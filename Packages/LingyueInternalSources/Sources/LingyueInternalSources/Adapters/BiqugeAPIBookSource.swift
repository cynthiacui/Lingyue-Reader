import Foundation
import LingyueCore

/// Fast-path adapter for the `bqg*` family of sites whose user-facing
/// pages render via a shared JSON API (`apiqu.cc` / `apige.cc`).
/// The catalog endpoint `/api/booklist?id=<bookID>` returns a flat
/// array of chapter titles; chapter URLs are reconstructed locally
/// from the title order plus the host's `/book/<bookID>/<n>.html`
/// pattern. The rule schema can't express this — there is no per-row
/// detail page to scrape, only an index in the response array.
///
/// Catalog and chapter both go through the same `apiqu.cc` /
/// `apige.cc` mirror set. `fetchDetail` is still a stub — there is
/// no per-book detail endpoint in this API; the legacy
/// `BookImportService` scrapes the user-facing HTML detail page,
/// and a seeded rule will eventually own that step once one exists.
public struct BiqugeAPIBookSource: BookSource {
    public let id: String = "internal:biquge-api"
    public let displayName: String = "笔趣阁 API"

    public var capabilities: SourceCapabilities {
        SourceCapabilities(
            supportsSearch: false,
            showInSearchBar: false,
            supportsBrowserImport: true,
            requiresWebRender: false,
            maxConcurrentRequests: 2,
            requestIntervalMillis: 250
        )
    }

    /// API endpoint hosts tried in order. Caller-supplied URLs use
    /// their own host (typically a `bqg*.…` domain); this adapter
    /// re-routes catalog/chapter reads through the API mirrors.
    static let apiHosts: [String] = ["apiqu.cc", "apige.cc"]

    private let loader: any SourceHTMLLoading

    public init(loader: any SourceHTMLLoading) {
        self.loader = loader
    }

    public func search(_ query: String) async throws -> [BookSearchResult] {
        throw BookSourceError.searchUnsupported
    }

    public func detectBook(in page: WebPageSnapshot) async throws -> BookDetection? {
        nil
    }

    public func fetchDetail(url: URL) async throws -> BookDetail {
        throw BookSourceError.parseFailed(field: "biqugeAPI.detail-not-yet-implemented")
    }

    public func fetchChapter(url: URL) async throws -> ChapterContent {
        guard Self.recognizesURL(url) else {
            throw BookSourceError.unsupportedURL(url)
        }
        guard let ids = Self.bookAndChapterID(from: url) else {
            throw BookSourceError.parseFailed(field: "biqugeAPI.chapterID")
        }

        var lastError: Error?
        for host in Self.apiHosts {
            guard let endpoint = Self.chapterEndpointURL(
                host: host,
                bookID: ids.bookID,
                chapterID: ids.chapterID
            ) else { continue }
            do {
                let snapshot = try await loader.fetchHTML(SourceRequest(
                    url: endpoint,
                    headers: ["Accept": "application/json,text/plain,*/*"]
                ))
                let content = try Self.decodeChapter(json: snapshot.html)
                if !content.paragraphs.isEmpty { return content }
            } catch {
                lastError = error
                continue
            }
        }
        if let lastError = lastError as? BookSourceError { throw lastError }
        if let lastError { throw BookSourceError.loadFailed(reason: String(describing: lastError)) }
        throw BookSourceError.parseFailed(field: "biqugeAPI.empty-chapter")
    }

    public func fetchCatalog(url: URL) async throws -> [ChapterLink] {
        guard Self.recognizesURL(url) else {
            throw BookSourceError.unsupportedURL(url)
        }
        guard let bookID = Self.bookID(from: url), !bookID.isEmpty else {
            throw BookSourceError.parseFailed(field: "biqugeAPI.bookID")
        }

        var lastError: Error?
        for host in Self.apiHosts {
            guard let endpoint = Self.endpointURL(host: host, bookID: bookID) else { continue }
            do {
                let snapshot = try await loader.fetchHTML(SourceRequest(
                    url: endpoint,
                    headers: ["Accept": "application/json,text/plain,*/*"]
                ))
                let links = try Self.decodeCatalog(
                    json: snapshot.html,
                    baseURL: url,
                    bookID: bookID
                )
                if !links.isEmpty { return links }
            } catch {
                lastError = error
                continue
            }
        }
        if let lastError = lastError as? BookSourceError { throw lastError }
        if let lastError { throw BookSourceError.loadFailed(reason: String(describing: lastError)) }
        throw BookSourceError.parseFailed(field: "biqugeAPI.empty-catalog")
    }

    // MARK: - URL parsing

