import UIKit
import SwiftUI
import XCTest
import LingyueCore
@testable import LingyueAppStore

final class AppUpdateAnnouncementStoreTests: XCTestCase {
    func testForceLaunchArgumentShowsAnnouncementAgainWithoutChangingInstallCohort() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        context.defaults.set(
            true,
            forKey: AppUpdateAnnouncementStore.seenKey(for: .libraryArchiveV1_2)
        )

        let forcedLaunch = AppUpdateAnnouncementStore(
            defaults: context.defaults,
            persistentDomainName: context.domainName,
            currentVersion: "1.2",
            applicationSupportDirectory: context.supportDirectory,
            arguments: [AppUpdateAnnouncementStore.forceShowArgument]
        )

        XCTAssertFalse(forcedLaunch.isExistingInstallation)
        XCTAssertEqual(forcedLaunch.pendingAnnouncement, .libraryArchiveV1_2)
    }

    func testArchiveAnnouncementIntroducesCategoryReordering() {
        XCTAssertTrue(
            AppUpdateAnnouncement.libraryArchiveV1_2.bullets.contains {
                $0.text == "长按分类标题，就能拖动调整分类顺序"
            }
        )
    }

    func testFreshInstallDoesNotShowUpdateAnnouncementAcrossRelaunches() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        let firstLaunch = AppUpdateAnnouncementStore(
            defaults: context.defaults,
            persistentDomainName: context.domainName,
            currentVersion: "1.2",
            applicationSupportDirectory: context.supportDirectory,
            arguments: []
        )

        XCTAssertFalse(firstLaunch.isExistingInstallation)
        XCTAssertNil(firstLaunch.pendingAnnouncement)
        XCTAssertEqual(
            context.defaults.string(forKey: AppUpdateAnnouncementStore.firstInstalledVersionKey),
            "1.2"
        )

        let secondLaunch = AppUpdateAnnouncementStore(
            defaults: context.defaults,
            persistentDomainName: context.domainName,
            currentVersion: "1.2",
            applicationSupportDirectory: context.supportDirectory,
            arguments: []
        )

        XCTAssertFalse(secondLaunch.isExistingInstallation)
        XCTAssertNil(secondLaunch.pendingAnnouncement)
    }

    func testLegacyInstallShowsArchiveAnnouncementOnlyOnce() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        context.defaults.set(true, forKey: "library.hasSeenHelpOverlay")

        let upgradedLaunch = AppUpdateAnnouncementStore(
            defaults: context.defaults,
            persistentDomainName: context.domainName,
            currentVersion: "1.2",
            applicationSupportDirectory: context.supportDirectory,
            arguments: []
        )

        XCTAssertTrue(upgradedLaunch.isExistingInstallation)
        XCTAssertEqual(upgradedLaunch.pendingAnnouncement, .libraryArchiveV1_2)

        upgradedLaunch.dismissPendingAnnouncement()
        XCTAssertNil(upgradedLaunch.pendingAnnouncement)
        XCTAssertTrue(
            context.defaults.bool(
                forKey: AppUpdateAnnouncementStore.seenKey(for: .libraryArchiveV1_2)
            )
        )

        let nextLaunch = AppUpdateAnnouncementStore(
            defaults: context.defaults,
            persistentDomainName: context.domainName,
            currentVersion: "1.2",
            applicationSupportDirectory: context.supportDirectory,
            arguments: []
        )
        XCTAssertNil(nextLaunch.pendingAnnouncement)
    }

    func testExistingApplicationSupportDataCountsAsUpgradeEvidence() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(
            at: context.supportDirectory,
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(
            to: context.supportDirectory.appendingPathComponent("LibraryStore.json")
        )

        let upgradedLaunch = AppUpdateAnnouncementStore(
            defaults: context.defaults,
            persistentDomainName: context.domainName,
            currentVersion: "1.2",
            applicationSupportDirectory: context.supportDirectory,
            arguments: []
        )

        XCTAssertTrue(upgradedLaunch.isExistingInstallation)
        XCTAssertEqual(upgradedLaunch.pendingAnnouncement, .libraryArchiveV1_2)
    }

    private func makeContext() throws -> AnnouncementTestContext {
        let domainName = "AppUpdateAnnouncementStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domainName))
        defaults.removePersistentDomain(forName: domainName)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdateAnnouncementStoreTests-\(UUID().uuidString)")
        return AnnouncementTestContext(
            defaults: defaults,
            domainName: domainName,
            rootDirectory: root,
            supportDirectory: root.appendingPathComponent("lingyue", isDirectory: true)
        )
    }
}

private struct AnnouncementTestContext {
    let defaults: UserDefaults
    let domainName: String
    let rootDirectory: URL
    let supportDirectory: URL

    func cleanup() {
        defaults.removePersistentDomain(forName: domainName)
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

final class CategoryReorderStateTests: XCTestCase {
    @MainActor
    func testDragSnapshotContainsVisiblePixels() throws {
        let image = try XCTUnwrap(
            CategoryDragSnapshotRenderer.image(
                for: RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red)
                    .frame(width: 40, height: 30),
                displayScale: 2
            )
        )
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        XCTAssertEqual(image.size, CGSize(width: 40, height: 30))
        XCTAssertGreaterThan(pixel[3], 0)
    }

    @MainActor
    func testFullCategoryDragPreviewRendersTitleAndBookArea() throws {
        let model = makeDragPreviewModel()
        let image = try XCTUnwrap(
            CategoryDragSnapshotRenderer.image(
                for: CategoryDragPreview(model: model, width: 340),
                displayScale: 2
            )
        )

        XCTAssertEqual(image.size.width, 340, accuracy: 0.5)
        XCTAssertGreaterThan(image.size.height, CategoryShelfMetrics.cardHeight)
        XCTAssertNotNil(image.cgImage)
    }

    @MainActor
    func testFullCategoryDragPreviewRenderPerformance() {
        let model = makeDragPreviewModel()
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            _ = autoreleasepool {
                CategoryDragSnapshotRenderer.image(
                    for: CategoryDragPreview(model: model, width: 340),
                    displayScale: 2
                )
            }
        }
    }

    func testQuickReleaseBeforeDragReturnsDirectlyToIdle() {
        let categoryID = UUID()
        let session = CategoryReorderSession(id: UUID(), categoryID: categoryID)
        var state = CategoryReorderState()

        state.touchBegan(session: session)
        XCTAssertEqual(state.phase, .pressing(session))
        XCTAssertFalse(state.transferIsActive)

        state.touchEnded(sessionID: session.id)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.sourceCategoryID)
        XCTAssertNil(state.targetCategoryID)
    }

    func testReleaseClearsHighlightButRetainsSourceUntilDropCompletes() {
        let sourceID = UUID()
        let targetID = UUID()
        let session = CategoryReorderSession(id: UUID(), categoryID: sourceID)
        var state = CategoryReorderState()

        state.touchBegan(session: session)
        state.dragBegan(session: session)
        state.enteredTarget(categoryID: targetID)

        XCTAssertTrue(state.isSourceHighlighted(sourceID))
        XCTAssertEqual(state.targetCategoryID, targetID)

        state.touchEnded(sessionID: session.id)
        XCTAssertEqual(state.phase, .released(session))
        XCTAssertFalse(state.isSourceHighlighted(sourceID))
        XCTAssertEqual(state.sourceCategoryID, sourceID)
        XCTAssertEqual(state.targetCategoryID, targetID)

        state.finish()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.sourceCategoryID)
        XCTAssertNil(state.targetCategoryID)
    }

    func testCancelClearsTargetBeforeNextDrag() {
        let firstSourceID = UUID()
        let staleTargetID = UUID()
        let nextSourceID = UUID()
        let firstSession = CategoryReorderSession(id: UUID(), categoryID: firstSourceID)
        let nextSession = CategoryReorderSession(id: UUID(), categoryID: nextSourceID)
        var state = CategoryReorderState()

        state.touchBegan(session: firstSession)
        state.dragBegan(session: firstSession)
        state.enteredTarget(categoryID: staleTargetID)
        state.touchEnded(sessionID: firstSession.id)
        state.finish()

        state.touchBegan(session: nextSession)
        state.dragBegan(session: nextSession)
        XCTAssertEqual(state.sourceCategoryID, nextSourceID)
        XCTAssertNil(state.targetCategoryID)
    }

    func testLateCallbackFromOldDragCannotClearNewDrag() {
        let oldCategoryID = UUID()
        let newCategoryID = UUID()
        let oldSession = CategoryReorderSession(id: UUID(), categoryID: oldCategoryID)
        let newSession = CategoryReorderSession(id: UUID(), categoryID: newCategoryID)
        var state = CategoryReorderState()

        state.touchBegan(session: oldSession)
        state.dragBegan(session: oldSession)
        state.finish(sessionID: oldSession.id)
        state.touchBegan(session: newSession)
        state.dragBegan(session: newSession)

        state.finish(sessionID: oldSession.id)
        XCTAssertEqual(state.phase, .dragging(newSession))
        XCTAssertEqual(state.sourceCategoryID, newCategoryID)
    }

    func testLateCallbackCannotClearNewDragOfTheSameCategory() {
        let categoryID = UUID()
        let oldSession = CategoryReorderSession(id: UUID(), categoryID: categoryID)
        let newSession = CategoryReorderSession(id: UUID(), categoryID: categoryID)
        var state = CategoryReorderState()

        state.touchBegan(session: oldSession)
        state.dragBegan(session: oldSession)
        state.finish(sessionID: oldSession.id)
        state.touchBegan(session: newSession)
        state.dragBegan(session: newSession)

        state.touchEnded(sessionID: oldSession.id)
        state.finish(sessionID: oldSession.id)

        XCTAssertEqual(state.phase, .dragging(newSession))
        XCTAssertTrue(state.isSourceHighlighted(categoryID))
    }

    func testGestureCompletionReturnsMoveAndResetsState() {
        let sourceID = UUID()
        let targetID = UUID()
        let session = CategoryReorderSession(id: UUID(), categoryID: sourceID)
        var state = CategoryReorderState()

        state.touchBegan(session: session)
        state.dragBegan(session: session)
        state.updateTarget(categoryID: targetID, sessionID: session.id)

        XCTAssertEqual(
            state.complete(sessionID: session.id),
            CategoryReorderMove(
                sourceCategoryID: sourceID,
                targetCategoryID: targetID
            )
        )
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.targetCategoryID)
    }

    func testStaleGestureCannotRetargetOrCompleteNewSession() {
        let categoryID = UUID()
        let oldSession = CategoryReorderSession(id: UUID(), categoryID: categoryID)
        let newSession = CategoryReorderSession(id: UUID(), categoryID: categoryID)
        var state = CategoryReorderState()

        state.touchBegan(session: oldSession)
        state.dragBegan(session: oldSession)
        state.finish(sessionID: oldSession.id)
        state.touchBegan(session: newSession)
        state.dragBegan(session: newSession)

        state.updateTarget(categoryID: UUID(), sessionID: oldSession.id)
        XCTAssertNil(state.complete(sessionID: oldSession.id))
        XCTAssertEqual(state.phase, .dragging(newSession))
        XCTAssertNil(state.targetCategoryID)
    }

    private func makeDragPreviewModel() -> CategoryDragPreviewModel {
        let novels = (0..<3).map { index in
            Novel(
                title: "预览书籍\(index + 1)",
                author: "作者",
                genre: "测试",
                summary: "",
                lastChapter: "第\(index + 1)章",
                progress: Double(index) * 0.2,
                readMinutes: index,
                addedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                coverPalette: NovelCoverPalette.allCases[index],
                isFeatured: false
            )
        }
        return CategoryDragPreviewModel(
            category: LibraryCategory(name: "测试分类", novels: novels),
            visibleNovels: novels,
            usesTraditionalChinese: false
        )
    }
}

final class LibraryPreviewSelectionTests: XCTestCase {
    func testPreviewSelectsOnlyThreeMostRelevantBooksInDisplayOrder() {
        let older = makeNovel(title: "较早", openedAt: 10, readMinutes: 500)
        let tiedLower = makeNovel(title: "同日短读", openedAt: 20, readMinutes: 5)
        let newest = makeNovel(title: "最新", openedAt: 30, readMinutes: 1)
        let tiedHigher = makeNovel(title: "同日长读", openedAt: 20, readMinutes: 50)

        let result = [older, tiedLower, newest, tiedHigher]
            .libraryPreviewNovels(limit: 3)

        XCTAssertEqual(result.map(\.title), ["最新", "同日长读", "同日短读"])
    }

    func testPreviewSelectionHandlesZeroLimit() {
        XCTAssertTrue([makeNovel(title: "一本", openedAt: 1)].libraryPreviewNovels(limit: 0).isEmpty)
    }

    private func makeNovel(
        title: String,
        openedAt: TimeInterval,
        readMinutes: Int = 0
    ) -> Novel {
        Novel(
            title: title,
            author: "测试",
            genre: "测试",
            summary: "",
            lastChapter: "第一章",
            progress: 0,
            readMinutes: readMinutes,
            lastOpenedAt: Date(timeIntervalSince1970: openedAt),
            coverPalette: .teal,
            isFeatured: false
        )
    }
}

final class ReadingStatsLedgerTests: XCTestCase {
    func testReadableCharacterCountExcludesWhitespaceAndPunctuation() {
        XCTAssertEqual(
            ReadingTextMetrics.characterCount(in: "第一章：Hello, 世界！123\n"),
            13
        )
    }

    func testOnlyForwardTurnsCountAndTwoPageSpreadsUseTheirStep() {
        let novel = makeNovel()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = ReadingStatsLedger()
        ledger.startReadingSession(
            novel: novel,
            timestamp: start,
            progress: 0,
            chapterIndex: 0,
            chapterPageIndex: 0,
            chapterSourceURLString: "chapter-0"
        )

        ledger.recordReading(
            novel: novel,
            timestamp: start.addingTimeInterval(10),
            chapterTitle: "第一章",
            progress: 0.1,
            chapterIndex: 0,
            chapterPageIndex: 1,
            chapterSourceURLString: "chapter-0",
            pageTextCharacterCount: 420
        )
        ledger.recordReading(
            novel: novel,
            timestamp: start.addingTimeInterval(20),
            chapterTitle: "第一章",
            progress: 0,
            chapterIndex: 0,
            chapterPageIndex: 0,
            chapterSourceURLString: "chapter-0",
            pageTextCharacterCount: 410
        )
        ledger.recordReading(
            novel: novel,
            timestamp: start.addingTimeInterval(30),
            chapterTitle: "第一章",
            progress: 0.2,
            chapterIndex: 0,
            chapterPageIndex: 2,
            chapterSourceURLString: "chapter-0",
            pageTextCharacterCount: 830,
            pageTurnStep: 2
        )

        XCTAssertEqual(ledger.events.count, 2)
        XCTAssertEqual(ledger.totalPageTurns, 2)
        XCTAssertEqual(ledger.totalCharacterCount, 1_250)
    }

