#!/bin/bash
# pkg/bundle.sh — produce a single self-contained enrollinator-standalone.sh
# with all lib files inlined.
#
# The result can be uploaded directly to Jamf's script repository and run
# as a policy script — no pkg, no lib directory needed.  Config is still
# delivered the same ways as the pkg version:
#
#   MDM profile  — com.enrollinator.app managed preferences (Option A)
#   Bundled XML  — pass --xml /path/to/config.plist  (Option B)
#
# Usage:
#   pkg/bundle.sh
#
# Output:
#   build/enrollinator-standalone.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${ROOT}/build"
SRC="${ROOT}/enrollinator.sh"
OUT="${BUILD}/enrollinator-standalone.sh"

mkdir -p "$BUILD"

echo "==> Building standalone script"

{
    # Process enrollinator.sh line-by-line, replacing each lib source line
    # with the actual content of the referenced file.
    while IFS= read -r line; do
        # Match:  . "${ENROLLINATOR_LIB}/plist.sh"  (with optional shellcheck comment above)
        if [[ "$line" =~ ^\.[[:space:]]+\"\$\{ENROLLINATOR_LIB\}/([a-zA-Z_-]+\.sh)\" ]]; then
            lib="${BASH_REMATCH[1]}"
            libpath="${ROOT}/lib/${lib}"
            if [ ! -f "$libpath" ]; then
                echo "ERROR: lib file not found: $libpath" >&2
                exit 1
            fi
            echo "# ── lib/${lib} (inlined by bundle.sh) $(printf '─%.0s' {1..40})"
            # Strip the shebang from lib files (they're not standalone scripts).
            sed '1{/^#!/d;}' "$libpath"
            echo "# ── end lib/${lib} $(printf '─%.0s' {1..52})"
        elif [[ "$line" =~ ^#[[:space:]]*shellcheck[[:space:]]+source=lib/ ]]; then
            # Drop shellcheck source directives — they're only meaningful when
            # the libs are separate files.
            :
        else
            echo "$line"
        fi
    done < "$SRC"
} > "$OUT"

chmod +x "$OUT"
echo "==> Done: ${OUT}"
echo ""
echo "Deploy via Jamf:"
echo "  1. Upload ${OUT} to Jamf Pro → Settings → Computer Management → Scripts"
echo "  2. Create a policy that runs this script with trigger: Enrollment Complete"
echo "  3. Because Jamf injects \$1–\$3, use a wrapper policy script:"
echo ""
echo "     #!/bin/bash"
echo "     until [ -f /usr/local/bin/dialog ]; do sleep 2; done"
echo "     /path/to/enrollinator-standalone.sh"
echo ""
echo "     Or copy the standalone script to a known path first, then call it."
