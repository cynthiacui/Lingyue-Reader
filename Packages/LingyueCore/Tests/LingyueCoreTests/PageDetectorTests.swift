import XCTest
@testable import LingyueCore

/// Phase 4 §4.7 — verifies the in-app browser's detector fans out,
/// applies tiebreaks deterministically, survives per-source thrown
/// errors, caches results, and drops the cache on demand.
final class PageDetectorTests: XCTestCase {

    // MARK: - Fan-out + filtering

    func testIgnoresSourcesWithoutBrowserImport() async {
        let searchOnly = StubBookSource(
            id: "rule:search-only",
            displayName: "搜索专用",
            capabilities: caps(browserImport: false),
            detection: BookDetection(confidence: 0.9, detailURL: anyURL, sourceID: "rule:search-only")
        )
        let importer = StubBookSource(
            id: "rule:import",
            displayName: "导入源",
            capabilities: caps(browserImport: true),
            detection: BookDetection(confidence: 0.5, detailURL: anyURL, sourceID: "rule:import")
        )
        let detector = PageDetector(registry: StubRegistry(sources: [searchOnly, importer]))

        let result = await detector.detect(in: snapshot())
        let searchOnlyCallCount = await searchOnly.detectCallCount
        let importerCallCount = await importer.detectCallCount

        XCTAssertEqual(result?.sourceID, "rule:import")
        XCTAssertEqual(searchOnlyCallCount, 0, "filtered source must never be probed")
        XCTAssertEqual(importerCallCount, 1)
    }

    func testReturnsNilWhenNoSourceMatches() async {
        let nonMatching = StubBookSource(
            id: "rule:nope",
            displayName: "Nope",
            capabilities: caps(browserImport: true),
            detection: nil
        )
        let detector = PageDetector(registry: StubRegistry(sources: [nonMatching]))

        let result = await detector.detect(in: snapshot())

        XCTAssertNil(result)
    }

    // MARK: - Tiebreak

    func testHigherConfidenceWins() async {
        let weak = StubBookSource(
            id: "rule:weak",
            displayName: "Weak",
            capabilities: caps(browserImport: true),
            detection: BookDetection(confidence: 0.4, detailURL: anyURL, sourceID: "rule:weak")
        )
        let strong = StubBookSource(
            id: "rule:strong",
            displayName: "Strong",
            capabilities: caps(browserImport: true),
            detection: BookDetection(confidence: 0.9, detailURL: anyURL, sourceID: "rule:strong")
        )
        // Order strong second on purpose — confidence must trump registry order.
        let detector = PageDetector(registry: StubRegistry(sources: [weak, strong]))

        let result = await detector.detect(in: snapshot())

        XCTAssertEqual(result?.sourceID, "rule:strong")
    }

    func testEqualConfidenceFallsBackToRegistryOrder() async {
        let first = StubBookSource(
            id: "rule:first",
            displayName: "First",
            capabilities: caps(browserImport: true),
            detection: BookDetection(confidence: 0.6, detailURL: anyURL, sourceID: "rule:first")
        )
        let second = StubBookSource(
            id: "rule:second",
            displayName: "Second",
            capabilities: caps(browserImport: true),
            detection: BookDetection(confidence: 0.6, detailURL: anyURL, sourceID: "rule:second")
        )
        let detector = PageDetector(registry: StubRegistry(sources: [first, second]))

        let result = await detector.detect(in: snapshot())

        XCTAssertEqual(result?.sourceID, "rule:first")
    }

    // MARK: - Error resilience

    func testThrownSourceDoesNotFailPass() async {
        let throwing = StubBookSource(
            id: "rule:throws",
            displayName: "Throws",
            capabilities: caps(browserImport: true),
            error: BookSourceError.parseFailed(field: "detection")
        )
        let working = StubBookSource(
            id: "rule:works",
            displayName: "Works",
            capabilities: caps(browserImport: true),
            detection: BookDetection(confidence: 0.7, detailURL: anyURL, sourceID: "rule:works")
        )
        let detector = PageDetector(registry: StubRegistry(sources: [throwing, working]))

        let result = await detector.detect(in: snapshot())

        XCTAssertEqual(result?.sourceID, "rule:works")
    }

    // MARK: - Cache

    func testCacheReturnsSameResultWithoutReprobing() async {
        let source = StubBookSource(
            id: "rule:cache",
            displayName: "Cached",
            capabilities: caps(browserImport: true),
            detection: BookDetection(confidence: 0.8, detailURL: anyURL, sourceID: "rule:cache")
        )
        let detector = PageDetector(registry: StubRegistry(sources: [source]))

        let first = await detector.detect(in: snapshot())
        let second = await detector.detect(in: snapshot())
        let callCount = await source.detectCallCount

        XCTAssertEqual(first, second)
        XCTAssertEqual(callCount, 1, "second lookup must hit cache, not re-probe")
    }

