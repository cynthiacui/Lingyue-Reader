---
name: lingyue-build-verify
description: How to build + install + run the Lingyue iOS app on a simulator for verification WITHOUT wiping the user's books, source rules, reading stats, or `@AppStorage` preferences (including the first-launch onboarding-seen flag). The destructive command is `xcrun simctl uninstall com.lingyue.reader` — it nukes the entire app sandbox container. Use this skill any time you're about to verify a Lingyue code change end-to-end on the simulator, or whenever you're running `xcodebuild` + `simctl install` + `simctl launch` against `LingyueAppStore`. Triggers: 验证 / verify / build + run / smoke launch / simctl install / install on simulator / re-install Lingyue / sanity-check the AppStore build / 重装 app / 测试新 build.
---

# Lingyue · Simulator Build Verification

You're driving the Lingyue iOS app on a booted simulator to verify a code change. The data the user has accumulated in that simulator (imported books, source rules, reading stats, the `@AppStorage` flag that suppresses the first-launch onboarding overlay) is **valuable** — they've been using this sim as a real test environment. Treat it like their real device.

## Core rule

**`xcrun simctl install` over an existing install preserves the data container.** That's an in-place app update, exactly like a TestFlight rollout. Use that path.

**`xcrun simctl uninstall` deletes the entire app sandbox** — `Library/Application Support/lingyue/*.json`, `Library/Preferences/com.lingyue.reader.plist`, downloaded chapters, web cache, all of it. The next launch comes up looking like a brand-new install: empty library, no source rules, onboarding overlay popping back up. **Don't run uninstall** unless the user explicitly asks for first-launch state.

## Canonical workflow

```bash
# 1. Build
xcodebuild -project lingyue.xcodeproj \
  -scheme LingyueAppStore \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=AE29EF4E-C36B-4813-BEB0-884EDB4C3DF6' \
  build 2>&1 | tail -3

# 2. Install (in-place — preserves the sandbox)
APP_PATH="/Users/xuanrrr/Library/Developer/Xcode/DerivedData/lingyue-aqykmwhwcnxxqmednygrmidegbxb/Build/Products/Debug-iphonesimulator/LingyueAppStore.app"
xcrun simctl install AE29EF4E-C36B-4813-BEB0-884EDB4C3DF6 "$APP_PATH"

# 3. Launch
xcrun simctl launch AE29EF4E-C36B-4813-BEB0-884EDB4C3DF6 com.lingyue.reader

# 4. Sanity check: is the process alive?
sleep 3
xcrun simctl spawn AE29EF4E-C36B-4813-BEB0-884EDB4C3DF6 launchctl list | grep -i lingyue

# 5. Screenshot if you want visual confirmation
xcrun simctl io AE29EF4E-C36B-4813-BEB0-884EDB4C3DF6 screenshot /tmp/lingyue-verify/$(date +%H%M%S).png
```

DerivedData path is deterministic for this project: `lingyue-aqykmwhwcnxxqmednygrmidegbxb`. If `xcodebuild` reports a different one for some reason (clean rebuild, Xcode preferences moved), use `find ~/Library/Developer/Xcode/DerivedData -name 'LingyueAppStore.app' -path '*Debug-iphonesimulator*' | head -1`.

The booted-by-default sim is iPhone 17 Pro, UUID `AE29EF4E-C36B-4813-BEB0-884EDB4C3DF6`. If it's not booted, `xcrun simctl boot AE29EF4E-...` or `xcrun simctl list devices booted` to pick another. Don't reset the device (`simctl erase`) — that's even more destructive than uninstall.

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
2. The bundled source rules CAN be re-imported: the gist holds the canonical copy (`REDACTED-SOURCE-GIST-URL`), and `docs/lingyue-sources.json` should also be on the user's Mac (gitignored, restored from git history during this session's earlier work).
3. Apologize, acknowledge the loss, and don't repeat the mistake.
