import XCTest
@testable import LingyueCore

/// Locks down `SourceRule.isSearchable` — the single definition three UI
/// surfaces read (Discovery's search gating, the 书源 list's 可搜索/仅浏览
/// pill, and the review screen's 搜索 row) *and* the filter
/// `DiscoverySearchService` applies when fanning rules into a query.
///
/// The property has to answer "can this rule produce a search hit?", not
/// "does a search block exist?". The advanced editor writes `urlTemplate`
/// and `resultsSelector` as unvalidated free text, so a rule can carry a
/// half-finished step. Treating that as searchable is what made a source
/// look healthy in the list, get fanned into every query, and come back as
/// "没有找到匹配内容" — which reads as "we searched and found nothing"
/// rather than "this source can't search".
final class SourceRuleSearchabilityTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRule(
        search: SearchStep? = nil,
        jsonAPI: JSONAPIConfig? = nil
    ) -> SourceRule {
        SourceRule(
            name: "Example",
            homepage: URL(string: "https://example.test")!,
            capabilities: SourceCapabilities(
                supportsSearch: search != nil,
                showInSearchBar: true,
                supportsBrowserImport: true,
                requiresWebRender: false
            ),
            detection: DetectionStep(hostPatterns: ["example.test"]),
            search: search,
            detail: DetailStep(
                titleField: FieldSelector(selector: "h1"),
                catalogURLField: FieldSelector(selector: "a.catalog", attribute: "href")
            ),
            catalog: CatalogStep(
                chaptersSelector: "ul.chapters > li > a",
                titleField: FieldSelector(),
                urlField: FieldSelector(attribute: "href")
            ),
            chapter: ChapterStep(
                titleField: FieldSelector(selector: "h2"),
                bodyField: FieldSelector(selector: "div.content")
            ),
            jsonAPI: jsonAPI
        )
    }

    private func makeSearchStep(
        urlTemplate: String = "https://example.test/s?q={query}",
        resultsSelector: String = ".result-item"
    ) -> SearchStep {
        SearchStep(
            urlTemplate: urlTemplate,
            resultsSelector: resultsSelector,
            titleField: FieldSelector(selector: "a"),
            detailURLField: FieldSelector(selector: "a", attribute: "href")
        )
    }

    private func makeJSONConfig(
        endpointTemplates: [String] = ["https://example.test/api?q={query}"],
        titleField: String = "name"
    ) -> JSONAPIConfig {
        makeJSONConfig(
            search: JSONAPIConfig.Search(
                endpointTemplates: endpointTemplates,
                titleField: titleField
            )
        )
    }

    private func makeJSONConfig(search: JSONAPIConfig.Search?) -> JSONAPIConfig {
        JSONAPIConfig(
            sourceID: "json-api:example",
            idExtractors: [:],
            search: search
        )
    }

    // MARK: - Browse-only: nothing configured

    func testNoSearchStepIsNotSearchable() {
        XCTAssertFalse(makeRule().isSearchable)
    }

    // MARK: - HTML search step

    func testCompleteHTMLSearchStepIsSearchable() {
        XCTAssertTrue(makeRule(search: makeSearchStep()).isSearchable)
    }

    func testBlankURLTemplateIsNotSearchable() {
        let rule = makeRule(search: makeSearchStep(urlTemplate: ""))
        XCTAssertFalse(rule.isSearchable)
    }

    /// The insidious one: a blank selector still issues the request, so the
    /// engine returns zero rows instead of throwing. Nothing downstream can
    /// tell that apart from a genuine miss, so it has to be caught here.
    func testBlankResultsSelectorIsNotSearchable() {
        let rule = makeRule(search: makeSearchStep(resultsSelector: ""))
        XCTAssertFalse(rule.isSearchable)
    }

    /// A field the user cleared and a field holding a stray space are
    /// equally unusable, so whitespace must not read as "filled in".
    func testWhitespaceOnlyFieldsAreNotSearchable() {
        XCTAssertFalse(makeRule(search: makeSearchStep(urlTemplate: "   ")).isSearchable)
        XCTAssertFalse(makeRule(search: makeSearchStep(resultsSelector: " \n ")).isSearchable)
    }

    // MARK: - JSON-API search

    func testCompleteJSONAPISearchIsSearchable() {
        XCTAssertTrue(makeRule(jsonAPI: makeJSONConfig()).isSearchable)
    }

    func testJSONAPIWithoutSearchBlockIsNotSearchable() {
        XCTAssertFalse(makeRule(jsonAPI: makeJSONConfig(search: nil)).isSearchable)
    }

    func testJSONAPIWithEmptyEndpointListIsNotSearchable() {
        let rule = makeRule(jsonAPI: makeJSONConfig(endpointTemplates: []))
        XCTAssertFalse(rule.isSearchable)
    }

    func testJSONAPIWithOnlyBlankEndpointsIsNotSearchable() {
        let rule = makeRule(jsonAPI: makeJSONConfig(endpointTemplates: ["", "  "]))
        XCTAssertFalse(rule.isSearchable)
    }

    func testJSONAPIWithBlankTitleFieldIsNotSearchable() {
        let rule = makeRule(jsonAPI: makeJSONConfig(titleField: ""))
        XCTAssertFalse(rule.isSearchable)
    }

    /// An empty `itemsPath` legitimately means "the JSON root is itself the
    /// array", so it must not be mistaken for an unfilled field.
    func testJSONAPIWithEmptyItemsPathStaysSearchable() {
        let config = makeJSONConfig(
            search: JSONAPIConfig.Search(
                endpointTemplates: ["https://example.test/api?q={query}"],
                itemsPath: "",
                titleField: "name"
            )
        )
        XCTAssertTrue(makeRule(jsonAPI: config).isSearchable)
    }

    // MARK: - Either path suffices

    func testUnrunnableHTMLStepFallsBackToRunnableJSONAPI() {
        let rule = makeRule(
            search: makeSearchStep(urlTemplate: ""),
            jsonAPI: makeJSONConfig()
        )
        XCTAssertTrue(rule.isSearchable)
    }

    func testBothPathsUnrunnableIsNotSearchable() {
        let rule = makeRule(
            search: makeSearchStep(resultsSelector: ""),
            jsonAPI: makeJSONConfig(endpointTemplates: [])
        )
        XCTAssertFalse(rule.isSearchable)
    }

    // MARK: - Independence from the derived capability flag

    /// `capabilities.supportsSearch` is authored/derived and reflects
    /// *verification*; `isSearchable` is structural. A rule whose flag lies
    /// must not change the structural answer, in either direction.
    func testIgnoresCapabilitiesSupportsSearchFlag() {
        var claimsSearch = makeRule()
        claimsSearch.capabilities.supportsSearch = true
        XCTAssertFalse(claimsSearch.isSearchable)

        var deniesSearch = makeRule(search: makeSearchStep())
        deniesSearch.capabilities.supportsSearch = false
        XCTAssertTrue(deniesSearch.isSearchable)
    }
}
