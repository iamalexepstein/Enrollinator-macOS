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
# Created while the watcher is showing interactive back-slides; removed when
# the persistent window is re-launched.  The polling loop pauses the timeout
# clock while this file exists so the timer doesn't fire mid-review.
WAIT_NAVIGATING_FILE="/var/tmp/enrollinator.wait-navigating"
# Blur-keeper for multi-slide wait windows: a background dialog that holds
# --blurscreen open continuously so the blur never flickers during transitions
# between the interactive instruction slides and the persistent wait window.
WAIT_BLUR_KEEPER_CMD="/var/tmp/enrollinator.wait-blur-keeper.log"
WAIT_BLUR_KEEPER_PID_FILE="/var/tmp/enrollinator.wait-blur-keeper.pid"
# Session token written by ui_wait_open just before forking the back-navigation
# watcher.  The watcher inherits the token at fork time and checks it on every
# outer-loop iteration; if the file has changed or disappeared the watcher knows
# it has been superseded by a newer step and exits quietly.  This prevents a
# stale watcher (one that survived because the SIGTERM in ui_wait_close failed
# under a non-root run) from mistaking a fresh empty WAIT_COMMAND_FILE as a
# "← Back" click and reopening the previous step's persistent window.
WAIT_SESSION_FILE="/var/tmp/enrollinator.wait.session"

# Run-level blur keeper — same pattern and same args as WAIT_BLUR_KEEPER, but
# scoped to the whole run so blur is continuous across step boundaries (one
# blurred wait window closing → next blurred wait window opening).
#
# Critical lesson from failed attempts: swiftDialog tolerates multiple dialogs
# stacked above a --blurscreen keeper just fine (the existing per-window
# keeper proves this), but it does NOT tolerate two simultaneous --blurscreen
# dialogs.  Whenever the run-level keeper is alive, foreground dialogs MUST
# skip their own --blurscreen flag.  All seven existing --blurscreen sites in
# this file are gated on _ui_run_blur_keeper_active for exactly this reason.
RUN_BLUR_KEEPER_CMD="/var/tmp/enrollinator.run-blur-keeper.log"
RUN_BLUR_KEEPER_PID_FILE="/var/tmp/enrollinator.run-blur-keeper.pid"

# Abort with a helpful message if swiftDialog isn't present.
ui_require_dialog() {
    if [ ! -x "$DIALOG_BIN" ]; then
        _ui_user_osascript 'display dialog "Enrollinator needs swiftDialog (https://github.com/swiftDialog/swiftDialog). Please install it via your MDM, then re-run." buttons {"OK"} default button "OK" with icon caution' || true
        log error "swiftDialog not found at $DIALOG_BIN"
        exit 3
    fi
}

# _ui_valid_dialog_pid <pid>
# Returns 0 only if pid is a positive integer belonging to a live process
# named "dialog" owned by the console user (or root when running without a
# session). Prevents a local user from spoofing world-readable PID files with
# an arbitrary PID to make root send signals to unrelated processes.
_ui_valid_dialog_pid() {
    local pid="$1"
    # Must be a positive integer.
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    # Process name must match the binary we launched (case-insensitive).
    # swiftDialog's Mach-O is literally `Dialog` (capital D) under
    # /Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog;
    # /usr/local/bin/dialog is a symlink to it.  ps -o comm= reports the
    # real binary name, so a literal "dialog" == "Dialog" test fails.
    local comm _want
    comm="$(/bin/ps -o comm= -p "$pid" 2>/dev/null | /usr/bin/xargs /usr/bin/basename 2>/dev/null | /usr/bin/tr '[:upper:]' '[:lower:]')"
    _want="$(/usr/bin/basename "$DIALOG_BIN" 2>/dev/null | /usr/bin/tr '[:upper:]' '[:lower:]')"
    [ "$comm" = "$_want" ] || return 1
    # Process must be owned by one of the three launch personas used by
    # _ui_user_exec:
    #   1. root                        — daemon mode without a console user
    #   2. $ENROLLINATOR_CONSOLE_USER  — daemon mode with launchctl asuser
    #   3. the current user            — dev/interactive mode (direct invocation)
    # The old version fell back to "root" when CONSOLE_USER was unset, which
    # mis-rejected dialogs legitimately owned by the current user during dev
    # runs.  That caused the back-navigation watcher to mistake the freshly
    # launched dialog as dead and immediately fire "← Back", reopening the
    # previous step's slideshow.
    local owner current_user
    owner="$(/bin/ps -o user= -p "$pid" 2>/dev/null | /usr/bin/tr -d ' ')"
    current_user="$(/usr/bin/id -un 2>/dev/null)"
    [ "$owner" = "root" ] \
        || { [ -n "${ENROLLINATOR_CONSOLE_USER:-}" ] && [ "$owner" = "$ENROLLINATOR_CONSOLE_USER" ]; } \
        || [ "$owner" = "$current_user" ] \
        || return 1
    return 0
}

# _ui_valid_root_pid <pid>
# Returns 0 only if pid is a positive integer for a live root-owned process.
# Used to validate PID files for Enrollinator's own background subshells.
_ui_valid_root_pid() {
    local pid="$1"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    local uid
    uid="$(/bin/ps -o uid= -p "$pid" 2>/dev/null | /usr/bin/tr -d ' ')"
    [ "$uid" = "0" ] || return 1
    return 0
}

# List all live dialog PIDs (one per line).  Case-insensitive exact match on
# process name, using the basename of $DIALOG_BIN — swiftDialog's Mach-O is
# `Dialog` (capital D), so `pgrep -x dialog` misses it entirely.  We use
# `pgrep -i` which is case-insensitive, combined with `-x` for exact match.
_ui_list_dialog_pids() {
    local _n
    _n="$(/usr/bin/basename "$DIALOG_BIN" 2>/dev/null)"
    [ -z "$_n" ] && _n="dialog"
    # pgrep on macOS is at /usr/bin/pgrep, NOT /bin/pgrep.  The original code
    # in this file invoked /bin/pgrep, which silently produces no output on
    # macOS (no such binary) — so every PID-resolution site thought "no live
    # dialogs", which is what ultimately caused the back-nav watcher's inner
    # poll condition to fail instantly and fire the bogus "← Back" branch.
    /usr/bin/pgrep -ix "$_n" 2>/dev/null
}

