import Foundation
import LingyueCore

/// `BookSourceRegistry` for the public App Store target. Returns only
/// user-authored rules from `EditableSourceStore` — no seeded rules,
/// no fast-path adapters, no internal-only hosts. This is the
/// compile-time guarantee Phase 5 leans on: `LingyueAppStore` does not
/// link `LingyueInternalSources`, so even if a developer
/// accidentally tried to reach for the seeded set from the App Store
/// target, the import would not resolve.
///
/// The Internal target uses `InternalSourceRegistry` instead, which
/// merges seeded rules + fast-path adapters on top of the same
/// editable store.
///
/// The conformance is module-qualified: the legacy `enum
/// BookSourceRegistry` in `Models/Novel.swift` shadows the
/// `LingyueCore` protocol of the same name. That enum is removed by
/// Phase 2.4 when `BookImportService` migrates onto the new registry;
/// once it's gone the qualifier can drop.
public struct AppStoreSourceRegistry: LingyueCore.BookSourceRegistry {
    private let editableStore: any EditableSourceStore
    private let loader: any SourceHTMLLoading

    public init(
        editableStore: any EditableSourceStore,
        loader: any SourceHTMLLoading
    ) {
        self.editableStore = editableStore
        self.loader = loader
    }

    public func enabledSources() async throws -> [any BookSource] {
        let rules = try await editableStore.loadEditableSources()
        return rules.map { RuleBasedBookSource(rule: $0, loader: loader) }
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
