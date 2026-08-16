#!/bin/bash
# lib/plugins.sh — action and condition handlers.
#
# Every Step in the mobileconfig has an optional `Action` (performed once)
# and optional `Conditions` (evaluated as read-only predicates). Both are
# dicts with a `Type` key; the type selects a handler here.
#
# Actions return exit 0 on success, non-zero on failure. Their stdout is
# captured for the user-visible message.
#
# Conditions also return 0 (pass) / non-zero (fail), and stdout becomes
# the message shown in the UI while polling.
#
# To add a new handler, just add a case branch and document the expected
# plist keys.

# ----------------------------------------------------------------------------
# Actions
# ----------------------------------------------------------------------------

# action_run <plist> <step_key>
# Runs the action at "<step_key>:Action". Echoes a user-visible message.
action_run() {
    local file="$1" key="$2"
    local type
    type="$(plist_get "$file" "${key}:Action:Type")"
    if [ -z "$type" ]; then
        # No Action at all → nothing to do, success. But an Action dict
        # whose Type can't be read is a malformed config: failing loudly
        # beats silently marking the step done without running anything.
        if plist_exists "$file" "${key}:Action"; then
            echo "Action exists but its Type key is missing or unreadable" >&2
            return 2
        fi
        return 0
    fi

    # Test mode: describe what we would run without actually running it.
    # Conditions still evaluate normally so users can rehearse gating.
    # Exception: dialog actions run for real — they are pure UI with no
    # side effects, so showing them during a test run is useful and safe.
    if [ "${ENROLLINATOR_TEST_MODE:-0}" = "1" ] && [ "$type" != "dialog" ]; then
        local summary
        case "$type" in
            shell)   summary="$(plist_get "$file" "${key}:Action:Command")" ;;
            package) summary="$(plist_get "$file" "${key}:Action:Path")" ;;
            wait)    summary="$(plist_get "$file" "${key}:Action:DurationSeconds")s" ;;
            noop)    summary="noop" ;;
            *)       summary="$type" ;;
        esac
        echo "TEST MODE: would run $type ($(trim_action_summary "$summary"))"
        return 0
    fi

    case "$type" in
        shell)           action_shell   "$file" "${key}:Action" ;;
        package)         action_package "$file" "${key}:Action" ;;
        wait)            action_wait    "$file" "${key}:Action" ;;
        dialog)          action_dialog  "$file" "${key}:Action" ;;
        noop)            echo "ok" ;;
        *) echo "Unknown action type: $type" >&2; return 2 ;;
    esac
}

# Squash to the first line, trimmed to 60 chars — keeps the UI from blowing
# up when a shell Command is a multi-line monster.
trim_action_summary() {
    local s="$1"
    s="${s%%$'\n'*}"
    if [ "${#s}" -gt 60 ]; then
        s="${s:0:57}…"
    fi
    printf '%s' "$s"
}

# action_shell — run an arbitrary shell command. Keys:
#   Command          (string, required)
#   RunAsUser        (string, optional)  "$CONSOLE_USER" or a specific username
#   TimeoutSeconds   (int, optional, default 300)
#   SuccessExitCodes (array of ints, optional, default [0])
action_shell() {
    local file="$1" key="$2"
    local cmd timeout user
    cmd="$(plist_get "$file" "${key}:Command")"
    timeout="$(plist_get "$file" "${key}:TimeoutSeconds")"
    timeout="${timeout:-300}"
    user="$(plist_get "$file" "${key}:RunAsUser")"

    if [ -z "$cmd" ]; then
        echo "shell action: missing Command" >&2
        return 2
    fi

    # Optional: run as the console user. We build an argv rather than
    # re-quoting into a new shell string.
    #
    # A requested privilege drop that cannot be honored fails the step. The
    # alternative is running the admin's user-scoped command as root, which
    # is what this used to do silently — see _user_exec_prefix.
    local -a argv
    if ! _user_exec_prefix "$user"; then
        echo "shell action: RunAsUser '$user' could not be honored; refusing to run this command as root" >&2
        return 2
    fi
    argv=( "${USER_EXEC_ARGV[@]}" /bin/sh -c "$cmd" )

    # `timeout(1)` isn't on macOS; use perl's alarm, passing argv through
    # @ARGV (no string interpolation = no quoting pitfalls).
    #
    # PATH is widened back to ENROLLINATOR_STEP_PATH for the admin's own
    # command. Enrollinator itself runs on a hardened PATH that excludes
    # /usr/local/bin (see the header of enrollinator.sh), but configs in the
    # wild call `brew`, `jamf` and similar unqualified, and a step command is
    # arbitrary root code by design — restricting its PATH would break those
    # configs without changing what the step is already permitted to do.
    PATH="$ENROLLINATOR_STEP_PATH" \
        /usr/bin/perl -e 'alarm shift; exec @ARGV or die $!' "$timeout" "${argv[@]}" 2>&1
    local rc=$?
    return $rc
}

