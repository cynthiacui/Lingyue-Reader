import Foundation
import LingyueCore

/// Internal-target `BookSourceRegistry`. Merges three groups:
///
/// 1. User-authored rules from `EditableSourceStore` (highest priority,
///    so a tester can patch a broken seeded rule without waiting for
///    an app update).
/// 2. Bundled `SeededRuleLoader` rules.
/// 3. Fast-path adapters — hand-written `BookSource` conformers for
///    sites whose parsing the rule schema can't yet express.
///
/// De-duplication is by `SourceRule.id`: when a user rule shares a
/// UUID with a seeded rule, the user copy wins. Fast-path adapter IDs
/// (`internal:<slug>`) never collide with rule IDs (`rule:<uuid>`).
///
/// `enabledSources()` is the source of truth for ordering. Every other
/// method derives from it, including `searchableSources()` which is
/// what the Discovery search bar consumes.
public struct InternalSourceRegistry: BookSourceRegistry {
    private let editableStore: any EditableSourceStore
    private let loader: any SourceHTMLLoading
    private let fastPathAdapters: [any BookSource]
    private let seededRules: [SourceRule]

    public init(
        editableStore: any EditableSourceStore,
        loader: any SourceHTMLLoading,
        fastPathAdapters: [any BookSource] = [],
        seededRules: [SourceRule]? = nil
    ) {
        self.editableStore = editableStore
        self.loader = loader
        self.fastPathAdapters = fastPathAdapters
        self.seededRules = seededRules ?? SeededRuleLoader.loadAll().rules
    }

    public func enabledSources() async throws -> [any BookSource] {
        let userRules = try await editableStore.loadEditableSources()
        let userIDs = Set(userRules.map(\.id))
        let bundled = seededRules.filter { !userIDs.contains($0.id) }
        let userSources: [any BookSource] = userRules.map {
            RuleBasedBookSource(rule: $0, loader: loader)
        }
        let bundledSources: [any BookSource] = bundled.map {
            RuleBasedBookSource(rule: $0, loader: loader)
        }
        return userSources + bundledSources + fastPathAdapters
    }

    public func searchableSources() async throws -> [any BookSource] {
        try await enabledSources().filter { source in
            source.capabilities.supportsSearch && source.capabilities.showInSearchBar
        }
    }

    public func source(withID id: String) async throws -> (any BookSource)? {
        try await enabledSources().first { $0.id == id }
    }
}