    func testLegacyWholeChapterEventIsRepairedExactlyOnce() throws {
        let novel = makeNovel(progress: 1)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let inflatedEventID = UUID()
        var events: [ReadingStatsEvent] = [
            makeEvent(novel: novel, timestamp: start, count: 500, chapter: "第一章", progress: 0.1),
            makeEvent(novel: novel, timestamp: start.addingTimeInterval(1), count: 480, chapter: "第一章", progress: 0.2),
            makeEvent(id: inflatedEventID, novel: novel, timestamp: start.addingTimeInterval(2), count: 3_000, chapter: "第二章", progress: 0.3)
        ]
        for offset in 3...7 {
            events.append(
                makeEvent(
                    novel: novel,
                    timestamp: start.addingTimeInterval(TimeInterval(offset)),
                    count: 500,
                    chapter: "第二章",
                    progress: 0.3 + Double(offset - 2) * 0.05
                )
            )
        }
        events.append(
            makeEvent(
                novel: novel,
                timestamp: start.addingTimeInterval(8),
                count: 510,
                chapter: "第三章",
                progress: 0.7
            )
        )
        let book = ReadingStatsBook(
            id: novel.id,
            title: novel.title,
            author: novel.author,
            coverPalette: novel.coverPalette,
            coverImageURLString: nil,
            sourceURLString: nil,
            firstReadAt: start,
            lastReadAt: start.addingTimeInterval(8),
            deletedAt: nil,
            currentProgress: 1,
            totalDurationSeconds: 80,
            pageTurns: events.count,
            characterCount: events.reduce(0) { $0 + $1.characterCount }
        )
        let encoded = try JSONEncoder().encode(ReadingStatsLedger(books: [book], events: events))
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "characterCountingVersion")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        var ledger = try JSONDecoder().decode(ReadingStatsLedger.self, from: legacyData)

        XCTAssertTrue(ledger.repairLegacyCharacterCounts())
        XCTAssertEqual(
            ledger.events.first(where: { $0.id == inflatedEventID })?.characterCount,
            500
        )
        XCTAssertEqual(
            ledger.books.first?.characterCount,
            ledger.events.reduce(0) { $0 + $1.characterCount }
        )
        XCTAssertFalse(ledger.repairLegacyCharacterCounts())
    }

    /// A session at 1 AM belongs to the previous evening's reading day (4 AM
    /// boundary): it must extend that day's streak rather than start a new day, and
    /// a following afternoon session lands on the actual new day.
    func testPostMidnightSessionCountsTowardThePreviousReadingDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
        }
        let novel = makeNovel()
        var ledger = ReadingStatsLedger(events: [
            makeEvent(novel: novel, timestamp: date(25, 21), count: 400, chapter: "第一章", progress: 0.1, duration: 300),
            makeEvent(novel: novel, timestamp: date(26, 1), count: 400, chapter: "第一章", progress: 0.2, duration: 300)
        ])

        // At 2 AM on the 26th the reading day is still the 25th: one active day.
        XCTAssertEqual(ledger.currentStreak(reference: date(26, 2), calendar: calendar), 1)
        // At noon on the 26th nothing has been read on the new day yet; the streak
        // from the 25th survives on grace.
        XCTAssertEqual(ledger.currentStreak(reference: date(26, 12), calendar: calendar), 1)

        ledger.events.append(
            makeEvent(novel: novel, timestamp: date(26, 13), count: 400, chapter: "第一章", progress: 0.3, duration: 300)
        )
        XCTAssertEqual(ledger.currentStreak(reference: date(26, 14), calendar: calendar), 2)
    }

    /// The "opened the app, turned a few pages, stats claim tens of thousands of
    /// characters" report: the legacy counter recorded the whole next chapter when a
    /// page turn crossed a chapter boundary. That inflated event usually sits in the
    /// *trailing* run — the chapter the user is still reading — where no following
    /// chapter exists to validate a remainder inference. It must still be repaired,
    /// down to one median page.
    func testTrailingRunWholeChapterOutlierIsRepairedToOneTypicalPage() throws {
        let novel = makeNovel(progress: 0.3)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let inflatedEventID = UUID()
        let events: [ReadingStatsEvent] = [
            makeEvent(novel: novel, timestamp: start, count: 420, chapter: "第一章", progress: 0.1),
            makeEvent(novel: novel, timestamp: start.addingTimeInterval(1), count: 430, chapter: "第一章", progress: 0.15),
            makeEvent(id: inflatedEventID, novel: novel, timestamp: start.addingTimeInterval(2), count: 15_000, chapter: "第二章", progress: 0.2),
            makeEvent(novel: novel, timestamp: start.addingTimeInterval(3), count: 410, chapter: "第二章", progress: 0.25),
            makeEvent(novel: novel, timestamp: start.addingTimeInterval(4), count: 425, chapter: "第二章", progress: 0.3)
        ]
        var ledger = try makeLegacyLedger(novel: novel, events: events, lastTick: 4)

        XCTAssertTrue(ledger.repairLegacyCharacterCounts())
        // Median rendered page across [410, 420, 425, 430, 15000] is 425.
        XCTAssertEqual(
            ledger.events.first(where: { $0.id == inflatedEventID })?.characterCount,
            425
        )
        XCTAssertEqual(ledger.books.first?.characterCount, 420 + 430 + 425 + 410 + 425)
    }

    /// A dev install that already ran the version-1 migration got stamped as migrated
    /// while its trailing-run outlier survived (version 1 only repaired completed
    /// runs). Version 2 must pick these ledgers up again.
    func testVersionOneStampedLedgerIsRepairedAgainByVersionTwo() throws {
        let novel = makeNovel(progress: 0.3)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let inflatedEventID = UUID()
        let events: [ReadingStatsEvent] = [
            makeEvent(novel: novel, timestamp: start, count: 420, chapter: "第一章", progress: 0.1),
            makeEvent(novel: novel, timestamp: start.addingTimeInterval(1), count: 430, chapter: "第一章", progress: 0.15),
            makeEvent(id: inflatedEventID, novel: novel, timestamp: start.addingTimeInterval(2), count: 15_000, chapter: "第二章", progress: 0.2),
            makeEvent(novel: novel, timestamp: start.addingTimeInterval(3), count: 410, chapter: "第二章", progress: 0.25)
        ]
        var ledger = try makeLegacyLedger(novel: novel, events: events, lastTick: 3, version: 1)

        XCTAssertTrue(ledger.repairLegacyCharacterCounts())
        // Median rendered page across [410, 420, 430, 15000] (lower-middle) is 420.
        XCTAssertEqual(
            ledger.events.first(where: { $0.id == inflatedEventID })?.characterCount,
            420
        )
        XCTAssertFalse(ledger.repairLegacyCharacterCounts())
    }

    /// A boundary crossing followed by closing the book leaves a lone whole-chapter
    /// event as an entire run — possibly the book's first retained event when older
    /// activity was compacted away. Outlier size alone identifies it.
    func testLoneBoundaryCrossingOutlierIsRepairedWithoutSurroundingRuns() throws {
        let novel = makeNovel(progress: 0.2)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let inflatedEventID = UUID()
        let events: [ReadingStatsEvent] = [
            makeEvent(id: inflatedEventID, novel: novel, timestamp: start, count: 12_000, chapter: "第五章", progress: 0.2),
            makeEvent(novel: novel, timestamp: start.addingTimeInterval(1), count: 380, chapter: "第六章", progress: 0.25)
        ]
        var ledger = try makeLegacyLedger(novel: novel, events: events, lastTick: 1)

        XCTAssertTrue(ledger.repairLegacyCharacterCounts())
        // Even-count ledgers must take the lower-middle median; the upper-middle here
        // is the 12,000-character placeholder itself, which would block the repair.
        XCTAssertEqual(
            ledger.events.first(where: { $0.id == inflatedEventID })?.characterCount,
            380
        )
        XCTAssertEqual(ledger.books.first?.characterCount, 380 + 380)
    }

    func testCompletedBookMigrationRestoresItsActualPageTotal() throws {
        let novel = makeNovel(progress: 1)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let pageCounts = [500, 500, 500, 500, 500, 500, 300]
        var events: [ReadingStatsEvent] = []
        var tick = 0

        for chapterIndex in 0..<100 {
            let title = "第\(chapterIndex + 1)章"
            let chapterProgress = Double(chapterIndex) / 100
            if chapterIndex == 0 {
                for count in pageCounts {
                    events.append(
                        makeEvent(
                            novel: novel,
                            timestamp: start.addingTimeInterval(TimeInterval(tick)),
                            count: count,
                            chapter: title,
                            progress: chapterProgress + 0.005
                        )
                    )
                    tick += 1
                }
            } else {
                // Legacy boundary observation: whole 3,300-character chapter, followed
                // by its real pages except page zero (which shares the same page key).
                events.append(
                    makeEvent(
                        novel: novel,
                        timestamp: start.addingTimeInterval(TimeInterval(tick)),
                        count: 3_300,
                        chapter: title,
                        progress: chapterProgress
                    )
                )
                tick += 1
                for count in pageCounts.dropFirst() {
                    events.append(
                        makeEvent(
                            novel: novel,
                            timestamp: start.addingTimeInterval(TimeInterval(tick)),
                            count: count,
                            chapter: title,
                            progress: chapterProgress + 0.005
                        )
                    )
                    tick += 1
                }
            }
        }

        let book = ReadingStatsBook(
            id: novel.id,
            title: novel.title,
            author: novel.author,
            coverPalette: novel.coverPalette,
            coverImageURLString: nil,
            sourceURLString: nil,
            firstReadAt: start,
            lastReadAt: start.addingTimeInterval(TimeInterval(tick)),
            deletedAt: nil,
            currentProgress: 1,
            totalDurationSeconds: TimeInterval(tick),
            pageTurns: events.count,
            characterCount: events.reduce(0) { $0 + $1.characterCount }
        )
        let encoded = try JSONEncoder().encode(ReadingStatsLedger(books: [book], events: events))
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "characterCountingVersion")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        var ledger = try JSONDecoder().decode(ReadingStatsLedger.self, from: legacyData)

        XCTAssertGreaterThan(ledger.books[0].characterCount, 600_000)
        ledger.repairLegacyCharacterCounts()
        XCTAssertEqual(ledger.books[0].characterCount, 330_000)
    }

    func testCompactionPreservesTotalsAndBoundsDetailedEvents() {
        let bookID = UUID()
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let oldStart = reference.addingTimeInterval(-200 * 24 * 60 * 60)
        let events = (0..<3_205).map { index in
            ReadingStatsEvent(
                id: UUID(),
                bookID: bookID,
                bookTitle: "测试书",
                timestamp: oldStart.addingTimeInterval(TimeInterval(index)),
                durationSeconds: 2,
                pageTurns: 1,
                characterCount: 300,
                chapterTitle: "第一章",
                progress: Double(index) / 3_205
            )
        }
        var ledger = ReadingStatsLedger(events: events)

        let totalsBefore = activityTotals(in: ledger)
        ledger.compactHistory(reference: reference)
        let totalsAfter = activityTotals(in: ledger)

        XCTAssertEqual(totalsAfter.duration, totalsBefore.duration)
        XCTAssertEqual(totalsAfter.pages, totalsBefore.pages)
        XCTAssertEqual(totalsAfter.characters, totalsBefore.characters)
        XCTAssertLessThanOrEqual(
            ledger.events.count,
            ReadingStatsLedger.maximumDetailedEventCount
        )
        XCTAssertFalse(ledger.dailySummaries.isEmpty)
    }

    func testLegacyLedgerWithoutDailySummariesStillDecodes() throws {
        let ledger = ReadingStatsLedger(
            events: [
                ReadingStatsEvent(
                    id: UUID(),
                    bookID: UUID(),
                    bookTitle: "旧备份",
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    durationSeconds: 30,
                    pageTurns: 1,
                    characterCount: 500,
                    chapterTitle: "第一章",
                    progress: 0.1
                )
            ]
        )
        let encoded = try JSONEncoder().encode(ledger)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "dailySummaries")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ReadingStatsLedger.self, from: legacyData)

        XCTAssertEqual(decoded.events, ledger.events)
        XCTAssertTrue(decoded.dailySummaries.isEmpty)
    }

    func testDetailedEventCapHoldsEvenWhenEveryEventHasADifferentBook() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let events = (0...ReadingStatsLedger.maximumDetailedEventCount).map { index in
            ReadingStatsEvent(
                id: UUID(),
                bookID: UUID(),
                bookTitle: "书 \(index)",
                timestamp: reference.addingTimeInterval(TimeInterval(-index)),
                durationSeconds: 1,
                pageTurns: 1,
                characterCount: 1,
                chapterTitle: "第一章",
                progress: 0.1
            )
        }
        var ledger = ReadingStatsLedger(events: events)

        ledger.compactHistory(reference: reference)

        XCTAssertEqual(
            ledger.events.count,
            ReadingStatsLedger.maximumDetailedEventCount
        )
        XCTAssertEqual(ledger.dailySummaries.count, 1)
    }

    private func activityTotals(
        in ledger: ReadingStatsLedger
    ) -> (duration: TimeInterval, pages: Int, characters: Int) {
        var duration: TimeInterval = 0
        var pages = 0
        var characters = 0
        ledger.forEachActivity { _, _, _, eventDuration, eventPages, eventCharacters in
            duration += eventDuration
            pages += eventPages
            characters += eventCharacters
        }
        return (duration, pages, characters)
    }

    private func makeNovel(progress: Double = 0) -> Novel {
        Novel(
            title: "测试书",
            author: "灵阅",
            genre: "测试",
            summary: "",
            lastChapter: "第一章",
            progress: progress,
            readMinutes: 0,
            coverPalette: .teal,
            isFeatured: false
        )
    }

    /// Builds a ledger as an older build would have persisted it. With `version: nil`
    /// the key is absent from the JSON (pre-migration builds, decodes as 0); with a
    /// number it simulates a ledger already stamped by that migration version.
    private func makeLegacyLedger(
        novel: Novel,
        events: [ReadingStatsEvent],
        lastTick: TimeInterval,
        version: Int? = nil
    ) throws -> ReadingStatsLedger {
        let start = events.first?.timestamp ?? Date(timeIntervalSince1970: 1_800_000_000)
        let book = ReadingStatsBook(
            id: novel.id,
            title: novel.title,
            author: novel.author,
            coverPalette: novel.coverPalette,
            coverImageURLString: nil,
            sourceURLString: nil,
            firstReadAt: start,
            lastReadAt: start.addingTimeInterval(lastTick),
            deletedAt: nil,
            currentProgress: novel.progress,
            totalDurationSeconds: lastTick,
            pageTurns: events.count,
            characterCount: events.reduce(0) { $0 + $1.characterCount }
        )
        let encoded = try JSONEncoder().encode(ReadingStatsLedger(books: [book], events: events))
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        if let version {
            legacyObject["characterCountingVersion"] = version
        } else {
            legacyObject.removeValue(forKey: "characterCountingVersion")
        }
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        return try JSONDecoder().decode(ReadingStatsLedger.self, from: legacyData)
    }

    private func makeEvent(
        id: UUID = UUID(),
        novel: Novel,
        timestamp: Date,
        count: Int,
        chapter: String,
        progress: Double,
        duration: TimeInterval = 10
    ) -> ReadingStatsEvent {
        ReadingStatsEvent(
            id: id,
            bookID: novel.id,
            bookTitle: novel.title,
            timestamp: timestamp,
            durationSeconds: duration,
            pageTurns: 1,
            characterCount: count,
            chapterTitle: chapter,
            progress: progress
        )
    }
}

