import SwiftUI

/// Hosts transient popups (input modals, picker sheets) at the root of the
/// view hierarchy so the dim layer renders above the navigation chrome and
/// tab bar — otherwise the toolbar buttons / search drawer / tab bar paint
/// over the dim with their own materials, looking highlighted instead of
/// receding into the background like the rest of the content.
@MainActor
final class OverlayManager: ObservableObject {
    @Published private(set) var presentation: Presentation?

    struct Presentation: Identifiable {
        let id = UUID()
        let view: AnyView
    }

    func present<Content: View>(@ViewBuilder _ build: () -> Content) {
        presentation = Presentation(view: AnyView(build()))
    }

    func dismiss() {
        presentation = nil
    }
}
