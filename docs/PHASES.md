# Lingyue source-engine migration: phase plan

Locked plan for migrating Lingyue from a single-target app with hard-coded
source adapters into a two-target app (App Store-safe + Internal/TestFlight)
backed by a declarative rule engine. Phase 0 has landed; Phases 1–5 are
the remaining work. This document is the source of truth — when a phase
diverges from what's written here, update this file in the same PR.

## Architecture context

Three load-bearing decisions everything else flows from:

1. **Module-based boundary, not directory naming.** `LingyueCore` is the
   only rule-engine module the App Store target links. `LingyueInternalSources`
   carries everything that names a specific external source (hostnames,
   seeded rules, fast-path adapters). The boundary is compile-time — code
   outside `LingyueCore` cannot accidentally leak into the App Store
   binary because the App Store target has no edge to that module.

2. **Rules are pure data, never code.** `SourceRule` is a `Codable` schema
   of selectors, regexes, and a closed `SourceTransform` enum. The engine
   interprets rules; the app never `eval`s anything. This is what lets us
   ship the rule editor to the App Store.

3. **Three-layer protocol split.** `BookSource` is what runtime consumers
   see (one usable source). `BookSourceRegistry` is the aggregator
   (Discovery, detector). `EditableSourceStore` is the editing surface
   (Settings → Sources). Editing concerns stay orthogonal to runtime
   concerns.

## Naming

- `lingyue` (existing Xcode target) — becomes the **Internal/TestFlight**
  app target. Renamed in Phase 5 to `LingyueInternal`.
- `LingyueAppStore` — new App Store target created in Phase 5. Depends on
  `LingyueCore` only.
- `LingyueCore` — SPM package, no UIKit/WebKit. The whole rule-engine surface.
- `LingyueInternalSources` — SPM package. Internal-only seeded sources +
  fast-path adapters. Only `LingyueInternal` links it.

---

## Phase 0 — Scaffold packages and protocol surface ✅ DONE

Landed as `5b87ac6 Scaffold Phase 0: LingyueCore + LingyueInternalSources packages`.

Deliverables now on `main`:

- `Packages/LingyueCore/` SPM package with SwiftSoup pinned at 2.7.5.
  - 4 protocols: `BookSource`, `BookSourceRegistry`, `EditableSourceStore`,
    `SourceHTMLLoading`.
  - 12 model files: `SourceRule`, `SourceCapabilities`, `EnginePerStep`,
    `SourceEncoding`, `SourceRequest`, `WebPageSnapshot`, `BookSearchResult`,
    `BookDetail`, `BookDetection`, `ChapterLink`, `ChapterContent`,
    `SourceTransform`.
  - `BookSourceError` enum.
  - 3 passing smoke tests (`SourceRuleTests`).
- `Packages/LingyueInternalSources/` SPM package, empty stub depending on
  `LingyueCore`, with `FixtureManifest.json` placeholder.
- `Tests/Fixtures/source-{a,b,c}/` placeholder HTML + `expected.json`.
- `lingyue.xcodeproj` untouched. Still builds.

Exit criteria (all met): `swift build` in both packages, `swift test` in
both, `xcodebuild -scheme lingyue` succeeds.

---

## Phase 1 — Rule engine + loader adapters

**Goal:** make `RuleBasedBookSource` real. Given a `SourceRule` and a
`SourceHTMLLoading`, it must serve `search`/`detail`/`catalog`/`chapter`
end-to-end against the fixture HTML in `Tests/Fixtures/`.

### 1.1 Rule engine in `LingyueCore`

New files under `Packages/LingyueCore/Sources/LingyueCore/Engine/`:

- `SelectorEngine.swift` — wraps SwiftSoup. Resolves a `FieldSelector`
  against an `Element` or `Document`: pick element, read attribute (or
  `text`), apply transform chain. Returns `String?`. Handles `nil` selector
  ("operate on page as a whole") by passing the raw HTML or final URL.
- `TransformApplier.swift` — applies a `[SourceTransform]` chain. One
  switch over the closed enum. Regex transforms compile lazily; invalid
  patterns throw `parseFailed(field:)`.
