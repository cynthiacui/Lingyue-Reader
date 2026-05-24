import Foundation
import LingyueCore

/// `BookSourceRegistry` for the public App Store target. Returns only
/// user-authored rules from `EditableSourceStore` — no seeded rules
/// and no built-in hosts.
///
/// The conformance is module-qualified: the legacy `enum
/// BookSourceRegistry` in `Models/Novel.swift` shadows the
/// `LingyueCore` protocol of the same name. Once the enum is removed,
/// the qualifier can drop.
public struct AppStoreSourceRegistry: LingyueCore.BookSourceRegistry {
    private let editableStore: any EditableSourceStore
    private let loader: any SourceHTMLLoading
    private let preferenceStore: (any SourcePreferenceStore)?

    public init(
        editableStore: any EditableSourceStore,
        loader: any SourceHTMLLoading,
        preferenceStore: (any SourcePreferenceStore)? = nil
    ) {
        self.editableStore = editableStore
        self.loader = loader
        self.preferenceStore = preferenceStore
    }

    public func enabledSources() async throws -> [any BookSource] {
        let rules = try await editableStore.loadEditableSources()
        let preferences: [UUID: SourcePreference]
        if let preferenceStore {
            preferences = (try? await preferenceStore.loadAll()) ?? [:]
        } else {
            preferences = [:]
        }
        let visible = rules.filter { preferences[$0.id]?.isEnabled ?? true }
        let sorted = visible.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return sorted.map { $0.makeBookSource(loader: loader) }
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
