import Foundation
import os
import LingyueCore

struct WebBookCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let author: String
    let summary: String
    let coverImageURLString: String?
    let sourceURL: URL
    let detectedChapterCount: Int
    let htmlSnapshot: String

    init(
        title: String,
        author: String,
        summary: String,
        coverImageURLString: String?,
        sourceURL: URL,
        detectedChapterCount: Int,
        htmlSnapshot: String
    ) {
        self.id = sourceURL.absoluteString
        self.title = title
        self.author = author
        self.summary = summary
        self.coverImageURLString = coverImageURLString
        self.sourceURL = sourceURL
        self.detectedChapterCount = detectedChapterCount
        self.htmlSnapshot = htmlSnapshot
    }

    static func == (lhs: WebBookCandidate, rhs: WebBookCandidate) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func replacingHTMLSnapshot(_ htmlSnapshot: String, detectedChapterCount: Int? = nil) -> WebBookCandidate {
        WebBookCandidate(
            title: title,
            author: author,
            summary: summary,
            coverImageURLString: coverImageURLString,
            sourceURL: sourceURL,
            detectedChapterCount: detectedChapterCount ?? self.detectedChapterCount,
            htmlSnapshot: htmlSnapshot
        )
    }
}

enum WebBookImportError: LocalizedError {
    case noBookDetected
    case noChaptersFound
    case emptyChapterContent
    case sourceBlockedContent
    case badStatus(Int)
    case unsupportedEncoding
    case unreadableFile
    case suspiciousChapterCatalog(count: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .noBookDetected:
            return "没有在当前网页识别到可导入的书籍。"
        case .noChaptersFound:
            return "找到了书籍信息，但没有识别到章节目录。"
        case .emptyChapterContent:
            return "章节页面可以打开，但没有解析到正文内容。"
        case .sourceBlockedContent:
            return "该来源限制章节正文显示，请尝试其他来源。"
        case .badStatus(let statusCode):
            return "网页请求失败，状态码 \(statusCode)。"
        case .unsupportedEncoding:
            return "无法识别文件编码，仅支持 UTF-8 或 GB18030 的 .txt 文件。"
        case .unreadableFile:
            return "无法读取所选文件，请重新选择。"
        case .suspiciousChapterCatalog(let count, let limit):
            return "识别到 \(count) 个章节链接，超过安全上限 \(limit)。这可能是网页解析异常，请尝试从书籍目录页重新导入。"
        }
    }
}

final class BookImportService: Sendable {
    static let shared = BookImportService()

    /// Sentinel content stored in the chapter cache for chapters whose source permanently
    /// refuses to serve the body (e.g. 努努书坊 paywalls its newest chapters with a
    /// "请下载努努书坊APP" gate). Distinct from a transient network error: retrying these
    /// against the same source won't help, so we persist the marker and treat the chapter
    /// as "accounted for" in download progress while still surfacing the original
    /// `sourceBlockedContent` error to the reader.
    static let sourceBlockedContentSentinel = "__lingyue.source_blocked__\n"

    static func isSourceBlockedSentinelContent(_ content: String) -> Bool {
        content.hasPrefix(sourceBlockedContentSentinel)
    }

    /// Safety fuse for parser runaways, not a normal product cap. Legitimately long web novels
    /// should import all chapters below this high ceiling; hitting it means the extractor likely
    /// matched navigation/archive links as chapters.
    private let runawayChapterLimit = 20_000
    private let biqugeAPIHosts = ["apiqu.cc", "apige.cc"]
    private let catalogRepairCache = OSAllocatedUnfairLock<[UUID: Bool]>(initialState: [:])
    private let httpSession: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        self.httpSession = URLSession(
            configuration: configuration,
            delegate: HTTPSUpgradingRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func detectBook(html: String, url: URL, pageTitle: String?) -> WebBookCandidate? {
        let metadata = parseMetadata(html: html, url: url, fallbackTitle: pageTitle)
        let chapterLinks = extractChapterLinks(from: html, baseURL: url)
        let title = metadata.title

        guard isLikelyBookPage(title: title, author: metadata.author, url: url, chapterCount: chapterLinks.count, html: html) else {
#if DEBUG
            debugLog("[BookImport] reject \(url.absoluteString) — title=\"\(title)\" author=\"\(metadata.author)\" chapters=\(chapterLinks.count) htmlBytes=\(html.count)")
#endif
            return nil
        }

#if DEBUG
        debugLog("[BookImport] accept \(url.absoluteString) — title=\"\(title)\" author=\"\(metadata.author)\" chapters=\(chapterLinks.count)")
#endif

        return WebBookCandidate(
            title: title,
            author: metadata.author.isEmpty ? "未知作者" : metadata.author,
            summary: metadata.summary,
            coverImageURLString: metadata.coverImageURL?.absoluteString,
            sourceURL: url,
            detectedChapterCount: chapterLinks.count,
            htmlSnapshot: html
        )
    }

    func importBook(from candidate: WebBookCandidate) async throws -> Novel {
        let snapshotHTML = candidate.htmlSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookHTML = snapshotHTML.isEmpty
            ? try await fetchHTML(from: candidate.sourceURL)
            : candidate.htmlSnapshot
        let metadata = parseMetadata(html: bookHTML, url: candidate.sourceURL, fallbackTitle: candidate.title)
        let title = metadata.title.isEmpty ? candidate.title : metadata.title
        let author = metadata.author.isEmpty ? candidate.author : metadata.author
        let summary = metadata.summary.isEmpty ? candidate.summary : metadata.summary
        let coverURLString = metadata.coverImageURL?.absoluteString ?? candidate.coverImageURLString

        let discoveredChapterLinks = try await bestChapterLinks(from: bookHTML, sourceURL: candidate.sourceURL)
        let chapterLinks = try checkedChapterLinks(discoveredChapterLinks)
        guard !chapterLinks.isEmpty else { throw WebBookImportError.noChaptersFound }

        let chapters = chapterLinks.map {
            NovelChapter(
                title: $0.title,
                content: "",
                sourceURLString: $0.url.absoluteString
            )
        }

        return Novel(
            title: title,
            author: author.isEmpty ? "未知作者" : author,
            genre: "无分类",
            summary: summary,
            lastChapter: chapters.first?.title ?? "已加入 \(chapters.count) 章目录",
            progress: 0,
            readMinutes: 0,
            coverPalette: .deterministic(for: title),
            coverImageURLString: coverURLString,
            isFeatured: false,
            sourceURLString: candidate.sourceURL.absoluteString,
            chapters: chapters
        )
    }

    private func checkedChapterLinks(_ links: [ChapterLink]) throws -> [ChapterLink] {
        guard links.count <= runawayChapterLimit else {
            throw WebBookImportError.suspiciousChapterCatalog(
                count: links.count,
                limit: runawayChapterLimit
            )
        }
        return links
    }

    func importBook(from sourceURL: URL, fallbackTitle: String?) async throws -> Novel {
        let html = try await fetchHTML(from: sourceURL)
        guard let candidate = detectBook(html: html, url: sourceURL, pageTitle: fallbackTitle) else {
            throw WebBookImportError.noBookDetected
        }

        return try await importBook(from: candidate)
    }

    /// Imports a local `.txt` file as a Novel. Splits chapters using the same
    /// "第N章" heuristic the web extractor uses; falls back to a single chapter
    /// when the file has no recognizable chapter headings.
    func importBook(fromPlainTextFile url: URL) throws -> Novel {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WebBookImportError.unreadableFile
        }

        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let gb = String(data: data, encoding: .gb_18030_2000) {
            text = gb
        } else if let big5 = String(data: data, encoding: .big5Chinese) {
            text = big5
        } else {
            throw WebBookImportError.unsupportedEncoding
        }

        let rawTitle = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty ? "未命名" : rawTitle

        let chapters = splitPlainTextIntoChapters(text, fallbackTitle: title)

        return Novel(
            title: title,
            author: "未知作者",
            genre: LibraryStore.uncategorizedName,
            summary: "",
            lastChapter: chapters.first?.title ?? "",
            progress: 0,
            readMinutes: 0,
            coverPalette: .deterministic(for: title),
            isFeatured: false,
            sourceURLString: BookSourceRegistry.localPlainTextSourceURLString(forTitle: title),
            chapters: chapters
        )
    }

    private func splitPlainTextIntoChapters(_ text: String, fallbackTitle: String) -> [NovelChapter] {
        let chapterMarker = #"^第\s*[\d一二三四五六七八九十百千万零〇两]+\s*[章节節回卷页頁]"#

        let lines = text.components(separatedBy: .newlines)

        var chapters: [NovelChapter] = []
        var currentTitle: String?
        var currentBuffer: [String] = []

        func flush() {
            guard let title = currentTitle else { return }
            let body = currentBuffer
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(NovelChapter(title: title, content: body))
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               trimmed.range(of: chapterMarker, options: .regularExpression) != nil {
                flush()
                currentTitle = trimmed
                currentBuffer = []
            } else if currentTitle != nil {
                currentBuffer.append(rawLine)
            }
        }
        flush()

        if chapters.isEmpty {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return [NovelChapter(title: fallbackTitle, content: body)]
        }

        return chapters
    }

    func likelyCatalogURLs(for candidate: WebBookCandidate) -> [URL] {
        let sourceBookID = authoritativeBookID(in: candidate.htmlSnapshot, url: candidate.sourceURL)
        return findCatalogURLs(in: candidate.htmlSnapshot, baseURL: candidate.sourceURL, sourceBookID: sourceBookID)
            .filter { $0 != candidate.sourceURL }
    }

    func detectedChapterCount(in html: String, baseURL: URL) -> Int {
        extractChapterLinks(from: html, baseURL: baseURL).count
    }

    func catalogNeedsRepair(for novel: Novel) -> Bool {
        if let cached = catalogRepairCache.withLock({ $0[novel.id] }) {
            return cached
        }

        let result = computeCatalogNeedsRepair(for: novel)
        catalogRepairCache.withLock { $0[novel.id] = result }
        return result
    }

    private func computeCatalogNeedsRepair(for novel: Novel) -> Bool {
        guard let sourceURLString = novel.sourceURLString,
              let sourceURL = URL(string: sourceURLString),
              let sourceBookID = bookID(from: sourceURL) else {
            return false
        }

        let chapterBookIDs = novel.chapters.compactMap { chapter in
            chapter.sourceURLString
                .flatMap(URL.init(string:))
                .flatMap(bookID)
        }
        guard !chapterBookIDs.isEmpty else { return false }

        let matchingCount = chapterBookIDs.filter { $0 == sourceBookID }.count
        if matchingCount < max(1, chapterBookIDs.count / 2) {
            return true
        }

        if isHJWZWHost(sourceURL),
           novel.chapters.count >= 10,
           let firstChapterNumber = novel.chapters.first.flatMap({ chapterNumber(from: $0.title) }),
           firstChapterNumber > 50 {
            return true
        }

        return false
    }

    func loadChapter(_ chapter: NovelChapter) async throws -> NovelChapter {
        guard chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return chapter
        }

        guard let sourceURLString = chapter.sourceURLString,
              let url = URL(string: sourceURLString) else {
            throw WebBookImportError.emptyChapterContent
        }

        guard let loadedChapter = try await fetchChapter(ChapterLink(title: chapter.title, url: url)) else {
            throw WebBookImportError.emptyChapterContent
        }

