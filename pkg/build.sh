#!/bin/bash
# pkg/build.sh — build a signed distribution .pkg that lays down Enrollinator.
#
# Layout of the produced pkg:
#   /usr/local/enrollinator/enrollinator.sh
#   /usr/local/enrollinator/lib/plist.sh
#   /usr/local/enrollinator/lib/ui.sh
#   /usr/local/enrollinator/lib/plugins.sh
#   /Library/LaunchDaemons/com.enrollinator.app.plist
#
# The .mobileconfig is deployed separately via your MDM. That's the whole
# point: swap configs without rebuilding the pkg.
#
# Usage:
#   pkg/build.sh <version> [signing-identity]
#
# Example:
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
