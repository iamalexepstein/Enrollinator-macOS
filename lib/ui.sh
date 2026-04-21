#!/bin/bash
# lib/ui.sh — swiftDialog driver for Enrollinator.
#
# swiftDialog is launched once in "list" mode for the main run window. Step
# status updates are sent by writing commands to its command file
# (/var/tmp/dialog.log by default). See
# https://github.com/swiftDialog/swiftDialog/wiki/Dynamic-Updates for the
# command reference.
#
# Enrollinator also spawns a second, transient swiftDialog window for each
# blocking step (a "wait window") that shows the user what they need to do.
# The wait window has its own command file and pid file so Enrollinator can
# update its contents (slideshow) while the main run window stays live.
#
# Because Enrollinator runs as root (from a LaunchDaemon) but the dialog needs
# to appear in the console user's session, we invoke swiftDialog via
# `launchctl asuser <uid>`. When ENROLLINATOR_CONSOLE_USER isn't set (dev runs,
# --skip-root-check) we fall back to a direct launch.
#
# If swiftDialog isn't installed, ui_require_dialog bails with a clear
# message. Enterprises typically bundle swiftDialog.pkg alongside Enrollinator.

DIALOG_BIN="${DIALOG_BIN:-/usr/local/bin/dialog}"
DIALOG_COMMAND_FILE="${DIALOG_COMMAND_FILE:-/var/tmp/dialog.log}"
DIALOG_PID_FILE="/var/tmp/enrollinator.dialog.pid"

# Wait-window state (one at a time — steps are serial).
WAIT_COMMAND_FILE="/var/tmp/enrollinator.wait.log"
WAIT_PID_FILE="/var/tmp/enrollinator.wait.pid"
WAIT_SLIDESHOW_PID_FILE="/var/tmp/enrollinator.wait-slideshow.pid"

# Abort with a helpful message if swiftDialog isn't present.
ui_require_dialog() {
    if [ ! -x "$DIALOG_BIN" ]; then
        _ui_user_osascript 'display dialog "Enrollinator needs swiftDialog (https://github.com/swiftDialog/swiftDialog). Please install it via your MDM, then re-run." buttons {"OK"} default button "OK" with icon caution' || true
        log error "swiftDialog not found at $DIALOG_BIN"
        exit 3
    fi
}

# Invoke argv as the console user when we're root; otherwise invoke directly.
_ui_user_exec() {
    local uid=""
    if [ "$(/usr/bin/id -u)" -eq 0 ] && [ -n "${ENROLLINATOR_CONSOLE_USER:-}" ]; then
        uid="$(/usr/bin/id -u "$ENROLLINATOR_CONSOLE_USER" 2>/dev/null)"
    fi
    if [ -n "$uid" ]; then
        /bin/launchctl asuser "$uid" "$@"
    else
        "$@"
    fi
}

# Convenience: osascript in the user session (for pre-UI error popups).
_ui_user_osascript() {
    local script="$1"
    _ui_user_exec /usr/bin/osascript -e "$script" >/dev/null 2>&1
}