- `RuleBasedBookSource.swift` — the `BookSource` conformer driving rules.
  - `id = "rule:\(rule.id.uuidString)"`, `displayName = rule.name`,
    `capabilities = rule.capabilities`.
  - `search(_:)`: substitute `{query}`, dispatch via per-step engine,
    parse results list with `SelectorEngine`, emit `BookSearchResult`s.
  - `detectBook(in:)`: host glob + path regex + confirm selector. Returns
    `BookDetection` with computed confidence.
  - `fetchDetail`, `fetchCatalog`, `fetchChapter`: straightforward
    selector-driven extraction. Catalog and chapter both honour the
    `nextPageField` / `nextBodyPageField` pagination cap.
- `URLTemplate.swift` — tiny `{query}` substitutor with percent-encoding.
  Reject templates that reference unknown placeholders so authoring errors
  surface at save time, not runtime.

### 1.2 Loader adapters in the app target

New files under `lingyue/Sources/` (Phase 5 reshuffles this):

- `HTTPSourceLoader.swift` — `SourceHTMLLoading` over `URLSession`.
  Applies `SourceEncoding`, headers, referer, per-host throttle, cookie jar.
- `WebViewSourceLoader.swift` — `SourceHTMLLoading` over `WKWebView`.
  Wraps the existing `WebRenderingService`. Uses `WKWebsiteDataStore.default()`
  so Cloudflare cookies persist between calls.
- `CompositeSourceLoader.swift` — chooses HTTP vs. web per `SourceRequest`
  based on the rule's `enginePerStep`. The engine asks the composite, not
  the two flavours.

### 1.3 Fixture-driven engine tests

Fill in `Tests/Fixtures/source-a/` first (one captured set is enough for
Phase 1 sign-off; b and c come in Phase 2):

- Capture homepage / search / detail / catalog / chapter1 / chapter2 from
  a single representative source. Strip query strings and any
  user-identifiable cookies before committing.
- Author the `SourceRule` JSON that should extract from this set. Commit
  it under `Tests/Fixtures/source-a/rule.json`.
- Fill in `expected.json` with the values the engine must produce.
- Add `LingyueCoreTests/RuleEngineFixtureTests.swift` that loads the rule,
  runs each step through the engine with a stub `SourceHTMLLoading` that
  serves files off disk, and asserts equality with `expected.json`.

### 1.4 Wire `LingyueCore` into the Xcode project

- Add `Packages/LingyueCore` as a local SPM dependency of the `lingyue`
  target via the project editor.
- Do **not** add `LingyueInternalSources` yet — Phase 2 wires it.
- No call-site changes in this phase. The existing `BookImportService`
  keeps working as-is; the rule engine sits beside it.

### Exit criteria for Phase 1

1. `swift test` in `LingyueCore` passes, including the new fixture tests
   against `source-a`.
2. `xcodebuild -scheme lingyue` succeeds with `LingyueCore` linked.
3. A throwaway debug menu entry (in `#if DEBUG`) can load `source-a`'s
   rule, run `search("漫游")` end-to-end via `HTTPSourceLoader`, and print
   results. Verifies the loader adapter works against the live host.

### Risks for Phase 1

- **SwiftSoup performance on large catalogs.** Mitigate by parsing once
  per page and reusing the `Document` across selectors.
- **Encoding-sniffing edge cases.** GB18030 sites often misdeclare. The
  `auto` path should consult `Content-Type`, then BOM, then a meta-tag
  scan, then fall back to UTF-8. Document the order in
  `HTTPSourceLoader.swift`.

---

## Phase 2 — Fill `LingyueInternalSources`

**Goal:** seed the Internal target with rules + fast-path adapters that
match every source the existing app currently supports.

### 2.1 Seeded rule bundles

- For each existing source the current `BookImportService` handles, author
  a `SourceRule` and check it in under
  `Packages/LingyueInternalSources/Sources/LingyueInternalSources/Resources/SeededRules/`.
- One JSON file per source. The package's `Package.swift` already lists
  the directory as a processed resource via `FixtureManifest.json` — add
  a `.process("Resources")` line so the JSON ships in the bundle.