final class ReaderPageTurnIntegrationTests: XCTestCase {
    func testContentRevisionSeparatesSameLengthChapterCorrections() {
        let original = ReaderContentRevision.fingerprint(title: "第一章", content: "甲乙丙丁")
        let corrected = ReaderContentRevision.fingerprint(title: "第一章", content: "甲乙丙戊")

        XCTAssertNotEqual(original, corrected)
        XCTAssertEqual(
            original,
            ReaderContentRevision.fingerprint(title: "第一章", content: "甲乙丙丁")
        )
    }

    func testFiveThousandContinuousForwardTurnsCrossEveryChapterBoundary() {
        let chapterCount = 1_001
        let pageCount = 5
        var chapterIndex = 0
        var pageIndex = 0
        var chapterTransitions = 0

        for _ in 0..<5_000 {
            let action = ReaderPageTurnResolver.action(
                direction: .forward,
                currentPageIndex: pageIndex,
                pageCount: pageCount,
                currentChapterIndex: chapterIndex,
                chapterCount: chapterCount,
                usesTwoColumns: false
            )
            switch action {
            case .page(let nextPageIndex):
                pageIndex = nextPageIndex
            case .chapter(let nextChapterIndex, let landOnLastPage):
                XCTAssertFalse(landOnLastPage)
                chapterIndex = nextChapterIndex
                pageIndex = 0
                chapterTransitions += 1
            case .none:
                XCTFail("Navigation stopped before the modeled end of the book")
                return
            }
        }

        XCTAssertEqual(chapterIndex, 1_000)
        XCTAssertEqual(pageIndex, 0)
        XCTAssertEqual(chapterTransitions, 1_000)
    }

    func testStatsRejectWholeChapterPlaceholderAndCountBothPagesInSpread() {
        let placeholder = ReaderPageItem(
            chapterIndex: 1,
            pageIndex: 0,
            chapterPageCount: 1,
            chapterTitle: "第二章",
            content: String(repeating: "整章正文", count: 1_000),
            renderSignature: "placeholder",
            isPaginated: false
        )
        let left = ReaderPageItem(
            chapterIndex: 1,
            pageIndex: 0,
            chapterPageCount: 2,
            chapterTitle: "第二章",
            content: "左页，共四字。",
            renderSignature: "left",
            isPaginated: true
        )
        let right = ReaderPageItem(
            chapterIndex: 1,
            pageIndex: 1,
            chapterPageCount: 2,
            chapterTitle: "第二章",
            content: "右页，也四字！",
            renderSignature: "right",
            isPaginated: true
        )

        XCTAssertNil(placeholder.readingStatsCharacterCount())
        XCTAssertEqual(left.readingStatsCharacterCount(companionPage: right), 10)
    }

    func testPaginationPrefetchCannotCascadeEvictVisibleChapter() {
        var cache = ReaderPaginationCache(capacity: 3)
        let visibleSignature = "chapter-10"
        cache.insert(["visible"], for: visibleSignature)

        for chapter in 11...20 {
            cache.insert(
                ["prefetched-\(chapter)"],
                for: "chapter-\(chapter)",
                protecting: [visibleSignature]
            )
        }

        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache[visibleSignature], ["visible"])
        XCTAssertEqual(cache["chapter-20"], ["prefetched-20"])
        XCTAssertNil(cache["chapter-11"])
    }

    func testPaginationCachePromotesEntriesOnRead() {
        var cache = ReaderPaginationCache(capacity: 3)
        cache.insert(["a"], for: "a")
        cache.insert(["b"], for: "b")
        cache.insert(["c"], for: "c")

        XCTAssertEqual(cache["a"], ["a"])
        cache.insert(["d"], for: "d")

        XCTAssertNil(cache["b"])
        XCTAssertEqual(cache["a"], ["a"])
        XCTAssertEqual(cache["d"], ["d"])
    }

    func testPaginationCacheProtectsCurrentNavigationWindow() {
        var cache = ReaderPaginationCache(capacity: 3)
        cache.insert(["previous"], for: "previous")
        cache.insert(["current"], for: "current")
        cache.insert(["next"], for: "next")

        cache.insert(
            ["distant"],
            for: "distant",
            protecting: ["current", "next"]
        )

        XCTAssertNil(cache["previous"])
        XCTAssertEqual(cache["current"], ["current"])
        XCTAssertEqual(cache["next"], ["next"])
    }

    func testPaginationCacheRemainsBoundedAcrossTenThousandChapterResults() {
        let capacity = 24
        var cache = ReaderPaginationCache(capacity: capacity)

        for chapterIndex in 0..<10_000 {
            let protected = Set((chapterIndex - 2...chapterIndex + 2).map { "chapter-\($0)" })
            let signature = "chapter-\(chapterIndex)"
            cache.insert(["page-\(chapterIndex)"], for: signature, protecting: protected)
            XCTAssertLessThanOrEqual(cache.count, capacity)
            if chapterIndex.isMultiple(of: 4) {
                XCTAssertEqual(cache[signature], ["page-\(chapterIndex)"])
            }
        }

        let retained = Set((9_995..<10_000).map { "chapter-\($0)" })
        let trimmedCount = cache.retainOnly(signatures: retained)
        let metrics = cache.metrics

        XCTAssertEqual(cache.count, retained.count)
        XCTAssertGreaterThan(trimmedCount, 0)
        XCTAssertEqual(metrics.entries, retained.count)
        XCTAssertEqual(metrics.hitCount, 2_500)
        XCTAssertGreaterThan(metrics.evictionCount, 9_000)
        XCTAssertEqual(metrics.memoryTrimmedCount, trimmedCount)
    }

    func testPaginationCacheCapacityWinsWhenEveryOldEntryIsProtected() {
        var cache = ReaderPaginationCache(capacity: 3)
        cache.insert(["a"], for: "a")
        cache.insert(["b"], for: "b")
        cache.insert(["c"], for: "c")
        cache.insert(["d"], for: "d", protecting: ["a", "b", "c"])

        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache["d"], ["d"])
        XCTAssertEqual(cache.metrics.evictionCount, 1)
    }

    func testReaderDiagnosticsSnapshotIncludesBoundedPerformanceCounters() {
        let snapshot = ReaderStateSnapshot(
            novelID: UUID(),
            novelTitle: "长会话测试",
            chapterIndex: 4,
            totalChapters: 10,
            chapterTitle: "第五章",
            pageIndex: 2,
            totalPages: 8,
            pageSignature: "signature",
            performance: ReaderPerformanceSnapshot(
                paginationCacheCapacity: 24,
                paginationCacheEntries: 5,
                paginationCacheHits: 20,
                paginationCacheMisses: 3,
                paginationCacheEvictions: 7,
                paginationCacheMemoryTrims: 2,
                prefetchRunning: 2,
                prefetchQueued: 1,
                prefetchMaximumRunning: 2,
                prefetchMaximumQueued: 3,
                prefetchCancelled: 4
            )
        )

        let context = snapshot.asContext()
        XCTAssertEqual(context["pageCache"], "5/24")
        XCTAssertEqual(context["pageCacheHitMiss"], "20/3")
        XCTAssertEqual(context["pageCacheMemTrim"], "2")
        XCTAssertEqual(context["prefetch"], "2/1")
        XCTAssertEqual(context["prefetchMax"], "2/3")
        XCTAssertEqual(context["prefetchCancel"], "4")
    }

    func testRenderedCurrentChapterCanTurnAfterItsCacheEntryIsEvicted() {
        let allowsTurn = ReaderPageAvailability.allowsForwardChapterTurn(
            hasCachedPages: false,
            visiblePageCount: 5,
            visibleChapterIndex: 3,
            currentChapterIndex: 3,
            visiblePageSignature: "chapter-3-layout-a",
            currentPageSignature: "chapter-3-layout-a",
            chapterIsReady: true
        )
        let action = ReaderPageTurnResolver.action(
            direction: .forward,
            currentPageIndex: 4,
            pageCount: 5,
            currentChapterIndex: 3,
            chapterCount: 8,
            usesTwoColumns: false,
            allowsChapterTurn: allowsTurn
        )

        XCTAssertTrue(allowsTurn)
        XCTAssertEqual(action, .chapter(index: 4, landOnLastPage: false))
    }

    func testStaleRenderedPagesCannotTurnDuringRepagination() {
        let allowsTurn = ReaderPageAvailability.allowsForwardChapterTurn(
            hasCachedPages: false,
            visiblePageCount: 5,
            visibleChapterIndex: 3,
            currentChapterIndex: 3,
            visiblePageSignature: "chapter-3-layout-a",
            currentPageSignature: "chapter-3-layout-b",
            chapterIsReady: true
        )

        XCTAssertFalse(allowsTurn)
    }

    func testSwipeBackAfterChapterButtonDoesNotWaitForPagination() {
        let allowsBackwardTurn = ReaderPageAvailability.allowsBoundaryChapterTurn(
            direction: .backward,
            allowsForwardChapterTurn: false
        )
        let action = ReaderPageTurnResolver.boundaryAction(
            direction: .backward,
            startPageIndex: 0,
            pageCount: 1,
            currentChapterIndex: 1,
            chapterCount: 3,
            usesTwoColumns: false,
            allowsChapterTurn: allowsBackwardTurn
        )

        XCTAssertEqual(action, .chapter(index: 0, landOnLastPage: true))
    }

    func testLoadingPageStillCannotSwipeForwardPrematurely() {
        let allowsForwardTurn = ReaderPageAvailability.allowsBoundaryChapterTurn(
            direction: .forward,
            allowsForwardChapterTurn: false
        )
        let action = ReaderPageTurnResolver.boundaryAction(
            direction: .forward,
            startPageIndex: 0,
            pageCount: 1,
            currentChapterIndex: 1,
            chapterCount: 3,
            usesTwoColumns: false,
            allowsChapterTurn: allowsForwardTurn
        )

        XCTAssertEqual(action, .none)
    }

    func testInteriorCurlBoundaryCallbackDoesNotSkipToNextChapter() {
        let action = ReaderPageTurnResolver.boundaryAction(
            direction: .forward,
            startPageIndex: 2,
            pageCount: 5,
            currentChapterIndex: 0,
            chapterCount: 2,
            usesTwoColumns: false
        )

        XCTAssertEqual(action, .none)
    }

    func testBackwardCurlFromNewChapterReturnsToPreviousChapterLastPage() {
        let action = ReaderPageTurnResolver.boundaryAction(
            direction: .backward,
            startPageIndex: 0,
            pageCount: 5,
            currentChapterIndex: 1,
            chapterCount: 2,
            usesTwoColumns: false
        )

        XCTAssertEqual(action, .chapter(index: 0, landOnLastPage: true))
    }

    func testSuppressedCurlCallbackCannotTurnChapterTwice() {
        let action = ReaderPageTurnResolver.boundaryAction(
            direction: .forward,
            startPageIndex: 4,
            pageCount: 5,
            currentChapterIndex: 0,
            chapterCount: 2,
            usesTwoColumns: false,
            suppressChapterTurn: true
        )

        XCTAssertEqual(action, .none)
    }
}

final class ReaderTypographyTests: XCTestCase {
    func testSharedTextLayoutPreservesReaderTypographyValues() throws {
        let attributes = ReaderTextLayout.attributes(
            fontSize: 22,
            lineSpacing: 7,
            paragraphSpacing: 0.5,
            fontFamily: .system,
            color: .label
        )

        let font = try XCTUnwrap(attributes[.font] as? UIFont)
        let paragraphStyle = try XCTUnwrap(
            attributes[.paragraphStyle] as? NSParagraphStyle
        )

        XCTAssertEqual(font.pointSize, 22, accuracy: 0.001)
        XCTAssertEqual(paragraphStyle.lineSpacing, 7, accuracy: 0.001)
        XCTAssertEqual(paragraphStyle.paragraphSpacing, 11, accuracy: 0.001)
        XCTAssertEqual(paragraphStyle.alignment, .justified)
        XCTAssertEqual(paragraphStyle.lineBreakMode, .byWordWrapping)
    }
}

