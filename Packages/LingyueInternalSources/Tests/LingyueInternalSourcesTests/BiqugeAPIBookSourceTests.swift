import XCTest
@testable import LingyueInternalSources
import LingyueCore

/// Unit tests for `BiqugeAPIBookSource`. Catalog endpoint only —
/// chapter content is still served by the legacy parser.
final class BiqugeAPIBookSourceTests: XCTestCase {

    // MARK: - URL parsing

    func testRecognizesBqgHostBookURLs() {
        XCTAssertTrue(BiqugeAPIBookSource.recognizesURL(URL(string: "https://bqg99.cc/book/12345/")!))
        XCTAssertTrue(BiqugeAPIBookSource.recognizesURL(URL(string: "https://m.bqg5.cc/book/12345/1.html")!))
        XCTAssertTrue(BiqugeAPIBookSource.recognizesURL(URL(string: "https://www.bqgi.cc/book/12345/1_2.html")!))
    }

    func testRejectsNonBqgURLs() {
        XCTAssertFalse(BiqugeAPIBookSource.recognizesURL(URL(string: "https://example.com/book/12345/")!))
        XCTAssertFalse(BiqugeAPIBookSource.recognizesURL(URL(string: "https://bqg99.cc/category/scifi")!))
    }

    func testBookIDExtraction() {
        XCTAssertEqual(
            BiqugeAPIBookSource.bookID(from: URL(string: "https://bqg99.cc/book/12345/")!),
            "12345"
        )
        XCTAssertEqual(
            BiqugeAPIBookSource.bookID(from: URL(string: "https://bqg99.cc/book/12345/7.html")!),
            "12345"
        )
        XCTAssertEqual(
            BiqugeAPIBookSource.bookID(from: URL(string: "https://bqg99.cc/book/12345/7_2.html")!),
            "12345"
        )
        XCTAssertNil(BiqugeAPIBookSource.bookID(from: URL(string: "https://bqg99.cc/category/scifi")!))
    }

    func testEndpointURLBuildsAPIPathWithQuery() {
        let url = BiqugeAPIBookSource.endpointURL(host: "apiqu.cc", bookID: "12345")
        XCTAssertEqual(
            url?.absoluteString,
            "https://apiqu.cc/api/booklist?id=12345"
        )
    }

    // MARK: - fetchCatalog

    func testFetchCatalogDecodesListIntoChapterLinks() async throws {
        let loader = StubLoader(responses: [
            .success(.init(html: Self.canonicalJSON, finalURL: URL(string: "https://apiqu.cc/api/booklist?id=12345")!))
        ])
        let source = BiqugeAPIBookSource(loader: loader)

        let bookURL = URL(string: "https://bqg99.cc/book/12345/")!
        let links = try await source.fetchCatalog(url: bookURL)

        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links[0].title, "第一章 序章")
        XCTAssertEqual(links[0].url.absoluteString, "https://bqg99.cc/book/12345/1.html")
        XCTAssertEqual(links[0].index, 0)
        XCTAssertEqual(links[1].url.absoluteString, "https://bqg99.cc/book/12345/2.html")
        XCTAssertEqual(links[1].index, 1)
        XCTAssertEqual(links[2].url.absoluteString, "https://bqg99.cc/book/12345/3.html")
        XCTAssertEqual(links[2].index, 2)

