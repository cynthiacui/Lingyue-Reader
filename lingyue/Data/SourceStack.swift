import Foundation
import SwiftUI
import LingyueCore
#if LINGYUE_INTERNAL
import LingyueInternalSources
#endif

/// Bundle of the long-lived rule-engine values the rest of the app needs
/// to reach: the HTTP/web composite loader, the user-authored rule store,
/// and the `BookSourceRegistry` that resolves rules for both registry
/// flavors.
///
/// The struct shape is shared across both Phase 5 targets — the only
/// thing that differs is which registry `live` instantiates:
///
/// - `LINGYUE_INTERNAL` build → `InternalSourceRegistry` with seeded
///   rules and fast-path adapters on top of the editable store.
/// - App Store build → `AppStoreSourceRegistry`, which reads from the
///   editable store alone. No seeded rules, no fast-path adapters, no
///   `LingyueInternalSources` link at compile time.
///
/// Phase 5 specifically: keeping a single `SourceStack` (instead of a
/// parallel `AppStoreSourceStack` type) means every call site —
/// Settings, Discovery, the in-app browser, the rule editor — stays
/// target-agnostic. The compile-time fork lives here, once.
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
    /// The fast-path adapter list grows here as adapters become
    /// usable. Order matters: registry methods (`source(withID:)`,
    /// `enabledSources()`) return them in this order, so list the
    /// most-specific URL recognizer first when two adapters could
    /// claim the same host.
    static let live: SourceStack = {
        let loader = CompositeSourceLoader()
        let store = FileEditableSourceStore()
        let preferenceStore = FileSourcePreferenceStore()
        let validationStore = FileSourceValidationStore()
        let registry: any LingyueCore.BookSourceRegistry
#if LINGYUE_INTERNAL
        registry = InternalSourceRegistry(
            editableStore: store,
            loader: loader,
            fastPathAdapters: [
                FivedxsBookSource(loader: loader),
                BiqugeAPIBookSource(loader: loader)
            ],
            preferenceStore: preferenceStore
        )
#else
        registry = AppStoreSourceRegistry(
            editableStore: store,
            loader: loader,
            preferenceStore: preferenceStore
        )
#endif
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