    func testCacheStoresMissesToo() async {
        let nonMatching = StubBookSource(
            id: "rule:miss",
            displayName: "Miss",
            capabilities: caps(browserImport: true),
            detection: nil
        )
        let detector = PageDetector(registry: StubRegistry(sources: [nonMatching]))

        let first = await detector.detect(in: snapshot())
        let second = await detector.detect(in: snapshot())
        let callCount = await nonMatching.detectCallCount

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(callCount, 1, "cached miss must short-circuit re-probe")
    }

    func testSameURLWithChangedHTMLReprobes() async {
        let detailURL = anyURL
        let source = StubBookSource(
            id: "rule:dynamic-dom",
            displayName: "Dynamic DOM",
            capabilities: caps(browserImport: true),
            detector: { page in
                page.html.contains("book-ready")
                    ? BookDetection(confidence: 0.8, detailURL: detailURL, sourceID: "rule:dynamic-dom")
                    : nil
            }
        )
        let detector = PageDetector(registry: StubRegistry(sources: [source]))

        let early = await detector.detect(in: snapshot(html: "<html></html>"))
        let settled = await detector.detect(in: snapshot(html: "<html>book-ready</html>"))
        let callCount = await source.detectCallCount

        XCTAssertNil(early)
        XCTAssertEqual(settled?.sourceID, "rule:dynamic-dom")
        XCTAssertEqual(callCount, 2, "same URL with a new rendered DOM must not reuse the earlier miss")
    }

    func testInvalidateCacheForcesReprobe() async {
        let source = StubBookSource(
            id: "rule:invalidate",
            displayName: "Invalidate",
            capabilities: caps(browserImport: true),
            detection: BookDetection(confidence: 0.7, detailURL: anyURL, sourceID: "rule:invalidate")
        )
        let detector = PageDetector(registry: StubRegistry(sources: [source]))

        _ = await detector.detect(in: snapshot())
        await detector.invalidateCache()
        _ = await detector.detect(in: snapshot())
        let callCount = await source.detectCallCount

        XCTAssertEqual(callCount, 2, "invalidate must drop cache and force re-probe")
    }

    // MARK: - Fixtures

    private var anyURL: URL { URL(string: "https://example.test/book/1")! }

    private func snapshot(url: URL? = nil, html: String = "<html></html>") -> WebPageSnapshot {
        WebPageSnapshot(html: html, finalURL: url ?? anyURL)
    }

    private func caps(browserImport: Bool) -> SourceCapabilities {
        SourceCapabilities(
            supportsSearch: false,
            showInSearchBar: false,
            supportsBrowserImport: browserImport,
            requiresWebRender: false
        )
    }
}

// MARK: - Stubs

/// Records `detectBook` calls and returns a pre-canned detection or
/// throws on demand. Counts are mutated through an actor-safe lock since
/// the detector fans calls out across a task group.
private final class StubBookSource: BookSource, @unchecked Sendable {
    let id: String
    let displayName: String
    let capabilities: SourceCapabilities

    private let detection: BookDetection?
    private let error: Error?
    private let detector: (@Sendable (WebPageSnapshot) -> BookDetection?)?
    private let callCounter = CallCounter()

    init(
        id: String,
        displayName: String,
        capabilities: SourceCapabilities,
        detection: BookDetection? = nil,
        error: Error? = nil,
        detector: (@Sendable (WebPageSnapshot) -> BookDetection?)? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.detection = detection
        self.error = error
        self.detector = detector
    }

    var detectCallCount: Int {
        get async { await callCounter.value }
    }

    func detectBook(in page: WebPageSnapshot) async throws -> BookDetection? {
        await callCounter.increment()
        if let error { throw error }
        if let detector { return detector(page) }
        return detection
    }

    // Unused in these tests; protocol completeness only.
    func search(_ query: String) async throws -> [BookSearchResult] {
        throw BookSourceError.searchUnsupported
    }
    func fetchDetail(url: URL) async throws -> BookDetail {
        throw BookSourceError.unsupportedURL(url)
    }
    func fetchCatalog(url: URL) async throws -> [ChapterLink] {
        throw BookSourceError.unsupportedURL(url)
    }
    func fetchChapter(url: URL) async throws -> ChapterContent {
        throw BookSourceError.unsupportedURL(url)
    }
}

private actor CallCounter {
    private var count = 0

    var value: Int { count }

    func increment() {
        count += 1
    }
}

private struct StubRegistry: BookSourceRegistry {
    let sources: [any BookSource]

    func enabledSources() async throws -> [any BookSource] { sources }
    func searchableSources() async throws -> [any BookSource] {
        sources.filter { $0.capabilities.supportsSearch && $0.capabilities.showInSearchBar }
    }
    func source(withID id: String) async throws -> (any BookSource)? {
        sources.first { $0.id == id }
    }
}