# action_package — install a .pkg via /usr/sbin/installer. Keys:
#   Path            (string, required)
#   Target          (string, optional, default "/")
#   TimeoutSeconds  (int, optional, default 600)
action_package() {
    local file="$1" key="$2"
    local path target timeout
    path="$(plist_get "$file" "${key}:Path")"
    target="$(plist_get "$file" "${key}:Target")"
    target="${target:-/}"
    timeout="$(plist_get "$file" "${key}:TimeoutSeconds")"
    timeout="${timeout:-600}"

    if [ -z "$path" ] || [ ! -f "$path" ]; then
        echo "Package not found: $path" >&2
        return 2
    fi
    # Widened PATH: pkg pre/postinstall scripts are third-party code that may
    # expect /usr/local/bin, exactly like a shell action's command.
    PATH="$ENROLLINATOR_STEP_PATH" \
        /usr/bin/perl -e 'alarm shift; exec @ARGV or die $!' "$timeout" \
        /usr/sbin/installer -pkg "$path" -target "$target" -verbose 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then
        echo "Installed $(/usr/bin/basename "$path")"
    fi
    return $rc
}

# action_wait — pause for a fixed duration. Useful after a background task
# (like a LaunchDaemon spawn) to give it time to settle before conditions run.
# Keys:
#   DurationSeconds (int, required)
action_wait() {
    local file="$1" key="$2"
    local secs
    secs="$(plist_get "$file" "${key}:DurationSeconds")"
    if [ -z "$secs" ] || ! [[ "$secs" =~ ^[0-9]+$ ]]; then
        echo "wait action: DurationSeconds (int) required"
        return 2
    fi
    /bin/sleep "$secs"
    echo "Waited ${secs}s"
    return 0
}