@MainActor
final class PageCurlPagerCacheTests: XCTestCase {
    func testVisibleNeighborhoodIsRenderedAndLaidOutBeforeSwipe() throws {
        let recorder = PagerRenderRecorder()
        let slots = ["0-0-layout", "0-1-layout", "0-2-layout"]
        let coordinator = PageCurlPager.Coordinator(
            makePager(slots: slots, currentIndex: 1, recorder: recorder)
        )
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        let viewportSize = CGSize(width: 390, height: 844)
        pager.view.frame = CGRect(origin: .zero, size: viewportSize)
        let current = try XCTUnwrap(coordinator.host(for: slots[1]))
        pager.setViewControllers([current], direction: .forward, animated: false)

        coordinator.prepareVisibleNeighborhood(in: pager)

        XCTAssertEqual(Set(recorder.identities), Set(slots))
        let blankReference = UIView(frame: CGRect(origin: .zero, size: viewportSize))
        blankReference.backgroundColor = .white
        let blankPixels = renderedPNG(of: blankReference)
        for identity in slots {
            let host = try XCTUnwrap(coordinator.host(for: identity))
            XCTAssertEqual(host.view.bounds.size, viewportSize)
            XCTAssertNotEqual(
                renderedPNG(of: host.view),
                blankPixels,
                "Prepared page \(identity) must contain its SwiftUI frame before a swipe"
            )
            if identity != slots[1] {
                XCTAssertNil(host.parent)
                XCTAssertNil(host.view.superview)
            }
        }
    }

    func testPageIndexUpdateDoesNotRebuildCachedPageRoots() {
        let recorder = PagerRenderRecorder()
        let slots = ["0-0-layout", "0-1-layout"]
        let coordinator = PageCurlPager.Coordinator(
            makePager(slots: slots, currentIndex: 0, recorder: recorder)
        )

        XCTAssertNotNil(coordinator.host(for: slots[0]))
        XCTAssertNotNil(coordinator.host(for: slots[1]))
        XCTAssertEqual(recorder.identities, slots)

        coordinator.parent = makePager(slots: slots, currentIndex: 1, recorder: recorder)

        XCTAssertFalse(coordinator.refreshCachedRenders())
        XCTAssertEqual(
            recorder.identities,
            slots,
            "Changing only the selected page must not replace cached SwiftUI roots"
        )

        let revisedSlots = [slots[0], "0-1-repaginated"]
        coordinator.parent = makePager(
            slots: revisedSlots,
            currentIndex: 1,
            recorder: recorder
        )

        XCTAssertTrue(coordinator.refreshCachedRenders())
        XCTAssertNotNil(coordinator.host(for: revisedSlots[1]))
        XCTAssertEqual(recorder.identities.last, revisedSlots[1])
    }

    func testSlotIndexUpdatesWhenPaginationReplacesTheSlotWindow() {
        let recorder = PagerRenderRecorder()
        let coordinator = PageCurlPager.Coordinator(
            makePager(slots: ["old-0", "old-1"], currentIndex: 0, recorder: recorder)
        )

        XCTAssertEqual(coordinator.slotIndex(of: "old-1"), 1)

        coordinator.parent = makePager(
            slots: ["new-0", "new-1", "new-2"],
            currentIndex: 1,
            recorder: recorder
        )

        XCTAssertNil(coordinator.slotIndex(of: "old-1"))
        XCTAssertEqual(coordinator.slotIndex(of: "new-2"), 2)
    }

    func testFiveThousandPageIdentityLookupsRemainExactAfterRebase() {
        let recorder = PagerRenderRecorder()
        let slots = (0..<5_000).map { "chapter-page-\($0)" }
        let coordinator = PageCurlPager.Coordinator(
            makePager(slots: slots, currentIndex: 0, recorder: recorder)
        )

        for (index, identity) in slots.enumerated() {
            XCTAssertEqual(coordinator.slotIndex(of: identity), index)
        }

        let rebasedSlots = slots.reversed()
        coordinator.parent = makePager(
            slots: Array(rebasedSlots),
            currentIndex: 0,
            recorder: recorder
        )
        for (index, identity) in rebasedSlots.enumerated() {
            XCTAssertEqual(coordinator.slotIndex(of: identity), index)
        }
        XCTAssertNil(coordinator.slotIndex(of: "stale-page"))
    }

    func testSlotRefreshKeepsGestureTargetIdentifiableUntilLanding() throws {
        let recorder = PagerRenderRecorder()
        let slots = ["0-0-layout", "0-1-layout"]
        let coordinator = PageCurlPager.Coordinator(
            makePager(slots: slots, currentIndex: 0, recorder: recorder)
        )
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        let first = try XCTUnwrap(coordinator.host(for: slots[0]))
        let target = try XCTUnwrap(coordinator.host(for: slots[1]))
        pager.setViewControllers([first], direction: .forward, animated: false)

        coordinator.pageViewController(pager, willTransitionTo: [target])
        coordinator.parent = makePager(
            slots: [slots[0], "0-2-new-neighbor"],
            currentIndex: 0,
            recorder: recorder
        )
        XCTAssertTrue(coordinator.refreshCachedRenders())

        pager.setViewControllers([target], direction: .forward, animated: false)
        coordinator.pageViewController(
            pager,
            didFinishAnimating: true,
            previousViewControllers: [first],
            transitionCompleted: true
        )

        XCTAssertEqual(coordinator.shownIdentity, slots[1])
        XCTAssertNil(coordinator.gestureTargetIdentity)
    }

    func testSlotChangeDuringGestureDefersAndRetriesNeighborRefresh() throws {
        let recorder = PagerRenderRecorder()
        let currentID = "0-0-layout"
        let nextID = "1-0-layout"
        let coordinator = PageCurlPager.Coordinator(
            makePager(slots: [currentID], currentIndex: 0, recorder: recorder)
        )
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        let current = try XCTUnwrap(coordinator.host(for: currentID))
        pager.setViewControllers([current], direction: .forward, animated: false)

        // This is the long-session race: prefetch adds the next chapter's bookend
        // while UIKit is resolving a page gesture. Refreshing the pager at this point
        // is unsafe, but forgetting the refresh makes UIKit cache "no next page".
        coordinator.gestureInFlight = true
        coordinator.parent = makePager(
            slots: [currentID, nextID],
            currentIndex: 0,
            recorder: recorder
        )

        XCTAssertTrue(coordinator.refreshCachedRenders())
        XCTAssertTrue(coordinator.needsNeighborRefresh)
        XCTAssertFalse(coordinator.refreshNeighborsIfNeeded(in: pager))
        XCTAssertTrue(coordinator.needsNeighborRefresh)

        coordinator.gestureInFlight = false

        XCTAssertTrue(coordinator.refreshNeighborsIfNeeded(in: pager))
        XCTAssertFalse(coordinator.needsNeighborRefresh)
        XCTAssertNotNil(coordinator.pageViewController(pager, viewControllerAfter: current))
    }

    func testChapterRebaseReplacesHostAndExposesSecondPage() throws {
        let recorder = PagerRenderRecorder()
        let firstPageID = "1-0-layout"
        let secondPageID = "1-1-layout"
        let coordinator = PageCurlPager.Coordinator(
            makePager(slots: ["0-last-layout", firstPageID], currentIndex: 1, recorder: recorder)
        )
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        pager.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let bookendHost = try XCTUnwrap(coordinator.host(for: firstPageID))
        coordinator.shownIdentity = firstPageID
        pager.setViewControllers([bookendHost], direction: .forward, animated: false)

        // The trailing bookend just became page zero of chapter 1. UIKit previously saw
        // that controller at the end of the old slot window and may have cached no next
        // controller for it. The rebase must install a new host before page one can turn
        // to page two reliably.
        coordinator.parent = makePager(
            slots: ["0-last-layout", firstPageID, secondPageID],
            currentIndex: 1,
            recorder: recorder
        )
        XCTAssertTrue(coordinator.refreshCachedRenders())
        XCTAssertTrue(coordinator.refreshNeighborsIfNeeded(in: pager))

        let refreshedHost = try XCTUnwrap(pager.viewControllers?.first)
        XCTAssertFalse(refreshedHost === bookendHost)
        let secondPageHost = try XCTUnwrap(
            coordinator.pageViewController(pager, viewControllerAfter: refreshedHost)
        )
        XCTAssertTrue(secondPageHost === coordinator.host(for: secondPageID))
        XCTAssertFalse(coordinator.needsNeighborRefresh)
    }

    func testCancelledGestureAutomaticallyAppliesDeferredNeighborRefresh() async throws {
        let recorder = PagerRenderRecorder()
        let slots = ["0-0-layout", "0-1-layout"]
        let coordinator = PageCurlPager.Coordinator(
            makePager(slots: slots, currentIndex: 0, recorder: recorder)
        )
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        let current = try XCTUnwrap(coordinator.host(for: slots[0]))
        let gestureTarget = try XCTUnwrap(coordinator.host(for: slots[1]))
        pager.setViewControllers([current], direction: .forward, animated: false)

        coordinator.pageViewController(pager, willTransitionTo: [gestureTarget])
        coordinator.parent = makePager(
            slots: slots + ["1-0-bookend"],
            currentIndex: 0,
            recorder: recorder
        )
        XCTAssertTrue(coordinator.refreshCachedRenders())
        XCTAssertTrue(coordinator.needsNeighborRefresh)

        coordinator.pageViewController(
            pager,
            didFinishAnimating: true,
            previousViewControllers: [current],
            transitionCompleted: false
        )
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(coordinator.needsNeighborRefresh)
        XCTAssertFalse(coordinator.gestureInFlight)
    }

    func testMissingGestureCallbackSelfHeals() async throws {
        let recorder = PagerRenderRecorder()
        let slots = ["0-0-layout", "0-1-layout"]
        let coordinator = PageCurlPager.Coordinator(
            makePager(slots: slots, currentIndex: 0, recorder: recorder),
            transitionWatchdogDelay: 0.01
        )
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        let current = try XCTUnwrap(coordinator.host(for: slots[0]))
        let gestureTarget = try XCTUnwrap(coordinator.host(for: slots[1]))
        pager.setViewControllers([current], direction: .forward, animated: false)

        // Intentionally omit didFinishAnimating to model a UIKit callback lost to an
        // interruption/background transition. The watchdog must not poison the session.
        coordinator.pageViewController(pager, willTransitionTo: [gestureTarget])
        XCTAssertTrue(coordinator.gestureInFlight)

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(coordinator.gestureInFlight)
        XCTAssertEqual(coordinator.shownIdentity, slots[0])
    }

    func testHostCacheStaysBoundedAcrossVeryLongChapter() throws {
        let recorder = PagerRenderRecorder()
        let slots = (0..<250).map { "0-\($0)-layout" }
        let coordinator = PageCurlPager.Coordinator(
            makePager(slots: slots, currentIndex: 0, recorder: recorder)
        )
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        let firstHost = try XCTUnwrap(coordinator.host(for: slots[0]))
        pager.setViewControllers([firstHost], direction: .forward, animated: false)

        for index in slots.indices {
            coordinator.parent = makePager(
                slots: slots,
                currentIndex: index,
                recorder: recorder
            )
            coordinator.shownIdentity = slots[index]
            XCTAssertNotNil(coordinator.host(for: slots[index]))
            coordinator.prepareVisibleNeighborhood(in: pager)
        }

        XCTAssertLessThanOrEqual(coordinator.cachedHostCount, 9)
        XCTAssertNotNil(
            coordinator.pageViewController(pager, viewControllerAfter: firstHost),
            "An evicted controller retained by UIKit must still identify itself in O(1)"
        )
        XCTAssertLessThanOrEqual(coordinator.cachedHostCount, 9)
    }

    /// An explicit navigation (chapter button / picker / boundary fallback) bumps the
    /// pager's navigation epoch instead of tearing the pager down via `.id` — the old
    /// teardown permanently wedged SwiftUI representable updates mid-session on
    /// iOS 26. A gesture that STARTED before the jump must not write its landing back:
    /// the landed page may be a bookend of the new window, and committing it would
    /// yank the reader across a chapter boundary the jump already decided.
    func testLandingFromBeforeAnExplicitJumpDoesNotWriteBackOrCommit() throws {
        let recorder = PagerRenderRecorder()
        let slots = ["6-0-layout", "6-1-layout", "7-0-bookend"]
        var boundIndex = 1
        var committed: [String] = []
        func pager(epoch: Int) -> PageCurlPager {
            PageCurlPager(
                transitionStyle: .scroll,
                slotIdentities: slots,
                currentIndex: Binding(get: { boundIndex }, set: { boundIndex = $0 }),
                backgroundColor: .white,
                renderPage: recorder.render(identity:),
                onCommit: { committed.append($0) },
                navigationEpoch: epoch
            )
        }
        let coordinator = PageCurlPager.Coordinator(pager(epoch: 0))
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        let current = try XCTUnwrap(coordinator.host(for: slots[1]))
        coordinator.shownIdentity = slots[1]
        pvc.setViewControllers([current], direction: .forward, animated: false)
        let target = try XCTUnwrap(coordinator.host(for: slots[2]))

        coordinator.pageViewController(pvc, willTransitionTo: [target])
        coordinator.parent = pager(epoch: 1)
        pvc.setViewControllers([target], direction: .forward, animated: false)
        coordinator.pageViewController(
            pvc,
            didFinishAnimating: true,
            previousViewControllers: [current],
            transitionCompleted: true
        )

        XCTAssertEqual(coordinator.shownIdentity, slots[2], "显示状态仍要如实反映 UIKit 停在的页面")
        XCTAssertEqual(boundIndex, 1, "过期落地不能回写页码")
        XCTAssertTrue(committed.isEmpty, "过期落地不能触发跨章 commit")
    }