        return NovelChapter(
            id: chapter.id,
            title: loadedChapter.title,
            content: loadedChapter.content,
            sourceURLString: sourceURLString
        )
    }

    func shouldUseCachedChapter(_ cachedChapter: NovelChapter, for originalChapter: NovelChapter) -> Bool {
        // Source-blocked sentinels are valid cache entries — they record "this source
        // permanently refuses to serve this chapter" so we don't keep re-fetching it.
        // The throw-on-read happens in `ChapterContentCache.chapter(for:)`.
        if Self.isSourceBlockedSentinelContent(cachedChapter.content) {
            return true
        }
        // Reject cached chapters whose title is a site-brand (e.g. "努努书坊", "笔趣阁") rather
        // than a real chapter name. These were produced by the old <h1>-grabs-first bug; force
        // a re-fetch so the new title parser can pick the right heading.
        if isSiteBrandTitle(cachedChapter.title) {
            return false
        }
        // Reject cached chapters whose body begins with a breadcrumb signature — indicates the
        // old extractor matched a page-level wrapper (e.g. 52书库's `<div class="content-wrap">`)
        // instead of the real chapter container.
        if startsWithBreadcrumb(cachedChapter.content) {
            return false
        }

        guard let sourceURLString = originalChapter.sourceURLString,
              let sourceURL = URL(string: sourceURLString),
              isBiqugeAPISource(sourceURL) else {
            return true
        }

        let content = cachedChapter.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count >= 30 else { return false }

        let leakedShellFragments = [
            "笔趣阁\n\n字体", "筆趣閣\n\n字體",
            "字体：", "字體：",
            "我的书架", "我的書架",
            "联系我们", "聯繫我們"
        ]
        let shellHitCount = leakedShellFragments.filter { content.contains($0) }.count
        return shellHitCount < 2
    }

    private func startsWithBreadcrumb(_ content: String) -> Bool {
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let firstChunk = lines.prefix(5).joined(separator: " ")
        let breadcrumbSignals = [
            "52书库 >", "52書庫 >", "半夏小说 >", "半夏小說 >",
            "笔趣阁 >", "筆趣閣 >", "宙斯小说网 >", "宙斯小說網 >",
            "同人圈 >", "同人小说网 >", "破万卷 >",
            "首页 >", "首頁 >"
        ]
        if breadcrumbSignals.contains(where: { firstChunk.contains($0) }) { return true }

        // Detect a nav-menu-style body (the old 宙斯小说 bug captured the menubar — many
        // short single-token lines like 最新入库 / 宙斯小说网 / 繁体版 / 都市 / 言情 / 仙侠).
        // If the cached body opens with several very short lines AND the total is small, it's
        // almost certainly menu cruft, not a chapter.
        if !lines.isEmpty {
            let head = lines.prefix(8)
            let shortHeadCount = head.filter { $0.count <= 8 }.count
            let cleanedTotal = lines.joined(separator: "").count
            if shortHeadCount >= 5 && cleanedTotal < 400 { return true }
        }

        let menuSignatures = [
            "宙斯小说网", "宙斯小說網", "最新入库", "最新入庫", "繁體版", "繁体版",
            "玄幻列表", "都市言情列表"
        ]
        if menuSignatures.contains(where: { firstChunk.contains($0) }) { return true }

        return false
    }

    private func isSiteBrandTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 12 else { return false }
        // Real chapter titles always carry a 第N章/节/页/回/卷 marker — if there's one, never reject.
        if trimmed.range(of: #"第\s*[\d一二三四五六七八九十百千万零〇两]+\s*[章节節回卷页頁]"#, options: .regularExpression) != nil {
            return false
        }
        let brandMarkers = [
            "书坊", "書坊", "书库", "書庫", "书城", "書城",
            "书网", "書網", "小说网", "小說網", "文学", "文學",
            "阁", "閣", "书屋", "書屋", "书院", "書院"
        ]
        return brandMarkers.contains(where: { trimmed.contains($0) })
    }

    private struct BookMetadata {
        let title: String
        let author: String
        let summary: String
        let coverImageURL: URL?
    }

    private struct ChapterLink: Hashable {
        let title: String
        let url: URL
    }

    private struct BiqugeBookListResponse: Decodable {
        let list: [String]
    }

    private struct BiqugeChapterResponse: Decodable {
        let title: String?
        let author: String?
        let chaptername: String?
        let txt: String?
    }

    private struct FivedxsCatalogResponse: Decodable {
        let items: [Item]?

        struct Item: Decodable {
            let chaptername: String
            let url: String
        }
    }

    private func parseMetadata(html: String, url: URL, fallbackTitle: String?) -> BookMetadata {
        let title = cleanBookTitle(
            metaContent(named: "og:novel:book_name", in: html)
                ?? metaContent(named: "book_name", in: html)
                ?? firstMatch(#"articlename\s*:\s*['"]([^'"]+)['"]"#, in: html)
                ?? sourceSpecificBookTitle(in: html, url: url)
                ?? firstMatch(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
                ?? firstMatch(#"<h2[^>]*class=["'][^"']*(?:book|title|name)[^"']*["'][^>]*>([\s\S]*?)</h2>"#, in: html)
                ?? firstMatch(#"<dt[^>]*class=["'][^"']*\btitle\b[^"']*["'][^>]*>([\s\S]*?)</dt>"#, in: html)
                ?? firstMatch(#""title"\s*:\s*"([^"]+)""#, in: html)
                ?? metaContent(named: "og:title", in: html)
                ?? fallbackTitle
                ?? ""
        )

        let author = cleanText(
            metaContent(named: "og:novel:author", in: html)
                ?? metaContent(named: "author", in: html)
                ?? firstMatch(#"author\s*:\s*['"]([^'"]+)['"]"#, in: html)
                ?? firstMatch(#"作者[：:]\s*<a[^>]*>([\s\S]*?)</a>"#, in: html)
                ?? firstMatch(#"作者[：:]\s*</span>\s*<[^>]+>([\s\S]*?)</"#, in: html)
                ?? firstMatch(#"作者[：:]\s*([^<\n\r]{1,40})"#, in: html)
                ?? ""
        )

        let summary = cleanText(
            metaContent(named: "og:description", in: html)
                ?? metaContent(named: "description", in: html)
                ?? firstMatch(#"<div[^>]*(?:id|class)=["'][^"']*(?:intro|desc|summary|bookintro)[^"']*["'][^>]*>([\s\S]*?)</div>"#, in: html)
                ?? ""
        )

        // 半夏小说 also stashes the full-resolution cover in the lazy <img>'s data-original
        // attribute (its src is a "no cover" placeholder). Try og:image first, then any img
        // with a book-cover-ish class — preferring data-original over src — before falling
        // back to the alt-attribute pattern that just gives us the title.
        let cover = metaContent(named: "og:image", in: html)
            ?? firstMatch(#"<img[^>]+(?:id|class)=["'][^"']*(?:cover|bookimg|image|book-img)[^"']*["'][^>]+data-original=["']([^"']+)["']"#, in: html)
            ?? firstMatch(#"<img[^>]+data-original=["']([^"']+)["'][^>]+(?:id|class)=["'][^"']*(?:cover|bookimg|image|book-img)[^"']*["']"#, in: html)
            ?? firstMatch(#"<div[^>]+class=["'][^"']*book-img[^"']*["'][^>]*>\s*<img[^>]+data-original=["']([^"']+)["']"#, in: html)
            ?? firstMatch(#"<div[^>]+class=["'][^"']*book-img[^"']*["'][^>]*>\s*<img[^>]+src=["']([^"']+)["']"#, in: html)
            ?? firstMatch(#"<img[^>]+(?:id|class)=["'][^"']*(?:cover|bookimg|image)[^"']*["'][^>]+src=["']([^"']+)["']"#, in: html)
            ?? firstMatch(#"<img[^>]+src=["']([^"']+)["'][^>]+(?:id|class)=["'][^"']*(?:cover|bookimg|image)[^"']*["']"#, in: html)

        return BookMetadata(
            title: title,
            author: author,
            summary: summary,
            coverImageURL: cover.flatMap { absoluteURL(from: $0, baseURL: url) }.map(httpsUpgraded)
        )
    }

    /// App Transport Security blocks plain http loads for URLSession (and therefore SwiftUI's
    /// AsyncImage), even though our WKWebView is allowed via NSAllowsArbitraryLoadsInWebContent.
    /// Some sources (e.g. 半夏小说) advertise their og:image as an http URL even though https
    /// works fine — upgrade so the cover actually loads.
    private func httpsUpgraded(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    private func sourceSpecificBookTitle(in html: String, url: URL) -> String? {
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        let isCatalogSource = host.contains("bqg")
            || host.contains("biqu")
            || host.contains("banxia")
            || host.contains("xbanxia")
            || host.contains("zhswx")
            || host.contains("hjwzw")
        guard isCatalogSource || BookSourceRegistry.isKnownHost(url) else { return nil }

        if host.contains("hjwzw") {
            let breadcrumbBookLink = #"<a[^>]+href=["'][^"']*/Book/\d+/?["'][^>]*>([^<]{2,100})</a>\s*(?:&nbsp;|\s|　)*>>"#
            if let title = firstMatch(breadcrumbBookLink, in: html).map(cleanBookTitle),
               isSpecificBookTitle(title) {
                return title
            }
        }

        let patterns = [
            // 半夏小说 wraps the book name in <h1> inside <div class="book-describe">. Other
            // sites use similar info containers; this pattern grabs the first h1/h2 that lives
            // directly inside one of those containers, which steers around site-logo <h1>s.
            #"<(?:div|section|article)[^>]+class=["'][^"']*(?:book-describe|book-detail|book-info|book-msg|bookbox|book-data)[^"']*["'][^>]*>\s*(?:<[^>]+>\s*)*?<(?:h1|h2|h3)[^>]*>\s*([^<]{2,100})\s*</(?:h1|h2|h3)>"#,
            #"<(?:h1|h2|h3|div|span|p)[^>]*(?:class|id)=["'][^"']*(?:bookname|book-name|booktitle|book-title|info-title|detail-title|novel-title|title)[^"']*["'][^>]*>([\s\S]{1,180}?)</(?:h1|h2|h3|div|span|p)>"#,
            #"<img[^>]+(?:class|id)=["'][^"']*(?:cover|bookimg|image|pic)[^"']*["'][^>]+alt=["']([^"']{1,100})["']"#,
            #"<img[^>]+alt=["']([^"']{1,100})["'][^>]+(?:class|id)=["'][^"']*(?:cover|bookimg|image|pic)[^"']*["']"#,
            #"<(?:h1|h2|h3|div|span|p)[^>]*>\s*([^<>]{1,100})\s*</(?:h1|h2|h3|div|span|p)>\s*[\s\S]{0,700}?作者[：:]"#
        ]

        for pattern in patterns {
            for match in matches(pattern, in: html) {
                let candidate = cleanBookTitle(firstMatch(pattern, in: match) ?? match)
                if isSpecificBookTitle(candidate) {
                    return candidate
                }
            }
        }

        return nil
    }

    private func isSpecificBookTitle(_ title: String) -> Bool {
        guard title.count >= 2, title.count <= 80 else { return false }
        let lowered = title.lowercased()
        let genericParts = [
            "笔趣阁", "筆趣閣", "免费阅读", "免費閱讀", "小说网", "小說網",
            "书库", "書庫", "首页", "首頁", "目录", "目錄", "搜索", "排行",
            "内容简介", "內容簡介", "简介", "簡介", "加入书架", "加入書架",
            "开始阅读", "開始閱讀",
            // Site brand names that occasionally land in logo <h1>s.
            "半夏小说", "半夏小說", "努努书坊", "努努書坊", "宙斯小说", "宙斯小說",
            "破万卷", "破萬卷", "黄金屋中文", "黃金屋中文", "52书库", "52書庫",
            "思兔阅读", "思兔閱讀", "台湾小说网", "臺灣小說網",
            "當前位置", "当前位置"
        ]
        if genericParts.contains(where: { lowered.contains($0.lowercased()) }) {
            return false
        }
        return true
    }

    private func isLikelyBookPage(title: String, author: String, url: URL, chapterCount: Int, html: String) -> Bool {
        guard !title.isEmpty, title.count <= 80 else { return false }

        let loweredTitle = title.lowercased()
        let blockedTitleParts = [
            "搜索", "登录", "注册", "首页", "排行榜", "书库", "目录大全",
            "google", "microsoft", "spotify", "笔趣阁", "筆趣閣"
        ]
        if blockedTitleParts.contains(where: { loweredTitle.contains($0.lowercased()) }) {
            return false
        }

        let loweredHTML = html.lowercased()
        guard chapterCount > 0 || loweredHTML.contains("ajax_novels/chapterlist") else {
            return false
        }

        let rawPath = url.path.lowercased()
        let rawFragment = url.fragment(percentEncoded: false)?.lowercased() ?? ""
        let path: String
        if (rawPath.isEmpty || rawPath == "/"), !rawFragment.isEmpty {
            path = rawFragment.hasPrefix("/") ? rawFragment : "/" + rawFragment
        } else {
            path = rawPath
        }

        let blockedPathFragments = ["search", "/so/", "/login", "/register", "/signup", "/category", "/tag/", "/zuozhe", "/rank", "/top/"]
        if path == "/" || path.isEmpty || blockedPathFragments.contains(where: { path.contains($0) }) {
            return false
        }
        if isHJWZWHost(url), !isHJWZWImportableBookPath(path) {
            return false
        }

        let hasNovelMeta = loweredHTML.contains("og:novel")
            || loweredHTML.contains("book_name")
            || loweredHTML.contains("articlelist")
            || loweredHTML.range(of: #"og:type[^>]*content\s*=\s*["']?\s*(novel|book)"#, options: .regularExpression) != nil
        let hasAuthor = !author.isEmpty || loweredHTML.contains("作者")
        let hasReaderActions = loweredHTML.contains("加入书架")
            || loweredHTML.contains("加入書架")
            || loweredHTML.contains("开始阅读")
            || loweredHTML.contains("開始閱讀")
            || loweredHTML.contains("立即阅读")
            || loweredHTML.contains("立即閱讀")
        let hasBookLikePath = path.range(
            of: #"^/(book|novel|info|read|story|look|kanshu|files)/\d+(/(index\.html?)?)?$"#,
            options: .regularExpression
        ) != nil
        let isKnownSourceHost = BookSourceRegistry.isKnownHost(url)

        return hasNovelMeta
            || (hasAuthor && chapterCount >= 1)
            || chapterCount >= 3
            || (hasAuthor && hasReaderActions)
            || (hasBookLikePath && hasAuthor)
            || (isKnownSourceHost && chapterCount >= 1)
    }

    private func isHJWZWHost(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return host == "hjwzw.com" || host.hasSuffix(".hjwzw.com")
    }

    private func isHJWZWImportableBookPath(_ path: String) -> Bool {
        path.range(of: #"^/book/\d+/?$"#, options: [.regularExpression, .caseInsensitive]) != nil
            || path.range(of: #"^/book/chapter/\d+/?$"#, options: [.regularExpression, .caseInsensitive]) != nil
            || path.range(of: #"^/book/read/\d+,\d+/?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func bestChapterLinks(from html: String, sourceURL: URL) async throws -> [ChapterLink] {
        let sourceBookID = authoritativeBookID(in: html, url: sourceURL)
        let primaryLinks = await chapterLinksAcrossPagination(
            startingHTML: html,
            startingURL: sourceURL,
            sourceBookID: sourceBookID
        )

        // Always fetch the canonical server HTML in parallel and treat it as another candidate.
        // WKWebView's outerHTML can serialize attributes differently or omit late-rendered DOM
        // (e.g. 破万卷小说 sometimes returns a snapshot missing the chapter list). The candidate
        // with the most chapters wins via chapterListScore below.
        var candidateLists = [primaryLinks]
        var freshLinks: [ChapterLink] = []
        var freshHTMLForCatalog: String?
        if let freshHTML = try? await fetchHTML(from: sourceURL) {
            freshHTMLForCatalog = freshHTML
            freshLinks = await chapterLinksAcrossPagination(
                startingHTML: freshHTML,
                startingURL: sourceURL,
                sourceBookID: sourceBookID
            )
            if !freshLinks.isEmpty {
                candidateLists.append(freshLinks)
            }
#if DEBUG
            debugLog("[ChapterImport] URLSession canonical fetch -> \(freshLinks.count) chapters")
#endif
        }

        let apiLinks = await biqugeAPICatalogLinks(for: sourceURL, sourceBookID: sourceBookID)
        if !apiLinks.isEmpty {
            candidateLists.append(apiLinks)
        }

        let fivedxsLinks = await fivedxsCatalogLinks(for: sourceURL, sourceBookID: sourceBookID)
        if !fivedxsLinks.isEmpty {
            candidateLists.append(fivedxsLinks)
#if DEBUG
            debugLog("[ChapterImport] 5dxs ajax catalog -> \(fivedxsLinks.count) chapters")
#endif
        }

        let hjwzwLinks = await hjwzwCatalogLinks(for: sourceURL, sourceBookID: sourceBookID)
        if !hjwzwLinks.isEmpty {
            candidateLists.append(hjwzwLinks)
#if DEBUG
            debugLog("[ChapterImport] HJWZW catalog -> \(hjwzwLinks.count) chapters")
#endif
        }

        // Probe catalog URLs unless the source page already gave us a contiguous chapter list
        // starting at 第1章. For 努努书坊 / 破万卷小说 / 黄金屋中文 the book detail page lists every
        // chapter inline, so probing wastes HTTP requests. For 宙斯小说 the book detail page lists
        // only the latest 30 chapters — count is high but the list starts at 第330章, so we still
        // need /chapter/<id>.html.
        let alreadyComplete = looksContiguousFromOne(primaryLinks)
            || looksContiguousFromOne(freshLinks)
            || looksContiguousFromOne(apiLinks)
            || looksContiguousFromOne(hjwzwLinks)

#if DEBUG
        debugLog("[ChapterImport] source=\(sourceURL.absoluteString) primary=\(primaryLinks.count) fresh=\(freshLinks.count) api=\(apiLinks.count) alreadyComplete=\(alreadyComplete)")
#endif

        if !alreadyComplete {
            let catalogSourceHTML = freshHTMLForCatalog ?? html
            for catalogURL in findCatalogURLs(in: catalogSourceHTML, baseURL: sourceURL, sourceBookID: sourceBookID).prefix(8) {
                guard catalogURL != sourceURL else { continue }

                do {
                    let catalogHTML = try await fetchHTML(from: catalogURL)
                    let links = await chapterLinksAcrossPagination(
                        startingHTML: catalogHTML,
                        startingURL: catalogURL,
                        sourceBookID: sourceBookID
                    )
                    if !links.isEmpty {
                        candidateLists.append(links)
#if DEBUG
                        debugLog("[ChapterImport] catalog \(catalogURL.absoluteString) -> \(links.count) chapters")
#endif
                        // Stop probing once a catalog gives us the full sequence.
                        if looksContiguousFromOne(links) {
                            break
                        }
                    }
                } catch {
                    continue
                }
            }
        }

        return candidateLists.max { lhs, rhs in
            chapterListScore(lhs) < chapterListScore(rhs)
        } ?? []
    }

    /// True when the chapter list starts at 第1章 with at least ~90% coverage of the 1..max range.
    /// Used to decide whether the source page already has the full catalog inline.
    private func looksContiguousFromOne(_ links: [ChapterLink]) -> Bool {
        let numbers = links.compactMap { chapterNumber(from: $0.title) }
        guard numbers.count >= 5 else { return false }
        let sorted = Set(numbers).sorted()
        guard sorted.first == 1, let max = sorted.last else { return false }
        return sorted.count >= Int(Double(max) * 0.9)
    }

    /// Walks `下一页 / 下一頁 / next` links from the given catalog page, fetching each subsequent
    /// page in turn (capped at `maxCatalogPages`). All chapter links across pages are combined,
    /// deduplicated by URL, and sorted by parsed chapter number when most titles are numbered.
    private func chapterLinksAcrossPagination(
        startingHTML: String,
        startingURL: URL,
        sourceBookID: String?
    ) async -> [ChapterLink] {
        var combined = chapterLinks(from: startingHTML, baseURL: startingURL, matching: sourceBookID)
        var visited: Set<String> = [startingURL.absoluteString]
        var currentHTML = startingHTML
        var currentURL = startingURL
        var pagesWalked = 0
        let maxCatalogPages = 60

        while pagesWalked < maxCatalogPages,
              let nextURL = nextCatalogPageURL(in: currentHTML, baseURL: currentURL),
              !visited.contains(nextURL.absoluteString) {
            visited.insert(nextURL.absoluteString)
            pagesWalked += 1
            do {
                let nextHTML = try await fetchHTML(from: nextURL)
                let pageLinks = chapterLinks(from: nextHTML, baseURL: nextURL, matching: sourceBookID)
                combined.append(contentsOf: pageLinks)
                currentHTML = nextHTML
                currentURL = nextURL
            } catch {
                break
            }
        }

        return orderedAndSortedChapterLinks(combined)
    }

    private func nextCatalogPageURL(in html: String, baseURL: URL) -> URL? {
        let blocks = matches(#"<a[^>]+href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#, in: html)
        for block in blocks {
            let text = cleanText(firstMatch(#">([\s\S]*?)</a>"#, in: block) ?? "")
            let lowered = text.lowercased()
            let isNext = text.contains("下一页")
                || text.contains("下一頁")
                || text.contains("下页")
                || text.contains("下頁")
                || lowered == "next"
                || lowered == "next page"
                || lowered == "next ›"
                || lowered == "›"
            guard isNext else { continue }
            guard let href = firstMatch(#"href\s*=\s*["']([^"']+)["']"#, in: block) else { continue }
            let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.lowercased().hasPrefix("javascript:") {
                continue
            }
            if let url = absoluteURL(from: trimmed, baseURL: baseURL) {
                return url
            }
        }
        return nil
    }

    private func orderedAndSortedChapterLinks(_ links: [ChapterLink]) -> [ChapterLink] {
        let unique = deduplicated(links)
        let numberedSlice = unique.compactMap { link -> (Int, ChapterLink)? in
            guard let n = chapterNumber(from: link.title) else { return nil }
            return (n, link)
        }
        // If most titles are numbered, sort by that number — fixes catalogs that show
        // "latest chapters" previews above the actual chapter sequence (e.g., 努努书坊).
        if numberedSlice.count >= max(3, unique.count * 3 / 4) {
            return numberedSlice.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return orderedChapterLinks(links)
    }

    private func biqugeAPICatalogLinks(for sourceURL: URL, sourceBookID: String?) async -> [ChapterLink] {
        // Phase 2.4 cut-over: when the registry-routing flag is on,
        // try the rule-engine path first. Failures or empty results
        // fall through to the legacy parser below — this is a
        // shadow-route, never a hard cutover, so a regression in the
        // adapter can never make catalog resolution *worse* than
        // legacy. Only the Biquge path is gated for now; 5dxs and
        // HJWZW remain on legacy until their adapters mature.
        if Self.useSourceRegistryForCatalog {
            let routed = await registryRoutedBiqugeAPICatalogLinks(for: sourceURL)
            if !routed.isEmpty {
                return routed
            }
        }

        guard isBiqugeAPISource(sourceURL),
              let bookID = sourceBookID ?? bookID(from: sourceURL),
              let data = try? await fetchBiqugeAPIData(
                path: "/api/booklist",
                queryItems: [URLQueryItem(name: "id", value: bookID)]
              ),
              let response = try? JSONDecoder().decode(BiqugeBookListResponse.self, from: data) else {
            return []
        }

        return response.list.enumerated().compactMap { offset, rawTitle in
            let title = cleanText(rawTitle)
            guard !title.isEmpty else { return nil }
            let chapterID = offset + 1
            guard let url = absoluteURL(from: "/book/\(bookID)/\(chapterID).html", baseURL: sourceURL) else {
                return nil
            }
            return ChapterLink(title: title, url: url)
        }
    }

    /// UserDefaults flag — flipped on in Settings → Lab when we're
    /// ready to A/B the registry route against legacy in TestFlight.
    /// Default OFF; the legacy path stays authoritative until the
    /// flag flips at runtime. Read inline (no caching) so a flip
    /// during a session takes effect on the next import.
    static var useSourceRegistryForCatalog: Bool {
        UserDefaults.standard.bool(forKey: "lingyue.useSourceRegistryForCatalog")
    }

    /// Phase 2.4 routed-Biquge path. Talks to the registry through
    /// `SourceStack.live` instead of `fetchBiqugeAPIData` directly,
    /// then maps `LingyueCore.ChapterLink` back to this file's
    /// private struct (the latter only carries title + URL). Any
    /// throw — host mismatch (`unsupportedURL`), decode failure,
    /// transport error — is swallowed so the caller falls through
    /// to legacy. We do NOT pre-check the URL host; that's the
    /// adapter's job, and going through the throw path keeps the
    /// dispatch layer ignorant of adapter internals.
    private func registryRoutedBiqugeAPICatalogLinks(for sourceURL: URL) async -> [ChapterLink] {
        do {
            guard let source = try await SourceStack.live.registry.source(withID: "internal:biquge-api") else {
                return []
            }
            let coreLinks = try await source.fetchCatalog(url: sourceURL)
            await ReaderDiagnostics.shared.log(.info, "registry route → catalog", context: [
                "adapter": "biquge-api",
                "count": String(coreLinks.count)
            ])
            return coreLinks.map { ChapterLink(title: $0.title, url: $0.url) }
        } catch BookSourceError.unsupportedURL {
            // Host didn't match — this URL isn't the registry's
            // problem, no diagnostic noise.
            return []
        } catch {
            await ReaderDiagnostics.shared.log(.info, "registry route fell back → legacy", context: [
                "adapter": "biquge-api",
                "url": sourceURL.absoluteString,
                "error": String(describing: error)
            ])
            return []
        }
    }

    /// Phase 2.4 routed-5dxs path. Same shadow-route pattern as
    /// `registryRoutedBiqugeAPICatalogLinks` — any throw falls back
    /// to legacy, host-mismatch (`unsupportedURL`) is silent, every
    /// other error logs once for the TestFlight ramp.
    private func registryRoutedFivedxsCatalogLinks(for sourceURL: URL) async -> [ChapterLink] {
        do {
            guard let source = try await SourceStack.live.registry.source(withID: "internal:5dxs") else {
                return []
            }
            let coreLinks = try await source.fetchCatalog(url: sourceURL)
            await ReaderDiagnostics.shared.log(.info, "registry route → catalog", context: [
                "adapter": "5dxs",
                "count": String(coreLinks.count)
            ])
            return coreLinks.map { ChapterLink(title: $0.title, url: $0.url) }
        } catch BookSourceError.unsupportedURL {
            return []
        } catch {
            await ReaderDiagnostics.shared.log(.info, "registry route fell back → legacy", context: [
                "adapter": "5dxs",
                "url": sourceURL.absoluteString,
                "error": String(describing: error)
            ])
            return []
        }
    }

    /// 就爱读小说 (5dxs.net / adxs.net) paginates the chapter catalog 10-per-page on the book
    /// detail page. The site's wap UI uses an /ajaxService endpoint that returns a JSON list
    /// — calling it once with size=2000 retrieves the entire catalog in a single request,
    /// avoiding the need to walk dozens of pages.
    private func fivedxsCatalogLinks(for sourceURL: URL, sourceBookID: String?) async -> [ChapterLink] {
        if Self.useSourceRegistryForCatalog {
            let routed = await registryRoutedFivedxsCatalogLinks(for: sourceURL)
            if !routed.isEmpty {
                return routed
            }
        }

        guard let host = sourceURL.host(percentEncoded: false)?.lowercased(),
              host.contains("5dxs.net") || host.contains("adxs.net") else {
            return []
        }
        guard let bookID = sourceBookID ?? bookID(from: sourceURL),
              !bookID.isEmpty else {
            return []
        }

        let endpoints = [
            "https://m.5dxs.net/ajaxService?action=chapterlist&articleno=\(bookID)&index=0&size=\(runawayChapterLimit)&sort=1",
            "https://m.adxs.net/ajaxService?action=chapterlist&articleno=\(bookID)&index=0&size=\(runawayChapterLimit)&sort=1"
        ]

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                let html = try await fetchHTML(from: url)
                guard let data = html.data(using: .utf8),
                      let response = try? JSONDecoder().decode(FivedxsCatalogResponse.self, from: data),
                      let items = response.items, !items.isEmpty else {
                    continue
                }
                return items.compactMap { item in
                    guard let chapterURL = absoluteURL(from: item.url, baseURL: sourceURL) else {
                        return nil
                    }
                    let title = cleanText(item.chaptername)
                    guard !title.isEmpty else { return nil }
                    return ChapterLink(title: title, url: chapterURL)
                }
            } catch {
                continue
            }
        }
        return []
    }

    /// 黄金屋 reader pages only expose the nearby previous/next-ish chapter region in-page.
    /// Its full catalog is a stable `/Book/Chapter/<book id>` page, so fetch that directly
    /// whenever we can identify the book id from either the detail, catalog, or reader URL.
    private func hjwzwCatalogLinks(for sourceURL: URL, sourceBookID: String?) async -> [ChapterLink] {
        guard isHJWZWHost(sourceURL),
              let bookID = sourceBookID ?? bookID(from: sourceURL),
              let catalogURL = absoluteURL(from: "/Book/Chapter/\(bookID)", baseURL: sourceURL),
              catalogURL != sourceURL else {
            return []
        }

        do {
            let html = try await fetchHTML(from: catalogURL)
            return await chapterLinksAcrossPagination(
                startingHTML: html,
                startingURL: catalogURL,
                sourceBookID: bookID
            )
        } catch {
            return []
        }
    }

    private func chapterListScore(_ links: [ChapterLink]) -> Int {
        let numberedCount = links.filter { chapterNumber(from: $0.title) != nil }.count
        return links.count * 10 + numberedCount
    }

    private func findCatalogURLs(in html: String, baseURL: URL, sourceBookID: String?) -> [URL] {
        let linkBlocks = matches(#"<a[^>]+href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#, in: html)
        var urls: [URL] = []

        for block in linkBlocks {
            let text = cleanText(firstMatch(#">([\s\S]*?)</a>"#, in: block) ?? "")
            guard let href = firstMatch(#"href\s*=\s*["']([^"']+)["']"#, in: block),
                  let url = absoluteURL(from: href, baseURL: baseURL) else { continue }

            let lowerHref = href.lowercased()
            let looksLikeCatalogText = text.contains("目录")
                || text.contains("章節")
                || text.contains("章节")
                || text.contains("目錄")
                || text.contains("全部")
                || text.contains("查看")
                || text.contains("更多")
                || text.contains("完整")
            let listLooksLikeCategory = lowerHref.range(of: #"/list/[^0-9]"#, options: .regularExpression) != nil
            let looksLikeCatalogURL = lowerHref.contains("chapter")
                || lowerHref.contains("catalog")
                || lowerHref.contains("dir")
                || (lowerHref.contains("list") && !listLooksLikeCategory)
                || lowerHref.contains("/index.html")

            guard looksLikeCatalogText || looksLikeCatalogURL else { continue }
            if let sourceBookID, let linkedBookID = bookID(from: url), linkedBookID != sourceBookID {
                continue
            }
            urls.append(url)
        }

        urls.append(contentsOf: inferredCatalogURLs(in: html, baseURL: baseURL, sourceBookID: sourceBookID))
        return deduplicatedURLs(urls)
    }

    private func inferredCatalogURLs(in html: String, baseURL: URL, sourceBookID: String?) -> [URL] {
        var urls: [URL] = []

        guard let articleID = sourceBookID ?? authoritativeBookID(in: html, url: baseURL) else {
            return []
        }

        if let indexURL = absoluteURL(from: "/book/\(articleID)/index.html", baseURL: baseURL) {
            urls.append(indexURL)
        }
        if let bookURL = absoluteURL(from: "/book/\(articleID)/", baseURL: baseURL) {
            urls.append(bookURL)
        }
        if let bqgListURL = absoluteURL(from: "/index/\(articleID)/list.html", baseURL: baseURL) {
            urls.append(bqgListURL)
        }
        if let bqgIndexURL = absoluteURL(from: "/index/\(articleID)/", baseURL: baseURL) {
            urls.append(bqgIndexURL)
        }
        if let ajaxURL = absoluteURL(from: "/ajax_novels/chapterlist/\(articleID).html", baseURL: baseURL) {
            urls.append(ajaxURL)
        }
        if isHJWZWHost(baseURL),
           let hjwzwCatalogURL = absoluteURL(from: "/Book/Chapter/\(articleID)", baseURL: baseURL) {
            urls.append(hjwzwCatalogURL)
        }

        return urls
    }

    private func chapterLinks(from html: String, baseURL: URL, matching sourceBookID: String?) -> [ChapterLink] {
        let links = extractChapterLinks(from: html, baseURL: baseURL)
        guard let sourceBookID else { return links }

        return links.filter { link in
            guard let linkBookID = bookID(from: link.url) else { return true }
            return linkBookID == sourceBookID
        }
    }

    private func extractChapterLinks(from html: String, baseURL: URL) -> [ChapterLink] {
        let linkBlocks = matches(#"<a[^>]+href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#, in: html)
        var links: [ChapterLink] = []

        for block in linkBlocks {
            let rawTitle = firstMatch(#">([\s\S]*?)</a>"#, in: block) ?? ""
            let title = cleanText(rawTitle)
            guard let href = firstMatch(#"href\s*=\s*["']([^"']+)["']"#, in: block),
                  let url = absoluteURL(from: href, baseURL: baseURL) else { continue }
            guard isLikelyChapterTitle(title) || isLikelyChapterURL(url, title: title) else { continue }
            links.append(ChapterLink(title: title, url: url))
        }

        return links
    }

    private func fetchChapters(_ links: [ChapterLink]) async throws -> [NovelChapter] {
        var chaptersByIndex: [Int: NovelChapter] = [:]

        try await withThrowingTaskGroup(of: (Int, NovelChapter?).self) { group in
            var nextIndex = 0

            let initialCount = min(6, links.count)
            for index in 0..<initialCount {
                group.addTask { [self] in
                    (index, try await fetchChapter(links[index]))
                }
                nextIndex += 1
            }

            while let (index, chapter) = try await group.next() {
                if let chapter {
                    chaptersByIndex[index] = chapter
                }

                if nextIndex < links.count {
                    let chapterIndex = nextIndex
                    group.addTask { [self] in
                        (chapterIndex, try await fetchChapter(links[chapterIndex]))
                    }
                    nextIndex += 1
                }
            }
        }

        return chaptersByIndex
            .keys
            .sorted()
            .compactMap { chaptersByIndex[$0] }
    }

    private func fetchChapter(_ link: ChapterLink) async throws -> NovelChapter? {
        if let chapter = try await fetchBiqugeAPIChapter(link) {
            return chapter
        }

        do {
            let html = try await fetchHTML(from: link.url)
            if isSourceContentBlocked(html: html) {
                throw WebBookImportError.sourceBlockedContent
            }
            if let chapter = try await chapterFromHTML(link: link, html: html, allowDynamicTextEndpoint: true) {
                return chapter
            }
        } catch let error as WebBookImportError {
            if case .sourceBlockedContent = error { throw error }
            // fall through to WKWebView fallback for other URLSession errors (e.g. badStatus)
#if DEBUG
            debugLog("[ChapterFetch] URLSession failed for \(link.url.absoluteString): \(error.localizedDescription) — trying WKWebView fallback")
#endif
        }

        guard let renderedHTML = await WebRenderingService.shared.renderHTML(at: link.url) else {
            return nil
        }
        if isSourceContentBlocked(html: renderedHTML) {
            throw WebBookImportError.sourceBlockedContent
        }
#if DEBUG
        debugLog("[ChapterFetch] WKWebView render returned \(renderedHTML.count) bytes for \(link.url.absoluteString)")
#endif
        return try await chapterFromHTML(link: link, html: renderedHTML, allowDynamicTextEndpoint: false)
    }

    private func chapterFromHTML(
        link: ChapterLink,
        html: String,
        allowDynamicTextEndpoint: Bool
    ) async throws -> NovelChapter? {
        // Prefer headings explicitly tagged as the chapter title (class/id="title", "chaptername",
        // "article-title", etc.) so site-logo <h1> elements like 努努书坊's
        // <h1 class="logo"><a href="/">努努书坊</a></h1> don't hijack the real title.
        let titleClassRegex = #"\b(?:title|chaptername|chapter-name|article-title|book-title|nr_title)\b"#
        let parsedTitle = cleanText(
            firstMatch(#"<h1[^>]+(?:class|id)\s*=\s*["'][^"']*\#(titleClassRegex)[^"']*["'][^>]*>([\s\S]*?)</h1>"#, in: html)
                ?? firstMatch(#"<h2[^>]+(?:class|id)\s*=\s*["'][^"']*\#(titleClassRegex)[^"']*["'][^>]*>([\s\S]*?)</h2>"#, in: html)
                ?? firstMatch(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html)
                ?? link.title
        )
        // If the parsed h1/h2 looks like just the book name (no 第N章/节/页/回 marker)
        // but the catalog gave us a real chapter label (link.title has a marker), prefer
        // the catalog one. 52书库 puts "<book name>(N)" in the chapter <h1>, but the catalog
        // links read "第N页", which is what the user actually wants to see.
        let chapterMarkerRegex = #"第\s*[\d一二三四五六七八九十百千万零〇两]+\s*[章节節回卷页頁]"#
        let parsedHasMarker = parsedTitle.range(of: chapterMarkerRegex, options: .regularExpression) != nil
        let linkHasMarker = link.title.range(of: chapterMarkerRegex, options: .regularExpression) != nil
        let title: String
        if !parsedHasMarker, linkHasMarker {
            title = link.title
        } else if parsedTitle.isEmpty {
            title = link.title
        } else {
            title = parsedTitle
        }
        let bodyHTML: String
        if allowDynamicTextEndpoint {
            bodyHTML = try await dynamicChapterBodyHTML(from: html, chapterURL: link.url)
                ?? chapterBodyHTML(from: html)
        } else {
            bodyHTML = chapterBodyHTML(from: html)
        }
        let content = cleanChapterBody(bodyHTML)
        let contentWithoutTitle = content
            .replacingOccurrences(of: title, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard contentWithoutTitle.count >= 30 else { return nil }
        let chapterContent = content.hasPrefix(title) ? content : "\(title)\n\n\(content)"
        return NovelChapter(title: title, content: chapterContent)
    }

    private func fetchBiqugeAPIChapter(_ link: ChapterLink) async throws -> NovelChapter? {
        // Phase 2.4 shadow-route. Same gate as catalog: only when the
        // flag is on, and only as a *first try*. Empty/failed registry
        // result falls through to the legacy `fetchBiqugeAPIData` path
        // below — so legacy stays authoritative until TestFlight clears
        // the new route.
        if Self.useSourceRegistryForCatalog {
            if let routed = try await registryRoutedBiqugeAPIChapter(link) {
                return routed
            }
        }

        guard isBiqugeAPISource(link.url),
              let (bookID, chapterID) = biqugeBookAndChapterID(from: link.url) else {
            return nil
        }

        let data = try await fetchBiqugeAPIData(
            path: "/api/chapter",
            queryItems: [
                URLQueryItem(name: "id", value: bookID),
                URLQueryItem(name: "chapterid", value: chapterID)
            ]
        )
        let response = try JSONDecoder().decode(BiqugeChapterResponse.self, from: data)
        let title = cleanText(response.chaptername ?? link.title)
        let content = cleanChapterBody(response.txt ?? "")
        let contentWithoutTitle = content
            .replacingOccurrences(of: title, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty, contentWithoutTitle.count >= 30 else { return nil }
        let chapterContent = contentLooksPrefixedByTitle(content, title: title) ? content : "\(title)\n\n\(content)"
        return NovelChapter(title: title, content: chapterContent)
    }

    /// Phase 2.4 routed-Biquge chapter path. Asks the registry adapter
    /// for `fetchChapter`, maps `ChapterContent` to the legacy
    /// `NovelChapter`. Host-mismatch is silent; other errors log once
    /// and return nil so the caller falls through.
    private func registryRoutedBiqugeAPIChapter(_ link: ChapterLink) async throws -> NovelChapter? {
        do {
            guard let source = try await SourceStack.live.registry.source(withID: "internal:biquge-api") else {
                return nil
            }
            let chapter = try await source.fetchChapter(url: link.url)
            let title = cleanText(chapter.title.isEmpty ? link.title : chapter.title)
            let body = chapter.paragraphs.joined(separator: "\n\n")
            let content = cleanChapterBody(body)
            let contentWithoutTitle = content
                .replacingOccurrences(of: title, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, contentWithoutTitle.count >= 30 else { return nil }
            await ReaderDiagnostics.shared.log(.info, "registry route → chapter", context: [
                "adapter": "biquge-api",
                "bytes": String(content.count)
            ])
            let chapterContent = contentLooksPrefixedByTitle(content, title: title) ? content : "\(title)\n\n\(content)"
            return NovelChapter(title: title, content: chapterContent)
        } catch BookSourceError.unsupportedURL {
            return nil
        } catch {
            await ReaderDiagnostics.shared.log(.info, "registry chapter fell back → legacy", context: [
                "adapter": "biquge-api",
                "url": link.url.absoluteString,
                "error": String(describing: error)
            ])
            return nil
        }
    }

    private func isBiqugeAPISource(_ url: URL) -> Bool {
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        return host.contains("bqg") && url.absoluteString.contains("/book/")
    }

    private func biqugeBookAndChapterID(from url: URL) -> (bookID: String, chapterID: String)? {
        let path = url.path
        guard let bookID = firstMatch(#"/book/(\d+)/\d+(?:_\d+)?\.html?$"#, in: path),
              let chapterID = firstMatch(#"/book/\d+/(\d+)(?:_\d+)?\.html?$"#, in: path) else {
            return nil
        }
        return (bookID, chapterID)
    }

    private func fetchBiqugeAPIData(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        var lastError: Error?

        for host in biqugeAPIHosts {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = path
            components.queryItems = queryItems
            guard let url = components.url else { continue }

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
                request.setValue("zh-CN,zh-Hans;q=0.9,zh;q=0.8,en;q=0.6", forHTTPHeaderField: "Accept-Language")

                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200..<400).contains(httpResponse.statusCode) {
                    lastError = WebBookImportError.badStatus(httpResponse.statusCode)
                    continue
                }
                return data
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? WebBookImportError.badStatus(-1)
    }

    private func contentLooksPrefixedByTitle(_ content: String, title: String) -> Bool {
        let contentPrefix = String(content.prefix(max(24, title.count + 8)))
        return compactTitleComparable(contentPrefix).hasPrefix(compactTitleComparable(title))
    }

    private func compactTitleComparable(_ text: String) -> String {
        cleanText(text)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\p{P}\p{S}]"#, with: "", options: .regularExpression)
    }

    private func isSourceContentBlocked(html: String) -> Bool {
        html.contains("由于版权问题不能显示")
            || html.contains("由於版權問題不能顯示")
            || html.contains("请下载努努书坊APP")
            || html.contains("請下載努努書坊APP")
    }

    private func chapterBodyHTML(from html: String) -> String {
        let containerKeywords = "chaptercontent|chapter-content|chapter_content|read-content|readcontent|read_content|read_chapter|read_chapterdetail|bookcontent|booktxt|textcontent|article-content|articlecontent|nr1|txtnav|mycontent|neirong"

        // Sibling-bound capture (txtnav … page1) stays a regex — no balanced walking needed.
        if let match = firstMatch(
            #"<div[^>]+class=["'][^"']*\btxtnav\b[^"']*["'][^>]*>([\s\S]*?)<div[^>]+class=["'][^"']*\bpage1\b"#,
            in: html
        ), cleanText(match).count >= 12 {
            return match
        }

        // Find the opening tag, then walk balanced to find the matching close.
        // Non-greedy regex like ([\s\S]*?)</div> stops at the FIRST </div>, which can
        // be a nested noise wrapper (e.g., 努努书坊's <div class="posterror">).
        //
        // Specific content selectors come first. Generic alternatives like `class*="content"`
        // are intentionally LAST because page wrappers like 52书库's `<div class="content-wrap">`
        // and `<div class="content contentmargin">` share the substring and would steal the match
        // away from the precise chapter container.
        let containers: [(String, String)] = [
            // 1. Inline-styled chapter body (黄金屋中文 / 宙斯小说). Drop the standalone `width: 700px`
            //    signal — 宙斯小说's header bar uses `position: absolute; ...; width: 700px;`.
            (#"<div[^>]+style=["'][^"']*(?:word-wrap:\s*break-word|text-indent:\s*2em)[^"']*["'][^>]*>"#, "div"),
            // 2. Specific id/class selectors.
            (#"<div[^>]+id=["']content["'][^>]*>"#, "div"),
            (#"<div[^>]+id=["']chaptercontent["'][^>]*>"#, "div"),
            // 3. Article/Section with a content-specific class — must come BEFORE the generic
            //    div-with-content selector so 52书库's `<article class="article-content" id="nr1">`
            //    wins over its outer `<div class="content contentmargin">`.
            (#"<article[^>]+(?:id|class)\s*=\s*["'][^"']*(?:\#(containerKeywords))[^"']*["'][^>]*>"#, "article"),
            (#"<section[^>]+(?:id|class)\s*=\s*["'][^"']*(?:\#(containerKeywords))[^"']*["'][^>]*>"#, "section"),
            // 4. Div with a specific keyword (no loose `content|txt` fallback that would catch wrappers).
            (#"<div[^>]+(?:id|class)\s*=\s*["'][^"']*(?:\#(containerKeywords))[^"']*["'][^>]*>"#, "div"),
            // 5. Generic fallbacks — match wider classes, but only if nothing more specific landed.
            (#"<div[^>]+(?:id|class)\s*=\s*["'][^"']*(?:acontent|contenttxt|chapter)[^"']*["'][^>]*>"#, "div"),
            (#"<section[^>]+(?:id|class)\s*=\s*["'][^"']*(?:content|chapter|read|article)[^"']*["'][^>]*>"#, "section"),
            (#"<main[^>]*>"#, "main"),
            (#"<article[^>]*>"#, "article")
        ]

        let nsHtml = html as NSString
        let lowerHtml = nsHtml.lowercased as NSString
        for (openingPattern, tagName) in containers {
            guard let regex = try? NSRegularExpression(pattern: openingPattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: nsHtml.length))
            else { continue }
            let openingEnd = match.range.location + match.range.length
            guard let inner = balancedInnerRange(after: openingEnd, tagName: tagName, lowerHtml: lowerHtml, totalLength: nsHtml.length) else { continue }
            let body = nsHtml.substring(with: inner)
            if cleanText(body).count >= 12 {
                return body
            }
        }

        return html
    }

    private func balancedInnerRange(
        after openingEnd: Int,
        tagName: String,
        lowerHtml: NSString,
        totalLength: Int
    ) -> NSRange? {
        let openToken = "<\(tagName)"
        let closeToken = "</\(tagName)>"
        var depth = 1
        var cursor = openingEnd

        while cursor < totalLength {
            let searchRange = NSRange(location: cursor, length: totalLength - cursor)
            let nextOpen = lowerHtml.range(of: openToken, options: [], range: searchRange)
            let nextClose = lowerHtml.range(of: closeToken, options: [], range: searchRange)
            guard nextClose.location != NSNotFound else { return nil }

            if nextOpen.location != NSNotFound && nextOpen.location < nextClose.location {
                let afterOpen = nextOpen.location + nextOpen.length
                if afterOpen < totalLength {
                    let next = lowerHtml.character(at: afterOpen)
                    // Treat as a real opening only if followed by space, tab, newline, or '>'
                    if next == 0x20 || next == 0x3E || next == 0x09 || next == 0x0A || next == 0x0D {
                        depth += 1
                    }
                }
                cursor = afterOpen
            } else {
                depth -= 1
                if depth == 0 {
                    return NSRange(location: openingEnd, length: nextClose.location - openingEnd)
                }
                cursor = nextClose.location + nextClose.length
            }
        }
        return nil
    }

    private func dynamicChapterBodyHTML(from html: String, chapterURL: URL) async throws -> String? {
        guard html.contains("/js/read.js") || html.contains("i31pdbha_") else { return nil }
        guard let itemID = metaContent(named: "itemid", in: html),
              let categoryID = metaContent(named: "catid", in: html),
              let chapterID = currentChapterID(from: chapterURL, html: html),
              let idList = dynamicChapterIDList(in: html, currentChapterID: chapterID) else {
            return nil
        }

        let salt = idList.last ?? ""
        guard salt.count >= 5 else { return nil }

        let suffixStart = (Int(chapterID) ?? 0) * 3 % 100
        let suffix = substring(salt, start: suffixStart, length: 5)
        guard suffix.count == 5 else { return nil }

        let host = html.contains("8book.com") ? "www.8book.com" : (chapterURL.host(percentEncoded: false) ?? "")
        guard !host.isEmpty,
              let textURL = URL(string: "https://\(host)/txt/\(categoryID)/\(itemID)/\(chapterID)\(suffix).html") else {
            return nil
        }

        let textHTML = try await fetchHTML(from: textURL)
        return cleanText(textHTML).isEmpty ? nil : textHTML
    }

    private func currentChapterID(from url: URL, html: String) -> String? {
        if let query = url.query(percentEncoded: false),
           let id = query.split(separator: "_").first?.filter(\.isNumber),
           !id.isEmpty {
            return String(id)
        }

        return firstMatch(#"var\s+[A-Za-z0-9_]+\s*=\s*u\.indexOf\('\?'\)>0\?parseInt\(u\.split\('\?'\)\[1\]\):(\d+)"#, in: html)
    }

    private func dynamicChapterIDList(in html: String, currentChapterID: String) -> [String]? {
        let lists = matches(#"var\s+[A-Za-z0-9_]+\s*=\s*"([\d,]+)"\.split\('\s*,\s*'\)"#, in: html, captureGroup: 1)

        return lists
            .map { $0.split(separator: ",").map(String.init) }
            .first { list in
                list.count > 10
                    && list.contains(currentChapterID)
                    && (list.last?.count ?? 0) > 20
            }
    }

    private func substring(_ text: String, start: Int, length: Int) -> String {
        guard start >= 0, length > 0, start < text.count else { return "" }
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(lower, offsetBy: min(length, text.distance(from: lower, to: text.endIndex)))
        return String(text[lower..<upper])
    }

    private func fetchHTML(from url: URL) async throws -> String {
        // App Transport Security blocks plain http for URLSession even though WKWebView is allowed
        // arbitrary loads in web content. Several sources (e.g. 破万卷小说) issue 301s that drop
        // from https to http, leaving us with an http URL we can't fetch directly. Upgrade the
        // scheme back to https — every source we've encountered serves both schemes equivalently.
        let secureURL: URL = {
            guard url.scheme?.lowercased() == "http",
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url
            }
            components.scheme = "https"
            return components.url ?? url
        }()

        var request = URLRequest(url: secureURL)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh-Hans;q=0.9,zh;q=0.8,en;q=0.6", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await httpSession.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode) {
            throw WebBookImportError.badStatus(httpResponse.statusCode)
        }

        return decodedHTML(data: data, response: response)
    }

    private func decodedHTML(data: Data, response: URLResponse) -> String {
        if let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           let charsetRange = contentType.range(of: #"charset=([^;\s]+)"#, options: .regularExpression) {
            let charset = String(contentType[charsetRange])
                .replacingOccurrences(of: "charset=", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if charset.contains("gb") || charset.contains("gbk") {
                return String(data: data, encoding: .gb_18030_2000) ?? ""
            }
            if charset.contains("big5") {
                return String(data: data, encoding: .big5Chinese) ?? ""
            }
        }

        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .gb_18030_2000)
            ?? String(data: data, encoding: .big5Chinese)
            ?? ""
    }

    private func cleanChapterBody(_ html: String) -> String {
        let text = htmlToText(html)
        let blockedFragments = [
            "请收藏本站", "加入书签", "加入書簽", "返回目录", "返回目錄",
            "上一章", "上一頁", "上一篇", "下一章", "下一頁", "下一篇",
            "最新网址", "最新網址", "手机用户", "本章未完", "点击报错", "點擊報錯",
            "章节报错", "章節報錯", "本站域名", "天才一秒记住", "天才一秒鐘記住",
            "喜欢请分享", "app下载", "APP下載", "无弹窗", "無彈窗",
            "看本书最新章节", "看本書最新章節", "請訪問sto9", "请访问sto9",
            "loadAdv(", "返回书架", "返回書架", "加入书架", "加入書架",
            "推荐本书", "推薦本書", "字体大小", "字體大小",
            // 努努书坊 inline error / report banner that sits above each chapter body
            "章节错误", "章節錯誤", "点此举报", "點此舉報", "举报后维护人员",
            "校正章节内容", "校正章節內容", "请耐心等待", "請耐心等待",
            "并刷新页面", "並刷新頁面",
            // 努努书坊 copyright wall fragments
            "由于版权问题", "由於版權問題", "请下载努努书坊", "請下載努努書坊",
            "下载努努书坊APP", "下載努努書坊APP", "在APP内更新", "在APP內更新",
            "下载免费看", "下載免費看", "如何阅读小说完整章节", "如何閱讀小說完整章節",
            "正在手打中", "电子书轻松制作", "電子書輕松制作",
            "更新最快的小说网站", "更新最快的小說網站",
            "努努书坊APP小说阅读器", "努努書坊APP小說閱讀器",
            // Generic ad / share text
            "请用搜索引擎", "請用搜索引擎",
            // Catalog / breadcrumb fragments that sometimes leak into chapter pages.
            "52书库 >", "52書庫 >", "半夏小说 >", "半夏小說 >",
            "笔趣阁 >", "筆趣閣 >", "思兔閱讀 >", "思兔阅读 >"
        ]
        let exactBlocked: Set<String> = [
            "返回", "回顶部", "回頂部", "目录", "目錄", "首页", "首頁",
            "大", "中", "小", "夜间", "夜間", "日间", "日間", "字号",
            "书签", "書籤", "书架", "書架", "txt下载", "TXT下載",
            "上一章", "下一章", "上一頁", "下一頁", "上一篇", "下一篇"
        ]

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if exactBlocked.contains(line) { return false }
                if Self.isNavigationOnlyLine(line) { return false }
                if line.range(
                    of: #"^(?:首页|首頁|52书库|52書庫|半夏小说|半夏小說|笔趣阁|筆趣閣|思兔閱讀|思兔阅读|书库|書庫)\s*[>›]"#,
                    options: .regularExpression
                ) != nil {
                    return false
                }
                if line.contains(">"),
                   line.count <= 140,
                   ["小说", "小說", "书库", "書庫", "男频", "女频", "分类"].contains(where: { line.contains($0) }) {
                    return false
                }
                return !blockedFragments.contains { line.localizedCaseInsensitiveContains($0) }
            }

        return stripLeadingBookMetadata(lines).joined(separator: "\n\n")
    }

    /// Navigation-link footers (e.g. "目录 上一页 下一页 尾页 Top" on 52书库, or
    /// "上一章 | 章节目录 | 下一章" on笔趣阁-style sites) survive earlier filters because
    /// they're a *single* line containing multiple labels separated by whitespace or
    /// punctuation. Tokenize the line and drop it if every token is a known nav label
    /// — this is source-agnostic, so adding new sources doesn't need a per-site rule.
    private static let navigationTokens: Set<String> = [
        "目录", "目錄", "目录页", "目錄頁", "章节列表", "章節列表",
        "首页", "首頁", "返回", "返回首页", "返回首頁",
        "上一章", "下一章", "上一頁", "下一頁", "上一页", "下一页",
        "上一篇", "下一篇", "上一卷", "下一卷",
        "首章", "末章", "首页章节", "末页", "末頁", "尾页", "尾頁",
        "回顶部", "回頂部", "返回顶部", "返回頂部",
        "书签", "書籤", "加入书签", "加入書簽", "加入书架", "加入書架",
        "书架", "書架", "下载", "下載", "txt下载", "txt下載",
        "字号", "字體大小", "字体大小",
        "夜间", "夜間", "日间", "日間",
        "top", "home", "back", "next", "prev", "previous"
    ]

    private static func isNavigationOnlyLine(_ line: String) -> Bool {
        // Cheap upper bound — a true nav footer is short. Saves us tokenizing every
        // long paragraph in the chapter body.
        guard line.count <= 60 else { return false }

        let separators = CharacterSet(charactersIn: " \t　|/·›>›→←-—‧•∙、，,")
        let tokens = line
            .components(separatedBy: separators)
            .map { token in
                token.trimmingCharacters(in: .punctuationCharacters)
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
            }
            .filter { !$0.isEmpty }

        // Single-token lines are handled by exactBlocked / blockedFragments; we only
        // care about the multi-label nav strip here.
        guard tokens.count >= 2 else { return false }

        return tokens.allSatisfy { navigationTokens.contains($0) }
    }

    /// Strips leading book-metadata noise that some sources wedge before the actual chapter
    /// content — e.g. 破万卷小说 prefaces every chapter page with the book title, "作者：xxx",
    /// "简介：" and a few summary paragraphs before the real "第N章 ..." heading. If we see
    /// metadata markers (作者[:：] / 简介[:：]) within the first ~12 lines AND a chapter heading
    /// appears later, drop everything up through that first chapter heading.
    private func stripLeadingBookMetadata(_ lines: [String]) -> [String] {
        guard !lines.isEmpty else { return lines }
        let prefixWindow = lines.prefix(12)
        let metadataPattern = #"^(?:作者|簡介|简介|內容簡介|内容简介)\s*[:：]"#
        let hasMetadata = prefixWindow.contains { line in
            line.range(of: metadataPattern, options: .regularExpression) != nil
        }
        guard hasMetadata else { return lines }

        let chapterMarker = #"^第\s*[\d一二三四五六七八九十百千万零〇两]+\s*[章节節回卷页頁]"#
        guard let firstMarkerIndex = lines.firstIndex(where: {
            $0.range(of: chapterMarker, options: .regularExpression) != nil
        }) else {
            return lines
        }

        // Drop everything up to AND including the first chapter heading — the chapter title is
        // already prepended separately by chapterFromHTML.
        let trimmed = Array(lines.suffix(from: lines.index(after: firstMarkerIndex)))
        return trimmed.isEmpty ? lines : trimmed
    }

    private func htmlToText(_ html: String) -> String {
        // Strip script/style first — they contain raw text we never want to leak through.
        // Then strip semantic chrome (head/nav/header/footer/aside/form/button/select):
        // these never appear inside a real chapter body, but DO leak through when
        // chapterBodyHTML falls back to whole-page HTML on an unrecognized source —
        // without this, the page <title>, top-nav, reader-control widgets, and footer
        // links all show up as text before the actual chapter content.
        var text = html
            .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<head[\s>][\s\S]*?</head>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<nav[\s>][\s\S]*?</nav>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<header[\s>][\s\S]*?</header>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<footer[\s>][\s\S]*?</footer>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<aside[\s>][\s\S]*?</aside>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<form[\s>][\s\S]*?</form>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<button[\s>][\s\S]*?</button>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<select[\s>][\s\S]*?</select>"#, with: "", options: [.regularExpression, .caseInsensitive])

        // Decode entities BEFORE the tag strip pass so entity-encoded tags inside the body
        // (e.g., 就爱读小说 wraps the chapter title as &lt;p class="name"&gt;...&lt;/p&gt;
        // inside #acontent) become real tags that the strip pass can remove. Doing it after
        // would leak the literal "<p class="name">…</p>" text into the rendered chapter.
        text = decodeHTMLEntities(text)

        text = text
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</p>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</div>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        text = text
            .replacingOccurrences(of: #"[ \t\u{00a0}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    private func cleanBookTitle(_ rawTitle: String) -> String {
        var title = cleanText(rawTitle)
        let suffixes = [
            "最新章节", "最新章節", "全文阅读", "全文閱讀", "免费阅读", "免費閱讀",
            "在线阅读", "在線閱讀", "章节目录", "章節目錄", "无弹窗", "無彈窗",
            "小说网", "小說網", "小说", "小說", "- 破万卷", "_52书库", "- 52书库",
            "|思兔sto9", "｜思兔sto9"
        ]
        for suffix in suffixes {
            title = title.replacingOccurrences(of: suffix, with: "")
        }
        // Strip 【…】 only when its contents are a known site-added metadata tag (status,
        // format, editorial note). Bracketed prefixes that name a fanfic universe or
        // crossover — e.g. 【综犬夜叉】之机械姬她没有心, 【综漫】, 【HP】 — are part of the
        // real title and must survive. The earlier blanket strip removed those too.
        let bracketMetadataPhrases = [
            "完本", "完結", "完结", "已完", "已完結", "已完结", "已完成",
            "連載", "连载", "連載中", "连载中", "斷更", "断更", "全本", "完",
            "TXT", "txt", "Txt", "VIP", "vip", "Vip",
            "限免", "免费", "免費", "有声", "有聲",
            "官方", "官方版", "转载", "轉載", "重发", "重發", "重置",
            "推荐", "推薦", "精校", "校对", "校對", "原创", "原創",
            "最新章节", "最新章節", "最新", "新书", "新書",
            "已审核", "已審核", "更新", "已更", "完整版"
        ].joined(separator: "|")
        return title
            .replacingOccurrences(of: "【\\s*(?:\(bracketMetadataPhrases))\\s*】", with: "", options: .regularExpression)
            // Tidy up empty brackets left behind after the suffix strip removed
            // their contents (e.g. 【最新章节】 → 【】 → "").
            .replacingOccurrences(of: #"【\s*】"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[-_｜|]\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func authoritativeBookID(in html: String, url: URL) -> String? {
        let candidates: [String?] = [
            bookID(from: url),
            metaContent(named: "og:book_id", in: html),
            metaContent(named: "og:novel:read_url", in: html).flatMap { bookID(from: $0, baseURL: url) },
            metaContent(named: "og:url", in: html).flatMap { bookID(from: $0, baseURL: url) },
            firstMatch(#"articleid\s*[:=]\s*['"]?(\d+)['"]?"#, in: html),
            firstMatch(#"addbookcase\(\s*(\d+)"#, in: html),
            firstMatch(#"/modules/article/txtarticle\.php\?id=(\d+)"#, in: html)
        ]

        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    private func bookID(from href: String, baseURL: URL) -> String? {
        guard let url = absoluteURL(from: href, baseURL: baseURL) else { return nil }
        return bookID(from: url)
    }

    private func bookID(from url: URL) -> String? {
        let rawPath = url.path.lowercased()
        let rawFragment = url.fragment(percentEncoded: false)?.lowercased() ?? ""
        let path: String
        if (rawPath.isEmpty || rawPath == "/"), !rawFragment.isEmpty {
            path = rawFragment.hasPrefix("/") ? rawFragment : "/" + rawFragment
        } else {
            path = rawPath
        }
        // Order matters: more specific patterns must come first. The biquge-style
        // /(?:htm|html|index|kan|look)/(\d+)... patterns aren't anchored to start, so on a
        // chapter URL like /tongren/20104/index/1.html they would otherwise match the trailing
        // /index/1.html and capture "1" — the chapter number — instead of the book id "20104".
        let patterns = [
            // 就爱读小说 (jieqi-style): /info/<sub>/<bookid>.html (detail), /reader/<sub>/<bookid>/<chapterno>.html (chapter)
            #"^/info/\d+/(\d+)\.html?$"#,
            #"^/reader/\d+/(\d+)/\d+\.html?$"#,
            // 破万卷小说: /<category>/<bookid> (book detail) and /<category>/<bookid>/index/<n>.html (chapter)
            #"^/[a-z]+\d*/(\d+)/index/\d+\.html?$"#,
            #"^/[a-z]+\d*/(\d+)/?$"#,
            #"/book/(\d+)(?:/index)?\.html$"#,
            #"/book/chapter/(\d+)/?$"#,
            #"/book/read/(\d+),\d+/?$"#,
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

    private func cleanText(_ rawText: String) -> String {
        decodeHTMLEntities(rawText)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var decoded = text

        for (entity, value) in HTMLEntityTable.entities {
            decoded = decoded.replacingOccurrences(of: entity, with: value)
        }

        decoded = decodeNumericHTMLEntities(in: decoded)
        return decoded
    }

    private func decodeNumericHTMLEntities(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|\d+);"#) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        var decoded = ""
        var cursor = text.startIndex
        for match in matches {
            guard
                let fullRange = Range(match.range(at: 0), in: text),
                let valueRange = Range(match.range(at: 1), in: text)
            else { continue }

            decoded.append(contentsOf: text[cursor..<fullRange.lowerBound])
            let token = String(text[valueRange])
            let value = token.lowercased().hasPrefix("x")
                ? UInt32(String(token.dropFirst()), radix: 16)
                : UInt32(token, radix: 10)
            if let value, let scalar = UnicodeScalar(value) {
                decoded.append(Character(scalar))
            }
            cursor = fullRange.upperBound
        }

        decoded.append(contentsOf: text[cursor..<text.endIndex])
        return decoded
    }

    private func metaContent(named name: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return firstMatch(#"<meta[^>]+(?:property|name)\s*=\s*["']\#(escaped)["'][^>]+content\s*=\s*["']([^"']*)["'][^>]*>"#, in: html, captureGroup: 1)
            ?? firstMatch(#"<meta[^>]+content\s*=\s*["']([^"']*)["'][^>]+(?:property|name)\s*=\s*["']\#(escaped)["'][^>]*>"#, in: html, captureGroup: 1)
    }

    private func absoluteURL(from href: String, baseURL: URL) -> URL? {
        let trimmed = decodeHTMLEntities(href).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.lowercased().hasPrefix("javascript:") else {
            return nil
        }

        guard var components = URLComponents(url: URL(string: trimmed, relativeTo: baseURL)?.absoluteURL ?? baseURL, resolvingAgainstBaseURL: true) else {
            return nil
        }

        components.fragment = nil
        if components.scheme == "http",
           baseURL.scheme == "https",
           components.host == baseURL.host {
            components.scheme = "https"
        }

        return components.url
    }

    private func isNonChapterButtonLabel(_ title: String) -> Bool {
        let labels = [
            "目录", "目錄", "首页", "首頁", "上一页", "上一頁", "下一页", "下一頁",
            "上一篇", "下一篇", "上一卷", "下一卷",
            "书签", "書籤", "书架", "書架", "下载", "下載",
            "登录", "登入", "注册", "排行榜",
            "开始阅读", "開始閱讀", "立即阅读", "立即閱讀",
            "在线阅读", "在線閱讀", "免费阅读", "免費閱讀",
            "加入书架", "加入書架", "加入书签", "加入書簽",
            "txt下载", "TXT下載", "目錄頁", "首頁回首"
        ]
        return labels.contains(where: { title.contains($0) })
    }

    private func isLikelyChapterTitle(_ title: String) -> Bool {
        guard title.count >= 2, title.count <= 80 else { return false }
        if isNonChapterButtonLabel(title) { return false }

        if title.range(of: #"第\s*[\d一二三四五六七八九十百千万零〇两]+\s*[章节節回卷页頁]"#, options: .regularExpression) != nil {
            return true
        }

        return title.hasPrefix("序章")
            || title.hasPrefix("楔子")
            || title.hasPrefix("番外")
            || title.hasPrefix("尾声")
            || title.localizedCaseInsensitiveContains("chapter")
    }

    private func isLikelyChapterURL(_ url: URL, title: String) -> Bool {
        guard title.count >= 2, title.count <= 80 else { return false }
        if isNonChapterButtonLabel(title) { return false }
        let path = url.path.lowercased()
        return path.range(of: #"/txt/\d+/\d+\.html$"#, options: .regularExpression) != nil
            || path.range(of: #"/read/\d+[_/]\d+\.html?$"#, options: .regularExpression) != nil
            || path.range(of: #"/book/read/\d+,\d+/?$"#, options: .regularExpression) != nil
            || path.range(of: #"/book/\d+/\d+(?:\.html?)?$"#, options: .regularExpression) != nil
            || path.range(of: #"/books/\d+/\d+\.html?$"#, options: .regularExpression) != nil
            || path.range(of: #"/(?:htm|html|index|kan|look)/\d+/\d+(?:\.html?)?$"#, options: .regularExpression) != nil
            || path.contains("/chapter/")
            || path.contains("/chapters/")
            || path.range(of: #"_\d+\.html?$"#, options: .regularExpression) != nil
    }

    private func deduplicated(_ links: [ChapterLink]) -> [ChapterLink] {
        var seen: Set<String> = []
        var unique: [ChapterLink] = []

        for link in links {
            let key = link.url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(link)
        }

        return unique
    }

    private func orderedChapterLinks(_ links: [ChapterLink]) -> [ChapterLink] {
        let unique = deduplicated(links)
        let numbers = unique.compactMap { chapterNumber(from: $0.title) }
        guard numbers.count >= 3 else { return unique }

        let pairs = zip(numbers, numbers.dropFirst())
        let increasingCount = pairs.filter { $0.1 >= $0.0 }.count
        let decreasingCount = pairs.filter { $0.1 < $0.0 }.count
        let mostlyDistinct = Set(numbers).count >= max(3, numbers.count * 3 / 4)

        if mostlyDistinct, decreasingCount > increasingCount * 2 {
            return unique.reversed()
        }

        return unique
    }

    private func chapterNumber(from title: String) -> Int? {
        if let arabic = firstMatch(#"第\s*(\d+)\s*[章节節回卷页頁]"#, in: title) {
            return Int(arabic)
        }

        if let chinese = firstMatch(#"第\s*([一二三四五六七八九十百千万零〇两]+)\s*[章节節回卷页頁]"#, in: title) {
            return chineseNumber(chinese)
        }

        return nil
    }

    private func chineseNumber(_ text: String) -> Int? {
        let digits: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1_000, "万": 10_000]

        var total = 0
        var section = 0
        var number = 0
        var sawToken = false

        for char in text {
            if let digit = digits[char] {
                number = digit
                sawToken = true
            } else if let unit = units[char] {
                sawToken = true
                if unit == 10_000 {
                    section = (section + number) * unit
                    total += section
                    section = 0
                } else {
                    section += (number == 0 ? 1 : number) * unit
                }
                number = 0
            } else {
                return nil
            }
        }

        guard sawToken else { return nil }
        return total + section + number
    }

    private func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []

        for url in urls {
            let key = url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(url)
        }

        return unique
    }

    private func firstMatch(_ pattern: String, in text: String, captureGroup: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let capture = Range(match.range(at: captureGroup), in: text) else {
            return nil
        }
        return String(text[capture])
    }

    private func matches(_ pattern: String, in text: String, captureGroup: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let capture = Range(match.range(at: captureGroup), in: text) else { return nil }
            return String(text[capture])
        }
    }
}

/// Named HTML entities encountered across the various Chinese novel sources we import from.
/// We don't need a full HTML5 spec table — just the entities that actually appear in chapter
/// content. Decimal/hex numeric entities are handled separately by decodeNumericHTMLEntities.
private enum HTMLEntityTable {
    static let entities: [String: String] = [
        // Whitespace
        "&nbsp;": " ",
        "&emsp;": "　",
        "&ensp;": " ",
        "&thinsp;": " ",
        "&zwj;": "",
        "&zwnj;": "",

        // Symbols
        "&amp;": "&",
        "&lt;": "<",
        "&gt;": ">",
        "&quot;": "\"",
        "&apos;": "'",

        // Smart quotes — many Chinese sources use these for dialogue
        "&ldquo;": "\u{201C}",  // “
        "&rdquo;": "\u{201D}",  // ”
        "&lsquo;": "\u{2018}",  // ‘
        "&rsquo;": "\u{2019}",  // ’
        "&laquo;": "«",
        "&raquo;": "»",
        "&sbquo;": "‚",
        "&bdquo;": "„",
        "&prime;": "′",
        "&Prime;": "″",

        // Dashes / ellipses
        "&mdash;": "—",
        "&ndash;": "–",
        "&hellip;": "……",
        "&horbar;": "―",

        // Punctuation
        "&middot;": "·",
        "&bull;": "•",
        "&para;": "¶",
        "&sect;": "§",
        "&dagger;": "†",
        "&Dagger;": "‡",
        "&permil;": "‰",

        // Trademarks / legal
        "&copy;": "©",
        "&reg;": "®",
        "&trade;": "™",

        // Math / common symbols
        "&times;": "×",
        "&divide;": "÷",
        "&plusmn;": "±",
        "&deg;": "°",
        "&micro;": "µ",

        // Numeric named (some sources still emit these)
        "&#39;": "'",
        "&#x27;": "'",
        "&#34;": "\"",
        "&#x22;": "\""
    ]
}

private extension String.Encoding {
    static let gb_18030_2000 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    static let big5Chinese = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)
        )
    )
}

/// URLSession delegate that rewrites http://… redirect targets to https://… so App Transport
/// Security doesn't block sites that 301 from https to http (e.g. 破万卷小说).
final class HTTPSUpgradingRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            completionHandler(request)
            return
        }
        components.scheme = "https"
        guard let upgraded = components.url else {
            completionHandler(request)
            return
        }
        var rewritten = request
        rewritten.url = upgraded
        completionHandler(rewritten)
    }
}

actor ChapterContentCache {
    static let shared = ChapterContentCache()

    private var memory: [String: NovelChapter] = [:]
    private var inFlight: [String: Task<NovelChapter, Error>] = [:]
    private let cacheDirectory: URL

    private init() {
        self.cacheDirectory = Self.cacheDirectoryURL()
    }

    nonisolated static func diskCachedChapter(for chapter: NovelChapter) -> NovelChapter? {
        guard chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return chapter
        }

        let key = chapter.sourceURLString ?? chapter.id.uuidString
        let url = cacheDirectoryURL().appendingPathComponent("\(stableHash(key)).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let cachedChapter = try? JSONDecoder().decode(NovelChapter.self, from: data) else {
            return nil
        }
        // Optimistic preheat callers expect real content; sentinel chapters route through
        // the throwing `chapter(for:)` path so the reader displays the source-blocked error.
        if BookImportService.isSourceBlockedSentinelContent(cachedChapter.content) {
            return nil
        }
        if BookImportService.shared.shouldUseCachedChapter(cachedChapter, for: chapter) {
            return cachedChapter
        }
        try? FileManager.default.removeItem(at: url)
        return nil
    }

    func chapter(for chapter: NovelChapter) async throws -> NovelChapter {
        guard chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return chapter
        }

        let key = cacheKey(for: chapter)

        if let cached = memory[key] {
            if BookImportService.shared.shouldUseCachedChapter(cached, for: chapter) {
                if BookImportService.isSourceBlockedSentinelContent(cached.content) {
                    throw WebBookImportError.sourceBlockedContent
                }
                return cached
            }
            memory[key] = nil
        }

        if let diskChapter = readChapterFromDisk(key: key) {
            if BookImportService.shared.shouldUseCachedChapter(diskChapter, for: chapter) {
                memory[key] = diskChapter
                if BookImportService.isSourceBlockedSentinelContent(diskChapter.content) {
                    throw WebBookImportError.sourceBlockedContent
                }
                return diskChapter
            }
            try? FileManager.default.removeItem(at: cacheFileURL(for: key))
        }

        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task {
            try await BookImportService.shared.loadChapter(chapter)
        }
        inFlight[key] = task

        do {
            let loaded = try await task.value
            memory[key] = loaded
            writeChapterToDisk(loaded, key: key)
            inFlight[key] = nil
            return loaded
        } catch {
            inFlight[key] = nil
            // Persist a sentinel for permanently source-blocked chapters so future probes
            // count them as cached and the download finishes instead of looping in
            // .failed. Reader path re-throws this error from the cached-sentinel branch
            // above, so the user still sees "该来源限制章节正文显示" when they open it.
            if let webError = error as? WebBookImportError, case .sourceBlockedContent = webError {
                let sentinel = NovelChapter(
                    id: chapter.id,
                    title: chapter.title,
                    content: BookImportService.sourceBlockedContentSentinel,
                    sourceURLString: chapter.sourceURLString
                )
                memory[key] = sentinel
                writeChapterToDisk(sentinel, key: key)
            }
            throw error
        }
    }

    func cachedChapter(for chapter: NovelChapter) -> NovelChapter? {
        guard chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return chapter
        }

        let key = cacheKey(for: chapter)
        if let cached = memory[key] {
            if BookImportService.shared.shouldUseCachedChapter(cached, for: chapter) {
                // Optimistic preheat callers want real content. Sentinel chapters route
                // through the throwing `chapter(for:)` path instead.
                if BookImportService.isSourceBlockedSentinelContent(cached.content) {
                    return nil
                }
                return cached
            }
            memory[key] = nil
        }

        if let diskChapter = readChapterFromDisk(key: key) {
            if BookImportService.shared.shouldUseCachedChapter(diskChapter, for: chapter) {
                memory[key] = diskChapter
                if BookImportService.isSourceBlockedSentinelContent(diskChapter.content) {
                    return nil
                }
                return diskChapter
            }
            try? FileManager.default.removeItem(at: cacheFileURL(for: key))
        }

        return nil
    }

    func cacheSizeBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    func clearAll() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        memory.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    func clearCache(for novel: Novel) {
        let keys = Set(novel.chapters.map(cacheKey(for:)))
        guard !keys.isEmpty else { return }

        for key in keys {
            inFlight[key]?.cancel()
            inFlight[key] = nil
            memory[key] = nil
            try? FileManager.default.removeItem(at: cacheFileURL(for: key))
        }
    }

    func cachedKeys(for chapters: [NovelChapter]) -> Set<String> {
        var keys: Set<String> = []

        for chapter in chapters where chapter.sourceURLString != nil {
            let key = cacheKey(for: chapter)
            if let cached = memory[key] {
                if BookImportService.shared.shouldUseCachedChapter(cached, for: chapter) {
                    keys.insert(key)
                    continue
                }
                memory[key] = nil
            }

            if let diskChapter = readChapterFromDisk(key: key) {
                if BookImportService.shared.shouldUseCachedChapter(diskChapter, for: chapter) {
                    keys.insert(key)
                } else {
                    try? FileManager.default.removeItem(at: cacheFileURL(for: key))
                }
            }
        }

        return keys
    }

    private func hasUsableCachedChapter(for chapter: NovelChapter, key: String) -> Bool {
        if let cached = memory[key] {
            if BookImportService.shared.shouldUseCachedChapter(cached, for: chapter) {
                return true
            }
            memory[key] = nil
        }

        if let diskChapter = readChapterFromDisk(key: key) {
            if BookImportService.shared.shouldUseCachedChapter(diskChapter, for: chapter) {
                return true
            }
            try? FileManager.default.removeItem(at: cacheFileURL(for: key))
        }

        return false
    }

    func prefetch(_ chapters: [NovelChapter]) {
        for chapter in chapters {
            guard chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  chapter.sourceURLString != nil else {
                continue
            }

            let key = cacheKey(for: chapter)
            guard !hasUsableCachedChapter(for: chapter, key: key),
                  inFlight[key] == nil else {
                continue
            }

            inFlight[key] = Task {
                let loaded = try await BookImportService.shared.loadChapter(chapter)
                self.storePrefetchedChapter(loaded, key: key)
                return loaded
            }
        }
    }

    private func storePrefetchedChapter(_ chapter: NovelChapter, key: String) {
        memory[key] = chapter
        writeChapterToDisk(chapter, key: key)
        inFlight[key] = nil
    }

    private func cacheKey(for chapter: NovelChapter) -> String {
        chapter.sourceURLString ?? chapter.id.uuidString
    }

    private func readChapterFromDisk(key: String) -> NovelChapter? {
        let url = cacheFileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NovelChapter.self, from: data)
    }

    private func writeChapterToDisk(_ chapter: NovelChapter, key: String) {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(chapter)
            try data.write(to: cacheFileURL(for: key), options: [.atomic])
        } catch {
#if DEBUG
            debugLog("[ChapterContentCache] write failed: \(error.localizedDescription)")
#endif
        }
    }

    private func cacheFileURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(Self.stableHash(key)).json")
    }

    private nonisolated static func cacheDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("lingyue", isDirectory: true)
            .appendingPathComponent("ChapterContentCache", isDirectory: true)
    }

    private nonisolated static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
