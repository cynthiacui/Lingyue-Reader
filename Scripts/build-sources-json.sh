#!/usr/bin/env bash
# Assemble bundled `*.json` source-rule files from the seeded rule set
# inside LingyueInternalSources. Two outputs land under `docs/`:
#
#   docs/lingyue-sources.json     — full bundle of all seeded rules
#   docs/lingyue-wikisource.json  — Wikisource only (CC public domain)
#
# Both files share the same envelope shape SourceImportService.decode()
# accepts:
#
#   { "kind": "lingyue-sources", "version": 1, "createdAt": "...",
#     "sources": [ <SourceRule>, ... ] }
#
# Run from the repo root:  Scripts/build-sources-json.sh
#
# The 'example.json' fixture is intentionally skipped — it uses an
# `.invalid.test` host and would just confuse a user who imports the file.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEEDED_DIR="$REPO_ROOT/Packages/LingyueInternalSources/Sources/LingyueInternalSources/Resources/SeededRules"
MAIN_OUTPUT="$REPO_ROOT/docs/lingyue-sources.json"
WIKI_OUTPUT="$REPO_ROOT/docs/lingyue-wikisource.json"

mkdir -p "$(dirname "$MAIN_OUTPUT")"

CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Main bundle: everything except example fixture and wikisource (the
# latter ships as its own file).
MAIN_SOURCES=$(
  find "$SEEDED_DIR" -maxdepth 1 -name '*.json' \
    ! -name 'example.json' \
    ! -name 'wikisource.json' \
    | sort \
    | xargs jq -s '.'
)

jq -n \
  --arg createdAt "$CREATED_AT" \
  --argjson sources "$MAIN_SOURCES" \
  '{
    kind: "lingyue-sources",
    version: 1,
    createdAt: $createdAt,
    sources: $sources
  }' > "$MAIN_OUTPUT"

echo "Wrote $MAIN_OUTPUT"
echo "Source count: $(jq '.sources | length' "$MAIN_OUTPUT")"

# Wikisource-only bundle.
jq -n \
  --arg createdAt "$CREATED_AT" \
  --slurpfile rule "$SEEDED_DIR/wikisource.json" \
  '{
    kind: "lingyue-sources",
    version: 1,
    createdAt: $createdAt,
    sources: $rule
  }' > "$WIKI_OUTPUT"

echo "Wrote $WIKI_OUTPUT"
echo "Source count: $(jq '.sources | length' "$WIKI_OUTPUT")"
