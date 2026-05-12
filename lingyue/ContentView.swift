import SwiftUI

struct ContentView: View {
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var themeManager = AppThemeManager()
    @StateObject private var downloadManager = BookDownloadManager()
    @StateObject private var overlayManager = OverlayManager()
    @State private var selectedTab: AppTab = .library
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        let effectiveTheme = themeManager.effectiveTheme(for: systemColorScheme)
        // When follow-system is on we must NOT apply `.preferredColorScheme`. That modifier
        // propagates up to the window and overrides its colorScheme — which would feed back
        // into `@Environment(\.colorScheme)` and lock the app into the override (dark→light
        // system flips would never escape). Letting the override go nil here keeps the
        // window's colorScheme tied to the actual system trait.
        let chromeOverride: ColorScheme? = themeManager.followSystemDark
            ? nil
            : themeManager.current.preferredColorScheme
        TabView(selection: $selectedTab) {
            NavigationStack {
                LibraryView()
            }
                .tabItem {
                    Label("书架", systemImage: "books.vertical")
                }
                .tag(AppTab.library)

            NavigationStack {
                DiscoveryView()
            }
                .tabItem {
                    Label("发现", systemImage: "sparkles")
                }
                .tag(AppTab.discovery)

            NavigationStack {
                ReadingStatsView()
            }
                .tabItem {
                    Label("统计", systemImage: "chart.bar.xaxis")
                }
                .tag(AppTab.stats)

            NavigationStack {
                SettingsView()
            }
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
        .tint(effectiveTheme.accent)
        .preferredColorScheme(chromeOverride)
        // Render transient popups above the navigation chrome and tab bar so
        // the dim layer covers the whole window — otherwise the toolbar /
        // search drawer / tab bar paint over the dim and look highlighted.
        // Environment values are injected AFTER the overlay so its content
        // inherits the same theme / stores as the TabView (overlay siblings
        // sit outside any environment applied before `.overlay`).
        .overlay {
            if let presentation = overlayManager.presentation {
                presentation.view
                    .id(presentation.id)
                    .transition(ModalStyle.transition)
            }
        }
        .animation(ModalStyle.presentationAnimation, value: overlayManager.presentation?.id)
        .environmentObject(libraryStore)
        .environmentObject(themeManager)
        .environmentObject(downloadManager)
        .environmentObject(overlayManager)
        .environment(\.appTheme, effectiveTheme)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                Task { await libraryStore.flush() }
            }
        }
        // Touch the reader-diagnostics singleton at launch so the prior
        // session's `current.json` rotates to `previous.json` even when the
        // user never opens the reader this run — otherwise a previous
        // session's log could be silently overwritten on the next-next launch.
        .task {
            _ = ReaderDiagnostics.shared
        }
    }
}

private enum AppTab: Hashable {
    case stats
    case library
    case discovery
    case settings
}

#Preview {
    ContentView()
}