    func testSameEpochLandingStillSyncsBindingAndCommits() throws {
        let recorder = PagerRenderRecorder()
        let slots = ["6-0-layout", "6-1-layout", "7-0-bookend"]
        var boundIndex = 1
        var committed: [String] = []
        let pager = PageCurlPager(
            transitionStyle: .scroll,
            slotIdentities: slots,
            currentIndex: Binding(get: { boundIndex }, set: { boundIndex = $0 }),
            backgroundColor: .white,
            renderPage: recorder.render(identity:),
            onCommit: { committed.append($0) },
            navigationEpoch: 3
        )
        let coordinator = PageCurlPager.Coordinator(pager)
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        let current = try XCTUnwrap(coordinator.host(for: slots[1]))
        coordinator.shownIdentity = slots[1]
        pvc.setViewControllers([current], direction: .forward, animated: false)
        let target = try XCTUnwrap(coordinator.host(for: slots[2]))

        coordinator.pageViewController(pvc, willTransitionTo: [target])
        pvc.setViewControllers([target], direction: .forward, animated: false)
        coordinator.pageViewController(
            pvc,
            didFinishAnimating: true,
            previousViewControllers: [current],
            transitionCompleted: true
        )

        XCTAssertEqual(coordinator.shownIdentity, slots[2])
        XCTAssertEqual(boundIndex, 2, "同代落地正常同步页码")
        XCTAssertEqual(committed, [slots[2]], "同代 bookend 落地正常 commit")
    }

    private func makePager(
        slots: [String],
        currentIndex: Int,
        recorder: PagerRenderRecorder
    ) -> PageCurlPager {
        PageCurlPager(
            transitionStyle: .scroll,
            slotIdentities: slots,
            currentIndex: .constant(currentIndex),
            backgroundColor: .white,
            renderPage: recorder.render(identity:)
        )
    }
}

/// The bookend-commit fallback re-bases from the ordinals embedded in the slot
/// identity when the landed page is no longer in the current slot window. These
/// tests pin the identity format that fallback depends on.
final class ReaderPageIdentityCommitFallbackTests: XCTestCase {
    func testSlotIdentityRoundTripsChapterAndPage() {
        let item = ReaderPageItem(
            chapterIndex: 7,
            pageIndex: 3,
            chapterPageCount: 9,
            chapterTitle: "第八章",
            content: "正文",
            renderSignature: "sig|18.0|8.0|0.5|system|false",
            isPaginated: true
        )
        let slotIdentity = "\(item.id)|纸张|362x762|62|34|0|0|20|1|standard"

        let parsed = ReaderPageItem.chapterAndPage(fromSlotIdentity: slotIdentity)
        XCTAssertEqual(parsed?.chapterIndex, 7)
        XCTAssertEqual(parsed?.pageIndex, 3)
    }

    func testNegativeRenderSignatureHashStillParses() {
        // String.hashValue is per-process seeded and can be negative, giving ids of
        // the form "1-0--5053685814133393371". The parser must not treat the hash's
        // leading minus as a delimiter anomaly.
        let identity = "1-0--5053685814133393371|纸张|362x762|62|34|0|0|20|1|standard"

        let parsed = ReaderPageItem.chapterAndPage(fromSlotIdentity: identity)
        XCTAssertEqual(parsed?.chapterIndex, 1)
        XCTAssertEqual(parsed?.pageIndex, 0)
    }

    func testMalformedIdentitiesReturnNil() {
        XCTAssertNil(ReaderPageItem.chapterAndPage(fromSlotIdentity: ""))
        XCTAssertNil(ReaderPageItem.chapterAndPage(fromSlotIdentity: "garbage"))
        XCTAssertNil(ReaderPageItem.chapterAndPage(fromSlotIdentity: "5|context-only"))
        XCTAssertNil(ReaderPageItem.chapterAndPage(fromSlotIdentity: "-1-2-3|ctx"))
        XCTAssertNil(ReaderPageItem.chapterAndPage(fromSlotIdentity: "x-y-z|ctx"))
    }
}

@MainActor
private final class PagerRenderRecorder {
    private(set) var identities: [String] = []

    func render(identity: String) -> AnyView {
        identities.append(identity)
        return AnyView(Color.red)
    }
}

@MainActor
private func renderedPNG(of view: UIView) -> Data? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: view.bounds.size, format: format)
        .image { context in
            view.layer.render(in: context.cgContext)
        }
        .pngData()
}

@MainActor
final class ReaderPrefetchSchedulerTests: XCTestCase {
    func testSchedulerNeverExceedsConfiguredConcurrency() async throws {
        let scheduler = ReaderPrefetchScheduler(maxConcurrentJobs: 2)
        var active = 0
        var maximumActive = 0
        var completed = 0

        let jobs = (0..<6).map { index in
            ReaderPrefetchScheduler.Job(id: "chapter-\(index)") { ticket in
                active += 1
                maximumActive = max(maximumActive, active)
                try? await Task.sleep(for: .milliseconds(20))
                ticket.commit { completed += 1 }
                active -= 1
            }
        }

        scheduler.replaceDesiredJobs(jobs)
        try await waitForPrefetchScheduler(scheduler)

        XCTAssertEqual(maximumActive, 2)
        XCTAssertEqual(completed, jobs.count)
        XCTAssertTrue(scheduler.isIdle)
    }

    func testReplacingWindowRejectsStaleJobCommit() async throws {
        let scheduler = ReaderPrefetchScheduler(maxConcurrentJobs: 1)
        var committed: [String] = []

        scheduler.replaceDesiredJobs([
            ReaderPrefetchScheduler.Job(id: "old") { ticket in
                try? await Task.sleep(for: .milliseconds(50))
                ticket.commit { committed.append("old") }
            }
        ])
        await Task.yield()
        scheduler.replaceDesiredJobs([
            ReaderPrefetchScheduler.Job(id: "new") { ticket in
                ticket.commit { committed.append("new") }
            }
        ])

        try await waitForPrefetchScheduler(scheduler)

        XCTAssertEqual(committed, ["new"])
    }

    func testFiveHundredRapidWindowReplacementsStayBoundedAndRejectStaleCommits() async throws {
        let scheduler = ReaderPrefetchScheduler(maxConcurrentJobs: 2)
        var currentGeneration = -1
        var staleCommitCount = 0
        var finalCommits: Set<String> = []

        for generation in 0..<500 {
            currentGeneration = generation
            let jobs = (0..<3).map { offset in
                ReaderPrefetchScheduler.Job(id: "\(generation)-\(offset)") { ticket in
                    try? await Task.sleep(for: .milliseconds(2))
                    ticket.commit {
                        if generation != currentGeneration {
                            staleCommitCount += 1
                        }
                        if generation == 499 {
                            finalCommits.insert("\(generation)-\(offset)")
                        }
                    }
                }
            }
            scheduler.replaceDesiredJobs(jobs)
            if generation.isMultiple(of: 20) {
                await Task.yield()
            }
        }

        try await waitForPrefetchScheduler(scheduler, timeoutIterations: 300)
        let metrics = scheduler.metrics

        XCTAssertEqual(staleCommitCount, 0)
        XCTAssertEqual(finalCommits, ["499-0", "499-1", "499-2"])
        XCTAssertLessThanOrEqual(metrics.maximumRunning, metrics.concurrencyLimit)
        XCTAssertLessThanOrEqual(metrics.maximumQueued, 3)
        XCTAssertGreaterThan(metrics.cancelled, 0)
        XCTAssertEqual(metrics.running, 0)
        XCTAssertEqual(metrics.queued, 0)
    }

    func testCancelAllRejectsInFlightCommitAndRecordsCancellation() async throws {
        let scheduler = ReaderPrefetchScheduler(maxConcurrentJobs: 1)
        var committed = false

        scheduler.replaceDesiredJobs([
            ReaderPrefetchScheduler.Job(id: "memory-pressure") { ticket in
                try? await Task.sleep(for: .milliseconds(20))
                ticket.commit { committed = true }
            }
        ])
        await Task.yield()
        scheduler.cancelAll()
        try await waitForPrefetchScheduler(scheduler)

        XCTAssertFalse(committed)
        XCTAssertEqual(scheduler.metrics.cancelled, 1)
        XCTAssertTrue(scheduler.isIdle)
    }

