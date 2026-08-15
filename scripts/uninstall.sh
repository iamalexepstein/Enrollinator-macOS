#!/bin/bash
# scripts/uninstall.sh — remove Enrollinator from a Mac.
#
# Designed to be safe to run more than once. Leaves /var/log/enrollinator.log in
# place for postmortem analysis; delete it manually if you don't want it.

set -e

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

DAEMON="/Library/LaunchDaemons/com.enrollinator.app.plist"
BIN_DIR="/usr/local/enrollinator"

echo "==> Unloading LaunchDaemon"
/bin/launchctl bootout system/com.enrollinator.app 2>/dev/null || true

# In case we're still on a host that had the old LaunchAgent installed,
# clean those up too so the uninstaller is safe across upgrades.
if [ -f "/Library/LaunchAgents/com.enrollinator.app.plist" ]; then
    echo "==> Cleaning up legacy LaunchAgent"
    for uid in $(/usr/bin/dscl . list /Users UniqueID | /usr/bin/awk '$2 >= 500 && $2 < 65000 {print $2}'); do
        /bin/launchctl bootout "gui/$uid/com.enrollinator.app" 2>/dev/null || true
    done
    /bin/rm -f "/Library/LaunchAgents/com.enrollinator.app.plist"
fi

echo "==> Removing files"
/bin/rm -f "$DAEMON"
/bin/rm -rf "$BIN_DIR"

echo "==> Removing state"
/bin/rm -rf /var/tmp/enrollinator
/bin/rm -rf /var/lib/enrollinator
# Pre-1.x layout: command/PID files and the image cache sat loose in /var/tmp
# instead of inside the state directory. Clean those up on upgrade too.
/bin/rm -rf /var/tmp/enrollinator-images
/bin/rm -f  /var/tmp/enrollinator.dialog.log      /var/tmp/enrollinator.dialog.pid \
            /var/tmp/enrollinator.wait.log        /var/tmp/enrollinator.wait.pid \
            /var/tmp/enrollinator.wait.session    /var/tmp/enrollinator.wait-navigating \
            /var/tmp/enrollinator.wait-slideshow.pid \
            /var/tmp/enrollinator.wait-blur-keeper.log \
            /var/tmp/enrollinator.wait-blur-keeper.pid \
            /var/tmp/enrollinator.run-blur-keeper.log \
            /var/tmp/enrollinator.run-blur-keeper.pid \
            /var/tmp/enrollinator.addon-picker.log \
            /var/tmp/enrollinator.popup.log \
            /var/tmp/enrollinator.blur-keeper.log

echo "==> Note: The Enrollinator .mobileconfig is managed by your MDM."
echo "    Remove it there too, or managed prefs will reinstall on next boot."
echo "Done."
