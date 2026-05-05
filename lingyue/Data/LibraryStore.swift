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

@MainActor
final class LibraryStore: ObservableObject {
    nonisolated static let uncategorizedName = "无分类"

    @Published var categories: [LibraryCategory] {
        didSet {
            scheduleSave()
        }
    }

    private let storageURL: URL
    private var pendingSave: Task<Void, Never>?

    init() {
        self.storageURL = LibraryStore.makeStorageURL()

        self.categories = LibraryStore.loadCategories(from: storageURL) ?? []
    }

    func flush() async {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = categories
        let url = storageURL
        await Self.persist(snapshot, to: url)
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
        openedAt: Date = Date()
    ) {
        let clampedProgress = min(max(progress, 0), 1)
        let trimmedChapterTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        for categoryIndex in categories.indices {
            guard let novelIndex = categories[categoryIndex].novels.firstIndex(where: { $0.id == novelID }) else {
                continue
            }

            if !trimmedChapterTitle.isEmpty {
                categories[categoryIndex].novels[novelIndex].lastChapter = trimmedChapterTitle
            }
            categories[categoryIndex].novels[novelIndex].progress = clampedProgress
            categories[categoryIndex].novels[novelIndex].currentChapterIndex = chapterIndex
            categories[categoryIndex].novels[novelIndex].currentChapterPageIndex = chapterPageIndex
            categories[categoryIndex].novels[novelIndex].currentChapterSourceURLString = chapterSourceURLString
            categories[categoryIndex].novels[novelIndex].lastOpenedAt = openedAt
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
            categories[index].novels.removeAll {
                matches($0, sourceURLString: sourceURLString, normalizedTitle: normalizedTitle)
            }
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
                print("[LibraryStore] save failed: \(error.localizedDescription)")
#endif
            }
        }.value
    }

    private static func loadCategories(from storageURL: URL) -> [LibraryCategory]? {
        guard let data = try? Data(contentsOf: storageURL) else { return nil }
        return try? JSONDecoder().decode([LibraryCategory].self, from: data)
    }

    private static func makeStorageURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("lingyue", isDirectory: true)
            .appendingPathComponent("LibraryStore.json")
    }
}