# Returns 0 (true) iff the run-level blur keeper is alive right now.
_ui_run_blur_keeper_active() {
    [ -f "$RUN_BLUR_KEEPER_PID_FILE" ] || return 1
    local _p
    _p="$(cat "$RUN_BLUR_KEEPER_PID_FILE" 2>/dev/null)"
    [ -z "$_p" ] && return 1
    /bin/kill -0 "$_p" 2>/dev/null
}

# Start the run-level blur keeper.  Idempotent.  Args (intentionally identical
# to the existing WAIT_BLUR_KEEPER): centered, full size, --ontop, --moveable,
# --ignorednd.  This is the configuration the existing multi-slide keeper uses
# and it works correctly there — the foreground dialog is launched after, also
# with --ontop, and stacks on top.  The KEY rule is that the foreground dialog
# does NOT also pass --blurscreen (the keeper is the sole source of blur).
ui_run_blur_keeper_start() {
    _ui_run_blur_keeper_active && return 0
    # Width/height args are accepted for backward-compat with callers but no
    # longer used — the keeper now sits as a tiny 4x4 window in the lower-left
    # corner so it never visually overlaps the foreground dialog (which lives
    # centered) and so its empty content isn't visible during between-step
    # transitions.  --blurscreen is a window-level effect that blurs the whole
    # screen behind the dialog, regardless of the dialog's own size/position,
    # so a 4x4 window still produces a fullscreen blur.
    : > "$RUN_BLUR_KEEPER_CMD"
    /bin/chmod 0644 "$RUN_BLUR_KEEPER_CMD" 2>/dev/null || true
    /usr/sbin/chown root:wheel "$RUN_BLUR_KEEPER_CMD" 2>/dev/null || true

    local _pre
    _pre=",$(_ui_list_dialog_pids 2>/dev/null | /usr/bin/tr '\n' ',')"

    # swiftDialog's --position bottomleft preset reserves a margin from the
    # screen edge.  Compute the actual screen height and place the 1x1 window
    # at x=0, y=screen_height-1 so it sits flush in the very corner.  Falls
    # back to 9999 if osascript is unavailable; swiftDialog clamps in that case.
    local _screen_h
    _screen_h="$(_ui_user_exec /usr/bin/osascript -e \
        'tell application "Finder" to get bounds of window of desktop' \
        2>/dev/null | /usr/bin/awk -F', ' '{print $4}')"
    [[ "$_screen_h" =~ ^[0-9]+$ ]] || _screen_h=9999
    local _y=$(( _screen_h - 1 ))

    local _args=(
        --title " " --message " "
        --messagefont "size=1"
        --position "0,${_y}"
        --width 1 --height 1
        --blurscreen
        --button1disabled --button1text " "
        --commandfile "$RUN_BLUR_KEEPER_CMD"
        --hideicon --moveable --ignorednd
    )
    [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && _args+=( --ontop )
    _ui_user_exec "$DIALOG_BIN" "${_args[@]}" &
    echo $! > "$RUN_BLUR_KEEPER_PID_FILE"

    # Resolve the real swiftDialog PID (the captured $! is the bash subshell).
    local _pid="" _i _all _p
    for (( _i=0; _i<40; _i++ )); do
        _all="$(_ui_list_dialog_pids 2>/dev/null)"
        for _p in $_all; do
            case "$_pre" in
                *",$_p,"*) continue ;;
            esac
            _pid="$_p"
            break
        done
        [ -n "$_pid" ] && break
        /bin/sleep 0.1
    done
    [ -n "$_pid" ] && printf '%s\n' "$_pid" > "$RUN_BLUR_KEEPER_PID_FILE"
}

# Stop the run-level blur keeper.  Idempotent.
ui_run_blur_keeper_stop() {
    [ -f "$RUN_BLUR_KEEPER_CMD" ] && \
        printf 'quit:\n' >> "$RUN_BLUR_KEEPER_CMD" 2>/dev/null || true
    if [ -f "$RUN_BLUR_KEEPER_PID_FILE" ]; then
        /bin/sleep 0.1
        local _p
        _p="$(cat "$RUN_BLUR_KEEPER_PID_FILE" 2>/dev/null)"
        if _ui_valid_dialog_pid "$_p"; then
            /bin/kill "$_p" 2>/dev/null || true
        fi
        /bin/rm -f "$RUN_BLUR_KEEPER_PID_FILE"
    fi
    /bin/rm -f "$RUN_BLUR_KEEPER_CMD" 2>/dev/null || true
}

