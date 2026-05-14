import XCTest
@testable import LingyueCore

/// Phase 2 — exit-criteria fixture tests for the remaining seeded rules
/// authored after the Phase 2.5 schema fitness check. Each case drives
/// `RuleBasedBookSource` through real captured search HTML and asserts the
/// rule extracts the expected fields. These are *expressiveness* tests:
/// if a rule's selectors can't pull a usable result out of a real page,
/// we want to know before shipping.
///
/// Captured HTML for each source lives at
/// `Fixtures/phase-2.5/<slug>/search.html` (UTF-8 transcoded where the
/// upstream encoding is GB18030). Rule JSON sits alongside as
/// `rule.json` and is also shipped from `LingyueInternalSources`'s
/// `Resources/SeededRules/<slug>.json` — the two are kept in lockstep so
/// fixture passes mirror production behavior.
final class Phase2SeededRuleTests: XCTestCase {
    private struct Case {
        let slug: String
        let expectedName: String
        let endpoint: String
        let detailURLPrefix: String
        let queryEncoding: SourceEncoding?
        let minResults: Int
    }

    private static let cases: [Case] = [
        Case(
            slug: "trxs",
            expectedName: "同人小说网",
            endpoint: "https://trxs.org/e/search/index.php",
            detailURLPrefix: "https://trxs.org/tongren/",
            queryEncoding: .gb18030,
            minResults: 1
        ),
        Case(
            slug: "powanjuan",
            expectedName: "破万卷小说",
            endpoint: "https://www.powanjuan.cc/e/search/index.php",
            detailURLPrefix: "https://www.powanjuan.cc/",
            queryEncoding: .gb18030,
            minResults: 2
        ),
        Case(
            slug: "52shuku",
            expectedName: "52书库",
            endpoint: "https://www.52shuku.net/so/search.php?q=%E6%96%97%E7%A0%B4",
            detailURLPrefix: "https://www.52shuku.net/",
            queryEncoding: nil,
            minResults: 3
        ),
        Case(
            slug: "zhswx",
            expectedName: "宙斯小说",
            endpoint: "https://www.zhswx.com/list/%E6%96%97%E7%A0%B4.html",
            detailURLPrefix: "https://www.zhswx.com/book/",
            queryEncoding: nil,
            minResults: 3
        ),
        Case(
            slug: "xbanxia",
            expectedName: "半夏小说",
            endpoint: "https://www.xbanxia.cc/modules/article/search_t.php",
            detailURLPrefix: "https://www.xbanxia.cc/books/",
            queryEncoding: nil,
            minResults: 3
        ),
        Case(
            slug: "nunu",
            expectedName: "努努书坊",
            endpoint: "https://www.nunucom.com/search/",
            detailURLPrefix: "https://www.nunucom.com/",
            queryEncoding: nil,
            minResults: 2
        ),
        Case(
            slug: "xsw",
            expectedName: "台灣小說網",
            endpoint: "https://www.xsw.tw/modules/article/search.php?searchtype=articlename&searchkey=%E6%96%97%E7%A0%B4",
            detailURLPrefix: "https://www.xsw.tw/",
            queryEncoding: nil,
            minResults: 3
        )
    ]

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

    func testAllSeededRulesDecodeAndParse() async throws {
        for c in Self.cases {
            let rule = try loadRule(c.slug)
            XCTAssertEqual(rule.name, c.expectedName, "\(c.slug): name mismatch")
            XCTAssertEqual(
                rule.search?.queryEncoding,
                c.queryEncoding,
                "\(c.slug): queryEncoding mismatch"
            )

            let source = RuleBasedBookSource(
                rule: rule,
                loader: try loader(c.slug, mapping: [c.endpoint: "search.html"])
            )
            let results = try await source.search("斗破")
            XCTAssertGreaterThanOrEqual(
                results.count,
                c.minResults,
                "\(c.slug): expected ≥\(c.minResults) results, got \(results.count)"
            )

            guard let first = results.first else {
                XCTFail("\(c.slug): no results parsed")
                continue
            }
            XCTAssertFalse(first.title.isEmpty, "\(c.slug): empty title")
            XCTAssertTrue(
                first.detailURL.absoluteString.hasPrefix(c.detailURLPrefix),
                "\(c.slug): detail URL \(first.detailURL) did not start with \(c.detailURLPrefix)"
            )
        }
    }
}
