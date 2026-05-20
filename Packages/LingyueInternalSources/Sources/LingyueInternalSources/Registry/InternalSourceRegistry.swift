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
    private let preferenceStore: (any SourcePreferenceStore)?

    public init(
        editableStore: any EditableSourceStore,
        loader: any SourceHTMLLoading,
        fastPathAdapters: [any BookSource] = [],
        seededRules: [SourceRule]? = nil,
        preferenceStore: (any SourcePreferenceStore)? = nil
    ) {
        self.editableStore = editableStore
        self.loader = loader
        self.fastPathAdapters = fastPathAdapters
        self.seededRules = seededRules ?? SeededRuleLoader.loadAll().rules
        self.preferenceStore = preferenceStore
    }

    public func enabledSources() async throws -> [any BookSource] {
        let userRules = try await editableStore.loadEditableSources()
        let userIDs = Set(userRules.map(\.id))
        let bundled = seededRules.filter { !userIDs.contains($0.id) }

        // Resolve the user's per-rule preferences once up front. nil store ==
        // "no opinion anywhere" — keeps tests and the App Store target's
        // bootstrap path working without a preference file.
        let preferences: [UUID: SourcePreference]
        if let preferenceStore {
            preferences = (try? await preferenceStore.loadAll()) ?? [:]
        } else {
            preferences = [:]
        }

        // Drop rules the user explicitly disabled. Fast-path adapters carry
        // no UUID, so the preference layer is rule-only — adapters always
        // pass through (their enable/disable, when we need it, will live on
        // their own settings surface).
        let enabledUserRules = userRules.filter { preferences[$0.id]?.isEnabled ?? true }
        let enabledBundled = bundled.filter { preferences[$0.id]?.isEnabled ?? true }

        // Stable sort within each rule bucket: priority asc, then name asc.
        // `Int.max` is the default for unknown keys, so freshly-seeded rules
        // sink to the bottom until the user reorders them — but they stay
        // visible, never hidden by missing preference state.
        func key(_ rule: SourceRule) -> (Int, String) {
            (preferences[rule.id]?.priority ?? .max, rule.name)
        }
        let sortedUser = enabledUserRules.sorted { key($0) < key($1) }
        let sortedBundled = enabledBundled.sorted { key($0) < key($1) }

        let userSources: [any BookSource] = sortedUser.map { $0.makeBookSource(loader: loader) }
        let bundledSources: [any BookSource] = sortedBundled.map { $0.makeBookSource(loader: loader) }
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
