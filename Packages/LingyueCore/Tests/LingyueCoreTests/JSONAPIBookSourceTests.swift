import XCTest
@testable import LingyueCore

/// Coverage for the generic JSON-API engine. The engine is fully driven
/// by `JSONAPIConfig`, so the tests focus on the seam between rule data
/// and the engine: token extraction from URLs, template substitution
/// across both shapes the seeded rules produce (5dxs object-array with
/// per-item `url`, biquge bare-string-array with a synthesized 1-indexed
/// URL template), body cleanup transforms, and the fallback to the
/// HTML scraper when a step has no `jsonAPI` config.
final class JSONAPIBookSourceTests: XCTestCase {

    // MARK: - Token extraction

    func testExtractTokensFromFivedxsInfoPath() throws {
        let url = URL(string: "https://m.5dxs.net/info/12/12345.html")!
        let tokens = try JSONAPIBookSource.extractTokens(
            from: url,
            using: ["bookID": [
                #"^/info/\d+/(\d+)\.html?$"#,
                #"^/reader/\d+/(\d+)/\d+\.html?$"#
            ]]
        )
        XCTAssertEqual(tokens["bookID"], "12345")
    }

    func testExtractTokensFromFivedxsReaderPath() throws {
        let url = URL(string: "https://m.5dxs.net/reader/12/12345/7.html")!
        let tokens = try JSONAPIBookSource.extractTokens(
            from: url,
            using: ["bookID": [
                #"^/info/\d+/(\d+)\.html?$"#,
                #"^/reader/\d+/(\d+)/\d+\.html?$"#
            ]]
        )
        XCTAssertEqual(tokens["bookID"], "12345")
    }

    func testExtractTokensFromBiqugeBookAndChapterPath() throws {
        let url = URL(string: "https://bqg99.cc/book/4242/77.html")!
        let tokens = try JSONAPIBookSource.extractTokens(
            from: url,
            using: [
                "bookID": [
                    #"/book/(\d+)/\d+(?:_\d+)?\.html?$"#,
                    #"/book/(\d+)/?$"#
                ],
                "chapterID": [
                    #"/book/\d+/(\d+)(?:_\d+)?\.html?$"#
                ]
            ]
        )
        XCTAssertEqual(tokens["bookID"], "4242")
        XCTAssertEqual(tokens["chapterID"], "77")
    }

    // MARK: - Host pattern matching

    func testHostMatchingHandlesGlobAndSuffix() {
        let url = URL(string: "https://m.bqg99.cc/book/1/")!
        XCTAssertTrue(
            JSONAPIBookSource.urlMatchesAnyHostPattern(url, patterns: ["*bqg*"])
        )
        XCTAssertTrue(
            JSONAPIBookSource.urlMatchesAnyHostPattern(url, patterns: ["bqg99.cc"])
        )
        XCTAssertFalse(
            JSONAPIBookSource.urlMatchesAnyHostPattern(url, patterns: ["example.test"])
        )
    }

    // MARK: - Catalog decoding (object-array shape, 5dxs)

