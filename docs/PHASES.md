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
  `LingyueCore`, with `FixtureManifest.json` placeholder. The manifest
  lives at the **package root** (outside any target's source path) so it
  is dev/test bookkeeping only and never ships in the Internal `.app`
  bundle.
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
  Applies `SourceEncoding`, headers, referer, per-host throttle. Cookies
  live in `HTTPCookieStorage.shared` — no custom `cookies.bin` file, no
  hand-rolled cookie sync.
- `WebViewSourceLoader.swift` — `SourceHTMLLoading` over `WKWebView`.
  Wraps the existing `WebRenderingService`. Uses
  `WKWebsiteDataStore.default()` for the web view's cookie jar.
  **Sharing with `HTTPCookieStorage.shared` is not actually automatic**
  despite the public docs implying it is — in practice the two stores
  diverge around HTTP-only cookies, the `Secure` flag, and per-site
  partitioning rules that have shifted across iOS versions. To make
  Cloudflare-style "clear-the-challenge-in-WebView-then-use-URLSession"
  flows reliable, Phase 1 implements an explicit one-way sync:
  after `renderHTML` returns, copy `WKHTTPCookieStore.getAllCookies()`
  into `HTTPCookieStorage.shared` before the snapshot bubbles up. A
  dedicated unit test asserts that a cookie set during a `renderHTML`
  call is readable from a subsequent `URLSession` request to the same
  host. If a future iOS release makes the sharing genuinely automatic,
  drop the sync and rely on the test to keep us honest.
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
   against `source-a`. Tests are **pure-disk**: a stub
   `SourceHTMLLoading` returns canned bytes off the filesystem regardless
   of the URL it is asked for. `source-a/rule.json` uses a synthetic
   hostname like `source-a.invalid.test` so no real host string lands in
   `LingyueCore` or its tests.
2. `xcodebuild -scheme lingyue` succeeds with `LingyueCore` linked.
3. `HTTPSourceLoader` and `WebViewSourceLoader` each have at least one
   unit test that exercises them against a local `URLProtocol` /
   `WKWebView` fixture — no real network calls. Live-host validation is
   deferred to Phase 2, where the `LingyueInternalSources` package owns
   the manifest mapping fixture IDs to real hosts.

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
- One JSON file per source. Add `.process("Resources")` to the target's
  resources list in `Package.swift` so the JSON ships in the Internal
  bundle.
- Update the package-root `FixtureManifest.json` to map `source-a` → real
  host, etc., so Internal-package tests can resolve a fixture ID back to
  its live counterpart for the live-host validation tests. The manifest
  stays **outside any target's source path** — read by tests via the
  package directory's filesystem path, never bundled into the `.app`.

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

Three entry points, same destination. **All UI text, placeholder
content, and demo screenshots must satisfy the Phase 6 invariants
(§6.2–§6.3)** — URL field placeholders use Wikisource not a novel
host; no "popular sources" picker; etc.

- **From scratch.** `Add Source` button → `SourceEditorView` with empty rule.
- **From URL.** User pastes a source homepage; the URL Analyzer (see
  3.2.1) pre-fills as many fields as it can with confidence scores. User
  refines from there.
- **Import JSON rule file (Internal target only).** TestFlight users can
  paste or open a rule JSON exported from another instance or shared by
  the community. **Scope-change note:** the original brief envisioned
  JSON import for both targets, comparable to Legado's source-file
  workflow. App-Store-target review posture made me uncomfortable
  shipping arbitrary-file-import there even though the content is pure
  data, so this revision restricts JSON import to the Internal target
  only. Both targets continue to support in-app authoring. If the
  review-risk read is wrong, surface JSON import in the App Store target
  too — the underlying schema is the same.

#### 3.2.1 URL Analyzer (Auto-fill from homepage)

The "From URL" path is non-trivial — a good autofill closes the gap
between "type a URL" and "have a working source." Pipeline, each step
emits a confidence score for the UI to display next to the field:

- **P1 — Homepage fetch.** Resolve URL, follow redirects, snapshot final
  URL + HTML. If the page only renders under JS, fall back to the
  headless renderer.
- **P2 — Host + path classification.** Derive `hostPatterns` from the
  final URL host (with subdomain wildcarding heuristic). Pull `<title>`
  and `<meta name="description">` for a default `name`.
- **P3 — Search-form discovery.** Look for `<form>` elements with
  `name`/`id` containing `search`, `query`, `q`. Build a candidate
  `urlTemplate` from the form's `action` + input names. Confidence
  drops sharply when there are multiple candidates.
- **P4 — Catalog-shape detection.** Scan for the densest `<a>`-cluster
  on any followable page (chapter lists are always large flat link
  lists). Propose `chaptersSelector` + per-item `titleField` /
  `urlField`. Honour `nofollow` / `aria-hidden` filters.
- **P5 — Chapter-body detection.** Follow one of the proposed chapter
  links; the body is the largest text-density `<div>` in the page.
  Propose `bodyField` with `[.brToNewline, .stripHTML]` defaults.
- **P6 — Confidence UI.** Every proposed selector lands in the editor
  with a small badge: green ≥ 0.8, yellow 0.5–0.8, red < 0.5. User
  sees at a glance what needs review. Save is blocked if any required
  field is red.

This deserves its own scope review before Phase 3 starts — depending on
how robust we want P3–P5 to be, the analyzer can be anything from a
weekend job to a two-week one. The skeleton above commits us to the
pipeline shape and the confidence UX, not to any single heuristic's
sophistication.

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

**Bundle ID strategy.** The canonical bundle ID (whatever the existing
TestFlight build uses, expected `com.lingyue.reader` — verify against the
project file before the phase starts) belongs on the **App Store**
target long-term: the public-facing app should have the clean name, and
the risky/changing build should have the qualified one. So:

A bundle ID maps 1:1 to an App Store Connect app record — you can't
"reuse" an existing ID for a different record. So the strategy below
preserves the existing record for the eventual public App Store launch
and creates a fresh record for the Internal track.

- Existing `lingyue` target is renamed → `LingyueInternal`, **and its
  bundle ID changes** to `com.lingyue.reader.internal` (or `.dev` — pick
  at phase start). This requires creating a **new App Store Connect app
  record** under the new bundle ID, with its own (new, empty) TestFlight.
  Existing testers will need a fresh TestFlight invite to that new app
  and a fresh install. One-time migration cost, paid while the tester
  base is small.
- New `LingyueAppStore` target keeps the canonical `com.lingyue.reader`
  bundle ID. It uploads to the **existing App Store Connect record** —
  the one the current `lingyue` build has been using for TestFlight all
  along. That record's TestFlight history continues; when the App
  Store-safe target is ready, the public submission goes through this
  same record.
**Migration cost is real.** iOS sandboxes by bundle ID — once a build
ships under a new bundle ID, it cannot read the old install's
`Application Support` directory. There is no "probe the legacy
container" trick. The honest path is a four-step sequence:

1. **Final `com.lingyue.reader` TestFlight build (existing record).**
   Before any rename, ship a "Backup library" feature in the current
   `lingyue` target: full export of `LibraryStore.json`,
   `EditableSourceStore.json`, and reader bookmarks into a single
   `.lingyue-backup` file via `UIDocumentPicker` / share sheet. Doubles
   as a general-purpose backup feature. This is the **last build that
   uploads to the existing App Store Connect record via the old `lingyue`
   target shape** — every later upload to that record is the App
   Store-safe target.
2. **Create the new App Store Connect record for Internal.** New bundle
   ID `com.lingyue.reader.internal`, new app in App Store Connect, new
   (empty) TestFlight group. Invite existing testers.
3. **First `LingyueInternal` TestFlight build.** Onboarding step "Import
   previous library" accepts the `.lingyue-backup` file from Files.
   Tester opens the file, the new build hydrates its sandbox. From this
   point on, every upload from the renamed/split project goes to one of
   two records — Internal builds to the new record,
   `LingyueAppStore` builds to the existing `com.lingyue.reader` record.
4. **Existing testers** uninstall the old `com.lingyue.reader` install
   from step 1 once import is verified. New testers (and all future App
   Store users) never see this dance.

Alternatives considered and rejected: App Group container — only helps
if the old build was already using the group, which it wasn't; CloudKit
— too large a lift for a one-time migration. Manual export/import wins
on simplicity and lands a backup feature as a side effect.

**Display name + icon.** Two targets ship two Info.plists, so the
home-screen label is set per target via `CFBundleDisplayName`:

| Target | `CFBundleDisplayName` |
|---|---|
| `LingyueAppStore` | `灵阅书屋` (matches the current app name) |
| `LingyueInternal` | `灵阅小书屋` |

Both apps can coexist on the same device (different bundle IDs = separate
sandboxes), so the suffix is the only way a tester can tell them apart
on the home screen. Pair this with a distinct app icon set for Internal
— a small `DEV` / red-dot overlay on the existing icon is the lowest
effort version. The two icon catalogs live under
`lingyue/Assets.xcassets/AppIcon-AppStore.appiconset` and
`AppIcon-Internal.appiconset`, each target's build settings point at the
right one via `ASSETCATALOG_COMPILER_APPICON_NAME`.
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

This sub-section used to spell out the App Store positioning rules, but
that material has grown enough to deserve its own phase. See **Phase 6
— App Store launch posture** for the full cross-phase invariant
checklist (metadata, in-app affordances, screenshots, review submission
package, ongoing risk management). Phase 5.2 itself is now just: tick
every Phase 6 item before the App Store-safe target's first upload to
the existing `com.lingyue.reader` App Store Connect record.

### 5.3 Internal target stays as-is, modulo the rule library

Each target keeps its own `EditableSourceStore` JSON in its own per-app
sandbox — they do **not** share files. A tester with both apps installed
has two independent rule libraries. The Phase-5.1 `.lingyue-backup` file
format lets the user manually carry rules across when they want, but
there is no automatic sync. Adding cross-target sync (via App Group
container, iCloud CloudKit, or a shared file in
`UIDocumentInteractionController`-accessible storage) is intentionally
deferred — possible future enhancement, not a Phase 5 requirement.

Internal also gets the seeded bundle + fast-path adapters on top, which
the App Store target by definition cannot see.

### 5.4 CI

Add a build job that builds `LingyueAppStore` and runs a multi-surface
scan against the produced `.app` bundle. A symbol-only check via `nm` is
not enough — hostnames almost never appear as symbols; they appear as
string literals embedded in the binary, in bundled JSON/plist resources,
or in compiled asset/string files. The scan covers:

1. **Binary string literals.** `strings -a "$APP/LingyueAppStore"` piped
   through `grep -i -F -f forbidden-hosts.txt`. `forbidden-hosts.txt`
   lives in the repo as **CI/test data**, alongside the scan script
   (e.g. `Scripts/forbidden-hosts.txt`). It is outside every Xcode
   target's file membership — not bundled into the App Store binary,
   and not bundled into the Internal binary either. It exists only for
   the build job to read.
2. **Bundled resources.** `find "$APP" -type f \( -name '*.json' -o
   -name '*.plist' -o -name '*.txt' -o -name '*.strings' \)` and grep
   each against the same forbidden list. Plists get a `plutil -convert
   xml1 -o -` pass first so binary plists are scanned readably.
3. **Asset catalogs.** Decompile `Assets.car` via `assetutil
   --info` and grep filenames / metadata. Belt-and-braces — covers the
   case where a developer accidentally drops a source logo named
   `52shuku.png` into the App Store asset catalog.

Job fails on any match. This is the structural-guarantee teeth — combined
with the compile-time fact that `LingyueAppStore` does not link
`LingyueInternalSources`, no internal host should ever land in the App
Store binary. The CI check catches the only realistic regression: a
developer hard-codes a hostname directly in the App Store target's source.

### Exit criteria for Phase 5

1. Both targets build green in CI.
2. The multi-surface scan (binary `strings`, bundled resources,
   `Assets.car`) on the `LingyueAppStore` `.app` bundle returns zero
   matches against `forbidden-hosts.txt`.
3. `LingyueInternal` TestFlight ships with the new bundle ID; existing
   testers complete the one-time install + data-migration without losing
   their library or rules.
4. App Store submission notes accurately describe the data-only rule
   model: closed selector/transform schema, no code execution from
   rules, no remote code loading, no source list bundled.

---

## Phase 6 — App Store launch posture (cross-phase invariants)

Architecture alone is not enough to keep the App Store target safe. A
reviewer who opens the app and pastes a known pirate URL gets a working
novel reader — that's a 5.2 (IP) rejection regardless of how clean the
rule schema is. The countermeasure is **positioning**: every surface the
reviewer (and future App Store user) touches must look like a
general-purpose web-content reader, not a Chinese-novel piracy tool.

This section is a **checklist of invariants**, not implementation work
— some items are delivered in Phase 3 (UI), some in Phase 5
(metadata/binary), some live entirely in App Store Connect. Tick every
box before submitting to the existing `com.lingyue.reader` record for
public release.

### 6.1 App Store Connect metadata

| Field | App Store target value |
|---|---|
| App name (en) | `Lingyue Reader` |
| App name (zh-Hans) | `灵阅书屋` |
| Subtitle (en) | `Your personal web-content reader` (or similar — no "novel", no "小说", no "fiction") |
| Subtitle (zh-Hans) | `个人网页阅读工具` (no "小说", no "书源") |
| Primary category | **Books.** The app *is* a reader — chapters, bookshelf, reading progress. Categorizing it as News/Productivity would risk Guideline 2.3 (Accurate Metadata). The defense lives in architecture, not category disguise. |
| Keywords | Honest keyword optimization, not misrepresentation: `reader, web, articles, longform, offline, public domain`. Avoid `novel, 小说, 书源, web-novel` not because the app couldn't be used that way, but because those keywords attract the piracy-seeking audience we don't want surfacing in App Store reviews (see §6.5). |
| Description | Truthful: a configurable reader for web content the user has the right to access — blogs, public-domain literature, RSS-style feeds, self-hosted writing. Don't invent capabilities the app doesn't have, don't disguise the ones it does. |
| Languages | English **and** Simplified Chinese. Both first-class. Submitting Chinese-only invites the "Chinese piracy reader" prior. |
| Age rating | Whatever the App Store Connect content questionnaire computes from honest answers. Don't predetermine. |

### 6.2 In-app affordances (Phase 3 deliverables)

- **Empty rule library on first launch.** No bundled rules except item 3
  below. Onboarding shows "Add your first source" with an Add button —
  not a pre-populated list.
- **URL field placeholder text must not reference any pirate-adjacent
  host.** Placeholder shows something like `https://example.com` or
  `https://en.wikisource.org/wiki/...`. Never 笔趣阁, hjwzw,
  novel-named hostnames, etc.
- **Zero bundled rules.** The App Store target ships with an empty
  rule library — no seeded sources, no "demo" rule, no exceptions. "No
  bundled source list, period" is a cleaner defensible posture than
  "no bundled list except this one legitimate exception" — the latter
  invites a reviewer thread on "which exceptions count," and the
  former is a single hard-line statement. Means the CI scan stays
  simple too: any rule-shaped JSON in the App Store `.app` is a fail,
  no allowlist needed.
- **Wikisource as inline example, not as bundled data or a one-tap
  recommendation.** Onboarding's "Add your first source" screen shows
  example URLs (Chinese Wikisource, Project Gutenberg, a tech blog) as
  **plain copyable text** in localized onboarding strings — no one-tap
  "use this URL" button that auto-fills the Add Source flow. The
  conservative read is that an auto-fill button flirts with "the app
  is suggesting a source"; plain copyable text reads unambiguously as
  help copy. The user long-presses to copy (or types manually), then
  pastes into the URL field. From a binary perspective the URL strings
  live in `Localizable.strings`, never in any rule JSON.
- **IP attestation in onboarding.** Before the "Add Source" sheet
  appears for the first time, a one-screen explainer + a tap-to-confirm
  checkbox: "I will only add sources I have the right to access." User
  acknowledgement is logged to `UserDefaults` for our records.
- **No "popular sources" / "community rules" / "recommended" UI.** Not
  in onboarding, not in Settings, not anywhere. Not even commented out
  — `strings` will find it.
- **No "import rule from URL".** Phase 3.2 already restricts JSON-file
  import to Internal. The App Store target also must not have a "paste
  a rule URL to import" affordance — same reviewer signal.
- **Sharing extension scope.** If we add a Share Sheet extension for
  importing pages from Safari, restrict it to extracting page URL +
  title only — do **not** auto-fan-out across enabled sources from the
  extension. Reviewers explore extensions; an extension that
  immediately attempts source detection on a random Safari page is a
  rejection vector.

### 6.3 Screenshots + visual identity

- **Screenshots show only public-domain or clearly-legal content.** Use
  Chinese Wikisource (三国演义, 红楼梦) or Project Gutenberg as the
  user-added source in screenshots. The screenshots demonstrate the
  user-adds-a-source flow — the rule didn't exist when the user
  installed the app; they typed in the URL during onboarding. No
  screenshots of any pirate-adjacent host. No screenshots of the search
  bar finding novel-titled results. No screenshots of the rule editor
  with a recognizable host in the URL field.
- **App icon avoids 小说 / 武侠 / 仙侠 visual tropes.** No scroll-style
  manuscript, no traditional gold-on-red palette evoking a wuxia novel
  cover. A neutral book-and-bookmark mark in a modern flat palette is
  enough.
- **Splash / launch screen** uses the same neutral palette. No demo
  text on launch.

### 6.4 App Store review submission package

Write the review notes once, save in `Scripts/appstore-review-notes.md`,
re-use for every submission:

- One paragraph on what the app is: configurable personal web reader.
- One paragraph on the rule architecture: declarative `Codable` schema
  (`SourceRule`), closed transform enum, **no JavaScript or other code
  execution from user-supplied rules**, no remote code loading, **no
  bundled source list of any kind** — the app installs with an empty
  rule library.
- One paragraph on user responsibility: in-app IP attestation,
  onboarding language.
- Optional: a 30-second screen recording demoing the app — start from
  a fresh install (empty rule library), tap a suggested example URL
  (Chinese Wikisource) in onboarding, watch the Add Source flow
  populate, then read a public-domain work. The "fresh install →
  user-adds-source → reads-Wikipedia-content" arc preempts the
  "are-you-sure-this-isn't-piracy" thread.
- **Do not** mention Lingyue Internal / TestFlight in the App Store
  notes. Those are separate App Store Connect records and bringing them
  up invites questions about the two-target strategy.

### 6.5 Ongoing risk management (post-launch)

- **Monitor App Store reviews for pirate-source mentions.** If a user
  posts "笔趣阁 finally works!" as a review, that visible-to-Apple
  endorsement of piracy use can trigger a takedown. We can't delete user
  reviews, but we can respond as the developer to disclaim. Set up a
  weekly check.
- **No marketing on Chinese novel forums / 贴吧 / Weibo / 小红书 in
  the App Store launch window.** Those audiences are exactly the
  audience that produces the kind of reviews above. Internal/TestFlight
  marketing can target them; App Store marketing should target
  general-purpose-reader audiences (Hacker News, ProductHunt, generic
  iOS/productivity blogs).
- **Restrict curated content, not user-driven features.** Search across
  the user's own added rules — including a unified result page that
  fans out across every enabled source — is a **core App Store target
  feature**. It's what makes a configurable reader useful and what the
  original product brief calls for. The line to hold is on **curated /
  preloaded content**, not on capability:
  - App Store target: user-added rules only. Unified search across the
    user's library is fine. The in-app browser detector is fine.
  - Internal target additionally ships the seeded rule bundle and
    fast-path adapters from `LingyueInternalSources`, plus any "browse
    popular" or "recommended sources" affordance.
  - A feature is App-Store-target-safe if it operates on rules the user
    explicitly added; it's Internal-only if it surfaces sources the app
    chose for them.

### 6.6 Realistic risk

- First submission: probably 50–70% pass rate if every item above is
  ticked. Higher than a Legado port, lower than a slam dunk.
- Most likely rejection: 5.2 (IP) or 4.3 (spam — "another novel
  reader"). Both appealable with positioning revisions, not
  architecture changes.
- Long-term: Apple can pull the app post-launch if pirate use becomes
  visible. Mitigated by §6.5, not eliminated.
- **The decision is whether 50–70% is good enough to attempt.** It is —
  the architecture work in Phases 0–5 is reusable on a worst-case
  rejection-and-resubmit cycle, and the Internal target ships regardless
  of App Store outcome.

### Exit criteria for Phase 6

A single pre-submission checklist PR that ticks every box above with a
concrete commit/file reference. The PR description is what we paste
into App Store Connect's review notes.

---

## Tracking

Each phase exit is a single PR (Phase 1) or a small stack of PRs
(Phases 2–5). PR titles reference the phase: `Phase 2.1: seed
rules for source-a/b/c`. When a phase ships, mark it ✅ DONE here in
the same PR that lands its last commit.