# action_dialog — spawn a swiftDialog popup with configurable buttons. The
# step succeeds if the user clicks the expected button, fails otherwise.
# Keys:
#   Title           (string, required)
#   Message         (string, required)
#   Width           (int, optional, default 520)
#   Height          (int, optional, default 300)
#   Buttons         (array of strings, optional; 1–3 labels, default [OK])
#   ExpectedButton  (string, optional; defaults to the first button)
action_dialog() {
    local file="$1" key="$2"
    local title message width height expected title_fs msg_fs dlg_blur dlg_ontop
    title="$(plist_get "$file" "${key}:Title")"
    message="$(plist_get "$file" "${key}:Message")"
    width="$(plist_get "$file" "${key}:Width")"
    height="$(plist_get "$file" "${key}:Height")"
    expected="$(plist_get "$file" "${key}:ExpectedButton")"
    title_fs="$(plist_get "$file" "${key}:TitleFontSize")"
    msg_fs="$(plist_get "$file" "${key}:MessageFontSize")"
    dlg_blur="$(plist_get "$file" "${key}:Blur")"
    dlg_ontop="$(plist_get "$file" "${key}:AlwaysOnTop")"
    local dlg_video dlg_video_autoplay dlg_slideshow="" dlg_ss_titles="" dlg_ss_msgs=""
    local dlg_ss_count dlg_j dlg_f dlg_st dlg_sm
    dlg_video="$(plist_get "$file" "${key}:Video")"
    dlg_video_autoplay="$(plist_get "$file" "${key}:VideoAutoplay")"
    dlg_ss_count="$(plist_array_count "$file" "${key}:Slideshow")"
    for (( dlg_j=0; dlg_j<dlg_ss_count; dlg_j++ )); do
        # Try dict format (Image sub-key) first; fall back to plain string entry.
        dlg_f="$(plist_get "$file" "${key}:Slideshow:${dlg_j}:Image")"
        if [ -n "$dlg_f" ]; then
            dlg_st="$(plist_get "$file" "${key}:Slideshow:${dlg_j}:Title")"
            dlg_sm="$(plist_get "$file" "${key}:Slideshow:${dlg_j}:Message")"
        else
            dlg_f="$(plist_get "$file" "${key}:Slideshow:${dlg_j}")"
            dlg_st=""
            dlg_sm=""
        fi
        # Skip entirely empty entries.
        [ -z "$dlg_f" ] && [ -z "$dlg_st" ] && [ -z "$dlg_sm" ] && continue
        dlg_slideshow="${dlg_slideshow:+${dlg_slideshow}|}${dlg_f}"
        dlg_ss_titles="${dlg_ss_titles:+${dlg_ss_titles}|}${dlg_st}"
        dlg_ss_msgs="${dlg_ss_msgs:+${dlg_ss_msgs}|}${dlg_sm}"
    done

    if [ -z "$title" ] || [ -z "$message" ]; then
        echo "dialog action: Title and Message are required"
        return 2
    fi

    # Gather buttons array → pipe-delimited list for ui_dialog_popup.
    local btns="" count i label
    count="$(plist_array_count "$file" "${key}:Buttons")"
    for (( i=0; i<count; i++ )); do
        label="$(plist_get "$file" "${key}:Buttons:$i")"
        [ -z "$label" ] && continue
        if [ -z "$btns" ]; then
            btns="$label"
        else
            btns="$btns|$label"
        fi
    done
    [ -z "$btns" ] && btns="OK"
    [ -z "$expected" ] && expected="${btns%%|*}"

    # Apply per-dialog blur/ontop overrides, falling back to global env.
    local _saved_blur="$ENROLLINATOR_UI_BLUR" _saved_ontop="$ENROLLINATOR_UI_ONTOP"
    [ "$dlg_blur"  = "true"  ] && ENROLLINATOR_UI_BLUR=1
    [ "$dlg_blur"  = "false" ] && ENROLLINATOR_UI_BLUR=0
    [ "$dlg_ontop" = "true"  ] && ENROLLINATOR_UI_ONTOP=1
    [ "$dlg_ontop" = "false" ] && ENROLLINATOR_UI_ONTOP=0
    export ENROLLINATOR_UI_BLUR ENROLLINATOR_UI_ONTOP

    local clicked rc
    clicked="$(ui_dialog_popup "$title" "$message" "$width" "$height" "$btns" "$title_fs" "$msg_fs" "$dlg_slideshow" "$dlg_video" "$dlg_ss_titles" "$dlg_ss_msgs" "$dlg_video_autoplay")"
    rc=$?
    ENROLLINATOR_UI_BLUR="$_saved_blur"; ENROLLINATOR_UI_ONTOP="$_saved_ontop"
    export ENROLLINATOR_UI_BLUR ENROLLINATOR_UI_ONTOP
    if [ $rc -ne 0 ]; then
        echo "dialog action: swiftDialog exit $rc"
        return $rc
    fi
    if [ "$clicked" = "$expected" ]; then
        echo "User clicked '$clicked'"
        return 0
    fi
    echo "User clicked '$clicked' (expected '$expected')"
    return 1
}

# ----------------------------------------------------------------------------
# Conditions
# ----------------------------------------------------------------------------

