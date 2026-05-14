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

    func testDisabledPreferenceDropsRuleFromEnabledSources() async throws {
        let keep = makeRule(name: "Keep", host: "k.invalid.test")
        let hide = makeRule(name: "Hide", host: "h.invalid.test")
        let preferences = InMemorySourcePreferenceStore(
            preferences: [
                hide.id: SourcePreference(ruleID: hide.id, isEnabled: false)
            ]
        )

        let registry = InternalSourceRegistry(
            editableStore: InMemoryEditableSourceStore(rules: []),
            loader: NoopLoader(),
            seededRules: [keep, hide],
            preferenceStore: preferences
        )

        let names = try await registry.enabledSources().map(\.displayName)
        XCTAssertEqual(names, ["Keep"])
    }

    func testPriorityPreferenceReordersEnabledSources() async throws {
        // Bundled rules are otherwise sorted by name; assert that an explicit
        // priority value flips that default so the user's manual reorder wins.
        let alpha = makeRule(name: "Alpha", host: "a.invalid.test")
        let zulu = makeRule(name: "Zulu", host: "z.invalid.test")
        let preferences = InMemorySourcePreferenceStore(
            preferences: [
                zulu.id: SourcePreference(ruleID: zulu.id, priority: 1),
                alpha.id: SourcePreference(ruleID: alpha.id, priority: 2)
            ]
        )

        let registry = InternalSourceRegistry(
            editableStore: InMemoryEditableSourceStore(rules: []),
            loader: NoopLoader(),
            seededRules: [alpha, zulu],
            preferenceStore: preferences
        )

        let names = try await registry.enabledSources().map(\.displayName)
        XCTAssertEqual(names, ["Zulu", "Alpha"])
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

private actor InMemorySourcePreferenceStore: SourcePreferenceStore {
    private var storage: [UUID: SourcePreference]
    init(preferences: [UUID: SourcePreference]) { self.storage = preferences }
    func loadAll() async throws -> [UUID: SourcePreference] { storage }
    func save(_ preference: SourcePreference) async throws {
        storage[preference.ruleID] = preference
    }
    func delete(ruleID: UUID) async throws { storage.removeValue(forKey: ruleID) }
    func replaceAll(_ preferences: [SourcePreference]) async throws {
        storage = Dictionary(uniqueKeysWithValues: preferences.map { ($0.ruleID, $0) })
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
