#!/bin/bash
# enrollinator.sh — MDM-agnostic macOS onboarding runner.
#
# Reads its entire configuration from managed preferences in the
# `com.enrollinator.app` domain (installed via .mobileconfig). Picks a matching
# profile, opens swiftDialog in list mode, and walks the profile's steps:
# runs each step's Action, then evaluates its Conditions. If a step is marked
# Blocking, the runner polls its conditions until they all pass, surfacing a
# user-visible prompt the whole time.
#
# Designed to run from a LaunchAgent at login. Safe to run by hand:
#
#     sudo /usr/local/enrollinator/enrollinator.sh --profile Engineering
#     /usr/local/enrollinator/enrollinator.sh --config ./examples/enrollinator.mobileconfig
#
# Exit codes:
#   0  run finished (user may still have been required to satisfy blockers)
#   1  fatal runtime error
#   2  config error (no profile matched, malformed mobileconfig, …)
#   3  dependency missing (swiftDialog)
#   5  no console user to display to (non-daemon invocation only)

set -o pipefail

# Pin PATH to the system directories, before the first external command runs.
#
# The LaunchDaemon used to hand us /usr/local/bin FIRST. That directory ships
# empty and root-owned, but it is the one location in root's default PATH that
# third-party tooling routinely reparents to an unprivileged user — Homebrew on
# Intel chowns it to the installing user, and the sample Engineering playbook
# installs Homebrew. Wherever that has happened, any command this script
# resolved through PATH became a root code-execution primitive: plant
# /usr/local/bin/dirname, wait for the next run, and line 28 below executes it
# as root before require_root has even been reached — and its stdout becomes
# ENROLLINATOR_ROOT, which is where the lib/*.sh files get sourced from.
#
# Every external command in this script and its libs is now called by absolute
# path, so this assignment is belt-and-braces for any call added later that
# forgets the prefix. Nothing Enrollinator itself runs needs /usr/local/bin —
# DIALOG_BIN is an explicit absolute path.
#
# Step commands are deliberately NOT restricted this way: see
# ENROLLINATOR_STEP_PATH below.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

# The PATH handed to a step's `shell` action or condition — the admin's own
# commands, not ours. This keeps /usr/local/bin, because configs in the wild
# call `brew`, `jamf`, and other locally-installed tooling unqualified, and
# dropping it would break them for no gain: a `shell` action already runs
# arbitrary code as root by design, so what it resolves through PATH is not a
# trust boundary. The hardened PATH above is what protects Enrollinator's own
# command resolution, which is the part an attacker could otherwise hijack.
ENROLLINATOR_STEP_PATH="${ENROLLINATOR_STEP_PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
export ENROLLINATOR_STEP_PATH

# ----------------------------------------------------------------------------
# Paths and constants
# ----------------------------------------------------------------------------

ENROLLINATOR_ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
ENROLLINATOR_LIB="${ENROLLINATOR_ROOT}/lib"
ENROLLINATOR_LOG="${ENROLLINATOR_LOG:-/var/log/enrollinator.log}"
ENROLLINATOR_DOMAIN="${ENROLLINATOR_DOMAIN:-com.enrollinator.app}"
# Runtime scratch state (swiftDialog command files, PID files, image cache).
#
# Under root this is a fixed, root-owned 0755 directory — see ensure_state_dir
# for why these files must not sit loose in mode-1777 /var/tmp. That directory
# is deliberately NOT writable by anyone else, which includes an unprivileged
# `--skip-root-check` dev run, so those get their own per-user directory under
# TMPDIR (already 0700 and per-user, so the same hardening applies for free).
#
# Resolved here, before lib/ui.sh is sourced: ui.sh derives every command and
# PID file path from this value at source time.
if [ -n "${ENROLLINATOR_STATE_DIR:-}" ]; then
    :
elif [ "$(/usr/bin/id -u)" -eq 0 ]; then
    ENROLLINATOR_STATE_DIR="/var/tmp/enrollinator"
else
    ENROLLINATOR_STATE_DIR="${TMPDIR:-/tmp}/enrollinator-$(/usr/bin/id -u)"
fi
# Strip trailing slashes before anything reads this value.
#
# `test -L` RESOLVES through a trailing slash: for a symlink at /a/link,
# `[ -L /a/link ]` is true but `[ -L /a/link/ ]` is FALSE, while stat and rm
# both follow the link either way. And where `rm -rf /a/link` merely unlinks
# the symlink, `rm -rf /a/link/` recursively deletes the TARGET'S CONTENTS.
# One stray slash on the override therefore disabled ensure_state_dir's
# symlink guard and turned its cleanup into a recursive delete of whatever
# the link pointed at. The shipped defaults never end in a slash; an
# override typed by hand easily can.
while [ "${ENROLLINATOR_STATE_DIR%/}" != "$ENROLLINATOR_STATE_DIR" ]; do
    ENROLLINATOR_STATE_DIR="${ENROLLINATOR_STATE_DIR%/}"
done
ENROLLINATOR_PERSIST_DIR="${ENROLLINATOR_PERSIST_DIR:-/var/lib/enrollinator}"
ENROLLINATOR_COMPLETED_FLAG="${ENROLLINATOR_COMPLETED_FLAG:-${ENROLLINATOR_PERSIST_DIR}/completed}"

# shellcheck source=lib/plist.sh
. "${ENROLLINATOR_LIB}/plist.sh"
# shellcheck source=lib/ui.sh
. "${ENROLLINATOR_LIB}/ui.sh"
# shellcheck source=lib/plugins.sh
. "${ENROLLINATOR_LIB}/plugins.sh"

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------

log() {
    local level="$1"; shift
    local ts line
    ts="$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')"
    # Multi-line messages (command output, forensics) get the prefix on
    # EVERY line — each log line stands alone, so grep/tail stay coherent
    # and nothing appears as bare un-timestamped continuation lines.
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s [%s] %s\n' "$ts" "$level" "$line" >> "$ENROLLINATOR_LOG"
        # Interactively, echo everything to stderr.
        #
        # Non-interactively, still echo warn and error. This used to be gated
        # entirely on [ -t 2 ], which meant that under launchd or a Jamf policy
        # script — the two contexts this actually ships in — a fatal config
        # error produced exit 2 with ZERO output on stdout or stderr. The
        # policy log showed a bare failure and the reason lived only in
        # /var/log/enrollinator.log on the endpoint. Warnings and errors are
        # low-volume, so surfacing them costs nothing and makes the daemon's
        # StandardErrorPath and the Jamf policy log genuinely diagnostic.
        if [ -t 2 ]; then
            # CRLF, not LF, when writing to a terminal.
            #
            # swiftDialog is launched through sudo, and sudo puts the
            # controlling terminal into raw mode (clearing ONLCR) for as long
            # as it runs. The main run window is launched in the BACKGROUND and
            # lives for the whole session, so the terminal stays raw for the
            # entire run: every subsequent log line emits a bare LF, the cursor
            # never returns to column 0, and the transcript walks diagonally
            # off the screen. Restoring the line discipline around each launch
            # cannot fix that — the process holding the terminal is still
            # running, and it is the one we are waiting on.
            #
            # Emitting the carriage return ourselves is correct in both states:
            # with ONLCR off it supplies the CR the terminal no longer adds,
            # and with ONLCR on the extra CR is a no-op (the cursor is already
            # at column 0). The log FILE always gets plain LF — this applies
            # only to the interactive echo.
            printf '%s [%s] %s\r\n' "$ts" "$level" "$line" >&2
        else
            case "$level" in
                warn|error) printf '%s [%s] %s\n' "$ts" "$level" "$line" >&2 ;;
            esac
        fi
    done <<< "$*"
}

init_logging() {
    local dir
    dir="$(/usr/bin/dirname "$ENROLLINATOR_LOG")"
    [ -d "$dir" ] || /bin/mkdir -p "$dir" 2>/dev/null
    # If we can't write there (running as a non-root user), fall back to /tmp.
    if ! /usr/bin/touch "$ENROLLINATOR_LOG" 2>/dev/null; then
        ENROLLINATOR_LOG="/tmp/enrollinator.log"
        /usr/bin/touch "$ENROLLINATOR_LOG"
    fi
}

# ----------------------------------------------------------------------------
# Temp-file cleanup
# ----------------------------------------------------------------------------

# These four are deliberately GLOBAL, and main() assigns them without `local`.
#
# An EXIT trap fires after main() has already returned, so main's locals are
# out of scope by then: a trap body of `rm -f "$cfg"` expanded to `rm -f ""`
# and removed nothing. Every completed run leaked its resolved-config temp
# file — which holds the entire config — plus three more into /var/folders.
ENROLLINATOR_TMP_CFG=""
ENROLLINATOR_TMP_STEPS=""
ENROLLINATOR_TMP_RAN_IDS=""
ENROLLINATOR_TMP_ID_MAP=""

# Create the runtime state directory as a real, root-owned, 0755 directory.
#
# Everything Enrollinator writes at runtime (swiftDialog command files, PID
# files, the image cache) lives here. The directory itself is the security
# boundary: see the header comment in lib/ui.sh for why these files must not
# sit loose in mode-1777 /var/tmp. Because root will `: >` and chown files in
# here, we refuse to adopt a path we don't control — a symlink, or a directory
# somebody else created first — and replace it instead.
# _state_dir_is_sane <dir> <am_root>
# Verify an EXISTING path is safe to adopt. Every test here inspects the path
# itself, never a symlink target.
_state_dir_is_sane() {
    local dir="$1" am_root="$2"
    if [ -L "$dir" ]; then
        log error "State dir $dir is a symlink — refusing to use it"
        return 1
    fi
    if [ ! -d "$dir" ]; then
        log error "State dir $dir exists but is not a directory — refusing to use it"
        return 1
    fi
    if [ "$am_root" -eq 1 ]; then
        local owner
        owner="$(/usr/bin/stat -f '%u' "$dir" 2>/dev/null)"
        if [ "$owner" != "0" ]; then
            log error "State dir $dir is owned by uid ${owner:-unknown}, not root — refusing to use it (its contents could have been pre-planted)"
            return 1
        fi
    fi
    return 0
}

