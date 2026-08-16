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

set -o pipefail

# ----------------------------------------------------------------------------
# Paths and constants
# ----------------------------------------------------------------------------

ENROLLINATOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    dir="$(dirname "$ENROLLINATOR_LOG")"
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
ensure_state_dir() {
    local dir="$ENROLLINATOR_STATE_DIR"
    local am_root=0
    [ "$(/usr/bin/id -u)" -eq 0 ] && am_root=1

    # A symlink or a non-directory at that path is never ours.
    if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
        log warn "State dir $dir is not a directory — replacing it"
        /bin/rm -f "$dir" 2>/dev/null
    fi
    # A real directory owned by anyone but root can have had its contents
    # pre-planted, so don't inherit it.
    if [ "$am_root" -eq 1 ] && [ -d "$dir" ]; then
        local owner
        owner="$(/usr/bin/stat -f '%u' "$dir" 2>/dev/null)"
        if [ -n "$owner" ] && [ "$owner" != "0" ]; then
            log warn "State dir $dir is owned by uid $owner, not root — recreating"
            /bin/rm -rf "$dir" 2>/dev/null
        fi
    fi

    /bin/mkdir -p "$dir" 2>/dev/null || {
        log error "Could not create state dir $dir"
        return 1
    }
    /bin/chmod 0755 "$dir" 2>/dev/null
    [ "$am_root" -eq 1 ] && /usr/sbin/chown root:wheel "$dir" 2>/dev/null
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
    cat <<EOF
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

# When Enrollinator starts from its LaunchDaemon at boot, there's usually no
# console user yet. Wait (bounded) for the loginwindow to hand over.
wait_for_console_user() {
    local timeout="${1:-300}" elapsed=0 user
    while [ "$elapsed" -lt "$timeout" ]; do
        user="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null)"
        case "$user" in
            ""|root|_*|loginwindow) : ;;   # keep waiting
            *) ENROLLINATOR_CONSOLE_USER="$user"; return 0 ;;
        esac
        /bin/sleep 2
        elapsed=$((elapsed + 2))
    done
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
        raw="$(load_bare_xml "$CLI_XML")" || exit $?
    elif [ -n "$CLI_CONFIG" ]; then
        ENROLLINATOR_CONFIG_SOURCE="--config $CLI_CONFIG"
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

    # Iterate PayloadContent indices looking for com.enrollinator.app.
    local i=0 type
    while type="$(/usr/bin/plutil -extract "PayloadContent.$i.PayloadType" raw -o - "$src" 2>/dev/null)"; do
        if [ "$type" = "com.enrollinator.app" ]; then
            # Pull the whole sub-dict into its own xml plist. The PayloadUUID
            # etc. keys ride along — harmless, Enrollinator never reads them.
            /usr/bin/plutil -extract "PayloadContent.$i" xml1 -o "$out" "$src" 2>/dev/null
            echo "$out"
            return 0
        fi
        i=$((i+1))
    done

    log error "No com.enrollinator.app payload found in $src"
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
        value="$(hw_info_value "$field")"
        [ -z "$value" ] && value="—"
        label="$(hw_info_label "$field")"
        # swiftDialog infobox honors markdown; double-space == line break.
        out="${out}**${label}:** ${value}  "$'\n'
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
        defer_count="$(cat "$defer_file" 2>/dev/null)"
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
        [ -n "$_osa_pid" ] && kill "$_osa_pid" 2>/dev/null
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

# run_addon_profiles cfg ran_ids_file list_item_base
#   cfg            — path to the plist config
#   ran_ids_file   — file of step IDs already executed (one per line)
#   list_item_base — number of list items already in the swiftDialog window
run_addon_profiles() {
    local cfg="$1" ran_ids_file="$2" list_item_base="$3"

    # Collect addon profiles.
    local prof_count i pname
    prof_count="$(plist_array_count "$cfg" ":Playbooks")"
    local addon_names=() addon_idxs=()
    local addon_descs=()
    for (( i=0; i<prof_count; i++ )); do
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

    ensure_state_dir
    /bin/mkdir -p "$ENROLLINATOR_PERSIST_DIR" 2>/dev/null

    # Already-completed gate. --force re-runs. Dry-run and explicit test-mode
    # bypass the gate too — those are developer workflows.
    if [ -f "$ENROLLINATOR_COMPLETED_FLAG" ] \
        && [ "$CLI_FORCE" -eq 0 ] \
        && [ "$CLI_DRY_RUN" -eq 0 ] \
        && [ "$CLI_TEST" -eq 0 ]; then
        log info "Completion flag present ($ENROLLINATOR_COMPLETED_FLAG); skipping. Use --force to re-run."
        exit 0
    fi

    # When we're a LaunchDaemon at boot, the console user may not exist yet.
    # Skip the wait if we're obviously interactive or there's already a user
    # logged in.
    if ! [ -t 1 ]; then
        if ! wait_for_console_user 300; then
            log warn "No console user after 5min; continuing anyway."
        else
            log info "Console user: $ENROLLINATOR_CONSOLE_USER"
        fi
    else
        ENROLLINATOR_CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null)"
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
            target_idx="$(awk -F'\t' -v t="$branch_target" '$1==t{print $2;exit}' "$id_map_file")"
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
    run_addon_profiles "$cfg" "$ran_ids_file" "$total" || any_fail=1

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
        pid="$(cat "$DIALOG_PID_FILE" 2>/dev/null)"
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
    #   * No console user. wait_for_console_user gives up after 5 minutes and
    #     logs "continuing anyway" — routine during ADE when Setup Assistant is
    #     still on screen. With no console user, _ui_user_exec cannot place a
    #     window in any GUI session, so every step ran headlessly.
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
