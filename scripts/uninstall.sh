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

echo "==> Note: The Enrollinator .mobileconfig is managed by your MDM."
echo "    Remove it there too, or managed prefs will reinstall on next boot."
echo "Done."
