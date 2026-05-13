import XCTest
@testable import LingyueInternalSources
import LingyueCore

/// Unit tests for `FivedxsBookSource`. We exercise the catalog endpoint
/// with a stub loader returning canned JSON — no network. The other
/// `BookSource` methods are stub-throws, so we assert their error
/// shapes too so a regression that silently starts succeeding gets
/// caught.
final class FivedxsBookSourceTests: XCTestCase {

    // MARK: - fetchCatalog

    func testFetchCatalogDecodesJSONIntoChapterLinks() async throws {
        let loader = StubLoader(responses: [
            .success(.init(html: Self.canonicalJSON, finalURL: Self.primaryEndpoint))
        ])
        let source = FivedxsBookSource(loader: loader)

        let detailURL = URL(string: "https://m.5dxs.net/info/100/12345.html")!
        let links = try await source.fetchCatalog(url: detailURL)

        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links[0].title, "第一章 引子")
        XCTAssertEqual(links[0].url.absoluteString, "https://m.5dxs.net/reader/100/12345/1.html")
        XCTAssertEqual(links[0].index, 0)
        XCTAssertEqual(links[1].title, "第二章 \"重逢\"")
        XCTAssertEqual(links[1].index, 1)
        XCTAssertEqual(links[2].url.absoluteString, "https://m.5dxs.net/reader/100/12345/3.html")
        XCTAssertEqual(links[2].index, 2)

