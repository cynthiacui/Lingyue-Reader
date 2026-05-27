import SwiftUI

struct ContentView: View {
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var themeManager = AppThemeManager()
    @StateObject private var downloadManager = BookDownloadManager()
    @StateObject private var overlayManager = OverlayManager()
    @StateObject private var tabSelection = TabSelectionStore()
    // Root-owned so `lingyue://import?url=…` deep links resolve regardless
    // of the foreground tab; the confirm dialog is presented here, not
    // inside the Sources tab. `SourcesListView` reaches the same instance
    // via `@EnvironmentObject` for its in-app import entries.
    @StateObject private var importCoordinator = SourceImportCoordinator()
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
        TabView(selection: $tabSelection.selectedTab) {
            NavigationStack {
                LibraryView()
            }
                .tabItem {
                    Label("书架", systemImage: "books.vertical")
                }
                .tag(AppTab.library)

            NavigationStack {
                DiscoveryAppStoreView()
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
                MeView()
            }
                .tabItem {
                    Label("我", systemImage: "person.crop.circle")
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
        .environmentObject(tabSelection)
        .environmentObject(importCoordinator)
        .environment(\.appTheme, effectiveTheme)
        .environment(\.sourceStack, .live)
        .onOpenURL { url in
            importCoordinator.handleDeepLink(url)
        }
        // Shared import confirm. Driven by `importCoordinator.staged`,
        // which any channel (file picker, URL, clipboard, QR, deep link)
        // sets after decode + diff. Presented at the root so a deep-link
        // import works from any tab.
        .alert(
            "导入书源",
            isPresented: Binding(
                get: { importCoordinator.staged != nil },
                set: { if !$0 { importCoordinator.staged = nil } }
            ),
            presenting: importCoordinator.staged
        ) { staged in
            Button("取消", role: .cancel) { importCoordinator.staged = nil }
            Button("导入（\(staged.summary.totalChanging) 项）") {
                Task { await importCoordinator.apply() }
            }
            .disabled(staged.summary.totalChanging == 0)
        } message: { staged in
            Text(importCoordinator.dialogMessage(for: staged.summary))
        }
        .alert(
            "导入失败",
            isPresented: Binding(
                get: { importCoordinator.errorMessage != nil },
                set: { if !$0 { importCoordinator.errorMessage = nil } }
            ),
            presenting: importCoordinator.errorMessage
        ) { _ in
            Button("好") { importCoordinator.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .overlay {
            if importCoordinator.isFetching {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView("正在下载书源…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                Task { await libraryStore.flush() }
            }
        }
        // Touch the reader-diagnostics singleton at launch so the prior
        // session's `current.json` rotates to `previous.json` even when the
        // user never opens the reader this run — otherwise a previous
        // session's log could be silently overwritten on the next-next launch.
        // Also probe the source registry so a misconfiguration (corrupt
        // user-sources.json, missing seeded-rule resources) surfaces in
        // diagnostics at launch instead of the first time the user opens
        // Settings → Sources.
        .task {
            _ = ReaderDiagnostics.shared
            do {
                let count = try await SourceStack.live.registry.enabledSources().count
                ReaderDiagnostics.shared.log(.lifecycle, "source registry ready", context: [
                    "count": String(count)
                ])
            } catch {
                ReaderDiagnostics.shared.log(.lifecycle, "source registry init failed", context: [
                    "error": String(describing: error)
                ])
            }
        }
    }
}

enum AppTab: Hashable {
    case stats
    case library
    case discovery
    case settings
}

/// Holds the active tab so deep links inside one tab (e.g. tapping the 我 hero card
/// to jump to 统计) can drive the `TabView` selection without threading a binding
/// through every intermediate view. Injected as `@EnvironmentObject` at the root.
@MainActor
final class TabSelectionStore: ObservableObject {
    @Published var selectedTab: AppTab = .library
}

#Preview {
    ContentView()
}
