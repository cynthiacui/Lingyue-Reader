import Foundation
import SwiftUI

struct LibraryCategory: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var novels: [Novel]

    init(id: UUID = UUID(), name: String, novels: [Novel]) {
        self.id = id
        self.name = name
        self.novels = novels
    }
}

/// A book that remains in the user's library but is intentionally hidden from the
/// day-to-day category shelves. `archivedAt` is the only archive-specific metadata:
/// restoring a book always asks for a destination category rather than preserving an
/// implicit relationship with its former category.
struct ArchivedBookRecord: Identifiable, Hashable, Codable, Sendable {
    var novel: Novel
    let archivedAt: Date

    var id: UUID { novel.id }
}

/// Short-lived capability used by the post-archive Undo toast. The archive itself does
/// not remember former categories; this token exists in memory only while Undo is visible.
struct LibraryArchiveUndo: Sendable, Equatable {
    let bookID: UUID
    let categoryID: UUID
    let categoryIndex: Int
}

/// Versioned on-disk envelope. Older app versions stored a bare `[LibraryCategory]`;
/// `loadLibrary` still decodes that shape and upgrades it in memory without changing any
/// category names or inferring archive intent from user data.
private struct LibraryStorageSnapshot: Codable, Sendable {
    var version = 1
    var categories: [LibraryCategory]
    var archivedBooks: [ArchivedBookRecord]
}

struct ReadingStatsBook: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var title: String
    var author: String
    var coverPalette: NovelCoverPalette
    var coverImageURLString: String?
    var sourceURLString: String?
    var firstReadAt: Date
    var lastReadAt: Date
    var deletedAt: Date?
    var currentProgress: Double
    var totalDurationSeconds: TimeInterval
    var pageTurns: Int
    var characterCount: Int

    var isDeleted: Bool { deletedAt != nil }
}

struct ReadingStatsEvent: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let bookID: UUID
    let bookTitle: String
    let timestamp: Date
    let durationSeconds: TimeInterval
    let pageTurns: Int
    let characterCount: Int
    let chapterTitle: String
    let progress: Double
}

/// A compact, lossless roll-up of older page-turn events. Recent events keep their
/// chapter/progress detail for browsing history; older activity only needs one record
/// per book and calendar day for Stats charts, streaks, and totals.
struct ReadingStatsDailySummary: Hashable, Codable, Sendable {
    let day: Date
    let bookID: UUID
    var bookTitle: String
    var durationSeconds: TimeInterval
    var pageTurns: Int
    var characterCount: Int
}

enum ReadingTextMetrics {
    /// Chinese reading statistics conventionally count readable letters and numbers,
    /// not whitespace or punctuation. Counting every non-whitespace scalar inflated the
    /// displayed value by including commas, quotation marks, and other layout symbols.
    static func characterCount(in text: String) -> Int {
        text.unicodeScalars.count { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                 .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                return true
            default:
                return false
            }
        }
    }
}

private struct ReadingStatsCursor: Hashable, Codable, Sendable {
    let bookID: UUID
    var lastObservedAt: Date
    var lastPageKey: String
    var lastProgress: Double
    var chapterIndex: Int?
    var chapterPageIndex: Int?
    var chapterSourceURLString: String?
}

struct ReadingStatsLedger: Hashable, Codable, Sendable {
    var books: [ReadingStatsBook] = []
    var events: [ReadingStatsEvent] = []
    var dailySummaries: [ReadingStatsDailySummary] = []
    fileprivate var cursors: [ReadingStatsCursor] = []
    private var characterCountingVersion: Int

    static let maximumDetailedEventCount = 3_000
    static let detailedHistoryDays = 100
    private static let currentCharacterCountingVersion = 1

    private enum CodingKeys: String, CodingKey {
        case books
        case events
        case dailySummaries
        case cursors
        case characterCountingVersion
    }

