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
    fileprivate var cursors: [ReadingStatsCursor] = []

    var totalDurationSeconds: TimeInterval {
        books.reduce(0) { $0 + $1.totalDurationSeconds }
    }

    var totalPageTurns: Int {
        books.reduce(0) { $0 + $1.pageTurns }
    }

    var totalCharacterCount: Int {
        books.reduce(0) { $0 + $1.characterCount }
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
        pageTextCharacterCount: Int
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
            chapterPageIndex: chapterPageIndex
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
        chapterPageIndex: Int?
    ) -> Bool {
        guard previous.lastPageKey != currentPageKey else { return false }
        guard let previousChapterIndex = previous.chapterIndex,
              let previousChapterPageIndex = previous.chapterPageIndex,
              let chapterIndex,
              let chapterPageIndex else {
            return false
        }

        if chapterIndex == previousChapterIndex {
            return abs(chapterPageIndex - previousChapterPageIndex) == 1
        }

        return abs(chapterIndex - previousChapterIndex) == 1
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

    @Published private(set) var readingStats: ReadingStatsLedger {
        didSet {
            scheduleStatsSave()
        }
    }

    private let storageURL: URL
    private let statsStorageURL: URL
    private var pendingSave: Task<Void, Never>?
    private var pendingStatsSave: Task<Void, Never>?

    init() {
        self.storageURL = LibraryStore.makeStorageURL()
        self.statsStorageURL = LibraryStore.makeStatsStorageURL()

        self.categories = LibraryStore.loadCategories(from: storageURL) ?? []
        var loadedStats = LibraryStore.loadReadingStats(from: statsStorageURL) ?? ReadingStatsLedger()
        // Older builds recorded "ghost" events whenever pagination or scene-phase changes
        // triggered a persist, even if the user never turned a page. Strip those legacy
        // events on load so the calendar/streak reflect actual reading rather than incidental
        // book-opens. Page-turn events have `pageTurns >= 1` by construction.
        loadedStats.events.removeAll { $0.pageTurns == 0 }
        self.readingStats = loadedStats
        seedReadingStatsFromLibraryIfNeeded()
    }

    func flush() async {
        pendingSave?.cancel()
        pendingSave = nil
        pendingStatsSave?.cancel()
        pendingStatsSave = nil
        let snapshot = categories
        let url = storageURL
        let statsSnapshot = readingStats
        let statsURL = statsStorageURL
        await Self.persist(snapshot, to: url)
        await Self.persistReadingStats(statsSnapshot, to: statsURL)
    }

    var allNovels: [Novel] {
        categories.flatMap(\.novels)
    }

    var currentlyReading: [Novel] {
        allNovels
            .filter { $0.lastOpenedAt != nil }
            .sorted { lhs, rhs in
                (lhs.lastOpenedAt ?? .distantPast) > (rhs.lastOpenedAt ?? .distantPast)
            }
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
        removeExistingBook(sourceURLString: novel.sourceURLString, title: novel.title)

        // Stamp the just-imported novel as if it had been opened "now" so the Library's
        // most-recent-first sort places it at the top of the stack, alongside actively-read
        // books. The user can still bury it by opening other books later.
        var stamped = novel
        stamped.lastOpenedAt = Date.now

        let targetIndex = ensureCategory(named: categoryName)
        categories[targetIndex].novels.insert(stamped, at: 0)
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

    func deleteBook(_ novel: Novel) {
        readingStats.rememberBook(novel, deletedAt: Date())
        var updatedCategories = categories
        for index in updatedCategories.indices {
            updatedCategories[index].novels.removeAll { $0.id == novel.id }
        }
        categories = updatedCategories
    }

    func updateReadingState(
        for novelID: UUID,
        chapterTitle: String,
        progress: Double,
        chapterIndex: Int? = nil,
        chapterPageIndex: Int? = nil,
        chapterSourceURLString: String? = nil,
        pageTextCharacterCount: Int? = nil,
        openedAt: Date = Date()
    ) {
        let clampedProgress = min(max(progress, 0), 1)
        let trimmedChapterTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        for categoryIndex in categories.indices {
            guard let novelIndex = categories[categoryIndex].novels.firstIndex(where: { $0.id == novelID }) else {
                continue
            }

            let existingNovel = categories[categoryIndex].novels[novelIndex]
            let pageCharacters = pageTextCharacterCount ?? 0
            readingStats.recordReading(
                novel: existingNovel,
                timestamp: openedAt,
                chapterTitle: trimmedChapterTitle,
                progress: clampedProgress,
                chapterIndex: chapterIndex,
                chapterPageIndex: chapterPageIndex,
                chapterSourceURLString: chapterSourceURLString,
                pageTextCharacterCount: pageCharacters
            )

            if !trimmedChapterTitle.isEmpty {
                categories[categoryIndex].novels[novelIndex].lastChapter = trimmedChapterTitle
            }
            categories[categoryIndex].novels[novelIndex].progress = clampedProgress
            categories[categoryIndex].novels[novelIndex].currentChapterIndex = chapterIndex
            categories[categoryIndex].novels[novelIndex].currentChapterPageIndex = chapterPageIndex
            categories[categoryIndex].novels[novelIndex].currentChapterSourceURLString = chapterSourceURLString
            categories[categoryIndex].novels[novelIndex].lastOpenedAt = openedAt
            categories[categoryIndex].novels[novelIndex].readMinutes = max(
                categories[categoryIndex].novels[novelIndex].readMinutes,
                Int((readingStats.books.first { $0.id == novelID }?.totalDurationSeconds ?? 0) / 60)
            )
        }
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

        for categoryIndex in categories.indices {
            guard let novelIndex = categories[categoryIndex].novels.firstIndex(where: { $0.id == novelID }) else {
                continue
            }

            let existingNovel = categories[categoryIndex].novels[novelIndex]
            readingStats.startReadingSession(
                novel: existingNovel,
                timestamp: openedAt,
                progress: clampedProgress,
                chapterIndex: chapterIndex,
                chapterPageIndex: chapterPageIndex,
                chapterSourceURLString: chapterSourceURLString
            )

            categories[categoryIndex].novels[novelIndex].lastOpenedAt = openedAt
            categories[categoryIndex].novels[novelIndex].progress = clampedProgress
            categories[categoryIndex].novels[novelIndex].currentChapterIndex = chapterIndex
            categories[categoryIndex].novels[novelIndex].currentChapterPageIndex = chapterPageIndex
            categories[categoryIndex].novels[novelIndex].currentChapterSourceURLString = chapterSourceURLString
        }
    }

    private func ensureCategory(named name: String) -> Int {
        if let existingIndex = categories.firstIndex(where: { $0.name == name }) {
            return existingIndex
        }

        categories.append(LibraryCategory(name: name, novels: []))
        return categories.count - 1
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

    private func removeExistingBook(sourceURLString: String?, title: String) {
        let normalizedTitle = normalized(title)
        for index in categories.indices {
            let removed = categories[index].novels.filter {
                matches($0, sourceURLString: sourceURLString, normalizedTitle: normalizedTitle)
            }
            for novel in removed {
                readingStats.rememberBook(novel, deletedAt: Date())
            }
            categories[index].novels.removeAll {
                matches($0, sourceURLString: sourceURLString, normalizedTitle: normalizedTitle)
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
        let snapshot = categories
        let url = storageURL
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await Self.persist(snapshot, to: url)
            self?.pendingSave = nil
        }
    }

    private func scheduleStatsSave() {
        pendingStatsSave?.cancel()
        let snapshot = readingStats
        let url = statsStorageURL
        pendingStatsSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await Self.persistReadingStats(snapshot, to: url)
            self?.pendingStatsSave = nil
        }
    }

    private static func persist(_ categories: [LibraryCategory], to url: URL) async {
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(categories)
                try data.write(to: url, options: [.atomic])
            } catch {
#if DEBUG
                debugLog("[LibraryStore] save failed: \(error.localizedDescription)")
#endif
            }
        }.value
    }

    private static func persistReadingStats(_ stats: ReadingStatsLedger, to url: URL) async {
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(stats)
                try data.write(to: url, options: [.atomic])
            } catch {
#if DEBUG
                debugLog("[LibraryStore] stats save failed: \(error.localizedDescription)")
#endif
            }
        }.value
    }

    private static func loadCategories(from storageURL: URL) -> [LibraryCategory]? {
        guard let data = try? Data(contentsOf: storageURL) else { return nil }
        return try? JSONDecoder().decode([LibraryCategory].self, from: data)
    }

    private static func loadReadingStats(from storageURL: URL) -> ReadingStatsLedger? {
        guard let data = try? Data(contentsOf: storageURL) else { return nil }
        return try? JSONDecoder().decode(ReadingStatsLedger.self, from: data)
    }

    private static func makeStorageURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("lingyue", isDirectory: true)
            .appendingPathComponent("LibraryStore.json")
    }

    private static func makeStatsStorageURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("lingyue", isDirectory: true)
            .appendingPathComponent("ReadingStatsStore.json")
    }
}
