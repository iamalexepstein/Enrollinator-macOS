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
ENROLLINATOR_STATE_DIR="${ENROLLINATOR_STATE_DIR:-/var/tmp/enrollinator}"
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
    local ts
    ts="$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s [%s] %s\n' "$ts" "$level" "$*" >> "$ENROLLINATOR_LOG"
    # Also echo INFO+ to stderr when running interactively.
    if [ -t 2 ]; then
        printf '%s [%s] %s\n' "$ts" "$level" "$*" >&2
    fi
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
# Arg parsing
# ----------------------------------------------------------------------------

CLI_CONFIG=""
CLI_XML=""
CLI_PROFILE=""
CLI_DRY_RUN=0
CLI_TEST=0
CLI_SKIP_ROOT=0
CLI_FORCE=0

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
  --test                Run in test mode: evaluate conditions, skip actions (dialog actions still run).
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
            *)                 echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
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

# Returns a path to a plist containing just Enrollinator's config. Handles:
#   * --xml file.plist           (bare plist, schema rooted at the top level)
#   * --config file.mobileconfig (extracts the inner com.enrollinator.app payload)
#   * managed defaults domain    (snapshots via `defaults export`)
load_config() {
    if [ -n "$CLI_XML" ]; then
        load_bare_xml "$CLI_XML"
    elif [ -n "$CLI_CONFIG" ]; then
        extract_mobileconfig_payload "$CLI_CONFIG"
    else
        plist_export_managed "$ENROLLINATOR_DOMAIN"
    fi
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
    out="$(/usr/bin/mktemp -t enrollinator-cfg).plist"
    if ! /bin/cp "$src" "$out"; then
        log error "Failed to read $src"
        exit 2
    fi
    # Best-effort normalize. Non-plist XML will fail here; surface that early.
    if ! /usr/bin/plutil -convert xml1 "$out" 2>/dev/null; then
        log error "File is not a valid property list: $src"
        /bin/rm -f "$out"
        exit 2
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
    out="$(/usr/bin/mktemp -t enrollinator-cfg).plist"

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
        log error "No Playbooks defined in config"
        exit 2
    fi

    # --profile wins.
    if [ -n "$forced" ]; then
        find_profile_by_name "$cfg" "$forced" && return 0
        log error "--profile '$forced' not found"
        exit 2
    fi

    # Walk Playbooks, return first with a matching Selector.
    local i
    for (( i=0; i<count; i++ )); do
        if profile_selector_matches "$cfg" ":Playbooks:$i"; then
            echo "$i"
            return 0
        fi
    done

    # No selector matched → fall back to DefaultPlaybook.
    if [ -n "$default_name" ]; then
        find_profile_by_name "$cfg" "$default_name" && return 0
        log error "DefaultPlaybook '$default_name' not found in Playbooks"
        exit 2
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

# Evaluates :<profile_key>:Selector. No selector → never matches (to keep
# fallback-via-DefaultPlaybook the only way to reach a playbook without a
# selector; this makes ordering predictable).
#
# Supported selector keys:
#   HostnameRegex          — matched against `scutil --get LocalHostName`
#   ModelIdentifierGlob    — fnmatch-style against `sysctl -n hw.model`
#   FileExists             — path must exist on disk
# Multiple keys AND together.
profile_selector_matches() {
    local cfg="$1" pkey="$2"
    plist_exists "$cfg" "${pkey}:Selector" || return 1

    local hostname_re model_glob file_path matched=0

    hostname_re="$(plist_get "$cfg" "${pkey}:Selector:HostnameRegex")"
    model_glob="$(plist_get "$cfg" "${pkey}:Selector:ModelIdentifierGlob")"
    file_path="$(plist_get "$cfg" "${pkey}:Selector:FileExists")"

    if [ -n "$hostname_re" ]; then
        matched=1
        local h
        h="$(/usr/sbin/scutil --get LocalHostName 2>/dev/null)"
        [[ "$h" =~ $hostname_re ]] || return 1
    fi
    if [ -n "$model_glob" ]; then
        matched=1
        local m
        m="$(/usr/sbin/sysctl -n hw.model 2>/dev/null)"
        # shellcheck disable=SC2053 — glob match is intentional.
        [[ "$m" == $model_glob ]] || return 1
    fi
    if [ -n "$file_path" ]; then
        matched=1
        [ -e "$file_path" ] || return 1
    fi

    # An empty Selector dict shouldn't count as a match.
    [ "$matched" -eq 1 ]
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
        printf '%s|%s|%s|%s\n' "$id" "$name" "$desc" "$icon" >> "$manifest"
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
    local start_ts now_ts elapsed
    start_ts="$(/bin/date +%s)"

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
            # Pause the clock while the user is reviewing back-slides so a
            # mid-navigation timer expiry doesn't end the step under their feet.
            if [ -f "${WAIT_NAVIGATING_FILE:-}" ]; then
                start_ts="$now_ts"
            fi
            elapsed=$((now_ts - start_ts))
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
        model)         echo "Model" ;;
        os_version)    echo "macOS" ;;
        ip_address)    echo "IP" ;;
        uuid)          echo "UUID" ;;
        *)             echo "$1" ;;
    esac
}

