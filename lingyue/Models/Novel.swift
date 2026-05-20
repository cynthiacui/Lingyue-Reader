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
        self.currentChapterIndex = currentChapterIndex
        self.currentChapterPageIndex = currentChapterPageIndex
        self.currentChapterSourceURLString = currentChapterSourceURLString
        self.coverPalette = coverPalette
        self.coverImageURLString = coverImageURLString
        self.isFeatured = isFeatured
        self.sourceURLString = sourceURLString
        self.chapters = chapters
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
    /// itself or as a suffix, so subdomains like `m.nunucom.com` resolve too) and an optional list
    /// of `hostPatterns` (regex on the lowercased host) for source families whose mirror domains
    /// proliferate (e.g. 笔趣阁 spawns bqg82.de, qu83.cc, biq53.com, d1070b.bqg606.cc, …).
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

    private static let sources: [SourcePattern] = {
#if LINGYUE_INTERNAL
        return [
        SourcePattern(name: "笔趣阁小说", hosts: ["bqgl.cc"]),
        SourcePattern(name: "大尾笔趣阁", hosts: ["daweixs.com"]),
        SourcePattern(
            name: "笔趣阁",
            hosts: ["bq99.cc"],
            hostPatterns: [#"(?:^|\.)(?:bq|biq|qu)[a-z]*\d+\.[a-z]{2,}$"#]
        ),
        SourcePattern(name: "破万卷小说", hosts: ["powanjuan.cc"]),
        SourcePattern(name: "ESJ轻小说", hosts: ["esjzone.cc"]),
        SourcePattern(name: "思兔閱讀", hosts: ["sto9.com"]),
        SourcePattern(name: "就爱读小说", hosts: ["5dxs.net"]),
        SourcePattern(name: "UU看书", hosts: ["uuks.org"]),
        SourcePattern(name: "同人圈", hosts: ["tongrenquan.org"]),
        SourcePattern(name: "同人小说网", hosts: ["trxs.org"]),
        SourcePattern(name: "台灣小說網", hosts: ["xsw.tw"]),
        SourcePattern(name: "半夏小说", hosts: ["xbanxia.cc"]),
        SourcePattern(name: "宙斯小说", hosts: ["zhswx.com"]),
        SourcePattern(name: "黄金屋中文", hosts: ["hjwzw.com"]),
        SourcePattern(name: "努努书坊", hosts: ["nunucom.com"]),
        SourcePattern(name: "轻小说百科", hosts: ["lnovel.org"]),
        SourcePattern(name: "飘天文学网", hosts: ["piaotian8.com"]),
        SourcePattern(name: "69书吧", hosts: ["69shuba.com"]),
        SourcePattern(name: "52书库", hosts: ["52shuku.net"]),
        SourcePattern(name: "无忧书城", hosts: ["51shucheng.net"])
        ]
#else
        return []
#endif
    }()

    /// Custom URL scheme used to mark books imported from a local `.txt` file. We don't store
    /// the original file URL (which would leak sandbox paths and be tied to a single device),
    /// so a sentinel URL with the title in the path keeps each imported book's `sourceURLString`
    /// stable and unique.
    static let localPlainTextScheme = "lingyue-local-txt"
    static let localPlainTextDisplayName = "本地TXT"

    static func localPlainTextSourceURLString(forTitle title: String) -> String {
        let safeTitle = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        return "\(localPlainTextScheme)://import/\(safeTitle)"
    }

    static func displayName(for sourceURLString: String?) -> String? {
        guard let sourceURLString,
              let url = URL(string: sourceURLString) else {
            return nil
        }
        if url.scheme == localPlainTextScheme {
            return localPlainTextDisplayName
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
        // Exact host match first so e.g. bqgl.cc resolves to 笔趣阁小说 rather than getting
        // swept up by 笔趣阁's mirror regex.
        for source in sources where source.hosts.contains(normalized) {
            return source
        }
        // Subdomain (suffix) match — m.nunucom.com, www.52shuku.net, etc.
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
