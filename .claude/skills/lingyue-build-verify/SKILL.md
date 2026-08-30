---
name: lingyue-build-verify
description: How to build + install + run the Lingyue iOS app on a simulator for verification WITHOUT wiping the user's books, source rules, reading stats, or `@AppStorage` preferences (including the first-launch onboarding-seen flag). The destructive command is `xcrun simctl uninstall com.lingyue.reader` — it nukes the entire app sandbox container. Use this skill any time you're about to verify a Lingyue code change end-to-end on the simulator, or whenever you're running `xcodebuild` + `simctl install` + `simctl launch` against `LingyueAppStore`. Triggers: 验证 / verify / build + run / smoke launch / simctl install / install on simulator / re-install Lingyue / sanity-check the AppStore build / 重装 app / 测试新 build.
---

# Lingyue · Simulator Build Verification

You're driving the Lingyue iOS app on a booted simulator to verify a code change. Any data accumulated in that simulator (imported books, source rules, reading stats, the `@AppStorage` flag that suppresses the first-launch onboarding overlay) is **valuable** — treat an established sim like the user's real device.

## Core rule

**`xcrun simctl install` over an existing install preserves the data container.** That's an in-place app update, exactly like a TestFlight rollout. Use that path.

**`xcrun simctl uninstall` deletes the entire app sandbox** — `Library/Application Support/lingyue/*.json`, `Library/Preferences/com.lingyue.reader.plist`, downloaded chapters, web cache, all of it. The next launch comes up looking like a brand-new install: empty library, no source rules, onboarding overlay popping back up. **Don't run uninstall** unless the user explicitly asks for first-launch state.

## Picking the simulator

Do NOT hardcode a device UUID — Xcode runtime upgrades recreate the device list and silently orphan old UUIDs (this has already happened once: the former iPhone 17 Pro sim `AE29EF4E-…` vanished, along with the test data on it). Resolve the target dynamically:

```bash
# Prefer whatever is already booted
xcrun simctl list devices booted

# Nothing booted? List candidates and boot one (prefer the newest iOS iPhone)
xcrun simctl list devices available | grep -i iphone
xcrun simctl boot <UDID>
```

As of 2026-08, the working device is iPhone 17 (iOS 26.5) `5F6549FE-2A82-4D03-AB62-98CE0B537E43` — but verify with `simctl list` before relying on it. Don't reset a device (`simctl erase`) — that's even more destructive than uninstall.

## Canonical workflow

```bash
UDID=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)

# 1. Build
xcodebuild -project lingyue.xcodeproj \
  -scheme LingyueAppStore \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$UDID" \
  build 2>&1 | tail -3

# 2. Install (in-place — preserves the sandbox)
APP_PATH="/Users/xuanrrr/Library/Developer/Xcode/DerivedData/lingyue-aqykmwhwcnxxqmednygrmidegbxb/Build/Products/Debug-iphonesimulator/LingyueAppStore.app"
xcrun simctl install "$UDID" "$APP_PATH"

# 3. Launch
xcrun simctl launch "$UDID" com.lingyue.reader

# 4. Sanity check: is the process alive?
sleep 3
xcrun simctl spawn "$UDID" launchctl list | grep -i lingyue

# 5. Screenshot if you want visual confirmation
xcrun simctl io "$UDID" screenshot /tmp/lingyue-verify/$(date +%H%M%S).png
```

DerivedData path is deterministic for this project: `lingyue-aqykmwhwcnxxqmednygrmidegbxb`. If `xcodebuild` reports a different one for some reason (clean rebuild, Xcode preferences moved), use `find ~/Library/Developer/Xcode/DerivedData -name 'LingyueAppStore.app' -path '*Debug-iphonesimulator*' | head -1`.

Beware stale incremental state: if the test target suddenly can't see an app-module type that clearly exists, the products-dir `LingyueAppStore.swiftmodule` is probably outdated — `touch` the affected source file (or any app source) and rebuild the app target before blaming the code.

## Reader paging stress harness (cross-chapter bugs)

For reader page-turn / chapter-boundary bugs, don't hand-swipe — the repo has a purpose-built harness:

```bash
xcodebuild test -project lingyue.xcodeproj -scheme LingyueAppStore \
  -destination "platform=iOS Simulator,id=<UDID>" \
  -only-testing:LingyueAppStoreUITests/ReaderPagingStressUITests
```

