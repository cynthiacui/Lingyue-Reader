import SwiftUI

struct ContentView: View {
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var themeManager = AppThemeManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack {
                LibraryView()
            }
                .tabItem {
                    Label("书架", systemImage: "books.vertical")
                }

            NavigationStack {
                DiscoveryView()
            }
                .tabItem {
                    Label("发现", systemImage: "sparkles")
                }

            NavigationStack {
                SettingsView()
            }
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
        .tint(themeManager.current.accent)
        .environmentObject(libraryStore)
        .environmentObject(themeManager)
        .environment(\.appTheme, themeManager.current)
        .preferredColorScheme(themeManager.current.preferredColorScheme)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                Task { await libraryStore.flush() }
            }
        }
    }
}

#Preview {
    ContentView()
}