- Update `FixtureManifest.json` to map `source-a` → real host, etc., so
  the fixture-bound tests can find their real-world counterpart.

### 2.2 Fast-path adapters where rules can't reach

Some current sources have bespoke parsing (header-stitched cookies,
multi-step POST forms, custom decoders) that the rule schema can't yet
express. Move those adapters here as direct `BookSource` conformers:

- `Packages/LingyueInternalSources/Sources/LingyueInternalSources/Adapters/`
- Name them `HJWZWBookSource`, etc., as `internal:hjwzw` IDs.
- Each gets fixture-driven tests under `source-b`, `source-c`.

### 2.3 Two registries

- `Packages/LingyueInternalSources/Sources/LingyueInternalSources/InternalSourceRegistry.swift`
  — `BookSourceRegistry` conformer. Merges:
  1. Bundled `SourceRule`-derived sources (built via `RuleBasedBookSource`
     from `Resources/SeededRules/`).
  2. Fast-path adapters from 2.2.
  3. User-authored rules from `EditableSourceStore`.
  - Priority order: user rules → bundled rules → fast-path adapters. User
    overrides win, which is how a user can patch a broken seeded rule
    without waiting for an app update.

- `lingyue/Sources/AppStoreSourceRegistry.swift` (lives in app target, but
  imports only `LingyueCore`) — `BookSourceRegistry` conformer. Returns
  only user-authored rules from `EditableSourceStore`. This is the registry
  the App Store target will use in Phase 5.

### 2.4 `EditableSourceStore` implementation

- `lingyue/Sources/FileEditableSourceStore.swift` — JSON file at
  `Application Support/Lingyue/user-sources.json`, atomic write via
  `Data.write(options: .atomic)`. One source of truth for both targets.

### Exit criteria for Phase 2

1. Every fixture set (`source-a`, `source-b`, `source-c`) has captured
   HTML + rule + `expected.json` and passes fixture tests.
2. `InternalSourceRegistry.enabledSources()` returns a non-empty list at
   app launch.
3. The current `BookImportService` is migrated to call
   `InternalSourceRegistry.source(withID:)` internally — same UX, new
   plumbing. Behind a `UserDefaults` flag for one TestFlight cycle so we
   can A/B against the old path.

---

## Phase 3 — Rule editor UI + Discovery search integration

**Goal:** users can author and edit rules in-app, and rule-driven sources
appear in Discovery search alongside seeded ones.

### 3.1 Settings → Sources screen

- `lingyue/Views/Settings/SourcesListView.swift` — lists every editable
  rule from `EditableSourceStore`, with enable/disable toggle, priority
  drag, "Test" button.
- `lingyue/Views/Settings/SourceEditorView.swift` — form-driven editor
  over the `SourceRule` schema. Every field has inline help.
  Encoding/transform pickers expose only the closed enum cases — no
  free-text code entry anywhere.
- `lingyue/Views/Settings/SourceTestSheet.swift` — runs the rule against
  a user-pasted URL, shows what each selector resolves to. The crucial
  authoring affordance.

### 3.2 Add Source flow

Two entry points, same destination:

- **From scratch.** `Add Source` button → `SourceEditorView` with empty rule.
- **From URL.** User pastes a source homepage; we pre-fill `homepage`,
  `hostPatterns`, and run a heuristic that pre-fills common selectors
  (`<title>`, `meta[name=description]`, the most chapter-list-like `<ul>`,
  etc.). User refines from there.

No "import rule JSON file" affordance — App Store reviewers treat
arbitrary-rule-file import as a code-injection vector, even though our
rules can only declare data. Authoring stays in-app.

### 3.3 Discovery search bar fan-out

- `lingyue/Views/DiscoverySearchBar` already exists. Change its source list
  from the hard-coded array to `registry.searchableSources()`.
- Result rows already group by source. Keep the grouping; switch the
  source-name source-of-truth to `BookSource.displayName`.
- Browser-only rules (`supportsSearch = false`) never appear here. Their
  entry point is the in-app browser (Phase 4).

### Exit criteria for Phase 3