# condition_run <plist> <condition_key>
# Echoes a human-readable message; returns 0 on pass, non-zero on fail.
condition_run() {
    local file="$1" key="$2"
    local type
    type="$(plist_get "$file" "${key}:Type")"
    [ -z "$type" ] && { echo "Condition missing Type"; return 2; }

    case "$type" in
        shell)              cond_shell              "$file" "$key" ;;
        app_installed)      cond_app_installed      "$file" "$key" ;;
        default_browser)    cond_default_browser    "$file" "$key" ;;
        file_exists)        cond_file_exists        "$file" "$key" ;;
        profile_installed)  cond_profile_installed  "$file" "$key" ;;
        process_running)    cond_process_running    "$file" "$key" ;;
        *) echo "Unknown condition type: $type"; return 2 ;;
    esac
}

# Shell command as a condition. 0 exit = pass.
# Keys: Command, RunAsUser (optional), TimeoutSeconds (default 15)
#
# RunAsUser matters more here than it does for actions: the common user-state
# checks (`defaults read MobileMeAccounts`, anything under ~) read a per-user
# preference domain, and as root they inspect /var/root and can never become
# true. A blocking step built on one of those would poll forever.
cond_shell() {
    local file="$1" key="$2"
    local cmd timeout user
    cmd="$(plist_get "$file" "${key}:Command")"
    timeout="$(plist_get "$file" "${key}:TimeoutSeconds")"
    timeout="${timeout:-15}"
    user="$(plist_get "$file" "${key}:RunAsUser")"

    # An empty Command would reach `sh -c ""`, exit 0, and pass vacuously —
    # a typo'd key would read as a satisfied condition. Fail it as config.
    if [ -z "$cmd" ]; then
        echo "shell condition: missing Command"
        return 2
    fi

    local -a argv
    # rc 2 = malformed/unsatisfiable config, which run_step handles explicitly:
    # it refuses to BLOCK on such a condition, so a blocking step can't poll
    # forever waiting for something that can never come true.
    if ! _user_exec_prefix "$user"; then
        echo "shell condition: RunAsUser '$user' could not be honored; refusing to evaluate this as root"
        return 2
    fi
    argv=( "${USER_EXEC_ARGV[@]}" /bin/sh -c "$cmd" )
    # Same widened PATH as action_shell — see the note there.
    PATH="$ENROLLINATOR_STEP_PATH" \
        /usr/bin/perl -e 'alarm shift; exec @ARGV or die $!' "$timeout" \
        "${argv[@]}" >/dev/null 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then
        echo "Passed"
    else
        echo "Exit $rc"
    fi
    return $rc
}

# app_installed — Keys: BundleId | Path, MinVersion (optional)
cond_app_installed() {
    local file="$1" key="$2"
    local bundle_id path min_version app_path
    bundle_id="$(plist_get "$file" "${key}:BundleId")"
    path="$(plist_get "$file" "${key}:Path")"
    min_version="$(plist_get "$file" "${key}:MinVersion")"

    if [ -n "$path" ]; then
        app_path="$path"
    elif [ -n "$bundle_id" ]; then
        app_path="$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == \"$bundle_id\"" 2>/dev/null | /usr/bin/head -n1)"
    else
        echo "app_installed: need BundleId or Path"
        return 2
    fi

    if [ -z "$app_path" ] || [ ! -d "$app_path" ]; then
        echo "Not installed"
        return 1
    fi

    if [ -n "$min_version" ]; then
        local version
        version="$(/usr/bin/defaults read "$app_path/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
        if [ -z "$version" ]; then
            echo "Installed but version unreadable"
            return 1
        fi
        if ! version_gte "$version" "$min_version"; then
            echo "v$version < required $min_version"
            return 1
        fi
        echo "v$version"
    else
        echo "Installed"
    fi
    return 0
}

# Dotted-number version comparison. version_gte A B → 0 if A >= B, else 1.
version_gte() {
    local a="$1" b="$2"
    /usr/bin/awk -v a="$a" -v b="$b" 'BEGIN{
        n=split(a,ap,"."); m=split(b,bp,".");
        k=(n>m?n:m);
        for(i=1;i<=k;i++){
            x=(i<=n?ap[i]:0)+0;
            y=(i<=m?bp[i]:0)+0;
            if(x>y)exit 0; if(x<y)exit 1;
        }
        exit 0;
    }'
}

