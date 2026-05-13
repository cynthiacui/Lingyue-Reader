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
/// Scope: catalog only. Chapter content (`/api/chapter?id=<bookID>&chapterid=<chapID>`)
/// follows a different JSON shape and lands in a later commit. The
/// stubs throw narrow errors so the legacy `BookImportService` can
/// keep covering chapter fetches until then.
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
        throw BookSourceError.parseFailed(field: "biqugeAPI.chapter-not-yet-implemented")
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