    init(
        books: [ReadingStatsBook] = [],
        events: [ReadingStatsEvent] = [],
        dailySummaries: [ReadingStatsDailySummary] = []
    ) {
        self.books = books
        self.events = events
        self.dailySummaries = dailySummaries
        self.cursors = []
        self.characterCountingVersion = Self.currentCharacterCountingVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        books = try container.decodeIfPresent([ReadingStatsBook].self, forKey: .books) ?? []
        events = try container.decodeIfPresent([ReadingStatsEvent].self, forKey: .events) ?? []
        dailySummaries = try container.decodeIfPresent(
            [ReadingStatsDailySummary].self,
            forKey: .dailySummaries
        ) ?? []
        cursors = try container.decodeIfPresent([ReadingStatsCursor].self, forKey: .cursors) ?? []
        characterCountingVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .characterCountingVersion
        ) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(books, forKey: .books)
        try container.encode(events, forKey: .events)
        try container.encode(dailySummaries, forKey: .dailySummaries)
        try container.encode(cursors, forKey: .cursors)
        try container.encode(characterCountingVersion, forKey: .characterCountingVersion)
    }

    /// Repairs detailed events written by the original counter. During a chapter change,
    /// ReaderView briefly exposed an unpaginated placeholder whose text was the *entire next
    /// chapter*. That whole chapter was recorded once, then its real pages were recorded
    /// again. For a completed contiguous chapter run, the bad first event is identifiable:
    /// it is a large outlier and equals the unread first page plus all following page events.
    /// Replacing it with that remainder restores the page total without guessing a blanket
    /// percentage. Ambiguous runs are deliberately left untouched.
    @discardableResult
    mutating func repairLegacyCharacterCounts() -> Bool {
        guard characterCountingVersion < Self.currentCharacterCountingVersion else {
            return false
        }

        var indicesByBook: [UUID: [Int]] = [:]
        for index in events.indices where events[index].pageTurns > 0 {
            indicesByBook[events[index].bookID, default: []].append(index)
        }

        for (bookID, unsortedIndices) in indicesByBook {
            let indices = unsortedIndices.sorted { events[$0].timestamp < events[$1].timestamp }
            let positiveCounts = indices
                .map { events[$0].characterCount }
                .filter { $0 > 0 }
                .sorted()
            guard !positiveCounts.isEmpty else { continue }

            // Whole-chapter placeholders are normally several times larger than a rendered
            // page. The median remains representative because there is at most one such
            // placeholder per chapter run, while a chapter normally has several pages.
            let typicalPageCount = positiveCounts[positiveCounts.count / 2]
            let plausiblePageCeiling = max(typicalPageCount * 2, typicalPageCount + 800)
            let bookIsFinished = books.first(where: { $0.id == bookID })?.currentProgress ?? 0 >= 0.999

            var runStart = 0
            while runStart < indices.count {
                let chapterTitle = events[indices[runStart]].chapterTitle
                var runEnd = runStart + 1
                while runEnd < indices.count,
                      events[indices[runEnd]].chapterTitle == chapterTitle {
                    runEnd += 1
                }

                let beginsAfterAnotherChapter = runStart > 0
                let hasFollowingChapter = runEnd < indices.count
                let completedForward = hasFollowingChapter
                    ? events[indices[runEnd]].progress > events[indices[runStart]].progress
                    : bookIsFinished
                let candidateIndex = indices[runStart]
                let candidateCount = events[candidateIndex].characterCount

                if beginsAfterAnotherChapter,
                   completedForward,
                   runEnd - runStart > 1,
                   candidateCount > plausiblePageCeiling {
                    let followingCount = indices[(runStart + 1)..<runEnd].reduce(0) {
                        $0 + max(events[$1].characterCount, 0)
                    }
                    let inferredFirstPageCount = candidateCount - followingCount
                    // A small amount of backtracking can make the following pages add up
                    // to the entire chapter. In that still-unambiguous case, fall back to
                    // the book's median rendered-page size instead of preserving the known
                    // whole-chapter value. If following activity exceeds the chapter total,
                    // the run is genuinely ambiguous and remains untouched.
                    let repairedCount: Int? = if inferredFirstPageCount > 0,
                                                inferredFirstPageCount <= plausiblePageCeiling {
                        inferredFirstPageCount
                    } else if candidateCount >= followingCount {
                        typicalPageCount
                    } else {
                        nil
                    }
                    if let repairedCount {
                        let event = events[candidateIndex]
                        events[candidateIndex] = ReadingStatsEvent(
                            id: event.id,
                            bookID: event.bookID,
                            bookTitle: event.bookTitle,
                            timestamp: event.timestamp,
                            durationSeconds: event.durationSeconds,
                            pageTurns: event.pageTurns,
                            characterCount: repairedCount,
                            chapterTitle: event.chapterTitle,
                            progress: event.progress
                        )
                    }
                }

                runStart = runEnd
            }
        }

        // ReadingStatsBook is the lifetime cache used by the overview. Rebuild only its
        // character total from the repaired source-of-truth activity; durations and page
        // turns are unaffected by this migration.
        var characterTotals: [UUID: Int] = [:]
        for summary in dailySummaries {
            characterTotals[summary.bookID, default: 0] += max(summary.characterCount, 0)
        }
        for event in events {
            characterTotals[event.bookID, default: 0] += max(event.characterCount, 0)
        }
        for index in books.indices {
            books[index].characterCount = characterTotals[books[index].id, default: 0]
        }

        characterCountingVersion = Self.currentCharacterCountingVersion
        return true
    }

    var totalDurationSeconds: TimeInterval {
        books.reduce(0) { $0 + $1.totalDurationSeconds }
    }

    var totalPageTurns: Int {
        books.reduce(0) { $0 + $1.pageTurns }
    }

    var totalCharacterCount: Int {
        books.reduce(0) { $0 + $1.characterCount }
    }

    /// Days the user has read consecutively, counted back from today (or the
    /// reference date). An empty *today* is grace-permitted — the streak survives
    /// until you skip an earlier day. Single source of truth for the streak badge
    /// shown on both the 我 hero card and the 统计 tab.
    func currentStreak(reference: Date = Date(), calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: reference)
        var perDayDuration: [Date: TimeInterval] = [:]
        for summary in dailySummaries {
            let day = calendar.startOfDay(for: summary.day)
            perDayDuration[day, default: 0] += summary.durationSeconds
        }
        for event in events {
            let day = calendar.startOfDay(for: event.timestamp)
            perDayDuration[day, default: 0] += event.durationSeconds
        }
        var streak = 0
        var cursor = today
        var safety = 0
        while safety < 366 {
            let duration = perDayDuration[cursor] ?? 0
            if duration > 0 {
                streak += 1
            } else if !calendar.isDate(cursor, inSameDayAs: today) {
                break
            }
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
            safety += 1
        }
        return streak
    }

    /// Iterates both compacted and detailed activity without allocating a merged array.
    /// Daily summaries use their calendar-day start as the timestamp.
    func forEachActivity(
        _ body: (
            _ bookID: UUID,
            _ bookTitle: String,
            _ timestamp: Date,
            _ durationSeconds: TimeInterval,
            _ pageTurns: Int,
            _ characterCount: Int
        ) -> Void
    ) {
        for summary in dailySummaries {
            body(
                summary.bookID,
                summary.bookTitle,
                summary.day,
                summary.durationSeconds,
                summary.pageTurns,
                summary.characterCount
            )
        }
        for event in events {
            body(
                event.bookID,
                event.bookTitle,
                event.timestamp,
                event.durationSeconds,
                event.pageTurns,
                event.characterCount
            )
        }
    }

    func totalDuration(since cutoff: Date) -> TimeInterval {
        var total: TimeInterval = 0
        forEachActivity { _, _, timestamp, duration, _, _ in
            if timestamp >= cutoff {
                total += duration
            }
        }
        return total
    }

    /// Keeps recent chapter-level history while bounding work on the Stats screen.
    /// Events outside the history window, plus the oldest events over the hard cap,
    /// are merged into stable per-book/per-day summaries.
    mutating func compactHistory(
        reference: Date = Date(),
        calendar: Calendar = .current
    ) {
        guard !events.isEmpty else { return }

        let today = calendar.startOfDay(for: reference)
        let historyCutoff = calendar.date(
            byAdding: .day,
            value: -Self.detailedHistoryDays,
            to: today
        ) ?? today

        var eventIDsToCompact = Set(
            events.lazy
                .filter { $0.timestamp < historyCutoff }
                .map(\.id)
        )

        let recentEvents = events.filter { !eventIDsToCompact.contains($0.id) }
        if recentEvents.count > Self.maximumDetailedEventCount {
            var latestEventIDByBook: [UUID: UUID] = [:]
            var latestTimestampByBook: [UUID: Date] = [:]
            for event in recentEvents {
                if event.timestamp >= (latestTimestampByBook[event.bookID] ?? .distantPast) {
                    latestTimestampByBook[event.bookID] = event.timestamp
                    latestEventIDByBook[event.bookID] = event.id
                }
            }

            var numberToCompact = recentEvents.count - Self.maximumDetailedEventCount
            for event in recentEvents.sorted(by: { $0.timestamp < $1.timestamp })
            where numberToCompact > 0 {
                guard latestEventIDByBook[event.bookID] != event.id else { continue }
                eventIDsToCompact.insert(event.id)
                numberToCompact -= 1
            }

            // A pathological import can create more than the cap's worth of books
            // inside the detail window. In that case keeping one event per book
            // would still leave the array unbounded, so roll up the oldest remaining
            // entries after preserving as many latest-per-book events as possible.
            if numberToCompact > 0 {
                for event in recentEvents.sorted(by: { $0.timestamp < $1.timestamp })
                where numberToCompact > 0 && !eventIDsToCompact.contains(event.id) {
                    eventIDsToCompact.insert(event.id)
                    numberToCompact -= 1
                }
            }
        }

        guard !eventIDsToCompact.isEmpty else { return }

        struct SummaryKey: Hashable {
            let day: Date
            let bookID: UUID
        }

        var summaries: [SummaryKey: ReadingStatsDailySummary] = [:]
        summaries.reserveCapacity(dailySummaries.count + eventIDsToCompact.count)
        for summary in dailySummaries {
            let day = calendar.startOfDay(for: summary.day)
            let key = SummaryKey(day: day, bookID: summary.bookID)
            if var existing = summaries[key] {
                existing.bookTitle = summary.bookTitle
                existing.durationSeconds += summary.durationSeconds
                existing.pageTurns += summary.pageTurns
                existing.characterCount += summary.characterCount
                summaries[key] = existing
            } else {
                summaries[key] = ReadingStatsDailySummary(
                    day: day,
                    bookID: summary.bookID,
                    bookTitle: summary.bookTitle,
                    durationSeconds: summary.durationSeconds,
                    pageTurns: summary.pageTurns,
                    characterCount: summary.characterCount
                )
            }
        }

        for event in events where eventIDsToCompact.contains(event.id) {
            let day = calendar.startOfDay(for: event.timestamp)
            let key = SummaryKey(day: day, bookID: event.bookID)
            if var existing = summaries[key] {
                existing.bookTitle = event.bookTitle
                existing.durationSeconds += event.durationSeconds
                existing.pageTurns += event.pageTurns
                existing.characterCount += event.characterCount
                summaries[key] = existing
            } else {
                summaries[key] = ReadingStatsDailySummary(
                    day: day,
                    bookID: event.bookID,
                    bookTitle: event.bookTitle,
                    durationSeconds: event.durationSeconds,
                    pageTurns: event.pageTurns,
                    characterCount: event.characterCount
                )
            }
        }

        events.removeAll { eventIDsToCompact.contains($0.id) }
        dailySummaries = summaries.values.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            return $0.bookID.uuidString < $1.bookID.uuidString
        }
    }

    mutating func rememberBook(_ novel: Novel, at date: Date = Date(), deletedAt: Date? = nil) {
        let progress = min(max(novel.progress, 0), 1)
        if let index = books.firstIndex(where: { $0.id == novel.id }) {
            books[index].title = novel.title
            books[index].author = novel.author
            books[index].coverPalette = novel.coverPalette
            books[index].coverImageURLString = novel.coverImageURLString
            books[index].sourceURLString = novel.sourceURLString
            books[index].lastReadAt = max(books[index].lastReadAt, date)
            books[index].currentProgress = progress
            if let deletedAt {
                books[index].deletedAt = deletedAt
            }
        } else {
            books.append(
                ReadingStatsBook(
                    id: novel.id,
                    title: novel.title,
                    author: novel.author,
                    coverPalette: novel.coverPalette,
                    coverImageURLString: novel.coverImageURLString,
                    sourceURLString: novel.sourceURLString,
                    firstReadAt: date,
                    lastReadAt: date,
                    deletedAt: deletedAt,
                    currentProgress: progress,
                    totalDurationSeconds: TimeInterval(max(novel.readMinutes, 0) * 60),
                    pageTurns: 0,
                    characterCount: 0
                )
            )
        }
    }

    /// Records a reading observation. An event is emitted **only** when the user actually
    /// advances the reading position by one page (or one chapter). Re-pagination, font/size
    /// changes, app foreground/background transitions, and onAppear / onDisappear flushes do
    /// NOT count, even if measurable elapsed time has passed since the last call — opening
    /// a book and closing it without turning a page no longer marks the day as "read".
    ///
    /// Trade-off: time spent lingering on the final page before closing is not credited,
    /// because no page turn triggers the flush. Most reading trackers behave the same way.
    mutating func recordReading(
        novel: Novel,
        timestamp: Date,
        chapterTitle: String,
        progress: Double,
        chapterIndex: Int?,
        chapterPageIndex: Int?,
        chapterSourceURLString: String?,
        pageTextCharacterCount: Int,
        pageTurnStep: Int = 1
    ) {
        rememberBook(novel, at: timestamp)

        let clampedProgress = min(max(progress, 0), 1)
        let pageKey = [
            chapterSourceURLString ?? "",
            String(chapterIndex ?? -1),
            String(chapterPageIndex ?? -1)
        ].joined(separator: "|")

        func updateBookProgress() {
            if let bookIndex = books.firstIndex(where: { $0.id == novel.id }) {
                books[bookIndex].currentProgress = clampedProgress
                books[bookIndex].lastReadAt = max(books[bookIndex].lastReadAt, timestamp)
            }
        }

        guard let cursorIndex = cursors.firstIndex(where: { $0.bookID == novel.id }) else {
            // First observation for this book — establish a cursor without emitting an event.
            cursors.append(
                ReadingStatsCursor(
                    bookID: novel.id,
                    lastObservedAt: timestamp,
                    lastPageKey: pageKey,
                    lastProgress: clampedProgress,
                    chapterIndex: chapterIndex,
                    chapterPageIndex: chapterPageIndex,
                    chapterSourceURLString: chapterSourceURLString
                )
            )
            updateBookProgress()
            return
        }

        let previous = cursors[cursorIndex]
        let isPageTurn = shouldCountPageReading(
            previous: previous,
            currentPageKey: pageKey,
            chapterIndex: chapterIndex,
            chapterPageIndex: chapterPageIndex,
            pageTurnStep: pageTurnStep
        )

        guard isPageTurn else {
            // Not a counted page turn. Keep the cursor's `lastObservedAt` anchored at the
            // last real turn so elapsed time on the current page keeps accumulating until
            // the user actually turns it. Refresh the location fields if the position
            // shifted (e.g., a chapter jump) and reset the clock in that case so we don't
            // later credit time spent navigating menus as reading.
            let pageKeyChanged = previous.lastPageKey != pageKey
            cursors[cursorIndex] = ReadingStatsCursor(
                bookID: novel.id,
                lastObservedAt: pageKeyChanged ? timestamp : previous.lastObservedAt,
                lastPageKey: pageKey,
                lastProgress: clampedProgress,
                chapterIndex: chapterIndex,
                chapterPageIndex: chapterPageIndex,
                chapterSourceURLString: chapterSourceURLString
            )
            updateBookProgress()
            return
        }

        let elapsed = timestamp.timeIntervalSince(previous.lastObservedAt)
        let duration: TimeInterval = (elapsed > 0.5 && elapsed <= 15 * 60) ? min(elapsed, 5 * 60) : 0
        let characters = max(pageTextCharacterCount, 0)

        cursors[cursorIndex] = ReadingStatsCursor(
            bookID: novel.id,
            lastObservedAt: timestamp,
            lastPageKey: pageKey,
            lastProgress: clampedProgress,
            chapterIndex: chapterIndex,
            chapterPageIndex: chapterPageIndex,
            chapterSourceURLString: chapterSourceURLString
        )

        events.append(
            ReadingStatsEvent(
                id: UUID(),
                bookID: novel.id,
                bookTitle: novel.title,
                timestamp: timestamp,
                durationSeconds: duration,
                pageTurns: 1,
                characterCount: characters,
                chapterTitle: chapterTitle,
                progress: clampedProgress
            )
        )
        if events.count > Self.maximumDetailedEventCount {
            compactHistory(reference: timestamp)
        }

        if let bookIndex = books.firstIndex(where: { $0.id == novel.id }) {
            books[bookIndex].lastReadAt = max(books[bookIndex].lastReadAt, timestamp)
            books[bookIndex].currentProgress = clampedProgress
            books[bookIndex].totalDurationSeconds += duration
            books[bookIndex].pageTurns += 1
            books[bookIndex].characterCount += characters
        }
    }

    mutating func startReadingSession(
        novel: Novel,
        timestamp: Date,
        progress: Double,
        chapterIndex: Int?,
        chapterPageIndex: Int?,
        chapterSourceURLString: String?
    ) {
        rememberBook(novel, at: timestamp)

        let clampedProgress = min(max(progress, 0), 1)
        let pageKey = [
            chapterSourceURLString ?? "",
            String(chapterIndex ?? -1),
            String(chapterPageIndex ?? -1)
        ].joined(separator: "|")

        if let cursorIndex = cursors.firstIndex(where: { $0.bookID == novel.id }) {
            cursors[cursorIndex] = ReadingStatsCursor(
                bookID: novel.id,
                lastObservedAt: timestamp,
                lastPageKey: pageKey,
                lastProgress: clampedProgress,
                chapterIndex: chapterIndex,
                chapterPageIndex: chapterPageIndex,
                chapterSourceURLString: chapterSourceURLString
            )
        } else {
            cursors.append(
                ReadingStatsCursor(
                    bookID: novel.id,
                    lastObservedAt: timestamp,
                    lastPageKey: pageKey,
                    lastProgress: clampedProgress,
                    chapterIndex: chapterIndex,
                    chapterPageIndex: chapterPageIndex,
                    chapterSourceURLString: chapterSourceURLString
                )
            )
        }

        if let bookIndex = books.firstIndex(where: { $0.id == novel.id }) {
            books[bookIndex].currentProgress = clampedProgress
            books[bookIndex].lastReadAt = max(books[bookIndex].lastReadAt, timestamp)
        }
    }

    private func shouldCountPageReading(
        previous: ReadingStatsCursor,
        currentPageKey: String,
        chapterIndex: Int?,
        chapterPageIndex: Int?,
        pageTurnStep: Int
    ) -> Bool {
        guard previous.lastPageKey != currentPageKey else { return false }
        guard let previousChapterIndex = previous.chapterIndex,
              let previousChapterPageIndex = previous.chapterPageIndex,
              let chapterIndex,
              let chapterPageIndex else {
            return false
        }

        if chapterIndex == previousChapterIndex {
            return chapterPageIndex - previousChapterPageIndex == max(pageTurnStep, 1)
        }

        return chapterIndex - previousChapterIndex == 1
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    nonisolated static let uncategorizedName = "无分类"

    @Published var categories: [LibraryCategory] {
        didSet {
            scheduleSave()
        }
    }

    @Published private(set) var archivedBooks: [ArchivedBookRecord] {
        didSet {
            scheduleSave()
        }
    }

    @Published private(set) var readingStats: ReadingStatsLedger {
        didSet {
            scheduleStatsSave()
        }
    }

    private let storageURL: URL
    private let statsStorageURL: URL
    private var pendingSave: Task<Void, Never>?
    private var pendingStatsSave: Task<Void, Never>?
    private var saveGeneration: UInt = 0
    private var statsSaveGeneration: UInt = 0

    init(storageDirectory: URL? = nil) {
        self.storageURL = LibraryStore.makeStorageURL(in: storageDirectory)
        self.statsStorageURL = LibraryStore.makeStatsStorageURL(in: storageDirectory)

#if DEBUG
        let usesScreenshotFixture = CommandLine.arguments.contains("--screenshot-fixture")
        let loadedLibrary = usesScreenshotFixture
            ? LibraryStorageSnapshot(
                categories: LibraryStore.screenshotFixtureCategories(),
                archivedBooks: []
            )
            : LibraryStore.loadLibrary(from: storageURL)
        let normalizedLibrary = LibraryStore.normalizedLibrary(loadedLibrary)
        self.categories = normalizedLibrary.categories
        self.archivedBooks = normalizedLibrary.archivedBooks
        var loadedStats = usesScreenshotFixture
            ? ReadingStatsLedger()
            : (LibraryStore.loadReadingStats(from: statsStorageURL) ?? ReadingStatsLedger())
#else
        let loadedLibrary = LibraryStore.loadLibrary(from: storageURL)
        let normalizedLibrary = LibraryStore.normalizedLibrary(loadedLibrary)
        self.categories = normalizedLibrary.categories
        self.archivedBooks = normalizedLibrary.archivedBooks
        var loadedStats = LibraryStore.loadReadingStats(from: statsStorageURL) ?? ReadingStatsLedger()
#endif
        let statsBeforeMigration = loadedStats
        // Older builds recorded "ghost" events whenever pagination or scene-phase changes
        // triggered a persist, even if the user never turned a page. Strip those legacy
        // events on load so the calendar/streak reflect actual reading rather than incidental
        // book-opens. Page-turn events have `pageTurns >= 1` by construction.
        loadedStats.events.removeAll { $0.pageTurns == 0 }
        loadedStats.repairLegacyCharacterCounts()
        loadedStats.compactHistory()
        self.readingStats = loadedStats
        seedReadingStatsFromLibraryIfNeeded()
        if loadedStats != statsBeforeMigration {
            scheduleStatsSave()
        }

        if storageDirectory == nil {
            let activeBookIDs = Set(allNovels.map(\.id))
            Task {
                await BookCoverStore.shared.removeOrphanedCovers(keeping: activeBookIDs)
            }
        }
    }

    func flush() async {
        saveGeneration &+= 1
        statsSaveGeneration &+= 1
        pendingSave?.cancel()
        pendingSave = nil
        pendingStatsSave?.cancel()
        pendingStatsSave = nil
        let snapshot = librarySnapshot
        let url = storageURL
        let statsSnapshot = readingStats
        let statsURL = statsStorageURL
        await Self.persistLibrary(snapshot, to: url)
        await Self.persistReadingStats(statsSnapshot, to: statsURL)
    }

    /// Phase 5.3 restore hook. `readingStats` is `private(set)` so other
    /// views can't drift the ledger out from under the calendar/streak
    /// UI; backup-restore is the one place it's legitimate to replace
    /// the whole snapshot. Setting through the published property runs
    /// the `didSet` save scheduler — the caller still calls `flush()`
    /// afterwards so the restore lands on disk before a quit.
    func replaceReadingStats(_ stats: ReadingStatsLedger) {
        var compacted = stats
        compacted.repairLegacyCharacterCounts()
        compacted.compactHistory()
        readingStats = compacted
    }

    /// Backup-restore hook that replaces both mutually-exclusive book locations together.
    func replaceLibrary(
        categories: [LibraryCategory],
        archivedBooks: [ArchivedBookRecord]
    ) {
        let normalized = Self.normalizedLibrary(
            LibraryStorageSnapshot(categories: categories, archivedBooks: archivedBooks)
        )
        self.categories = normalized.categories
        self.archivedBooks = normalized.archivedBooks
    }

    var allNovels: [Novel] {
        categories.flatMap(\.novels) + archivedBooks.map(\.novel)
    }

    var archivedNovels: [Novel] { archivedBooks.map(\.novel) }

    func isArchived(_ novel: Novel) -> Bool {
        archivedBooks.contains { $0.id == novel.id }
    }

    /// The novel the user has most recently opened, or nil if nothing has been
    /// opened yet. Earlier this was a fully sorted array (`O(N log N)` per
    /// access) but the only caller takes `.first` — `max(by:)` does the same
    /// work as a single O(N) pass.
    var mostRecentlyOpenedNovel: Novel? {
        var best: Novel?
        var bestDate: Date = .distantPast
        for category in categories {
            for novel in category.novels {
                guard let opened = novel.lastOpenedAt else { continue }
                if opened > bestDate {
                    bestDate = opened
                    best = novel
                }
            }
        }
        return best
    }

    func containsBook(sourceURLString: String?, title: String) -> Bool {
        let normalizedTitle = normalized(title)
        return allNovels.contains { novel in
            matches(novel, sourceURLString: sourceURLString, normalizedTitle: normalizedTitle)
        }
    }

    func categoryName(forBookWith sourceURLString: String?, title: String) -> String? {
        let normalizedTitle = normalized(title)
        for category in categories {
            if category.novels.contains(where: {
                matches($0, sourceURLString: sourceURLString, normalizedTitle: normalizedTitle)
            }) {
                return category.name
            }
        }
        return nil
    }

    func isArchivedBook(sourceURLString: String?, title: String) -> Bool {
        let normalizedTitle = normalized(title)
        return archivedBooks.contains {
            matches($0.novel, sourceURLString: sourceURLString, normalizedTitle: normalizedTitle)
        }
    }

    func importedBookNeedsRepair(sourceURLString: String?, title: String) -> Bool {
        let normalizedTitle = normalized(title)
        guard let novel = allNovels.first(where: {
            matches($0, sourceURLString: sourceURLString, normalizedTitle: normalizedTitle)
        }) else {
            return true
        }

        guard !novel.chapters.isEmpty else { return true }
        if novel.chapters.contains(where: { $0.sourceURLString != nil }) {
            if chapterSourcesMismatchBookSource(novel) {
                return true
            }
            return novel.chapters.count < 20
        }

        if novel.chapters.count < 10 {
            return true
        }

        let readableChapterCount = novel.chapters.filter { chapter in
            chapter.content
                .replacingOccurrences(of: chapter.title, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .count >= 30
        }.count

        return readableChapterCount < max(1, novel.chapters.count / 2)
    }

    @discardableResult
    func addImportedNovel(_ novel: Novel, categoryName: String = LibraryStore.uncategorizedName) -> Bool {
        let normalizedTitle = normalized(novel.title)
        let existingArchiveDate = archivedBooks.first(where: {
            matches($0.novel, sourceURLString: novel.sourceURLString, normalizedTitle: normalizedTitle)
        })?.archivedAt

        removeExistingBook(
            sourceURLString: novel.sourceURLString,
            title: novel.title,
            replacementBookID: novel.id
        )

        // Stamp `addedAt` (not `lastOpenedAt`) so the just-imported book
        // floats to the top of its category in the wallet stack — but
        // doesn't hijack the "继续阅读" hero card, which keys on
        // `lastOpenedAt` alone. Opening any book later naturally
        // outranks both via `librarySortRank`.
        var stamped = novel
        stamped.addedAt = Date.now

        if let existingArchiveDate {
            archivedBooks.insert(
                ArchivedBookRecord(novel: stamped, archivedAt: existingArchiveDate),
                at: 0
            )
        } else {
            let targetIndex = ensureCategory(named: categoryName)
            categories[targetIndex].novels.insert(stamped, at: 0)
        }
        Task {
            await BookCoverStore.shared.prefetchCover(
                for: stamped.id,
                remoteURLString: stamped.coverImageURLString
            )
        }
        return true
    }

    @discardableResult
    func addCategory(named name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }

        let exists = categories.contains {
            $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
        guard !exists else { return false }

        categories.append(LibraryCategory(name: trimmedName, novels: []))
        return true
    }

    func renameCategory(id: UUID, to newName: String) -> Bool {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }

        guard let index = categories.firstIndex(where: { $0.id == id }) else { return false }

        if categories[index].name == trimmedName { return true }

        let conflicts = categories.contains { other in
            other.id != id && other.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
        guard !conflicts else { return false }

        categories[index].name = trimmedName
        return true
    }

    /// Moves an active book into the archive. The returned token powers the brief Undo
    /// affordance and is deliberately not persisted.
    @discardableResult
    func archiveBook(
        _ novel: Novel,
        archivedAt: Date = Date()
    ) -> LibraryArchiveUndo? {
        guard let sourceLocation = location(for: novel.id),
              case .category(let categoryIndex, let novelIndex) = sourceLocation else {
            return nil
        }

        let storedNovel = categories[categoryIndex].novels[novelIndex]
        let undo = LibraryArchiveUndo(
            bookID: storedNovel.id,
            categoryID: categories[categoryIndex].id,
            categoryIndex: novelIndex
        )
        var updatedCategories = categories
        var updatedArchive = archivedBooks
        updatedCategories[categoryIndex].novels.remove(at: novelIndex)
        updatedArchive.removeAll { $0.id == storedNovel.id }
        updatedArchive.insert(
            ArchivedBookRecord(novel: storedNovel, archivedAt: archivedAt),
            at: 0
        )
        categories = updatedCategories
        archivedBooks = updatedArchive
        return undo
    }

    @discardableResult
    func undoArchive(_ undo: LibraryArchiveUndo) -> Bool {
        guard let archivedIndex = archivedBooks.firstIndex(where: { $0.id == undo.bookID }) else {
            return false
        }
        var updatedCategories = categories
        let targetIndex: Int
        if let existing = updatedCategories.firstIndex(where: { $0.id == undo.categoryID }) {
            targetIndex = existing
        } else {
            targetIndex = ensureCategoryIndex(
                named: Self.uncategorizedName,
                in: &updatedCategories
            )
        }

        var updatedArchive = archivedBooks
        let restoredNovel = updatedArchive.remove(at: archivedIndex).novel
        let insertionIndex = min(max(undo.categoryIndex, 0), updatedCategories[targetIndex].novels.count)
        updatedCategories[targetIndex].novels.insert(restoredNovel, at: insertionIndex)
        categories = updatedCategories
        archivedBooks = updatedArchive
        return true
    }

    /// Moves either an active or archived book into a normal category. This is the only
    /// long-term restore path exposed by the archive UI.
    @discardableResult
    func moveBook(_ novel: Novel, toCategoryID categoryID: UUID) -> Bool {
        guard categories.contains(where: { $0.id == categoryID }),
              let location = location(for: novel.id) else {
            return false
        }

        let storedNovel = self.novel(at: location)
        var updatedCategories = categories
        var updatedArchive = archivedBooks
        removeBook(at: location, from: &updatedCategories, archivedBooks: &updatedArchive)

        guard let refreshedTargetIndex = updatedCategories.firstIndex(where: { $0.id == categoryID }) else {
            return false
        }
        updatedCategories[refreshedTargetIndex].novels.append(storedNovel)
        categories = updatedCategories
        archivedBooks = updatedArchive
        return true
    }

    func deleteBook(_ novel: Novel) {
        let storedNovel = location(for: novel.id).map { self.novel(at: $0) } ?? novel
        readingStats.rememberBook(storedNovel, deletedAt: Date())
        var updatedCategories = categories
        var updatedArchive = archivedBooks
        for index in updatedCategories.indices {
            updatedCategories[index].novels.removeAll { $0.id == novel.id }
        }
        updatedArchive.removeAll { $0.id == novel.id }
        categories = updatedCategories
        archivedBooks = updatedArchive
        removeStoredAssets(for: [storedNovel])
    }

    func deleteCategory(id: UUID) {
        guard let category = categories.first(where: { $0.id == id }) else { return }
        let removedNovels = category.novels
        let deletedAt = Date()
        for novel in removedNovels {
            readingStats.rememberBook(novel, deletedAt: deletedAt)
        }
        categories.removeAll { $0.id == id }
        removeStoredAssets(for: removedNovels)
    }

    func reconcileStoredCovers() {
        let activeBookIDs = Set(allNovels.map(\.id))
        Task {
            await BookCoverStore.shared.removeOrphanedCovers(keeping: activeBookIDs)
        }
    }

    func updateReadingState(
        for novelID: UUID,
        chapterTitle: String,
        progress: Double,
        chapterIndex: Int? = nil,
        chapterPageIndex: Int? = nil,
        chapterSourceURLString: String? = nil,
        pageTextCharacterCount: Int? = nil,
        pageTurnStep: Int = 1,
        openedAt: Date = Date()
    ) {
        let clampedProgress = min(max(progress, 0), 1)
        let trimmedChapterTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let location = location(for: novelID) else {
            return
        }

        let existingNovel = novel(at: location)
        readingStats.recordReading(
            novel: existingNovel,
            timestamp: openedAt,
            chapterTitle: trimmedChapterTitle,
            progress: clampedProgress,
            chapterIndex: chapterIndex,
            chapterPageIndex: chapterPageIndex,
            chapterSourceURLString: chapterSourceURLString,
            pageTextCharacterCount: pageTextCharacterCount ?? 0,
            pageTurnStep: pageTurnStep
        )

        var updatedNovel = existingNovel
        if !trimmedChapterTitle.isEmpty {
            updatedNovel.lastChapter = trimmedChapterTitle
        }
        updatedNovel.progress = clampedProgress
        updatedNovel.currentChapterIndex = chapterIndex
        updatedNovel.currentChapterPageIndex = chapterPageIndex
        updatedNovel.currentChapterSourceURLString = chapterSourceURLString
        updatedNovel.lastOpenedAt = openedAt
        updatedNovel.readMinutes = max(
            updatedNovel.readMinutes,
            Int((readingStats.books.first { $0.id == novelID }?.totalDurationSeconds ?? 0) / 60)
        )
        replaceNovel(updatedNovel, at: location)
    }

    func startReadingSession(
        for novelID: UUID,
        progress: Double,
        chapterIndex: Int? = nil,
        chapterPageIndex: Int? = nil,
        chapterSourceURLString: String? = nil,
        openedAt: Date = Date()
    ) {
        let clampedProgress = min(max(progress, 0), 1)

        guard let location = location(for: novelID) else {
            return
        }

        let existingNovel = novel(at: location)
        readingStats.startReadingSession(
            novel: existingNovel,
            timestamp: openedAt,
            progress: clampedProgress,
            chapterIndex: chapterIndex,
            chapterPageIndex: chapterPageIndex,
            chapterSourceURLString: chapterSourceURLString
        )

        var updatedNovel = existingNovel
        updatedNovel.lastOpenedAt = openedAt
        updatedNovel.progress = clampedProgress
        updatedNovel.currentChapterIndex = chapterIndex
        updatedNovel.currentChapterPageIndex = chapterPageIndex
        updatedNovel.currentChapterSourceURLString = chapterSourceURLString
        replaceNovel(updatedNovel, at: location)
    }

    private func ensureCategory(named name: String) -> Int {
        if let existingIndex = categories.firstIndex(where: { $0.name == name }) {
            return existingIndex
        }

        categories.append(LibraryCategory(name: name, novels: []))
        return categories.count - 1
    }

    private func ensureCategoryIndex(
        named name: String,
        in categories: inout [LibraryCategory]
    ) -> Int {
        if let existingIndex = categories.firstIndex(where: { $0.name == name }) {
            return existingIndex
        }
        categories.append(LibraryCategory(name: name, novels: []))
        return categories.count - 1
    }

    private enum StoredBookLocation {
        case category(categoryIndex: Int, novelIndex: Int)
        case archived(index: Int)
    }

    private func location(for novelID: UUID) -> StoredBookLocation? {
        for categoryIndex in categories.indices {
            if let novelIndex = categories[categoryIndex].novels.firstIndex(where: { $0.id == novelID }) {
                return .category(categoryIndex: categoryIndex, novelIndex: novelIndex)
            }
        }
        if let index = archivedBooks.firstIndex(where: { $0.id == novelID }) {
            return .archived(index: index)
        }
        return nil
    }

    private func novel(at location: StoredBookLocation) -> Novel {
        switch location {
        case .category(let categoryIndex, let novelIndex):
            return categories[categoryIndex].novels[novelIndex]
        case .archived(let index):
            return archivedBooks[index].novel
        }
    }

    private func replaceNovel(_ novel: Novel, at location: StoredBookLocation) {
        switch location {
        case .category(let categoryIndex, let novelIndex):
            var updatedCategories = categories
            updatedCategories[categoryIndex].novels[novelIndex] = novel
            categories = updatedCategories
        case .archived(let index):
            var updatedArchive = archivedBooks
            updatedArchive[index].novel = novel
            archivedBooks = updatedArchive
        }
    }

    private func removeBook(
        at location: StoredBookLocation,
        from categories: inout [LibraryCategory],
        archivedBooks: inout [ArchivedBookRecord]
    ) {
        switch location {
        case .category(let categoryIndex, let novelIndex):
            categories[categoryIndex].novels.remove(at: novelIndex)
        case .archived(let index):
            archivedBooks.remove(at: index)
        }
    }

    private func normalized(_ text: String) -> String {
        simplifiedChinese(text)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]"#, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func simplifiedChinese(_ text: String) -> String {
        ChineseTextConverter.simplified(text)
    }

    private func chapterSourcesMismatchBookSource(_ novel: Novel) -> Bool {
        guard let sourceURLString = novel.sourceURLString,
              let sourceBookID = bookID(from: sourceURLString) else {
            return false
        }

        let chapterBookIDs = novel.chapters.compactMap { chapter in
            chapter.sourceURLString.flatMap(bookID)
        }
        guard !chapterBookIDs.isEmpty else { return false }

        let matchingCount = chapterBookIDs.filter { $0 == sourceBookID }.count
        return matchingCount < max(1, chapterBookIDs.count / 2)
    }

    private func bookID(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let path = url.path
        let patterns = [
            #"/book/(\d+)(?:/index)?\.html$"#,
            #"/book/(\d+)/\d+(?:\.html?)?$"#,
            #"/book/(\d+)/?$"#,
            #"/books/(\d+)\.html$"#,
            #"/books/(\d+)/\d+\.html$"#,
            #"/txt/(\d+)/\d+\.html$"#,
            #"/(?:htm|html|index|kan|look)/(\d+)/list\.html?$"#,
            #"/(?:htm|html|index|kan|look)/(\d+)(?:/|\.html?)?$"#,
            #"/(?:htm|html|index|kan|look)/(\d+)/\d+(?:\.html?)?$"#,
            #"/read/(\d+)[_/]\d+\.html?$"#,
            #"/ajax_novels/chapterlist/(\d+)\.html$"#
        ]

        for pattern in patterns {
            if let id = firstMatch(pattern, in: path) {
                return id
            }
        }
        return nil
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[capture])
    }

    private func matches(_ novel: Novel, sourceURLString: String?, normalizedTitle: String) -> Bool {
        if let sourceURLString,
           let existingSourceURLString = novel.sourceURLString,
           existingSourceURLString == sourceURLString {
            return true
        }

        return normalized(novel.title) == normalizedTitle
    }

    private func removeExistingBook(
        sourceURLString: String?,
        title: String,
        replacementBookID: UUID
    ) {
        let normalizedTitle = normalized(title)
        var removedNovels: [Novel] = []
        for index in categories.indices {
            let removed = categories[index].novels.filter {
                matches($0, sourceURLString: sourceURLString, normalizedTitle: normalizedTitle)
            }
            for novel in removed {
                readingStats.rememberBook(novel, deletedAt: Date())
                if novel.id != replacementBookID { removedNovels.append(novel) }
            }
            categories[index].novels.removeAll {
                matches($0, sourceURLString: sourceURLString, normalizedTitle: normalizedTitle)
            }
        }
        let archivedMatches = archivedBooks.filter {
            matches($0.novel, sourceURLString: sourceURLString, normalizedTitle: normalizedTitle)
        }
        for record in archivedMatches {
            readingStats.rememberBook(record.novel, deletedAt: Date())
            if record.id != replacementBookID { removedNovels.append(record.novel) }
        }
        archivedBooks.removeAll {
            matches($0.novel, sourceURLString: sourceURLString, normalizedTitle: normalizedTitle)
        }
        removeStoredAssets(for: removedNovels)
    }

    private func removeStoredAssets(for novels: [Novel]) {
        guard !novels.isEmpty else { return }
        for novel in novels {
            BookDownloadManager.shared.clearState(for: novel)
        }
        Task {
            for novel in novels {
                await ChapterContentCache.shared.clearCache(for: novel)
                await BookCoverStore.shared.removeCover(for: novel.id)
            }
        }
    }

    private func seedReadingStatsFromLibraryIfNeeded() {
        guard readingStats.books.isEmpty else { return }
        for novel in allNovels where novel.lastOpenedAt != nil || novel.readMinutes > 0 {
            readingStats.rememberBook(novel, at: novel.lastOpenedAt ?? Date())
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        saveGeneration &+= 1
        let generation = saveGeneration
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.librarySnapshot
            let url = self.storageURL
            await Self.persistLibrary(snapshot, to: url)
            if self.saveGeneration == generation {
                self.pendingSave = nil
            }
        }
    }

    private func scheduleStatsSave() {
        pendingStatsSave?.cancel()
        statsSaveGeneration &+= 1
        let generation = statsSaveGeneration
        pendingStatsSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.readingStats
            let url = self.statsStorageURL
            await Self.persistReadingStats(snapshot, to: url)
            if self.statsSaveGeneration == generation {
                self.pendingStatsSave = nil
            }
        }
    }

    private var librarySnapshot: LibraryStorageSnapshot {
        LibraryStorageSnapshot(categories: categories, archivedBooks: archivedBooks)
    }

    private static func persistLibrary(_ snapshot: LibraryStorageSnapshot, to url: URL) async {
        do {
            try await LibraryPersistenceWriter.shared.persist(snapshot, to: url)
        } catch {
#if DEBUG
            debugLog("[LibraryStore] save failed: \(error.localizedDescription)")
#endif
        }
    }

    private static func persistReadingStats(_ stats: ReadingStatsLedger, to url: URL) async {
        do {
            try await LibraryPersistenceWriter.shared.persist(stats, to: url)
        } catch {
#if DEBUG
            debugLog("[LibraryStore] stats save failed: \(error.localizedDescription)")
#endif
        }
    }

    private static func loadLibrary(from storageURL: URL) -> LibraryStorageSnapshot {
        guard let data = try? Data(contentsOf: storageURL, options: [.mappedIfSafe]) else {
            return LibraryStorageSnapshot(categories: [], archivedBooks: [])
        }
        if let snapshot = try? JSONDecoder().decode(LibraryStorageSnapshot.self, from: data) {
            return snapshot
        }
        if let legacyCategories = try? JSONDecoder().decode([LibraryCategory].self, from: data) {
            return LibraryStorageSnapshot(categories: legacyCategories, archivedBooks: [])
        }
        return LibraryStorageSnapshot(categories: [], archivedBooks: [])
    }

    /// Enforces the single-location invariant at every external persistence boundary.
    /// The first occurrence wins, preserving category order and keeping normal shelves
    /// authoritative if a corrupt or hand-edited backup contains the same book twice.
    private static func normalizedLibrary(
        _ snapshot: LibraryStorageSnapshot
    ) -> LibraryStorageSnapshot {
        var seenBookIDs: Set<UUID> = []
        var normalizedCategories: [LibraryCategory] = []
        normalizedCategories.reserveCapacity(snapshot.categories.count)

        for category in snapshot.categories {
            let uniqueNovels = category.novels.filter { novel in
                seenBookIDs.insert(novel.id).inserted
            }
            normalizedCategories.append(
                LibraryCategory(id: category.id, name: category.name, novels: uniqueNovels)
            )
        }

        let normalizedArchive = snapshot.archivedBooks.filter { record in
            seenBookIDs.insert(record.id).inserted
        }
        return LibraryStorageSnapshot(
            version: snapshot.version,
            categories: normalizedCategories,
            archivedBooks: normalizedArchive
        )
    }

    private static func loadReadingStats(from storageURL: URL) -> ReadingStatsLedger? {
        guard let data = try? Data(contentsOf: storageURL, options: [.mappedIfSafe]) else { return nil }
        return try? JSONDecoder().decode(ReadingStatsLedger.self, from: data)
    }

    private static func makeStorageURL(in storageDirectory: URL?) -> URL {
        let baseURL = storageDirectory ?? defaultStorageDirectory()
        return baseURL
            .appendingPathComponent("LibraryStore.json")
    }

    private static func makeStatsStorageURL(in storageDirectory: URL?) -> URL {
        let baseURL = storageDirectory ?? defaultStorageDirectory()
        return baseURL
            .appendingPathComponent("ReadingStatsStore.json")
    }

    private static func defaultStorageDirectory() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("lingyue", isDirectory: true)
    }

#if DEBUG
    private static func screenshotFixtureCategories() -> [LibraryCategory] {
        let novel = Novel(
            id: UUID(uuidString: "8F72F58F-3B6A-4E08-960D-70F92D6BB377")!,
            title: "红楼梦",
            author: "曹雪芹",
            genre: "古典文学",
            summary: "满纸荒唐言，一把辛酸泪。",
            lastChapter: "第十五回",
            progress: 0.11,
            readMinutes: 0,
            lastOpenedAt: Date(),
            addedAt: Date(),
            currentChapterIndex: 14,
            currentChapterPageIndex: 2,
            coverPalette: .rose,
            isFeatured: false
        )
        return [
            LibraryCategory(
                id: UUID(uuidString: "57EE2FF6-8899-4680-A22A-D04B2BDC563F")!,
                name: "古典文学",
                novels: [novel]
            )
        ]
    }
#endif
}

private actor LibraryPersistenceWriter {
    static let shared = LibraryPersistenceWriter()

    func persist<Value: Encodable & Sendable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
    }
}