- `--paging-stress-fixture` (DEBUG launch arg, set by the test) seeds a 150-chapter, 2-pages-per-chapter book. Chapter 1 is inline; chapters 2+ use `lingyue-stress://chapter/<n>` URLs, which `ChapterContentCache` resolves in DEBUG with an artificial 150–700 ms delay (occasional 3× outliers), bypassing all caches. This replays the remote-chapter lifecycle (loading placeholders, pagination-signature flips, bookends appearing mid-read) that pure-local fixtures cannot — the 2026-08 "stuck at a chapter's first page" bug ONLY reproduced with this.
- The test mixes fast swipes, right-edge taps, and backward jitter (~320 turns, both slide and pageCurl), detects a dead-end via the footer page label, and pauses 17 s before failing so the reader's stuck-gesture watchdog gets one self-heal window.
- `--diagnostics-deep` (also set by the test) grows the ReaderDiagnostics ring buffer 300 → 4000 entries. Afterwards read `$CONT/…/Diagnostics/current.json`: healthy runs show `pager slots changed` / `pager neighbor refresh` tracking every `bookend commit`; a broken update pipeline shows `pager dataSource nil` streaks with a frozen `updates` counter.
- Synthetic drags need a real touch-up: use `press(forDuration: 0.03, thenDragTo:withVelocity:.fast, thenHoldForDuration: 0.08)`. Zero-hold fast drags sometimes lose the release and wedge UIKit's interactive page transition (the reader force-cancels such recognizers after 15 s).

## Seeding a reader test book (no network needed)

To drive the reader end-to-end on a fresh sim without real sources, seed a local multi-chapter book and skip the first-run overlays. Do this BEFORE the app's first launch (or while it's terminated):

```bash
UDID=<udid>
CONT=$(xcrun simctl get_app_container "$UDID" com.lingyue.reader data)
mkdir -p "$CONT/Library/Application Support/lingyue"
cp <fixture>.json "$CONT/Library/Application Support/lingyue/LibraryStore.json"

# Reader prefs: UIPageViewController paths are exercised by slide / pageCurl
xcrun simctl spawn "$UDID" defaults write com.lingyue.reader reader.pageTransition -string slide
xcrun simctl spawn "$UDID" defaults write com.lingyue.reader reader.hasSeenHelpOverlay -bool true
xcrun simctl spawn "$UDID" defaults write com.lingyue.reader library.hasSeenHelpOverlayV2 -bool true
```

Fixture shape (`LibraryStorageSnapshot`): `{"version": 1, "categories": [{"id": "<UUID>", "name": "无分类", "novels": [<Novel>]}], "archivedBooks": []}`. A local Novel carries inline chapters — `chapters: [{id, title, content, sourceURLString: null}]` — plus `sourceURLString: "lingyue-local-txt://import/<percent-encoded title>"` so the library card shows 本地TXT. Dates (`addedAt`) are `Double` seconds since reference date. ~40 sentences of Chinese per chapter ≈ 4 pages at default font on an iPhone 17. Number the sentences per chapter (e.g. 第2章第07句) so screenshots identify the exact page.

Diagnostics land in `$CONT/Library/Application Support/lingyue/Diagnostics/current.json` (rotated to `previous.json` on next launch). Writes are throttled — press HOME (background the app) to force a flush before reading the file.

## When uninstall IS the right call

There are a few legitimate reasons to wipe; **all of them require the user to ask for it explicitly or the goal to genuinely depend on a fresh launch**:

- The user wants to test the first-launch onboarding overlay (or any other first-run code path).
- A migration step is added and you specifically want to verify the no-prior-data branch.
- The schema-on-disk has incompatibly changed and you've already established with the user that wiping is the migration path.

If you do uninstall, say so explicitly *before* the command runs so the user can stop you: "I'm about to wipe the sim's data to test first-launch — yes?"

## Don't

- ❌ `xcrun simctl uninstall com.lingyue.reader` "just to make sure it's a clean install" — install over an existing app is already clean from the binary's perspective; the data is the user's data.
- ❌ `xcrun simctl erase <UDID>` — nukes the whole device, including every other app and its data.
- ❌ Running `rm -rf` against `~/Library/Developer/CoreSimulator/Devices/...` — same as above, plus risk of typo.
- ❌ Treating `simctl uninstall` as the iOS equivalent of "clean build" — it isn't. The "clean build" equivalent is `rm -rf ~/Library/Developer/Xcode/DerivedData/lingyue-*`, which is purely build artifacts.

## Recovery if you wiped

If you ran `simctl uninstall` and the user is upset (legitimately):

1. **You can't recover the books / library / reading stats from inside the simulator** — that container is gone.
2. The bundled source rules CAN be re-imported: the canonical copy lives in a secret gist whose URL is kept in the private `release-and-source-distribution` memory (deliberately **not** published in this repo — the repo is reachable from the App Store listing), and `docs/lingyue-sources.json` should also be on the user's Mac (gitignored).
3. Apologize, acknowledge the loss, and don't repeat the mistake.
