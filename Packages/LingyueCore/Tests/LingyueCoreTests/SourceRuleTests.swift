import XCTest
@testable import LingyueCore

/// Phase 0 smoke tests — verifies the rule schema round-trips through
/// `Codable` and that the value types stay `Hashable`. Real engine tests
/// land in Phase 1 once `RuleBasedBookSource` exists.
final class SourceRuleTests: XCTestCase {
    func testSchemaVersionConstant() {
        XCTAssertGreaterThanOrEqual(SourceRule.currentSchemaVersion, 1)
    }

    func testMinimalRuleRoundTripsThroughCodable() throws {
        let rule = SourceRule(
            name: "Example",
            homepage: URL(string: "https://example.test")!,
            capabilities: SourceCapabilities(
                supportsSearch: false,
                showInSearchBar: false,
                supportsBrowserImport: true,
                requiresWebRender: false
            ),
            detection: DetectionStep(hostPatterns: ["example.test"]),
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
                bodyField: FieldSelector(
                    selector: "div.content",
                    transforms: [.brToNewline, .stripHTML, .collapseWhitespace]
                )
            )
        )

        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(SourceRule.self, from: data)
        XCTAssertEqual(rule, decoded)
    }

    func testSourceCapabilitiesDefaults() {
        let caps = SourceCapabilities(
            supportsSearch: true,
            showInSearchBar: true,
            supportsBrowserImport: false,
            requiresWebRender: false
        )
        XCTAssertEqual(caps.maxConcurrentRequests, 3)
        XCTAssertEqual(caps.requestIntervalMillis, 0)
    }
}
