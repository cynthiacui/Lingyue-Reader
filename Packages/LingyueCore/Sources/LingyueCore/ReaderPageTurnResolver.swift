import Foundation

public enum ReaderPageTurnDirection: Sendable {
    case backward
    case forward
}

public enum ReaderPageTurnAction: Equatable, Sendable {
    case none
    case page(Int)
    case chapter(index: Int, landOnLastPage: Bool)
}

public enum ReaderPageTurnResolver {
    public static func action(
        direction: ReaderPageTurnDirection,
        currentPageIndex: Int,
        pageCount: Int,
        currentChapterIndex: Int,
        chapterCount: Int,
        usesTwoColumns: Bool,
        allowsChapterTurn: Bool = true
    ) -> ReaderPageTurnAction {
        let step = usesTwoColumns ? 2 : 1
        let lastPageIndex = lastNavigablePageIndex(
            pageCount: pageCount,
            usesTwoColumns: usesTwoColumns
        )

        switch direction {
        case .backward:
            if currentPageIndex >= step {
                return .page(currentPageIndex - step)
            }
            guard allowsChapterTurn, currentChapterIndex > 0 else {
                return .none
            }
            return .chapter(index: currentChapterIndex - 1, landOnLastPage: true)

        case .forward:
            if currentPageIndex < lastPageIndex {
                return .page(min(currentPageIndex + step, lastPageIndex))
            }
            guard allowsChapterTurn, currentChapterIndex < chapterCount - 1 else {
                return .none
            }
            return .chapter(index: currentChapterIndex + 1, landOnLastPage: false)
        }
    }

    public static func boundaryAction(
        direction: ReaderPageTurnDirection,
        startPageIndex: Int,
        pageCount: Int,
        currentChapterIndex: Int,
        chapterCount: Int,
        usesTwoColumns: Bool,
        allowsChapterTurn: Bool = true,
        suppressChapterTurn: Bool = false
    ) -> ReaderPageTurnAction {
        guard allowsChapterTurn, !suppressChapterTurn else {
            return .none
        }

        switch direction {
        case .backward:
            let atFirstPage = usesTwoColumns
                ? startPageIndex < 2
                : startPageIndex == 0
            guard atFirstPage, currentChapterIndex > 0 else {
                return .none
            }
            return .chapter(index: currentChapterIndex - 1, landOnLastPage: true)

        case .forward:
            let lastPageIndex = lastNavigablePageIndex(
                pageCount: pageCount,
                usesTwoColumns: usesTwoColumns
            )
            guard startPageIndex >= lastPageIndex,
                  currentChapterIndex < chapterCount - 1 else {
                return .none
            }
            return .chapter(index: currentChapterIndex + 1, landOnLastPage: false)
        }
    }

    private static func lastNavigablePageIndex(
        pageCount: Int,
        usesTwoColumns: Bool
    ) -> Int {
        let validPageCount = max(pageCount, 1)
        if usesTwoColumns {
            return max(((validPageCount + 1) / 2 - 1) * 2, 0)
        }
        return validPageCount - 1
    }
}