# Resolve an icon/logo spec. swiftDialog accepts absolute paths (just pass),
# https:// URLs (just pass), and SF= tokens. Older code required `[ -f ]`
# which silently dropped web URLs on the floor — that's what this function
# fixes. Echoes the normalized spec, or empty if the input is blank.
_ui_normalize_icon() {
    local spec="$1"
    [ -z "$spec" ] && return 0
    case "$spec" in
        http://*|https://*|SF=*) printf '%s' "$spec" ;;
        /*)
            if [ -f "$spec" ]; then
                printf '%s' "$spec"
            fi
            ;;
        *) printf '%s' "$spec" ;;   # let swiftDialog decide
    esac
}

# ui_start — launches the main run window.
# Arguments: title subtitle accent logo_path steps_file
# Additional optional knobs (read from env to keep the positional list sane):
#   ENROLLINATOR_UI_WIDTH         int, default 720
#   ENROLLINATOR_UI_HEIGHT        int, default 560
#   ENROLLINATOR_UI_BANNER        absolute path or https URL for the banner image
#   ENROLLINATOR_UI_INFOBOX       markdown rendered in the right-side info panel
#   ENROLLINATOR_UI_HELPMESSAGE   markdown shown by the ? help button (enables it)
ui_start() {
    local title="$1" subtitle="$2" accent="$3" logo="$4" steps_file="$5"

    # The command file needs to be writable by both root (Enrollinator) and the
    # user-session swiftDialog process. /var/tmp is sticky world-writable.
    : > "$DIALOG_COMMAND_FILE"
    /bin/chmod 0666 "$DIALOG_COMMAND_FILE" 2>/dev/null || true

    # Build the --listitem arguments from the manifest.
    local listitems=()
    local id name desc icon entry resolved_icon
    while IFS='|' read -r id name desc icon; do
        [ -z "$id" ] && continue
        entry="title=$name,statustext=Pending,status=pending"
        resolved_icon="$(_ui_normalize_icon "$icon")"
        if [ -n "$resolved_icon" ]; then
            # Strip any ",animation=X" suffix from SF symbols before embedding
            # the icon in the --listitem comma-delimited string. The suffix
            # introduces an extra comma that swiftDialog parses as a separate
            # key=value pair, causing it to display the attribute key name
            # ("animation") as the list item's visible title instead of the
            # step name. List item icons don't need animations in the list view.
            case "$resolved_icon" in
                SF=*,*) resolved_icon="${resolved_icon%%,*}" ;;
            esac
            entry="$entry,icon=$resolved_icon"
        fi
        listitems+=( --listitem "$entry" )
    done < "$steps_file"

    local width="${ENROLLINATOR_UI_WIDTH:-720}"
    local height="${ENROLLINATOR_UI_HEIGHT:-560}"

    local args=(
        --title "$title"
        --message "$subtitle"
        --position "center"
        --width "$width"
        --height "$height"
        --moveable
        --ignorednd
        --hidetimerbar
        --button1disabled
        --button1text "Done"
        --commandfile "$DIALOG_COMMAND_FILE"
        --progress
        --progresstext "Getting ready…"
    )

    local logo_resolved
    logo_resolved="$(_ui_normalize_icon "$logo")"
    if [ -n "$logo_resolved" ]; then
        args+=( --icon "$logo_resolved" )
    else
        args+=( --icon "SF=sparkles" )
    fi

    if [ -n "${ENROLLINATOR_UI_BANNER:-}" ]; then
        local banner_resolved
        banner_resolved="$(_ui_normalize_icon "$ENROLLINATOR_UI_BANNER")"
        if [ -n "$banner_resolved" ]; then
            args+=( --bannerimage "$banner_resolved" --bannertitle "$title" )
        fi
    fi
    if [ -n "${ENROLLINATOR_UI_INFOBOX:-}" ]; then
        args+=( --infobox "$ENROLLINATOR_UI_INFOBOX" )
    fi
    if [ -n "${ENROLLINATOR_UI_HELPMESSAGE:-}" ]; then
        args+=( --helpmessage "$ENROLLINATOR_UI_HELPMESSAGE" )
    fi

    # --titlefont: combine accent colour and optional font size.
    local tf_parts=()
    [ -n "$accent" ] && tf_parts+=("color=$accent")
    [ -n "${ENROLLINATOR_UI_TITLE_FONTSIZE:-}" ] && tf_parts+=("size=${ENROLLINATOR_UI_TITLE_FONTSIZE}")
    if [ "${#tf_parts[@]}" -gt 0 ]; then
        local IFS=","
        args+=( --titlefont "${tf_parts[*]}" )
    fi
    local mf_size="${ENROLLINATOR_UI_MSG_FONTSIZE:-14}"
    args+=( --messagefont "size=${mf_size}" )

    [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && args+=( --ontop )
    [ "${ENROLLINATOR_UI_BLUR:-0}"  = "1" ] && args+=( --blurscreen )
    _ui_user_exec "$DIALOG_BIN" "${args[@]}" "${listitems[@]}" &
    echo $! > "$DIALOG_PID_FILE"
    # Give the dialog a moment to open the command file for reading.
    /bin/sleep 0.5

    # When root, the PID above belongs to launchctl (exits immediately after
    # handing swiftDialog off to the user session). Poll pgrep to find the
    # real dialog PID and overwrite the file so callers can wait on it.
    if [ "$(/usr/bin/id -u)" -eq 0 ]; then
        local _dpid="" _i
        for (( _i=0; _i<40; _i++ )); do
            _dpid="$(/bin/pgrep -nx dialog 2>/dev/null)"
            [ -n "$_dpid" ] && break
            /bin/sleep 0.1
        done
        [ -n "$_dpid" ] && printf '%s\n' "$_dpid" > "$DIALOG_PID_FILE"
    fi
}

# Write a raw command to swiftDialog's command file.
ui_cmd() {
    printf '%s\n' "$*" >> "$DIALOG_COMMAND_FILE"
}

# ui_set_step_status <index> <status> [text]
# status: pending | wait | success | fail | error | progress
ui_set_step_status() {
    local idx="$1" status="$2" text="${3:-}"
    local statustext
    case "$status" in
        pending)  statustext="Pending" ;;
        wait)     statustext="${text:-Waiting…}" ;;
        success)  statustext="${text:-Done}" ;;
        fail)     statustext="${text:-Failed}" ;;
        error)    statustext="${text:-Error}" ;;
        progress) statustext="${text:-Running…}" ;;
        *)        statustext="$text" ;;
    esac
    ui_cmd "listitem: index: $idx, status: $status, statustext: $statustext"
}

# Update the overall progress bar (0..100).
ui_set_progress() {
    local pct="$1" text="${2:-}"
    ui_cmd "progress: $pct"
    [ -n "$text" ] && ui_cmd "progresstext: $text"
}

# Set the persistent banner message above the list.
ui_set_banner() {
    local text="$1"
    ui_cmd "message: $text"
}

# Enable the Done button.
ui_enable_done() {
    ui_cmd "button1: enable"
}

# Dynamically append a step list item to the running main window.
# Arguments: name [icon]
ui_append_step() {
    local name="$1" icon="${2:-}"
    local cmd="listitem: add, title: $name, status: pending, statustext: Pending"
    local resolved_icon
    resolved_icon="$(_ui_normalize_icon "$icon")"
    if [ -n "$resolved_icon" ]; then
        # Strip animation suffix from SF symbols — same comma-parsing issue
        # as in ui_start: the extra comma produces a rogue "animation" key.
        case "$resolved_icon" in
            SF=*,*) resolved_icon="${resolved_icon%%,*}" ;;
        esac
        cmd="$cmd, icon: $resolved_icon"
    fi
    ui_cmd "$cmd"
}

# Show a blocking checkbox picker for addon profiles.
# Arguments: alternating name/description pairs — name1 desc1 name2 desc2 …
# Descriptions are shown as subtitles under each checkbox (leave empty for none).
# Echoes selected profile names (one per line) to stdout.
# Returns 1 if user clicked Skip/cancelled, 0 otherwise.
ui_addon_picker() {
    local title="${ENROLLINATOR_ADDON_TITLE:-Optional Add-ons}"
    local message="${ENROLLINATOR_ADDON_MESSAGE:-Select additional profiles to install.}"
    local install_btn="${ENROLLINATOR_ADDON_INSTALL_BTN:-Install}"
    local skip_btn="${ENROLLINATOR_ADDON_SKIP_BTN:-Skip}"
    local width="${ENROLLINATOR_ADDON_WIDTH:-500}"
    local height="${ENROLLINATOR_ADDON_HEIGHT:-360}"
    local icon_raw="${ENROLLINATOR_ADDON_ICON:-}"
    local title_fontsize="${ENROLLINATOR_ADDON_TITLE_FONTSIZE:-}"
    local msg_fontsize="${ENROLLINATOR_ADDON_MSG_FONTSIZE:-14}"
    local icon_resolved
    icon_resolved="$(_ui_normalize_icon "$icon_raw")"

    local args=(
        --title   "$title"
        --message "$message"
        --messagefont "size=${msg_fontsize}"
        --button1text "$install_btn"
        --button2text "$skip_btn"
        --json
        --moveable
        --position center
        --width  "$width"
        --height "$height"
    )
    [ -n "$icon_resolved" ]    && args+=( --icon "$icon_resolved" )
    [ -n "$title_fontsize" ]   && args+=( --titlefont "size=${title_fontsize}" )
    [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && args+=( --ontop )
    [ "${ENROLLINATOR_UI_BLUR:-0}"  = "1" ] && args+=( --blurscreen )

    # Build checkbox list; track names separately for JSON parsing.
    # Descriptions are consumed here (used by caller in the message body)
    # but not forwarded to --checkbox since swiftDialog's subtitle support
    # via the comma format is unreliable across versions.
    local names=()
    while (( $# >= 2 )); do
        local _n="$1"
        shift 2
        names+=("$_n")
        args+=( --checkbox "$_n" )
    done

    local raw exit_code
    raw="$(_ui_user_exec "$DIALOG_BIN" "${args[@]}" 2>/dev/null)"
    exit_code=$?
    # swiftDialog exits 2 when the secondary button (Skip) is clicked.
    [ "$exit_code" -eq 2 ] && return 1

    # Parse JSON: swiftDialog emits checkbox values as string "true"/"false".
    # Key is the checkbox label (first field), unaffected by subtitle.
    local json_tmp
    json_tmp="$(/usr/bin/mktemp -t enrollinator-picker-json)"
    printf '%s' "$raw" > "$json_tmp"
    local n
    for n in "${names[@]}"; do
        /usr/bin/python3 -c "
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
val = data.get(sys.argv[2], '')
sys.exit(0 if str(val).lower() == 'true' else 1)
" "$json_tmp" "$n" 2>/dev/null && printf '%s\n' "$n"
    done
    /bin/rm -f "$json_tmp"
    return 0
}

# Close swiftDialog cleanly.
ui_stop() {
    ui_cmd "quit:"
    if [ -f "$DIALOG_PID_FILE" ]; then
        /bin/sleep 0.3
        local pid
        pid="$(cat "$DIALOG_PID_FILE")"
        if [ -n "$pid" ] && /bin/kill -0 "$pid" 2>/dev/null; then
            /bin/kill "$pid" 2>/dev/null || true
        fi
        /bin/rm -f "$DIALOG_PID_FILE"
    fi
    # Just in case a wait window was left open.
    ui_wait_close
}

# ---------------------------------------------------------------------------
# Wait window — a second, transient swiftDialog that blocks the step visually.
# ---------------------------------------------------------------------------

# ui_wait_open <title> <message> <slideshow_pipe_delim> <video> <width> <height>
#   slideshow_pipe_delim: "/a.png|/b.png|/c.png" — empty means no slideshow
#   video: path or URL, empty means none
# If slideshow and video are both set, video wins.
ui_wait_open() {
    local title="$1" message="$2" slideshow="$3" video="$4" width="$5" height="$6"
    local title_fontsize="${7:-}" msg_fontsize="${8:-14}"
    [ -z "$width" ] && width=520
    [ -z "$height" ] && height=420

    ui_wait_close   # clean up any prior wait window

    : > "$WAIT_COMMAND_FILE"
    /bin/chmod 0666 "$WAIT_COMMAND_FILE" 2>/dev/null || true

    local args=(
        --title "$title"
        --message "$message"
        --messagefont "size=${msg_fontsize}"
        --position "center"
        --width "$width"
        --height "$height"
        --moveable
        --ignorednd
        --button1disabled
        --button1text "Waiting…"
        --commandfile "$WAIT_COMMAND_FILE"
        --hideicon
        --progress
        --hidetimerbar
        --progresstext "Watching for your action…"
    )

    if [ -n "$video" ]; then
        args+=( --video "$video" )
    elif [ -n "$slideshow" ]; then
        local first="${slideshow%%|*}"
        local first_resolved
        first_resolved="$(_ui_normalize_icon "$first")"
        [ -n "$first_resolved" ] && args+=( --bannerimage "$first_resolved" )
    fi

    [ -n "$title_fontsize" ] && args+=( --titlefont "size=${title_fontsize}" )
    [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && args+=( --ontop )
    [ "${ENROLLINATOR_UI_BLUR:-0}"  = "1" ] && args+=( --blurscreen )

    _ui_user_exec "$DIALOG_BIN" "${args[@]}" &
    echo $! > "$WAIT_PID_FILE"

    # If this is a multi-image slideshow, start a background rotator.
    if [ -z "$video" ] && [ -n "$slideshow" ] && [[ "$slideshow" == *"|"* ]]; then
        ( ui_wait_slideshow_loop "$slideshow" ) &
        echo $! > "$WAIT_SLIDESHOW_PID_FILE"
    fi

    /bin/sleep 0.3
}

# Generic background slideshow rotator.
# _ui_slideshow_loop <cmd_file> <pipe-delimited-frames> [interval_secs]
# Cycles bannerimage: commands into cmd_file until that file disappears.
_ui_slideshow_loop() {
    local cmd_file="$1" slideshow="$2" interval="${3:-${ENROLLINATOR_WAIT_SLIDESHOW_INTERVAL:-6}}"
    local -a frames
    local IFS='|'
    # shellcheck disable=SC2206
    frames=( $slideshow )
    unset IFS
    local n=${#frames[@]}
    [ "$n" -le 1 ] && return 0
    local i=1
    while [ -f "$cmd_file" ]; do
        /bin/sleep "$interval"
        [ -f "$cmd_file" ] || break
        local f="${frames[$((i % n))]}"
        local r
        r="$(_ui_normalize_icon "$f")"
        [ -n "$r" ] && printf 'bannerimage: %s\n' "$r" >> "$cmd_file"
        i=$((i + 1))
    done
}

# Kept for back-compat; delegates to the generic helper.
ui_wait_slideshow_loop() {
    _ui_slideshow_loop "$WAIT_COMMAND_FILE" "$@"
}

ui_wait_close() {
    if [ -f "$WAIT_COMMAND_FILE" ]; then
        printf 'quit:\n' >> "$WAIT_COMMAND_FILE" 2>/dev/null || true
    fi
    if [ -f "$WAIT_SLIDESHOW_PID_FILE" ]; then
        local spid
        spid="$(cat "$WAIT_SLIDESHOW_PID_FILE" 2>/dev/null)"
        [ -n "$spid" ] && /bin/kill "$spid" 2>/dev/null || true
        /bin/rm -f "$WAIT_SLIDESHOW_PID_FILE"
    fi
    if [ -f "$WAIT_PID_FILE" ]; then
        /bin/sleep 0.2
        local pid
        pid="$(cat "$WAIT_PID_FILE" 2>/dev/null)"
        if [ -n "$pid" ] && /bin/kill -0 "$pid" 2>/dev/null; then
            /bin/kill "$pid" 2>/dev/null || true
        fi
        /bin/rm -f "$WAIT_PID_FILE"
    fi
    /bin/rm -f "$WAIT_COMMAND_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# One-shot popup — used by the "dialog" action type.
# ---------------------------------------------------------------------------

# ui_dialog_popup <title> <message> <width> <height> <buttons_pipe_delim>
#                 [title_fontsize] [msg_fontsize] [slideshow_pipe_delim] [video]
# Prints the label of the button the user clicked to stdout, exit 0.
# Returns non-zero on error (swiftDialog failed to launch or was killed).
# Supports up to 3 buttons (swiftDialog limit for button1/2/3).
# slideshow_pipe_delim: "/a.png|/b.png|/c.png" — each image is its own dialog
#   the user must click "Next →" through; the last frame shows with the real
#   action buttons.  Single image: shown as --image in the final dialog.
# video: path or URL — wins over slideshow when both set
ui_dialog_popup() {
    local title="$1" message="$2" width="$3" height="$4" buttons="$5"
    local title_fontsize="${6:-}" msg_fontsize="${7:-14}"
    local slideshow="${8:-}" video="${9:-}"
    [ -z "$width" ]  && width=520
    [ -z "$height" ] && height=300

    local b1 b2 b3
    local IFS='|'
    # shellcheck disable=SC2206
    local -a barr=( $buttons )
    unset IFS
    b1="${barr[0]:-OK}"
    b2="${barr[1]:-}"
    b3="${barr[2]:-}"

    # ── User-clicked slideshow ──────────────────────────────────────────────
    # When multiple images are in the Slideshow array, display each one as
    # its own dialog that the user must explicitly click through before the
    # final action dialog (with the real buttons) appears.  This is different
    # from the wait-window auto-rotator which runs on a timer.
    if [ -z "$video" ] && [[ "$slideshow" == *"|"* ]]; then
        local -a ss_frames
        local IFS='|'
        # shellcheck disable=SC2206
        ss_frames=( $slideshow )
        unset IFS
        local ss_total=${#ss_frames[@]}
        local ss_i
        for (( ss_i=0; ss_i < ss_total - 1; ss_i++ )); do
            local ss_frame ss_resolved
            ss_frame="${ss_frames[$ss_i]}"
            ss_resolved="$(_ui_normalize_icon "$ss_frame")"
            local ss_args=(
                --title "$title"
                --message "$message"
                --messagefont "size=${msg_fontsize}"
                --position "center"
                --width "$width"
                --height "$height"
                --moveable
                --hideicon
                --button1text "Next →  ($(( ss_i + 1 )) of ${ss_total})"
            )
            [ -n "$title_fontsize" ]  && ss_args+=( --titlefont "size=${title_fontsize}" )
            [ -n "$ss_resolved" ]     && ss_args+=( --image "$ss_resolved" )
            [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && ss_args+=( --ontop )
            [ "${ENROLLINATOR_UI_BLUR:-0}"  = "1" ] && ss_args+=( --blurscreen )
            _ui_user_exec "$DIALOG_BIN" "${ss_args[@]}"
            local ss_rc=$?
            # Any non-zero exit (user force-quit, timeout, etc.) aborts the slideshow.
            [ "$ss_rc" -ne 0 ] && return "$ss_rc"
        done
        # Replace the slideshow variable with just the last frame so the final
        # dialog below shows it as a single image rather than re-triggering
        # the multi-frame path.
        slideshow="${ss_frames[$(( ss_total - 1 ))]}"
    fi

    # ── Final (or only) dialog ──────────────────────────────────────────────
    local popup_cmd="/var/tmp/enrollinator.popup.log"
    : > "$popup_cmd"
    /bin/chmod 0666 "$popup_cmd" 2>/dev/null || true

    local args=(
        --title "$title"
        --message "$message"
        --messagefont "size=${msg_fontsize}"
        --position "center"
        --width "$width"
        --height "$height"
        --moveable
        --hideicon
        --button1text "$b1"
        --commandfile "$popup_cmd"
    )
    [ -n "$title_fontsize" ] && args+=( --titlefont "size=${title_fontsize}" )
    [ -n "$b2" ] && args+=( --button2text "$b2" )
    [ -n "$b3" ] && args+=( --infobuttontext "$b3" )   # 3rd = info button slot
    [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && args+=( --ontop )
    [ "${ENROLLINATOR_UI_BLUR:-0}"  = "1" ] && args+=( --blurscreen )

    # Video wins over a single remaining slideshow frame.
    if [ -n "$video" ]; then
        args+=( --video "$video" )
    elif [ -n "$slideshow" ]; then
        local single_resolved
        single_resolved="$(_ui_normalize_icon "$slideshow")"
        [ -n "$single_resolved" ] && args+=( --image "$single_resolved" )
    fi

    local rc
    _ui_user_exec "$DIALOG_BIN" "${args[@]}"
    rc=$?
    /bin/rm -f "$popup_cmd" 2>/dev/null || true

    # swiftDialog return codes: 0=button1, 2=button2, 3=infobutton, 10=timeout, etc.
    case "$rc" in
        0)  printf '%s' "$b1"; return 0 ;;
        2)  printf '%s' "$b2"; return 0 ;;
        3)  printf '%s' "$b3"; return 0 ;;
        *)  return "$rc" ;;
    esac
}
