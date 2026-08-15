import UIKit
import SwiftUI
import XCTest
import LingyueCore
@testable import LingyueAppStore

final class AppUpdateAnnouncementStoreTests: XCTestCase {
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

    private func makeEvent(
        id: UUID = UUID(),
        novel: Novel,
        timestamp: Date,
        count: Int,
        chapter: String,
        progress: Double
    ) -> ReadingStatsEvent {
        ReadingStatsEvent(
            id: id,
            bookID: novel.id,
            bookTitle: novel.title,
            timestamp: timestamp,
            durationSeconds: 10,
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
