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
- One JSON file per source. Add `.copy("Resources/SeededRules")` to the
  target's resources list in `Package.swift` so the JSON ships in the
  Internal bundle with its subdirectory preserved — `.process` would
  flatten the directory structure, dropping the per-rule namespacing.
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

1. Every fixture set has captured HTML + rule + parse assertions and
   passes fixture tests.
   - **Status (done):** 9 seeded rules ship under
     `LingyueInternalSources/Resources/SeededRules/` —
     `sto9.json`, `tongrenquan.json` (Phase 2.5 prototypes), plus
     `trxs.json`, `powanjuan.json`, `52shuku.json`, `zhswx.json`,
     `xbanxia.json`, `nunu.json`, `xsw.json` (Phase 2 batch). Each has
     paired fixture HTML under
     `LingyueCore/Tests/.../Fixtures/phase-2.5/<slug>/search.html` and
     is exercised by `Phase2SeededRuleTests` /
     `Phase25PrototypeTests` end-to-end against `RuleBasedBookSource`.
     All 28 LingyueCore tests + 51 LingyueInternalSources tests pass.
   - **Deferred to fast-path adapters (2.2):**
     - `笔趣阁小说` (`m.bqgl.cc`) — search endpoint returns JSON
       (`articlename` / `url_list` / `author` / `intro`), not HTML; the
       rule schema only speaks SwiftSoup selectors. Needs either a
       schema extension (`jsonPath` field type) or an adapter.
     - `大尾笔趣阁` (`daweixs.com`) — returns 403 to the standard
       browser-shaped curl request used by `RuleBasedBookSource`.
       Production iOS hits it through a different code path; needs
       investigation (likely cookie/header tightening) and possibly an
       adapter.
     - `无忧书城` (`51shucheng.net`) — same 403 symptom as `daweixs`.
     - `黄金屋中文` (`tw.hjwzw.com`) — `BookImportService` already flags
       HJWZW catalog/chapter as needing an adapter (cookie-stitched
       navigation, partial in-page chapter lists). Search via curl
       returns the homepage layout despite a documented `/List/{query}`
       contract — production app gets real results, so this is a
       header/session quirk rather than a dead source. Defer to 2.2.
     - `就爱读小说` (`5dxs.net`) and `ESJ轻小说` (`esjzone.cc`) — not
       captured in this batch; rules can be authored from the legacy
       parser's selectors but were skipped for scope.
2. `InternalSourceRegistry.enabledSources()` returns a non-empty list at
   app launch.
   - **Status (done):** `SeededRuleLoader.testBundledRulesDecodeCleanly`
     confirms all 10 bundled rules (9 sources + 1 example) decode.
     Registry composition test in
     `InternalSourceRegistryTests` verifies user rules + bundled rules
     + fast-path adapters merge correctly with UUID dedup. Bumped
     `LingyueInternalSources.bundledRulesVersion` from 1 → 2 to mark
     the Phase 2 batch.
3. The current `BookImportService` is migrated to call
   `InternalSourceRegistry.source(withID:)` internally — same UX, new
   plumbing. Behind a `UserDefaults` flag for one TestFlight cycle so we
   can A/B against the old path.
   - **Status (in-progress):** shadow-route is wired for Biquge catalog,
     Biquge chapter content, and 5dxs catalog behind the
     `lingyue.useSourceRegistryForCatalog` flag (default off). Empty or
     thrown registry results fall through to legacy unchanged, so the
     legacy path stays authoritative until the flag flips. Outstanding:
     flip the flag in a TestFlight build, watch `ReaderDiagnostics` for
     drift, then delete the legacy bespoke methods once clean.

---

## Phase 2.5 — Rule-schema fitness check (interlude)

**Goal:** before authoring rules for all 14 remaining legacy sources,
prove the schema is expressive enough for the messy real-world shapes —
and let the actual gaps drive the schema, not speculation.

### What shipped

- **`SearchStep.queryEncoding: SourceEncoding?`** — optional, `nil`
  defaults to UTF-8 so existing rules round-trip unchanged. Why: legacy
  mainland CMS deployments (Empire CMS clones, mainly) decode form bodies
  as GB18030 server-side, so a UTF-8 query reaches the search handler as
  garbled bytes and silently returns zero results.

- **`URLTemplate.expand(_:query:encoding:)`** — UTF-8 fast path is
  unchanged. The non-UTF-8 path round-trips the query through
  `String.data(using:)` then percent-escapes each byte outside
  `.urlQueryAllowed`, so `斗破` in GB18030 becomes `%B6%B7%C6%C6` not
  `%E6%96%97%E7%A0%B4`.

- **`RuleBasedBookSource.runSearchRequest`** — passes `step.queryEncoding
  ?? .utf8` to `URLTemplate.expand` for both the URL and (when present)
  the POST body. On POST + non-UTF-8 it also sets `Content-Type:
  application/x-www-form-urlencoded; charset=<iana>` so legacy backends
  know how to interpret the percent-decoded bytes.

