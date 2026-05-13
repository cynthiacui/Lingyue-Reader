import Foundation
import LingyueCore

/// First fast-path adapter — covers the catalog endpoint of 就爱读小说
/// (5dxs.net / adxs.net), which is genuinely bespoke and can't be
/// expressed with the rule schema yet.
///
/// The site's mobile UI paginates the chapter catalog ten-per-page on the
/// HTML detail page, but exposes an undocumented `/ajaxService` JSON
/// endpoint that returns the full list in one request. We hit that
/// endpoint via the shared `SourceHTMLLoading` so request throttling +
/// User-Agent are applied the same way as every other fetch in the
/// engine. The response body is JSON — the loader returns it through
/// `WebPageSnapshot.html` (the field is named for the dominant case;
/// the bytes round-trip verbatim).
///
/// What this adapter does **not** cover yet: search, detection, detail,
/// and chapter parsing. Those fall through to standard rule-driven flows
/// — once a seeded rule for 5dxs exists, callers should be wired to use
/// the rule for everything except `fetchCatalog`, where this adapter
/// stays definitive. Until then, the unsupported methods throw narrow
/// errors so the caller can fall back to its legacy parser.
///
/// Because the search/detail/chapter methods are stubs, this adapter is
/// **not** included in `InternalSourceRegistry.fastPathAdapters` by
/// default. The Phase 2.4 cutover will swap callers onto the registry
/// for catalog-only routes when the URL host matches one of `hosts`, and
/// keep the legacy path for everything else.
public struct FivedxsBookSource: BookSource {
    public let id: String = "internal:5dxs"
    public let displayName: String = "就爱读小说"

    public var capabilities: SourceCapabilities {
        SourceCapabilities(
            supportsSearch: false,
            showInSearchBar: false,
            supportsBrowserImport: true,
            requiresWebRender: false,
            maxConcurrentRequests: 2,
            requestIntervalMillis: 200
        )
    }

    /// Hosts this adapter recognizes. Domain is lower-cased before
    /// comparison; subdomains (`m.5dxs.net`, `www.5dxs.net`) match when
    /// the suffix matches.
    public static let hosts: [String] = ["5dxs.net", "adxs.net"]

    /// Endpoints tried in order. `m.5dxs.net` is the canonical mobile
    /// host and serves the JSON straight; `m.adxs.net` is the mirror
    /// some users land on after a regional redirect. Falling through to
    /// the mirror covers the case where the primary returns an empty
    /// `items` array but the mirror has the same book under the same id.
    private static let endpointTemplates: [String] = [
        "https://m.5dxs.net/ajaxService?action=chapterlist&articleno={id}&index=0&size=20000&sort=1",
        "https://m.adxs.net/ajaxService?action=chapterlist&articleno={id}&index=0&size=20000&sort=1"
    ]

    private let loader: any SourceHTMLLoading

    public init(loader: any SourceHTMLLoading) {
        self.loader = loader
    }

    public func search(_ query: String) async throws -> [BookSearchResult] {
        throw BookSourceError.searchUnsupported
    }

    public func detectBook(in page: WebPageSnapshot) async throws -> BookDetection? {
        // Detection on the bare page is delegated to the rule-based source
        // once a seeded rule exists; refusing here keeps detection
        // results deterministic and prevents this adapter from
        // out-voting a (forthcoming) rule.
        nil
    }

    public func fetchDetail(url: URL) async throws -> BookDetail {
        throw BookSourceError.parseFailed(field: "fivedxs.detail-not-yet-implemented")
    }

    public func fetchChapter(url: URL) async throws -> ChapterContent {
        throw BookSourceError.parseFailed(field: "fivedxs.chapter-not-yet-implemented")
    }

    public func fetchCatalog(url: URL) async throws -> [ChapterLink] {
        guard let host = url.host?.lowercased(),
              Self.hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw BookSourceError.unsupportedURL(url)
        }
        guard let bookID = Self.bookID(from: url), !bookID.isEmpty else {
            throw BookSourceError.parseFailed(field: "fivedxs.bookID")
        }

        var lastError: Error?
        for template in Self.endpointTemplates {
            let endpoint = template.replacingOccurrences(of: "{id}", with: bookID)
            guard let endpointURL = URL(string: endpoint) else { continue }
            do {
                let snapshot = try await loader.fetchHTML(SourceRequest(url: endpointURL))
                let links = try Self.decodeCatalog(
                    json: snapshot.html,
                    baseURL: url
                )
                if !links.isEmpty { return links }
            } catch {
                lastError = error
                continue
            }
        }
        if let lastError = lastError as? BookSourceError { throw lastError }
        if let lastError { throw BookSourceError.loadFailed(reason: String(describing: lastError)) }
        throw BookSourceError.parseFailed(field: "fivedxs.empty-catalog")
    }

    // MARK: - Parsing

    /// Pulls the `<bookid>` segment out of a 5dxs URL. The site uses
    /// jieqi-style paths — `/info/<sub>/<id>.html` for detail pages and
    /// `/reader/<sub>/<id>/<chapter>.html` for reader pages. We accept
    /// either; both return the same article id.
    static func bookID(from url: URL) -> String? {
        let path = url.path
        let patterns = [
            #"^/info/\d+/(\d+)\.html?$"#,
            #"^/reader/\d+/(\d+)/\d+\.html?$"#
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

    private struct CatalogResponse: Decodable {
        let items: [Item]?
        struct Item: Decodable {
            let chaptername: String
            let url: String
        }
    }

    static func decodeCatalog(json: String, baseURL: URL) throws -> [ChapterLink] {
        guard let data = json.data(using: .utf8) else {
            throw BookSourceError.parseFailed(field: "fivedxs.encoding")
        }
        let response: CatalogResponse
        do {
            response = try JSONDecoder().decode(CatalogResponse.self, from: data)
        } catch {
            throw BookSourceError.parseFailed(field: "fivedxs.json")
        }
        guard let items = response.items, !items.isEmpty else {
            return []
        }
        return items.enumerated().compactMap { offset, item in
            let title = cleanTitle(item.chaptername)
            guard !title.isEmpty,
                  let chapterURL = absoluteURL(from: item.url, baseURL: baseURL) else {
                return nil
            }
            return ChapterLink(title: title, url: chapterURL, index: offset)
        }
    }

    private static func cleanTitle(_ raw: String) -> String {
        // Mirrors `BookImportService.cleanText` for the common cases the
        // catalog endpoint produces — HTML entities (numeric + named)
        // and stray whitespace. We keep the helper local so the engine
        // dependency surface stays minimal; if a third adapter needs
        // the same logic we'll hoist it into LingyueCore.
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
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.lowercased().hasPrefix("javascript:") else {
            return nil
        }
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