# Expand {token} placeholders in a branding string with live hardware/user
# values. Tokens match the hw_info_value key names:
#   {console_user}  {full_name}  {hostname}  {computer_name}
#   {serial_number} {model}      {os_version} {ip_address}
# Example: "Setting up {full_name}'s Mac!" → "Setting up Jane Smith's Mac!"
expand_title_vars() {
    local str="$1" key value
    for key in console_user full_name hostname computer_name \
                serial_number model os_version ip_address; do
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
# swiftDialog auto-install
# ----------------------------------------------------------------------------

# ensure_swiftdialog
# If $DIALOG_BIN is already executable, returns immediately (nothing to do).
# Otherwise: shows an osascript "please wait" popup to the console user,
# downloads the latest swiftDialog release from GitHub, installs it, then
# dismisses the popup.
ensure_swiftdialog() {
    [ -x "$DIALOG_BIN" ] && return 0

    log info "swiftDialog not found at $DIALOG_BIN — installing latest release…"

    # Show a non-blocking osascript popup while we work.  'giving up after'
    # acts as a safety net so it never hangs permanently.
    local _osa_pid=""
    if [ -n "${ENROLLINATOR_CONSOLE_USER:-}" ] && [ "$ENROLLINATOR_CONSOLE_USER" != "root" ]; then
        local _uid
        _uid="$(/usr/bin/id -u "$ENROLLINATOR_CONSOLE_USER" 2>/dev/null)"
        if [ -n "$_uid" ]; then
            /bin/launchctl asuser "$_uid" /usr/bin/osascript -e \
                'display dialog "Your new computer setup will start in a moment — please wait while a few required components are installed." buttons {"OK"} giving up after 300 with title "Getting Ready…" with icon note' \
                >/dev/null 2>&1 &
            _osa_pid=$!
        fi
    fi

    local _dismiss_osa
    _dismiss_osa() {
        [ -n "$_osa_pid" ] && kill "$_osa_pid" 2>/dev/null
        wait "$_osa_pid" 2>/dev/null
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
    tmp_pkg="$(/usr/bin/mktemp -t swiftdialog).pkg"

    if ! /usr/bin/curl -fsSL -o "$tmp_pkg" "$pkg_url"; then
        log warn "Failed to download swiftDialog pkg."
        /bin/rm -f "$tmp_pkg"
        _dismiss_osa
        return 1
    fi

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
    local ui_idx rc any_fail=0
    for (( i=0; i<total_addon; i++ )); do
        ui_idx=$(( list_item_base + i ))
        ui_set_progress $(( (i * 100) / total_addon )) "Add-on step $((i+1)) of $total_addon"
        # Apply per-addon test mode for this step's action/condition handlers.
        ENROLLINATOR_TEST_MODE="${addon_run_test[$i]}"
        export ENROLLINATOR_TEST_MODE
        run_step "$cfg" "${addon_run_pkeys[$i]}" "${addon_run_idxs[$i]}" "$ui_idx"
        rc=$?
        [ $rc -ne 0 ] && any_fail=1
        # Record this step as done so future addons in the same session can dedup.
        local done_id
        done_id="$(plist_get "$cfg" "${addon_run_pkeys[$i]}:Steps:${addon_run_idxs[$i]}:Id")"
        [ -z "$done_id" ] && done_id="addon-step-$i"
        printf '%s\n' "$done_id" >> "$ran_ids_file"
    done
    ui_set_progress 100 "Add-ons complete"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
    # Guarantee a stable CWD so launchctl asuser never inherits a path that
    # root can't resolve (e.g. a user's Downloads, a deleted temp dir).
    cd / || true
    parse_args "$@"
    require_root
    init_logging
    log info "Enrollinator starting (root=$ENROLLINATOR_ROOT domain=$ENROLLINATOR_DOMAIN pid=$$)"

    /bin/mkdir -p "$ENROLLINATOR_STATE_DIR" "$ENROLLINATOR_PERSIST_DIR" 2>/dev/null

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

    local cfg
    cfg="$(load_config)"
    log info "Config loaded: $cfg"

    # Pick profile.
    local pidx pname pkey
    pidx="$(pick_profile "$cfg" "$CLI_PROFILE")"
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
    local steps_file
    steps_file="$(build_steps_manifest "$cfg" "$pkey")"
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
    export ENROLLINATOR_UI_WIDTH ENROLLINATOR_UI_HEIGHT ENROLLINATOR_UI_BANNER \
           ENROLLINATOR_UI_TITLE_FONTSIZE ENROLLINATOR_UI_MSG_FONTSIZE \
           ENROLLINATOR_UI_INFOBOX ENROLLINATOR_UI_HELPMESSAGE

    local ui_blur ui_ontop
    ui_blur="$(plist_bool "$cfg" ":BlurScreen" false)"
    ui_ontop="$(plist_bool "$cfg" ":AlwaysOnTop" true)"
    ENROLLINATOR_UI_BLUR="$([ "$ui_blur"  = "true" ] && echo 1 || echo 0)"
    ENROLLINATOR_UI_ONTOP="$([ "$ui_ontop" = "true" ] && echo 1 || echo 0)"
    export ENROLLINATOR_UI_BLUR ENROLLINATOR_UI_ONTOP

    # Auto-install swiftDialog if the config requests it.
    if [ "$(plist_bool "$cfg" ":InstallSwiftDialog" false)" = "true" ]; then
        ensure_swiftdialog || true   # non-fatal — ui_require_dialog will catch a missing binary
    fi

    ui_require_dialog
    ui_start "$title" "$subtitle" "$accent" "$logo" "$steps_file"
    local ran_ids_file id_map_file
    ran_ids_file="$(/usr/bin/mktemp -t enrollinator-ran-ids)"
    id_map_file="$(/usr/bin/mktemp -t enrollinator-id-map)"
    trap 'ui_stop; /bin/rm -f "$cfg" "$steps_file" "$ran_ids_file" "$id_map_file"' EXIT

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
                i=$target_idx
            fi
        fi
    done
    if (( steps_done >= max_iters )); then
        log warn "Step execution halted after $steps_done iterations — possible branch cycle detected"
    fi

    # Mark any steps that were never visited (branched over / unreachable) as Skipped.
    local _sk
    for (( _sk=0; _sk<total; _sk++ )); do
        if [ -z "${_visited_idx[$_sk]:-}" ]; then
            ui_set_step_status "$_sk" pending "Skipped"
        fi
    done

    ui_set_progress 100 "Finished"

    # Offer addon profiles if any are defined.
    run_addon_profiles "$cfg" "$ran_ids_file" "$total"

    # Finish. If AllowClose, leave a Done button; otherwise auto-quit.
    local allow_close
    allow_close="$(plist_bool "$cfg" ":AllowClose" false)"
    if [ "$allow_close" = "true" ]; then
        ui_enable_done
        ui_set_banner "All done. You can close this window."
        # Wait for the dialog process to exit naturally (user clicks Done).
        if [ -f "$DIALOG_PID_FILE" ]; then
            local pid
            pid="$(cat "$DIALOG_PID_FILE")"
            while [ -n "$pid" ] && /bin/kill -0 "$pid" 2>/dev/null; do
                /bin/sleep 0.5
            done
        fi
    else
        ui_set_banner "All done."
        /bin/sleep 2
    fi

    # Mark the run complete so we don't bother the user on next login. Test mode
    # does NOT count — the point is to rehearse the run, not consume it.
    if [ $any_fail -eq 0 ] && [ "$ENROLLINATOR_TEST_MODE" != "1" ]; then
        /usr/bin/touch "$ENROLLINATOR_COMPLETED_FLAG" 2>/dev/null || true
    fi

    log info "Enrollinator finished (any_fail=$any_fail test_mode=$ENROLLINATOR_TEST_MODE)"
    [ $any_fail -eq 0 ]
}

main "$@"