    private func waitForPrefetchScheduler(
        _ scheduler: ReaderPrefetchScheduler,
        timeoutIterations: Int = 100
    ) async throws {
        for _ in 0..<timeoutIterations {
            if scheduler.isIdle { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Prefetch scheduler did not become idle")
    }
}

@MainActor
final class LibraryLifecycleIntegrationTests: XCTestCase {
    func testCategoryReorderMovesBothDirectionsAndPersists() async throws {
        let directory = temporaryDirectory()
        let first = LibraryCategory(name: "第一类", novels: [makeNovel(title: "第一本")])
        let second = LibraryCategory(name: "第二类", novels: [])
        let third = LibraryCategory(name: "第三类", novels: [makeNovel(title: "第三本")])
        let store = LibraryStore(storageDirectory: directory)
        store.categories = [first, second, third]

        XCTAssertTrue(store.moveCategory(id: first.id, toPositionOf: third.id))
        XCTAssertEqual(store.categories.map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(store.categories.last?.novels.first?.title, "第一本")

        XCTAssertTrue(store.moveCategory(id: first.id, toPositionOf: second.id))
        XCTAssertEqual(store.categories.map(\.id), [first.id, second.id, third.id])

        XCTAssertTrue(store.moveCategory(id: second.id, by: 1))
        XCTAssertEqual(store.categories.map(\.id), [first.id, third.id, second.id])
        XCTAssertTrue(store.moveCategory(id: second.id, by: -1))
        XCTAssertEqual(store.categories.map(\.id), [first.id, second.id, third.id])

        XCTAssertFalse(store.moveCategory(id: first.id, toPositionOf: first.id))
        XCTAssertFalse(store.moveCategory(id: UUID(), toPositionOf: second.id))
        XCTAssertFalse(store.moveCategory(id: first.id, by: -1))

        await store.flush()
        let reloaded = LibraryStore(storageDirectory: directory)
        XCTAssertEqual(reloaded.categories.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(reloaded.categories.flatMap(\.novels).map(\.title), ["第一本", "第三本"])
    }

    func testBackupRestoreRehydratesLibraryStatsAndCover() async throws {
        let directory = temporaryDirectory()
        let store = LibraryStore(storageDirectory: directory)
        let stack = makeSourceStack(in: directory)
        let service = BackupService(libraryStore: store, stack: stack)
        let novel = makeNovel()
        let archivedNovel = makeNovel(title: "归档回归测试")
        let cover = try makeCoverData()
        var ledger = ReadingStatsLedger()
        ledger.rememberBook(novel, at: novel.lastOpenedAt ?? Date())
        let archive = BackupArchive(
            version: BackupArchive.currentVersion,
            createdAt: Date(),
            buildVariant: "appstore",
            library: [LibraryCategory(name: "测试", novels: [novel])],
            archivedBooks: [
                ArchivedBookRecord(
                    novel: archivedNovel,
                    archivedAt: Date(timeIntervalSince1970: 1_760_000_000)
                )
            ],
            readingStats: ledger,
            editableSources: [],
            sourcePreferences: [],
            sourceValidations: [],
            bookCovers: [
                novel.id.uuidString: cover,
                archivedNovel.id.uuidString: cover
            ]
        )

        let encoded = try service.encodeArchive(archive)
        let decoded = try service.decodeArchive(from: encoded)
        try await service.restore(decoded)

        XCTAssertEqual(store.allNovels, [novel, archivedNovel])
        XCTAssertEqual(store.archivedNovels, [archivedNovel])
        XCTAssertEqual(store.readingStats.books.map(\.id), [novel.id])
        let restoredCover = await BookCoverStore.shared.coverData(
            for: novel.id,
            remoteURLString: nil
        )
        XCTAssertEqual(restoredCover, cover)
        await BookCoverStore.shared.removeCover(for: novel.id)
        await BookCoverStore.shared.removeCover(for: archivedNovel.id)
    }

    func testArchiveUndoRestoresOriginalCategoryPosition() throws {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let first = makeNovel(title: "第一本")
        let archived = makeNovel(title: "第二本")
        let last = makeNovel(title: "第三本")
        let category = LibraryCategory(name: "测试", novels: [first, archived, last])
        store.categories = [category]

        let archivedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let undo = try XCTUnwrap(store.archiveBook(archived, archivedAt: archivedAt))

        XCTAssertEqual(store.categories[0].novels.map(\.id), [first.id, last.id])
        XCTAssertEqual(store.archivedBooks.map(\.id), [archived.id])
        XCTAssertEqual(store.archivedBooks.first?.archivedAt, archivedAt)
        XCTAssertTrue(store.allNovels.contains(where: { $0.id == archived.id }))

        XCTAssertTrue(store.undoArchive(undo))
        XCTAssertEqual(store.categories[0].novels.map(\.id), [first.id, archived.id, last.id])
        XCTAssertTrue(store.archivedBooks.isEmpty)
    }

    func testArchivedBookIsExcludedFromContinueReadingAndMovesToChosenCategory() throws {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let novel = makeNovel()
        let source = LibraryCategory(name: "正在看", novels: [novel])
        let destination = LibraryCategory(name: "以后再看", novels: [])
        store.categories = [source, destination]

        XCTAssertNotNil(store.mostRecentlyOpenedNovel)
        XCTAssertNotNil(store.archiveBook(novel))
        XCTAssertNil(store.mostRecentlyOpenedNovel)

        XCTAssertTrue(store.moveBook(novel, toCategoryID: destination.id))
        XCTAssertTrue(store.archivedBooks.isEmpty)
        XCTAssertTrue(store.categories[0].novels.isEmpty)
        XCTAssertEqual(store.categories[1].novels.map(\.id), [novel.id])
    }

    func testArchivePersistsAndReadingStateUpdatesInPlace() async throws {
        let directory = temporaryDirectory()
        let store = LibraryStore(storageDirectory: directory)
        let novel = makeNovel()
        store.categories = [LibraryCategory(name: "测试", novels: [novel])]
        XCTAssertNotNil(store.archiveBook(novel))

        store.updateReadingState(
            for: novel.id,
            chapterTitle: "第二章",
            progress: 0.75,
            chapterIndex: 1,
            chapterPageIndex: 3,
            chapterSourceURLString: "chapter-2"
        )
        await store.flush()

        let reloaded = LibraryStore(storageDirectory: directory)
        let persisted = try XCTUnwrap(reloaded.archivedNovels.first)
        XCTAssertEqual(persisted.lastChapter, "第二章")
        XCTAssertEqual(persisted.progress, 0.75)
        XCTAssertEqual(persisted.currentChapterIndex, 1)
        XCTAssertTrue(reloaded.categories.first?.novels.isEmpty == true)
    }

    func testLegacyLibraryKeepsUserCategoryAndDoesNotInferArchiveMeaning() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let novel = makeNovel()
        let legacyCategories = [LibraryCategory(name: "看过好看的", novels: [novel])]
        let data = try JSONEncoder().encode(legacyCategories)
        try data.write(to: directory.appendingPathComponent("LibraryStore.json"), options: .atomic)

        let store = LibraryStore(storageDirectory: directory)

        XCTAssertEqual(store.categories.map(\.name), ["看过好看的"])
        XCTAssertEqual(store.categories.first?.novels.map(\.id), [novel.id])
        XCTAssertTrue(store.archivedBooks.isEmpty)
    }

    func testRestoreDropsDuplicateArchiveLocation() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let novel = makeNovel()
        store.replaceLibrary(
            categories: [LibraryCategory(name: "测试", novels: [novel])],
            archivedBooks: [ArchivedBookRecord(novel: novel, archivedAt: Date())]
        )

        XCTAssertEqual(store.allNovels.map(\.id), [novel.id])
        XCTAssertTrue(store.archivedBooks.isEmpty)
    }

    func testReplacingArchivedImportPreservesArchiveLocation() throws {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let original = makeNovel(sourceURLString: "https://example.com/book")
        store.categories = [LibraryCategory(name: "测试", novels: [original])]
        let archivedAt = Date(timeIntervalSince1970: 1_770_000_000)
        XCTAssertNotNil(store.archiveBook(original, archivedAt: archivedAt))
        XCTAssertTrue(
            store.isArchivedBook(
                sourceURLString: original.sourceURLString,
                title: original.title
            )
        )
        let replacement = makeNovel(sourceURLString: "https://example.com/book")

        store.addImportedNovel(replacement, categoryName: "不应移动到这里")

        XCTAssertEqual(store.archivedBooks.map(\.id), [replacement.id])
        XCTAssertEqual(store.archivedBooks.first?.archivedAt, archivedAt)
        XCTAssertFalse(store.categories.contains(where: { $0.name == "不应移动到这里" }))
    }

    func testOldBackupWithoutArchiveFieldStillDecodes() throws {
        let directory = temporaryDirectory()
        let store = LibraryStore(storageDirectory: directory)
        let service = BackupService(libraryStore: store, stack: makeSourceStack(in: directory))
        let archive = BackupArchive(
            version: 1,
            createdAt: Date(),
            buildVariant: "appstore",
            library: [],
            readingStats: ReadingStatsLedger(),
            editableSources: [],
            sourcePreferences: [],
            sourceValidations: [],
            bookCovers: nil
        )
        let encoded = try service.encodeArchive(archive)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "archivedBooks")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try service.decodeArchive(from: legacyData)

        XCTAssertNil(decoded.archivedBooks)
    }

    func testDeletingBookRemovesItsSavedCover() async throws {
        let directory = temporaryDirectory()
        let store = LibraryStore(storageDirectory: directory)
        let novel = makeNovel()
        let cover = try makeCoverData()
        store.categories = [LibraryCategory(name: "测试", novels: [novel])]
        XCTAssertNotNil(store.archiveBook(novel))
        await BookCoverStore.shared.restoreCovers(
            [novel.id.uuidString: cover],
            keeping: [novel.id]
        )

        store.deleteBook(novel)

        let deadline = Date().addingTimeInterval(2)
        var storedCover: Data?
        repeat {
            storedCover = await BookCoverStore.shared.coverData(
                for: novel.id,
                remoteURLString: nil
            )
            if storedCover == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline

        XCTAssertTrue(store.allNovels.isEmpty)
        XCTAssertNil(storedCover)
    }

    private func makeSourceStack(in directory: URL) -> SourceStack {
        let loader = HTTPSourceLoader()
        let editableStore = FileEditableSourceStore(
            fileURL: directory.appendingPathComponent("sources.json")
        )
        let preferenceStore = FileSourcePreferenceStore(
            fileURL: directory.appendingPathComponent("preferences.json")
        )
        let validationStore = FileSourceValidationStore(
            fileURL: directory.appendingPathComponent("validations.json")
        )
        let registry = AppStoreSourceRegistry(
            editableStore: editableStore,
            loader: loader,
            preferenceStore: preferenceStore
        )
        return SourceStack(
            loader: loader,
            editableStore: editableStore,
            preferenceStore: preferenceStore,
            validationStore: validationStore,
            registry: registry,
            pageDetector: PageDetector(registry: registry)
        )
    }

    private func makeNovel(
        title: String = "回归测试",
        sourceURLString: String? = nil
    ) -> Novel {
        Novel(
            title: title,
            author: "灵阅",
            genre: "测试",
            summary: "用于验证备份与清理。",
            lastChapter: "第一章",
            progress: 0.25,
            readMinutes: 12,
            lastOpenedAt: Date(timeIntervalSince1970: 1_750_000_000),
            coverPalette: .teal,
            isFeatured: false,
            sourceURLString: sourceURLString,
            chapters: [
                NovelChapter(title: "第一章", content: "测试正文")
            ]
        )
    }

    private func makeCoverData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LingyueAppTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

final class BookTitleParserTests: XCTestCase {
    func testSeparatesAuthorAndStatusTagFromScrapedTitle() {
        let parsed = BookTitleParser.parse("凡人修仙传_忘语【完结】")
        XCTAssertEqual(parsed.title, "凡人修仙传")
        XCTAssertEqual(parsed.author, "忘语")
    }

    func testKnownAuthorSuffixIsStrippedAcrossSeparators() {
        for raw in ["诡秘之主_爱潜水的乌贼", "诡秘之主 - 爱潜水的乌贼", "诡秘之主（爱潜水的乌贼）", "诡秘之主爱潜水的乌贼著"] {
            let parsed = BookTitleParser.parse(raw, knownAuthor: "爱潜水的乌贼")
            XCTAssertEqual(parsed.title, "诡秘之主", "failed for \(raw)")
            XCTAssertEqual(parsed.author, "爱潜水的乌贼", "failed for \(raw)")
        }
    }

    func testLongPenNameIsRecognizedWithoutKnownAuthor() {
        let parsed = BookTitleParser.parse("大王饶命_会说话的肘子")
        XCTAssertEqual(parsed.title, "大王饶命")
        XCTAssertEqual(parsed.author, "会说话的肘子")
    }

    func testSiteBrandTailIsDroppedWithoutAuthorAttribution() {
        let parsed = BookTitleParser.parse("凡人修仙传_笔趣阁")
        XCTAssertEqual(parsed.title, "凡人修仙传")
        XCTAssertNil(parsed.author)
    }

    func testJunkTailAndAuthorBothStripInOnePass() {
        let parsed = BookTitleParser.parse("凡人修仙传小说_忘语最新章节_某某小说网")
        XCTAssertEqual(parsed.title, "凡人修仙传")
        XCTAssertEqual(parsed.author, "忘语")
    }

    func testReadingSuffixesStripWithoutSeparators() {
        XCTAssertEqual(BookTitleParser.parse("诡秘之主最新章节列表").title, "诡秘之主")
        XCTAssertEqual(BookTitleParser.parse("诡秘之主全文免费阅读").title, "诡秘之主")
    }

    func testExplicitAuthorMarkerSplits() {
        let parsed = BookTitleParser.parse("赤心巡天 作者：情何以甚")
        XCTAssertEqual(parsed.title, "赤心巡天")
        XCTAssertEqual(parsed.author, "情何以甚")
    }

    func testLeadingQuotedTitleAdoptedWhenTailIsAuthor() {
        let parsed = BookTitleParser.parse("《赤心巡天》情何以甚")
        XCTAssertEqual(parsed.title, "赤心巡天")
        XCTAssertEqual(parsed.author, "情何以甚")
    }

    func testLeadingQuotedTitleKeptWholeWhenTailCouldBePartOfName() {
        let parsed = BookTitleParser.parse("《斗罗大陆》II绝世唐门")
        XCTAssertEqual(parsed.title, "《斗罗大陆》II绝世唐门")
        XCTAssertNil(parsed.author)
    }

    func testFanficUniverseBracketsSurvive() {
        let parsed = BookTitleParser.parse("【综漫】之机械姬她没有心")
        XCTAssertEqual(parsed.title, "【综漫】之机械姬她没有心")
        XCTAssertNil(parsed.author)
    }

    func testParenthesizedSubtitleSurvivesWithoutKnownAuthor() {
        let parsed = BookTitleParser.parse("鬼吹灯(精绝古城)")
        XCTAssertEqual(parsed.title, "鬼吹灯(精绝古城)")
        XCTAssertNil(parsed.author)
    }

    func testParenthesizedStatusTagIsMetadata() {
        XCTAssertEqual(BookTitleParser.parse("凡人修仙传(完结)").title, "凡人修仙传")
        XCTAssertEqual(BookTitleParser.parse("凡人修仙传（全本）").title, "凡人修仙传")
    }

    func testGluedSequelNameStaysIntact() {
        let parsed = BookTitleParser.parse("斗罗大陆IV终极斗罗")
        XCTAssertEqual(parsed.title, "斗罗大陆IV终极斗罗")
        XCTAssertNil(parsed.author)
    }

    func testAllDecorationInputFallsBackToOriginal() {
        let parsed = BookTitleParser.parse("最新章节")
        XCTAssertEqual(parsed.title, "最新章节")
        XCTAssertNil(parsed.author)
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(BookTitleParser.parse("  "), ParsedBookTitle(title: "", author: nil))
    }

    func testCleanTitleWithoutDecorationsIsUntouched() {
        let parsed = BookTitleParser.parse("凡人修仙传", knownAuthor: "忘语")
        XCTAssertEqual(parsed.title, "凡人修仙传")
        XCTAssertNil(parsed.author)
    }
}

@MainActor
final class LibraryTitleMatchingTests: XCTestCase {
    /// Switching sources imports the book from a *different* URL, so the
    /// replace-vs-duplicate decision falls to the title comparison. A record
    /// saved before title parsing landed carries a decorated title; the fresh
    /// import carries the bare name. They must match, or the switch inserts a
    /// duplicate instead of replacing the record.
    func testSwitchSourceReplacesLegacyDecoratedTitleRecord() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let legacy = makeNovel(
            title: "第二人格_骑着鬼火扫大街【完结】",
            sourceURLString: "https://old.example.com/book/1/"
        )
        store.categories = [LibraryCategory(name: "无分类", novels: [legacy])]

        XCTAssertTrue(
            store.containsBook(
                sourceURLString: "https://new.example.com/novel/9/",
                title: "第二人格"
            ),
            "clean import title should match the legacy decorated record"
        )

        let replacement = makeNovel(
            title: "第二人格",
            sourceURLString: "https://new.example.com/novel/9/"
        )
        XCTAssertTrue(store.addImportedNovel(replacement, categoryName: "无分类"))

        let allTitles = store.allNovels.map(\.title)
        XCTAssertEqual(allTitles, ["第二人格"], "the legacy record should be replaced, not duplicated")
    }

    func testDistinctBooksSharingAPrefixAreNotMerged() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let base = makeNovel(
            title: "第二人格",
            sourceURLString: "https://a.example.com/book/1/"
        )
        store.categories = [LibraryCategory(name: "无分类", novels: [base])]

        let different = makeNovel(
            title: "拥有第二人格",
            sourceURLString: "https://b.example.com/book/2/"
        )
        XCTAssertTrue(store.addImportedNovel(different, categoryName: "无分类"))
        XCTAssertEqual(
            Set(store.allNovels.map(\.title)),
            ["第二人格", "拥有第二人格"],
            "different books must never be merged by the title normalizer"
        )
    }

    /// 两本都留: importing the same title from a second source keeps the shelf copy
    /// instead of overwriting it.
    func testKeepingBothSameTitleImportsLeavesTheOriginalOnTheShelf() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let original = makeNovel(
            title: "第二人格",
            sourceURLString: "https://a.example.com/book/1/"
        )
        store.categories = [LibraryCategory(name: "无分类", novels: [original])]

        let other = makeNovel(
            title: "第二人格",
            sourceURLString: "https://b.example.com/book/2/"
        )
        XCTAssertTrue(
            store.containsSameTitleBookFromAnotherSource(
                sourceURLString: other.sourceURLString,
                title: other.title
            ),
            "a same-titled book from another source is what makes keeping both meaningful"
        )
        XCTAssertTrue(store.addImportedNovelKeepingSameTitleBooks(other, categoryName: "无分类"))

        XCTAssertEqual(
            Set(store.allNovels.map(\.id)),
            [original.id, other.id],
            "both copies should stay on the shelf"
        )
    }

    /// Once the user has said the two same-titled books are distinct, a later import
    /// of either source must update only that copy — the title alone no longer
    /// identifies a record, or the next 更新书籍 would delete both.
    func testReimportingAfterKeepingBothReplacesOnlyThatSource() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let original = makeNovel(
            title: "第二人格",
            sourceURLString: "https://a.example.com/book/1/"
        )
        store.categories = [LibraryCategory(name: "无分类", novels: [original])]
        let other = makeNovel(
            title: "第二人格",
            sourceURLString: "https://b.example.com/book/2/"
        )
        store.addImportedNovelKeepingSameTitleBooks(other, categoryName: "无分类")

        let refreshedOther = makeNovel(
            title: "第二人格",
            sourceURLString: "https://b.example.com/book/2/"
        )
        XCTAssertTrue(store.addImportedNovel(refreshedOther, categoryName: "无分类"))

