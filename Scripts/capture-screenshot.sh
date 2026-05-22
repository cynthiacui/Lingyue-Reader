#!/usr/bin/env bash
# Capture the currently booted iOS simulator's screen to
# docs/screenshots/<name>.png. Used when refreshing the README's
# visual tour after UI changes.
#
# Usage:  Scripts/capture-screenshot.sh <name>
# Example: Scripts/capture-screenshot.sh 01-bookshelf

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <name>" >&2
  echo "example: $0 01-bookshelf  →  docs/screenshots/01-bookshelf.png" >&2
  exit 64
fi

NAME="$1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/docs/screenshots/$NAME.png"

mkdir -p "$(dirname "$OUT")"
xcrun simctl io booted screenshot "$OUT"
echo "Wrote $OUT"
