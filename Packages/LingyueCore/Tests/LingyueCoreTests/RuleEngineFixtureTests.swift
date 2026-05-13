import XCTest
@testable import LingyueCore

/// End-to-end engine test against the `source-a` synthetic fixtures.
/// Drives `RuleBasedBookSource` through search → detail → catalog → chapter
/// with a `FixtureLoader` that serves canned HTML, then compares every
/// extracted value against `expected.json`. This is the contract test for
/// Phase 1: a real rule.json + real HTML + the real engine, with no
/// network in the loop.
final class RuleEngineFixtureTests: XCTestCase {

    // MARK: - Fixture loading

    private struct Expected: Decodable {
        struct Detection: Decodable {
            let confidence: Double
            let title: String?
            let detailURL: URL
        }
        struct SearchResult: Decodable {
            let title: String
            let author: String?
            let detailURL: URL
            let coverURL: URL?
            let snippet: String?
        }
        struct Search: Decodable {
            let query: String
            let results: [SearchResult]
        }
        struct Detail: Decodable {
            let url: URL
            let title: String
            let author: String?
            let coverURL: URL?
            let description: String?
            let status: String?
            let statistics: String?
            let tags: [String]
            let catalogURL: URL
        }
        struct Chapter: Decodable {
            let title: String
            let url: URL
            let volume: String?
        }
        struct Catalog: Decodable {
            let url: URL
            let chapters: [Chapter]
        }
        struct ChapterContentExpected: Decodable {
            let url: URL
            let title: String
            let paragraphs: [String]
            let nextChapterURL: URL?
            let previousChapterURL: URL?
        }

        let detection: Detection
        let search: Search
        let detail: Detail
        let catalog: Catalog
        let chapter1: ChapterContentExpected
        let chapter2: ChapterContentExpected
    }