        XCTAssertEqual(
            Set(store.allNovels.map(\.id)),
            [original.id, refreshedOther.id],
            "refreshing one source should replace only its own copy"
        )
    }

    /// A third source's import can't guess which of the kept copies it belongs to,
    /// so it lands as its own record rather than silently swallowing either one.
    func testImportFromAThirdSourceDoesNotSwallowKeptDuplicates() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let original = makeNovel(
            title: "第二人格",
            sourceURLString: "https://a.example.com/book/1/"
        )
        store.categories = [LibraryCategory(name: "无分类", novels: [original])]
        let other = makeNovel(
            title: "第二人格",
            sourceURLString: "https://b.example.com/book/2/"
        )
        store.addImportedNovelKeepingSameTitleBooks(other, categoryName: "无分类")

        XCTAssertFalse(
            store.containsBook(
                sourceURLString: "https://c.example.com/book/3/",
                title: "第二人格"
            ),
            "deliberate duplicates are matched by source URL only"
        )
    }

    /// Re-importing the exact same page is a refresh, not a second book: the prompt
    /// must not offer 两本都留 there.
    func testSamePageReimportIsNotOfferedAsADuplicate() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let original = makeNovel(
            title: "第二人格",
            sourceURLString: "https://a.example.com/book/1/"
        )
        store.categories = [LibraryCategory(name: "无分类", novels: [original])]

        XCTAssertFalse(
            store.containsSameTitleBookFromAnotherSource(
                sourceURLString: "https://a.example.com/book/1/",
                title: "第二人格"
            )
        )
    }

    /// Keep-both on the very same page is a refresh in disguise — two records from
    /// one URL would be indistinguishable forever, so the store replaces instead.
    func testKeepingBothFallsBackToReplacingWhenTheSourceURLIsIdentical() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let original = makeNovel(
            title: "第二人格",
            sourceURLString: "https://a.example.com/book/1/"
        )
        store.categories = [LibraryCategory(name: "无分类", novels: [original])]

        let samePage = makeNovel(
            title: "第二人格",
            sourceURLString: "https://a.example.com/book/1/"
        )
        XCTAssertTrue(store.addImportedNovelKeepingSameTitleBooks(samePage, categoryName: "无分类"))

        XCTAssertEqual(store.allNovels.map(\.id), [samePage.id])
    }

    /// The duplicate flag is stored as an optional so a library saved before it
    /// existed still decodes.
    func testLibraryWithoutDuplicateFlagStillDecodes() throws {
        let novel = makeNovel(title: "第二人格", sourceURLString: "https://a.example.com/book/1/")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(novel)) as? [String: Any]
        )
        object.removeValue(forKey: "isSameTitleDuplicate")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Novel.self, from: legacy)
        XCTAssertNil(decoded.isSameTitleDuplicate)
    }

    private func makeNovel(title: String, sourceURLString: String) -> Novel {
        Novel(
            title: title,
            author: "测试",
            genre: "测试",
            summary: "",
            lastChapter: "第一章",
            progress: 0,
            readMinutes: 0,
            coverPalette: .teal,
            isFeatured: false,
            sourceURLString: sourceURLString,
            chapters: [NovelChapter(title: "第一章", content: "测试正文")]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LingyueAppTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

@MainActor
final class LibrarySourceSwitchTests: XCTestCase {
    /// 切换书源 targets the book the user opened. With two same-titled copies on the
    /// shelf, the switch must move that one and leave its sibling untouched.
    func testSwitchingSourceReplacesOnlyTheTargetedBook() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let opened = makeNovel(title: "第二人格", sourceURLString: "https://a.example.com/book/1/")
        store.categories = [LibraryCategory(name: "无分类", novels: [opened])]
        let sibling = makeNovel(title: "第二人格", sourceURLString: "https://b.example.com/book/2/")
        store.addImportedNovelKeepingSameTitleBooks(sibling, categoryName: "无分类")

        let switched = makeNovel(title: "第二人格", sourceURLString: "https://c.example.com/book/3/")
        XCTAssertTrue(store.replaceBook(id: opened.id, with: switched, categoryName: "无分类"))

        XCTAssertEqual(
            Set(store.allNovels.map(\.id)),
            [switched.id, sibling.id],
            "only the opened copy should have moved to the new source"
        )
        XCTAssertEqual(
            store.allNovels.first(where: { $0.id == switched.id })?.isSameTitleDuplicate,
            true,
            "the switched copy stays a deliberate duplicate, or the pair re-merges by title"
        )
    }

    /// The switched-in record keeps the book's shelf spot: same category, same row.
    func testSwitchingSourceKeepsTheBookInItsCategory() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let other = makeNovel(title: "别的书", sourceURLString: "https://x.example.com/book/9/")
        let opened = makeNovel(title: "第二人格", sourceURLString: "https://a.example.com/book/1/")
        store.categories = [LibraryCategory(name: "玄幻", novels: [other, opened])]

        let switched = makeNovel(title: "第二人格", sourceURLString: "https://c.example.com/book/3/")
        XCTAssertTrue(store.replaceBook(id: opened.id, with: switched, categoryName: "玄幻"))

        XCTAssertEqual(store.categories.map(\.name), ["玄幻"])
        XCTAssertEqual(store.categories.first?.novels.map(\.id), [other.id, switched.id])
    }

    /// An archived book has no category to pick, so the switch leaves it archived.
    func testSwitchingSourceOnAnArchivedBookKeepsItArchived() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let opened = makeNovel(title: "第二人格", sourceURLString: "https://a.example.com/book/1/")
        store.categories = [LibraryCategory(name: "无分类", novels: [opened])]
        XCTAssertNotNil(store.archiveBook(opened))

        let switched = makeNovel(title: "第二人格", sourceURLString: "https://c.example.com/book/3/")
        XCTAssertTrue(
            store.replaceBook(id: opened.id, with: switched, categoryName: LibraryStore.uncategorizedName)
        )

        XCTAssertEqual(store.archivedBooks.map(\.id), [switched.id])
        XCTAssertTrue(store.categories.allSatisfy { $0.novels.isEmpty })
    }

    /// Deleting the book from the library tab while the browser is open leaves the
    /// import nothing to replace; the caller falls back to a plain add.
    func testSwitchingSourceReportsFailureWhenTheBookIsGone() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let switched = makeNovel(title: "第二人格", sourceURLString: "https://c.example.com/book/3/")

        XCTAssertFalse(
            store.replaceBook(id: UUID(), with: switched, categoryName: "无分类")
        )
        XCTAssertTrue(store.allNovels.isEmpty)
    }

    /// Refreshing one of two kept copies from its own source must not hand its title
    /// back: the pair would start matching each other again and the next 更新书籍
    /// would take both.
    func testRefreshingAKeptDuplicateStaysADuplicate() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let original = makeNovel(title: "第二人格", sourceURLString: "https://a.example.com/book/1/")
        store.categories = [LibraryCategory(name: "无分类", novels: [original])]
        let kept = makeNovel(title: "第二人格", sourceURLString: "https://b.example.com/book/2/")
        store.addImportedNovelKeepingSameTitleBooks(kept, categoryName: "无分类")

        let refreshed = makeNovel(title: "第二人格", sourceURLString: "https://b.example.com/book/2/")
        XCTAssertTrue(store.addImportedNovel(refreshed, categoryName: "无分类"))

        XCTAssertEqual(
            store.allNovels.first(where: { $0.id == refreshed.id })?.isSameTitleDuplicate,
            true
        )
        XCTAssertEqual(Set(store.allNovels.map(\.id)), [original.id, refreshed.id])
    }

    /// The browser stays open after 换源 hands it a target, so the user can wander to
    /// another novel. That page must not be offered as a replacement for the book they
    /// set out to switch — a decorated variant of the same title still counts as a match.
    func testSwitchTargetOnlyAppliesToTheSameBook() {
        let store = LibraryStore(storageDirectory: temporaryDirectory())
        let opened = makeNovel(
            title: "第二人格_骑着鬼火扫大街【完结】",
            sourceURLString: "https://a.example.com/book/1/"
        )
        store.categories = [LibraryCategory(name: "无分类", novels: [opened])]

        XCTAssertTrue(store.book(withID: opened.id, matchesTitle: "第二人格"))
        XCTAssertFalse(store.book(withID: opened.id, matchesTitle: "拥有第二人格"))
        XCTAssertFalse(store.book(withID: UUID(), matchesTitle: "第二人格"))
    }

    private func makeNovel(title: String, sourceURLString: String) -> Novel {
        Novel(
            title: title,
            author: "测试",
            genre: "测试",
            summary: "",
            lastChapter: "第一章",
            progress: 0,
            readMinutes: 0,
            coverPalette: .teal,
            isFeatured: false,
            sourceURLString: sourceURLString,
            chapters: [NovelChapter(title: "第一章", content: "测试正文")]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LingyueAppTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

final class BookImportTitleSeparationTests: XCTestCase {
    /// The browser detect flow must store the parts separated: a decorated page
    /// title (`书名_作者名【完结】`) with no dedicated author element becomes a
    /// candidate with the bare name as title and the embedded author extracted.
    func testDetectBookSeparatesDecoratedPageTitle() throws {
        let html = """
        <html><head>
        <meta property="og:novel:book_name" content="第二人格_骑着鬼火扫大街【完结】" />
        <script src="/ajax_novels/chapterlist/1.html"></script>
        </head><body>
        <div class="intro">突然产生的第二人格。</div>
        </body></html>
        """
        let url = try XCTUnwrap(URL(string: "https://example.com/book/1/"))

        let candidate = try XCTUnwrap(
            BookImportService.shared.detectBook(html: html, url: url, pageTitle: nil)
        )
        XCTAssertEqual(candidate.title, "第二人格")
        XCTAssertEqual(candidate.author, "骑着鬼火扫大街")
    }

    /// A scraped author element wins over the title-embedded heuristic, and the
    /// decorated title still reduces to the bare name.
    func testDetectBookPrefersScrapedAuthorOverTitleTail() throws {
        let html = """
        <html><head>
        <meta property="og:novel:book_name" content="第二人格_骑着鬼火扫大街【完结】" />
        <meta property="og:novel:author" content="骑着鬼火扫大街" />
        <script src="/ajax_novels/chapterlist/1.html"></script>
        </head><body></body></html>
        """
        let url = try XCTUnwrap(URL(string: "https://example.com/book/1/"))

        let candidate = try XCTUnwrap(
            BookImportService.shared.detectBook(html: html, url: url, pageTitle: nil)
        )
        XCTAssertEqual(candidate.title, "第二人格")
        XCTAssertEqual(candidate.author, "骑着鬼火扫大街")
    }

    /// Downloaded TXT files named `书名_作者名【完结】.txt` import with the parts
    /// separated instead of surfacing the whole filename as the title.
    func testPlainTextImportSeparatesDecoratedFilename() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LingyueAppTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("第二人格_骑着鬼火扫大街【完结】.txt")
        let body = "第一章 觉醒\n这是第一章的正文。\n第二章 巡夜\n这是第二章的正文。"
        try body.write(to: fileURL, atomically: true, encoding: .utf8)

        let novel = try BookImportService.shared.importBook(fromPlainTextFile: fileURL)
        XCTAssertEqual(novel.title, "第二人格")
        XCTAssertEqual(novel.author, "骑着鬼火扫大街")
        XCTAssertEqual(novel.chapters.count, 2)
        XCTAssertEqual(
            novel.sourceURLString,
            BookSourceRegistry.localPlainTextSourceURLString(forTitle: "第二人格"),
            "the local-import sentinel URL must be derived from the parsed title"
        )
    }
}

final class BookTitleParserCompoundTagTests: XCTestCase {
    /// Exact case reported from a live source: a compound status bracket after the
    /// author tail. The compound tag must strip so the author tail becomes
    /// recognizable again.
    func testCompoundBracketTagAfterAuthorTail() {
        let parsed = BookTitleParser.parse("穿成反派前妻的第二人格_你的荣光【完结+番外】")
        XCTAssertEqual(parsed.title, "穿成反派前妻的第二人格")
        XCTAssertEqual(parsed.author, "你的荣光")
    }

    func testCompoundBracketVariants() {
        XCTAssertEqual(BookTitleParser.parse("书名一二【完结＋番外】").title, "书名一二")
        XCTAssertEqual(BookTitleParser.parse("书名一二(已完结/精校)").title, "书名一二")
        XCTAssertEqual(BookTitleParser.parse("书名一二【完结 番外】").title, "书名一二")
    }

    func testBareCompoundStatusTailIsJunk() {
        let parsed = BookTitleParser.parse("书名一二_完结+番外")
        XCTAssertEqual(parsed.title, "书名一二")
        XCTAssertNil(parsed.author)
    }

    /// A compound bracket containing a non-metadata piece is part of the name
    /// space we must not guess about — keep it whole.
    func testCompoundBracketWithUnknownPieceSurvives() {
        let parsed = BookTitleParser.parse("【综漫+完结】某某某传")
        XCTAssertEqual(parsed.title, "【综漫+完结】某某某传")
    }
}

/// Regression: the in-app browser's rule-based detection fired on HTTP
/// error pages. Reproduced on 大尾笔趣阁 (www.daweixs.com) — the mirror
/// answered a book URL with nginx's stock 502 page, the URL still matched
/// the rule's host+path detection, and the prompt armed as
/// 「从 大尾笔趣阁 导入《502 Bad Gateway》」 using the error page's <title>.
/// `HTTPErrorPageScreen` now rejects such snapshots before any source's
/// `detectBook` runs, and the browser forwards the main-frame HTTP status
/// into the snapshot so non-2xx responses are refused even when the error
/// body looks like a normal page.
final class HTTPErrorPageScreenRegressionTests: XCTestCase {

    /// The exact page shape from the reproduced outage.
    func testNginx502PageIsScreened() {
        let html = """
        <html>
        <head><title>502 Bad Gateway</title></head>
        <body>
        <center><h1>502 Bad Gateway</h1></center>
        <hr><center>nginx</center>
        </body>
        </html>
        """
        XCTAssertTrue(HTTPErrorPageScreen.isObviousErrorPage(snapshot(html: html)))
    }

    func testCommonErrorTitleVariantsAreScreened() {
        let titles = [
            "404 Not Found",
            "403 Forbidden",
            "500 Internal Server Error",
            "503 Service Temporarily Unavailable",
            "504 Gateway Time-out",
            "HTTP Status 404 – Not Found",
            "www.daweixs.com | 502: Bad gateway",
            "Welcome to nginx!"
        ]
        for title in titles {
            let html = "<html><head><title>\(title)</title></head><body>正在维护</body></html>"
            XCTAssertTrue(
                HTTPErrorPageScreen.isObviousErrorPage(snapshot(html: html)),
                "expected screening for title: \(title)"
            )
        }
    }

    /// Some error pages ship without a <title>; the banner <h1> must
    /// still be enough.
    func testErrorHeadingScreensWhenTitleIsMissing() {
        let html = "<html><body><center><h1>502 Bad Gateway</h1></center><hr><center>openresty</center></body></html>"
        XCTAssertTrue(HTTPErrorPageScreen.isObviousErrorPage(snapshot(html: html)))
    }

    /// The browser now records the main-frame response status. A non-2xx
    /// status must screen the page even when its body looks bookish, and
    /// a 200 must never screen a healthy page.
    func testStatusCodeScreensIndependentlyOfContent() {
        XCTAssertTrue(HTTPErrorPageScreen.isObviousErrorPage(snapshot(html: bookDetailHTML, statusCode: 502)))
        XCTAssertFalse(HTTPErrorPageScreen.isObviousErrorPage(snapshot(html: bookDetailHTML, statusCode: 200)))
    }

    func testRealBookDetailPageIsNotScreened() {
        XCTAssertFalse(HTTPErrorPageScreen.isObviousErrorPage(snapshot(html: bookDetailHTML)))
    }

    /// Titles that merely *look* status-shaped must never be screened —
    /// the patterns anchor on Latin status lines.
    func testNumericAndChineseTitlesAreNotScreened() {
        let titles = [
            "第502章 大结局",
            "502教室最新章节_大尾笔趣阁",
            "404不存在的国度",
            "错误的爱情"
        ]
        for title in titles {
            let html = "<html><head><title>\(title)</title></head><body>\(String(repeating: "<p>正文段落</p>", count: 60))</body></html>"
            XCTAssertFalse(
                HTTPErrorPageScreen.isObviousErrorPage(snapshot(html: html)),
                "false positive for title: \(title)"
            )
        }
    }

    /// End-to-end through `PageDetector`: even a source whose detection
    /// claims every page must not surface a hit for an error snapshot,
    /// while the healthy render of the same URL still detects.
    func testPageDetectorRefusesErrorPageEvenWhenASourceClaimsIt() async {
        let source = AlwaysMatchingBookSource()
        let detector = PageDetector(registry: SingleSourceRegistry(source: source))

        let errorHTML = "<html><head><title>502 Bad Gateway</title></head><body><center><h1>502 Bad Gateway</h1></center><hr><center>nginx</center></body></html>"
        let armed = await detector.detect(in: snapshot(html: errorHTML))
        XCTAssertNil(armed, "import prompt must not arm on an HTTP error page")

        let statusOnly = await detector.detect(in: snapshot(html: bookDetailHTML, statusCode: 502))
        XCTAssertNil(statusOnly, "a non-2xx main-frame status must veto detection")

        let healthy = await detector.detect(in: snapshot(html: bookDetailHTML))
        XCTAssertEqual(healthy?.sourceID, source.id, "healthy render of the same URL must still detect")
    }

    // MARK: - Fixtures

    private var bookDetailHTML: String {
        """
        <html>
        <head><title>凡人修仙传最新章节_忘语_大尾笔趣阁</title></head>
        <body>
        <div class="book-info"><h1>凡人修仙传</h1><p>作者：忘语</p></div>
        <div id="list">
        <dl>
        <dd><a href="/book/93650/1.html">第一章 山村小子</a></dd>
        <dd><a href="/book/93650/2.html">第二章 七玄门</a></dd>
        <dd><a href="/book/93650/3.html">第三章 墨大夫</a></dd>
        </dl>
        </div>
        </body>
        </html>
        """
    }

    private func snapshot(html: String, statusCode: Int? = nil) -> WebPageSnapshot {
        WebPageSnapshot(
            html: html,
            finalURL: URL(string: "https://www.daweixs.com/book/93650/")!,
            responseHeaders: [:],
            statusCode: statusCode
        )
    }
}

/// Claims every snapshot — stands in for a URL-pattern rule whose host and
/// path still match while the server is erroring.
private struct AlwaysMatchingBookSource: BookSource {
    let id = "rule:test-always-match"
    let displayName = "测试源"
    let capabilities = SourceCapabilities(
        supportsSearch: false,
        showInSearchBar: false,
        supportsBrowserImport: true,
        requiresWebRender: false
    )

    func detectBook(in page: WebPageSnapshot) async throws -> BookDetection? {
        BookDetection(confidence: 0.9, detailURL: page.finalURL, title: nil, sourceID: id)
    }

    func search(_ query: String) async throws -> [BookSearchResult] {
        throw BookSourceError.searchUnsupported
    }
    func fetchDetail(url: URL) async throws -> BookDetail {
        throw BookSourceError.unsupportedURL(url)
    }
    func fetchCatalog(url: URL) async throws -> [ChapterLink] {
        throw BookSourceError.unsupportedURL(url)
    }
    func fetchChapter(url: URL) async throws -> ChapterContent {
        throw BookSourceError.unsupportedURL(url)
    }
}

// Module-qualified: `@testable import LingyueAppStore` exposes the app's
// internal `enum BookSourceRegistry` (the seeded-rules namespace), which
// collides with LingyueCore's protocol of the same name.
private struct SingleSourceRegistry: LingyueCore.BookSourceRegistry {
    let source: any BookSource

    func enabledSources() async throws -> [any BookSource] { [source] }
    func searchableSources() async throws -> [any BookSource] { [] }
    func source(withID id: String) async throws -> (any BookSource)? {
        source.id == id ? source : nil
    }
}

// MARK: - App interface language (简体 → 繁体 UI conversion)

/// The interface-language feature relies on Swift preferring the app module's
/// concrete `String` initializer shadows over SwiftUI's `LocalizedStringKey` /
/// `StringProtocol` overloads for string literals. If that resolution ever changed
/// (a SwiftUI API addition, a new overload), UI chrome would silently stop
/// converting — so pin the behavior here at the `Text` level.
final class AppUILanguageTests: XCTestCase {
    private var savedValue: Any?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.object(forKey: AppUILanguage.storageKey)
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: AppUILanguage.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppUILanguage.storageKey)
        }
        super.tearDown()
    }

    func testDisplayPassesThroughWhenSimplified() {
        UserDefaults.standard.set(false, forKey: AppUILanguage.storageKey)
        XCTAssertEqual(AppUILanguage.display("书架与分类"), "书架与分类")
    }

    func testDisplayConvertsWhenTraditional() {
        UserDefaults.standard.set(true, forKey: AppUILanguage.storageKey)
        XCTAssertEqual(AppUILanguage.display("书架"), "書架")
        XCTAssertEqual(AppUILanguage.display("阅读历史"), "閱讀歷史")
        // ASCII (URLs, header names…) must survive conversion untouched.
        XCTAssertEqual(AppUILanguage.display("https://example.com"), "https://example.com")
    }

    func testTextLiteralRoutesThroughInterfaceLanguageShadow() {
        UserDefaults.standard.set(true, forKey: AppUILanguage.storageKey)
        XCTAssertEqual(Text("书架"), Text(verbatim: "書架"))

        UserDefaults.standard.set(false, forKey: AppUILanguage.storageKey)
        XCTAssertEqual(Text("书架"), Text(verbatim: "书架"))
    }

    func testTextInterpolationRoutesThroughInterfaceLanguageShadow() {
        UserDefaults.standard.set(true, forKey: AppUILanguage.storageKey)
        let count = 3
        XCTAssertEqual(Text("删除 \(count) 个书源？"), Text(verbatim: "刪除 3 個書源？"))
    }
}