    func testDecodeFivedxsCatalogShape() throws {
        let json = #"""
        {
          "items": [
            { "chaptername": "第一章 开始", "url": "/reader/12/12345/1.html" },
            { "chaptername": "第二章 路上", "url": "https://m.5dxs.net/reader/12/12345/2.html" }
          ]
        }
        """#
        let catalog = JSONAPIConfig.Catalog(
            endpointTemplates: ["https://ignored/"],
            itemsPath: "items",
            titleField: "chaptername",
            urlField: "url",
            titleTransforms: [.decodeEntities, .stripHTML, .collapseWhitespace, .trim]
        )
        let links = try JSONAPIBookSource.decodeCatalog(
            json: json,
            catalog: catalog,
            tokens: [:],
            baseURL: URL(string: "https://m.5dxs.net/info/12/12345.html")!
        )
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].title, "第一章 开始")
        XCTAssertEqual(links[0].url.absoluteString, "https://m.5dxs.net/reader/12/12345/1.html")
        XCTAssertEqual(links[1].url.absoluteString, "https://m.5dxs.net/reader/12/12345/2.html")
    }

    // MARK: - Catalog decoding (bare-string-array shape, biquge)

    func testDecodeBiqugeCatalogShapeSynthesizesURLs() throws {
        let json = #"""
        { "list": ["第一章 启程", "第二章 路上"] }
        """#
        let catalog = JSONAPIConfig.Catalog(
            endpointTemplates: ["https://ignored/"],
            itemsPath: "list",
            urlTemplate: "/book/{bookID}/{index}.html",
            titleTransforms: [.decodeEntities, .stripHTML, .collapseWhitespace, .trim]
        )
        let links = try JSONAPIBookSource.decodeCatalog(
            json: json,
            catalog: catalog,
            tokens: ["bookID": "4242"],
            baseURL: URL(string: "https://bqg99.cc/book/4242/")!
        )
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].title, "第一章 启程")
        XCTAssertEqual(links[0].url.absoluteString, "https://bqg99.cc/book/4242/1.html")
        XCTAssertEqual(links[1].url.absoluteString, "https://bqg99.cc/book/4242/2.html")
    }

    // MARK: - Chapter decoding + body transforms

    func testDecodeBiqugeChapterAppliesBodyPipeline() throws {
        let json = #"""
        {
          "chaptername": "第一章 启程",
          "txt": "第一段。<br/>第二段&mdash;<br>\r\n请收藏本站\n第三段。"
        }
        """#
        let chapter = JSONAPIConfig.Chapter(
            endpointTemplates: ["https://ignored/"],
            titleField: "chaptername",
            bodyField: "txt",
            bodyTransforms: [
                .normalizeLineEndings,
                .brToNewline,
                .stripHTML,
                .decodeEntities,
                .splitLines,
                .filterBoilerplate
            ],
            boilerplateFragments: ["请收藏本站"]
        )
        let content = try JSONAPIBookSource.decodeChapter(json: json, chapter: chapter)
        XCTAssertEqual(content.title, "第一章 启程")
        XCTAssertEqual(content.paragraphs, ["第一段。", "第二段\u{2014}", "第三段。"])
    }

    // MARK: - Routing (jsonAPI present → JSONAPIBookSource; nil → RuleBasedBookSource)

    func testMakeBookSourceRoutesByJSONAPIPresence() {
        let loader = StubLoader()
        let rule = Self.makeMinimalRule(jsonAPI: nil)
        let source = rule.makeBookSource(loader: loader)
        XCTAssertTrue(source is RuleBasedBookSource)

        let configured = Self.makeMinimalRule(jsonAPI: JSONAPIConfig(
            sourceID: "json-api:test",
            idExtractors: [:]
        ))
        let routed = configured.makeBookSource(loader: loader)
        XCTAssertTrue(routed is JSONAPIBookSource)
        XCTAssertEqual(routed.id, "json-api:test")
    }

    // MARK: - Helpers

    static func makeMinimalRule(jsonAPI: JSONAPIConfig?) -> SourceRule {
        SourceRule(
            name: "Stub",
            homepage: URL(string: "https://example.test/")!,
            capabilities: SourceCapabilities(
                supportsSearch: false,
                showInSearchBar: false,
                supportsBrowserImport: true,
                requiresWebRender: false
            ),
            detection: DetectionStep(hostPatterns: ["example.test"]),
            detail: DetailStep(
                titleField: FieldSelector(selector: "h1"),
                catalogURLField: FieldSelector(selector: "a")
            ),
            catalog: CatalogStep(
                chaptersSelector: "li",
                titleField: FieldSelector(selector: "a"),
                urlField: FieldSelector(selector: "a", attribute: "href")
            ),
            chapter: ChapterStep(
                titleField: FieldSelector(selector: "h1"),
                bodyField: FieldSelector(selector: "div")
            ),
            jsonAPI: jsonAPI
        )
    }
}

private struct StubLoader: SourceHTMLLoading {
    func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        throw BookSourceError.loadFailed(reason: "stub")
    }
    func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        throw BookSourceError.loadFailed(reason: "stub")
    }
}
