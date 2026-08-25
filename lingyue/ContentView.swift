import SwiftUI

struct AppUpdateAnnouncementBullet: Identifiable, Equatable {
    let icon: String
    let text: String

    var id: String { "\(icon):\(text)" }
}

enum AppUpdateAnnouncement: String, Identifiable, Equatable {
    case libraryArchiveV1_2 = "library-archive-1.2"

    var id: String { rawValue }

    var introducedInVersion: String {
        switch self {
        case .libraryArchiveV1_2:
            return "1.2"
        }
    }

    var icon: String {
        switch self {
        case .libraryArchiveV1_2:
            return "archivebox.fill"
        }
    }

    var eyebrow: String {
        switch self {
        case .libraryArchiveV1_2:
            return "本次更新"
        }
    }

    var title: String {
        switch self {
        case .libraryArchiveV1_2:
            return "书架新增「已归档」"
        }
    }

    var summary: String {
        switch self {
        case .libraryArchiveV1_2:
            return "看完后还想继续保留的书，现在可以放进「已归档」。"
        }
    }

    var bullets: [AppUpdateAnnouncementBullet] {
        switch self {
        case .libraryArchiveV1_2:
            return [
                AppUpdateAnnouncementBullet(
                    icon: "hand.tap",
                    text: "长按书籍，或左滑后点“分类书籍”，即可选择归档"
                ),
                AppUpdateAnnouncementBullet(
                    icon: "book.closed",
                    text: "归档后会离开原来的分类，但书籍、阅读进度和记录都还在"
                ),
                AppUpdateAnnouncementBullet(
                    icon: "arrow.right.arrow.left",
                    text: "在书架底部打开「已归档」，也可以再把书移动到其他分类"
                ),
                AppUpdateAnnouncementBullet(
                    icon: "arrow.up.arrow.down",
                    text: "长按分类标题，就能拖动调整分类顺序"
                )
            ]
        }
    }
}

/// Decides whether this launch belongs to a fresh install or an update, then exposes
/// versioned announcements one at a time. The first-installed version is written before
/// the rest of the app creates any storage, so a fresh install remains in the fresh-install
/// cohort across relaunches. For users upgrading from builds that predate this marker, any
/// existing app defaults or Application Support data is treated as legacy-install evidence.
///
/// Each announcement owns a stable identifier and introduction version. Adding a future
/// announcement therefore doesn't require another one-off boolean or custom launch path.
final class AppUpdateAnnouncementStore: ObservableObject {
    static let firstInstalledVersionKey = "app.firstInstalledVersion"
    static let seenKeyPrefix = "app.updateAnnouncement.seen."
    static let forceShowArgument = "--show-update-announcement"

    @Published private(set) var pendingAnnouncement: AppUpdateAnnouncement?
    let isExistingInstallation: Bool

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        persistentDomainName: String? = nil,
        currentVersion: String? = nil,
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default,
        arguments: [String] = CommandLine.arguments
    ) {
        self.defaults = defaults

        let resolvedDomainName = persistentDomainName
            ?? Bundle.main.bundleIdentifier
            ?? "com.lingyue.reader"
        let resolvedCurrentVersion = currentVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "0"
        let resolvedSupportDirectory = applicationSupportDirectory
            ?? Self.defaultApplicationSupportDirectory(fileManager: fileManager)

        let firstInstalledVersion: String
        if let storedVersion = defaults.string(forKey: Self.firstInstalledVersionKey) {
            firstInstalledVersion = storedVersion
        } else {
            let hadLegacyInstallation = Self.hasLegacyInstallationEvidence(
                defaults: defaults,
                persistentDomainName: resolvedDomainName,
                applicationSupportDirectory: resolvedSupportDirectory,
                fileManager: fileManager
            )
            firstInstalledVersion = hadLegacyInstallation ? "0" : resolvedCurrentVersion
            defaults.set(firstInstalledVersion, forKey: Self.firstInstalledVersionKey)
        }

        isExistingInstallation = Self.isVersion(
            firstInstalledVersion,
            olderThan: resolvedCurrentVersion
        )

        let announcement = AppUpdateAnnouncement.libraryArchiveV1_2
        let featureIsAvailable = !Self.isVersion(
            resolvedCurrentVersion,
            olderThan: announcement.introducedInVersion
        )
        let installationPredatesFeature = Self.isVersion(
            firstInstalledVersion,
            olderThan: announcement.introducedInVersion
        )
        let hasSeenAnnouncement = defaults.bool(forKey: Self.seenKey(for: announcement))
        let suppressesLaunchUI = arguments.contains("--screenshot-fixture")
        let forcesAnnouncement = arguments.contains(Self.forceShowArgument)

        pendingAnnouncement = forcesAnnouncement
            ? announcement
            : featureIsAvailable
                && installationPredatesFeature
                && !hasSeenAnnouncement
                && !suppressesLaunchUI
                ? announcement
                : nil
    }

    func dismissPendingAnnouncement() {
        guard let pendingAnnouncement else { return }
        defaults.set(true, forKey: Self.seenKey(for: pendingAnnouncement))
        self.pendingAnnouncement = nil
    }

    static func seenKey(for announcement: AppUpdateAnnouncement) -> String {
        seenKeyPrefix + announcement.id
    }

    private static func defaultApplicationSupportDirectory(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return baseURL.appendingPathComponent("lingyue", isDirectory: true)
    }

    private static func hasLegacyInstallationEvidence(
        defaults: UserDefaults,
        persistentDomainName: String,
        applicationSupportDirectory: URL,
        fileManager: FileManager
    ) -> Bool {
        let existingDefaults = defaults.persistentDomain(forName: persistentDomainName) ?? [:]
        let hasAppDefaults = existingDefaults.keys.contains { key in
            key != firstInstalledVersionKey && !key.hasPrefix(seenKeyPrefix)
        }
        if hasAppDefaults { return true }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: applicationSupportDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return !contents.isEmpty
    }

    private static func isVersion(_ lhs: String, olderThan rhs: String) -> Bool {
        let left = numericVersionComponents(lhs)
        let right = numericVersionComponents(rhs)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart < rightPart }
        }
        return false
    }

    private static func numericVersionComponents(_ version: String) -> [Int] {
        let components = version
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        return components.isEmpty ? [0] : components
    }
}