ensure_state_dir() {
    local dir="$ENROLLINATOR_STATE_DIR"
    local am_root=0
    [ "$(/usr/bin/id -u)" -eq 0 ] && am_root=1

    # Defensive re-strip: the value is normalized at assignment, but this
    # function is the one that can destroy things, so it does not take that
    # on trust. See the note at the ENROLLINATOR_STATE_DIR assignment.
    while [ "${dir%/}" != "$dir" ]; do dir="${dir%/}"; done

    # Floor on the path itself. ENROLLINATOR_STATE_DIR is env-overridable and
    # everything below creates or chowns it, so a value like "/" or "/var" —
    # a typo away from a stray override — must never reach those operations.
    if [ -z "$dir" ] || [ "${dir#/}" = "$dir" ]; then
        log error "State dir '$dir' is not an absolute path — refusing to use it"
        return 1
    fi
    case "${dir#/}" in
        */*) : ;;
        *)   log error "State dir '$dir' is a top-level directory — refusing to use it"
             return 1 ;;
    esac

    # Create the leaf ourselves, exclusively.
    #
    # This deliberately does NOT repair a bad directory by removing it. The
    # old code did `rm -rf "$dir"` and then `mkdir -p "$dir"`, which is two
    # operations with a window between them: an attacker who recreated the
    # path as a symlink in that window got root's subsequent `mkdir -p`
    # (silently succeeds on an existing target), `chmod 0755` and
    # `chown root:wheel` applied to the link's TARGET, since all three follow
    # symlinks. `mkdir` without -p is atomic and fails outright if anything
    # already exists at the path, so there is no window and nothing to race.
    #
    # -p is still used for the PARENT, which only ever needs to exist.
    local parent
    parent="$(/usr/bin/dirname "$dir")"
    [ -d "$parent" ] || /bin/mkdir -p "$parent" 2>/dev/null

    if /bin/mkdir "$dir" 2>/dev/null; then
        # We created it, so nothing can have been pre-planted inside.
        # mkdir applies the umask, so set the mode explicitly.
        /bin/chmod 0755 "$dir" 2>/dev/null
        [ "$am_root" -eq 1 ] && /usr/sbin/chown root:wheel "$dir" 2>/dev/null
        return 0
    fi

    # mkdir failed — usually because the directory already exists from an
    # earlier run, which is the normal case. Verify rather than rebuild, and
    # fail closed if it isn't ours. A hostile or corrupted state dir is
    # exactly when a root daemon should stop instead of trying to fix it.
    _state_dir_is_sane "$dir" "$am_root" || return 1
    /bin/chmod 0755 "$dir" 2>/dev/null
    return 0
}

# ----------------------------------------------------------------------------
# Single-instance lock
# ----------------------------------------------------------------------------
#
# Every path Enrollinator writes at runtime is FIXED per machine: the state
# directory (/var/tmp/enrollinator under root), swiftDialog's command and pid
# files inside it, and the completion flag. Nothing was stopping two instances
# from using them at once, and on a real deployment two instances is the normal
# case, not an exotic one:
#
#   * The LaunchDaemon runs `/usr/local/enrollinator/enrollinator.sh` with NO
#     arguments, so it always resolves config from the managed profile.
#   * An admin testing a change runs the same script by hand with --xml or
#     --config.
#
# Both then write the same dialog.pid and the same dialog command file, so the
# window on screen belongs to whichever instance launched it — usually the
# daemon, whose config came from the profile. The flags were parsed and obeyed
# by the manual run, but the run the user could SEE was the daemon's. That is
# indistinguishable from "--xml was ignored and it used the profile instead",
# and it happens only when a profile is installed: without one the daemon's
# argument-less run exits 2 at config resolution and leaves the field clear.
#
# mkdir is the lock primitive because it is atomic on every filesystem macOS
# ships, needs no external binary, and leaves the holder's pid inspectable.
ENROLLINATOR_LOCK_DIR="${ENROLLINATOR_STATE_DIR}/run.lock"
ENROLLINATOR_LOCK_HELD=0

acquire_run_lock() {
    local holder=""
    if /bin/mkdir "$ENROLLINATOR_LOCK_DIR" 2>/dev/null; then
        echo "$$" > "${ENROLLINATOR_LOCK_DIR}/pid"
        ENROLLINATOR_LOCK_HELD=1
        return 0
    fi
    holder="$(/bin/cat "${ENROLLINATOR_LOCK_DIR}/pid" 2>/dev/null)"
    # A lock left behind by a killed run must not wedge the machine forever —
    # this daemon is the only thing standing between a new Mac and its
    # onboarding, so failing closed on a stale lock would be worse than the
    # race it prevents.
    if [ -z "$holder" ] || ! /bin/kill -0 "$holder" 2>/dev/null; then
        log warn "Removing stale run lock at $ENROLLINATOR_LOCK_DIR (holder pid ${holder:-unknown} is gone)."
        /bin/rm -rf "$ENROLLINATOR_LOCK_DIR" 2>/dev/null
        if /bin/mkdir "$ENROLLINATOR_LOCK_DIR" 2>/dev/null; then
            echo "$$" > "${ENROLLINATOR_LOCK_DIR}/pid"
            ENROLLINATOR_LOCK_HELD=1
            return 0
        fi
    fi
    return 1
}

release_run_lock() {
    [ "$ENROLLINATOR_LOCK_HELD" -eq 1 ] || return 0
    /bin/rm -rf "$ENROLLINATOR_LOCK_DIR" 2>/dev/null
    ENROLLINATOR_LOCK_HELD=0
    return 0
}

cleanup_temp_files() {
    local f
    for f in "$ENROLLINATOR_TMP_CFG" "$ENROLLINATOR_TMP_STEPS" \
             "$ENROLLINATOR_TMP_RAN_IDS" "$ENROLLINATOR_TMP_ID_MAP"; do
        [ -n "$f" ] && /bin/rm -f "$f" 2>/dev/null
    done
    # ui.sh's replay cache is a mktemp -d that nothing else removes.
    [ -n "${UI_STATE_DIR:-}" ] && /bin/rm -rf "$UI_STATE_DIR" 2>/dev/null
    release_run_lock
    return 0
}

# ----------------------------------------------------------------------------
# Arg parsing
# ----------------------------------------------------------------------------

CLI_CONFIG=""
CLI_XML=""
CLI_PROFILE=""
CLI_DRY_RUN=0
CLI_TEST=0
CLI_SKIP_ROOT=0
CLI_FORCE=0
CLI_IGNORED_ARGS=""

usage() {
    /bin/cat <<EOF
Usage: enrollinator.sh [options]

Options:
  --config PATH         Use a local .mobileconfig instead of managed prefs.
                        Extracts the inner com.enrollinator.app payload.
  --xml PATH            Use a bare plist XML file (no .mobileconfig wrapping).
                        Useful for dev configs — schema rooted at the top level.
  --profile NAME        Force a specific profile, ignoring selectors.
  --domain DOMAIN       Override managed-prefs domain (default: com.enrollinator.app).
  --test                Run in test mode: skip non-dialog actions and treat
                        their steps as succeeded; dialog actions still run
                        and their condition-only / no-action steps still
                        evaluate normally.
  --force               Re-run even if /var/lib/enrollinator/completed exists.
  --dry-run             Parse config and print the plan, don't execute.
  --skip-root-check     Allow running as non-root (development only).
  -h, --help            Show this help.

Exit codes:
  0  success
  1  runtime error
  2  config error
  3  dependency missing (swiftDialog)
  4  must be root
  5  no console user to display to (non-daemon invocation only)
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --config)          CLI_CONFIG="$2"; shift 2 ;;
            --xml)             CLI_XML="$2"; shift 2 ;;
            --profile)         CLI_PROFILE="$2"; shift 2 ;;
            --domain)          ENROLLINATOR_DOMAIN="$2"; shift 2 ;;
            --test)            CLI_TEST=1; shift ;;
            --force)           CLI_FORCE=1; shift ;;
            --dry-run)         CLI_DRY_RUN=1; shift ;;
            --skip-root-check) CLI_SKIP_ROOT=1; shift ;;
            -h|--help)         usage; exit 0 ;;
            # Jamf passes $1=mount point, $2=computer name, $3=username to
            # EVERY script it runs. Treating those as errors meant the
            # standalone script exited 2 ("Unknown option: /") before doing
            # anything at all when used as a policy script — the documented
            # Method 2 deployment. Ignore bare positional arguments; a
            # genuinely mistyped flag still fails loudly.
            -*)                echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
            *)                 CLI_IGNORED_ARGS="${CLI_IGNORED_ARGS:+$CLI_IGNORED_ARGS }$1"; shift ;;
        esac
    done
    # Resolve config paths to absolute now — main() does `cd /` for daemon
    # hygiene before loading config, which would break relative paths.
    [ -n "$CLI_CONFIG" ] && [ "${CLI_CONFIG#/}" = "$CLI_CONFIG" ] && CLI_CONFIG="$PWD/$CLI_CONFIG"
    [ -n "$CLI_XML" ]    && [ "${CLI_XML#/}" = "$CLI_XML" ]       && CLI_XML="$PWD/$CLI_XML"
}

# Refuse to run unless we're root. Enrollinator installs pkgs, touches
# /var/lib/enrollinator, and needs to launchctl asuser — all root-only. Dev
# users can override with --skip-root-check but the UI bridge will
# degrade gracefully in that case.
require_root() {
    [ "$CLI_SKIP_ROOT" -eq 1 ] && return 0
    if [ "$(/usr/bin/id -u)" -ne 0 ]; then
        echo "enrollinator.sh must be run as root. Use sudo or deploy the LaunchDaemon." >&2
        exit 4
    fi
}

# When Enrollinator starts from its LaunchDaemon there is usually no console
# user yet. Wait for the loginwindow to hand /dev/console over.
#
# Pass 0 (the default) to wait indefinitely. That is the correct behaviour for
# the daemon, and the whole reason the daemon exists: under PreStage the pkg
# installs during Setup Assistant, so postinstall bootstraps this job while
# `_mbsetupuser` still owns the console. There is no reboot between that
# install and the user's first login, so this process IS the mechanism that
# carries the run across Setup Assistant. It must not give up partway.
#
# It used to time out after five minutes and let the caller proceed anyway,
# which drew nothing (there is no GUI session to place a window in) while
# still installing packages and running shell steps. Setup Assistant routinely
# outlasts five minutes, so that fired on ordinary hardware.
#
# Waiting forever is cheap and cannot accumulate: launchd runs one process per
# job label, a daemon still waiting at reboot is terminated, and RunAtLoad
# starts exactly one fresh instance on the way back up.
wait_for_console_user() {
    local timeout="${1:-0}" elapsed=0 user
    while [ "$timeout" -le 0 ] || [ "$elapsed" -lt "$timeout" ]; do
        user="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null)"
        case "$user" in
            ""|root|_*|loginwindow) : ;;   # keep waiting
            *) ENROLLINATOR_CONSOLE_USER="$user"; return 0 ;;
        esac
        # Heartbeat once a minute. Without it the log jumps straight from
        # "Enrollinator starting" to the run, and a wait that is working
        # correctly is indistinguishable from a hung daemon.
        if [ $((elapsed % 60)) -eq 0 ] && [ "$elapsed" -gt 0 ]; then
            log info "Waiting for a console user (${elapsed}s; console currently '${user:-none}')"
        fi
        /bin/sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# A console user exists the moment loginwindow hands over, which is a beat
# before the session is usable — the Dock and Finder are still coming up.
# swiftDialog launched into that gap stalls on a cold LaunchServices cache
# (the same "Getting ready…" freeze lib/ui.sh describes for the root-context
# case), so let the session settle first.
#
# Bounded, and non-fatal on expiry: unlike a missing console user, a missing
# Dock does not stop `launchctl asuser` from placing a window. A session that
# never grows a Dock should still get its onboarding.
wait_for_session_ready() {
    local timeout="${1:-60}" elapsed=0 uid
    uid="$(/usr/bin/id -u "${ENROLLINATOR_CONSOLE_USER:-}" 2>/dev/null)"
    [ -n "$uid" ] || return 0
    while [ "$elapsed" -lt "$timeout" ]; do
        if /usr/bin/pgrep -u "$uid" -x Dock >/dev/null 2>&1; then
            [ "$elapsed" -gt 0 ] && log info "Desktop session ready after ${elapsed}s"
            return 0
        fi
        /bin/sleep 1
        elapsed=$((elapsed + 1))
    done
    log warn "Dock never appeared for '$ENROLLINATOR_CONSOLE_USER' after ${timeout}s; continuing anyway."
    return 1
}

# ----------------------------------------------------------------------------
# Config loading
# ----------------------------------------------------------------------------

# Sets ENROLLINATOR_CFG_PATH to a plist containing just Enrollinator's config.
# Handles:
#   * --xml file.plist           (bare plist, schema rooted at the top level)
#   * --config file.mobileconfig (extracts the inner com.enrollinator.app payload)
#   * enrollinator.xml alongside the script (bundled pkg config, no flags needed)
#   * managed defaults domain    (snapshots via `defaults export`)
#
# It returns the path via a global rather than stdout because it also records
# ENROLLINATOR_CONFIG_SOURCE. Called as `cfg="$(load_config)"` the whole thing
# ran in a subshell, so that assignment — like any other state it wanted to
# publish — was discarded the moment the subshell exited, and error messages
# reported the config source as "unknown".
ENROLLINATOR_BUNDLED_XML="${ENROLLINATOR_ROOT}/enrollinator.xml"
# Where the active config actually came from. Reported in errors so a failure
# names the delivery path, not just the symptom.
ENROLLINATOR_CONFIG_SOURCE=""
ENROLLINATOR_CFG_PATH=""
load_config() {
    local raw
    local managed_path="${ENROLLINATOR_MANAGED_PREFS_DIR:-/Library/Managed Preferences}/${ENROLLINATOR_DOMAIN}.plist"
    if [ -n "$CLI_XML" ]; then
        ENROLLINATOR_CONFIG_SOURCE="--xml $CLI_XML"
        log info "Using --xml config: $CLI_XML"
        # Say out loud that the flag beat an installed profile. The precedence
        # is deliberate, so this is info rather than a warning — but without
        # it, a run driven by a flag and a run driven by a profile produce
        # identical logs ("Config loaded: /var/folders/…/enrollinator-cfg.X"),
        # and there is no way to tell from the log which config actually won.
        [ -f "$managed_path" ] && log info "A managed profile for '$ENROLLINATOR_DOMAIN' is also installed at $managed_path; --xml takes precedence over it."
        raw="$(load_bare_xml "$CLI_XML")" || exit $?
    elif [ -n "$CLI_CONFIG" ]; then
        ENROLLINATOR_CONFIG_SOURCE="--config $CLI_CONFIG"
        log info "Using --config config: $CLI_CONFIG"
        [ -f "$managed_path" ] && log info "A managed profile for '$ENROLLINATOR_DOMAIN' is also installed at $managed_path; --config takes precedence over it."
        raw="$(load_bare_xml "$CLI_CONFIG")" || exit $?
    elif [ -f "$ENROLLINATOR_BUNDLED_XML" ]; then
        ENROLLINATOR_CONFIG_SOURCE="bundled $ENROLLINATOR_BUNDLED_XML"
        log info "Using bundled config: $ENROLLINATOR_BUNDLED_XML"
        # A bundled XML outranks managed preferences. When a profile is ALSO
        # installed, the admin has almost certainly just pushed it expecting it
        # to take effect — and it silently does nothing. This is the "I updated
        # the profile and the Mac ignored it" support ticket, so say so loudly
        # rather than at info level.
        if [ -f "$managed_path" ]; then
            log warn "A managed profile for '$ENROLLINATOR_DOMAIN' is installed at $managed_path but is being IGNORED — the bundled config at $ENROLLINATOR_BUNDLED_XML takes precedence. Rebuild the pkg without enrollinator.xml (or delete that file) if the profile should win."
        fi
        raw="$(load_bare_xml "$ENROLLINATOR_BUNDLED_XML")" || exit $?
    else
        ENROLLINATOR_CONFIG_SOURCE="managed preferences domain '$ENROLLINATOR_DOMAIN'"
        # Name the exact path and the two ways an MDM-delivered profile fails
        # to land there. Both produce an empty config, and the downstream error
        # ("No Playbooks defined") points at the config's contents rather than
        # at the delivery problem that actually caused it.
        if [ ! -f "$managed_path" ]; then
            log warn "No managed preferences found at $managed_path. If the profile was deployed by MDM, check that the payload's preference domain is exactly '$ENROLLINATOR_DOMAIN', and that the profile is scoped at COMPUTER level — a user-level profile installs into the user's own Managed Preferences directory, which this daemon runs too early and too privileged to read."
        fi
        raw="$(plist_export_managed "$ENROLLINATOR_DOMAIN")" || exit $?
    fi
    # Undo MDM stringification before anything else — a mangled
    # PayloadContent would block the envelope extraction below.
    if plist_repair_stringified "$raw"; then
        log warn "Config contained MDM-stringified keys — repaired automatically. Consider re-uploading the bare plist so the deployed profile is clean."
    fi
    # Regardless of source, unwrap a .mobileconfig envelope when present.
    # Configs arrive wrapped more often than you'd think: a full mobileconfig
    # passed to --xml, or an envelope mistakenly uploaded into an MDM
    # custom-settings payload so the whole thing lands inside the prefs
    # domain. Bare configs pass through untouched.
    if plist_exists "$raw" ":PayloadContent"; then
        log info "Config contains a PayloadContent envelope — extracting inner payload"
        local inner
        inner="$(extract_mobileconfig_payload "$raw")" || { /bin/rm -f "$raw"; exit 2; }
        /bin/rm -f "$raw"
        if plist_repair_stringified "$inner"; then
            log warn "Extracted payload contained MDM-stringified keys — repaired automatically."
        fi
        ENROLLINATOR_CFG_PATH="$inner"
        return 0
    fi
    ENROLLINATOR_CFG_PATH="$raw"
    return 0
}

# Copy a bare plist XML to a temp location and hand back the path. We normalize
# to a predictable binary1/xml1 format so downstream PlistBuddy calls don't
# care whether the dev handed us XML, JSON, or a mangled file.
load_bare_xml() {
    local src="$1"
    if [ ! -f "$src" ]; then
        log error "XML config not found: $src"
        exit 2
    fi
    local out
    # Do NOT append .plist after mktemp — that produces a second,
    # non-atomic path vulnerable to a symlink race. plutil and PlistBuddy
    # identify file format from content, not extension.
    out="$(/usr/bin/mktemp -t enrollinator-cfg)"
    if ! /bin/cp "$src" "$out"; then
        log error "Failed to read $src"
        exit 2
    fi
    # Best-effort normalize. Non-plist XML will fail here; surface that early.
    if ! /usr/bin/plutil -convert xml1 "$out" 2>/dev/null; then
        # Maybe a CMS-signed .mobileconfig — try stripping the signature.
        if ! /usr/bin/security cms -D -i "$src" -o "$out" 2>/dev/null \
            || ! /usr/bin/plutil -convert xml1 "$out" 2>/dev/null; then
            log error "File is not a valid property list: $src"
            /bin/rm -f "$out"
            exit 2
        fi
        log info "Stripped CMS signature from $src"
    fi
    echo "$out"
}

# From a .mobileconfig, extract the first PayloadContent entry whose
# PayloadType is `com.enrollinator.app` and emit a standalone plist path.
# Uses only /usr/bin/plutil, which is built into macOS.
extract_mobileconfig_payload() {
    local src="$1"
    if [ ! -f "$src" ]; then
        log error "Config file not found: $src"
        exit 2
    fi

    local out
    # Do NOT append .plist after mktemp — that produces a second,
    # non-atomic path vulnerable to a symlink race. plutil and PlistBuddy
    # identify file format from content, not extension.
    out="$(/usr/bin/mktemp -t enrollinator-cfg)"

    # If there's no :PayloadContent, treat the file as an already-bare
    # com.enrollinator.app prefs plist.
    if ! /usr/bin/plutil -extract "PayloadContent" raw "$src" >/dev/null 2>&1; then
        /bin/cp "$src" "$out"
        echo "$out"
        return 0
    fi

    # Iterate PayloadContent indices looking for Enrollinator's payload.
    #
    # Which PayloadType counts follows $ENROLLINATOR_DOMAIN (--domain), the
    # same value plist_export_managed uses to find the installed profile.
    # This used to match only the shipped default, so under --domain the two
    # halves disagreed: the managed-prefs branch read the custom domain
    # happily while --config/--xml could not extract a payload carrying it,
    # and the run died at exit 2. The effect on the machine was that passing
    # a config flag accomplished nothing and the installed profile stayed the
    # only config that loaded.
    #
    # The shipped default is still accepted as a fallback, so a config built
    # before --domain was in play keeps working.
    local want="${ENROLLINATOR_DOMAIN:-com.enrollinator.app}"
    local i=0 type seen="" match=-1 fallback=-1
    while type="$(/usr/bin/plutil -extract "PayloadContent.$i.PayloadType" raw -o - "$src" 2>/dev/null)"; do
        seen="${seen:+$seen, }$type"
        if [ "$type" = "$want" ]; then
            match=$i
            break
        fi
        if [ "$type" = "com.enrollinator.app" ] && [ "$fallback" -lt 0 ]; then
            fallback=$i
        fi
        i=$((i+1))
    done
    if [ "$match" -lt 0 ] && [ "$fallback" -ge 0 ]; then
        match=$fallback
        log info "No '$want' payload in $src; using its 'com.enrollinator.app' payload instead."
    fi
    if [ "$match" -ge 0 ]; then
        # Pull the whole sub-dict into its own xml plist. The PayloadUUID
        # etc. keys ride along — harmless, Enrollinator never reads them.
        /usr/bin/plutil -extract "PayloadContent.$match" xml1 -o "$out" "$src" 2>/dev/null
        echo "$out"
        return 0
    fi

    # Name what the file actually contains. "No payload found" alone sends
    # you looking at the flag or the path, when the answer is in the file.
    log error "No '$want' payload found in $src. PayloadTypes present: ${seen:-none}. If this profile was built for a different preference domain, pass --domain <that domain>."
    exit 2
}

# ----------------------------------------------------------------------------
# Profile selection
# ----------------------------------------------------------------------------

# Echoes the index (0-based) of the selected playbook in :Playbooks, or empty
# if none match and no DefaultPlaybook is configured.
pick_profile() {
    local cfg="$1"
    local forced="$2"      # from --profile
    local default_name

    default_name="$(plist_get "$cfg" ":DefaultPlaybook")"
    local count
    count="$(plist_array_count "$cfg" ":Playbooks")"
    if [ "$count" -eq 0 ]; then
        if plist_exists "$cfg" ":Playbooks"; then
            # The key exists but :Playbooks:0 doesn't — it's not an array of
            # dicts. The usual culprit is an MDM editor re-serializing the
            # array as a single string on upload/edit.
            log error "Playbooks key exists but is not a readable array of dicts, and automatic repair could not recover it. Re-upload the bare plist (never edit the payload in the MDM console) or deploy a signed .mobileconfig. Config source: ${ENROLLINATOR_CONFIG_SOURCE:-unknown}"
        else
            log error "No Playbooks defined in config. Config source: ${ENROLLINATOR_CONFIG_SOURCE:-unknown}"
        fi
        exit 2
    fi

    # --profile wins.
    if [ -n "$forced" ]; then
        find_profile_by_name "$cfg" "$forced" && return 0
        log error "--profile '$forced' not found"
        exit 2
    fi

    # Selectors were removed; the only ways to choose a playbook are now
    # --profile (handled above) and DefaultPlaybook (fallback below).
    if [ -n "$default_name" ]; then
        find_profile_by_name "$cfg" "$default_name" && return 0
        log error "DefaultPlaybook '$default_name' not found in Playbooks (names are matched exactly, case-sensitive)"
        exit 2
    fi

    # No DefaultPlaybook. Fall back to the only playbook when there is just
    # one, or to the first when the welcome-screen picker will let the user
    # choose anyway. Hard-fail only when neither applies.
    if [ "$count" -eq 1 ]; then
        log info "No DefaultPlaybook set; using the only defined playbook"
        echo 0
        return 0
    fi
    if [ "$(plist_bool "$cfg" ":WelcomeScreen:PlaybookPicker:Enabled" false)" = "true" ]; then
        log info "No DefaultPlaybook set; PlaybookPicker enabled — starting from the first playbook"
        echo 0
        return 0
    fi

    log error "No playbook matched and no DefaultPlaybook set"
    exit 2
}

find_profile_by_name() {
    local cfg="$1" name="$2"
    local count i n
    count="$(plist_array_count "$cfg" ":Playbooks")"
    for (( i=0; i<count; i++ )); do
        n="$(plist_get "$cfg" ":Playbooks:$i:Name")"
        if [ "$n" = "$name" ]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# ----------------------------------------------------------------------------
# Step execution
# ----------------------------------------------------------------------------

# Writes id|name|description|icon per step into a temp file, echoes the path.
# Icon is whatever the Step's Icon key says — a local path, a URL, or a
# "SF=symbol.name" token that swiftDialog understands natively.
build_steps_manifest() {
    local cfg="$1" pkey="$2"
    local manifest
    manifest="$(/usr/bin/mktemp -t enrollinator-steps)"
    local count i id name desc icon
    count="$(plist_array_count "$cfg" "${pkey}:Steps")"
    for (( i=0; i<count; i++ )); do
        id="$(plist_get   "$cfg" "${pkey}:Steps:$i:Id")"
        name="$(plist_get "$cfg" "${pkey}:Steps:$i:Name")"
        desc="$(plist_get "$cfg" "${pkey}:Steps:$i:Description")"
        icon="$(plist_get "$cfg" "${pkey}:Steps:$i:Icon")"
        [ -z "$id" ] && id="step-$i"
        [ -z "$name" ] && name="$id"
        # Use ASCII unit-separator (0x1F) so pipe characters in step
        # Name/Description/Icon values don't corrupt the field boundaries.
        printf '%s\x1f%s\x1f%s\x1f%s\n' "$id" "$name" "$desc" "$icon" >> "$manifest"
    done
    echo "$manifest"
}

# Run all conditions for a step. Returns 0 if every condition passes.
# Echoes a single message (last failing condition's, or last passing one).
eval_step_conditions() {
    local cfg="$1" skey="$2"
    local count i type msg rc last_msg=""
    count="$(plist_array_count "$cfg" "${skey}:Conditions")"
    if [ "$count" -eq 0 ]; then
        echo "ok"
        return 0
    fi
    for (( i=0; i<count; i++ )); do
        msg="$(condition_run "$cfg" "${skey}:Conditions:$i")"
        rc=$?
        last_msg="$msg"
        if [ $rc -ne 0 ]; then
            echo "$msg"
            return $rc
        fi
    done
    echo "$last_msg"
    return 0
}

# Run a single step. Arguments: cfg, pkey, step_index, ui_index.
#
# Flow:
#   1. Fire Action (if present). Failures honor ContinueOnFailure.
#   2. Evaluate Conditions. If all pass → success.
#   3. If any fail and Blocking=true → poll with UserPrompt banner.
#   4. If any fail and Blocking=false → mark failed (or success if
#      ContinueOnFailure=true — we still treat the run as advancing).
run_step() {
    local cfg="$1" pkey="$2" idx="$3" ui_idx="$4"
    local skey="${pkey}:Steps:$idx"

    local id name blocking continue_on_failure user_prompt poll timeout
    id="$(plist_get "$cfg" "$skey:Id")"
    name="$(plist_get "$cfg" "$skey:Name")"
    blocking="$(plist_bool "$cfg" "$skey:Blocking" false)"
    continue_on_failure="$(plist_bool "$cfg" "$skey:ContinueOnFailure" false)"
    user_prompt="$(plist_get "$cfg" "$skey:UserPrompt")"
    poll="$(plist_get "$cfg" "$skey:PollIntervalSeconds")"
    poll="${poll:-5}"
    timeout="$(plist_get "$cfg" "$skey:TimeoutSeconds")"
    timeout="${timeout:-0}"   # 0 = no timeout

    # An MDM editor can hand us a <string> where the schema wants an <integer>
    # ("300", "5 minutes"). Unvalidated, those reach `sleep` and `[ -gt ]`:
    # the timeout comparison errors out with "integer expression expected" on
    # every poll, and a bad interval makes `sleep` fail instantly, spinning
    # the blocking loop as fast as the CPU allows.
    if ! [[ "$poll" =~ ^[0-9]+$ ]] || [ "$poll" -lt 1 ]; then
        [ -n "$poll" ] && [ "$poll" != "5" ] \
            && log warn "step=$id PollIntervalSeconds='$poll' is not a positive integer — using 5"
        poll=5
    fi
    if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
        log warn "step=$id TimeoutSeconds='$timeout' is not an integer — treating as no timeout"
        timeout=0
    fi

    # Test mode caps blocking steps at 5s so a rehearsal doesn't actually hang
    # the installer waiting for the tester to go sign into ZScaler.
    if [ "${ENROLLINATOR_TEST_MODE:-0}" = "1" ] && [ "$blocking" = "true" ]; then
        if [ "$timeout" -eq 0 ] || [ "$timeout" -gt 5 ]; then
            timeout=5
        fi
        poll=1
    fi

    # WaitWindow pulls (optional).
    local ww_title ww_message ww_video ww_video_autoplay ww_width ww_height ww_slideshow="" ww_has=0
    local ww_title_fs="" ww_msg_fs="" ww_blur="" ww_ontop=""
    if plist_exists "$cfg" "$skey:WaitWindow"; then
        ww_has=1
        ww_title="$(plist_get    "$cfg" "$skey:WaitWindow:Title")"
        ww_message="$(plist_get  "$cfg" "$skey:WaitWindow:Message")"
        ww_video="$(plist_get          "$cfg" "$skey:WaitWindow:Video")"
        ww_video_autoplay="$(plist_get "$cfg" "$skey:WaitWindow:VideoAutoplay")"
        ww_width="$(plist_get          "$cfg" "$skey:WaitWindow:Width")"
        ww_height="$(plist_get   "$cfg" "$skey:WaitWindow:Height")"
        ww_title_fs="$(plist_get "$cfg" "$skey:WaitWindow:TitleFontSize")"
        ww_msg_fs="$(plist_get   "$cfg" "$skey:WaitWindow:MessageFontSize")"
        ww_blur="$(plist_get     "$cfg" "$skey:WaitWindow:Blur")"
        ww_ontop="$(plist_get    "$cfg" "$skey:WaitWindow:AlwaysOnTop")"
        [ -z "$ww_title" ] && ww_title="$name"
        [ -z "$ww_message" ] && ww_message="${user_prompt:-Please complete the action shown and leave this window open.}"
        local ss_count j f_img f_title f_msg
        local ww_ss_titles="" ww_ss_msgs=""
        ss_count="$(plist_array_count "$cfg" "$skey:WaitWindow:Slideshow")"
        for (( j=0; j<ss_count; j++ )); do
            # Try dict format (Image sub-key) first; fall back to plain string entry.
            f_img="$(plist_get "$cfg" "$skey:WaitWindow:Slideshow:$j:Image")"
            if [ -n "$f_img" ]; then
                f_title="$(plist_get "$cfg" "$skey:WaitWindow:Slideshow:$j:Title")"
                f_msg="$(plist_get   "$cfg" "$skey:WaitWindow:Slideshow:$j:Message")"
            else
                f_img="$(plist_get   "$cfg" "$skey:WaitWindow:Slideshow:$j")"
                f_title=""
                f_msg=""
            fi
            [ -z "$f_img" ] && [ -z "$f_title" ] && [ -z "$f_msg" ] && continue
            ww_slideshow="${ww_slideshow:+${ww_slideshow}|}${f_img}"
            ww_ss_titles="${ww_ss_titles:+${ww_ss_titles}|}${f_title}"
            ww_ss_msgs="${ww_ss_msgs:+${ww_ss_msgs}|}${f_msg}"
        done
    fi

    log info "step=$id name=$name blocking=$blocking"

    # Sync the run-level blur keeper to this step's blur intent, BEFORE any
    # UI surface runs.  Doing this at the step boundary — rather than at each
    # dialog function's entry — avoids the leak where intermediate UI calls
    # inside the step run against a temporarily-restored global blur and tear
    # down the keeper mid-step.
    #
    # A step can opt into blur from MORE THAN ONE place:
    #   * WaitWindow.Blur — already read into ww_blur above
    #   * Action.Blur     — read here for action_dialog (or any future action
    #                       type that forwards blur to ui_dialog_popup)
    # Any "true" wins; otherwise fall back to the global ENROLLINATOR_UI_BLUR.
    # This is critical: if a step sets blur via Action.Blur (not WaitWindow)
    # and we only checked WaitWindow.Blur, the keeper would stop at the step
    # boundary and the user would see a flicker between consecutive blurred
    # steps that don't use WaitWindow.
    local _action_blur=""
    if plist_exists "$cfg" "$skey:Action"; then
        _action_blur="$(plist_get "$cfg" "$skey:Action:Blur")"
    fi
    local _step_blur="${ENROLLINATOR_UI_BLUR:-0}"
    [ "$ww_blur"      = "true"  ] && _step_blur=1
    [ "$_action_blur" = "true"  ] && _step_blur=1
    case "$_step_blur" in
        true|1) _step_blur=1 ;;
        *)      _step_blur=0 ;;
    esac
    if [ "$_step_blur" = "1" ]; then
        ui_run_blur_keeper_start "${ww_width:-}" "${ww_height:-}"
    else
        ui_run_blur_keeper_stop
    fi

    # 1. Action.
    if plist_exists "$cfg" "$skey:Action"; then
        ui_set_step_status "$ui_idx" progress "Running…"
        local action_msg action_rc
        action_msg="$(action_run "$cfg" "$skey" 2>&1)"
        action_rc=$?
        if [ $action_rc -ne 0 ]; then
            log warn "step=$id action failed rc=$action_rc: $action_msg"
            if [ "$continue_on_failure" = "true" ]; then
                ui_set_step_status "$ui_idx" fail "Action failed (continuing)"
            else
                ui_set_step_status "$ui_idx" fail "$(trim_one_line "$action_msg")"
                return $action_rc
            fi
        else
            # Log full success output — a command can exit 0 without doing
            # what you meant (e.g. `jamf policy -event x` with no matching
            # policy), and this is the only place that's visible. log()
            # prefixes every line, so multi-line output stays greppable.
            log info "step=$id action ok: $action_msg"
        fi

        # Test mode: non-dialog actions are simulated (action_run returned 0
        # without doing the work), so any conditions that check for the
        # action's side effects (e.g. a shell action that installs an app
        # which a downstream app_installed condition then looks for) would
        # legitimately fail.  Mark the step as succeeded and skip conditions
        # in that case so the user can rehearse the flow end-to-end.
        # Dialog actions are exempt: they have no side effects and run for
        # real even in test mode, so their conditions still make sense.
        # Blocking steps are also exempt from the early return: they fall
        # through to the WaitWindow section so the tester can see the UI;
        # the 5s timeout cap (set above) prevents them from hanging.
        if [ "${ENROLLINATOR_TEST_MODE:-0}" = "1" ]; then
            local _act_type
            _act_type="$(plist_get "$cfg" "$skey:Action:Type")"
            if [ -n "$_act_type" ] && [ "$_act_type" != "dialog" ] && [ "$blocking" != "true" ]; then
                ui_set_step_status "$ui_idx" success "TEST MODE: skipped"
                return 0
            fi
        fi
    fi

    # 2. Initial condition check.
    if ! plist_exists "$cfg" "$skey:Conditions"; then
        ui_set_step_status "$ui_idx" success "Done"
        return 0
    fi

    local cond_msg cond_rc
    cond_msg="$(eval_step_conditions "$cfg" "$skey")"
    cond_rc=$?
    if [ $cond_rc -eq 0 ]; then
        ui_set_step_status "$ui_idx" success "$(trim_one_line "$cond_msg")"
        return 0
    fi

    # 3. Non-blocking failure: mark and move on.
    if [ "$blocking" != "true" ]; then
        if [ "$continue_on_failure" = "true" ]; then
            ui_set_step_status "$ui_idx" fail "$(trim_one_line "$cond_msg") (skipped)"
            return 0
        fi
        ui_set_step_status "$ui_idx" fail "$(trim_one_line "$cond_msg")"
        return 1
    fi

    # A rc=2 condition is malformed config, not an unmet state: an unknown
    # Type, a missing required key. It can never become true, so blocking on
    # it would hang the run forever — TimeoutSeconds defaults to "no timeout",
    # and there is no user action that could ever satisfy it. Fail the step.
    if [ $cond_rc -eq 2 ]; then
        log error "step=$id has a malformed condition; refusing to block on it: $cond_msg"
        ui_set_step_status "$ui_idx" error "$(trim_one_line "$cond_msg")"
        [ "$continue_on_failure" = "true" ] && return 0
        return 1
    fi

    # 4. Blocking: poll until pass (or timeout). Prefer a WaitWindow popup
    # over stomping on the main window's subtitle.
    if [ "$ww_has" -eq 1 ]; then
        local _saved_blur="$ENROLLINATOR_UI_BLUR" _saved_ontop="$ENROLLINATOR_UI_ONTOP"
        [ "$ww_blur"  = "true"  ] && ENROLLINATOR_UI_BLUR=1
        [ "$ww_blur"  = "false" ] && ENROLLINATOR_UI_BLUR=0
        [ "$ww_ontop" = "true"  ] && ENROLLINATOR_UI_ONTOP=1
        [ "$ww_ontop" = "false" ] && ENROLLINATOR_UI_ONTOP=0
        export ENROLLINATOR_UI_BLUR ENROLLINATOR_UI_ONTOP
        ui_wait_open "$ww_title" "$ww_message" "$ww_slideshow" "$ww_video" "$ww_width" "$ww_height" "$ww_title_fs" "$ww_msg_fs" "$ww_ss_titles" "$ww_ss_msgs" "$ww_video_autoplay"
        ENROLLINATOR_UI_BLUR="$_saved_blur"; ENROLLINATOR_UI_ONTOP="$_saved_ontop"
        export ENROLLINATOR_UI_BLUR ENROLLINATOR_UI_ONTOP
    elif [ -n "$user_prompt" ]; then
        ui_set_banner "$user_prompt"
    fi
    local now_ts elapsed last_ts
    last_ts="$(/bin/date +%s)"
    elapsed=0

    while :; do
        ui_set_step_status "$ui_idx" wait "$(trim_one_line "$cond_msg")"
        /bin/sleep "$poll"

        cond_msg="$(eval_step_conditions "$cfg" "$skey")"
        cond_rc=$?
        if [ $cond_rc -eq 0 ]; then
            ui_set_step_status "$ui_idx" success "$(trim_one_line "$cond_msg")"
            if [ "$ww_has" -eq 1 ]; then
                ui_wait_close
            else
                ui_set_banner "$(plist_get "$cfg" ":Branding:Subtitle")"
            fi
            return 0
        fi

        if [ "$timeout" -gt 0 ]; then
            now_ts="$(/bin/date +%s)"
            # Pause — don't reset — the clock while the user is reviewing
            # back-slides, so a mid-navigation expiry doesn't end the step
            # under their feet. Accumulate only the intervals they weren't
            # navigating through. The old code assigned start_ts=now on every
            # navigating poll, which threw away ALL the time banked so far:
            # one "← Back" click silently granted a fresh full timeout.
            if [ ! -f "${WAIT_NAVIGATING_FILE:-}" ]; then
                elapsed=$(( elapsed + (now_ts - last_ts) ))
            fi
            last_ts="$now_ts"
            if [ "$elapsed" -ge "$timeout" ]; then
                log warn "step=$id blocking timeout after ${elapsed}s"
                if [ "$ww_has" -eq 1 ]; then
                    ui_wait_close
                else
                    ui_set_banner "$(plist_get "$cfg" ":Branding:Subtitle")"
                fi
                if [ "$continue_on_failure" = "true" ]; then
                    ui_set_step_status "$ui_idx" fail "Timed out (continuing)"
                    return 0
                fi
                ui_set_step_status "$ui_idx" error "Timed out"
                return 1
            fi
        fi
    done
}

# mark_unvisited_skipped <from> <to>
# Mark every step in [from, to) that hasn't run yet as Skipped in the UI.
# Reads main()'s _visited_idx via bash's dynamic scoping, and is idempotent —
# the end-of-run sweep calls it over the whole range as a backstop.
mark_unvisited_skipped() {
    local from="$1" to="$2" k
    for (( k=from; k<to; k++ )); do
        [ -n "${_visited_idx[$k]:-}" ] && continue
        ui_set_step_status "$k" pending "Skipped"
    done
}

# First line only, trimmed to something UI-friendly (80 chars).
trim_one_line() {
    local s="$1"
    s="${s%%$'\n'*}"
    if [ "${#s}" -gt 80 ]; then
        s="${s:0:77}…"
    fi
    printf '%s' "$s"
}

# ----------------------------------------------------------------------------
# Hardware info + help message
# ----------------------------------------------------------------------------

# Marketing model name ("MacBook Pro") rather than the identifier hw.model
# reports ("MacBookPro18,4"). system_profiler is the only source that covers
# both Intel and Apple silicon; falls back to the identifier so a branding
# string never renders blank.
hw_marketing_model() {
    local name
    name="$(/usr/sbin/system_profiler SPHardwareDataType 2>/dev/null \
        | /usr/bin/awk -F': ' '/Model Name/ {print $2; exit}')"
    [ -z "$name" ] && name="$(/usr/sbin/sysctl -n hw.model 2>/dev/null)"
    printf '%s' "$name"
}

# Look up a hardware info field by short key. Echoes a single line (or empty).
hw_info_value() {
    case "$1" in
        console_user)
            printf '%s' "${ENROLLINATOR_CONSOLE_USER:-$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null)}"
            ;;
        full_name)
            local _fu="${ENROLLINATOR_CONSOLE_USER:-$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null)}"
            [ -n "$_fu" ] && /usr/bin/id -F "$_fu" 2>/dev/null
            ;;
        hostname)
            /usr/sbin/scutil --get LocalHostName 2>/dev/null
            ;;
        computer_name)
            /usr/sbin/scutil --get ComputerName 2>/dev/null
            ;;
        serial_number)
            /usr/sbin/ioreg -c IOPlatformExpertDevice -d 2 2>/dev/null \
                | /usr/bin/awk -F'"' '/IOPlatformSerialNumber/ {print $4; exit}'
            ;;
        model)
            /usr/sbin/sysctl -n hw.model 2>/dev/null
            ;;
        model_name)
            hw_marketing_model
            ;;
        os_version)
            /usr/bin/sw_vers -productVersion 2>/dev/null
            ;;
        ip_address)
            /usr/sbin/ipconfig getifaddr en0 2>/dev/null \
                || /usr/sbin/ipconfig getifaddr en1 2>/dev/null
            ;;
        uuid)
            /usr/sbin/ioreg -c IOPlatformExpertDevice -d 2 2>/dev/null \
                | /usr/bin/awk -F'"' '/IOPlatformUUID/ {print $4; exit}'
            ;;
        *) return ;;
    esac
}

# Human label for each hw field. Used by the infobox rendering.
hw_info_label() {
    case "$1" in
        console_user)  echo "User" ;;
        full_name)     echo "Name" ;;
        hostname)      echo "Hostname" ;;
        computer_name) echo "Computer" ;;
        serial_number) echo "Serial" ;;
        model)         echo "Model ID" ;;
        model_name)    echo "Model" ;;
        os_version)    echo "macOS" ;;
        ip_address)    echo "IP" ;;
        uuid)          echo "UUID" ;;
        *)             echo "$1" ;;
    esac
}

# Expand {token} placeholders in a branding string with live hardware/user
# values. Tokens match the hw_info_value key names:
#   {console_user}  {full_name}   {hostname}   {computer_name}
#   {serial_number} {model}       {model_name} {os_version}
#   {ip_address}    {uuid}
# Example: "Setting up {full_name}'s Mac!" → "Setting up Jane Smith's Mac!"
expand_title_vars() {
    local str="$1" key value
    for key in console_user full_name hostname computer_name \
                serial_number model model_name os_version ip_address uuid; do
        [[ "$str" == *"{$key}"* ]] || continue
        value="$(hw_info_value "$key")"
        str="${str//\{$key\}/$value}"
    done
    printf '%s' "$str"
}

# Build the swiftDialog --infobox markdown from the HardwareInfo config.
# Returns empty if HardwareInfo.Enabled is not true.
build_hw_infobox() {
    local cfg="$1"
    local enabled
    enabled="$(plist_bool "$cfg" ":HardwareInfo:Enabled" false)"
    [ "$enabled" = "true" ] || { printf ''; return 0; }

    local count
    count="$(plist_array_count "$cfg" ":HardwareInfo:Fields")"
    [ "$count" -eq 0 ] && { printf ''; return 0; }

    local out="" i field value label
    for (( i=0; i<count; i++ )); do
        field="$(plist_get "$cfg" ":HardwareInfo:Fields:$i")"
        [ -z "$field" ] && continue
        # swiftDialog infobox honors markdown; double-space == line break.
        case "$field" in
            spacer)
                # A line of literal spaces collapses in markdown, so park a
                # non-breaking space there to keep the blank line.
                out="${out}&nbsp;  "$'\n'
                ;;
            text:*)
                out="${out}$(expand_title_vars "${field#text:}")  "$'\n'
                ;;
            *)
                value="$(hw_info_value "$field")"
                [ -z "$value" ] && value="—"
                label="$(hw_info_label "$field")"
                out="${out}**${label}:** ${value}  "$'\n'
                ;;
        esac
    done
    printf '%s' "$out"
}

# Build the swiftDialog --helpmessage markdown from the Help config.
# Returns empty if Help.Enabled is not true.
build_help_message() {
    local cfg="$1"
    local enabled
    enabled="$(plist_bool "$cfg" ":Help:Enabled" false)"
    [ "$enabled" = "true" ] || { printf ''; return 0; }

    local title message
    title="$(plist_get "$cfg" ":Help:Title")"
    message="$(plist_get "$cfg" ":Help:Message")"
    [ -z "$title" ] && title="Need help?"

    local out=""
    out="${out}### ${title}"$'\n\n'
    if [ -n "$message" ]; then
        out="${out}${message}"$'\n\n'
    fi

    local count i label detail url
    count="$(plist_array_count "$cfg" ":Help:Contacts")"
    for (( i=0; i<count; i++ )); do
        label="$(plist_get  "$cfg" ":Help:Contacts:$i:Label")"
        detail="$(plist_get "$cfg" ":Help:Contacts:$i:Detail")"
        url="$(plist_get    "$cfg" ":Help:Contacts:$i:URL")"
        [ -z "$label" ] && continue
        if [ -n "$url" ]; then
            out="${out}- **${label}:** [${detail:-$url}](${url})"$'\n'
        elif [ -n "$detail" ]; then
            out="${out}- **${label}:** ${detail}"$'\n'
        else
            out="${out}- ${label}"$'\n'
        fi
    done

    printf '%s' "$out"
}

# ----------------------------------------------------------------------------
# Dry-run
# ----------------------------------------------------------------------------

dry_run_plan() {
    local cfg="$1" pkey="$2" pname="$3"
    local count i id name action_type blocking cconds on_success on_failure

    echo "Playbook: $pname"
    count="$(plist_array_count "$cfg" "${pkey}:Steps")"
    echo "Steps:    $count"
    for (( i=0; i<count; i++ )); do
        id="$(plist_get   "$cfg" "${pkey}:Steps:$i:Id")"
        name="$(plist_get "$cfg" "${pkey}:Steps:$i:Name")"
        action_type="$(plist_get "$cfg" "${pkey}:Steps:$i:Action:Type")"
        blocking="$(plist_bool "$cfg" "${pkey}:Steps:$i:Blocking" false)"
        cconds="$(plist_array_count "$cfg" "${pkey}:Steps:$i:Conditions")"
        on_success="$(plist_get "$cfg" "${pkey}:Steps:$i:OnSuccess")"
        on_failure="$(plist_get "$cfg" "${pkey}:Steps:$i:OnFailure")"
        local branch_str=""
        [ -n "$on_success" ] && branch_str=" on_success=${on_success}"
        [ -n "$on_failure" ] && branch_str="${branch_str} on_failure=${on_failure}"
        printf '  [%d] %s (%s) action=%s blocking=%s conditions=%d%s\n' \
            "$i" "$id" "$name" "${action_type:-none}" "$blocking" "$cconds" "$branch_str"
    done
}

# ----------------------------------------------------------------------------
# Welcome screen
# ----------------------------------------------------------------------------

# show_welcome_screen <cfg>
# Displays the welcome dialog if WelcomeScreen.Enabled is true in the config.
# Supports an optional "Not Now" deferral button with a configurable max count.
# Deferral increments a counter in ENROLLINATOR_PERSIST_DIR and exits 0 so the
# LaunchDaemon/LaunchAgent can re-trigger on the next login.
# Calling convention: must be called after ui_require_dialog and before ui_start.
show_welcome_screen() {
    local cfg="$1"
    local enabled
    enabled="$(plist_bool "$cfg" ":WelcomeScreen:Enabled" false)"
    [ "$enabled" = "true" ] || return 0

    local title message button defer_button max_deferrals
    local width height logo title_fs msg_fs blur ontop
    title="$(plist_get         "$cfg" ":WelcomeScreen:Title")"
    message="$(plist_get       "$cfg" ":WelcomeScreen:Message")"
    button="$(plist_get        "$cfg" ":WelcomeScreen:Button")"
    defer_button="$(plist_get  "$cfg" ":WelcomeScreen:DeferButton")"
    max_deferrals="$(plist_get "$cfg" ":WelcomeScreen:MaxDeferrals")"
    width="$(plist_get         "$cfg" ":WelcomeScreen:Width")"
    height="$(plist_get        "$cfg" ":WelcomeScreen:Height")"
    logo="$(plist_get          "$cfg" ":WelcomeScreen:Logo")"
    title_fs="$(plist_get      "$cfg" ":WelcomeScreen:TitleFontSize")"
    msg_fs="$(plist_get        "$cfg" ":WelcomeScreen:MessageFontSize")"
    blur="$(plist_get          "$cfg" ":WelcomeScreen:Blur")"
    ontop="$(plist_get         "$cfg" ":WelcomeScreen:AlwaysOnTop")"

    # Fall back to branding values when WelcomeScreen-specific ones aren't set.
    [ -z "$title"  ] && title="$(plist_get "$cfg" ":Branding:Title")"
    [ -z "$title"  ] && title="Welcome"
    [ -z "$button" ] && button="Get Started"
    [ -z "$width"  ] && width=600
    [ -z "$height" ] && height=450
    [ -z "$logo"   ] && logo="$(plist_get "$cfg" ":Branding:Logo")"

    # Expand {token} placeholders (same substitution available in Branding fields).
    title="$(expand_title_vars "$title")"
    [ -n "$message" ] && message="$(expand_title_vars "$message")"

    # Build pipe-delimited slideshow strings (same format as action_dialog).
    local slideshow="" ss_titles="" ss_msgs="" video="" video_autoplay=""
    video="$(plist_get         "$cfg" ":WelcomeScreen:Video")"
    video_autoplay="$(plist_get "$cfg" ":WelcomeScreen:VideoAutoplay")"
    local ss_count j f_img f_title f_msg
    ss_count="$(plist_array_count "$cfg" ":WelcomeScreen:Slideshow")"
    for (( j=0; j<ss_count; j++ )); do
        f_img="$(plist_get "$cfg" ":WelcomeScreen:Slideshow:$j:Image")"
        if [ -n "$f_img" ]; then
            f_title="$(plist_get "$cfg" ":WelcomeScreen:Slideshow:$j:Title")"
            f_msg="$(plist_get   "$cfg" ":WelcomeScreen:Slideshow:$j:Message")"
        else
            f_img="$(plist_get "$cfg" ":WelcomeScreen:Slideshow:$j")"
            f_title=""
            f_msg=""
        fi
        [ -z "$f_img" ] && [ -z "$f_title" ] && [ -z "$f_msg" ] && continue
        slideshow="${slideshow:+${slideshow}|}${f_img}"
        ss_titles="${ss_titles:+${ss_titles}|}${f_title}"
        ss_msgs="${ss_msgs:+${ss_msgs}|}${f_msg}"
    done

    # Deferral tracking — count persists across LaunchDaemon restarts.
    local defer_count=0
    local defer_file="${ENROLLINATOR_PERSIST_DIR}/welcome_deferrals"
    if [ -f "$defer_file" ]; then
        defer_count="$(/bin/cat "$defer_file" 2>/dev/null)"
        [[ "$defer_count" =~ ^[0-9]+$ ]] || defer_count=0
    fi

    # Suppress defer button once the cap is reached.
    local btns="$button"
    if [ -n "$defer_button" ]; then
        local _show_defer=1
        if [[ "$max_deferrals" =~ ^[0-9]+$ ]] && [ "$defer_count" -ge "$max_deferrals" ]; then
            _show_defer=0
            log info "Welcome screen: max deferrals ($max_deferrals) reached — hiding defer button"
        fi
        [ "$_show_defer" -eq 1 ] && btns="${btns}|${defer_button}"
    fi

    # Apply per-welcome blur/ontop overrides, then restore.
    local _saved_blur="$ENROLLINATOR_UI_BLUR" _saved_ontop="$ENROLLINATOR_UI_ONTOP"
    [ "$blur"  = "true"  ] && ENROLLINATOR_UI_BLUR=1
    [ "$blur"  = "false" ] && ENROLLINATOR_UI_BLUR=0
    [ "$ontop" = "true"  ] && ENROLLINATOR_UI_ONTOP=1
    [ "$ontop" = "false" ] && ENROLLINATOR_UI_ONTOP=0
    export ENROLLINATOR_UI_BLUR ENROLLINATOR_UI_ONTOP

    # Manage the run-level blur keeper at the welcome boundary.  ui_dialog_popup
    # itself no longer auto-syncs (run_step does that for steps), so we sync
    # explicitly here based on the welcome's resolved blur intent.
    if [ "${ENROLLINATOR_UI_BLUR:-0}" = "1" ]; then
        ui_run_blur_keeper_start "$width" "$height"
    else
        ui_run_blur_keeper_stop
    fi

    local clicked rc
    # Pass the logo as the optional 13th argument (icon) to ui_dialog_popup.
    clicked="$(ui_dialog_popup "$title" "$message" "$width" "$height" "$btns" \
                "$title_fs" "$msg_fs" "$slideshow" "$video" "$ss_titles" "$ss_msgs" \
                "$video_autoplay" "$logo")"
    rc=$?

    ENROLLINATOR_UI_BLUR="$_saved_blur"; ENROLLINATOR_UI_ONTOP="$_saved_ontop"
    export ENROLLINATOR_UI_BLUR ENROLLINATOR_UI_ONTOP

    if [ $rc -ne 0 ]; then
        log warn "Welcome screen exited unexpectedly (rc=$rc) — proceeding with onboarding."
        return 0
    fi

    log info "Welcome screen: user clicked '$clicked'"

    # Playbook picker — shown after "Get Started", not after a deferral.
    local _pp_defer=0
    [ -n "$defer_button" ] && [ "$clicked" = "$defer_button" ] && _pp_defer=1
    if [ "$_pp_defer" -eq 0 ] \
       && [ "$(plist_bool "$cfg" ":WelcomeScreen:PlaybookPicker:Enabled" false)" = "true" ]; then
        local pp_count pp_k pp_name pp_values="" pp_first="" pp_title pp_msg pp_icon pp_hideicon pp_json pp_selected
        pp_count="$(plist_array_count "$cfg" ":WelcomeScreen:PlaybookPicker:Playbooks")"
        if [ "$pp_count" -gt 0 ]; then
            for (( pp_k=0; pp_k<pp_count; pp_k++ )); do
                pp_name="$(plist_get "$cfg" ":WelcomeScreen:PlaybookPicker:Playbooks:$pp_k")"
                # Skip blank/whitespace-only entries — can't select an unnamed playbook.
                [ -z "${pp_name// /}" ] && continue
                [ -z "$pp_first" ] && pp_first="$pp_name"
                pp_values="${pp_values:+${pp_values},}${pp_name}"
            done
            if [ -n "$pp_values" ]; then
                pp_title="$(plist_get "$cfg" ":WelcomeScreen:PlaybookPicker:Title")"
                [ -z "$pp_title" ] && pp_title="Choose your setup"
                pp_msg="$(plist_get "$cfg" ":WelcomeScreen:PlaybookPicker:Message")"
                [ -z "$pp_msg" ] && pp_msg="Select the configuration that applies to you."
                pp_icon="$(plist_get      "$cfg" ":WelcomeScreen:PlaybookPicker:Icon")"
                pp_hideicon="$(plist_bool "$cfg" ":WelcomeScreen:PlaybookPicker:HideIcon" false)"
                local pp_width pp_height
                pp_width="$(plist_get  "$cfg" ":WelcomeScreen:PlaybookPicker:Width")"
                pp_height="$(plist_get "$cfg" ":WelcomeScreen:PlaybookPicker:Height")"
                [ -z "$pp_width"  ] && pp_width=520
                [ -z "$pp_height" ] && pp_height=300
                local _pp_args=(
                    --title   "$pp_title"
                    --message "$pp_msg"
                    --selecttitle "Playbook"
                    --selectvalues "$pp_values"
                    --selectdefault "$pp_first"
                    --button1text "Continue"
                    --width  "$pp_width"
                    --height "$pp_height"
                    --position center
                    --moveable
                    --json
                )
                if [ "$pp_hideicon" = "true" ]; then
                    _pp_args+=( --hideicon )
                elif [ -n "$pp_icon" ]; then
                    _pp_args+=( --icon "$pp_icon" )
                fi
                [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && _pp_args+=( --ontop )
                [ -n "${ENROLLINATOR_UI_QUIT_KEY:-}" ]  && _pp_args+=( --quitkey "${ENROLLINATOR_UI_QUIT_KEY}" )
                # Explicit scratch commandfile — an implicit default binding
                # would truncate swiftDialog's shared default path at launch.
                local _pp_scratch
                _pp_scratch="$(_ui_mktemp_cmdfile)"
                _pp_args+=( --commandfile "$_pp_scratch" )
                local _pp_rc
                pp_json="$(_ui_user_exec "$DIALOG_BIN" "${_pp_args[@]}" 2>/dev/null)"
                # Capture BEFORE the rm — `$?` after it reads the rm's status,
                # which is ~always 0, so the dialog's exit code was discarded.
                _pp_rc=$?
                /bin/rm -f "$_pp_scratch"
                if [ "$_pp_rc" -eq 0 ] && [ -n "$pp_json" ]; then
                    # plutil, not python3: /usr/bin/python3 is a stub that
                    # triggers the Xcode CLT installer when the tools aren't
                    # present, which is the normal state of a freshly enrolled
                    # Mac. See the matching note in ui_addon_picker.
                    local _pp_plist
                    _pp_plist="$(/usr/bin/mktemp -t enrollinator-picker-json)"
                    if printf '%s' "$pp_json" | /usr/bin/plutil -convert xml1 -o "$_pp_plist" - 2>/dev/null; then
                        # swiftDialog returns a --selectvalues result as a
                        # NESTED DICT, not a string:
                        #   {"Playbook": {"selectedValue": "…", "selectedIndex": 0}}
                        # Reading :Playbook therefore yielded PlistBuddy's
                        # textual rendering — literally "Dict {\n selectedIndex
                        # = 0\n selectedValue = Standard\n}" — which was then
                        # searched for as a playbook name, never matched, and
                        # logged as 'not found — using default'. The picker
                        # silently did nothing at all.
                        pp_selected="$(plist_get "$_pp_plist" ":Playbook:selectedValue")"
                        if [ -z "$pp_selected" ]; then
                            # Older swiftDialog returned a bare string here.
                            pp_selected="$(plist_get "$_pp_plist" ":Playbook")"
                            # Never accept a structure rendering as a name.
                            case "$pp_selected" in
                                "Dict {"*|"Array {"*) pp_selected="" ;;
                            esac
                        fi
                        # Defensive: a name is a single line.
                        pp_selected="${pp_selected%%$'\n'*}"
                    else
                        log warn "Playbook picker: could not parse swiftDialog JSON output"
                        pp_selected=""
                    fi
                    /bin/rm -f "$_pp_plist"
                    if [ -n "$pp_selected" ]; then
                        ENROLLINATOR_PICKER_PROFILE="$pp_selected"
                        export ENROLLINATOR_PICKER_PROFILE
                        log info "Playbook picker: user selected '$pp_selected'"
                    fi
                fi
            fi
        fi
    fi

    # Handle deferral.
    if [ -n "$defer_button" ] && [ "$clicked" = "$defer_button" ]; then
        local new_count=$(( defer_count + 1 ))
        printf '%s\n' "$new_count" > "$defer_file" 2>/dev/null || true
        log info "Onboarding deferred (${new_count}/${max_deferrals:-∞})"
        # The welcome screen may have started the run-level blur keeper —
        # this exit never reaches the main EXIT trap, so stop it here or the
        # screen stays blurred after the window closes.
        ui_run_blur_keeper_stop
        exit 0
    fi

    return 0
}

# ----------------------------------------------------------------------------
# swiftDialog auto-install
# ----------------------------------------------------------------------------

# ensure_swiftdialog <config_plist>
# If $DIALOG_BIN is already executable, returns immediately (nothing to do).
# Otherwise: shows an osascript "please wait" popup to the console user,
# downloads the latest swiftDialog release from GitHub, installs it, then
# dismisses the popup.
ensure_swiftdialog() {
    local cfg_path="${1:-}"
    [ -x "$DIALOG_BIN" ] && return 0

    log info "swiftDialog not found at $DIALOG_BIN — installing latest release…"

    # Show a non-blocking osascript popup while we work.  'giving up after'
    # acts as a safety net so it never hangs permanently.
    #
    # The trailing `-e` is an AppleScript comment carrying a unique marker.
    # It exists purely so _dismiss_osa can find the real osascript process:
    # $! is the launchctl wrapper, and killing that leaves the actual dialog
    # sitting on the user's screen for the full 'giving up after' window.
    local _osa_pid="" _osa_uid=""
    local _osa_marker="enrollinator-swiftdialog-install-notice"
    if [ -n "${ENROLLINATOR_CONSOLE_USER:-}" ] && [ "$ENROLLINATOR_CONSOLE_USER" != "root" ]; then
        _osa_uid="$(/usr/bin/id -u "$ENROLLINATOR_CONSOLE_USER" 2>/dev/null)"
        if [ -n "$_osa_uid" ]; then
            /bin/launchctl asuser "$_osa_uid" /usr/bin/osascript \
                -e 'display dialog "Your new computer setup will start in a moment — please wait while a few required components are installed." buttons {"OK"} giving up after 300 with title "Getting Ready…" with icon note' \
                -e "-- $_osa_marker" \
                >/dev/null 2>&1 &
            _osa_pid=$!
        fi
    fi

    local _dismiss_osa
    _dismiss_osa() {
        [ -n "$_osa_pid" ] && /bin/kill "$_osa_pid" 2>/dev/null
        wait "$_osa_pid" 2>/dev/null
        # Now the process that actually owns the window. Scoped to the console
        # user and matched on our marker, so it can't hit anything else.
        [ -n "$_osa_uid" ] && /usr/bin/pkill -u "$_osa_uid" -f "$_osa_marker" 2>/dev/null
        return 0
    }

    # Fetch the latest pkg URL from the GitHub releases API.
    local pkg_url
    pkg_url="$(/usr/bin/curl -fsSL \
        "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest" \
        | /usr/bin/grep '"browser_download_url"' \
        | /usr/bin/grep '\.pkg"' \
        | /usr/bin/head -1 \
        | /usr/bin/awk -F'"' '{print $4}')"

    if [ -z "$pkg_url" ]; then
        log warn "Could not determine latest swiftDialog download URL — skipping install."
        _dismiss_osa
        return 1
    fi

    log info "Downloading swiftDialog from: $pkg_url"
    local tmp_pkg
    # No extension appended — installer identifies pkg format from content.
    tmp_pkg="$(/usr/bin/mktemp -t swiftdialog)"

    if ! /usr/bin/curl -fsSL -o "$tmp_pkg" "$pkg_url"; then
        log warn "Failed to download swiftDialog pkg."
        /bin/rm -f "$tmp_pkg"
        _dismiss_osa
        return 1
    fi

    # Verify the package before installing it as root.
    #
    # "Status: signed by" alone is NOT a supply-chain control: it is satisfied
    # by ANY valid Developer ID, including one an attacker holds. Since we
    # install this as root, pin the signer to swiftDialog's own team as well.
    # PWA5E9TQ59 is CSIRO, who publish swiftDialog; override with
    # SwiftDialogTeamID in the config if you mirror your own rebuilt package.
    local sig_check team_id
    team_id="$(plist_get "$cfg_path" ":SwiftDialogTeamID")"
    team_id="${team_id:-PWA5E9TQ59}"
    sig_check="$(/usr/sbin/pkgutil --check-signature "$tmp_pkg" 2>&1)"
    if ! printf '%s\n' "$sig_check" | /usr/bin/grep -q "Status: signed by"; then
        log warn "swiftDialog pkg failed signature check — aborting install."
        log warn "pkgutil output: $sig_check"
        /bin/rm -f "$tmp_pkg"
        _dismiss_osa
        return 1
    fi
    if ! printf '%s\n' "$sig_check" | /usr/bin/grep -qF "($team_id)"; then
        log warn "swiftDialog pkg is signed, but not by the expected team ($team_id) — aborting install."
        log warn "pkgutil output: $sig_check"
        /bin/rm -f "$tmp_pkg"
        _dismiss_osa
        return 1
    fi
    log info "swiftDialog pkg signature OK (team $team_id): $(printf '%s\n' "$sig_check" | /usr/bin/grep 'Developer ID' | /usr/bin/head -1 | /usr/bin/xargs)"

    log info "Installing swiftDialog…"
    /usr/sbin/installer -pkg "$tmp_pkg" -target / >/dev/null 2>&1
    local rc=$?
    /bin/rm -f "$tmp_pkg"

    if [ $rc -eq 0 ]; then
        log info "swiftDialog installed successfully."
    else
        log warn "swiftDialog installer exited $rc."
    fi

    _dismiss_osa
    return $rc
}

# ----------------------------------------------------------------------------
# Addon profiles — shown to the user after the main profile finishes.
# ----------------------------------------------------------------------------

# run_addon_profiles cfg ran_ids_file list_item_base ran_idx
#   cfg            — path to the plist config
#   ran_ids_file   — file of step IDs already executed (one per line)
#   list_item_base — number of list items already in the swiftDialog window
#   ran_idx        — index of the playbook that just ran, never re-offered
run_addon_profiles() {
    local cfg="$1" ran_ids_file="$2" list_item_base="$3" ran_idx="${4:-}"

    # Collect addon profiles.
    local prof_count i pname
    prof_count="$(plist_array_count "$cfg" ":Playbooks")"
    local addon_names=() addon_idxs=()
    local addon_descs=()
    for (( i=0; i<prof_count; i++ )); do
        # Never offer the playbook that just ran. Selection matches on name
        # alone — neither DefaultPlaybook, --profile, nor the welcome-screen
        # picker consults Addon — so a playbook marked as an add-on can also be
        # the one chosen to run. Offering it again is an option that does
        # nothing: every step it owns is already in ran_ids_file and would be
        # deduplicated away one by one.
        if [ -n "$ran_idx" ] && [ "$i" -eq "$ran_idx" ]; then
            if [ "$(plist_bool "$cfg" ":Playbooks:$i:Addon" false)" = "true" ]; then
                log info "Add-on picker: '$(plist_get "$cfg" ":Playbooks:$i:Name")' already ran as the main playbook — not offering it again."
            fi
            continue
        fi
        if [ "$(plist_bool "$cfg" ":Playbooks:$i:Addon" false)" = "true" ]; then
            pname="$(plist_get "$cfg" ":Playbooks:$i:Name")"
            addon_names+=("$pname")
            addon_descs+=("$(plist_get "$cfg" ":Playbooks:$i:Description")")
            addon_idxs+=("$i")
        fi
    done
    [ "${#addon_names[@]}" -eq 0 ] && return 0

    # Read AddonPicker customisations from the mobileconfig (all optional).
    local ap_title ap_message ap_install ap_skip ap_width ap_height
    ap_title="$(plist_get "$cfg"         ":AddonPicker:Title")"
    ap_message="$(plist_get "$cfg"       ":AddonPicker:Message")"
    ap_icon="$(plist_get "$cfg"          ":AddonPicker:Icon")"
    ap_title_fs="$(plist_get "$cfg"      ":AddonPicker:TitleFontSize")"
    ap_msg_fs="$(plist_get "$cfg"        ":AddonPicker:MessageFontSize")"
    ap_install="$(plist_get "$cfg"       ":AddonPicker:InstallButton")"
    ap_skip="$(plist_get "$cfg"          ":AddonPicker:SkipButton")"
    ap_width="$(plist_get "$cfg"         ":AddonPicker:Width")"
    ap_height="$(plist_get "$cfg"        ":AddonPicker:Height")"

    # Build the picker message: short intro + one bullet per addon with its description.
    local default_msg="Select additional profiles to install."
    local picker_msg="${ap_message:-$default_msg}"
    for (( i=0; i<${#addon_names[@]}; i++ )); do
        if [ -n "${addon_descs[$i]}" ]; then
            picker_msg="${picker_msg}\n- **${addon_names[$i]}** — ${addon_descs[$i]}"
        fi
    done

    # Build interleaved name/description args for ui_addon_picker.
    local picker_args=()
    for (( i=0; i<${#addon_names[@]}; i++ )); do
        picker_args+=("${addon_names[$i]}" "${addon_descs[$i]}")
    done

    # Let the user pick.
    ui_set_banner "Base install complete. Choose optional add-ons below."
    local selected_raw
    ENROLLINATOR_ADDON_TITLE="${ap_title}"               \
    ENROLLINATOR_ADDON_MESSAGE="${picker_msg}"           \
    ENROLLINATOR_ADDON_ICON="${ap_icon}"                 \
    ENROLLINATOR_ADDON_TITLE_FONTSIZE="${ap_title_fs}"  \
    ENROLLINATOR_ADDON_MSG_FONTSIZE="${ap_msg_fs}"       \
    ENROLLINATOR_ADDON_INSTALL_BTN="${ap_install}"       \
    ENROLLINATOR_ADDON_SKIP_BTN="${ap_skip}"             \
    ENROLLINATOR_ADDON_WIDTH="${ap_width}"               \
    ENROLLINATOR_ADDON_HEIGHT="${ap_height}"             \
    selected_raw="$(ui_addon_picker "${picker_args[@]}")" || {
        log info "User skipped addon picker."
        return 0
    }
    [ -z "$selected_raw" ] && { log info "No addons selected."; return 0; }

    # Build a list of (pkey, step_index, test_mode) for unique steps, and
    # append them to the running swiftDialog window.
    # test_mode per step: inherits the addon profile's own TestMode flag (or the
    # already-exported ENROLLINATOR_TEST_MODE if the global/main-profile flag set it).
    local -a addon_run_pkeys=() addon_run_idxs=() addon_run_test=()
    local sel_name apkey acount j sid sname sicon addon_test
    while IFS= read -r sel_name; do
        [ -z "$sel_name" ] && continue
        # Map name → index.
        for (( i=0; i<${#addon_names[@]}; i++ )); do
            [ "${addon_names[$i]}" != "$sel_name" ] && continue
            apkey=":Playbooks:${addon_idxs[$i]}"
            # Effective test mode for this addon: global env already set to 1 if
            # --test / top-level TestMode / main-profile TestMode applied.
            # Also honour the addon profile's own TestMode key.
            addon_test="$ENROLLINATOR_TEST_MODE"
            if [ "$addon_test" != "1" ] && \
               [ "$(plist_bool "$cfg" "$apkey:TestMode" false)" = "true" ]; then
                addon_test="1"
            fi
            acount="$(plist_array_count "$cfg" "$apkey:Steps")"
            for (( j=0; j<acount; j++ )); do
                sid="$(plist_get "$cfg" "$apkey:Steps:$j:Id")"
                [ -z "$sid" ] && sid="addon-${addon_idxs[$i]}-step-$j"
                # Skip if this step ID already ran.
                if grep -qxF "$sid" "$ran_ids_file" 2>/dev/null; then
                    log info "Addon step '$sid' already ran — skipping."
                    continue
                fi
                sname="$(plist_get "$cfg" "$apkey:Steps:$j:Name")"
                sicon="$(plist_get "$cfg" "$apkey:Steps:$j:Icon")"
                [ -z "$sname" ] && sname="$sid"
                ui_append_step "$sname" "$sicon"
                addon_run_pkeys+=("$apkey")
                addon_run_idxs+=("$j")
                addon_run_test+=("$addon_test")
            done
            break
        done
    done <<< "$selected_raw"

    local total_addon="${#addon_run_pkeys[@]}"
    if [ "$total_addon" -eq 0 ]; then
        ui_set_banner "All selected add-on steps were already completed."
        return 0
    fi

    ui_set_progress 0 "Running add-ons…"
    # Per-addon test mode is applied around each step and restored afterwards.
    # Leaving it set leaked a TestMode add-on's flag into the caller, where the
    # end-of-run check reads it and skips the completion flag for the WHOLE
    # run — so a real onboarding that happened to end with a test add-on would
    # replay from scratch at the next login.
    local _saved_test_mode="$ENROLLINATOR_TEST_MODE"
    local ui_idx rc addon_fail=0
    for (( i=0; i<total_addon; i++ )); do
        ui_idx=$(( list_item_base + i ))
        ui_set_progress $(( (i * 100) / total_addon )) "Add-on step $((i+1)) of $total_addon"
        # Apply per-addon test mode for this step's action/condition handlers.
        ENROLLINATOR_TEST_MODE="${addon_run_test[$i]}"
        export ENROLLINATOR_TEST_MODE
        run_step "$cfg" "${addon_run_pkeys[$i]}" "${addon_run_idxs[$i]}" "$ui_idx"
        rc=$?
        [ $rc -ne 0 ] && addon_fail=1
        # Record this step as done so future addons in the same session can dedup.
        local done_id
        done_id="$(plist_get "$cfg" "${addon_run_pkeys[$i]}:Steps:${addon_run_idxs[$i]}:Id")"
        [ -z "$done_id" ] && done_id="addon-step-$i"
        printf '%s\n' "$done_id" >> "$ran_ids_file"
    done
    ENROLLINATOR_TEST_MODE="$_saved_test_mode"
    export ENROLLINATOR_TEST_MODE
    ui_set_progress 100 "Add-ons complete"
    # Report failure to the caller. This used to be a `local any_fail` that
    # shadowed main's, so add-on failures were invisible to the completion gate.
    return $addon_fail
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
    # Parse args first — it resolves relative --config/--xml paths against
    # the caller's CWD, which the cd below would destroy.
    parse_args "$@"
    # Guarantee a stable CWD so launchctl asuser never inherits a path that
    # root can't resolve (e.g. a user's Downloads, a deleted temp dir).
    cd / || true
    require_root
    init_logging
    log info "Enrollinator starting (root=$ENROLLINATOR_ROOT domain=$ENROLLINATOR_DOMAIN pid=$$)"

    # Echo the invocation verbatim, then the flags as parse_args resolved them.
    #
    # Without this, "my --xml was ignored" cannot be told apart from "--xml
    # never arrived": both produce a run with empty CLI_XML, and the only
    # other evidence is a temp path that looks identical whatever the source.
    # The two have completely different causes — one is a precedence bug in
    # here, the other is a caller (LaunchDaemon ProgramArguments, a wrapper
    # script, an MDM policy) dropping the arguments before this process sees
    # them — so the log has to distinguish them on the first run.
    log info "Invoked as: $0 ${*:-<no arguments>}"
    log info "Resolved flags: xml='${CLI_XML}' config='${CLI_CONFIG}' profile='${CLI_PROFILE}' domain='${ENROLLINATOR_DOMAIN}' force=${CLI_FORCE} dry_run=${CLI_DRY_RUN} test=${CLI_TEST}${CLI_IGNORED_ARGS:+ ignored_positional='$CLI_IGNORED_ARGS'}"

    # Warn when another instance is already live.
    #
    # There is no lock, and every root instance derives the same swiftDialog
    # command and PID files from ENROLLINATOR_STATE_DIR (lib/ui.sh). So a
    # hand-run `enrollinator.sh --xml test.plist` started while the daemon's
    # own flagless run is up does not get its own window — the two fight over
    # one, and the window already on screen belongs to the daemon, driven by
    # whatever config IT resolved (the installed profile). The flags were
    # honoured; the run they configured is not the run being displayed.
    #
    # Warn rather than lock: a lock would change daemon behaviour, and a false
    # positive must never stop a real enrollment from running.
    # Filter by process GROUP, not just pid. Every command substitution in
    # this script forks a subshell that inherits our command line, so matching
    # on the name alone makes a lone run report itself. Our own subshells and
    # children share our pgid; a separate invocation does not.
    _pgid="$(/bin/ps -o pgid= -p $$ 2>/dev/null | /usr/bin/tr -d ' ')"
    _other=""
    for _p in $(/usr/bin/pgrep -f '[e]nrollinator\.sh' 2>/dev/null); do
        [ "$_p" = "$$" ] && continue
        [ "$(/bin/ps -o pgid= -p "$_p" 2>/dev/null | /usr/bin/tr -d ' ')" = "$_pgid" ] && continue
        _other="${_other:+$_other }$_p"
    done
    if [ -n "$_other" ]; then
        log warn "Another Enrollinator process is already running (pid(s): $_other). Instances share $ENROLLINATOR_STATE_DIR and one swiftDialog window, so the window on screen may belong to that run and reflect ITS config, not this one's. If that is the LaunchDaemon, stop it first: launchctl bootout system/com.enrollinator.app"
    fi
    unset _other _pgid _p

    # Fatal if this fails. lib/ui.sh derived every command-file and PID-file
    # path from ENROLLINATOR_STATE_DIR at source time, so there is nowhere
    # else to put them — continuing would run the whole playbook with a UI
    # that can never receive a command. Exiting leaves the completion flag
    # unwritten, so the run is retried on the next boot.
    if ! ensure_state_dir; then
        log error "Cannot establish a usable state directory ($ENROLLINATOR_STATE_DIR); aborting. Inspect that path — Enrollinator will not remove or replace it."
        exit 1
    fi
    /bin/mkdir -p "$ENROLLINATOR_PERSIST_DIR" 2>/dev/null

    # Take the single-instance lock before anything that writes shared state.
    # --dry-run is exempt: it draws nothing, writes no state, and inspecting a
    # config while the daemon is mid-run is exactly when you want to.
    if [ "$CLI_DRY_RUN" -eq 0 ]; then
        if ! acquire_run_lock; then
            local _holder
            _holder="$(/bin/cat "${ENROLLINATOR_LOCK_DIR}/pid" 2>/dev/null)"
            if [ -n "$CLI_XML" ] || [ -n "$CLI_CONFIG" ] || [ -n "$CLI_PROFILE" ]; then
                # Name the trap precisely. Starting anyway would parse the
                # flags correctly and then fight the running instance for one
                # dialog command file, which reads as "my flags were ignored
                # and it used the profile".
                log error "Another Enrollinator run (pid ${_holder:-unknown}) is already in progress and owns the setup window. It was started without config flags — under the LaunchDaemon that means it is running the MANAGED PROFILE's config, not the ${CLI_XML:+--xml }${CLI_CONFIG:+--config }${CLI_PROFILE:+--profile }you just passed. Refusing to start a second instance. To test your config instead: sudo /bin/launchctl bootout system/com.enrollinator.app, then re-run this command with --force."
            else
                log error "Another Enrollinator run (pid ${_holder:-unknown}) is already in progress; refusing to start a second instance."
            fi
            exit 1
        fi
        trap 'release_run_lock' EXIT
    fi

    # Already-completed gate. --force re-runs. Dry-run and explicit test-mode
    # bypass the gate too — those are developer workflows.
    if [ -f "$ENROLLINATOR_COMPLETED_FLAG" ] \
        && [ "$CLI_FORCE" -eq 0 ] \
        && [ "$CLI_DRY_RUN" -eq 0 ] \
        && [ "$CLI_TEST" -eq 0 ]; then
        # Flags that name a config or playbook are a strong signal that
        # someone is at a keyboard trying to test a change. Skipping the run
        # makes those flags do nothing, and at info level that message is not
        # echoed to a non-tty caller at all — so over SSH or from a script the
        # command produced no output and exit 0, which reads as "--xml was
        # ignored" rather than "the whole run was skipped". Warn instead, and
        # name the flags that had no effect.
        if [ -n "$CLI_XML" ] || [ -n "$CLI_CONFIG" ] || [ -n "$CLI_PROFILE" ]; then
            log warn "Completion flag present ($ENROLLINATOR_COMPLETED_FLAG); skipping this run — so ${CLI_XML:+--xml }${CLI_CONFIG:+--config }${CLI_PROFILE:+--profile }had no effect. This machine has already been onboarded. Re-run with --force to use the config you passed, or --dry-run to inspect it without running."
        else
            log info "Completion flag present ($ENROLLINATOR_COMPLETED_FLAG); skipping. Use --force to re-run."
        fi
        exit 0
    fi

    # Resolve the console user. How long we're willing to wait depends on who
    # started us, because "wait forever" is right for exactly one caller.
    if [ -t 1 ]; then
        # A human at a terminal. Nothing to wait for.
        ENROLLINATOR_CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null)"
    elif [ "$PPID" -eq 1 ]; then
        # Parented by launchd: this is the LaunchDaemon. Nothing upstream is
        # blocked on us, so wait as long as it takes. Under PreStage this
        # process is bootstrapped mid-Setup-Assistant and its whole job is to
        # carry the run across to the desktop session.
        wait_for_console_user 0
        log info "Console user: $ENROLLINATOR_CONSOLE_USER"
        wait_for_session_ready 60
    else
        # Non-interactive, but not the daemon — a Jamf script policy, an SSH
        # session, CI. Something upstream is holding a connection open on us,
        # so blocking indefinitely would wedge it (a Jamf policy would sit
        # open and stall the queue behind it). Wait a bounded while, then fail
        # loudly. Failing is the point: the old behaviour was to continue and
        # run every step with nowhere to draw, which installed software
        # invisibly and left the user with no onboarding.
        if wait_for_console_user 300; then
            log info "Console user: $ENROLLINATOR_CONSOLE_USER"
            wait_for_session_ready 60
        else
            log error "No console user after 5min, and not running under launchd. There is no GUI session to place the setup window in, so this run would be invisible — refusing to continue. Deploy via the LaunchDaemon (which waits indefinitely for the desktop session), or invoke this once a user is logged in."
            exit 5
        fi
    fi
    export ENROLLINATOR_CONSOLE_USER

    # NOT `local` — see cleanup_temp_files. Same for steps_file, ran_ids_file
    # and id_map_file below.
    #
    # load_config runs in THIS shell, not a subshell, so it can publish both
    # the config path and the config source. A fatal error inside it exits the
    # script directly, which is what we want — the old `cfg="$(load_config)"`
    # form needed `|| exit $?` precisely because the exit only killed the
    # subshell, leaving the caller to limp on with an empty value and
    # misreport the failure as a benign no-op ("Profile '' has no steps").
    load_config
    cfg="$ENROLLINATOR_CFG_PATH"
    if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then
        log error "Config could not be resolved. Config source: ${ENROLLINATOR_CONFIG_SOURCE:-unknown}"
        exit 2
    fi
    ENROLLINATOR_TMP_CFG="$cfg"
    # Install file cleanup as soon as there's something to clean. Every exit
    # from here on is covered, including the welcome-screen deferral. The trap
    # is upgraded to also tear down the UI once ui_start has run.
    trap 'cleanup_temp_files' EXIT
    log info "Config loaded: $cfg"

    # Pick profile.
    local pidx pname pkey
    pidx="$(pick_profile "$cfg" "$CLI_PROFILE")" || exit $?
    pkey=":Playbooks:$pidx"
    pname="$(plist_get "$cfg" "$pkey:Name")"
    log info "Selected profile: $pname (index $pidx)"

    # Resolve test mode. Precedence: --test > top-level TestMode > profile TestMode.
    local test_mode="false"
    if [ "$CLI_TEST" -eq 1 ]; then
        test_mode="true"
    elif [ "$(plist_bool "$cfg" ":TestMode" false)" = "true" ]; then
        test_mode="true"
    elif [ "$(plist_bool "$cfg" "$pkey:TestMode" false)" = "true" ]; then
        test_mode="true"
    fi
    if [ "$test_mode" = "true" ]; then
        ENROLLINATOR_TEST_MODE=1
        log info "TEST MODE enabled — actions will be simulated."
    else
        ENROLLINATOR_TEST_MODE=0
    fi
    export ENROLLINATOR_TEST_MODE

    if [ "$CLI_DRY_RUN" -eq 1 ]; then
        dry_run_plan "$cfg" "$pkey" "$pname"
        /bin/rm -f "$cfg"
        exit 0
    fi

    # Build step manifest for the UI.
    steps_file="$(build_steps_manifest "$cfg" "$pkey")"
    ENROLLINATOR_TMP_STEPS="$steps_file"
    local total
    total="$(plist_array_count "$cfg" "$pkey:Steps")"
    if [ "$total" -eq 0 ]; then
        log warn "Profile '$pname' has no steps; nothing to do."
        /bin/rm -f "$cfg" "$steps_file"
        exit 0
    fi

    # Branding.
    local title subtitle accent logo banner
    title="$(plist_get "$cfg" ":Branding:Title")"
    subtitle="$(plist_get "$cfg" ":Branding:Subtitle")"
    accent="$(plist_get "$cfg" ":Branding:AccentColor")"
    logo="$(plist_get   "$cfg" ":Branding:Logo")"
    banner="$(plist_get "$cfg" ":Branding:Banner")"
    local title_fontsize msg_fontsize
    title_fontsize="$(plist_get "$cfg" ":Branding:TitleFontSize")"
    msg_fontsize="$(plist_get   "$cfg" ":Branding:MessageFontSize")"
    [ -z "$title" ] && title="Setting up your Mac"
    [ -z "$subtitle" ] && subtitle="Please keep this window open."
    title="$(expand_title_vars "$title")"
    subtitle="$(expand_title_vars "$subtitle")"
    if [ "$ENROLLINATOR_TEST_MODE" = "1" ]; then
        title="[TEST MODE] $title"
    fi

    # Window sizing. Passed to ui.sh via env so we don't balloon ui_start's
    # positional argument list.
    local w h
    w="$(plist_get "$cfg" ":Branding:WindowWidth")"
    h="$(plist_get "$cfg" ":Branding:WindowHeight")"
    [ -n "$w" ] && ENROLLINATOR_UI_WIDTH="$w"
    [ -n "$h" ] && ENROLLINATOR_UI_HEIGHT="$h"
    [ -n "$banner" ] && ENROLLINATOR_UI_BANNER="$banner"
    [ -n "$title_fontsize" ] && ENROLLINATOR_UI_TITLE_FONTSIZE="$title_fontsize"
    [ -n "$msg_fontsize" ]   && ENROLLINATOR_UI_MSG_FONTSIZE="$msg_fontsize"
    ENROLLINATOR_UI_INFOBOX="$(build_hw_infobox "$cfg")"
    ENROLLINATOR_UI_HELPMESSAGE="$(build_help_message "$cfg")"
    local quit_key
    quit_key="$(plist_get "$cfg" ":Branding:QuitKey")"
    ENROLLINATOR_UI_QUIT_KEY="${quit_key:-}"
    export ENROLLINATOR_UI_WIDTH ENROLLINATOR_UI_HEIGHT ENROLLINATOR_UI_BANNER \
           ENROLLINATOR_UI_TITLE_FONTSIZE ENROLLINATOR_UI_MSG_FONTSIZE \
           ENROLLINATOR_UI_INFOBOX ENROLLINATOR_UI_HELPMESSAGE \
           ENROLLINATOR_UI_QUIT_KEY

    local ui_blur ui_ontop
    ui_blur="$(plist_bool "$cfg" ":BlurScreen" false)"
    ui_ontop="$(plist_bool "$cfg" ":AlwaysOnTop" true)"
    ENROLLINATOR_UI_BLUR="$([ "$ui_blur"  = "true" ] && echo 1 || echo 0)"
    ENROLLINATOR_UI_ONTOP="$([ "$ui_ontop" = "true" ] && echo 1 || echo 0)"
    export ENROLLINATOR_UI_BLUR ENROLLINATOR_UI_ONTOP

    # Auto-install swiftDialog if the config requests it.
    if [ "$(plist_bool "$cfg" ":InstallSwiftDialog" false)" = "true" ]; then
        ensure_swiftdialog "$cfg" || true   # non-fatal — ui_require_dialog will catch a missing binary
    fi

    ui_require_dialog
    show_welcome_screen "$cfg"

    # If the welcome screen's playbook picker returned a selection, re-pick.
    if [ -n "${ENROLLINATOR_PICKER_PROFILE:-}" ]; then
        local _pp_idx
        _pp_idx="$(find_profile_by_name "$cfg" "$ENROLLINATOR_PICKER_PROFILE" 2>/dev/null)"
        if [ -n "$_pp_idx" ]; then
            pidx="$_pp_idx"
            pkey=":Playbooks:$pidx"
            pname="$(plist_get "$cfg" "$pkey:Name")"
            log info "Playbook picker override applied: '$pname' (index $pidx)"
            /bin/rm -f "$steps_file"
            steps_file="$(build_steps_manifest "$cfg" "$pkey")"
            ENROLLINATOR_TMP_STEPS="$steps_file"
            total="$(plist_array_count "$cfg" "$pkey:Steps")"
            if [ "$total" -eq 0 ]; then
                log warn "Picker-selected profile '$pname' has no steps; nothing to do."
                /bin/rm -f "$cfg" "$steps_file"
                exit 0
            fi
        else
            log warn "Playbook picker selection '$ENROLLINATOR_PICKER_PROFILE' not found — using default."
        fi
        unset ENROLLINATOR_PICKER_PROFILE
    fi

    # Sync the run-level blur keeper to the FIRST step's blur intent before
    # the main window opens. ui_start can hold for several seconds waiting
    # for window readiness; without this, a keeper started by a blurred
    # welcome screen stays up through that whole hold and the screen
    # remains blurred long after the welcome closed. run_step re-syncs at
    # every step boundary, so this only covers the welcome→step-0 gap.
    local _first_blur="${ENROLLINATOR_UI_BLUR:-0}"
    [ "$(plist_get "$cfg" "$pkey:Steps:0:WaitWindow:Blur")" = "true" ] && _first_blur=1
    [ "$(plist_get "$cfg" "$pkey:Steps:0:Action:Blur")"     = "true" ] && _first_blur=1
    if [ "$_first_blur" = "1" ]; then
        ui_run_blur_keeper_start
    else
        ui_run_blur_keeper_stop
    fi

    ui_start "$title" "$subtitle" "$accent" "$logo" "$steps_file"
    ran_ids_file="$(/usr/bin/mktemp -t enrollinator-ran-ids)"
    id_map_file="$(/usr/bin/mktemp -t enrollinator-id-map)"
    ENROLLINATOR_TMP_RAN_IDS="$ran_ids_file"
    ENROLLINATOR_TMP_ID_MAP="$id_map_file"
    trap 'ui_stop; cleanup_temp_files' EXIT

    # Build a step-ID → index map for branch resolution.
    # Uses a tab-delimited temp file instead of a bash 4+ associative array so
    # the script stays compatible with the bash 3.2 that ships with macOS.
    local _k _sid
    for (( _k=0; _k<total; _k++ )); do
        _sid="$(plist_get "$cfg" "$pkey:Steps:$_k:Id")"
        [ -z "$_sid" ] && _sid="step-$_k"
        printf '%s\t%d\n' "$_sid" "$_k" >> "$id_map_file"
    done

    # Execute steps — state-machine style so OnSuccess/OnFailure can branch.
    # Cycle guard: abort if we've executed more than total*2 steps (catches
    # infinite loops caused by a branch that points back to itself).
    # _visited_idx is a plain indexed array (bash 3.2 compatible).
    local -a _visited_idx
    local i=0 rc any_fail=0 step_id steps_done=0 max_iters=$(( total * 2 + total ))
    while (( i < total && steps_done < max_iters )); do
        # Replay cached statuses first — heals any updates swiftDialog's
        # watcher missed during its startup window (fast first-step clicks).
        ui_reassert_state
        ui_set_progress $(( (steps_done * 100) / total )) "Step $((steps_done+1)) of $total"
        _visited_idx[$i]=1
        run_step "$cfg" "$pkey" "$i" "$i"
        rc=$?; [ $rc -ne 0 ] && any_fail=1
        steps_done=$(( steps_done + 1 ))

        step_id="$(plist_get "$cfg" "$pkey:Steps:$i:Id")"
        [ -z "$step_id" ] && step_id="step-$i"
        printf '%s\n' "$step_id" >> "$ran_ids_file"

        # Resolve branch target.
        local branch_target
        if [ $rc -eq 0 ]; then
            branch_target="$(plist_get "$cfg" "$pkey:Steps:$i:OnSuccess")"
        else
            branch_target="$(plist_get "$cfg" "$pkey:Steps:$i:OnFailure")"
        fi

        if [ -z "$branch_target" ]; then
            # Default: advance to next step (or stop on failure if not ContinueOnFailure).
            i=$(( i + 1 ))
        elif [ "$branch_target" = '$end' ]; then
            log info "step=$step_id branch → end (rc=$rc)"
            # Nothing else will run, so everything still unvisited is skipped.
            mark_unvisited_skipped 0 "$total"
            break
        elif [ "$branch_target" = '$next' ]; then
            log info "step=$step_id branch → next (continue despite rc=$rc)"
            i=$(( i + 1 ))
        else
            # Named step ID — look up in the tab-delimited id_map_file.
            local target_idx
            target_idx="$(/usr/bin/awk -F'\t' -v t="$branch_target" '$1==t{print $2;exit}' "$id_map_file")"
            if [ -z "$target_idx" ]; then
                log warn "step=$step_id branch target '$branch_target' not found; advancing normally"
                i=$(( i + 1 ))
            else
                log info "step=$step_id branch → $branch_target (idx=$target_idx rc=$rc)"
                # Label the steps we just jumped over NOW rather than at the end
                # of the run. A branch at step 0 that lands on the last step
                # otherwise leaves every step between them reading "Pending"
                # for the entire run — and if the landing step is a blocking
                # one, the user sits looking at a list that claims work is
                # still coming while nothing is happening. A backward branch
                # can bring one of these back into play; run_step overwrites
                # the status when it actually runs, so this self-corrects.
                if [ "$target_idx" -gt $(( i + 1 )) ]; then
                    mark_unvisited_skipped $(( i + 1 )) "$target_idx"
                fi
                i=$target_idx
            fi
        fi
    done
    if (( steps_done >= max_iters )); then
        log warn "Step execution halted after $steps_done iterations — possible branch cycle detected"
    fi

    # Backstop: anything still unvisited (unreachable, or skipped by a path the
    # loop above didn't label) gets marked here. Branch-time marking handles the
    # common case early; this catches the rest.
    mark_unvisited_skipped 0 "$total"

    ui_set_progress 100 "Finished"

    # Offer addon profiles if any are defined. A failed add-on step counts
    # toward the run result, same as a main-playbook step.
    run_addon_profiles "$cfg" "$ran_ids_file" "$total" "$pidx" || any_fail=1

    # Finish. If AllowClose, leave a Done button; otherwise auto-quit.
    local allow_close
    allow_close="$(plist_bool "$cfg" ":AllowClose" false)"
    log info "End-of-run: AllowClose=$allow_close pid_file_exists=$([ -f "$DIALOG_PID_FILE" ] && echo yes || echo no)"
    if [ "$allow_close" = "true" ]; then
        ui_enable_done
        ui_set_banner "All done. You can close this window."
        # Wait for the main dialog to exit naturally (user clicks Done).
        # Resolve the live PID defensively: trust DIALOG_PID_FILE first, but
        # fall back to pgrep if it's stale or dead — earlier failures (e.g.
        # the addon picker leaving the file pointing at a now-defunct
        # subshell wrapper) used to make this loop exit instantly and the
        # script tear down before the user could click Done.  When falling
        # back, pick the lowest swiftDialog PID, which is typically the
        # oldest process — i.e. the main run window, not a later keeper or
        # popup.
        local pid
        pid="$(/bin/cat "$DIALOG_PID_FILE" 2>/dev/null)"
        if ! [[ "$pid" =~ ^[1-9][0-9]*$ ]] || ! /bin/kill -0 "$pid" 2>/dev/null; then
            local _resolved
            _resolved="$(_ui_list_dialog_pids 2>/dev/null | /usr/bin/sort -n | /usr/bin/head -1)"
            if [ -n "$_resolved" ]; then
                log info "End-of-run: stored dialog PID '$pid' invalid; using pgrep result $_resolved"
                pid="$_resolved"
            fi
        fi
        log info "End-of-run: waiting on dialog pid=$pid"
        if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
            while /bin/kill -0 "$pid" 2>/dev/null; do
                /bin/sleep 0.5
            done
            log info "End-of-run: dialog pid=$pid exited"
        else
            log warn "End-of-run: no live dialog PID resolved; AllowClose hold skipped"
        fi
    else
        ui_set_banner "All done."
        /bin/sleep 2
    fi

    # Mark the run complete so we don't bother the user on next login. Test mode
    # does NOT count — the point is to rehearse the run, not consume it.
    #
    # Neither does a run the user never saw. Two ways that happened, both of
    # which used to write the flag and permanently suppress onboarding:
    #
    #   * No console user. Under the LaunchDaemon this no longer occurs —
    #     wait_for_console_user blocks until a session exists rather than
    #     timing out and running headlessly. The guard stays because the
    #     interactive path can still reach it: a `sudo enrollinator.sh --force`
    #     over SSH has no GUI session to place a window in.
    #   * The dialog died during startup (ENROLLINATOR_UI_FAILED), which
    #     ui_start already detects and warns about.
    #
    # In both cases the work may well have succeeded, but the user saw nothing.
    # Leaving the flag unwritten costs one repeat run; writing it costs the
    # entire onboarding, silently and permanently.
    local ui_was_shown=1
    if [ -z "${ENROLLINATOR_CONSOLE_USER:-}" ]; then
        log error "No console user was ever available — this run had nowhere to display. NOT writing the completion flag, so onboarding will be retried."
        ui_was_shown=0
    elif [ "${ENROLLINATOR_UI_FAILED:-0}" = "1" ]; then
        log error "The setup window never came up — this run was invisible to the user. NOT writing the completion flag, so onboarding will be retried."
        ui_was_shown=0
    fi

    if [ $any_fail -eq 0 ] && [ "$ENROLLINATOR_TEST_MODE" != "1" ] && [ "$ui_was_shown" -eq 1 ]; then
        /usr/bin/touch "$ENROLLINATOR_COMPLETED_FLAG" 2>/dev/null || true
        # A completed run resets the welcome-screen deferral budget, so a
        # future re-run (--force / daemon kickstart) starts fresh.
        /bin/rm -f "${ENROLLINATOR_PERSIST_DIR}/welcome_deferrals" 2>/dev/null || true
    fi

    log info "Enrollinator finished (any_fail=$any_fail test_mode=$ENROLLINATOR_TEST_MODE)"

    # Push an inventory update so Jamf Pro reflects the new state immediately.
    # Run in the background so we don't block; skip in test/dry-run mode and
    # when Jamf isn't present (the script is MDM-agnostic). Opt out with
    # JamfRecon=false at the top level of the config.
    if [ "$CLI_DRY_RUN" -eq 0 ] && [ "$ENROLLINATOR_TEST_MODE" != "1" ] \
       && [ "$(plist_bool "$cfg" ":JamfRecon" true)" = "true" ] \
       && [ -x /usr/local/jamf/bin/jamf ]; then
        log info "Triggering jamf recon"
        /usr/local/jamf/bin/jamf recon &
    fi

    [ $any_fail -eq 0 ]
}

main "$@"