        let requested = await loader.requestedURLs()
        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(
            requested.first?.absoluteString,
            "https://m.5dxs.net/ajaxService?action=chapterlist&articleno=12345&index=0&size=20000&sort=1"
        )
    }

    func testFetchCatalogFallsBackToMirrorEndpointOnEmptyPrimary() async throws {
        let loader = StubLoader(responses: [
            .success(.init(html: Self.emptyJSON, finalURL: Self.primaryEndpoint)),
            .success(.init(html: Self.canonicalJSON, finalURL: Self.mirrorEndpoint))
        ])
        let source = FivedxsBookSource(loader: loader)

        let detailURL = URL(string: "https://m.5dxs.net/info/100/12345.html")!
        let links = try await source.fetchCatalog(url: detailURL)
        XCTAssertEqual(links.count, 3)

        let requested = await loader.requestedURLs()
        XCTAssertEqual(requested.count, 2)
        XCTAssertEqual(requested.first?.host, "m.5dxs.net")
        XCTAssertEqual(requested.last?.host, "m.adxs.net")
    }

    func testFetchCatalogFallsBackToMirrorOnPrimaryError() async throws {
        let loader = StubLoader(responses: [
            .failure(BookSourceError.loadFailed(reason: "timeout")),
            .success(.init(html: Self.canonicalJSON, finalURL: Self.mirrorEndpoint))
        ])
        let source = FivedxsBookSource(loader: loader)

        let detailURL = URL(string: "https://m.5dxs.net/info/100/12345.html")!
        let links = try await source.fetchCatalog(url: detailURL)
        XCTAssertEqual(links.count, 3)
    }

    func testFetchCatalogThrowsForUnsupportedHost() async throws {
        let loader = StubLoader(responses: [])
        let source = FivedxsBookSource(loader: loader)
        let badURL = URL(string: "https://example.com/info/100/12345.html")!

        do {
            _ = try await source.fetchCatalog(url: badURL)
            XCTFail("Expected unsupportedURL error")
        } catch BookSourceError.unsupportedURL(let url) {
            XCTAssertEqual(url, badURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchCatalogThrowsWhenBookIDMissingFromURL() async throws {
        let loader = StubLoader(responses: [])
        let source = FivedxsBookSource(loader: loader)
        let urlWithoutID = URL(string: "https://m.5dxs.net/home.html")!

        do {
            _ = try await source.fetchCatalog(url: urlWithoutID)
            XCTFail("Expected parseFailed error")
        } catch BookSourceError.parseFailed(let field) {
            XCTAssertEqual(field, "fivedxs.bookID")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchCatalogRecognizesReaderURLs() async throws {
        let loader = StubLoader(responses: [
            .success(.init(html: Self.canonicalJSON, finalURL: Self.primaryEndpoint))
        ])
        let source = FivedxsBookSource(loader: loader)
        let readerURL = URL(string: "https://m.5dxs.net/reader/100/12345/2.html")!

        let links = try await source.fetchCatalog(url: readerURL)
        XCTAssertEqual(links.count, 3)
    }

    func testFetchCatalogPropagatesLastErrorWhenAllEndpointsFail() async throws {
        let loader = StubLoader(responses: [
            .failure(BookSourceError.loadFailed(reason: "primary down")),
            .failure(BookSourceError.loadFailed(reason: "mirror down"))
        ])
        let source = FivedxsBookSource(loader: loader)

        do {
            _ = try await source.fetchCatalog(
                url: URL(string: "https://m.5dxs.net/info/100/12345.html")!
            )
            XCTFail("Expected error")
        } catch BookSourceError.loadFailed(let reason) {
            XCTAssertTrue(reason.contains("mirror down"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchCatalogThrowsParseFailedOnAllEmptyResponses() async throws {
        let loader = StubLoader(responses: [
            .success(.init(html: Self.emptyJSON, finalURL: Self.primaryEndpoint)),
            .success(.init(html: Self.emptyJSON, finalURL: Self.mirrorEndpoint))
        ])
        let source = FivedxsBookSource(loader: loader)

        do {
            _ = try await source.fetchCatalog(
                url: URL(string: "https://m.5dxs.net/info/100/12345.html")!
            )
            XCTFail("Expected parseFailed error")
        } catch BookSourceError.parseFailed(let field) {
            XCTAssertEqual(field, "fivedxs.empty-catalog")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchCatalogAcceptsAdxsMirrorHost() async throws {
        let loader = StubLoader(responses: [
            .success(.init(html: Self.canonicalJSON, finalURL: Self.mirrorEndpoint))
        ])
        let source = FivedxsBookSource(loader: loader)
        let url = URL(string: "https://m.adxs.net/info/100/12345.html")!

        let links = try await source.fetchCatalog(url: url)
        XCTAssertEqual(links.count, 3)
        // The base URL drives final scheme/host resolution; for adxs
        // input the engine should produce adxs-rooted links.
        XCTAssertEqual(links[0].url.host, "m.adxs.net")
    }

    // MARK: - Stub-throwing methods (regression guards)

    func testSearchThrowsSearchUnsupported() async {
        let source = FivedxsBookSource(loader: StubLoader(responses: []))
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
        let source = FivedxsBookSource(loader: StubLoader(responses: []))
        let page = WebPageSnapshot(html: "<html></html>", finalURL: URL(string: "https://m.5dxs.net/")!)
        let detection = try await source.detectBook(in: page)
        XCTAssertNil(detection)
    }

    func testFetchDetailThrowsParseFailed() async {
        let source = FivedxsBookSource(loader: StubLoader(responses: []))
        do {
            _ = try await source.fetchDetail(url: URL(string: "https://m.5dxs.net/info/100/12345.html")!)
            XCTFail("Expected parseFailed")
        } catch BookSourceError.parseFailed {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchChapterThrowsParseFailed() async {
        let source = FivedxsBookSource(loader: StubLoader(responses: []))
        do {
            _ = try await source.fetchChapter(url: URL(string: "https://m.5dxs.net/reader/100/12345/1.html")!)
            XCTFail("Expected parseFailed")
        } catch BookSourceError.parseFailed {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Identity / capability

    func testCapabilities() {
        let source = FivedxsBookSource(loader: StubLoader(responses: []))
        XCTAssertEqual(source.id, "internal:5dxs")
        XCTAssertEqual(source.displayName, "就爱读小说")
        XCTAssertFalse(source.capabilities.supportsSearch)
        XCTAssertFalse(source.capabilities.showInSearchBar)
        XCTAssertTrue(source.capabilities.supportsBrowserImport)
        XCTAssertFalse(source.capabilities.requiresWebRender)
    }

    // MARK: - Fixtures

    private static let primaryEndpoint = URL(string: "https://m.5dxs.net/ajaxService")!
    private static let mirrorEndpoint = URL(string: "https://m.adxs.net/ajaxService")!

    private static let canonicalJSON = """
    {
      "items": [
        {"chaptername": "第一章 引子", "url": "/reader/100/12345/1.html"},
        {"chaptername": "第二章 &quot;重逢&quot;", "url": "/reader/100/12345/2.html"},
        {"chaptername": "第三章 落幕", "url": "/reader/100/12345/3.html"}
      ]
    }
    """

    private static let emptyJSON = """
    {"items": []}
    """
}

// MARK: - Test helpers

private actor StubLoader: SourceHTMLLoading {
    enum Response {
        case success(WebPageSnapshot)
        case failure(Error)
    }

    private var responses: [Response]
    private var requested: [URL] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        requested.append(request.url)
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

    func requestedURLs() -> [URL] { requested }
}
