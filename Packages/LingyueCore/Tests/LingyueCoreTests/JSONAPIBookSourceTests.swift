import XCTest
@testable import LingyueCore

/// In-memory stub for `SourceHTMLLoading`. Records every fetched URL and
/// dispenses responses from a queue. Lets a test drive the JSON-API
/// engine through a precise sequence of upstream responses (e.g. "first
/// call returns HTML, second call returns JSON") without touching the
/// network or filesystem.
private actor QueuedStubLoader: SourceHTMLLoading {
    private var responses: [WebPageSnapshot]
    private(set) var requestedURLs: [URL] = []

    init(responses: [WebPageSnapshot]) {
        self.responses = responses
    }

    func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        requestedURLs.append(request.url)
        guard !responses.isEmpty else {
            throw BookSourceError.loadFailed(reason: "stub exhausted")
        }
        return responses.removeFirst()
    }

    func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        try await fetchHTML(request)
    }

    func capturedURLs() -> [URL] { requestedURLs }
}

private func snapshot(html: String, contentType: String, url: String) -> WebPageSnapshot {
    WebPageSnapshot(
        html: html,
        finalURL: URL(string: url)!,
        responseHeaders: ["content-type": contentType],
        statusCode: 200
    )
}

private func makeRule() -> SourceRule {
    SourceRule(
        name: "stub",
        homepage: URL(string: "https://example.test/")!,
        capabilities: SourceCapabilities(
            supportsSearch: false,
            showInSearchBar: false,
            supportsBrowserImport: true,
            requiresWebRender: false
        ),
        detection: DetectionStep(hostPatterns: ["example.test", "*.example.test"]),
        detail: DetailStep(
            titleField: FieldSelector(selector: "h1"),
            catalogURLField: FieldSelector(transforms: [.useBaseURL])
        ),
        catalog: CatalogStep(
            chaptersSelector: "ul a",
            titleField: FieldSelector(),
            urlField: FieldSelector(attribute: "href")
        ),
        chapter: ChapterStep(
            titleField: FieldSelector(selector: "h2"),
            bodyField: FieldSelector(selector: "div.content")
        ),
        jsonAPI: JSONAPIConfig(
            sourceID: "json-api:stub",
            idExtractors: ["bookID": [#"^/book/(\d+)\.html?$"#]],
            catalog: JSONAPIConfig.Catalog(
                endpointTemplates: ["https://example.test/api/list?id={bookID}"],
                itemsPath: "items",
                titleField: "title",
                urlField: "url"
            )
        )
    )
}

final class JSONAPIBookSourceTests: XCTestCase {

    /// First call returns HTML (simulating a CDN that's holding an HTML
    /// page in cache for a JSON endpoint); engine should retry with a
    /// cache-buster appended, see the JSON body, and decode the catalog
    /// normally.
    func testFetchCatalogRetriesOnHTMLResponse() async throws {
        let cleanCatalogJSON = """
        {"items":[{"title":"第一章","url":"/book/1/c1.html"},{"title":"第二章","url":"/book/1/c2.html"}]}
        """
        let loader = QueuedStubLoader(responses: [
            // Primary call: server returns HTML.
            snapshot(
                html: "<!DOCTYPE html><html><body>wrong cache hit</body></html>",
                contentType: "text/html; charset=utf-8",
                url: "https://example.test/api/list?id=1"
            ),
            // Retry call (with cache-buster): server returns JSON.
            snapshot(
                html: cleanCatalogJSON,
                contentType: "application/json; charset=utf-8",
                url: "https://example.test/api/list?id=1"
            )
        ])
        let rule = makeRule()
        let source = JSONAPIBookSource(rule: rule, config: rule.jsonAPI!, loader: loader)
        let links = try await source.fetchCatalog(url: URL(string: "https://example.test/book/1.html")!)

        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.first?.title, "第一章")
        let captured = await loader.capturedURLs()
        XCTAssertEqual(captured.count, 2, "expected exactly one retry")
        XCTAssertFalse(
            captured[0].query?.contains("_=") ?? false,
            "primary request must not carry a cache-buster"
        )
        XCTAssertTrue(
            captured[1].query?.contains("_=") ?? false,
            "retry request must carry a cache-buster (_=<ms>)"
        )
    }

    /// When the very first response is well-formed JSON, the engine must
    /// not retry — the CDN caching path is only meant to fire when
    /// something's actually wrong.
    func testFetchCatalogDoesNotRetryWhenResponseIsJSON() async throws {
        let json = """
        {"items":[{"title":"only chapter","url":"/book/1/c1.html"}]}
        """
        let loader = QueuedStubLoader(responses: [
            snapshot(
                html: json,
                contentType: "application/json; charset=utf-8",
                url: "https://example.test/api/list?id=1"
            )
        ])
        let rule = makeRule()
        let source = JSONAPIBookSource(rule: rule, config: rule.jsonAPI!, loader: loader)
        let links = try await source.fetchCatalog(url: URL(string: "https://example.test/book/1.html")!)

        XCTAssertEqual(links.count, 1)
        let captured = await loader.capturedURLs()
        XCTAssertEqual(captured.count, 1, "no retry should happen on a clean JSON response")
    }
}
