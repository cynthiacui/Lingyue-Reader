import UIKit
import SwiftUI
import XCTest
import LingyueCore
@testable import LingyueAppStore

final class ReadingStatsLedgerTests: XCTestCase {
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
}

final class ReaderPageTurnIntegrationTests: XCTestCase {
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
        return AnyView(Color.white)
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
