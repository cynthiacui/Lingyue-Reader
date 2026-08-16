import Foundation
import SwiftUI

struct Novel: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let title: String
    let author: String
    let genre: String
    let summary: String
    var lastChapter: String
    var progress: Double
    var readMinutes: Int
    var lastOpenedAt: Date?
    var addedAt: Date?
    var currentChapterIndex: Int?
    var currentChapterPageIndex: Int?
    var currentChapterSourceURLString: String?
    let coverPalette: NovelCoverPalette
    let coverImageURLString: String?
    let isFeatured: Bool
    let sourceURLString: String?
    let chapters: [NovelChapter]

    var coverColor: Color {
        coverPalette.color
    }

    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        genre: String,
        summary: String,
        lastChapter: String,
        progress: Double,
        readMinutes: Int,
        lastOpenedAt: Date? = nil,
        addedAt: Date? = nil,
        currentChapterIndex: Int? = nil,
        currentChapterPageIndex: Int? = nil,
        currentChapterSourceURLString: String? = nil,
        coverPalette: NovelCoverPalette,
        coverImageURLString: String? = nil,
        isFeatured: Bool,
        sourceURLString: String? = nil,
        chapters: [NovelChapter] = []
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.genre = genre
        self.summary = summary
        self.lastChapter = lastChapter
        self.progress = progress
        self.readMinutes = readMinutes
        self.lastOpenedAt = lastOpenedAt
        self.addedAt = addedAt
        self.currentChapterIndex = currentChapterIndex
        self.currentChapterPageIndex = currentChapterPageIndex
        self.currentChapterSourceURLString = currentChapterSourceURLString
        self.coverPalette = coverPalette
        self.coverImageURLString = coverImageURLString
        self.isFeatured = isFeatured
        self.sourceURLString = sourceURLString
        self.chapters = chapters
    }

    /// Date used by the library's most-recent-first sort. Picks the
    /// latest of `lastOpenedAt` (user actually read the book) and
    /// `addedAt` (user just imported it). A freshly imported book
    /// floats to the top of its category until something more recent
    /// happens; opening a different book later naturally outranks both.
    /// The "继续阅读" hero card stays keyed strictly on `lastOpenedAt`
    /// so importing never claims that card.
    var librarySortRank: Date {
        switch (lastOpenedAt, addedAt) {
        case let (l?, a?): return max(l, a)
        case let (l?, nil): return l
        case let (nil, a?): return a
        case (nil, nil):   return .distantPast
        }
    }

    /// Shared recent-first ordering for every library surface. Keeping this rule on
    /// the model prevents search, expanded categories, and drag previews from slowly
    /// drifting into subtly different orders as each screen evolves.
    func isOrderedBeforeInLibrary(_ other: Novel) -> Bool {
        if librarySortRank != other.librarySortRank {
            return librarySortRank > other.librarySortRank
        }
        return readMinutes > other.readMinutes
    }
}

extension Collection where Element == Novel {
    /// Returns only the books needed by the collapsed category shelf. The result is
    /// ordered like a full library sort, but keeping a fixed-size insertion buffer
    /// makes the work linear in the number of books instead of sorting every book
    /// whenever drag state causes the shelf to refresh.
    func libraryPreviewNovels(limit: Int) -> [Novel] {
        guard limit > 0 else { return [] }

        var result: [Novel] = []
        result.reserveCapacity(limit)

        for novel in self {
            let insertionIndex = result.firstIndex { existing in
                novel.isOrderedBeforeInLibrary(existing)
            } ?? result.endIndex

            guard insertionIndex < limit else { continue }
            result.insert(novel, at: insertionIndex)
            if result.count > limit {
                result.removeLast()
            }
        }
        return result
    }
}

enum NovelCoverPalette: String, Codable, CaseIterable, Sendable {
    case indigo
    case teal
    case rose
    case blue
    case amber
    case forest
    case slate
    case plum