        let requested = await loader.requestedURLs()
        XCTAssertEqual(requested.first?.host, "apiqu.cc")
        XCTAssertEqual(requested.first?.path, "/api/booklist")
    }

    func testFetchCatalogFallsBackToSecondAPIHostOnError() async throws {
        let loader = StubLoader(responses: [
            .failure(BookSourceError.loadFailed(reason: "apiqu down")),
            .success(.init(html: Self.canonicalJSON, finalURL: URL(string: "https://apige.cc/api/booklist?id=12345")!))
        ])
        let source = BiqugeAPIBookSource(loader: loader)

        let bookURL = URL(string: "https://bqg99.cc/book/12345/")!
        let links = try await source.fetchCatalog(url: bookURL)
        XCTAssertEqual(links.count, 3)

        let requested = await loader.requestedURLs()
        XCTAssertEqual(requested.map { $0.host }, ["apiqu.cc", "apige.cc"])
    }

    func testFetchCatalogPreservesUserFacingHostInChapterURLs() async throws {
        let loader = StubLoader(responses: [
            .success(.init(html: Self.canonicalJSON, finalURL: URL(string: "https://apiqu.cc/api/booklist?id=12345")!))
        ])
        let source = BiqugeAPIBookSource(loader: loader)

        let bookURL = URL(string: "https://m.bqg5.cc/book/12345/")!
        let links = try await source.fetchCatalog(url: bookURL)
        XCTAssertEqual(links[0].url.host, "m.bqg5.cc")
    }

    func testFetchCatalogThrowsForUnsupportedHost() async {
        let source = BiqugeAPIBookSource(loader: StubLoader(responses: []))
        do {
            _ = try await source.fetchCatalog(url: URL(string: "https://example.com/book/12345/")!)
            XCTFail("Expected unsupportedURL")
        } catch BookSourceError.unsupportedURL {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchCatalogThrowsWhenBookIDMissing() async {
        let source = BiqugeAPIBookSource(loader: StubLoader(responses: []))
        // bqg host but no /book/ID path
        do {
            _ = try await source.fetchCatalog(url: URL(string: "https://bqg99.cc/book/foo/")!)
            XCTFail("Expected parseFailed")
        } catch BookSourceError.parseFailed(let field) {
            XCTAssertEqual(field, "biqugeAPI.bookID")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchCatalogPropagatesLastErrorOnTotalFailure() async {
        let loader = StubLoader(responses: [
            .failure(BookSourceError.loadFailed(reason: "primary")),
            .failure(BookSourceError.loadFailed(reason: "mirror"))
        ])
        let source = BiqugeAPIBookSource(loader: loader)

        do {
            _ = try await source.fetchCatalog(url: URL(string: "https://bqg99.cc/book/12345/")!)
            XCTFail("Expected error")
        } catch BookSourceError.loadFailed(let reason) {
            XCTAssertTrue(reason.contains("mirror"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchCatalogReturnsEmptyCatalogErrorWhenBothHostsEmpty() async {
        let loader = StubLoader(responses: [
            .success(.init(html: #"{"list":[]}"#, finalURL: URL(string: "https://apiqu.cc/")!)),
            .success(.init(html: #"{"list":[]}"#, finalURL: URL(string: "https://apige.cc/")!))
        ])
        let source = BiqugeAPIBookSource(loader: loader)

        do {
            _ = try await source.fetchCatalog(url: URL(string: "https://bqg99.cc/book/12345/")!)
            XCTFail("Expected parseFailed")
        } catch BookSourceError.parseFailed(let field) {
            XCTAssertEqual(field, "biqugeAPI.empty-catalog")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchCatalogSendsAcceptHeader() async throws {
        let loader = StubLoader(responses: [
            .success(.init(html: Self.canonicalJSON, finalURL: URL(string: "https://apiqu.cc/")!))
        ])
        let source = BiqugeAPIBookSource(loader: loader)
        _ = try await source.fetchCatalog(url: URL(string: "https://bqg99.cc/book/12345/")!)

        let headers = await loader.headersForRequest(at: 0)
        XCTAssertEqual(headers?["Accept"], "application/json,text/plain,*/*")
    }

    func testFetchCatalogSkipsEmptyTitlesInResponse() async throws {
        let json = """
        {"list": ["第一章 序章", "", "第三章 落幕"]}
        """
        let loader = StubLoader(responses: [
            .success(.init(html: json, finalURL: URL(string: "https://apiqu.cc/")!))
        ])
        let source = BiqugeAPIBookSource(loader: loader)
        let links = try await source.fetchCatalog(url: URL(string: "https://bqg99.cc/book/12345/")!)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].title, "第一章 序章")
        XCTAssertEqual(links[1].title, "第三章 落幕")
        // Index is 0-based on the *response* position, so the gap from
        // the empty title still slots links into 0 and 2.
        XCTAssertEqual(links[0].index, 0)
        XCTAssertEqual(links[1].index, 2)
        // But the chapter URL uses 1-based response position too, so
        // the second link points to /3.html (the third response slot).
        XCTAssertEqual(links[1].url.absoluteString, "https://bqg99.cc/book/12345/3.html")
    }

    // MARK: - Stub-throwing methods

    func testSearchThrowsSearchUnsupported() async {
        let source = BiqugeAPIBookSource(loader: StubLoader(responses: []))
        do {
            _ = try await source.search("anything")
            XCTFail("Expected searchUnsupported")
        } catch BookSourceError.searchUnsupported {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDetectBookReturnsNil() async throws {
        let source = BiqugeAPIBookSource(loader: StubLoader(responses: []))
        let page = WebPageSnapshot(html: "<html></html>", finalURL: URL(string: "https://bqg99.cc/")!)
        let detection = try await source.detectBook(in: page)
        XCTAssertNil(detection)
    }

    func testFetchDetailThrowsParseFailed() async {
        let source = BiqugeAPIBookSource(loader: StubLoader(responses: []))
        do {
            _ = try await source.fetchDetail(url: URL(string: "https://bqg99.cc/book/12345/")!)
            XCTFail("Expected parseFailed")
        } catch BookSourceError.parseFailed {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - fetchChapter

    func testBookAndChapterIDExtraction() {
        let ids = BiqugeAPIBookSource.bookAndChapterID(
            from: URL(string: "https://bqg99.cc/book/12345/7.html")!
        )
        XCTAssertEqual(ids?.bookID, "12345")
        XCTAssertEqual(ids?.chapterID, "7")

        // Split-paginated chapter URLs (_2 suffix) drop the suffix.
        let split = BiqugeAPIBookSource.bookAndChapterID(
            from: URL(string: "https://bqg99.cc/book/12345/7_2.html")!
        )
        XCTAssertEqual(split?.chapterID, "7")

        // Book-only path has no chapter.
        XCTAssertNil(BiqugeAPIBookSource.bookAndChapterID(
            from: URL(string: "https://bqg99.cc/book/12345/")!
        ))
    }

    func testChapterEndpointURLBuildsAPIPathWithIDs() {
        let url = BiqugeAPIBookSource.chapterEndpointURL(
            host: "apiqu.cc", bookID: "12345", chapterID: "7"
        )
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "apiqu.cc")
        XCTAssertEqual(url?.path, "/api/chapter")
        // Query item order is preserved by URLComponents.
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items, [
            URLQueryItem(name: "id", value: "12345"),
            URLQueryItem(name: "chapterid", value: "7")
        ])
    }

    func testFetchChapterDecodesJSONIntoChapterContent() async throws {
        let json = """
        {
          "chaptername": "第一章 序章",
          "txt": "第一段。\\r\\n第二段，含&nbsp;空格。\\r\\n第三段。"
        }
        """
        let loader = StubLoader(responses: [
            .success(.init(html: json, finalURL: URL(string: "https://apiqu.cc/api/chapter")!))
        ])
        let source = BiqugeAPIBookSource(loader: loader)
        let content = try await source.fetchChapter(
            url: URL(string: "https://bqg99.cc/book/12345/1.html")!
        )

        XCTAssertEqual(content.title, "第一章 序章")
        XCTAssertEqual(content.paragraphs.count, 3)
        XCTAssertEqual(content.paragraphs[0], "第一段。")
        XCTAssertEqual(content.paragraphs[1], "第二段，含 空格。")
        XCTAssertEqual(content.paragraphs[2], "第三段。")

        let requested = await loader.requestedURLs()
        XCTAssertEqual(requested.first?.path, "/api/chapter")
        XCTAssertTrue(requested.first?.query?.contains("id=12345") ?? false)
        XCTAssertTrue(requested.first?.query?.contains("chapterid=1") ?? false)
    }

    func testFetchChapterStripsBrTagsAndResidualHTML() async throws {
        let json = """
        {"chaptername": "第二章", "txt": "<p>段一。</p><br/>段二。<br><br>段三。"}
        """
        let loader = StubLoader(responses: [
            .success(.init(html: json, finalURL: URL(string: "https://apiqu.cc/")!))
        ])
        let source = BiqugeAPIBookSource(loader: loader)
        let content = try await source.fetchChapter(
            url: URL(string: "https://bqg99.cc/book/12345/2.html")!
        )
        XCTAssertEqual(content.paragraphs, ["段一。", "段二。", "段三。"])
    }

    func testFetchChapterDropsBoilerplateLines() async throws {
        let json = """
        {
          "chaptername": "第三章",
          "txt": "正文段落一。\\r\\n请收藏本站！\\r\\n正文段落二。\\r\\n上一章 下一章\\r\\n正文段落三。"
        }
        """
        let loader = StubLoader(responses: [
            .success(.init(html: json, finalURL: URL(string: "https://apiqu.cc/")!))
        ])
        let source = BiqugeAPIBookSource(loader: loader)
        let content = try await source.fetchChapter(
            url: URL(string: "https://bqg99.cc/book/12345/3.html")!
        )
        XCTAssertEqual(content.paragraphs, ["正文段落一。", "正文段落二。", "正文段落三。"])
    }

    func testFetchChapterFallsBackToMirrorOnError() async throws {
        let goodJSON = #"{"chaptername":"x","txt":"段一。\r\n段二。"}"#
        let loader = StubLoader(responses: [
            .failure(BookSourceError.loadFailed(reason: "apiqu down")),
            .success(.init(html: goodJSON, finalURL: URL(string: "https://apige.cc/")!))
        ])
        let source = BiqugeAPIBookSource(loader: loader)
        let content = try await source.fetchChapter(
            url: URL(string: "https://bqg99.cc/book/12345/4.html")!
        )
        XCTAssertEqual(content.paragraphs.count, 2)
        let requested = await loader.requestedURLs()
        XCTAssertEqual(requested.map(\.host), ["apiqu.cc", "apige.cc"])
    }

    func testFetchChapterThrowsForUnsupportedHost() async {
        let source = BiqugeAPIBookSource(loader: StubLoader(responses: []))
        do {
            _ = try await source.fetchChapter(url: URL(string: "https://example.com/book/12345/1.html")!)
            XCTFail("Expected unsupportedURL")
        } catch BookSourceError.unsupportedURL {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchChapterThrowsWhenChapterIDMissing() async {
        let source = BiqugeAPIBookSource(loader: StubLoader(responses: []))
        do {
            _ = try await source.fetchChapter(url: URL(string: "https://bqg99.cc/book/12345/")!)
            XCTFail("Expected parseFailed")
        } catch BookSourceError.parseFailed(let field) {
            XCTAssertEqual(field, "biqugeAPI.chapterID")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchChapterThrowsEmptyChapterWhenBothHostsReturnNoText() async {
        let emptyJSON = #"{"chaptername":"x","txt":""}"#
        let loader = StubLoader(responses: [
            .success(.init(html: emptyJSON, finalURL: URL(string: "https://apiqu.cc/")!)),
            .success(.init(html: emptyJSON, finalURL: URL(string: "https://apige.cc/")!))
        ])
        let source = BiqugeAPIBookSource(loader: loader)
        do {
            _ = try await source.fetchChapter(url: URL(string: "https://bqg99.cc/book/12345/1.html")!)
            XCTFail("Expected parseFailed")
        } catch BookSourceError.parseFailed(let field) {
            XCTAssertEqual(field, "biqugeAPI.empty-chapter")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchChapterFollowsSplitPaginatedURLsToSameChapterID() async throws {
        let json = #"{"chaptername":"x","txt":"段一。\r\n段二。"}"#
        let loader = StubLoader(responses: [
            .success(.init(html: json, finalURL: URL(string: "https://apiqu.cc/")!))
        ])
        let source = BiqugeAPIBookSource(loader: loader)
        _ = try await source.fetchChapter(
            url: URL(string: "https://bqg99.cc/book/12345/7_2.html")!
        )
        let requested = await loader.requestedURLs()
        // The `_2` page-2 suffix maps back to chapter 7 — same API call.
        XCTAssertTrue(requested.first?.query?.contains("chapterid=7") ?? false)
    }

    func testDecodesNamedHTMLEntitiesInBody() async throws {
        let json = #"""
        {"chaptername":"x","txt":"&ldquo;你好&rdquo;\r\n&hellip;终章。"}
        """#
        let loader = StubLoader(responses: [
            .success(.init(html: json, finalURL: URL(string: "https://apiqu.cc/")!))
        ])
        let source = BiqugeAPIBookSource(loader: loader)
        let content = try await source.fetchChapter(
            url: URL(string: "https://bqg99.cc/book/12345/1.html")!
        )
        XCTAssertEqual(content.paragraphs[0], "\u{201C}你好\u{201D}")
        XCTAssertEqual(content.paragraphs[1], "\u{2026}终章。")
    }

    // MARK: - Identity / capability

    func testCapabilities() {
        let source = BiqugeAPIBookSource(loader: StubLoader(responses: []))
        XCTAssertEqual(source.id, "internal:biquge-api")
        XCTAssertEqual(source.displayName, "笔趣阁 API")
        XCTAssertFalse(source.capabilities.supportsSearch)
        XCTAssertFalse(source.capabilities.showInSearchBar)
        XCTAssertTrue(source.capabilities.supportsBrowserImport)
        XCTAssertFalse(source.capabilities.requiresWebRender)
    }

    // MARK: - Fixtures

    private static let canonicalJSON = """
    {
      "list": ["第一章 序章", "第二章 风起", "第三章 落幕"]
    }
    """
}

// MARK: - Test helpers

private actor StubLoader: SourceHTMLLoading {
    enum Response {
        case success(WebPageSnapshot)
        case failure(Error)
    }

    private var responses: [Response]
    private var requests: [SourceRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        requests.append(request)
        guard !responses.isEmpty else {
            throw BookSourceError.loadFailed(reason: "stub-exhausted")
        }
        let next = responses.removeFirst()
        switch next {
        case .success(let snapshot): return snapshot
        case .failure(let error): throw error
        }
    }

    func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        throw BookSourceError.loadFailed(reason: "stub-render-unsupported")
    }

    func requestedURLs() -> [URL] { requests.map(\.url) }
    func headersForRequest(at index: Int) -> [String: String]? {
        guard requests.indices.contains(index) else { return nil }
        return requests[index].headers
    }
}
