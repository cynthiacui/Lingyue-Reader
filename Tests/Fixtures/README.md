# Tests/Fixtures

Captured pages used to exercise the rule engine offline. Each `source-X/`
folder holds the HTML for one source's representative pages plus an
`expected.json` describing the values a correctly-configured rule should
extract.

## Why neutral IDs

Folders are named `source-a`, `source-b`, `source-c` — not after any
real host. The neutral IDs let the fixtures be checked in without
leaking host strings into `LingyueCore` test code, and grepping the App
Store binary turns up no real source names from fixtures.

## File layout per source

```
source-a/
  homepage.html       optional, used for sniffing baseline behaviour
  search.html         response from a representative search query
  detail.html         representative book detail page
  catalog.html        chapter list page (first page if paginated)
  chapter1.html       first chapter body
  chapter2.html       second chapter body (covers next/prev-chapter linking)
  expected.json       ground truth: what the engine must extract
```

Phase 0 ships placeholder stubs so the directory layout is in place. Real
captures land in Phase 1 alongside the rule engine.