    var color: Color {
        switch self {
        case .indigo:
            return .readerIndigo
        case .teal:
            return .readerTeal
        case .rose:
            return .readerRose
        case .blue:
            return .readerBlue
        case .amber:
            return .readerAmber
        case .forest:
            return .readerAccent
        case .slate:
            return Color(red: 0.36, green: 0.39, blue: 0.42)
        case .plum:
            return Color(red: 0.44, green: 0.31, blue: 0.48)
        }
    }

    static func deterministic(for text: String) -> NovelCoverPalette {
        let palettes = NovelCoverPalette.allCases
        let value = text.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }
        return palettes[value % palettes.count]
    }
}

struct NovelChapter: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let title: String
    let content: String
    let sourceURLString: String?

    init(id: UUID = UUID(), title: String, content: String, sourceURLString: String? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.sourceURLString = sourceURLString
    }
}

enum ChineseTextConverter {
    static func display(_ text: String, usesTraditionalChinese: Bool) -> String {
        usesTraditionalChinese ? traditional(text) : simplified(text)
    }

    static func simplified(_ text: String) -> String {
        convert(text, transformIDs: ["Traditional-Simplified", "Any-Hans"])
    }

    static func traditional(_ text: String) -> String {
        convert(text, transformIDs: ["Simplified-Traditional", "Any-Hant", "Hans-Hant"])
    }

    private static func convert(_ text: String, transformIDs: [String]) -> String {
        for transformID in transformIDs {
            let mutableText = NSMutableString(string: text)
            if CFStringTransform(mutableText, nil, transformID as CFString, false) {
                return mutableText as String
            }
        }

        return text
    }
}

enum BookSourceRegistry {
    /// Each source is identified by a display `name` plus a list of `hosts` (matched as the host
    /// itself or as a suffix, so subdomains resolve too) and an optional list of `hostPatterns`
    /// (regex on the lowercased host) for source families whose mirror domains proliferate.
    /// Add a new source by appending one entry — no other code changes needed.
    private struct SourcePattern {
        let name: String
        let hosts: [String]
        let hostPatterns: [String]

        init(name: String, hosts: [String], hostPatterns: [String] = []) {
            self.name = name
            self.hosts = hosts
            self.hostPatterns = hostPatterns
        }
    }

    private static let sources: [SourcePattern] = []

    /// Custom URL schemes used to mark books imported from local files. We don't store
    /// the original file URL (which would leak sandbox paths and be tied to a single device),
    /// so a sentinel URL with the title in the path keeps each imported book's `sourceURLString`
    /// stable and unique. Three sibling schemes track the source format so the library can
    /// surface "本地TXT / EPUB / HTML" without re-sniffing the chapter content.
    static let localPlainTextScheme = "lingyue-local-txt"
    static let localPlainTextDisplayName = "本地TXT"
    static let localEPUBScheme = "lingyue-local-epub"
    static let localEPUBDisplayName = "本地EPUB"
    static let localHTMLScheme = "lingyue-local-html"
    static let localHTMLDisplayName = "本地HTML"

    static func localPlainTextSourceURLString(forTitle title: String) -> String {
        localSourceURLString(scheme: localPlainTextScheme, title: title)
    }

    static func localEPUBSourceURLString(forTitle title: String) -> String {
        localSourceURLString(scheme: localEPUBScheme, title: title)
    }

    static func localHTMLSourceURLString(forTitle title: String) -> String {
        localSourceURLString(scheme: localHTMLScheme, title: title)
    }

    private static func localSourceURLString(scheme: String, title: String) -> String {
        let safeTitle = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        return "\(scheme)://import/\(safeTitle)"
    }

    static func displayName(for sourceURLString: String?) -> String? {
        guard let sourceURLString,
              let url = URL(string: sourceURLString) else {
            return nil
        }
        switch url.scheme {
        case localPlainTextScheme: return localPlainTextDisplayName
        case localEPUBScheme: return localEPUBDisplayName
        case localHTMLScheme: return localHTMLDisplayName
        default: break
        }
        guard let host = url.host(percentEncoded: false) else {
            return nil
        }
        return displayName(forHost: host)
    }

