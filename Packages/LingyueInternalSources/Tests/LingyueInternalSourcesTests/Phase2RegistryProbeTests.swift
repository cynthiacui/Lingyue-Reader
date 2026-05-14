import XCTest
@testable import LingyueInternalSources
import LingyueCore

/// Phase 2 verification probe: makes sure every newly-seeded rule is
/// actually picked up by the bundle loader and surfaces through
/// `InternalSourceRegistry.searchableSources()` with the capabilities the
/// Discovery search bar expects (`supportsSearch` + `showInSearchBar`).
///
/// This is the "did the JSON drop into the right place" check — fixture
/// tests in `LingyueCore` already prove each rule's selectors parse a
/// real captured page, this one proves the rule reaches the runtime.
final class Phase2RegistryProbeTests: XCTestCase {
    private static let expectedSeededNames: Set<String> = [
        "思兔閱讀",
        "同人圈",
        "同人小说网",
        "破万卷小说",
        "52书库",
        "宙斯小说",
        "半夏小说",
        "努努书坊",
        "台灣小說網"
    ]

    func testBundledRulesIncludeAllPhase2Sources() {
        let names = Set(LingyueInternalSources.bundledRules().map(\.name))
        let missing = Self.expectedSeededNames.subtracting(names)
        XCTAssertTrue(
            missing.isEmpty,
            "Phase 2 seeded rules missing from bundle: \(missing.sorted())"
        )
    }

    func testEverySeededRuleIsSearchableAndShowsInSearchBar() {
        let rules = LingyueInternalSources.bundledRules()
            .filter { Self.expectedSeededNames.contains($0.name) }
        for rule in rules {
            XCTAssertTrue(
                rule.capabilities.supportsSearch,
                "\(rule.name): supportsSearch must be true"
            )
            XCTAssertTrue(
                rule.capabilities.showInSearchBar,
                "\(rule.name): showInSearchBar must be true"
            )
            XCTAssertNotNil(rule.search, "\(rule.name): search step must be present")
        }
    }

    func testRegistryEnabledSourcesIncludesSeededRules() async throws {
        let registry = InternalSourceRegistry(
            editableStore: NullEditableSourceStore(),
            loader: NullLoader()
        )
        let enabledNames = try await registry.enabledSources().map(\.displayName)
        let missing = Self.expectedSeededNames.subtracting(enabledNames)
        XCTAssertTrue(
            missing.isEmpty,
            "InternalSourceRegistry.enabledSources missing: \(missing.sorted())"
        )

        let searchableNames = try await registry.searchableSources().map(\.displayName)
        let missingSearchable = Self.expectedSeededNames.subtracting(searchableNames)
        XCTAssertTrue(
            missingSearchable.isEmpty,
            "InternalSourceRegistry.searchableSources missing: \(missingSearchable.sorted())"
        )
    }

    func testBundledRulesVersionBumped() {
        XCTAssertGreaterThanOrEqual(LingyueInternalSources.bundledRulesVersion, 2)
    }
}

// MARK: - Stubs

private struct NullEditableSourceStore: EditableSourceStore {
    func loadEditableSources() async throws -> [SourceRule] { [] }
    func saveEditableSource(_ rule: SourceRule) async throws {}
    func deleteSource(id: UUID) async throws {}
    func replaceAll(_ rules: [SourceRule]) async throws {}
}

private struct NullLoader: SourceHTMLLoading {
    func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        throw BookSourceError.unsupportedURL(request.url)
    }
    func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        throw BookSourceError.unsupportedURL(request.url)
    }
}