    /// Matches user-facing book URLs on any `bqg*` host containing
    /// `/book/`. Mirrors `BookImportService.isBiqugeAPISource`.
    static func recognizesURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("bqg") && url.absoluteString.contains("/book/")
    }

    /// Extracts the `<bookID>` from a `/book/<bookID>` or
    /// `/book/<bookID>/<chap>.html` path.
    static func bookID(from url: URL) -> String? {
        let path = url.path
        let patterns = [
            #"/book/(\d+)/\d+(?:_\d+)?\.html?$"#,
            #"/book/(\d+)/?$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            if let match = regex.firstMatch(in: path, range: range),
               match.numberOfRanges > 1,
               let captureRange = Range(match.range(at: 1), in: path) {
                return String(path[captureRange])
            }
        }
        return nil
    }

    static func endpointURL(host: String, bookID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/booklist"
        components.queryItems = [URLQueryItem(name: "id", value: bookID)]
        return components.url
    }

    /// Extracts `(bookID, chapterID)` from a `/book/<bookID>/<chap>.html`
    /// or `/book/<bookID>/<chap>_<n>.html` path. The chapter ID is the
    /// integer-only prefix before any underscore — split-paginated
    /// chapter URLs (`123_2.html`) point at the same `chapterid` as
    /// the canonical first page.
    static func bookAndChapterID(from url: URL) -> (bookID: String, chapterID: String)? {
        let path = url.path
        guard let regex = try? NSRegularExpression(pattern: #"/book/(\d+)/(\d+)(?:_\d+)?\.html?$"#) else {
            return nil
        }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        guard let match = regex.firstMatch(in: path, range: range),
              match.numberOfRanges > 2,
              let bookRange = Range(match.range(at: 1), in: path),
              let chapterRange = Range(match.range(at: 2), in: path) else {
            return nil
        }
        return (String(path[bookRange]), String(path[chapterRange]))
    }

    static func chapterEndpointURL(host: String, bookID: String, chapterID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/chapter"
        components.queryItems = [
            URLQueryItem(name: "id", value: bookID),
            URLQueryItem(name: "chapterid", value: chapterID)
        ]
        return components.url
    }

    // MARK: - Response decoding

    private struct CatalogResponse: Decodable {
        let list: [String]
    }

    static func decodeCatalog(json: String, baseURL: URL, bookID: String) throws -> [ChapterLink] {
        guard let data = json.data(using: .utf8) else {
            throw BookSourceError.parseFailed(field: "biqugeAPI.encoding")
        }
        let response: CatalogResponse
        do {
            response = try JSONDecoder().decode(CatalogResponse.self, from: data)
        } catch {
            throw BookSourceError.parseFailed(field: "biqugeAPI.json")
        }
        guard !response.list.isEmpty else { return [] }
        return response.list.enumerated().compactMap { offset, rawTitle in
            let title = cleanTitle(rawTitle)
            guard !title.isEmpty else { return nil }
            // Biquge chapter URLs are 1-indexed: list[0] → /<bookID>/1.html.
            let chapterID = offset + 1
            guard let chapterURL = absoluteURL(
                from: "/book/\(bookID)/\(chapterID).html",
                baseURL: baseURL
            ) else { return nil }
            return ChapterLink(title: title, url: chapterURL, index: offset)
        }
    }

    private struct ChapterResponse: Decodable {
        let chaptername: String?
        let txt: String?
    }

    static func decodeChapter(json: String) throws -> ChapterContent {
        guard let data = json.data(using: .utf8) else {
            throw BookSourceError.parseFailed(field: "biqugeAPI.encoding")
        }
        let response: ChapterResponse
        do {
            response = try JSONDecoder().decode(ChapterResponse.self, from: data)
        } catch {
            throw BookSourceError.parseFailed(field: "biqugeAPI.json")
        }
        let title = cleanTitle(response.chaptername ?? "")
        let paragraphs = splitChapterBody(response.txt ?? "")
        return ChapterContent(title: title, paragraphs: paragraphs)
    }

    /// Splits the Biquge API's `txt` field into reader-ready paragraphs.
    /// The field is *near*-plaintext: paragraphs are separated by
    /// `\r\n` (sometimes doubled), with the occasional `<br>` or
    /// `<br/>` left behind and named/numeric HTML entities sprinkled
    /// in. We:
    ///  1. Normalize line endings + `<br>` tags into `\n`.
    ///  2. Strip residual HTML tags (rare but possible — ad spans).
    ///  3. Decode the named entities we observe in practice.
    ///  4. Drop common boilerplate ("请收藏本站…") and nav-only lines
    ///     by exact match — the API serves these inline in `txt` on
    ///     a handful of mirror hosts.
    ///  5. Trim each remaining line and discard empties.
    /// The result is consumed verbatim by the reader's pagination engine.
    static func splitChapterBody(_ raw: String) -> [String] {
        var text = raw
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(
            of: #"<\s*br\s*/?\s*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = decodeNamedEntities(text)

        let lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !isBoilerplate($0) }
        return lines
    }

    private static let boilerplateFragments: [String] = [
        "请收藏本站", "請收藏本站", "加入书签", "加入書簽",
        "返回目录", "返回目錄", "返回书架", "返回書架",
        "上一章", "下一章", "上一頁", "下一頁",
        "最新网址", "最新網址", "手机用户", "手機用戶",
        "本章未完", "点击报错", "點擊報錯",
        "天才一秒记住", "天才一秒鐘記住",
        "无弹窗", "無彈窗", "看本书最新章节", "看本書最新章節",
        "字体大小", "字體大小"
    ]

    private static func isBoilerplate(_ line: String) -> Bool {
        // Boilerplate fragments are always at line scope and short —
        // a paragraph that mentions "上一章" inside dialogue would be
        // a false positive, but the API never serves dialogue in
        // that form; the fragments only appear in standalone footer
        // lines. Cheap upper-bound guard keeps us out of long paras.
        guard line.count <= 80 else { return false }
        return boilerplateFragments.contains { line.localizedCaseInsensitiveContains($0) }
    }

    private static func decodeNamedEntities(_ text: String) -> String {
        var decoded = text
        let map: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&nbsp;", " "),
            ("&ldquo;", "\u{201C}"),
            ("&rdquo;", "\u{201D}"),
            ("&lsquo;", "\u{2018}"),
            ("&rsquo;", "\u{2019}"),
            ("&hellip;", "\u{2026}"),
            ("&mdash;", "\u{2014}"),
            ("&ndash;", "\u{2013}")
        ]
        for (entity, value) in map {
            decoded = decoded.replacingOccurrences(of: entity, with: value)
        }
        return decoded
    }

    private static func cleanTitle(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func absoluteURL(from href: String, baseURL: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(
            url: URL(string: trimmed, relativeTo: baseURL)?.absoluteURL ?? baseURL,
            resolvingAgainstBaseURL: true
        ) else {
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
}