/// Bulk downloads used to persist anti-bot challenge pages ("cookies need to be
/// enabled" walls, 访问过于频繁 interstitials) as chapter text once a source started
/// rate-limiting the burst — and the garbage outlived the download until the user
/// wiped the cache by hand. These pin the detector and the cache self-heal.
final class AntiBotChallengeDetectionTests: XCTestCase {
    func testEnglishCookieWallIsDetected() {
        let wall = """
        Cookies need to be enabled in order to browse this site.
        Please enable cookies in your browser and try again.
        """
        XCTAssertTrue(BookImportService.isAntiBotChallengeContent(wall))
    }

    func testChineseRateLimitInterstitialIsDetected() {
        XCTAssertTrue(BookImportService.isAntiBotChallengeContent("访问过于频繁，请开启Cookies后重新访问。"))
        XCTAssertTrue(BookImportService.isAntiBotChallengeContent("人機驗證：請開啟Cookie後繼續訪問本站"))
    }

    func testCloudflareInterstitialIsDetected() {
        XCTAssertTrue(BookImportService.isAntiBotChallengeContent("Checking your browser before accessing the site."))
        XCTAssertTrue(BookImportService.isAntiBotChallengeContent("Verifying you are human. This may take a few seconds."))
    }

    func testRealChapterProseIsNotDetected() {
        let shortChapter = "第三章 夜谈\n\n山间的风慢慢吹过旧书页，两人对坐无言，直到烛火燃尽。"
        XCTAssertFalse(BookImportService.isAntiBotChallengeContent(shortChapter))
    }

    func testLongProseMentioningCookiesIsNotDetected() {
        // The length gate keeps a genuine chapter that happens to quote a challenge
        // phrase from being misclassified — challenge pages are always short.
        let filler = String(repeating: "他继续读着屏幕上的报错信息，觉得有些好笑。", count: 60)
        let chapter = filler + "屏幕上写着 cookies need to be enabled，他叹了口气合上电脑。"
        XCTAssertFalse(BookImportService.isAntiBotChallengeContent(chapter))
    }

    func testPoisonedCacheEntryIsRejectedForRefetch() {
        let poisoned = NovelChapter(
            title: "第一百二十章 大结局",
            content: "Cookies need to be enabled in order to browse this site.",
            sourceURLString: "https://example.com/book/120.html"
        )
        let original = NovelChapter(
            title: "第一百二十章 大结局",
            content: "",
            sourceURLString: "https://example.com/book/120.html"
        )
        XCTAssertFalse(BookImportService.shared.shouldUseCachedChapter(poisoned, for: original))
    }

    func testSourceBlockedSentinelStillAcceptedAsCacheEntry() {
        let sentinel = NovelChapter(
            title: "第一章",
            content: BookImportService.sourceBlockedContentSentinel,
            sourceURLString: "https://example.com/book/1.html"
        )
        let original = NovelChapter(title: "第一章", content: "", sourceURLString: "https://example.com/book/1.html")
        XCTAssertTrue(BookImportService.shared.shouldUseCachedChapter(sentinel, for: original))
    }

    /// A whole-page blob cached by the extractor's whole-page fallback froze the
    /// reader for ~20s on open (and could watchdog-crash it). Oversized web-cache
    /// entries must be rejected so they re-fetch under the new extraction limit;
    /// realistically long genuine chapters stay accepted.
    func testOversizedCachedBlobIsRejectedButLongChapterIsKept() {
        let original = NovelChapter(title: "第九章", content: "", sourceURLString: "https://example.com/book/9.html")
        let blob = NovelChapter(
            title: "第九章",
            content: String(repeating: "目录 第一章 第二章 第三章 广告脚本噪声 ", count: 6_000),
            sourceURLString: "https://example.com/book/9.html"
        )
        XCTAssertFalse(BookImportService.shared.shouldUseCachedChapter(blob, for: original))

        let longButReal = NovelChapter(
            title: "第九章",
            content: "第九章\n\n" + String(repeating: "山间的风慢慢吹过旧书页，读者一页一页往下读。", count: 1_800),
            sourceURLString: "https://example.com/book/9.html"
        )
        XCTAssertLessThanOrEqual(longButReal.content.count, BookImportService.maxReasonableWebChapterLength)
        XCTAssertTrue(BookImportService.shared.shouldUseCachedChapter(longButReal, for: original))
    }
}

/// The reader paginated by binary-searching the WHOLE remaining chapter for every
/// page, so cost scaled with (chapter length × page count). A real field case — a
/// 12,330-character chapter read at 29pt (80 pages) — blocked the main thread for
/// 66 seconds on open, which the user experienced as "the book takes forever to
/// open and then I can't turn the page". These pin the fix (bracketed search) and
/// the page splits it must preserve.
final class ReaderPaginationPerformanceTests: XCTestCase {
    private let textSize = CGSize(width: 400, height: 844)

    private func fieldCaseChapter() -> String {
        // ~12k characters of Chinese prose, matching the reported chapter's size.
        let paragraph = "他走进那间旧书房，窗外的光线斜斜落在桌面上，尘埃在空气里缓缓浮动。"
            + "书页被风吹得翻了一角，露出下面压着的一张字条，字迹已经有些模糊了。"
        return (1...175).map { "第\($0)段：" + paragraph }.joined(separator: "\n")
    }

    func testLargeFontChapterPaginatesQuicklyEnoughForTheMainThread() {
        let content = fieldCaseChapter()
        XCTAssertGreaterThan(content.count, 10_000, "fixture should match the field case size")

        let start = Date()
        let pages = ReaderView.paginate(
            content: content,
            textSize: textSize,
            fontSize: 29,
            lineSpacing: 8,
            paragraphSpacing: 1,
            fontFamily: .system
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThan(pages.count, 20, "a 29pt read of this chapter spans many pages")
        // The old quadratic search took 66s for this shape on device. Two seconds in
        // the simulator leaves generous headroom while still catching a regression.
        XCTAssertLessThan(elapsed, 2.0, "分页耗时 \(elapsed)s —— 分页复杂度回退了")
    }

    func testPaginationIsLosslessAndOrdered() {
        let content = fieldCaseChapter()
        let pages = ReaderView.paginate(
            content: content,
            textSize: textSize,
            fontSize: 29,
            lineSpacing: 8,
            paragraphSpacing: 1,
            fontFamily: .system
        )
        XCTAssertFalse(pages.isEmpty)
        XCTAssertFalse(pages.contains(where: \.isEmpty), "no page may be empty")

        // Every page's text must appear in order, with nothing dropped: stripping
        // whitespace, the concatenation reproduces the source.
        let joined = pages.joined()
        let strip: (String) -> String = { $0.filter { !$0.isWhitespace } }
        XCTAssertEqual(strip(joined), strip(content), "pagination must not drop or reorder text")
    }

    func testTinyViewportStillMakesProgress() {
        // A viewport too small for a single line must not spin forever.
        let pages = ReaderView.paginate(
            content: "短章节内容测试",
            textSize: CGSize(width: 40, height: 8),
            fontSize: 29,
            lineSpacing: 8,
            paragraphSpacing: 1,
            fontFamily: .system
        )
        XCTAssertFalse(pages.isEmpty)
    }
}