# default_browser — Keys: BundleId (required)
# Reads LaunchServices prefs as the console user.
cond_default_browser() {
    local file="$1" key="$2"
    local expected
    expected="$(plist_get "$file" "${key}:BundleId")"
    if [ -z "$expected" ]; then
        echo "default_browser: missing BundleId"
        return 2
    fi
    expected="$(printf '%s' "$expected" | /usr/bin/tr '[:upper:]' '[:lower:]')"

    # This reads a PER-USER preference domain, so it must run as the console
    # user, not merely inside their session — see _user_exec_prefix.
    local user
    user="$(resolve_user_name '$CONSOLE_USER')"
    if [ -z "$user" ] && [ "$(/usr/bin/id -u)" -eq 0 ]; then
        echo "No console user"
        return 1
    fi
    # rc 1, not 2: unlike the shell handlers, this condition is normally
    # polled on a blocking step, and a console user appearing later is the
    # expected course of events. Failing it as "not satisfied yet" keeps the
    # step pollable. What must NOT happen is falling through to read ROOT's
    # LaunchServices domain, which can never observe the user's choice.
    if ! _user_exec_prefix '$CONSOLE_USER'; then
        echo "Cannot check as the console user"
        return 1
    fi

    local handler
    handler="$("${USER_EXEC_ARGV[@]}" /usr/bin/defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null \
        | /usr/bin/tr -d '\n' \
        | /usr/bin/sed -E 's/.*LSHandlerRoleAll = "?([^";]+)"?;[[:space:]]*LSHandlerURLScheme = "?(http|https)"?.*/\1/' \
        | /usr/bin/tr '[:upper:]' '[:lower:]')"

    if [ "$handler" = "$expected" ]; then
        echo "$expected is default"
        return 0
    fi
    echo "Default is ${handler:-not set}"
    return 1
}

# file_exists — Keys: Path, Kind (file|directory|any, default any)
cond_file_exists() {
    local file="$1" key="$2"
    local path kind
    path="$(plist_get "$file" "${key}:Path")"
    kind="$(plist_get "$file" "${key}:Kind")"
    kind="${kind:-any}"
    if [ -z "$path" ]; then echo "file_exists: missing Path"; return 2; fi
    case "$kind" in
        file)      [ -f "$path" ] && { echo "Present"; return 0; } ;;
        directory) [ -d "$path" ] && { echo "Present"; return 0; } ;;
        *)         [ -e "$path" ] && { echo "Present"; return 0; } ;;
    esac
    echo "Missing"
    return 1
}

# profile_installed — Keys: Identifier (PayloadIdentifier)
cond_profile_installed() {
    local file="$1" key="$2"
    local identifier
    identifier="$(plist_get "$file" "${key}:Identifier")"
    if [ -z "$identifier" ]; then echo "profile_installed: missing Identifier"; return 2; fi
    if /usr/bin/profiles list -all 2>/dev/null | /usr/bin/grep -qF "$identifier"; then
        echo "Installed"
        return 0
    fi
    echo "Not installed"
    return 1
}

