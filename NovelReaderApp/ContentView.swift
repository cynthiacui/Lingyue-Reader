import SwiftUI

struct ContentView: View {
    @StateObject private var libraryStore = LibraryStore()
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
        .tint(.readerAccent)
        .environmentObject(libraryStore)
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