1. A user can create a new rule for a brand-new source through the editor
   alone, test it on a real URL, save it, and see it light up in Discovery.
2. Editing a seeded rule produces a user override (stored in
   `EditableSourceStore`) without mutating the bundled JSON.
3. UI strings are localized in `Localizable.strings` for both `en` and
   `zh-Hans`.

---

## Phase 4 — In-app browser import via detection

**Goal:** as the user browses freely in the in-app web view, every page
load is checked against every enabled source. When something matches, an
Import button appears.

### 4.1 Detector pipeline

- `lingyue/Views/InAppBrowser/PageDetector.swift` — on `WKNavigationDelegate
  didFinish`, snapshot the page via existing rendering helpers, build a
  `WebPageSnapshot`, fan it out across `registry.enabledSources()`'s
  `detectBook(in:)` calls. Pick the highest-confidence non-nil. Show
  Import button with `"Import from \(detection.sourceID)"`.
- Cache per-URL detection results for the back/forward navigation case.

### 4.2 Import action

- Tap → call `BookImportService` with `detection.detailURL` and the
  detection's `sourceID`. Existing import flow continues from there.
- Failure paths (`sourceBlocked`, `rateLimited`) surface a translated
  message and keep the user on the page.

### Exit criteria for Phase 4

1. Browser-only sources (Cloudflare-gated etc.) import successfully via
   browser → detect → import.
2. Two sources that claim the same page (same host, ambiguous path)
   resolve deterministically via confidence + registry priority.
3. Detection adds no perceptible latency on page load. Budget: ≤ 30ms p95
   for fan-out across 20 enabled sources, off the main thread.

---

## Phase 5 — Two app targets

**Goal:** ship `LingyueAppStore` and `LingyueInternal` from the same
project, with the App Store binary genuinely incapable of touching any
internal-only code.

### 5.1 Xcode target split

- Rename existing `lingyue` target → `LingyueInternal` in the project
  file. Keep the bundle ID the same for now (TestFlight continuity).
- Create new `LingyueAppStore` target. Bundle ID `com.lingyue.appstore`,
  new App Store Connect record.
- Both targets share most of `lingyue/` source files. The split is:
  - Files that import `LingyueInternalSources` → `Internal` target only.
    Add a tiny header comment listing the import for grep-friendliness,
    plus a CI lint that fails if an `Internal`-only file gets added to
    `LingyueAppStore`'s membership list.
  - Files that build the `BookSourceRegistry` differ: `Internal` wires up
    `InternalSourceRegistry`; `AppStore` wires up `AppStoreSourceRegistry`.
  - `BookImportService` differs trivially in the two targets — accepts a
    `BookSourceRegistry`, doesn't care which one.

### 5.2 App Store posture polish

- Onboarding for `LingyueAppStore` explains the "bring your own rules"
  model. No pre-seeded rules. No mention of specific source names.
- "Add Source from URL" is the only entry path. The screen accepts any URL.
- App Store review notes: rules are user-authored Codable data; the app
  interprets a closed selector/transform schema; no code execution from
  rules; no remote code loading; no source list bundled.

### 5.3 Internal target stays as-is

Reads the same `EditableSourceStore` file as the App Store target, so a
user moving between TestFlight and App Store builds keeps their rules.
Internal also gets the seeded bundle + fast-path adapters on top.

### 5.4 CI

- Add a build job that builds `LingyueAppStore` and runs
  `nm -gU $BINARY | grep -i <real source host>` against the output. Job
  fails on any match. This is the structural guarantee teeth.

### Exit criteria for Phase 5

1. Both targets build green in CI.
2. Symbol-grep check on `LingyueAppStore` binary returns zero matches
   against the internal host list.
3. TestFlight build of `LingyueInternal` ships unchanged from current
   behaviour.
4. App Store submission notes accurately describe the data-only rule
   model.

---

## Tracking

Each phase exit is a single PR (Phase 1) or a small stack of PRs
(Phases 2–5). PR titles reference the phase: `Phase 2.1: seed
rules for source-a/b/c`. When a phase ships, mark it ✅ DONE here in
the same PR that lands its last commit.
