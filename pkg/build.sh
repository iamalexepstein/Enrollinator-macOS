#!/bin/bash
# pkg/build.sh — build a distribution .pkg that lays down Enrollinator.
#
# Layout of the produced pkg:
#   /usr/local/enrollinator/enrollinator.sh
#   /usr/local/enrollinator/lib/plist.sh
#   /usr/local/enrollinator/lib/ui.sh
#   /usr/local/enrollinator/lib/plugins.sh
#   /Library/LaunchDaemons/com.enrollinator.app.plist
#
# Config options (mutually exclusive; MDM profile takes priority if both present):
#   Option A — MDM profile (recommended):
#     Deploy a .mobileconfig via your MDM separately. The script reads managed
#     prefs from com.enrollinator.app at runtime. Swap configs without rebuilding.
#
#   Option B — Bundled XML:
#     Drop enrollinator.xml next to this script before building:
#       cp /path/to/config.xml enrollinator.xml && pkg/build.sh 1.0.0
#     The file is installed at /usr/local/enrollinator/enrollinator.xml and
#     auto-discovered at runtime (no flags needed). Useful when MDM profile
#     deployment isn't available or for self-contained test packages.
#
# Usage:
#   pkg/build.sh <version> [signing-identity]
#
# Example:
#   pkg/build.sh 1.0.0
#   pkg/build.sh 1.0.0 "Developer ID Installer: Example, Inc. (ABCDE12345)"

set -euo pipefail

VERSION="${1:-0.0.0}"
SIGN_IDENTITY="${2:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/build"
ROOTFS="${BUILD}/root"
OUT="${BUILD}/Enrollinator-${VERSION}.pkg"

IDENTIFIER="com.enrollinator.app.pkg"

echo "==> Cleaning ${BUILD}"
/bin/rm -rf "$BUILD"
/bin/mkdir -p "$ROOTFS/usr/local/enrollinator/lib"
/bin/mkdir -p "$ROOTFS/Library/LaunchDaemons"

echo "==> Staging files"
/usr/bin/install -m 0755 "$ROOT/enrollinator.sh"          "$ROOTFS/usr/local/enrollinator/enrollinator.sh"
/usr/bin/install -m 0644 "$ROOT/lib/plist.sh"         "$ROOTFS/usr/local/enrollinator/lib/plist.sh"
/usr/bin/install -m 0644 "$ROOT/lib/ui.sh"            "$ROOTFS/usr/local/enrollinator/lib/ui.sh"
/usr/bin/install -m 0644 "$ROOT/lib/plugins.sh"       "$ROOTFS/usr/local/enrollinator/lib/plugins.sh"
/usr/bin/install -m 0644 "$ROOT/launchd/com.enrollinator.app.plist" \
                         "$ROOTFS/Library/LaunchDaemons/com.enrollinator.app.plist"

# Enforce root:wheel ownership on all staged files. pkgbuild --ownership
# recommended inherits build-time metadata, which may be wrong in CI
# environments that run as an unprivileged user. Explicit chown ensures the
# sourced lib/*.sh files are not world-writable after installation.
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    /usr/sbin/chown -R root:wheel "$ROOTFS"
else
    echo "==> WARNING: not running as root — file ownership in the pkg may be wrong."
    echo "==>          Run 'sudo pkg/build.sh' for a production build."
fi

# Bundle enrollinator.xml if present alongside this script (Option B above).
if [ -f "${ROOT}/enrollinator.xml" ]; then
    echo "==> Bundling enrollinator.xml"
    /usr/bin/install -m 0644 "${ROOT}/enrollinator.xml" \
                             "$ROOTFS/usr/local/enrollinator/enrollinator.xml"
else
    echo "==> No enrollinator.xml found — config will be read from managed prefs at runtime"
fi

echo "==> Building component pkg"
/usr/bin/pkgbuild \
    --root "$ROOTFS" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --ownership recommended \
    --install-location "/" \
    "$OUT"

if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Signing with: $SIGN_IDENTITY"
    local_signed="${OUT%.pkg}-signed.pkg"
    /usr/bin/productsign --sign "$SIGN_IDENTITY" "$OUT" "$local_signed"
    /bin/mv "$local_signed" "$OUT"
fi

echo "==> Done: $OUT"
