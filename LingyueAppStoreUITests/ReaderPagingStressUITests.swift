import XCTest

/// Reproduction harness for the reader's cross-chapter paging bugs. Drives real
/// pan gestures through the full UIPageViewController + bookend-commit stack at
/// frame-rate pacing — much tighter than a human, so the races surface in
/// hundreds of turns instead of hours of reading.
///
/// The fixture book (`--paging-stress-fixture`) has 150 chapters × 2 pages, so
/// every other forward swipe is a cross-chapter bookend commit, and chapters 2+
/// resolve through a synthetic 150–700 ms network delay (`lingyue-stress://`),
/// replaying the remote-chapter lifecycle that pure-local fixtures cannot.
///
/// Covered field reports:
///  - "读久了在某章第一页翻不到第二页" — continuous forward reading dead-ends at
///    a chapter boundary (`runPagingStress`).
///  - "新书直接跳到很后面的章节再往后翻，出现空白页或卡住" — a deep chapter-picker
///    jump into unloaded territory followed by immediate forward paging
///    (`runDeepJumpStress`).
final class ReaderPagingStressUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSlideModeSurvivesHundredsOfCrossChapterTurns() throws {
        let app = launchStressReader(transitionStyle: "slide")
        try runPagingStress(app: app, transitionStyle: "slide", turns: 320)
    }

    func testPageCurlModeSurvivesHundredsOfCrossChapterTurns() throws {
        let app = launchStressReader(transitionStyle: "pageCurl")
        try runPagingStress(app: app, transitionStyle: "pageCurl", turns: 320)
    }

    func testSlideModeDeepJumpThenForwardPaging() throws {
        let app = launchStressReader(transitionStyle: "slide")
        try runDeepJumpStress(app: app, transitionStyle: "slide")
    }

    func testPageCurlModeDeepJumpThenForwardPaging() throws {
        let app = launchStressReader(transitionStyle: "pageCurl")
        try runDeepJumpStress(app: app, transitionStyle: "pageCurl")
    }

    // MARK: - Shared launch / probes

    private func launchStressReader(transitionStyle: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--paging-stress-fixture",
            "--diagnostics-deep",
            "-reader.pageTransition", transitionStyle,
            "-reader.hasSeenHelpOverlay", "YES",
            "-library.hasSeenHelpOverlayV2", "YES",
            "-reader.usesTraditionalChinese", "NO",
            "-app.usesTraditionalChineseInterface", "NO",
            "-reader.fontSize", "18.0",
            "-reader.autoScroll", "NO",
            "-reader.twoColumn", "NO"
        ]
        app.launch()

        let bookRow = app.staticTexts["跨章压测"].firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 8), "书架上应出现压测书")
        bookRow.tap()

        let helpButton = app.buttons["开始阅读"].firstMatch
        if helpButton.waitForExistence(timeout: 2) {
            helpButton.tap()
        }

        XCTAssertTrue(
            pageMarkerQuery(in: app).firstMatch.waitForExistence(timeout: 8),
            "阅读器底栏应显示页码"
        )
        return app
    }

    /// Footer page marker, e.g. "1 / 2". Unique on screen (page body never
    /// contains a bare "n / m" line), so together with the chapter-title footer
    /// it identifies the visible page.
    private func pageMarkerQuery(in app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^\\d+ / \\d+$"))
    }

    private func chapterFooterQuery(in app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^第\\d+章 跨章章节\\d+$"))
    }

    /// Label of the first HITTABLE match. UIPageViewController keeps cached
    /// neighbour pages alive off-screen with live accessibility elements, so an
    /// existence check alone can report a footer that isn't the visible page's —
    /// including when the visible page is the blank fallback (whole-page
    /// background with no footer at all).
    private func firstHittableLabel(in query: XCUIElementQuery) -> String? {
        let count = min(query.count, 6)
        for index in 0..<count {
            let element = query.element(boundBy: index)
            if element.exists, element.isHittable {
                return element.label
            }
        }
        return nil
    }

    /// (signature, blank): `signature` identifies the visible page for stall
    /// detection; `blank == true` means the reader is open but no on-screen
    /// footer exists — the blank-fallback-page symptom.
    private func visibleState(in app: XCUIApplication) -> (signature: String, blank: Bool) {
        for _ in 0..<3 {
            let marker = firstHittableLabel(in: pageMarkerQuery(in: app))
            let chapterFooter = firstHittableLabel(in: chapterFooterQuery(in: app))
            if let marker, let chapterFooter {
                return (chapterFooter + "|" + marker, false)
            }
            usleep(150_000)
        }
        // Three probes over ~0.5s with no on-screen footer: mid-transition churn
        // or a genuinely blank page. Callers escalate only on a persistent run.
        return ("blank-\(Date().timeIntervalSince1970)", true)
    }

    private func swipeForward(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        // The brief hold before lift-off makes the synthetic touch-up land
        // reliably; a zero-hold fast drag sometimes loses its release on the
        // pageCurl recognizer and wedges the interactive transition mid-flight.
        start.press(forDuration: 0.03, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.08)
    }

    private func swipeBackward(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 0.03, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.08)
    }

    private func failWithDiagnosticsFlush(_ message: String) {
        // Backgrounding forces the diagnostics ring buffer to disk so the
        // post-mortem can read the stuck moment.
        XCUIDevice.shared.press(.home)
        sleep(2)
        XCTFail(message)
    }

    // MARK: - Continuous-reading stress

    private func runPagingStress(app: XCUIApplication, transitionStyle: String, turns: Int) throws {
        // The right-edge tap zone drives the programmatic requestTransition path,
        // interleaving it with gesture-driven curls the way real reading does.
        let forwardTapZone = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.55))

        var previousSignature = visibleState(in: app).signature
        var stalledSwipes = 0

        for turn in 0..<turns {
            // Every 9th turn, jab backward once before continuing forward so the
            // leading-bookend (previous chapter's last page) path gets real reps.
            if turn % 9 == 8 {
                swipeBackward(in: app)
                usleep(120_000)
            }
            if turn % 5 == 4 {
                forwardTapZone.tap()
            } else {
                swipeForward(in: app)
            }
            usleep(120_000)

            let state = visibleState(in: app)
            if state.blank || state.signature == previousSignature {
                stalledSwipes += 1
                // A short stall is legitimate while the next chapter is still on
                // its artificial network delay (forward turns are gated until the
                // content arrives); the field bug never recovers. Six distinct
                // failed turns (~4s) is far beyond the slowest synthetic load.
                if stalledSwipes >= 6 {
                    // One recovery window: a synthetic drag that lost its touch-up
                    // wedges UIKit's interactive transition, which the reader's
                    // 15s watchdog force-cancels. A genuine dead-end (the field
                    // bug) survives the wait AND the extra swipe.
                    sleep(17)
                    swipeForward(in: app)
                    usleep(400_000)
                    let recovered = visibleState(in: app)
                    if !recovered.blank, recovered.signature != state.signature {
                        stalledSwipes = 0
                        previousSignature = recovered.signature
                        continue
                    }
                    failWithDiagnosticsFlush(
                        "翻页在第\(turn + 1)次滑动后卡死：连续\(stalledSwipes)次前滑页面未变且等待自愈无效，签名=\(state.signature)，模式=\(transitionStyle)"
                    )
                    return
                }
            } else {
                stalledSwipes = 0
                previousSignature = state.signature
            }
        }

        // Flush diagnostics for post-run inspection even on success.
        XCUIDevice.shared.press(.home)
        sleep(2)
    }

    // MARK: - Deep-jump stress

    /// Field report: open a fresh book, jump straight to a much later chapter via
    /// the chapter picker, then page forward — the next chapter comes up blank
    /// (needs flipping back and forth to render) or the turn dead-ends entirely.
    /// Every jump lands in territory the prefetch window has never touched, so
    /// the forward turns race chapter loads, pagination, and bookend swaps.
    private func runDeepJumpStress(app: XCUIApplication, transitionStyle: String) throws {
        // Warm up inside chapter 1 like a reader sampling a new book.
        swipeForward(in: app)
        usleep(200_000)

        for (cycle, target) in [60, 100, 130].enumerated() {
            jumpToChapter(target, in: app)
            // Let the jump land; the chapter itself may still be loading, which
            // is exactly the state the field report starts from.
            usleep(400_000)

            var previousSignature = visibleState(in: app).signature
            var stalledTurns = 0
            var blankProbes = 0

            for turn in 0..<14 {
                // Mix one backward turn in so the freshly-built leading bookend
                // is exercised right after the jump too.
                if turn == 9 {
                    swipeBackward(in: app)
                    usleep(150_000)
                }
                swipeForward(in: app)
                usleep(150_000)

                let state = visibleState(in: app)
                if state.blank {
                    blankProbes += 1
                    // One blank probe can be an in-flight animation; two in a row
                    // (with a settle wait between) is the reported blank page.
                    if blankProbes >= 2 {
                        sleep(2)
                        if visibleState(in: app).blank {
                            failWithDiagnosticsFlush(
                                "深跳到第\(target)章后第\(turn + 1)次前翻出现持续空白页，模式=\(transitionStyle)，轮次=\(cycle + 1)"
                            )
                            return
                        }
                        blankProbes = 0
                    }
                } else {
                    blankProbes = 0
                }

                if state.signature == previousSignature {
                    stalledTurns += 1
                    if stalledTurns >= 6 {
                        sleep(17)
                        swipeForward(in: app)
                        usleep(400_000)
                        let recovered = visibleState(in: app)
                        if !recovered.blank, recovered.signature != state.signature {
                            stalledTurns = 0
                            previousSignature = recovered.signature
                            continue
                        }
                        failWithDiagnosticsFlush(
                            "深跳到第\(target)章后第\(turn + 1)次前翻卡死且等待自愈无效，签名=\(state.signature)，模式=\(transitionStyle)"
                        )
                        return
                    }
                } else {
                    stalledTurns = 0
                    previousSignature = state.signature
                }
            }
        }

        XCUIDevice.shared.press(.home)
        sleep(2)
    }

    /// Opens the reader controls, then the chapter picker, scrolls the lazy list
    /// until the target chapter's row materializes, and taps it.
    private func jumpToChapter(_ number: Int, in app: XCUIApplication) {
        let pickerButton = app.buttons["章节目录"].firstMatch
        if !pickerButton.exists || !pickerButton.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(pickerButton.waitForExistence(timeout: 3), "工具栏应有章节目录按钮")
        }
        pickerButton.tap()

        XCTAssertTrue(
            app.staticTexts["章节目录"].firstMatch.waitForExistence(timeout: 3),
            "章节目录弹层应出现"
        )

        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "第\(number)章 跨章章节\(number)")
        ).firstMatch
        // The modal is centered (≈360×460pt), so keep scroll drags inside its
        // vertical band; slow velocity avoids momentum flinging the lazy list
        // past the target row before it materializes.
        let dragFrom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.64))
        let dragTo = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34))
        var attempts = 0
        while !(row.exists && row.isHittable) && attempts < 50 {
            dragFrom.press(
                forDuration: 0.03,
                thenDragTo: dragTo,
                withVelocity: XCUIGestureVelocity(300),
                thenHoldForDuration: 0.05
            )
            attempts += 1
        }
        XCTAssertTrue(row.exists && row.isHittable, "目录应能滚动到第\(number)章")
        row.tap()
    }
}