    private func fixturesBaseURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw XCTSkip("Fixtures bundle resource not found")
        }
        return url
    }

    private func loadRule() throws -> SourceRule {
        let url = try fixturesBaseURL().appendingPathComponent("source-a/rule.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SourceRule.self, from: data)
    }

    private func loadExpected() throws -> Expected {
        let url = try fixturesBaseURL().appendingPathComponent("source-a/expected.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Expected.self, from: data)
    }

    private func makeLoader() throws -> FixtureLoader {
        let baseDir = try fixturesBaseURL().appendingPathComponent("source-a")
        let mapping: [String: String] = [
            "https://source-a.invalid.test/": "homepage.html",
            "https://source-a.invalid.test/search?q=ling": "search.html",
            "https://source-a.invalid.test/book/42": "detail.html",
            "https://source-a.invalid.test/book/42/catalog": "catalog-page1.html",
            "https://source-a.invalid.test/book/42/catalog?page=2": "catalog-page2.html",
            "https://source-a.invalid.test/book/42/chapter/1": "chapter1-page1.html",
            "https://source-a.invalid.test/book/42/chapter/1?p=2": "chapter1-page2.html",
            "https://source-a.invalid.test/book/42/chapter/2": "chapter2.html"
        ]
        return FixtureLoader(baseDirectory: baseDir, mapping: mapping)
    }

    private func makeSource() throws -> RuleBasedBookSource {
        RuleBasedBookSource(rule: try loadRule(), loader: try makeLoader())
    }

    // MARK: - Schema integrity

    func testRuleDecodesCleanly() throws {
        let rule = try loadRule()
        XCTAssertEqual(rule.name, "Source A")
        XCTAssertEqual(rule.schemaVersion, SourceRule.currentSchemaVersion)
        XCTAssertTrue(rule.capabilities.supportsSearch)
        XCTAssertNotNil(rule.search)
    }

    // MARK: - Detection

    func testDetectBookOnDetailPage() async throws {
        let source = try makeSource()
        let expected = try loadExpected()
        let baseDir = try fixturesBaseURL().appendingPathComponent("source-a")
        let detailHTML = try String(
            contentsOf: baseDir.appendingPathComponent("detail.html"),
            encoding: .utf8
        )
        let pageURL = URL(string: "https://source-a.invalid.test/book/42")!
        let snapshot = WebPageSnapshot(
            html: detailHTML,
            finalURL: pageURL,
            responseHeaders: [:],
            statusCode: 200
        )
        let detection = try await source.detectBook(in: snapshot)
        XCTAssertNotNil(detection)
        XCTAssertEqual(detection?.detailURL, expected.detection.detailURL)
        XCTAssertEqual(detection?.title, expected.detection.title)
        XCTAssertEqual(detection?.confidence ?? 0, expected.detection.confidence, accuracy: 0.0001)
    }

    func testDetectBookRejectsNonDetailPage() async throws {
        let source = try makeSource()
        let baseDir = try fixturesBaseURL().appendingPathComponent("source-a")
        let homepageHTML = try String(
            contentsOf: baseDir.appendingPathComponent("homepage.html"),
            encoding: .utf8
        )
        let pageURL = URL(string: "https://source-a.invalid.test/")!
        let snapshot = WebPageSnapshot(
            html: homepageHTML,
            finalURL: pageURL,
            responseHeaders: [:],
            statusCode: 200
        )
        let detection = try await source.detectBook(in: snapshot)
        XCTAssertNil(detection, "Homepage path should fail the pathPattern guard")
    }

    // MARK: - Search

    func testSearchReturnsTwoResults() async throws {
        let source = try makeSource()
        let expected = try loadExpected()
        let results = try await source.search(expected.search.query)
        XCTAssertEqual(results.count, expected.search.results.count)
        for (got, want) in zip(results, expected.search.results) {
            XCTAssertEqual(got.title, want.title)
            XCTAssertEqual(got.author, want.author)
            XCTAssertEqual(got.detailURL, want.detailURL)
            XCTAssertEqual(got.coverURL, want.coverURL)
            XCTAssertEqual(got.snippet, want.snippet)
            XCTAssertEqual(got.sourceID, source.id)
        }
    }

    // MARK: - Detail

    func testFetchDetail() async throws {
        let source = try makeSource()
        let expected = try loadExpected()
        let detail = try await source.fetchDetail(url: expected.detail.url)
        XCTAssertEqual(detail.title, expected.detail.title)
        XCTAssertEqual(detail.author, expected.detail.author)
        XCTAssertEqual(detail.coverURL, expected.detail.coverURL)
        XCTAssertEqual(detail.description, expected.detail.description)
        XCTAssertEqual(detail.status, expected.detail.status)
        XCTAssertEqual(detail.statistics, expected.detail.statistics)
        XCTAssertEqual(detail.tags, expected.detail.tags)
        XCTAssertEqual(detail.catalogURL, expected.detail.catalogURL)
        XCTAssertEqual(detail.detailURL, expected.detail.url)
        XCTAssertEqual(detail.sourceID, source.id)
    }

    // MARK: - Catalog

    func testFetchCatalogWalksPagination() async throws {
        let source = try makeSource()
        let expected = try loadExpected()
        let chapters = try await source.fetchCatalog(url: expected.catalog.url)
        XCTAssertEqual(chapters.count, expected.catalog.chapters.count)
        for (i, (got, want)) in zip(chapters, expected.catalog.chapters).enumerated() {
            XCTAssertEqual(got.title, want.title, "chapter[\(i)] title")
            XCTAssertEqual(got.url, want.url, "chapter[\(i)] url")
            XCTAssertEqual(got.volume, want.volume, "chapter[\(i)] volume")
            XCTAssertEqual(got.index, i, "chapter[\(i)] index")
        }
    }

    // MARK: - Chapter

    func testFetchChapterFollowsBodyPagination() async throws {
        let source = try makeSource()
        let expected = try loadExpected()
        let content = try await source.fetchChapter(url: expected.chapter1.url)
        XCTAssertEqual(content.title, expected.chapter1.title)
        XCTAssertEqual(content.paragraphs, expected.chapter1.paragraphs)
        XCTAssertEqual(content.nextChapterURL, expected.chapter1.nextChapterURL)
        XCTAssertEqual(content.previousChapterURL, expected.chapter1.previousChapterURL)
    }

    func testFetchChapterReadsPrevAndNextLinks() async throws {
        let source = try makeSource()
        let expected = try loadExpected()
        let content = try await source.fetchChapter(url: expected.chapter2.url)
        XCTAssertEqual(content.title, expected.chapter2.title)
        XCTAssertEqual(content.paragraphs, expected.chapter2.paragraphs)
        XCTAssertEqual(content.nextChapterURL, expected.chapter2.nextChapterURL)
        XCTAssertEqual(content.previousChapterURL, expected.chapter2.previousChapterURL)
    }
}
