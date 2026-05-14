import Foundation
import SwiftUI
import LingyueCore
import LingyueInternalSources

/// Bundle of the long-lived rule-engine values the rest of the app needs
/// to reach: the HTTP/web composite loader, the user-authored rule store,
/// and the `BookSourceRegistry` that merges them with the seeded rule
/// bundle and any fast-path adapters.
///
/// Phase 2 wiring deliberately stops one step short of routing the legacy
/// `BookImportService` through this registry — that swap is gated behind
/// a UserDefaults flag in Phase 2.4. The point of constructing the stack
/// at launch now is so Settings → Sources, the rule editor (Phase 3), and
/// the in-app browser detector (Phase 4) can read from a single shared
/// registry instance instead of each manufacturing its own.
///
/// Phase 5 splits the app into two targets. **This file is Internal-only**
/// — it imports `LingyueInternalSources` and instantiates
/// `InternalSourceRegistry`. The `LingyueAppStore` target will ship a
/// parallel `AppStoreSourceStack` (no internal import, `AppStoreSourceRegistry`).
struct SourceStack: Sendable {
    let loader: any SourceHTMLLoading
    let editableStore: any EditableSourceStore
    let preferenceStore: any SourcePreferenceStore
    // Module-qualified: the legacy `enum BookSourceRegistry` in
    // Models/Novel.swift shadows the LingyueCore protocol of the same
    // name. Phase 2.4 removes the enum once `BookImportService` migrates
    // onto this registry — the qualifier can drop at that point.
    let registry: any LingyueCore.BookSourceRegistry

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
        let registry = InternalSourceRegistry(
            editableStore: store,
            loader: loader,
            fastPathAdapters: [
                FivedxsBookSource(loader: loader),
                BiqugeAPIBookSource(loader: loader)
            ],
            preferenceStore: preferenceStore
        )
        return SourceStack(
            loader: loader,
            editableStore: store,
            preferenceStore: preferenceStore,
            registry: registry
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
