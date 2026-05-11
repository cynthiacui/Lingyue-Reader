import SwiftUI

struct ContentView: View {
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var themeManager = AppThemeManager()
    @StateObject private var downloadManager = BookDownloadManager()
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
        .environmentObject(libraryStore)
        .environmentObject(themeManager)
        .environmentObject(downloadManager)
        .environment(\.appTheme, effectiveTheme)
        .preferredColorScheme(chromeOverride)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                Task { await libraryStore.flush() }
            }
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
