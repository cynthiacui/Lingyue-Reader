import XCTest
@testable import LingyueInternalSources
import LingyueCore

/// Behavior tests for `InternalSourceRegistry`'s merge + priority
/// semantics. Uses an in-memory `EditableSourceStore` stub plus a stub
/// loader (never called in these tests — the registry only constructs
/// `RuleBasedBookSource`s, it does not exercise them).
final class InternalSourceRegistryTests: XCTestCase {

    func testEnabledSourcesMergesUserBundledAndFastPathInOrder() async throws {
        let userRule = makeRule(name: "User", host: "user.invalid.test")
        let seededRule = makeRule(name: "Seeded", host: "seeded.invalid.test")
        let adapter = StubAdapter(id: "internal:stub", supportsSearch: true)

        let registry = InternalSourceRegistry(
            editableStore: InMemoryEditableSourceStore(rules: [userRule]),
            loader: NoopLoader(),
            fastPathAdapters: [adapter],
            seededRules: [seededRule]
        )

        let sources = try await registry.enabledSources()
        XCTAssertEqual(sources.map(\.displayName), ["User", "Seeded", "internal-stub"])
    }

    func testUserRuleSuppressesSeededRuleWithSameUUID() async throws {
        let id = UUID()
        let userVersion = makeRule(id: id, name: "User override", host: "x.invalid.test")
        let seededVersion = makeRule(id: id, name: "Seeded original", host: "x.invalid.test")

        let registry = InternalSourceRegistry(
            editableStore: InMemoryEditableSourceStore(rules: [userVersion]),
            loader: NoopLoader(),
            seededRules: [seededVersion]
        )

        let names = try await registry.enabledSources().map(\.displayName)
        XCTAssertEqual(names, ["User override"])
    }

    func testSearchableSourcesFiltersByCapability() async throws {
        let searchable = makeRule(name: "Searchable", host: "a.invalid.test", supportsSearch: true)
        let browserOnly = makeRule(name: "Browse only", host: "b.invalid.test", supportsSearch: false)

        let registry = InternalSourceRegistry(
            editableStore: InMemoryEditableSourceStore(rules: []),
            loader: NoopLoader(),
            seededRules: [searchable, browserOnly]
        )

        let names = try await registry.searchableSources().map(\.displayName)
        XCTAssertEqual(names, ["Searchable"])
    }

    func testSourceByIDFindsRuleAndAdapter() async throws {
        let rule = makeRule(name: "R", host: "r.invalid.test")
        let adapter = StubAdapter(id: "internal:adapter", supportsSearch: true)

        let registry = InternalSourceRegistry(
            editableStore: InMemoryEditableSourceStore(rules: [rule]),
            loader: NoopLoader(),
            fastPathAdapters: [adapter],
            seededRules: []
        )

        let ruleHit = try await registry.source(withID: "rule:\(rule.id.uuidString)")
        XCTAssertEqual(ruleHit?.displayName, "R")

        let adapterHit = try await registry.source(withID: "internal:adapter")
        XCTAssertEqual(adapterHit?.displayName, "internal-adapter")

        let miss = try await registry.source(withID: "rule:\(UUID().uuidString)")
        XCTAssertNil(miss)
    }

    // MARK: - Helpers

    private func makeRule(
        id: UUID = UUID(),
        name: String,
        host: String,
        supportsSearch: Bool = true
    ) -> SourceRule {
        SourceRule(
            id: id,
            name: name,
            homepage: URL(string: "https://\(host)/")!,
            capabilities: SourceCapabilities(
                supportsSearch: supportsSearch,
                showInSearchBar: supportsSearch,
                supportsBrowserImport: true,
                requiresWebRender: false
            ),
            detection: DetectionStep(hostPatterns: [host]),
            search: supportsSearch ? SearchStep(
                urlTemplate: "https://\(host)/s?q={query}",
                resultsSelector: "li",
                titleField: FieldSelector(selector: "a"),
                detailURLField: FieldSelector(selector: "a", attribute: "href")
            ) : nil,
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
                titleField: FieldSelector(selector: "h2"),
                bodyField: FieldSelector(selector: "div")
            )
        )
    }
}

// MARK: - Stubs

private struct NoopLoader: SourceHTMLLoading {
    func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        throw BookSourceError.loadFailed(reason: "noop")
    }
    func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        throw BookSourceError.loadFailed(reason: "noop")
    }
}

private actor InMemoryEditableSourceStore: EditableSourceStore {
    private var storage: [SourceRule]
    init(rules: [SourceRule]) { self.storage = rules }
    func loadEditableSources() async throws -> [SourceRule] { storage }
    func saveEditableSource(_ rule: SourceRule) async throws {
        if let idx = storage.firstIndex(where: { $0.id == rule.id }) {
            storage[idx] = rule
        } else {
            storage.append(rule)
        }
    }
    func deleteSource(id: UUID) async throws {
        storage.removeAll { $0.id == id }
    }
    func replaceAll(_ rules: [SourceRule]) async throws { storage = rules }
}

private struct StubAdapter: BookSource {
    let id: String
    let supportsSearch: Bool
    var displayName: String { id.replacingOccurrences(of: ":", with: "-") }
    var capabilities: SourceCapabilities {
        SourceCapabilities(
            supportsSearch: supportsSearch,
            showInSearchBar: supportsSearch,
            supportsBrowserImport: true,
            requiresWebRender: false
        )
    }
    func search(_ query: String) async throws -> [BookSearchResult] { [] }
    func detectBook(in page: WebPageSnapshot) async throws -> BookDetection? { nil }
    func fetchDetail(url: URL) async throws -> BookDetail {
        throw BookSourceError.unsupportedURL(url)
    }
    func fetchCatalog(url: URL) async throws -> [ChapterLink] { [] }
    func fetchChapter(url: URL) async throws -> ChapterContent {
        throw BookSourceError.unsupportedURL(url)
    }
}