struct ContentView: View {
    // Must be initialized before stores that may create Application Support files; this
    // preserves the fresh-install/update distinction on the very first launch.
    @StateObject private var updateAnnouncements = AppUpdateAnnouncementStore()
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var themeManager = AppThemeManager()
    @StateObject private var downloadManager = BookDownloadManager.shared
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
        .overlay {
            if let announcement = updateAnnouncements.pendingAnnouncement,
               overlayManager.presentation == nil,
               importCoordinator.staged == nil,
               importCoordinator.errorMessage == nil,
               !importCoordinator.isFetching {
                AppUpdateAnnouncementPopup(announcement: announcement) {
                    withAnimation(.easeInOut(duration: 0.24)) {
                        updateAnnouncements.dismissPendingAnnouncement()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(
            .easeInOut(duration: 0.24),
            value: updateAnnouncements.pendingAnnouncement?.id
        )
        .environmentObject(libraryStore)
        .environmentObject(themeManager)
        .environmentObject(downloadManager)
        .environmentObject(overlayManager)
        .environmentObject(tabSelection)
        .environmentObject(importCoordinator)
        .environmentObject(updateAnnouncements)
        .environment(\.appTheme, effectiveTheme)
        .environment(\.sourceStack, .live)
        // Drive the background cross-fade from one central place so it animates
        // exactly once (on the visible page) instead of every page replaying it
        // when navigated to. Every `ThemeBackgroundView` observes the shared
        // `ThemeTransition` rather than running its own per-instance fade.
        .onChange(of: effectiveTheme) { oldValue, newValue in
            ThemeTransition.shared.transition(from: oldValue, to: newValue)
        }
        .onOpenURL { url in
            // Two delivery shapes funnel through here: a `lingyue://import?url=…`
            // deep link, or a `.json` file the user shared into 灵阅书屋 from
            // another app's share sheet / "打开方式" (see CFBundleDocumentTypes).
            if url.isFileURL {
                importCoordinator.handleIncomingFile(url)
            } else {
                importCoordinator.handleDeepLink(url)
            }
        }
        // After an external import (deep link / shared file) applies, jump to the
        // 发现 tab; DiscoveryAppStoreView then pushes the 书源 page so the user
        // sees the result. The destination binding clears the flag on pop-back.
        .onChange(of: importCoordinator.shouldShowSources) { _, show in
            if show { tabSelection.selectedTab = .discovery }
        }
        // Shared import confirm. Driven by `importCoordinator.staged`,
        // which any channel (file picker, URL, deep link) sets after
        // decode + diff. Presented at the root so a deep-link import
        // works from any tab.
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
                // Capture `staged` and hand it to apply — SwiftUI clears
                // `importCoordinator.staged` on dismissal before the async
                // task runs, so apply can't read it back off the coordinator.
                Task { await importCoordinator.apply(staged) }
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

private struct AppUpdateAnnouncementPopup: View {
    @Environment(\.appTheme) private var theme

    let announcement: AppUpdateAnnouncement
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(theme.accent.opacity(0.13))
                        .frame(width: 74, height: 74)

                    Image(systemName: announcement.icon)
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }

                VStack(spacing: 7) {
                    Text(announcement.eyebrow)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accent)
                        .textCase(.uppercase)

                    Text(announcement.title)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)

                    Text(announcement.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 13) {
                    ForEach(announcement.bullets) { bullet in
                        updateRow(icon: bullet.icon, text: bullet.text)
                    }
                }

                Button(action: onDismiss) {
                    Text("知道了")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(theme.accent))
                }
                .buttonStyle(.plain)
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 22, x: 0, y: 12)
            .padding(.horizontal, 24)
        }
        .accessibilityElement(children: .contain)
    }

    private func updateRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(theme.accent.opacity(0.11)))

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
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
    @Published var selectedTab: AppTab

    init() {
#if DEBUG
        selectedTab = CommandLine.arguments.contains("--screenshot-me") ? .settings : .library
#else
        selectedTab = .library
#endif
    }
}

#Preview {
    ContentView()
}
