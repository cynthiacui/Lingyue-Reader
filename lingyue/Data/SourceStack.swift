import Foundation
import SwiftUI
import LingyueCore

/// Bundle of the long-lived rule-engine values the rest of the app needs
/// to reach: the HTTP/web composite loader, the user-authored rule store,
/// and the `BookSourceRegistry` that resolves rules from the editable
/// store.
struct SourceStack: Sendable {
    let loader: any SourceHTMLLoading
    let editableStore: any EditableSourceStore
    let preferenceStore: any SourcePreferenceStore
    let validationStore: any SourceValidationStore
    // Module-qualified: the legacy `enum BookSourceRegistry` in
    // Models/Novel.swift shadows the LingyueCore protocol of the same
    // name. Phase 2.4 removes the enum once `BookImportService` migrates
    // onto this registry — the qualifier can drop at that point.
    let registry: any LingyueCore.BookSourceRegistry
    /// Phase 4: the in-app browser's fan-out detector. Constructed once
    /// at launch so the URL cache survives navigation within a session.
    /// Cache invalidation hooks (slice 5) call `invalidateCache()` on
    /// every source-set change (toggle, reorder, save, delete, validate).
    let pageDetector: PageDetector

    /// Process-wide default. Constructed lazily on first access so unit
    /// tests can inject their own stack without paying the WebView
    /// renderer's startup cost.
    ///
    /// Sources whose parsing the rule schema can't express in plain HTML
    /// terms ride in through user-imported rules with a `jsonAPI` config
    /// block — the rule's UUID is the persisted identity, and
    /// `SourceRule.makeBookSource(loader:)` swaps in `JSONAPIBookSource`
    /// at registry-build time. The engine is fully generic; every URL,
    /// ID-extraction regex, JSON path, and boilerplate fragment lives
    /// in the rule JSON.
    static let live: SourceStack = {
        let loader = CompositeSourceLoader()
        let store = FileEditableSourceStore()
        let preferenceStore = FileSourcePreferenceStore()
        let validationStore = FileSourceValidationStore()
        let registry: any LingyueCore.BookSourceRegistry = AppStoreSourceRegistry(
            editableStore: store,
            loader: loader,
            preferenceStore: preferenceStore
        )
        return SourceStack(
            loader: loader,
            editableStore: store,
            preferenceStore: preferenceStore,
            validationStore: validationStore,
            registry: registry,
            pageDetector: PageDetector(registry: registry)
        )
    }()
}

private struct SourceStackKey: EnvironmentKey {
    static let defaultValue: SourceStack = .live
}

extension EnvironmentValues {
    /// Read with `@Environment(\.sourceStack)` from any view that needs to
    /// reach the registry or editable store. Views obtain a snapshot —
    /// `enabledSources()` is async so callers run it inside `.task` /
    /// `Task {}` and observe results through their own state.
    var sourceStack: SourceStack {
        get { self[SourceStackKey.self] }
        set { self[SourceStackKey.self] = newValue }
    }
}
