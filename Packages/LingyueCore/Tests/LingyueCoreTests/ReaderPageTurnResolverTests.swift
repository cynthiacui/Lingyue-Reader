import XCTest
@testable import LingyueCore

final class ReaderPageTurnResolverTests: XCTestCase {
    func testForwardTurnAdvancesWithinChapter() {
        let action = ReaderPageTurnResolver.action(
            direction: .forward,
            currentPageIndex: 2,
            pageCount: 5,
            currentChapterIndex: 1,
            chapterCount: 3,
            usesTwoColumns: false
        )

        XCTAssertEqual(action, .page(3))
    }

    func testForwardTurnAtLastPageAdvancesChapter() {
        let action = ReaderPageTurnResolver.action(
            direction: .forward,
            currentPageIndex: 4,
            pageCount: 5,
            currentChapterIndex: 1,
            chapterCount: 3,
            usesTwoColumns: false
        )

        XCTAssertEqual(action, .chapter(index: 2, landOnLastPage: false))
    }

    func testBackwardTurnAtFirstPageLandsOnPreviousChapterLastPage() {
        let action = ReaderPageTurnResolver.action(
            direction: .backward,
            currentPageIndex: 0,
            pageCount: 5,
            currentChapterIndex: 1,
            chapterCount: 3,
            usesTwoColumns: false
        )

        XCTAssertEqual(action, .chapter(index: 0, landOnLastPage: true))
    }

    func testTurnStopsAtBookEdges() {
        let backward = ReaderPageTurnResolver.action(
            direction: .backward,
            currentPageIndex: 0,
            pageCount: 5,
            currentChapterIndex: 0,
            chapterCount: 3,
            usesTwoColumns: false
        )
        let forward = ReaderPageTurnResolver.action(
            direction: .forward,
            currentPageIndex: 4,
            pageCount: 5,
            currentChapterIndex: 2,
            chapterCount: 3,
            usesTwoColumns: false
        )

        XCTAssertEqual(backward, .none)
        XCTAssertEqual(forward, .none)
    }

    func testTwoColumnTurnUsesSpreadBoundaries() {
        let withinChapter = ReaderPageTurnResolver.action(
            direction: .forward,
            currentPageIndex: 0,
            pageCount: 5,
            currentChapterIndex: 0,
            chapterCount: 2,
            usesTwoColumns: true
        )
        let nextChapter = ReaderPageTurnResolver.action(
            direction: .forward,
            currentPageIndex: 4,
            pageCount: 5,
            currentChapterIndex: 0,
            chapterCount: 2,
            usesTwoColumns: true
        )

        XCTAssertEqual(withinChapter, .page(2))
        XCTAssertEqual(nextChapter, .chapter(index: 1, landOnLastPage: false))
    }

    func testBoundarySwipeUsesGestureStartPage() {
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

    func testSuppressedBoundarySwipeDoesNotAdvanceChapterTwice() {
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

    func testLoadingPlaceholderCannotTriggerChapterTurn() {
        let action = ReaderPageTurnResolver.boundaryAction(
            direction: .forward,
            startPageIndex: 0,
            pageCount: 1,
            currentChapterIndex: 0,
            chapterCount: 2,
            usesTwoColumns: false,
            allowsChapterTurn: false
        )

        XCTAssertEqual(action, .none)
    }
}
