import UIKit
import SwiftUI
import XCTest
import LingyueCore
@testable import LingyueAppStore

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
final class LibraryLifecycleIntegrationTests: XCTestCase {
    func testBackupRestoreRehydratesLibraryStatsAndCover() async throws {
        let directory = temporaryDirectory()
        let store = LibraryStore(storageDirectory: directory)
        let stack = makeSourceStack(in: directory)
        let service = BackupService(libraryStore: store, stack: stack)
        let novel = makeNovel()
        let cover = try makeCoverData()
        var ledger = ReadingStatsLedger()
        ledger.rememberBook(novel, at: novel.lastOpenedAt ?? Date())
        let archive = BackupArchive(
            version: BackupArchive.currentVersion,
            createdAt: Date(),
            buildVariant: "appstore",
            library: [LibraryCategory(name: "测试", novels: [novel])],
            readingStats: ledger,
            editableSources: [],
            sourcePreferences: [],
            sourceValidations: [],
            bookCovers: [novel.id.uuidString: cover]
        )

        let encoded = try service.encodeArchive(archive)
        let decoded = try service.decodeArchive(from: encoded)
        try await service.restore(decoded)

        XCTAssertEqual(store.allNovels, [novel])
        XCTAssertEqual(store.readingStats.books.map(\.id), [novel.id])
        let restoredCover = await BookCoverStore.shared.coverData(
            for: novel.id,
            remoteURLString: nil
        )
        XCTAssertEqual(restoredCover, cover)
        await BookCoverStore.shared.removeCover(for: novel.id)
    }

    func testDeletingBookRemovesItsSavedCover() async throws {
        let directory = temporaryDirectory()
        let store = LibraryStore(storageDirectory: directory)
        let novel = makeNovel()
        let cover = try makeCoverData()
        store.categories = [LibraryCategory(name: "测试", novels: [novel])]
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

    private func makeNovel() -> Novel {
        Novel(
            title: "回归测试",
            author: "灵阅",
            genre: "测试",
            summary: "用于验证备份与清理。",
            lastChapter: "第一章",
            progress: 0.25,
            readMinutes: 12,
            lastOpenedAt: Date(timeIntervalSince1970: 1_750_000_000),
            coverPalette: .teal,
            isFeatured: false,
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
