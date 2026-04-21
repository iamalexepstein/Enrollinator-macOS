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
    [ -z "$type" ] && return 0   # no action → treat as success

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
    local -a argv
    if [ -n "$user" ]; then
        local uid
        uid="$(resolve_uid "$user")"
        if [ -n "$uid" ]; then
            argv=(/bin/launchctl asuser "$uid" /bin/sh -c "$cmd")
        else
            argv=(/bin/sh -c "$cmd")
        fi
    else
        argv=(/bin/sh -c "$cmd")
    fi

    # `timeout(1)` isn't on macOS; use perl's alarm, passing argv through
    # @ARGV (no string interpolation = no quoting pitfalls).
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
    /usr/bin/perl -e 'alarm shift; exec @ARGV or die $!' "$timeout" \
        /usr/sbin/installer -pkg "$path" -target "$target" -verbose 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then
        echo "Installed $(basename "$path")"
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
    local title message width height expected title_fs msg_fs
    title="$(plist_get "$file" "${key}:Title")"
    message="$(plist_get "$file" "${key}:Message")"
    width="$(plist_get "$file" "${key}:Width")"
    height="$(plist_get "$file" "${key}:Height")"
    expected="$(plist_get "$file" "${key}:ExpectedButton")"
    title_fs="$(plist_get "$file" "${key}:TitleFontSize")"
    msg_fs="$(plist_get "$file" "${key}:MessageFontSize")"

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

    local clicked rc
    clicked="$(ui_dialog_popup "$title" "$message" "$width" "$height" "$btns" "$title_fs" "$msg_fs")"
    rc=$?
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
# Keys: Command, TimeoutSeconds (default 15)
cond_shell() {
    local file="$1" key="$2"
    local cmd timeout
    cmd="$(plist_get "$file" "${key}:Command")"
    timeout="$(plist_get "$file" "${key}:TimeoutSeconds")"
    timeout="${timeout:-15}"
    /usr/bin/perl -e 'alarm shift; exec @ARGV or die $!' "$timeout" \
        /bin/sh -c "$cmd" >/dev/null 2>&1
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
        app_path="$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == $bundle_id" 2>/dev/null | /usr/bin/head -n1)"
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

    local uid
    uid="$(resolve_uid '$CONSOLE_USER')"
    [ -z "$uid" ] && { echo "No console user"; return 1; }

    local handler
    handler="$(/bin/launchctl asuser "$uid" /usr/bin/defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null \
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

# Resolve `$CONSOLE_USER` or a literal username to a numeric uid. Prefers the
# ENROLLINATOR_CONSOLE_USER export from main() (captured once on startup) before
# falling back to a live /dev/console lookup.
resolve_uid() {
    local name="$1"
    if [ "$name" = "\$CONSOLE_USER" ] || [ "$name" = '$CONSOLE_USER' ]; then
        name="${ENROLLINATOR_CONSOLE_USER:-}"
        if [ -z "$name" ]; then
            name="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null)"
        fi
    fi
    [ -z "$name" ] || [ "$name" = "root" ] && return
    /usr/bin/id -u "$name" 2>/dev/null
}
