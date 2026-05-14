import XCTest
@testable import LingyueCore

/// Phase 2.5 — rule-schema fitness check. Drives `RuleBasedBookSource`
/// through real search-result HTML captured from two live sites and
/// validates the rule schema produces the expected hits. The point isn't
/// regression coverage — it's a proof that the schema is expressive enough
/// for two non-trivial real-world shapes:
///
/// - 思兔閱讀 (sto9.com): POST search that 302-redirects to a GET URL,
///   plus an AJAX-loaded catalog that the rule reaches through a
///   `regexReplace` on the detail page's catalog-link URL.
/// - 同人圈 (tongrenquan.org): Empire CMS clone that decodes form bodies
///   as GB18030 server-side. Validates the `queryEncoding` schema
///   extension end-to-end.
///
/// Captured HTML lives alongside each rule under
/// `Fixtures/phase-2.5/<site>/search.html`.
final class Phase25PrototypeTests: XCTestCase {
    private func fixturesBaseURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw XCTSkip("Fixtures bundle resource not found")
        }
        return url.appendingPathComponent("phase-2.5")
    }

    private func loadRule(_ slug: String) throws -> SourceRule {
        let url = try fixturesBaseURL().appendingPathComponent("\(slug)/rule.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SourceRule.self, from: data)
    }

    private func loader(_ slug: String, mapping: [String: String]) throws -> FixtureLoader {
        let dir = try fixturesBaseURL().appendingPathComponent(slug)
        return FixtureLoader(baseDirectory: dir, mapping: mapping)
    }

    // MARK: - 思兔閱讀

    func testSto9RuleDecodes() throws {
        let rule = try loadRule("sto9")
        XCTAssertEqual(rule.name, "思兔閱讀")
        XCTAssertEqual(rule.search?.method, .post)
        // No queryEncoding → defaults to UTF-8 at runtime.
        XCTAssertNil(rule.search?.queryEncoding)
    }

    func testSto9SearchParses() async throws {
        let rule = try loadRule("sto9")
        let source = RuleBasedBookSource(
            rule: rule,
            loader: try loader("sto9", mapping: [
                "https://sto9.com/search": "search.html"
            ])
        )
        let results = try await source.search("斗破苍穹")
        XCTAssertGreaterThanOrEqual(results.count, 1, "sto9 returned no results")
        let first = try XCTUnwrap(results.first)
        XCTAssertFalse(first.title.isEmpty)
        XCTAssertTrue(
            first.detailURL.absoluteString.hasPrefix("https://sto9.com/book/"),
            "unexpected detail URL: \(first.detailURL)"
        )
    }

    // MARK: - 同人圈 (GB18030)

    func testTongrenquanRuleDecodesWithGB18030QueryEncoding() throws {
        let rule = try loadRule("tongrenquan")
        XCTAssertEqual(rule.name, "同人圈")
        XCTAssertEqual(rule.search?.queryEncoding, .gb18030)
    }

    func testTongrenquanBodyExpansionUsesGB18030Bytes() throws {
        let rule = try loadRule("tongrenquan")
        let step = try XCTUnwrap(rule.search)
        let body = try URLTemplate.expand(
            try XCTUnwrap(step.bodyTemplate),
            query: "斗破苍穹",
            encoding: step.queryEncoding ?? .utf8
        )
        XCTAssertTrue(
            body.contains("keyboard=%B6%B7%C6%C6%B2%D4%F1%B7"),
            "expected GB18030 percent-bytes in body, got \(body)"
        )
    }

    func testTongrenquanSearchParses() async throws {
        let rule = try loadRule("tongrenquan")
        let source = RuleBasedBookSource(
            rule: rule,
            loader: try loader("tongrenquan", mapping: [
                "https://tongrenquan.org/e/search/indexstart.php": "search.html"
            ])
        )
        let results = try await source.search("斗破苍穹")
        XCTAssertGreaterThanOrEqual(results.count, 3, "tongrenquan returned <3 results")
        let first = try XCTUnwrap(results.first)
        XCTAssertTrue(first.title.contains("斗破"), "unexpected title: \(first.title)")
        XCTAssertTrue(
            first.detailURL.absoluteString.hasPrefix("https://tongrenquan.org/tongren/"),
            "unexpected detail URL: \(first.detailURL)"
        )
        XCTAssertNotNil(first.author)
    }
}
