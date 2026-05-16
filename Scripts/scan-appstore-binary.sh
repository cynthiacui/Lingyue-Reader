#!/usr/bin/env bash
# Phase 5.4 — multi-surface scan against a built LingyueAppStore .app
# bundle. Greps the binary `strings`, all bundled text resources, and
# the asset catalog metadata against Scripts/forbidden-hosts.txt.
#
# Exit status: 0 if no matches, 1 if any forbidden host found, 2 on
# argument / environment errors. Designed to be called from a CI job.
#
# Usage: Scripts/scan-appstore-binary.sh <path/to/LingyueAppStore.app>
#
# Example (after `xcodebuild ... build`):
#   APP="$(find ~/Library/Developer/Xcode/DerivedData/lingyue-*/Build/Products \
#       -name 'LingyueAppStore.app' -type d | head -n1)"
#   Scripts/scan-appstore-binary.sh "$APP"

set -euo pipefail

APP="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS_FILE="$SCRIPT_DIR/forbidden-hosts.txt"

if [[ -z "$APP" ]]; then
    echo "usage: $0 <path/to/LingyueAppStore.app>" >&2
    exit 2
fi

if [[ ! -d "$APP" ]]; then
    echo "error: '$APP' is not a directory" >&2
    exit 2
fi

if [[ ! -f "$HOSTS_FILE" ]]; then
    echo "error: forbidden-hosts list not found at $HOSTS_FILE" >&2
    exit 2
fi

# Strip comments + blank lines for grep -F input. Stored as a temp
# file so we can reuse it across all three scan arms.
PATTERNS="$(mktemp)"
trap 'rm -f "$PATTERNS"' EXIT
grep -vE '^\s*(#|$)' "$HOSTS_FILE" > "$PATTERNS"

if [[ ! -s "$PATTERNS" ]]; then
    echo "error: forbidden-hosts list is empty after stripping comments" >&2
    exit 2
fi

FAIL=0
report_hit() {
    local surface="$1"
    local detail="$2"
    echo "FORBIDDEN_HOST in $surface: $detail" >&2
    FAIL=1
}

# Arm 1: binary string literals.
# Scan the main binary and any sibling .debug.dylib next to it. We use
# `strings -a` to dump every printable run; `grep -i -F` matches case-
# insensitively against the patterns. Each match line surfaces the
# offending host so CI logs are actionable without re-running.
scan_binary() {
    local bin="$1"
    [[ -f "$bin" ]] || return 0
    local hits
    if hits="$(strings -a "$bin" | grep -i -F -f "$PATTERNS" || true)"; then
        if [[ -n "$hits" ]]; then
            while IFS= read -r line; do
                report_hit "binary($(basename "$bin"))" "$line"
            done <<< "$hits"
        fi
    fi
}

APP_NAME="$(basename "$APP" .app)"
scan_binary "$APP/$APP_NAME"
for dylib in "$APP/$APP_NAME.debug.dylib" "$APP"/*.dylib; do
    scan_binary "$dylib"
done

# Arm 2: bundled text resources. Plists may be binary, so convert
# in-place via `plutil -convert xml1 -o -` before grepping. Skip
# Assets.car (handled by arm 3) and the main Info.plist's
# CFBundleDisplayName, which is allowed to contain the app name.
scan_resource() {
    local file="$1"
    local content
    case "$file" in
        *.plist)
            content="$(plutil -convert xml1 -o - "$file" 2>/dev/null || cat "$file")"
            ;;
        *)
            content="$(cat "$file")"
            ;;
    esac
    local hits
    if hits="$(printf '%s\n' "$content" | grep -i -F -f "$PATTERNS" || true)"; then
        if [[ -n "$hits" ]]; then
            while IFS= read -r line; do
                report_hit "resource(${file#$APP/})" "$line"
            done <<< "$hits"
        fi
    fi
}

while IFS= read -r -d '' file; do
    scan_resource "$file"
done < <(find "$APP" -type f \( \
    -name '*.json' -o \
    -name '*.plist' -o \
    -name '*.txt' -o \
    -name '*.strings' \
\) -print0)

# Arm 3: asset catalog metadata. `assetutil --info` is undocumented but
# stable across recent Xcode releases; it emits a JSON array describing
# every asset (filename, idiom, scale, size, etc.). We grep that JSON
# for forbidden host substrings — catches the case where a source logo
# named "52shuku.png" or similar lands in the asset catalog.
ASSETS_CAR="$APP/Assets.car"
if [[ -f "$ASSETS_CAR" ]]; then
    if command -v assetutil >/dev/null 2>&1; then
        info="$(assetutil --info "$ASSETS_CAR" 2>/dev/null || true)"
        hits="$(printf '%s\n' "$info" | grep -i -F -f "$PATTERNS" || true)"
        if [[ -n "$hits" ]]; then
            while IFS= read -r line; do
                report_hit "assets(Assets.car)" "$line"
            done <<< "$hits"
        fi
    else
        echo "warning: assetutil not on PATH; skipping Assets.car scan" >&2
    fi
fi

if [[ "$FAIL" -ne 0 ]]; then
    echo "scan FAILED: at least one forbidden host found in $APP" >&2
    exit 1
fi

echo "scan OK: no forbidden hosts in $APP"
