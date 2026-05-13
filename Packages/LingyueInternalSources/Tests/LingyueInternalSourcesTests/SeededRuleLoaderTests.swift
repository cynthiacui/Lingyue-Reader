import XCTest
@testable import LingyueInternalSources
import LingyueCore

/// Smoke tests for `SeededRuleLoader`. The point is to fail loudly if a
/// bundled JSON ever drifts from the `SourceRule` schema — a silently
/// undecodable seeded rule would just vanish at runtime.
final class SeededRuleLoaderTests: XCTestCase {

    func testBundledRulesDecodeCleanly() {
        let result = SeededRuleLoader.loadAll()
        XCTAssertTrue(
            result.decodeFailures.isEmpty,
            "Seeded rule JSON failed to decode: \(result.decodeFailures)"
        )
        XCTAssertFalse(
            result.rules.isEmpty,
            "Phase 2 ships at least the example seeded rule"
        )
    }

    func testRulesAreSortedDeterministically() {
        let first = SeededRuleLoader.loadAll().rules.map(\.id)
        let second = SeededRuleLoader.loadAll().rules.map(\.id)
        XCTAssertEqual(first, second)
    }

    func testExampleRuleIsPresent() {
        let rules = SeededRuleLoader.loadAll().rules
        let exampleID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
        XCTAssertTrue(rules.contains(where: { $0.id == exampleID }))
    }

    func testBundledRulesAccessorMatchesLoader() {
        XCTAssertEqual(
            LingyueInternalSources.bundledRules().map(\.id),
            SeededRuleLoader.loadAll().rules.map(\.id)
        )
    }
}
