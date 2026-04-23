#!/bin/bash
# lib/plist.sh — helpers for reading Enrollinator's managed preferences.
#
# Enrollinator's configuration lives in a .mobileconfig that macOS merges into
# the `com.enrollinator.app` defaults domain. We export that domain to a temp
# plist file once, then walk it with /usr/libexec/PlistBuddy.
#
# PlistBuddy can't enumerate an array's length directly, so we probe
# incrementing indices until PlistBuddy returns an error. That pattern is
# the `plist_array_keys` function below.

PLB=/usr/libexec/PlistBuddy

# Exports the managed prefs for Enrollinator into a temp file, printing the path
# on stdout. The caller is responsible for deleting the file when done.
plist_export_managed() {
    local domain="${1:-com.enrollinator.app}"
    local tmp
    # Do NOT append an extension after mktemp — that produces a second,
    # non-atomically-created path that is vulnerable to a symlink race.
    # defaults export and PlistBuddy work fine without a .plist suffix.
    tmp="$(/usr/bin/mktemp -t enrollinator-prefs)"
    # `defaults export` writes a plist to the given path.
    /usr/bin/defaults export "$domain" "$tmp" 2>/dev/null || {
        # If nothing is set, defaults export exits non-zero; create an empty plist.
        /bin/cat >"$tmp" <<'EMPTY'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
EMPTY
    }
    echo "$tmp"
}

# plist_get <file> <keypath>
# Prints the value at the keypath (e.g. ":Branding:Title"). Prints nothing
# on missing key. Never exits non-zero — callers check for empty output.
plist_get() {
    local file="$1" keypath="$2"
    "$PLB" -c "Print $keypath" "$file" 2>/dev/null
}

# plist_exists <file> <keypath>
# Returns 0 if the key exists, 1 otherwise.
plist_exists() {
    local file="$1" keypath="$2"
    "$PLB" -c "Print $keypath" "$file" >/dev/null 2>&1
}

# plist_bool <file> <keypath> [default:false]
# Prints "true" or "false". Empty/missing returns the default.
plist_bool() {
    local file="$1" keypath="$2" default="${3:-false}"
    local v
    v="$(plist_get "$file" "$keypath")"
    case "$v" in
        true) echo "true" ;;
        false) echo "false" ;;
        "") echo "$default" ;;
        *) echo "$default" ;;
    esac
}

# plist_array_count <file> <keypath>
# Prints the number of elements in the array at keypath (0 if missing).
# Uses binary probe — fast enough for the small arrays we deal with.
plist_array_count() {
    local file="$1" keypath="$2"
    local lo=0 hi=1
    # Not an array? Return 0.
    plist_exists "$file" "$keypath:0" || { echo 0; return; }
    # Exponential grow to find a failing index.
    while plist_exists "$file" "${keypath}:$hi"; do
        lo=$hi
        hi=$((hi * 2))
    done
    # Binary search between lo (exists) and hi (missing).
    while [ $((hi - lo)) -gt 1 ]; do
        local mid=$(( (lo + hi) / 2 ))
        if plist_exists "$file" "${keypath}:$mid"; then
            lo=$mid
        else
            hi=$mid
        fi
    done
    echo $((lo + 1))
}