    static func displayName(forHost host: String) -> String? {
        if let name = matchedSource(forHost: host)?.name {
            return name
        }
        return matchedRuleName(forHost: normalize(host))
    }

    static func isKnownHost(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false) else { return false }
        if matchedSource(forHost: host) != nil { return true }
        return matchedRuleName(forHost: normalize(host)) != nil
    }

    /// User-rule cache. The legacy hardcoded `sources` list is empty in the App Store
    /// build (Phase 5 gates it), so a book imported via a user-authored `SourceRule`
    /// would otherwise have no displayable source name. We mirror each rule's
    /// `name` + `detection.hostPatterns` into this cache at launch and on every
    /// rule mutation, so cards and the reader header can resolve names sync.
    private static let ruleCacheLock = NSLock()
    private static var ruleEntries: [RuleEntry] = []

    struct RuleEntry: Sendable {
        let pattern: String
        let name: String
    }

    static func registerRuleDisplayNames(_ entries: [RuleEntry]) {
        ruleCacheLock.lock()
        ruleEntries = entries
        ruleCacheLock.unlock()
    }

    private static func matchedRuleName(forHost normalizedHost: String) -> String? {
        ruleCacheLock.lock()
        let snapshot = ruleEntries
        ruleCacheLock.unlock()
        for entry in snapshot
        where hostMatches(host: normalizedHost, pattern: entry.pattern.lowercased()) {
            return entry.name
        }
        return nil
    }

    /// Mirrors the glob semantics used by the rule engine (`JSONAPIBookSource.hostMatches`):
    /// plain patterns match exact host or subdomain suffix; `*` wildcards may appear anywhere.
    /// Strips a leading `www.` from plain patterns so users entering `www.example.com` and
    /// `example.com` both resolve subdomains symmetrically.
    private static func hostMatches(host: String, pattern: String) -> Bool {
        if !pattern.contains("*") {
            let cleaned = pattern.hasPrefix("www.") ? String(pattern.dropFirst(4)) : pattern
            return host == cleaned || host.hasSuffix(".\(cleaned)")
        }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var searchStart = host.startIndex
        for (i, fragment) in parts.enumerated() where !fragment.isEmpty {
            let isPrefix = (i == 0 && !pattern.hasPrefix("*"))
            let isSuffix = (i == parts.count - 1 && !pattern.hasSuffix("*"))
            guard let range = host.range(of: fragment, range: searchStart..<host.endIndex) else {
                return false
            }
            if isPrefix && range.lowerBound != host.startIndex { return false }
            if isSuffix && range.upperBound != host.endIndex { return false }
            searchStart = range.upperBound
        }
        return true
    }

    private static func matchedSource(forHost host: String) -> SourcePattern? {
        let normalized = normalize(host)
        // Exact host match first so a specific host resolves to its own
        // entry rather than getting swept up by a mirror-family regex.
        for source in sources where source.hosts.contains(normalized) {
            return source
        }
        // Subdomain (suffix) match — handles m.<host>, www.<host>, etc.
        for source in sources where source.hosts.contains(where: { normalized.hasSuffix(".\($0)") }) {
            return source
        }
        // Regex patterns for proliferating mirror families.
        for source in sources {
            for pattern in source.hostPatterns
            where normalized.range(of: pattern, options: .regularExpression) != nil {
                return source
            }
        }
        return nil
    }

    private static func normalize(_ host: String) -> String {
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }
}

struct NovelCategory: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let symbol: String
    let count: Int
}

enum ReadingTheme: String, CaseIterable, Identifiable {
    case paper = "纸张"
    case warm = "米黄"
    case mint = "护眼"
    case sky = "雅蓝"
    case night = "夜读"

    var id: String { rawValue }
}