# process_running — Keys: Name (required), MinimumCount (default 1)
cond_process_running() {
    local file="$1" key="$2"
    local name minimum count
    name="$(plist_get "$file" "${key}:Name")"
    minimum="$(plist_get "$file" "${key}:MinimumCount")"
    minimum="${minimum:-1}"
    if [ -z "$name" ]; then echo "process_running: missing Name"; return 2; fi
    count=$(/usr/bin/pgrep -x "$name" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    if [ "$count" -ge "$minimum" ]; then
        echo "$count running"
        return 0
    fi
    echo "Not running"
    return 1
}

# ----------------------------------------------------------------------------
# Shared helpers
# ----------------------------------------------------------------------------

# Resolve `$CONSOLE_USER` or a literal username to a concrete username.
# Prefers the ENROLLINATOR_CONSOLE_USER export from main() (captured once on
# startup) before falling back to a live /dev/console lookup. Echoes nothing
# for root or an unresolvable user — callers read that as "no switch needed".
resolve_user_name() {
    local name="$1"
    if [ "$name" = "\$CONSOLE_USER" ] || [ "$name" = '$CONSOLE_USER' ]; then
        name="${ENROLLINATOR_CONSOLE_USER:-}"
        if [ -z "$name" ]; then
            name="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null)"
        fi
    fi
    if [ -z "$name" ] || [ "$name" = "root" ]; then
        return 0
    fi
    printf '%s' "$name"
}

# Resolve `$CONSOLE_USER` or a literal username to a numeric uid.
resolve_uid() {
    local name
    name="$(resolve_user_name "$1")"
    [ -z "$name" ] && return 0
    /usr/bin/id -u "$name" 2>/dev/null
}

# _user_exec_prefix <user>
# Populates the global array USER_EXEC_ARGV with the argv prefix that runs a
# command AS <user> inside that user's GUI session.
#
# Returns 0 when the prefix is ready to use — which includes the cases where
# an empty prefix is the correct answer (nothing was requested, root was
# explicitly requested, or we are not root and therefore cannot escalate).
# Returns 2 when a privilege drop WAS requested and cannot be honored.
#
# That distinction is the whole point of the return code. This function used
# to answer every one of those cases with an empty array and `return 0`, so
# "no drop needed" and "drop impossible" were literally the same value — and
# an empty prefix means "run it right here", i.e. as root under the daemon.
# A step asking for LESS privilege got MORE, was reported as succeeded, and
# said nothing in the log. The case that fired in production is the silent
# one: during ADE, main() waits five minutes for a console user, logs
# "continuing anyway", and every RunAsUser step then ran as root, writing
# into /var/root instead of the user's home.
#
# The rule applied below is narrower than "fail on error": fail closed only
# where the failure would run something with MORE privilege than was asked
# for. A privilege mismatch is fine; a privilege escalation is not.
#
# `launchctl asuser <uid>` alone is NOT a privilege drop. It moves the process
# into the target user's Mach bootstrap but leaves it running as ROOT, against
# root's home and root's preference domain. That silently broke every
# RunAsUser consumer: the bundled Homebrew recipe (brew hard-refuses to run as
# root), `git config --global` (wrote /var/root/.gitconfig), and the
# default_browser condition (read root's LaunchServices plist, so it could
# never observe the user's choice). `sudo -u` is what actually changes the
# persona; -H points HOME at the target user so per-user tooling lands in the
# right place. lib/ui.sh:_ui_user_exec pairs the same two commands.
USER_EXEC_ARGV=()
_user_exec_prefix() {
    local user="$1"
    USER_EXEC_ARGV=()

    # No RunAsUser key at all — nothing was asked for.
    [ -z "$user" ] && return 0
    # An explicit request for root is satisfied by running as root. This is
    # checked on the LITERAL requested value, before resolution, because
    # resolve_user_name also returns empty when $CONSOLE_USER happens to
    # resolve to root — which is a failure to find a real user, not a request
    # for root, and must not be conflated with it.
    [ "$user" = "root" ] && return 0

    # Only root can change identity. A non-root run (dev, --skip-root-check)
    # cannot honor the request either, but it also cannot escalate: the
    # command runs as the unprivileged invoker, never with more authority
    # than was asked for. Permissive is safe here, so this stays a success.
    [ "$(/usr/bin/id -u)" -ne 0 ] && return 0

    local name uid
    name="$(resolve_user_name "$user")"
    if [ -z "$name" ]; then
        log warn "RunAsUser '$user' did not resolve to a real non-root user (no console user yet?) — refusing to run this as root instead"
        return 2
    fi
    uid="$(/usr/bin/id -u "$name" 2>/dev/null)"
    if [ -z "$uid" ]; then
        log warn "RunAsUser '$name' does not resolve to a uid — refusing to run this as root instead"
        return 2
    fi
    USER_EXEC_ARGV=(/bin/launchctl asuser "$uid" /usr/bin/sudo -H -u "$name" --)
    return 0
}