# Sync the run-level keeper to the current ENROLLINATOR_UI_BLUR setting.
# Called at the top of every dialog-emitting function.  Optional width/height
# args propagate to the keeper window so it matches the foreground dialog.
_ui_run_blur_keeper_sync() {
    if [ "${ENROLLINATOR_UI_BLUR:-0}" = "1" ]; then
        ui_run_blur_keeper_start "${1:-}" "${2:-}"
    else
        ui_run_blur_keeper_stop
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

# Detect YouTube URLs and convert them to an embeddable form for swiftDialog's
# Normalise a video URL/identifier for swiftDialog's --video flag.
# swiftDialog accepts file paths, https:// URLs, and bare YouTube video IDs
# via --video youtubeid=ID.  Full YouTube watch/short URLs are reduced to just
# the 11-character ID.  When autoplay is "true" the YouTube embed URL gets
# ?autoplay=1 appended so the web-view renderer starts it automatically.
# Echoes the normalised value; empty input echoes nothing.
_ui_normalize_video() {
    local url="$1" autoplay="${2:-}"
    [ -z "$url" ] && return 0
    # Store regex in variables — bash 3.2 can't parse [?&] or {n} as bare
    # literals inside [[ =~ ]] without a syntax error.
    local _re_watch='[?&]v=([A-Za-z0-9_-]{11})'
    local _re_short='youtu\.be/([A-Za-z0-9_-]{11})'
    local _re_bare='^[A-Za-z0-9_-]{11}$'
    local _yt_id=""
    if [[ "$url" =~ $_re_watch ]]; then
        _yt_id="${BASH_REMATCH[1]}"
    elif [[ "$url" =~ $_re_short ]]; then
        _yt_id="${BASH_REMATCH[1]}"
    elif [[ "$url" =~ $_re_bare ]]; then
        _yt_id="$url"
    fi
    if [ -n "$_yt_id" ]; then
        if [ "$autoplay" = "true" ]; then
            printf 'youtubeid=%s?autoplay=1&rel=0' "$_yt_id"
        else
            printf 'youtubeid=%s' "$_yt_id"
        fi
        return 0
    fi
    printf '%s' "$url"
}

# _ui_add_video_arg <array_name_ref> <video_url_or_id> [autoplay:true|""]
# Resolves YouTube URLs to the youtubeid= form (with autoplay param when set),
# then appends --video and optionally --videoautoplay to the named array.
_ui_add_video_arg() {
    local _arr="$1" _url="$2" _autoplay="${3:-}"
    # Restrict array name to safe identifier characters before eval to prevent
    # injection if this function is ever called with a derived first argument.
    [[ "$_arr" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
    local _resolved
    _resolved="$(_ui_normalize_video "$_url" "$_autoplay")"
    if [ -n "$_resolved" ]; then
        eval "${_arr}+=( --video \"\$_resolved\" )"
        # For non-YouTube URLs also pass --videoautoplay for AVPlayer autoplay.
        local _re_yt='^youtubeid='
        if [ "$_autoplay" = "true" ] && ! [[ "$_resolved" =~ $_re_yt ]]; then
            eval "${_arr}+=( --videoautoplay )"
        fi
    fi
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

    # No keeper sync here — show_welcome_screen and run_step are the only two
    # places that decide keeper state, because they have the per-surface blur
    # intent in scope.  Auto-syncing here against ENROLLINATOR_UI_BLUR (which
    # has already been restored to its global value by the time ui_start runs
    # after a blurred welcome screen) would tear down a keeper the next step
    # is about to want, producing a visible blur drop between welcome and the
    # first blurred step.

    # The command file is written by root (Enrollinator) and read by the
    # user-session swiftDialog process. 0644 gives swiftDialog read access
    # without allowing local users to inject commands.
    : > "$DIALOG_COMMAND_FILE"
    /bin/chmod 0644 "$DIALOG_COMMAND_FILE" 2>/dev/null || true
    /usr/sbin/chown root:wheel "$DIALOG_COMMAND_FILE" 2>/dev/null || true

    # Build the --listitem arguments from the manifest.
    local listitems=()
    local id name desc icon entry resolved_icon
    while IFS=$'\x1f' read -r id name desc icon; do
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
    [ "${ENROLLINATOR_UI_BLUR:-0}"  = "1" ] && ! _ui_run_blur_keeper_active && args+=( --blurscreen )

    # Snapshot live dialog PIDs before launch so we can identify ours.
    local _pre_pids
    _pre_pids=",$(_ui_list_dialog_pids 2>/dev/null | /usr/bin/tr '\n' ',')"

    _ui_user_exec "$DIALOG_BIN" "${args[@]}" "${listitems[@]}" &
    echo $! > "$DIALOG_PID_FILE"
    # Give the dialog a moment to open the command file for reading.
    /bin/sleep 0.5

    # Find the dialog PID that wasn't alive before launch.  See ui_wait_open
    # for the rationale — pgrep -nx alone picks up older dialogs as false
    # positives when one is already running.
    local _dpid="" _i _all _p
    for (( _i=0; _i<40; _i++ )); do
        _all="$(_ui_list_dialog_pids 2>/dev/null)"
        for _p in $_all; do
            case "$_pre_pids" in
                *",$_p,"*) continue ;;
            esac
            _dpid="$_p"
            break
        done
        [ -n "$_dpid" ] && break
        /bin/sleep 0.1
    done
    [ -n "$_dpid" ] && printf '%s\n' "$_dpid" > "$DIALOG_PID_FILE"
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

    # Run-level keeper is managed by run_step at step boundaries; no sync here.

    # Use a dedicated command file so this dialog does NOT share state with the
    # main run window.  Without --commandfile, swiftDialog falls back to its
    # default (/var/tmp/dialog.log), which IS DIALOG_COMMAND_FILE — the same
    # file the main run window reads from.  Sharing the command file lets
    # signals leak between the two dialogs, and in practice causes the main
    # window to tear down the moment the picker exits, defeating the
    # AllowClose=true (Done button) hold at end-of-run.  ui_dialog_popup uses
    # the same isolation pattern with its own popup_cmd file.
    local picker_cmd="/var/tmp/enrollinator.addon-picker.log"
    : > "$picker_cmd"
    /bin/chmod 0644 "$picker_cmd" 2>/dev/null || true
    /usr/sbin/chown root:wheel "$picker_cmd" 2>/dev/null || true

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
        --commandfile "$picker_cmd"
    )
    [ -n "$icon_resolved" ]    && args+=( --icon "$icon_resolved" )
    [ -n "$title_fontsize" ]   && args+=( --titlefont "size=${title_fontsize}" )
    [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && args+=( --ontop )
    [ "${ENROLLINATOR_UI_BLUR:-0}"  = "1" ] && ! _ui_run_blur_keeper_active && args+=( --blurscreen )

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
    /bin/rm -f "$picker_cmd" 2>/dev/null || true
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
        if _ui_valid_dialog_pid "$pid"; then
            /bin/kill "$pid" 2>/dev/null || true
        fi
        /bin/rm -f "$DIALOG_PID_FILE"
    fi
    # Just in case a wait window was left open.
    ui_wait_close
    # End-of-run teardown of the run-level blur keeper.
    ui_run_blur_keeper_stop
}

# ---------------------------------------------------------------------------
# Wait window — a second, transient swiftDialog that blocks the step visually.
# ---------------------------------------------------------------------------

# ui_wait_open <title> <message> <slideshow_pipe_delim> <video> <width> <height>
#              [title_fontsize] [msg_fontsize] [slide_titles_pipe_delim] [slide_msgs_pipe_delim]
#   slideshow_pipe_delim: "/a.png|/b.png|/c.png"
#     Multiple frames → user clicks "Next →" through each one synchronously
#     before the persistent wait window (last frame) launches.  Condition
#     polling in run_step doesn't start until ui_wait_open returns, so the
#     user finishes reading all instruction slides before Enrollinator begins
#     checking.  Single frame → shown as --image in the wait window.
#   video: path or URL, or YouTube URL (auto-converted to web embed), empty = none
#     video wins over slideshow when both set
#   slide_titles_pipe_delim: "Title 1|Title 2|…"  — per-frame title overrides
#   slide_msgs_pipe_delim:   "Msg 1|Msg 2|…"      — per-frame message overrides
#     Empty slot for a frame → falls back to the window-level title/message.
#   video_autoplay: "true" → add --videoautoplay to the wait window
ui_wait_open() {
    local title="$1" message="$2" slideshow="$3" video="$4" width="$5" height="$6"
    local title_fontsize="${7:-}" msg_fontsize="${8:-14}"
    local slide_titles="${9:-}" slide_msgs="${10:-}" video_autoplay="${11:-}"
    [ -z "$width" ] && width=520
    [ -z "$height" ] && height=420

    # Run-level keeper is managed by run_step at step boundaries; no sync here.

    ui_wait_close   # clean up any prior wait window

    # ── Blur keeper ─────────────────────────────────────────────────────────
    # When blur is enabled and the slideshow has multiple frames, launch a
    # tiny background dialog that holds --blurscreen open for the whole
    # sequence.  Individual slide dialogs appear on top (they're created later,
    # so macOS stacks them in front); the keeper fills the ~200 ms gap between
    # transitions so the blur never flickers.  _ww_use_keeper is set here so
    # every --blurscreen flag in this function can check it.
    local _ww_use_keeper=0
    # Skip the per-window keeper when the run-level keeper is already alive —
    # two simultaneous --blurscreen dialogs break input on the foreground.
    [ "${ENROLLINATOR_UI_BLUR:-0}" = "1" ] && [ -z "$video" ] && [[ "$slideshow" == *"|"* ]] \
        && ! _ui_run_blur_keeper_active && _ww_use_keeper=1
    if [ "$_ww_use_keeper" = "1" ]; then
        : > "$WAIT_BLUR_KEEPER_CMD"
        /bin/chmod 0644 "$WAIT_BLUR_KEEPER_CMD" 2>/dev/null || true
        /usr/sbin/chown root:wheel "$WAIT_BLUR_KEEPER_CMD" 2>/dev/null || true
        local _wbk_args=(
            --title " " --message " "
            --messagefont "size=1"
            --position center
            --width "$width" --height "$height"
            --blurscreen
            --button1disabled --button1text " "
            --commandfile "$WAIT_BLUR_KEEPER_CMD"
            --hideicon --moveable --ignorednd
        )
        [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && _wbk_args+=( --ontop )
        _ui_user_exec "$DIALOG_BIN" "${_wbk_args[@]}" &
        echo $! > "$WAIT_BLUR_KEEPER_PID_FILE"
    fi

    # ── User-clicked instruction slides ────────────────────────────────────
    # Frames 0..N-2 are shown as interactive dialogs (Next + Back after first).
    # The last frame becomes the persistent wait window with button1 disabled
    # ("Waiting…") and — when there are prior frames to return to — an active
    # "← Back" button (button2).
    if [ -z "$video" ] && [[ "$slideshow" == *"|"* ]]; then
        local -a ww_frames ww_stitle_arr ww_smsg_arr
        local IFS='|'
        # shellcheck disable=SC2206
        ww_frames=( $slideshow )
        [ -n "$slide_titles" ] && ww_stitle_arr=( $slide_titles ) || ww_stitle_arr=()
        [ -n "$slide_msgs"   ] && ww_smsg_arr=(   $slide_msgs   ) || ww_smsg_arr=()
        unset IFS
        local ww_total=${#ww_frames[@]}
        local ww_i=0
        while [ "$ww_i" -lt $(( ww_total - 1 )) ]; do
            local ww_frame ww_resolved ww_stitle ww_smsg
            ww_frame="${ww_frames[$ww_i]}"
            ww_resolved="$(_ui_normalize_icon "$ww_frame")"
            ww_stitle="${ww_stitle_arr[$ww_i]:-}"
            ww_smsg="${ww_smsg_arr[$ww_i]:-}"
            [ -z "$ww_stitle" ] && ww_stitle="$title"
            [ -z "$ww_smsg"   ] && ww_smsg="$message"
            local ww_slide_args=(
                --title "$ww_stitle"
                --message "$ww_smsg"
                --messagefont "size=${msg_fontsize}"
                --position "center"
                --width "$width"
                --height "$height"
                --moveable
                --ignorednd
                --hideicon
                --button1text "Next →  ($(( ww_i + 1 )) of ${ww_total})"
            )
            [ "$ww_i" -gt 0 ] && ww_slide_args+=( --button2text "← Back" )
            [ -n "$title_fontsize" ] && ww_slide_args+=( --titlefont "size=${title_fontsize}" )
            [ -n "$ww_resolved" ]    && ww_slide_args+=( --image "$ww_resolved" )
            [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && ww_slide_args+=( --ontop )
            [ "${ENROLLINATOR_UI_BLUR:-0}"  = "1" ] && [ "$_ww_use_keeper" = "0" ] && ! _ui_run_blur_keeper_active && ww_slide_args+=( --blurscreen )
            _ui_user_exec "$DIALOG_BIN" "${ww_slide_args[@]}"
            local ww_rc=$?
            case "$ww_rc" in
                0) ww_i=$(( ww_i + 1 )) ;;
                2) [ "$ww_i" -gt 0 ] && ww_i=$(( ww_i - 1 )) ;;
                *) return "$ww_rc" ;;
            esac
        done
        # Carry the last frame's image and per-slide text into the persistent window.
        local ww_last=$(( ww_total - 1 ))
        slideshow="${ww_frames[$ww_last]}"
        local _last_stitle="${ww_stitle_arr[$ww_last]:-}"
        local _last_smsg="${ww_smsg_arr[$ww_last]:-}"
        [ -n "$_last_stitle" ] && title="$_last_stitle"
        [ -n "$_last_smsg"   ] && message="$_last_smsg"
    elif [ -z "$video" ] && [ -n "$slideshow" ]; then
        # Single-frame slideshow: apply per-slide overrides to the persistent window
        local IFS='|'
        local -a _s1_t _s1_m
        [ -n "$slide_titles" ] && _s1_t=( $slide_titles ) || _s1_t=()
        [ -n "$slide_msgs"   ] && _s1_m=( $slide_msgs   ) || _s1_m=()
        unset IFS
        [ -n "${_s1_t[0]:-}" ] && title="${_s1_t[0]}"
        [ -n "${_s1_m[0]:-}" ] && message="${_s1_m[0]}"
    fi

    : > "$WAIT_COMMAND_FILE"
    /bin/chmod 0644 "$WAIT_COMMAND_FILE" 2>/dev/null || true
    /usr/sbin/chown root:wheel "$WAIT_COMMAND_FILE" 2>/dev/null || true

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
    # Show an active Back button on the persistent window when the slideshow
    # had prior frames the user can return to.
    [ "${ww_total:-0}" -gt 1 ] && args+=( --button2text "← Back" )

    if [ -n "$video" ]; then
        _ui_add_video_arg args "$video" "$video_autoplay"
    elif [ -n "$slideshow" ]; then
        local single_resolved
        single_resolved="$(_ui_normalize_icon "$slideshow")"
        [ -n "$single_resolved" ] && args+=( --image "$single_resolved" )
    fi

    [ -n "$title_fontsize" ] && args+=( --titlefont "size=${title_fontsize}" )
    [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && args+=( --ontop )
    [ "${ENROLLINATOR_UI_BLUR:-0}"  = "1" ] && [ "$_ww_use_keeper" = "0" ] && ! _ui_run_blur_keeper_active && args+=( --blurscreen )

    # Snapshot the set of live dialog PIDs BEFORE launching so we can identify
    # which one is ours.  `pgrep -nx dialog` alone returns the newest live
    # dialog, which for the wait window is a race: the main Enrollinator list
    # dialog from ui_start is already alive, so pgrep would return its PID on
    # the first iteration before our new one has even spawned.  Latching onto
    # the main window here corrupts the back-nav watcher because when the
    # watcher's inner poll sees "main window still alive" it never exits, and
    # worse, when the new wait dialog dies the poll is still watching a wrong
    # target — the subtle symptom being the back-nav slideshow reopening.
    local _pre_pids
    _pre_pids=",$(_ui_list_dialog_pids 2>/dev/null | /usr/bin/tr '\n' ',')"

    _ui_user_exec "$DIALOG_BIN" "${args[@]}" &
    echo $! > "$WAIT_PID_FILE"

    # Poll for a dialog PID that wasn't alive before our launch.  Works in both
    # modes: in dev mode the new dialog is a child of the `&` subshell; in root
    # mode it's a detached launchctl-asuser descendant.  Either way, it's new.
    local _wwpid="" _wwi _all_pids _pid
    for (( _wwi=0; _wwi<40; _wwi++ )); do
        _all_pids="$(_ui_list_dialog_pids 2>/dev/null)"
        for _pid in $_all_pids; do
            case "$_pre_pids" in
                *",$_pid,"*) continue ;;   # was already alive → not ours
            esac
            _wwpid="$_pid"
            break
        done
        [ -n "$_wwpid" ] && break
        /bin/sleep 0.1
    done
    [ -n "$_wwpid" ] && printf '%s\n' "$_wwpid" > "$WAIT_PID_FILE"

    # ── Back-navigation watcher ─────────────────────────────────────────────
    # When the slideshow has more than one frame, a background subshell watches
    # the persistent window's PID.  If it exits because the user clicked
    # "← Back" (rather than because ui_wait_close sent "quit:"), the watcher
    # re-runs the interactive slides from the second-to-last frame, then
    # re-launches the persistent window.  This loops so the user can go back
    # and forward as many times as they like while condition polling continues.
    #
    # Detection: ui_wait_close writes "quit:" into WAIT_COMMAND_FILE before
    # killing the PID; a natural Back-click exit leaves the file empty.
    if [ "${ww_total:-0}" -gt 1 ]; then
        # Write a unique session token before forking so the subshell inherits
        # it.  Any watcher from a prior step will see a different (or absent)
        # token on its next outer-loop check and exit quietly, even if the
        # SIGTERM we sent via ui_wait_close never arrived (non-root run).
        local _ww_session
        _ww_session="$(/bin/date +%s)${RANDOM}${RANDOM}"
        printf '%s\n' "$_ww_session" > "$WAIT_SESSION_FILE"
        /bin/chmod 0644 "$WAIT_SESSION_FILE" 2>/dev/null || true

        # Capture persistent-window args in the subshell (copy at fork time).
        # ww_frames, ww_stitle_arr, ww_smsg_arr, ww_total, and all display
        # vars are inherited by the subshell because it is a fork.
        (
            # Track the PID of any interactive slide dialog we open so we can
            # kill it cleanly if ui_wait_close sends SIGTERM to this watcher.
            local _w_pid _w_back_i _w_child_pid=""
            trap '
                [ -n "$_w_child_pid" ] && /bin/kill "$_w_child_pid" 2>/dev/null || true
                /bin/rm -f "$WAIT_NAVIGATING_FILE" 2>/dev/null || true
                exit 0
            ' TERM INT

            while true; do
                # Exit immediately if our session token is no longer current.
                # ui_wait_close removes WAIT_SESSION_FILE, and any subsequent
                # ui_wait_open overwrites it with a fresh token.  Either event
                # means this watcher has been superseded and must not re-launch
                # the previous step's persistent window.
                local _cur_session
                _cur_session="$(cat "$WAIT_SESSION_FILE" 2>/dev/null)"
                [ "$_cur_session" != "$_ww_session" ] && exit 0

                # Poll until the persistent window PID is no longer alive.
                # Validate the PID is actually a dialog process before polling.
                _w_pid="$(cat "$WAIT_PID_FILE" 2>/dev/null)"
                while _ui_valid_dialog_pid "$_w_pid" && /bin/kill -0 "$_w_pid" 2>/dev/null; do
                    /bin/sleep 0.3
                    # Check session on every cycle: if ui_wait_close ran and a new
                    # step has already written a fresh token (or the file is gone),
                    # exit immediately rather than continuing to poll the wrong PID.
                    _cur_session="$(cat "$WAIT_SESSION_FILE" 2>/dev/null)"
                    [ "$_cur_session" != "$_ww_session" ] && exit 0
                    _w_pid="$(cat "$WAIT_PID_FILE" 2>/dev/null)"
                done

                # If WAIT_PID_FILE was removed, ui_wait_close already ran → done.
                [ ! -f "$WAIT_PID_FILE" ] && exit 0

                # Re-check session here: the inner loop above may have exited
                # because the dialog process died, but in the time between the
                # last 0.3 s sleep and now, ui_wait_close could have removed
                # WAIT_SESSION_FILE and a new step's ui_wait_open could have
                # recreated WAIT_PID_FILE (so the file-exists check above passed).
                # Without this check we would incorrectly conclude "← Back".
                _cur_session="$(cat "$WAIT_SESSION_FILE" 2>/dev/null)"
                [ "$_cur_session" != "$_ww_session" ] && exit 0

                # If WAIT_COMMAND_FILE contains "quit:", condition was met → done.
                grep -q 'quit:' "$WAIT_COMMAND_FILE" 2>/dev/null && exit 0

                # Otherwise the user clicked "← Back".  Re-run interactive
                # slides starting from the second-to-last frame.
                # Signal the polling loop to pause its timeout clock.
                touch "$WAIT_NAVIGATING_FILE" 2>/dev/null || true
                _w_back_i=$(( ww_total - 2 ))
                while true; do
                    local _wf _wr _wt _wm
                    _wf="${ww_frames[$_w_back_i]}"
                    _wr="$(_ui_normalize_icon "$_wf")"
                    _wt="${ww_stitle_arr[$_w_back_i]:-}"
                    _wm="${ww_smsg_arr[$_w_back_i]:-}"
                    [ -z "$_wt" ] && _wt="$title"
                    [ -z "$_wm" ] && _wm="$message"
                    local _wa=(
                        --title "$_wt"
                        --message "$_wm"
                        --messagefont "size=${msg_fontsize}"
                        --position "center"
                        --width "$width"
                        --height "$height"
                        --moveable --ignorednd --hideicon
                        --button1text "Next →  ($(( _w_back_i + 1 )) of ${ww_total})"
                    )
                    [ "$_w_back_i" -gt 0 ]                  && _wa+=( --button2text "← Back" )
                    [ -n "$title_fontsize" ]                 && _wa+=( --titlefont "size=${title_fontsize}" )
                    [ -n "$_wr" ]                            && _wa+=( --image "$_wr" )
                    [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ]  && _wa+=( --ontop )
                    [ "${ENROLLINATOR_UI_BLUR:-0}"  = "1" ] && [ "$_ww_use_keeper" = "0" ] && ! _ui_run_blur_keeper_active && _wa+=( --blurscreen )
                    # Run in background so the TERM trap can kill it mid-slide.
                    _ui_user_exec "$DIALOG_BIN" "${_wa[@]}" &
                    _w_child_pid=$!
                    wait "$_w_child_pid" 2>/dev/null
                    local _wrc=$?
                    _w_child_pid=""
                    case "$_wrc" in
                        0)  _w_back_i=$(( _w_back_i + 1 ))
                            # Break when we've passed the last interactive
                            # frame (index N-2); frame N-1 is the persistent
                            # window, relaunched below — not shown here.
                            [ "$_w_back_i" -ge $(( ww_total - 1 )) ] && break ;;
                        2)  [ "$_w_back_i" -gt 0 ] && _w_back_i=$(( _w_back_i - 1 )) ;;
                        *)  exit 0 ;;   # killed externally — exit quietly
                    esac
                done

                # Re-launch the persistent wait window and update the PID file.
                # Clear the navigation flag first so the timeout clock resumes.
                /bin/rm -f "$WAIT_NAVIGATING_FILE" 2>/dev/null || true
                : > "$WAIT_COMMAND_FILE"
                /bin/chmod 0644 "$WAIT_COMMAND_FILE" 2>/dev/null || true
                /usr/sbin/chown root:wheel "$WAIT_COMMAND_FILE" 2>/dev/null || true
                # Same pgrep-diff resolution as the initial launch in
                # ui_wait_open — picking pgrep -nx alone races against the
                # main Enrollinator list dialog (also a `dialog` process).
                local _pre_pids_rl
                _pre_pids_rl=",$(_ui_list_dialog_pids 2>/dev/null | /usr/bin/tr '\n' ',')"
                _ui_user_exec "$DIALOG_BIN" "${args[@]}" &
                echo $! > "$WAIT_PID_FILE"
                local _rw_pid="" _ri _all_rl _p_rl
                for (( _ri=0; _ri<40; _ri++ )); do
                    _all_rl="$(_ui_list_dialog_pids 2>/dev/null)"
                    for _p_rl in $_all_rl; do
                        case "$_pre_pids_rl" in
                            *",$_p_rl,"*) continue ;;
                        esac
                        _rw_pid="$_p_rl"
                        break
                    done
                    [ -n "$_rw_pid" ] && break
                    /bin/sleep 0.1
                done
                [ -n "$_rw_pid" ] && printf '%s\n' "$_rw_pid" > "$WAIT_PID_FILE"
                # Loop back to watch this new PID.
            done
        ) &
        local _watcher_pid=$!
        echo "$_watcher_pid" > "$WAIT_SLIDESHOW_PID_FILE"
        # disown removes it from bash's job table so SIGTERM doesn't produce
        # a noisy "Terminated: 15" message when ui_wait_close kills it.
        disown "$_watcher_pid" 2>/dev/null || true
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
        # Slideshow PID is Enrollinator's own watcher subshell.  Validate that
        # the process is owned by either root (daemon mode) or the current user
        # (interactive/test mode) before sending SIGTERM, so a local user cannot
        # spoof the PID file to kill an unrelated process when running as root.
        if [[ "$spid" =~ ^[1-9][0-9]*$ ]]; then
            local _sp_uid
            _sp_uid="$(/bin/ps -o uid= -p "$spid" 2>/dev/null | /usr/bin/tr -d ' ')"
            if [ "$_sp_uid" = "0" ] || [ "$_sp_uid" = "$(/usr/bin/id -u)" ]; then
                /bin/kill "$spid" 2>/dev/null || true
            fi
        fi
        /bin/rm -f "$WAIT_SLIDESHOW_PID_FILE"
    fi
    if [ -f "$WAIT_PID_FILE" ]; then
        /bin/sleep 0.2
        local pid
        pid="$(cat "$WAIT_PID_FILE" 2>/dev/null)"
        if _ui_valid_dialog_pid "$pid"; then
            /bin/kill "$pid" 2>/dev/null || true
        fi
        /bin/rm -f "$WAIT_PID_FILE"
    fi
    /bin/rm -f "$WAIT_COMMAND_FILE"    2>/dev/null || true
    /bin/rm -f "$WAIT_NAVIGATING_FILE" 2>/dev/null || true
    # Invalidate the session token so any watcher that survived the SIGTERM
    # above (e.g. because we are not running as root) exits cleanly on its next
    # outer-loop iteration rather than re-launching the previous step's window.
    /bin/rm -f "$WAIT_SESSION_FILE"    2>/dev/null || true
    # Close the blur keeper (if one was launched for a multi-slide wait window).
    if [ -f "$WAIT_BLUR_KEEPER_PID_FILE" ]; then
        local _bkpid
        _bkpid="$(cat "$WAIT_BLUR_KEEPER_PID_FILE" 2>/dev/null)"
        # Write quit: unconditionally — it's a safe command-file write that
        # works regardless of whether we can validate the PID.  The PID in the
        # file may be the launchctl wrapper (already dead) rather than the real
        # swiftDialog process, so gate only the SIGTERM on PID validation.
        printf 'quit:\n' >> "$WAIT_BLUR_KEEPER_CMD" 2>/dev/null || true
        /bin/sleep 0.1
        if _ui_valid_dialog_pid "$_bkpid"; then
            /bin/kill "$_bkpid" 2>/dev/null || true
        fi
        /bin/rm -f "$WAIT_BLUR_KEEPER_PID_FILE"
    fi
    /bin/rm -f "$WAIT_BLUR_KEEPER_CMD" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# One-shot popup — used by the "dialog" action type.