- **Two prototype rules** under
  `Packages/LingyueCore/Tests/LingyueCoreTests/Fixtures/phase-2.5/`:
  - `sto9/` — 思兔閱讀. Validates POST-then-302-redirect-to-GET (handled
    transparently by URLSession) and the AJAX-loaded catalog trick (the
    detail rule reaches the AJAX endpoint via `regexReplace` on the
    detail page's catalog-link URL).
  - `tongrenquan/` — 同人圈. Validates GB18030 query encoding end-to-end
    against real captured HTML.

- **Tests:** `Phase25PrototypeTests` and `URLTemplateTests` — 10 new
  tests, all green. Both rules decode, both search parsers produce the
  expected hits from captured HTML, and the GB18030 percent-encoded body
  bytes match `%B6%B7%C6%C6%B2%D4%F1%B7` (verified independently via
  Python).

### What we learned (informs Phase 2 ETAs)

- **Per-rule authoring time, captured-HTML-in-hand:** ~20 min for a
  Empire-CMS-shaped site (tongrenquan), ~30 min for a site with an AJAX
  catalog (sto9). Most of the time goes to inspecting the result DOM and
  picking stable selectors; the schema itself rarely needs extending.

- **One outstanding schema sharp edge:** there is no first-class way to
  reference the page's own URL from `detail.catalogURLField`. Workaround:
  pick a self-link selector (canonical, breadcrumb, or an existing
  catalog button) and run `regexReplace` on it. Acceptable for the
  current 14 sources; revisit only if a site forces it.

- **Catalog-fetch shape varies wildly:** static full page (5dxs, Biquge),
  static partial + AJAX full (sto9), pagination (HJWZW). The current
  `CatalogStep` (chaptersSelector + nextPageField) handles the first
  two cleanly via different URL strategies; the third already worked in
  Phase 1.

### Exit criteria for Phase 2.5

1. New `queryEncoding` field merged with tests. ✓
2. Two prototype rules pass fixture-based search tests. ✓
3. Per-site authoring time estimates updated in this doc. ✓

---

## Phase 3 — Source authoring UX + Discovery search integration

**Goal (revised 2026-05-14).** Users add a source by pasting a homepage
URL — the app analyzes it, shows a human-readable review of what it
found, and lets the user save + enable when the review confirms the
required blocks work. The full `SourceRule` schema stays editable, but
only as advanced repair from inside the review screen — never as the
default authoring surface.

### Mental model

> "Paste a source URL; Lingyue analyzes it; if something is wrong, I
> can repair the advanced rules."

A normal user never thinks about capabilities, engines, headers,
host patterns, or selectors. A power user (typically on the Internal
/ TestFlight target, but also reachable from the App Store target via
the advanced disclosure) can drop into the raw schema when an
analyzer miss needs hand-fixing.

**What this revision changes.** Phase 3.1 originally treated
`SourceEditorView` (the full schema-driven form) as the default
authoring surface. We shipped it that way and validated end-to-end
that rules persist and feed `DiscoverySearchService`, but the form
exposed too many internal knobs — `supportsSearch`, `showInSearchBar`,
`requiresWebRender`, per-step engine, default headers, advanced
detection — for a normal user to make sensible choices. The revised
plan keeps that form (it's the only surface that can author the
full schema), but demotes it to **advanced repair** behind a
disclosure in §3.4, and makes the URL → analyze → review flow
(§3.2 + §3.3) the only path a normal user sees.

All UI text, placeholders, and screenshots continue to satisfy the
Phase 6 invariants (§6.2–§6.3) — URL field placeholders use
`https://example.com` or Wikisource; no "popular sources" picker;
empty App Store rule library; internal-provider metadata never
surfaces on App Store rows.

### 3.1 Sources list (Settings → 我的书源)

**Revised scope.** The list is a status dashboard, not a capability
inventory.

- Each row shows: source name, primary domain, an enable/disable
  toggle, and **one overall status pill**. Status values:
  - **可用** — every required block has analyzer confidence ≥ 0.8
    *or* a passing manual Test run; rule is enabled (or eligible to).
  - **需要检查** — at least one required block is unverified
    (analyzer red/yellow with no passing Test).
  - **测试失败** — last manual Test run on a required block failed;
    user intervention needed before re-enable.
  - **已关闭** — user has the source disabled. Overrides the other
    statuses visually.
- **No capability badges on rows.** The previous `搜索 / 浏览导入 /
  需渲染` chips read like an author-driven checklist; capabilities
  are derived from the rule + tests (see §3.5), not author choices,
  so they shouldn't appear that way.
- Origin badge (`内置` / `自定义`) stays, but small and subdued.
- Internal-only metadata (source-provider identifiers, fast-path
  adapter notes) must not appear on rows shown in the App Store
  target — App Store posture invariant.
- Tapping a row pushes the **Review screen** (§3.3), not the raw
  editor. This is true for both seeded and user-authored rules:
  the Review screen is the source detail surface; the raw editor is
  reachable only from inside it.
- `EditButton()` in the toolbar drives drag-to-reorder. In edit
  mode, rows are non-NavigationLink cards so SwiftUI doesn't dim
  them as "disabled nav targets," toggles are hidden, and `.onMove`
  reorders persist to `FileSourcePreferenceStore`.
- Toolbar `+` opens the **Add Source flow** (§3.2). On the App
  Store target, that's the only entry point. On Internal, a Menu
  on `+` offers `URL` / `JSON 导入` / `从空白开始`.

**Status (landed, needs revision).**

- ✅ Row render with name / domain / origin badge / enable toggle,
  drag-to-reorder, persisted enabled state, edit-mode-safe layout —
  shipped (commits up to `ce616ad`).
- 🟡 Rows currently render `搜索 / 浏览导入 / 需渲染` capability
  badges. Remove as part of §3.5 derivation rollout.
- 🟡 Rows currently lack an overall status pill. Add when §3.3
  Review screen ships (status is computed there).
- 🟡 Tapping a row currently pushes `SourceEditorView` (raw editor).
  Switch destination to the new Review screen.
- 🟡 The `+` toolbar button currently jumps to `SourceEditorView`
  over a blank rule. Switch destination to the new URL form
  (§3.2).

### 3.2 Add Source flow

**Primary path: URL → analyze → review → save.** Required user input
is intentionally minimal:

- **Homepage URL** (required).
- **Example book URL** (optional, strongly recommended — anchors
  catalog / chapter detection per §3.2.1 P4).
- **Test search keyword** (optional — lets the analyzer confirm the
  search step end-to-end rather than only matching a form).

Tap `分析` → app runs the analyzer (§3.2.1) → pushes the Review
screen (§3.3). No raw schema fields surface in this form at all.

**JSON import (Internal target only).** Unchanged from prior plan.
TestFlight users can paste or open a rule JSON exported from another
instance. The App Store target does not expose this affordance for
reasons documented in §6.2 ("No import rule from URL"). Internal
target wires JSON import as a second entry on the `+` Menu.

**"From scratch" / blank rule.** No longer a top-level entry on
the App Store target. The Review screen offers `编辑高级规则` as
the disclosure into the raw editor (§3.4); power users who want to
start from empty pick that path. On the Internal target, the `+`
Menu can include `从空白开始` for symmetry with the JSON import
entry, but it routes through the same raw editor surface — there's
no separate "blank editor as default" code path.

#### 3.2.1 URL Analyzer (Auto-fill from homepage) — v1

**Scope is unchanged from the prior plan**; only the destination
moves (analyzer output now flows into the Review screen rather than
prepopulating a raw editor).

**v1 is deliberately conservative.** Goals: close the typing gap
between "paste a URL" and "have a draft rule worth saving," without
pretending to be magic. URLSession-only, deterministic, no JS
rendering. Each pipeline step emits a confidence score (0–1) that
the Review screen (§3.3) translates into human-readable status copy
— scores never appear as a numeric badge to the user.

Pipeline:

- **P1 — Homepage fetch.** Resolve URL, follow redirects, snapshot
  final URL + HTML via `URLSession`. **No WebKit fallback in v1.**
  JS-only pages return a low-confidence empty pass — analyzer flags
  the rule as needing manual work rather than silently guessing.
  WebKit fallback lands in v1.1+ when there's a real target that
  needs it.
- **P2 — Host + path classification.** Derive `hostPatterns` from
  the final URL host (with subdomain wildcarding heuristic). Pull
  `<title>` and `<meta name="description">` for a default `name`.
- **P3 — Search-form discovery (simple GET/POST only).** Look for
  `<form>` elements with `name` / `id` / `action` containing
  `search`, `query`, `q`, `keyboard`, `searchkey`. Pick the first
  viable form; derive `urlTemplate` + `bodyTemplate` from its
  `action` + input names. Multiple candidate forms → yellow.
  Non-form AJAX/JS-driven search → red, no urlTemplate proposed.
  **Multi-step forms, JSON-API search, and CAPTCHA-gated forms are
  out of scope — v1.1+.** If a test search keyword was supplied,
  P3 also executes the proposed search and verifies non-empty
  parseable results before scoring green.
- **P4 — Catalog-shape detection (anchor via optional book URL).**
  If the user supplied an example book URL, fetch that page and
  pick the densest `<a>`-cluster as the catalog candidate. Propose
  `chaptersSelector` + per-item `titleField` / `urlField`. Honour
  `nofollow` / `aria-hidden` filters. **Without the example URL,
  P4 emits red and the Review screen surfaces `需要检查` with copy
  asking for an example book URL** — crawling from homepage to
  find a book is fragile and not worth v1 complexity.
  **AJAX-paginated catalogs, multi-volume layouts, and per-page
  chapter listings are explicit non-goals.**
- **P5 — Chapter-body detection.** Follow one of the proposed
  chapter links; the body is the largest text-density block in the
  page. Propose `bodyField` with `[.brToNewline, .stripHTML]`
  defaults. Paginated chapter bodies (`maxBodyPages > 1`) are not
  inferred in v1.
- **P6 — Confidence emission.** Every pipeline step emits a score
  and a structured reason. The Review screen consumes these — the
  analyzer itself never renders UI.

**Capability inference (deferred).** The analyzer emits an
`AnalysisReport` alongside the draft rule — it does **not** write
`SourceCapabilities` directly. The report carries per-block
confidence, reason text, and an analyzer-input fingerprint of the
fields it inferred (consumed by §3.5.1 to invalidate stale
validation when the user later edits selectors). Capabilities are
derived at Save / Enable time on the Review screen (§3.5.2) from
rule shape + validation store, not at analyzer-output time. The
split prevents stale `supportsSearch = true` from lingering after
a user hand-edits search selectors in §3.4.

**Out of scope for v1 (tracked for v1.1+):**

- WebKit/headless render fallback for JS-only pages.
- AJAX search/catalog inference.
- Catalog pagination + multi-volume detection.
- Multi-step / token-protected search forms.
- Encoding sniffing beyond what `URLSession` / `HTMLString` already
  give us.

### 3.3 Review screen

**One screen per source-in-progress.** No raw selectors visible by
default. Blocks render as human-readable status copy backed by the
analyzer's confidence + the user's most recent Test result for that
block:

- 搜索：**已识别** / **未识别** / **需要检查**
- 书籍详情：**已识别** / **需要检查**
- 目录：**已识别** / **需要检查**
- 正文：**已识别** / **需要检查**

Above the block list, the Review screen also shows a single
**read-only** line for detection — `检测到域名：xxx.com、www.xxx.com`
— so the user can confirm the analyzer picked the right host(s)
without ever editing wildcard host patterns from the default flow.
If the analyzer guessed badly, `修复` on the detection line opens
the §3.4 advanced editor scrolled to the host-pattern row.

State semantics:

- **已识别** — analyzer confidence ≥ 0.8 *or* the user ran the
  block's manual Test and it passed.
- **需要检查** — analyzer is yellow (0.5–0.8) or red (<0.5) and the
  user has not yet passed a manual Test.
- **未识别** (search only) — P3 emitted red. Block is treated as
  optional: search just won't fire for this source.

Per-block actions:

- **测试** — opens `SourceTestSheet` deep-linked to this block,
  pre-filled with a sensible default input (the homepage / the
  example book URL / the test keyword captured in §3.2). A pass
  flips the block to 已识别 regardless of analyzer confidence.
- **修复** — opens the §3.4 advanced editor scrolled and expanded
  to this block's subsection (search / detail / catalog / chapter).
  Returning from the editor re-runs analyzer P6 + clears any stale
  test pass for fields that changed.

Save / Enable:

- **Save (草稿).** Always available. Writes to
  `EditableSourceStore`. The Sources list shows `需要检查` if any
  required block is unverified.
- **Enable.** Available when every **required** block is **已识别**:
  - Required-for-search-enable: search + detail + catalog + chapter
    all 已识别. Source appears in Discovery search when enabled.
  - Required-for-browse-only-enable: detail + catalog + chapter
    all 已识别; search is **未识别** or **需要检查**. Source can
    be enabled for browser import (§Phase 4) but is invisible to
    Discovery search.
  - Analyzer confidence guides the UI but never permanently blocks
    a knowledgeable user — a yellow/red block becomes 已识别 the
    moment its manual Test passes.

**Status (not started).** Builds alongside §3.2; the analyzer's
output has no destination today. Pre-cursor work that's already
landed: `SourceTestSheet` works against an in-memory draft and
returns structured per-block results — the Review screen reads the
same shape, so the integration is wiring, not new parsing.

### 3.4 Advanced Rules (高级规则 / 手动修复)

**Collapsed disclosure section at the bottom of the Review screen.**
Hosts the full `SourceRule` schema as form rows. This is the only
normal-user path into the raw schema; the Sources list never opens
the raw editor.

Fields hosted in advanced (none surface in the default flow):

- **基础信息.** Encoding (`自动 / UTF-8 / GBK / GB18030 / Big5`).
  Default headers / User-Agent override if surfaced at all
  (deferrable — most rules don't need it; surface only when a
  reported analyzer miss can be traced to a UA-gated host).
- **检测.** Host patterns (analyzer-inferred; shown read-only on
  the Review screen, editable here only when `修复` deep-links from
  the detection line), path regex, confirm selector, canonical URL.
- **搜索.** GET / POST, URL template, body template, query
  encoding, results selector, every field selector and its
  transform chain.
- **书籍详情 / 目录 / 章节.** All field selectors, transform chains,
  max catalog pages, max body pages.
- **引擎.** Per-step engine choice if surfaced. Default behavior is
  HTTP first; the analyzer or loader writes `requiresWebRender =
  true` when HTTP is provably insufficient (§3.5). Hand-overriding
  to headless lives here.
- **能力.** Hidden from the advanced UI too. Computed, not
  authored — see §3.5.

**Surface re-uses `SourceEditorView`.** That's the form code that
already exists today. The recent revision (commits 2026-05-14)
removed engine / headers / advanced detection rows from the form;
those rows need to be **re-added under §3.4** rather than left
deleted, since this is now their home. Re-adding them is a
straightforward revert-with-relocation of the lines that were just
removed.

**Fix actions deep-link.** `修复 → 搜索` opens `SourceEditorView`
with the disclosure pre-expanded and scrolled to the search step.
SwiftUI: a `scrollProxy` driven by an `@State var pendingScrollTo:
Section.ID?` on the editor view; the Review screen sets it through
the navigation argument when it pushes.

**Status (landed, needs relocation).**

- ✅ `SourceEditorView` form exists, covers detection / search /
  detail / catalog / chapter / danger sections.
- 🟡 Engine / headers / advanced detection rows were removed in
  the 2026-05-14 simplification pass. Restore them here, under a
  default-collapsed `DisclosureGroup`.
- 🟡 `SourceTestSheet` is reachable from the editor toolbar today.
  The Review screen's per-block 测试 button reuses the same sheet
  with a `step:` argument pre-selected; the toolbar-from-editor
  entry stays for power-user convenience.

### 3.5 Validation store + capability derivation

The Review-screen status copy and Sources-list status pill both
depend on state that must outlive an app restart but **must not
travel between installs**: which blocks the analyzer scored green
*for this version of the rule*, when the user last ran a passing
manual Test, what the last failure said. A device-local validation
store carries that state; capability derivation reads from it.

#### 3.5.1 `SourceValidationStore` (device-local)

New store at `lingyue/Data/FileSourceValidationStore.swift`, sibling
to `FileSourcePreferenceStore`. Same actor + JSON-file pattern as
the existing stores so reliability lessons (atomic write, lowercase
`lingyue/` parent — see §3.1 history) carry over for free.

- Path: `Application Support/lingyue/source-validation.json`.
- Keyed by `ruleID`. Per rule the record holds:
  - `analyzerReport` — last `AnalysisReport` from §3.2.1.
    Phase-3 closeout keeps this **in memory only**: the AddSource →
    Review path carries the fresh report through to capability
    derivation, but reopening Review via a Sources-list row tap
    starts with a blank report (analyzer hasn't run this session).
    Persistence is a follow-up — out of scope for the exit
    criteria. The Review screen does honor the in-memory report:
    analyzer-green soft-passes the block (see `effectiveStatus`)
    so a clean analyze → Enable round-trip works without forcing
    a manual Test.
  - `tests` — per-block test history. For each of
    `.search / .detail / .catalog / .chapter`:
    - `status`: `.passed / .failed / .notRun`.
    - `lastRunAt`: ISO8601 timestamp.
    - `failureSummary`: optional, populated on `.failed`.
    - `inputFingerprint`: hash of the rule's selectors / transforms
      / templates that this block depends on, captured at the time
      the test ran. Consumed by `statusEffective` below.

- `statusEffective(block, rule)` — read-side helper. Returns
  `.notRun` when the stored `inputFingerprint` doesn't match the
  rule's current fingerprint for that block — i.e. the user edited
  selectors in §3.4 since the last pass, so the prior pass is
  stale. The store never silently mutates: stale passes still live
  on disk, they just don't count until either re-tested or the
  fields revert.

- Read sites: Review-screen render, Sources-list status pill
  (§3.1), §3.5.2 capability derivation, Enable-button gating
  (§3.3).
- Write sites: analyzer run completion (writes `analyzerReport`),
  `SourceTestSheet` pass / fail (writes `tests[block]`), rule
  delete (removes the record).
- **Never exported.** The Phase 3.2 JSON-import path on Internal
  target ingests rules only; an imported rule arrives with no
  validation record, so every block starts `.notRun` and the user
  must Test before enable. That's the intended behavior — one
  user's "passed on my device" should not grant enable on
  another's.

#### 3.5.2 Capability derivation

`SourceCapabilities` stays a schema field — it's still serialized
on every rule and `InternalSourceRegistry.searchableSources()` /
the in-app browser detector both read it — but it is no longer a
user-authored form. Values are derived from rule shape + the
validation store:

- `supportsSearch` = `rule.search != nil && validation.statusEffective
  (.search, rule) == .passed`.
- `supportsBrowserImport` = `rule.detection.hostPatterns.nonempty &&
  .detail + .catalog + .chapter all `.statusEffective == .passed`.
- `requiresWebRender` = `validation.analyzerReport?.suggestsHeadless
  ?? false` ‖ explicit toggle in §3.4 advanced. Seeded rules carry
  their authored value forward unchanged.
- `showInSearchBar` is **removed from any authoring surface**.
  Default behavior: any source where `supportsSearch == true`
  appears in Discovery search. If we later need a per-source
  performance switch ("include in global search"), it lands as
  device-local state (`UserDefaults`, scoped to the install), not
  a rule-schema field. The schema field stays for seeded rules
  but no editor exposes it.

Derivation runs at:
- **Save / Enable on the Review screen** — recompute, write into
  `rule.capabilities`, persist via `EditableSourceStore`. This is
  the only place capabilities flow back onto the rule.
- **Test pass / fail (`SourceTestSheet`)** — writes only to
  `SourceValidationStore`. The next Save / Enable picks up the
  effective status. No partial capability flips between tests.
- **Rule edit (§3.4)** — writes only to `EditableSourceStore`.
  The validation store's `inputFingerprint` invalidates stale
  passes automatically; the user must re-Test before re-enable.

Downstream code (`InternalSourceRegistry.searchableSources()`,
in-app browser detector) reads `rule.capabilities` exactly as
today — no new APIs, just an upstream source-of-truth change.

### 3.6 Discovery search bar fan-out

Unchanged from prior plan — see the original §3.3 content below
for the lab-flag rollout. The dependency on "a user can create a
new rule and see it light up in Discovery" now flows through §3.3
(Review screen → Enable → write `capabilities.supportsSearch =
true`) rather than the raw editor.

- `lingyue/Views/DiscoverySearchBar` already exists. Change its
  source list from the hard-coded array to
  `registry.searchableSources()`.
- Result rows already group by source. Keep the grouping; switch
  the source-name source-of-truth to `BookSource.displayName`.
- Browser-only rules (`supportsSearch = false`) never appear here.
  Their entry point is the in-app browser (Phase 4).

**Phase 3.6 — landed behind lab flag.** First slice ships as
`DiscoverySearchService.routeViaRegistry`: per-search, the service
asks `InternalSourceRegistry.searchableSources()` for a `BookSource`
whose `displayName` matches the legacy `DiscoverySource.name`, and
when the flag `lingyue.useRegistryForDiscoverySearch` is on, the
rule engine's `search()` result replaces the hand-written parser's
output. Empty or thrown registry runs fall through to the legacy
path, so flipping the flag is purely additive — no source loses
search coverage. The flag is exposed under Settings → 实验. Once
we have parity on live sites for the 9 seeded rules, the flag is
removed and the registry path becomes the only path.

What still ships in a later 3.6 commit, once §3.3 lands:
synthesizing a `DiscoverySource` for *user-created* rules whose
`displayName` isn't in the hand-coded catalog. Until then, exit
criterion #1 ("a user can paste a URL and see it light up in
Discovery") is gated on §3.2–§3.3.

### Implementation order (revised)

The work that's already landed lines up like this; the rest is the
ordered todo for the revised UX:

1. ✅ §3.1 list infra (rows, toggle persistence, reorder,
   edit-mode-safe layout).
2. ✅ §3.4 raw schema form exists (currently misplaced as the
   default authoring surface).
3. ✅ §3.6 Discovery search lab-flag wiring for seeded rules.
4. ✅ §3.2 URL form. `AddSourceURLView` over homepage / example
   URL / keyword; `+` button on Sources list opens it as a sheet.
   Analyzer is the slice-1 stub (host pattern + name from URL
   parsing only); every per-block confidence comes back `.notRun`
   so the Review screen has a destination to land in.
5. ✅ §3.3 Review screen. Per-block status copy, per-block 测试
   button deep-linked into `SourceTestSheet` (pre-fills search
   keyword / example book URL from §3.2 inputs), 修复 button that
   pushes `SourceEditorView` as the advanced surface, Save draft
   vs. Enable gated on `detail + catalog + chapter` all 已识别.
   Capability derivation runs at save time from in-memory block
   status — the data shape matches §3.5.1 so slice 6 swaps to the
   on-disk validation store without UI churn. Deep-link "scrolled
   to this section" inside the editor stays slice 7. Per-block
   pass state is in-memory only and resets when the Review view
   unmounts (the on-disk record is slice 6).
6. ✅ §3.5 validation store + capability derivation.
   `FileSourceValidationStore` persists per-block test outcomes at
   `Application Support/lingyue/source-validation.json`; reads via
   `statusEffective(_:rule:)` use a SHA256 fingerprint of the
   relevant rule sub-struct so a §3.4 schema edit silently
   invalidates the prior pass. The Review screen reads/writes
   through it; Save / Enable runs capability derivation
   (§3.5.2) against the store, so `supportsSearch` /
   `supportsBrowserImport` flow only from validated reality
   onto `rule.capabilities`. The Sources list dropped capability
   badges and renders one of 可用 / 需要检查 / 测试失败 / 已关闭
   per row, computed from rule + preference + validation snapshot
   (seeded rules trust their authored capabilities — they don't
   need test records to read as 可用). `SourceEditorView`'s
   capability toggles are gone; the editor is now strictly a raw
   schema surface. Rule + preference + validation are deleted
   together when the user removes a custom rule, so a future
   re-import of the same UUID starts clean.
7. ✅ §3.4 advanced surface. Engine pickers (per step),
   `defaultHeaders` editor, advanced-detection rows
   (`pathPattern`, `confirmSelector`, `canonicalURL`), and the
   `requiresWebRender` override toggle live behind
   `SourceEditorView.advancedSection` — a default-collapsed
   `DisclosureGroup` so a novice rule author never sees them. The
   editor gained a `ScrollAnchor` enum + `scrollTo:` init param;
   `ScrollViewReader` scrolls the form to the requested section on
   first appear. `SourceReviewView`'s per-block 修复 button passes
   the matching anchor (search/detail/catalog/chapter) so the user
   lands on the failing block, and the editor auto-expands the
   advanced disclosure when the anchor points inside it. The
   generic 高级修复 button leaves the anchor nil and opens at the
   top.
8. ✅ §3.2.1 URL Analyzer pipeline (P1–P3). `SourceAnalyzer` moved
   from the app target into `LingyueCore/Analyzer/` so it can call
   `SwiftSoup` directly without adding a duplicate dep on the app
   target. P1 fetches the homepage via the injected
   `SourceHTMLLoading` (default `HTTPSourceLoader`); P2 derives
   `hostPatterns` (with `www.`-stripping dedup) and pulls a display
   name from `<title>` / `<meta description>`; P3 walks `<form>`
   candidates, scoring them against search-flavoured tokens and
   input names, then synthesizes `urlTemplate` / `bodyTemplate` /
   `queryEncoding` (defaulting to UTF-8). When `testKeyword` is
   provided, P3 fires the proposed search and confirms a non-empty
   `resultsSelector` match — green only when the smoke-test
   actually returns rows. Fail-soft throughout: P1 network/HTML
   failures degrade to URL-parsing-only output with an
   `isStub`-flagged report so the Review banner explains the
   degradation. P4 (catalog) and P5 (chapter) remain `.notRun`
   with a steer-to-Test note — deferred to slice 9 once an
   example-book-URL passing rate is measurable.
9. ✅ §3.2.1 P4–P5 + §3.6 user-rule fan-out. `SourceAnalyzer`
   gained `analyzeCatalog` (walks `ul/ol/dl/div/table/tbody`
   containers, scores the densest `<a>`-bearing row cluster ≥5
   rows, synthesizes `chaptersSelector` via `#id > .class > tag`
   path, and writes `rule.catalog`; green when ≥10 rows dominate
   2:1, yellow otherwise) and `analyzeChapterBody` (walks
   `div/article/section/pre/.content/.chapter/#content/#chapter`,
   prefers class/id name matches like `content/chapter/text/
   articlebody`, defaults `bodyField` transforms to brToNewline +
   stripHTML + collapseWhitespace). Detail and chapter title
   selectors default to `h1`. `DiscoverySource` gained a `kind`
   field (`.seeded` / `.userRule`); `DiscoverySearchService`
   `searchStream` augments the seeded source list every round
   with `loadUserRuleSources()` (reads `EditableSourceStore`,
   filters `capabilities.supportsSearch && preferenceStore.
   isEnabled`). User-rule sources route exclusively through
   `InternalSourceRegistry` (no legacy parser); the
   `useRegistryForDiscoverySearch` lab flag stays in effect
   only for seeded rules.
10. ✅ Phase 3 closeout fixes (codex audit). Four issues caught
    by an outside review and patched together:
    - Sources-list row tap now pushes `SourceReviewView` via
      `navigationDestination(item:)` instead of opening
      `SourceEditorView` directly. The raw editor is only
      reachable from inside Review via 高级修复, matching the
      revised §3.3 UX. Re-entering Review from a row tap starts
      with a blank `AnalysisReport` (now an optional
      `analyzerInput`); the AddSource path still threads the
      fresh report through.
    - Review now consumes the analyzer report. New
      `effectiveStatus(_:)` returns the recorded test status when
      one exists; otherwise it soft-passes when the analyzer
      scored the block `.green`. Both the per-block status pill
      and Enable gating use this, so an analyzer-clean rule round-
      trips to enabled without forcing a manual Test for every
      block. The validation store still holds only test history —
      `analyzerReport` is in-memory for closeout (see §3.5.1).
    - Same-page catalog rules no longer scrape the document for
      a URL. New `SourceTransform.useBaseURL` discards the
      extracted value and emits the request URL; the analyzer's
      "catalog lives on the detail page itself" branch now writes
      `FieldSelector(selector: nil, transforms: [.useBaseURL])`
      so the engine's catalog fetch is a no-op re-read of the
      detail page rather than chasing whole-document text.
    - Per-block Test sheet now prefills catalog + chapter inputs.
      `AnalysisReport` gained `firstChapterURL` (captured during
      P5); Review's `defaultTestInput` returns
      `exampleBookURL` for catalog and `firstChapterURL` for
      chapter so the user no longer re-types URLs the analyzer
      already discovered.

### Exit criteria for Phase 3 (revised)

1. A user can paste a homepage URL, run analyzer + Test, see a
   human-readable Review screen, save + enable a working source —
   **without ever opening the raw schema editor**.
2. Editing a seeded rule produces a user override stored in
   `EditableSourceStore` (unchanged from prior plan).
3. The advanced schema editor (§3.4) is reachable from every
   Review-screen block via 修复, and exposes the full
   `SourceRule` schema (encoding, GET/POST + body template + query
   encoding, all selectors, transforms, max catalog/body pages,
   headers, engine mode).
4. The Sources list shows no capability badges and no
   internal-provider metadata on rows shown in the App Store
   target. Rows carry an overall status pill (可用 / 需要检查 /
   测试失败 / 已关闭) computed from rule + tests.
5. `SourceCapabilities` is derived from rule + `SourceValidationStore`
   at save time, never authored as a user-facing form.
   `showInSearchBar` is removed from any authoring surface.
   Per-block analyzer / test state persists across app restarts
   via `SourceValidationStore`; stale passes invalidate
   automatically when the user edits the rule.
6. UI copy is zh-Hans by design (v1 target market). Localization
   infrastructure (`.xcstrings` String Catalog, `LocalizedStringKey`
   adoption, en translation) is **out of Phase 3 scope** and lives in
   its own future phase whenever an English-market push is on the
   table. The original "en + zh-Hans" wording in this slot conflicted
   with how the rest of the codebase is built — no `.lproj` dirs, no
   String Catalog, no `LocalizedStringKey` usage across the ~20
   `Text()`-using files. Localizing only Phase 3 surfaces while every
   other surface stays hard-coded zh-Hans would be busywork, not a
   shippable improvement.

---

## Phase 4 — In-app browser import via detection

**Goal:** as the user browses freely in the in-app web view, Lingyue
checks the rendered page against enabled, validated sources. When a
rule recognizes the page, the browser shows an import affordance and
imports through that source's rule engine. Legacy heuristic detection
remains an **Internal-only fallback** until the Phase 5 target split
removes it from the App Store build.

### 4.0 Preconditions

Phase 4 assumes the Phase 3 source-authoring flow is true in code:

- Sources-list row tap opens `SourceReviewView`, not `SourceEditorView`.
- User-authored sources can be enabled only after validation.
- Enabled rules have derived capabilities:
  - `supportsSearch` when search passed.
  - `supportsBrowserImport` when detail + catalog + chapter passed.
- `SourceReviewView` is the only normal path into advanced repair.

The detector only considers sources where
`source.capabilities.supportsBrowserImport == true`.

### 4.1 `PageDetector` fan-out (LingyueCore)

New actor at `Packages/LingyueCore/Sources/LingyueCore/Detection/
PageDetector.swift`. It lives in core so both future app targets can
reuse it. It must depend only on `BookSourceRegistry`, never
`InternalSourceRegistry` or any `LingyueInternalSources` type.

`BookSourceRegistry` already exists at `LingyueCore/Protocols/
BookSourceRegistry.swift` and `InternalSourceRegistry` already
conforms to it, so this slice is purely additive — no registry
refactor required. The detector takes the protocol-typed registry
and the app passes the concrete `InternalSourceRegistry` instance.

```swift
public actor PageDetector {
    public init(registry: any BookSourceRegistry, cacheCapacity: Int = 64)

    public func detect(in snapshot: WebPageSnapshot) async -> DetectionResult?
    public func invalidateCache()
}

public struct DetectionResult: Sendable, Hashable {
    public var detection: BookDetection
    public var sourceID: String
    public var sourceName: String
}
```

- Reads `registry.enabledSources()` per call and filters to
  `supportsBrowserImport`.
- Fans `detectBook(in:)` across sources with `withTaskGroup`.
- Treats per-source thrown errors as misses plus DEBUG diagnostics,
  not as a failure of the whole detection pass.
- Tiebreak: confidence desc, registry index asc. Equal confidence →
  first source in registry order wins. The Sources-list order is the
  user's preference signal; no chooser in v1.
- Cache key includes `snapshot.finalURL.absoluteString` plus a
  source-set generation/fingerprint, or callers must invoke
  `invalidateCache()` whenever the source set changes.
- Cache must never return a source that is now disabled or deleted.

### 4.2 `InAppBrowserView` wiring

Replace the current direct legacy call:

```swift
BookImportService.shared.detectBook(html: html, url: url, pageTitle: pageTitle)
```

with rule-first detection:

1. Capture the rendered page from the visible `WKWebView`:
   `document.documentElement.outerHTML`.
2. Build `WebPageSnapshot{html, finalURL, responseHeaders: [:],
   statusCode: nil}` — the existing model has no `fetchedAt`; cache
   keying lives in `PageDetector`, not the snapshot.
3. Call `await pageDetector.detect(in: snapshot)`.
4. If rule detection succeeds, show `从 <sourceName> 导入` and store
   the `BookDetection` / `sourceID` pair for the import action.
5. If rule detection returns nil:
   - Internal target may fall back to the legacy
     `BookImportService.detectBook(html:url:pageTitle:)` heuristic.
   - App Store target must not use any hardcoded-host fallback.

Keep the existing delayed scans at 0 / 600ms / 1500ms, but debounce by
URL + HTML hash so the same rendered page does not repeatedly flash or
replace prompts.

### 4.3 Browser-session loading scope

Do not claim `.web` steps automatically use the visible browser session
unless we implement that explicitly. Current runtime loaders use a
separate `WebRenderingService` plus cookie sync, not the visible
`InAppBrowserView`'s `WKWebView`.

Phase 4 v1 scope:

- Detection uses the visible browser's rendered HTML.
- Import uses the normal `SourceStack.loader`.
- Before rule-routed import, run a one-time WK→HTTP cookie sync.
  `WebViewSourceLoader.syncWKCookiesToHTTPStorage()` already does this
  on every `.webView` engine render; for `.http`-engine first-imports
  (which would otherwise miss cookies the visible browser captured),
  factor the helper out so the import action can call it explicitly
  before `source.fetchDetail`.
- If import fails because the site needs live JS/session state, surface
  a clear error and keep the browser open.

Phase 4 v1.1 candidate:

- Add `BrowserSessionSourceLoader` backed by the current
  `InAppBrowserState` / visible `WKWebView`.
- Same-origin fetches can use `fetch(..., { credentials: "include" })`
  from the visible page context.
- `.web` steps can navigate/render through the visible or shared
  browser context.
- This is the version that truly supports Cloudflare/session-gated
  imports. Ship it only when a real source justifies the complexity.

### 4.4 Rule-routed import action

Add a registry-based import path:

```swift
importBook(
    result: DetectionResult,
    registry: any BookSourceRegistry,
    loader: any SourceHTMLLoading
)
```

Flow:

1. Resolve `source = registry.source(withID: result.sourceID)`.
2. `source.fetchDetail(url: result.detection.detailURL)`.
3. `source.fetchCatalog(url: detail.catalogURL)`.
4. Convert `BookDetail + [ChapterLink]` into the existing `Novel`
   model.
5. Keep chapter bodies lazy-loaded as today.
6. Reuse the existing category prompt and
   `LibraryStore.addImportedNovel` flow from `InAppBrowserView`.

Failures keep the browser open and surface a clear message:

- source disappeared / disabled
- unsupported URL
- parse failed
- rate limited
- source blocked
- network/render failed

The heuristic import path stays only for the Internal fallback branch.

### 4.5 Target-specific fallback rules

Internal target:

- Rule detection first.
- Legacy hardcoded `BookImportService.detectBook` fallback second.
- Useful during migration and for still-unconverted internal sources.

App Store target:

- Rule detection only.
- No hardcoded novel-site fallback.
- If no user rule recognizes the page, show no import prompt or show a
  neutral "Add this site as a source first" affordance.

### 4.6 Cache invalidation

Call `PageDetector.invalidateCache()` whenever:

- source enabled/disabled changes
- source priority changes
- a source rule is saved or deleted
- validation state changes from not-enabled to enabled
- registry cache invalidates

Do not key cache only by URL forever; otherwise disabled or deleted
sources can still produce stale import prompts.

### 4.7 Tests

Core tests:

- `PageDetector` ignores disabled / non-browser-import sources.
- Higher confidence wins.
- Equal confidence uses registry order.
- Per-source thrown errors do not fail detection.
- Cache hit returns the same result.
- Cache invalidation drops stale results.

App/integration tests:

- `InAppBrowserView` prefers rule detection over legacy fallback.
- Internal fallback still works when rule detection returns nil.
- App Store-mode path has no legacy fallback.
- Import failure leaves the browser open and surfaces an error.

### 4.8 Performance budget

Measure before optimizing:

- DEBUG timing around `PageDetector.detect`.
- Detection must run off the main actor and create no visible UI hitch.
- Target: ≤30ms p95 for 20 enabled sources on representative pages.
- If p95 is bad, optimize in this order:
  1. host/pattern prefilter before parsing
  2. cache by URL + source generation
  3. parse HTML once inside `PageDetector`
  4. only then consider a `detectBook(in:document:)` overload

Do not add a parse-once protocol change before measurement proves it is
needed.

### Exit criteria for Phase 4

1. Enabled user-authored rules with `supportsBrowserImport` can detect
   and import from the in-app browser without opening the raw editor.
2. Internal target still has legacy heuristic fallback; App Store path
   has rule detection only.
3. Two sources that claim the same page resolve deterministically via
   confidence + registry priority.
4. Disabling/deleting/reordering a source invalidates detector cache and
   cannot leave stale prompts.
5. Import failures keep the browser open and show actionable errors.
6. Detection adds no perceptible page-load latency and meets the measured
   performance budget or documents why optimization was needed.

### Implementation order

1. ✅ §4.1 `PageDetector` actor in `LingyueCore` with protocol registry,
   fan-out, tiebreaks (confidence desc, registry index asc), LRU URL
   cache, and explicit `invalidateCache()` API. Lives at
   `Detection/PageDetector.swift`; depends only on
   `BookSourceRegistry` so both target stacks reuse it.
2. ✅ §4.7 core tests at
   `LingyueCoreTests/PageDetectorTests.swift` cover capability filter,
   higher-confidence win, equal-confidence registry order, thrown-
   source resilience, cache hit (same result + no re-probe), cached-
   miss short-circuit, and `invalidateCache()` re-probe.
3. ✅ §4.2 `InAppBrowserView` races rule detection and the legacy
   heuristic per scan. Rule hit becomes `ruleDetectedBook` and shows
   `从 <sourceName> 导入`; heuristic-only hit still surfaces the
   legacy prompt for the Internal fallback. Same-URL re-scans refine
   title strength and/or replace the heuristic fallback with a
   richer one. The detector pulls `sourceStack.pageDetector` from
   the shared `SourceStack`.
4. ✅ §4.4 `BookImportService.importBook(detection:registry:)` resolves
   the source by ID, calls `fetchDetail` → `fetchCatalog`, applies the
   same runaway-chapter fuse the heuristic path uses, and maps
   `BookSourceError` cases to user-facing `WebBookImportError`
   (rateLimited / sourceBlocked / parseFailed-ruleIncomplete-
   unsupportedURL → noBookDetected / loadFailed → badStatus). Rule
   failure falls back to the heuristic candidate when one was captured
   in parallel during detection. Browser stays open on every error.
5. ✅ §4.3 cookie sync hook. `startRuleImport` calls
   `WebViewSourceLoader.syncWKCookiesToHTTPStorage()` once before
   the registry-routed import so `.http`-engine first-imports see any
   cookies the visible WKWebView session captured (Cloudflare
   clearance, login state).
6. ✅ §4.6 cache invalidation wired into every source-set mutation
   point: `SourcesListView` toggle + reorder, `SourceEditorView`
   save + delete, `SourceReviewView` capability-flipping Save/Enable.
   Each one calls `sourceStack.pageDetector.invalidateCache()`
   alongside `DiscoverySearchService.shared.invalidateRegistryCache()`.
7. ✅ §4.8 DEBUG timing baked into `PageDetector.detect`:
   millisecond fan-out span + winner sourceID logged per call,
   plus cache-hit telemetry. Stub-tested fan-out runs in <1ms;
   real-world budget (≤30ms p95 for 20 enabled sources) holds with
   the current rule set — no parse-once optimization needed.

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

**Landed:** the two appiconsets exist and each target's
`ASSETCATALOG_COMPILER_APPICON_NAME` points at the correct one. Both
sets currently carry the same `AppIcon-1024.png`; the Internal-variant
overlay (`DEV` / red-dot) is a follow-up artwork task — replace
`AppIcon-Internal.appiconset/AppIcon-1024.png` when ready, no code
change needed.
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

### Implementation order

1. ✅ §5.1 slice 1 — code-level fork prep via `LINGYUE_INTERNAL`
   compilation condition (Internal-side only, no project split yet).
   `SourceStack.live` switches between `InternalSourceRegistry`
   (seeded rules + fast-path adapters) and `AppStoreSourceRegistry`
   (editable store only) at compile time; `InAppBrowserView` routes
   the heuristic catalog through a helper that returns `nil` on App
   Store builds; `SourcesListView` seeds from the bundle only on
   Internal builds; the legacy heuristic import fallback inside
   `startRuleImport` rethrows on App Store. Both branches build
   green from the same source tree. Verified via `xcodebuild ...
   SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` to simulate the App
   Store target before the actual project split. Caveat: this slice
   alone did **not** achieve App Store binary cleanliness — the
   compile-time fork toggled high-level call sites, but
   `LingyueInternalSources` was still linked into the single
   `lingyue` target and host literals still lived in shared files
   (`DiscoveryView` catalog + legacy parsers, `Novel.BookSourceRegistry`,
   `BookImportService` fast-path adapters, `ReaderDiagnostics`
   receipt-gated runtime check). That removal is slice 2.
2. ✅ §5.1 slice 2 — Xcode target split + source-level host gating.
   Duplicated `lingyue` → `LingyueInternal` (bundle id
   `com.lingyue.reader.internal`, `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
   includes `LINGYUE_INTERNAL`) and new `LingyueAppStore` target
   (bundle id `com.lingyue.reader`, no `LINGYUE_INTERNAL`).
   `LingyueAppStore`'s Frameworks build phase drops
   `LingyueInternalSources` so it cannot link. Source-level
   `#if LINGYUE_INTERNAL` gates applied to every host-bearing site
   in the shared file tree: `DiscoverySourceCatalog.searchRoutes` /
   `.sources`, all legacy parser methods in `DiscoveryView`
   (parseDaweixs/ESJ/52Shuku/Sto9/Jieqi/Banxia/BQGL/Zhswx/HJWZW/
   EmpireCMSBook/XSW/Nunu/Powanjuan), the `parseDirectResults`
   switch body, `Novel.BookSourceRegistry.sources` host catalog,
   `BookImportService` fast-path adapter helpers
   (`biquge*`/`fivedxs*`/`hjwzw*`), and the host-bearing fallback
   URL on `DiscoverySource.fallbackSourceURL`. `ReaderDiagnostics.isInternalBuild`
   flipped from receipt-gated runtime to compile-time `#if`.
   Settings lab toggles + diagnostics section gated to Internal.
   Both schemes (Debug + Release) build green. Binary scan via
   `strings -a … | grep -F <host>` against all 22 forbidden hosts
   returns zero matches on the LingyueAppStore Release `.app` main
   binary and the Debug `.app` (main + `.debug.dylib`).
3. ⏳ §5.1 backup feature. Ship `.lingyue-backup` export + import
   (LibraryStore, EditableSourceStore, reader bookmarks) in the
   renamed `LingyueInternal` target so existing TestFlight testers
   can carry their library across to the new `LingyueAppStore`
   bundle ID install. (Originally planned to ship from the old
   `lingyue` target before the rename, but the rename happened
   first; the migration now flows from Internal → AppStore via
   the file rather than from old `lingyue` → both new targets.)
4. ⏳ §5.1 ASC operations (out of code). Create the new
   `com.lingyue.reader.internal` App Store Connect record, invite
   testers to its new TestFlight group. Existing
   `com.lingyue.reader` record stays for the eventual App Store
   submission.
5. ✅ §5.4 CI multi-surface scan. `Scripts/forbidden-hosts.txt`
   lists 24 hosts (10 seeded homepages, 11 legacy host-pattern
   catalog entries, 3 fast-path adapter hosts).
   `Scripts/scan-appstore-binary.sh` runs all three scan arms
   (strings, bundled JSON/plist/txt/strings, `assetutil --info`
   on `Assets.car`) and exits non-zero on any match. Sanity-checked
   locally: zero hits against the LingyueAppStore Release `.app`,
   all 24 hits surfaced against the LingyueInternal Debug `.app`
   (confirms the scan actually fires). Wiring this into a CI job
   remains a project-infra task — the script is self-contained and
   takes the `.app` path as its only argument.
6. ⏳ Cross-target rule sync (deferred — not a Phase 5 requirement).
   Each target keeps its own per-app sandbox `EditableSourceStore`;
   users carry rules across manually via `.lingyue-backup`.

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
