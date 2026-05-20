#!/usr/bin/env bash
# Assemble docs/lingyue-sources.json from the seeded rule set bundled
# inside the LingyueInternalSources package. Output mirrors the shape
# SourceImportService.decode() accepts:
#
#   { "kind": "lingyue-sources", "version": 1, "createdAt": "...",
#     "sources": [ <SourceRule>, ... ] }
#
# Run from the repo root:  Scripts/build-sources-json.sh
#
# The 'example.json' fixture is intentionally skipped — it uses the
# `seeded-example.invalid.test` host and would just confuse a user who
# imports the file.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEEDED_DIR="$REPO_ROOT/Packages/LingyueInternalSources/Sources/LingyueInternalSources/Resources/SeededRules"
OUTPUT="$REPO_ROOT/docs/lingyue-sources.json"

mkdir -p "$(dirname "$OUTPUT")"

# Collect every seeded rule except the test fixture, in filename order so
# the diff stays stable across runs.
SOURCES=$(
  find "$SEEDED_DIR" -maxdepth 1 -name '*.json' ! -name 'example.json' \
    | sort \
    | xargs jq -s '.'
)

CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --arg createdAt "$CREATED_AT" \
  --argjson sources "$SOURCES" \
  '{
    kind: "lingyue-sources",
    version: 1,
    createdAt: $createdAt,
    sources: $sources
  }' > "$OUTPUT"

echo "Wrote $OUTPUT"
echo "Source count: $(jq '.sources | length' "$OUTPUT")"