# ---------------------------------------------------------------------------

# ui_dialog_popup <title> <message> <width> <height> <buttons_pipe_delim>
#                 [title_fontsize] [msg_fontsize] [slideshow_pipe_delim] [video]
#                 [slide_titles_pipe_delim] [slide_msgs_pipe_delim]
# Prints the label of the button the user clicked to stdout, exit 0.
# Returns non-zero on error (swiftDialog failed to launch or was killed).
# Supports up to 3 buttons (swiftDialog limit for button1/2/3).
# slideshow_pipe_delim: "/a.png|/b.png|/c.png" — each image is its own dialog
#   the user must click "Next →" through; the last frame shows with the real
#   action buttons.  Single image: shown as --image in the final dialog.
# video: path, URL, or YouTube URL (auto-converted to web embed) — wins over slideshow
# slide_titles_pipe_delim: "Title 1|Title 2|…"  — per-frame title overrides
# slide_msgs_pipe_delim:   "Msg 1|Msg 2|…"      — per-frame message overrides
#   Empty slot → falls back to the dialog-level title/message.
# video_autoplay: "true" → add --videoautoplay
ui_dialog_popup() {
    local title="$1" message="$2" width="$3" height="$4" buttons="$5"
    local title_fontsize="${6:-}" msg_fontsize="${7:-14}"
    local slideshow="${8:-}" video="${9:-}"
    local slide_titles="${10:-}" slide_msgs="${11:-}" video_autoplay="${12:-}"
    # Optional icon/logo path or SF= token. When set, replaces --hideicon so the
    # caller can show a logo (e.g. welcome screen). Empty = --hideicon (default).
    local icon="${13:-}"
    [ -z "$width" ]  && width=520
    [ -z "$height" ] && height=300

    # Run-level keeper is managed by run_step (or show_welcome_screen) at the
    # step boundary; no sync here so transient ENROLLINATOR_UI_BLUR changes
    # inside a step (e.g. envvar restored to global mid-flow) don't tear down
    # the keeper while the step still wants blur.

    local b1 b2 b3
    local IFS='|'
    # shellcheck disable=SC2206
    local -a barr=( $buttons )
    unset IFS
    b1="${barr[0]:-OK}"
    b2="${barr[1]:-}"
    b3="${barr[2]:-}"

    # ── Parse slideshow frames ──────────────────────────────────────────────
    local -a dlg_frames dlg_stitle_arr dlg_smsg_arr
    local dlg_total=1 dlg_has_slides=0
    # Decided before args are built so every --blurscreen flag can use it.
    local _use_keeper=0

    if [ -z "$video" ] && [[ "$slideshow" == *"|"* ]]; then
        dlg_has_slides=1
        local IFS='|'
        # shellcheck disable=SC2206
        dlg_frames=( $slideshow )
        [ -n "$slide_titles" ] && dlg_stitle_arr=( $slide_titles ) || dlg_stitle_arr=()
        [ -n "$slide_msgs"   ] && dlg_smsg_arr=(   $slide_msgs   ) || dlg_smsg_arr=()
        unset IFS
        dlg_total=${#dlg_frames[@]}
        # Skip the per-popup keeper when the run-level keeper is already alive.
        [ "${ENROLLINATOR_UI_BLUR:-0}" = "1" ] && ! _ui_run_blur_keeper_active && _use_keeper=1
    elif [ -z "$video" ] && [ -n "$slideshow" ]; then
        # Single-frame slideshow — resolve per-slide overrides once.
        local IFS='|'
        local -a _s1_t _s1_m
        [ -n "$slide_titles" ] && _s1_t=( $slide_titles ) || _s1_t=()
        [ -n "$slide_msgs"   ] && _s1_m=( $slide_msgs   ) || _s1_m=()
        unset IFS
        [ -n "${_s1_t[0]:-}" ] && title="${_s1_t[0]}"
        [ -n "${_s1_m[0]:-}" ] && message="${_s1_m[0]}"
    fi

    # ── Build final action-dialog args (used in every iteration of the loop) ─
    # The last slideshow frame's per-slide title/message/image override the
    # dialog-level values for the action dialog.
    local _final_title="$title" _final_message="$message" _final_img=""
    if [ "$dlg_has_slides" -eq 1 ]; then
        local dlg_last=$(( dlg_total - 1 ))
        local _lt="${dlg_stitle_arr[$dlg_last]:-}" _lm="${dlg_smsg_arr[$dlg_last]:-}"
        [ -n "$_lt" ] && _final_title="$_lt"
        [ -n "$_lm" ] && _final_message="$_lm"
        _final_img="${dlg_frames[$dlg_last]}"
    fi

    local popup_cmd="/var/tmp/enrollinator.popup.log"
    : > "$popup_cmd"
    /bin/chmod 0644 "$popup_cmd" 2>/dev/null || true
    /usr/sbin/chown root:wheel "$popup_cmd" 2>/dev/null || true

    # Resolve the optional icon once; used in both the final dialog and slides.
    local _icon_resolved
    _icon_resolved="$(_ui_normalize_icon "$icon")"

    local args=(
        --title "$_final_title"
        --message "$_final_message"
        --messagefont "size=${msg_fontsize}"
        --position "center"
        --width "$width"
        --height "$height"
        --moveable
        --button1text "$b1"
        --commandfile "$popup_cmd"
    )
    if [ -n "$_icon_resolved" ]; then
        args+=( --icon "$_icon_resolved" )
    else
        args+=( --hideicon )
    fi
    [ -n "$title_fontsize" ] && args+=( --titlefont "size=${title_fontsize}" )
    # Use b2 slot for ← Back when there are preceding slides and the caller
    # hasn't defined a secondary action button; otherwise pass b2 through.
    local _nav_back=0
    if [ "$dlg_total" -gt 1 ] && [ -z "$b2" ]; then
        _nav_back=1
        args+=( --button2text "← Back" )
    else
        [ -n "$b2" ] && args+=( --button2text "$b2" )
    fi
    [ -n "$b3" ] && args+=( --infobuttontext "$b3" )
    [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && args+=( --ontop )
    # Skip --blurscreen on individual slides when the keeper owns the blur.
    [ "${ENROLLINATOR_UI_BLUR:-0}"  = "1" ] && [ "$_use_keeper" = "0" ] && ! _ui_run_blur_keeper_active && args+=( --blurscreen )

    # Video (with YouTube support) wins over a slideshow image on the final dialog.
    if [ -n "$video" ]; then
        _ui_add_video_arg args "$video" "$video_autoplay"
    elif [ -n "$_final_img" ]; then
        local _fi_r
        _fi_r="$(_ui_normalize_icon "$_final_img")"
        [ -n "$_fi_r" ] && args+=( --image "$_fi_r" )
    elif [ -n "$slideshow" ]; then
        local _ss_r
        _ss_r="$(_ui_normalize_icon "$slideshow")"
        [ -n "$_ss_r" ] && args+=( --image "$_ss_r" )
    fi

    # ── Blur keeper ─────────────────────────────────────────────────────────
    # Same principle as the wait-window keeper: a background dialog holds
    # --blurscreen open so the blur doesn't flicker between slide transitions.
    local _bk_cmd="" _bk_pid=""
    if [ "$_use_keeper" = "1" ]; then
        _bk_cmd="/var/tmp/enrollinator.blur-keeper.log"
        : > "$_bk_cmd"
        /bin/chmod 0644 "$_bk_cmd" 2>/dev/null || true
        /usr/sbin/chown root:wheel "$_bk_cmd" 2>/dev/null || true
        local _bk_args=(
            --title " " --message " "
            --messagefont "size=1"
            --position center
            --width "$width" --height "$height"
            --blurscreen
            --button1disabled --button1text " "
            --commandfile "$_bk_cmd"
            --hideicon --moveable
        )
        [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && _bk_args+=( --ontop )
        _ui_user_exec "$DIALOG_BIN" "${_bk_args[@]}" &
        _bk_pid=$!
    fi

    # ── Unified navigation loop ──────────────────────────────────────────────
    # Frames 0..N-2 are interactive "Next / ← Back" slides; frame N-1 is the
    # action dialog.  ← Back on the action dialog (when b2 is not already a
    # real action) returns to frame N-2 so the user can re-read before acting.
    local dlg_i=0
    while true; do
        if [ "$dlg_has_slides" -eq 1 ] && [ "$dlg_i" -lt $(( dlg_total - 1 )) ]; then
            # ── Interactive slide ────────────────────────────────────────────
            local _df _dr _dt _dm
            _df="${dlg_frames[$dlg_i]}"
            _dr="$(_ui_normalize_icon "$_df")"
            _dt="${dlg_stitle_arr[$dlg_i]:-}"
            _dm="${dlg_smsg_arr[$dlg_i]:-}"
            [ -z "$_dt" ] && _dt="$title"
            [ -z "$_dm" ] && _dm="$message"
            local _da=(
                --title "$_dt"
                --message "$_dm"
                --messagefont "size=${msg_fontsize}"
                --position "center"
                --width "$width"
                --height "$height"
                --moveable
                --button1text "Next →  ($(( dlg_i + 1 )) of ${dlg_total})"
            )
            if [ -n "$_icon_resolved" ]; then _da+=( --icon "$_icon_resolved" ); else _da+=( --hideicon ); fi
            [ "$dlg_i" -gt 0 ]                  && _da+=( --button2text "← Back" )
            [ -n "$title_fontsize" ]             && _da+=( --titlefont "size=${title_fontsize}" )
            [ -n "$_dr" ]                        && _da+=( --image "$_dr" )
            [ "${ENROLLINATOR_UI_ONTOP:-1}" = "1" ] && _da+=( --ontop )
            [ "${ENROLLINATOR_UI_BLUR:-0}"  = "1" ] && [ "$_use_keeper" = "0" ] && ! _ui_run_blur_keeper_active && _da+=( --blurscreen )
            _ui_user_exec "$DIALOG_BIN" "${_da[@]}"
            local _drc=$?
            case "$_drc" in
                0)  dlg_i=$(( dlg_i + 1 )) ;;
                2)  [ "$dlg_i" -gt 0 ] && dlg_i=$(( dlg_i - 1 )) ;;
                *)  /bin/rm -f "$popup_cmd" 2>/dev/null || true
                    # Close the blur keeper before exiting.  Write quit: to the
                    # command file unconditionally (safe write); only gate the
                    # kill on PID validation — _bk_pid may be the dead launchctl
                    # wrapper rather than the real swiftDialog process.
                    if [ -n "$_bk_cmd" ]; then
                        printf 'quit:\n' >> "$_bk_cmd" 2>/dev/null || true
                        /bin/sleep 0.1
                        if _ui_valid_dialog_pid "$_bk_pid"; then
                            /bin/kill "$_bk_pid" 2>/dev/null || true
                        fi
                        /bin/rm -f "$_bk_cmd" 2>/dev/null || true
                    fi
                    return "$_drc" ;;
            esac
        else
            # ── Final action dialog ─────────────────────────────────────────
            _ui_user_exec "$DIALOG_BIN" "${args[@]}"
            local rc=$?
            # ← Back on the action dialog: return to the last interactive slide.
            if [ "$rc" -eq 2 ] && [ "$_nav_back" -eq 1 ]; then
                dlg_i=$(( dlg_total - 2 ))
                continue
            fi
            /bin/rm -f "$popup_cmd" 2>/dev/null || true
            # Close the blur keeper now that the dialog sequence is done.
            # Same as the error-exit path: quit: is unconditional, kill is gated.
            if [ -n "$_bk_cmd" ]; then
                printf 'quit:\n' >> "$_bk_cmd" 2>/dev/null || true
                /bin/sleep 0.1
                if _ui_valid_dialog_pid "$_bk_pid"; then
                    /bin/kill "$_bk_pid" 2>/dev/null || true
                fi
                /bin/rm -f "$_bk_cmd" 2>/dev/null || true
            fi
            # swiftDialog return codes: 0=button1, 2=button2, 3=infobutton, etc.
            case "$rc" in
                0)  printf '%s' "$b1"; return 0 ;;
                2)  printf '%s' "$b2"; return 0 ;;
                3)  printf '%s' "$b3"; return 0 ;;
                *)  return "$rc" ;;
            esac
        fi
    done
}
