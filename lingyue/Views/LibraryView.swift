import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let librarySwipeSpring: Animation = .spring(response: 0.32, dampingFraction: 0.86)

/// Window-level tap/pan catcher used to dismiss an open Library swipe panel from
/// areas SwiftUI gestures can't reach — the navigation bar (`书架` title), the
/// search-bar drawer hit area outside the SwiftUI tree, and the toolbar buttons.
/// `cancelsTouchesInView = false` means the recognizer observes touches without
/// stealing them, so taps still navigate, the search field still focuses, etc.
/// Active only while `isActive == true` (i.e. there's an open swipe), so the
/// recognizer doesn't sit on the window during normal use.
private struct WindowDismissCatcher: UIViewRepresentable {
    let isActive: Bool
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        DispatchQueue.main.async {
            context.coordinator.sync(window: uiView.window, isActive: isActive)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onDismiss: (() -> Void)?
        private weak var window: UIWindow?
        private var tap: UITapGestureRecognizer?
        private var pan: UIPanGestureRecognizer?

        func sync(window: UIWindow?, isActive: Bool) {
            guard isActive, let window else {
                detach()
                return
            }
            // Already attached to the same window — nothing to do.
            if window === self.window, tap != nil { return }
            detach()
            self.window = window

            let tap = UITapGestureRecognizer(target: self, action: #selector(fire))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            self.tap = tap

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            pan.cancelsTouchesInView = false
            pan.delegate = self
            window.addGestureRecognizer(pan)
            self.pan = pan
        }

        func detach() {
            if let tap, let window { window.removeGestureRecognizer(tap) }
            if let pan, let window { window.removeGestureRecognizer(pan) }
            tap = nil
            pan = nil
            window = nil
        }

        @objc func fire() { onDismiss?() }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            // Fire once at gesture start so the swipe panel slides closed as soon
            // as the user begins moving their finger — matches the in-SwiftUI
            // simultaneousGesture behavior.
            if recognizer.state == .began { onDismiss?() }
        }

        // Recognize alongside every other gesture so we don't break scrolling,
        // button taps, search focus, navigation pops, etc.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private struct LibraryScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// One row of the Library first-launch help popup. Each item maps to one
/// interactive affordance on the screen — icon, short title, one-line detail.
private struct LibraryHelpItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

private let libraryHelpItems: [LibraryHelpItem] = [
    LibraryHelpItem(icon: "doc.badge.plus", title: "导入本地小说", detail: "左上角按钮导入 TXT 文件"),
    LibraryHelpItem(icon: "arrow.down.circle", title: "下载管理", detail: "右上角查看进度，暂停或重试"),
    LibraryHelpItem(icon: "magnifyingglass", title: "搜索书架", detail: "下拉呼出搜索栏，按书名或作者查找"),
    LibraryHelpItem(icon: "square.grid.2x2", title: "分类管理", detail: "用分类整理书架，导入后可随时归类"),
    LibraryHelpItem(icon: "hand.tap", title: "书籍交互", detail: "点击阅读 · 长按移动分类 · 左滑清理或删除")
]

struct LibraryView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var downloadManager: BookDownloadManager
    @EnvironmentObject private var overlayManager: OverlayManager

    @State private var newCategoryName = ""
    @State private var newBookCategoryName = ""
    @State private var activeSwipeID: UUID?
    @State private var expandedCategoryID: UUID?
    @State private var bookToOpen: Novel?
    @State private var isManagingCategories = false
    @State private var isShowingDownloads = false
    @State private var isShowingTxtPicker = false
    @State private var txtImportToast: String?
    @State private var searchText = ""
    @Namespace private var stackNamespace

    /// One-shot onboarding flag. Flipped to `true` the first time the user
    /// dismisses the help overlay; persists across launches via UserDefaults so
    /// the overlay never reappears.
    @AppStorage("library.hasSeenHelpOverlay") private var hasSeenHelpOverlay = false

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 12 }
        return horizontalSizeClass == .compact ? 14 : 22
    }

    private var readingColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 10, alignment: .top),
            GridItem(.flexible(), spacing: 10, alignment: .top)
        ]
    }

    private var isLibraryEmpty: Bool {
        libraryStore.allNovels.isEmpty && libraryStore.categories.isEmpty
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedSearch.isEmpty }

    /// Cross-category title+author matches, recent-first. Mirrors the matcher and sort
    /// CategoryDetailView already uses for in-category search so the two screens behave
    /// identically.
    private var searchHits: [Novel] {
        let q = trimmedSearch
        guard !q.isEmpty else { return [] }
        return libraryStore.allNovels
            .filter {
                $0.title.localizedCaseInsensitiveContains(q) ||
                $0.author.localizedCaseInsensitiveContains(q)
            }
            .sorted { lhs, rhs in
                let l = lhs.lastOpenedAt ?? .distantPast
                let r = rhs.lastOpenedAt ?? .distantPast
                if l != r { return l > r }
                return lhs.readMinutes > rhs.readMinutes
            }
    }

    private var hasActiveOverlay: Bool {
        expandedCategoryID != nil
    }

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            if isLibraryEmpty {
                emptyStateView
            } else if isSearching {
                searchResultsList
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        currentlyReadingSection
                        categorizedBooksSection
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: LibraryScrollOffsetKey.self,
                                value: proxy.frame(in: .named("LibraryScroll")).minY
                            )
                        }
                    )
                }
                .coordinateSpace(name: "LibraryScroll")
                .onPreferenceChange(LibraryScrollOffsetKey.self) { _ in
                    closeActiveSwipe()
                }
                // Mail-style global dismissal: any tap inside the library closes an
                // open swipe alongside whatever the tapped child does. simultaneous
                // means action-button taps still fire (the button's own closeSwipe()
                // is redundant with this but harmless), and a tap on a different row
                // both closes the swipe and forwards the tap. Excludes the toolbar /
                // navigation chrome — those use onChange hooks below.
                .simultaneousGesture(
                    TapGesture().onEnded { closeActiveSwipe() }
                )
                // Vertical drag (scroll attempt) closes too — covers the case where the
                // content fits the viewport and offset never changes, so the preference
                // path above can't fire. We only close on predominantly vertical drags
                // so a horizontal swipe still reaches IconSwipeRow's own gesture.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            if abs(value.translation.height) > abs(value.translation.width) {
                                closeActiveSwipe()
                            }
                        }
                )
                .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
                .safeAreaPadding(.bottom, 12)
            }

            if let expandedCategory = libraryStore.categories.first(where: { $0.id == expandedCategoryID }) {
                ExpandedCategoryOverlay(
                    category: expandedCategory,
                    namespace: stackNamespace,
                    onDismiss: collapseExpandedCategory,
                    onSelect: { novel in
                        collapseExpandedCategory()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            bookToOpen = novel
                        }
                    },
                    onLongPress: { novel in
                        collapseExpandedCategory()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            presentCategoryEditor(for: novel)
                        }
                    },
                    onDelete: { novel in
                        deleteFromCategories(novel)
                    },
                    onDownload: downloadBook,
                    onClearDownloadData: clearDownloadedData
                )
                .zIndex(10)
            }

            if let txtImportToast {
                LibraryCenterToast(text: txtImportToast)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
                    .zIndex(13)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: txtImportToast)
        .overlay {
            if !hasSeenHelpOverlay {
                LibraryHelpPopup(onDismiss: dismissHelpOverlay)
                    .transition(.opacity)
                    .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.28), value: hasSeenHelpOverlay)
        .navigationDestination(item: $bookToOpen) { novel in
            ReaderView(novel: novel)
        }
        .fileImporter(
            isPresented: $isShowingTxtPicker,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await importTxt(at: url) }
            }
        }
        .sheet(isPresented: $isManagingCategories) {
            NavigationStack {
                CategoryManagementView()
                    .environmentObject(libraryStore)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingDownloads) {
            NavigationStack {
                DownloadsView()
                    .environmentObject(libraryStore)
                    .environmentObject(downloadManager)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    closeActiveSwipe()
                    isShowingTxtPicker = true
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .accessibilityLabel("从文件导入")
            }

            ToolbarItem(placement: .topBarTrailing) {
                LibraryDownloadToolbarButton(
                    isPresented: $isShowingDownloads,
                    novels: libraryStore.allNovels
                )
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: expandedCategoryID)
        // While a category is expanded the overlay fills the screen, so hide
        // the navigation chrome and tab bar — leaving them visible would let
        // the user tap into unrelated UI without dismissing first. Smaller
        // modals (new-category input, move-book picker) are presented at the
        // ContentView level via OverlayManager so their dim layer naturally
        // covers the chrome instead of needing it hidden.
        .toolbar(hasActiveOverlay ? .hidden : .visible, for: .navigationBar)
        .toolbar(hasActiveOverlay ? .hidden : .visible, for: .tabBar)
        .navigationTitle("书架")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索书名或作者"
        )
        .onChange(of: searchText) { _, _ in closeActiveSwipe() }
        .task {
            await downloadManager.refreshStates(for: libraryStore.allNovels)
        }
        .onChange(of: libraryStore.categories) { _, _ in
            Task {
                await downloadManager.refreshStates(for: libraryStore.allNovels)
            }
        }
        // Toolbar buttons live outside the ScrollView, so the simultaneousGesture
        // above doesn't see their taps. Closing on sheet presentation keeps the
        // swipe panel from lingering behind the modal.
        .onChange(of: isShowingDownloads) { _, _ in closeActiveSwipe() }
        .onChange(of: bookToOpen?.id) { _, newValue in
            // Pushing the reader navigation also dismisses any open swipe.
            if newValue != nil { closeActiveSwipe() }
        }
        // Window-level catcher for taps/drags in UIKit-rendered chrome the
        // SwiftUI simultaneousGesture can't see — navigation title (书架),
        // search-bar drawer, toolbar items. Only attached while a swipe is
        // open, so it doesn't sit on the window during normal use.
        .background(
            WindowDismissCatcher(
                isActive: activeSwipeID != nil,
                onDismiss: { closeActiveSwipe() }
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        )
    }

    private func closeActiveSwipe() {
        guard activeSwipeID != nil else { return }
        withAnimation(librarySwipeSpring) {
            activeSwipeID = nil
        }
    }

    private func dismissHelpOverlay() {
        withAnimation(.easeInOut(duration: 0.28)) {
            hasSeenHelpOverlay = true
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.10))
                    .frame(width: 124, height: 124)

                Image(systemName: "books.vertical")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(theme.accent.opacity(0.85))
            }

            VStack(spacing: 10) {
                Text("书架空空如也")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("点击下方「发现」搜索并导入小说\n也可以先创建一个分类整理书籍")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 40)

            Button {
                presentNewCategoryInput()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                    Text("新建分类")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Capsule().fill(theme.accent.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    /// Flat list shown in place of the wallet-stacked layout while a search query is
    /// active. Mirrors `CategoryDetailView`'s row composition (BookPressableNavigationRow
    /// + CategoryBookRow) so swipe-to-delete, long-press category move, and tap-to-open
    /// all behave consistently with the in-category detail screen.
    private var searchResultsList: some View {
        ScrollView {
            if searchHits.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(theme.secondaryText.opacity(0.6))
                    Text("没有匹配的书籍")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(searchHits) { novel in
                        let actions = downloadActions(for: novel)
                        BookPressableNavigationRow(
                            rowID: novel.id,
                            activeSwipeID: $activeSwipeID,
                            label: { CategoryBookRow(novel: novel) },
                            onTap: { bookToOpen = novel },
                            onLongPress: { presentCategoryEditor(for: novel) },
                            onDownload: actions.onDownload,
                            onClearDownloadData: actions.onClearDownloadData,
                            onDelete: { deleteFromCategories(novel) }
                        )
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 18)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: LibraryScrollOffsetKey.self,
                            value: proxy.frame(in: .named("LibrarySearchScroll")).minY
                        )
                    }
                )
            }
        }
        .coordinateSpace(name: "LibrarySearchScroll")
        .onPreferenceChange(LibraryScrollOffsetKey.self) { _ in
            closeActiveSwipe()
        }
        .simultaneousGesture(
            TapGesture().onEnded { closeActiveSwipe() }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    if abs(value.translation.height) > abs(value.translation.width) {
                        closeActiveSwipe()
                    }
                }
        )
        .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
        .safeAreaPadding(.bottom, 12)
    }

    @ViewBuilder
    private var currentlyReadingSection: some View {
        if !libraryStore.currentlyReading.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CompactSectionHeader(title: "最近阅读")

                LazyVGrid(columns: readingColumns, spacing: 10) {
                    ForEach(Array(libraryStore.currentlyReading.prefix(2))) { novel in
                        let actions = downloadActions(for: novel)
                        CompactReadingCard(novel: novel)
                            .contentShape(Rectangle())
                            .onTapGesture { bookToOpen = novel }
                            .contextMenu {
                                Button {
                                    presentCategoryEditor(for: novel)
                                } label: {
                                    Label("移动到分类", systemImage: "folder")
                                }

                                if let onDownload = actions.onDownload {
                                    Button {
                                        onDownload()
                                    } label: {
                                        Label("下载本书", systemImage: "arrow.down.circle")
                                    }
                                }

                                if let onClearDownloadData = actions.onClearDownloadData {
                                    Button {
                                        onClearDownloadData()
                                    } label: {
                                        Label("清理缓存", systemImage: "arrow.down.circle.dotted")
                                    }
                                }

                                Button(role: .destructive) {
                                    libraryStore.deleteBook(novel)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
    }

    private var categorizedBooksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CompactSectionHeader(title: "分类")

                Spacer()

                Menu {
                    Button {
                        presentNewCategoryInput()
                    } label: {
                        Label("新建分类", systemImage: "plus")
                    }

                    Button {
                        closeActiveSwipe()
                        isManagingCategories = true
                    } label: {
                        Label("管理分类", systemImage: "slider.horizontal.3")
                    }
                    .disabled(libraryStore.categories.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .accessibilityLabel("分类操作")
            }

            if libraryStore.categories.isEmpty {
                EmptyCategoryCard()
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(libraryStore.categories) { category in
                        StackedCategoryShelf(
                            category: category,
                            namespace: stackNamespace,
                            isExpanded: expandedCategoryID == category.id,
                            activeSwipeID: $activeSwipeID,
                            onTopTap: { novel in
                                bookToOpen = novel
                            },
                            onExpand: {
                                expandedCategoryID = category.id
                            },
                            onMoveCategory: presentCategoryEditor,
                            onDownload: downloadBook,
                            onClearDownloadData: clearDownloadedData,
                            onDelete: deleteFromCategories
                        )
                    }
                }
            }
        }
    }

    private func collapseExpandedCategory() {
        expandedCategoryID = nil
    }

    private func deleteFromCategories(_ novel: Novel) {
        libraryStore.deleteBook(novel)
    }

    private func presentNewCategoryInput() {
        closeActiveSwipe()
        newCategoryName = ""
        overlayManager.present {
            InputModalView(
                title: "新建分类",
                helperText: "分类会先创建为空，可以稍后加入书籍。",
                placeholder: "分类名称",
                text: $newCategoryName,
                confirmTitle: "添加",
                cancelTitle: "取消",
                onConfirm: addCategory,
                onDismiss: {
                    newCategoryName = ""
                    overlayManager.dismiss()
                }
            )
        }
    }

    private func presentCategoryEditor(for novel: Novel) {
        closeActiveSwipe()
        newBookCategoryName = ""
        overlayManager.present {
            CategoryEditOverlay(
                novel: novel,
                categories: $libraryStore.categories,
                newCategoryName: $newBookCategoryName,
                onDismiss: {
                    newBookCategoryName = ""
                    overlayManager.dismiss()
                }
            )
        }
    }

    private func addCategory() {
        let trimmedName = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        _ = libraryStore.addCategory(named: trimmedName)
        newCategoryName = ""
        overlayManager.dismiss()
    }

    private func clearDownloadedData(for novel: Novel) {
        downloadManager.clearState(for: novel)
        Task {
            await ChapterContentCache.shared.clearCache(for: novel)
        }
    }

    private func downloadBook(_ novel: Novel) {
        downloadManager.startDownload(novel)
    }

    @MainActor
    private func importTxt(at url: URL) async {
        let message: String
        do {
            let novel = try BookImportService.shared.importBook(fromPlainTextFile: url)
            let alreadyInLibrary = libraryStore.containsBook(
                sourceURLString: nil,
                title: novel.title
            )
            libraryStore.addImportedNovel(novel)
            if alreadyInLibrary {
                message = "已替换《\(novel.title)》共 \(novel.chapters.count) 章"
            } else {
                message = "已导入《\(novel.title)》共 \(novel.chapters.count) 章"
            }
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }

        txtImportToast = message
        let dismissedNotice = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if txtImportToast == dismissedNotice {
                txtImportToast = nil
            }
        }
    }

    fileprivate func downloadActions(for novel: Novel) -> (onDownload: (() -> Void)?, onClearDownloadData: (() -> Void)?) {
        bookDownloadActions(for: novel, manager: downloadManager)
    }
}

/// Returns the download/clear callbacks that should be exposed in the swipe and
/// context menu for a given novel. `onDownload` is suppressed once a book is
/// fully downloaded or already in flight; `onClearDownloadData` is only offered
/// when there's actually something cached to clear.
@MainActor
fileprivate func bookDownloadActions(
    for novel: Novel,
    manager: BookDownloadManager
) -> (onDownload: (() -> Void)?, onClearDownloadData: (() -> Void)?) {
    let clear: () -> Void = {
        manager.clearState(for: novel)
        Task {
            await ChapterContentCache.shared.clearCache(for: novel)
        }
    }
    let download: () -> Void = { manager.startDownload(novel) }

    switch manager.state(for: novel) {
    case .idle:
        return (download, nil)
    case .downloading, .paused:
        // Mid-flight or paused — let the user manage from the downloads sheet.
        // "清理缓存" still offered because clearState cancels the task and
        // wipes partial cache in one shot.
        return (nil, clear)
    case .failed:
        return (download, clear)
    case .downloaded:
        return (nil, clear)
    }
}

/// Pill-shaped notice anchored to screen center. Used for one-shot import
/// confirmations so the result reads as a glanceable acknowledgement.
private struct LibraryCenterToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .multilineTextAlignment(.center)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.78))
            )
            .shadow(color: Color.black.opacity(0.25), radius: 14, x: 0, y: 6)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// First-launch help popup. Dim scrim + a single centered card listing every
/// Library affordance with an icon, title, and one-line description. Tapping
/// the scrim or "知道了" calls `onDismiss`, which flips the @AppStorage flag
/// so the popup never reappears.
private struct LibraryHelpPopup: View {
    @Environment(\.appTheme) private var theme

    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text("欢迎使用灵阅")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    Text("书架功能速览")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                }

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(libraryHelpItems) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(theme.accent)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle().fill(theme.accent.opacity(0.12))
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(theme.primaryText)
                                Text(item.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
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
            .frame(maxWidth: 320)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 18, x: 0, y: 10)
            .padding(.horizontal, 24)
        }
    }
}

private struct CenteredOverlay<Content: View>: View {
    let content: Content
    let onDismiss: () -> Void

    init(@ViewBuilder content: () -> Content, onDismiss: @escaping () -> Void) {
        self.content = content()
        self.onDismiss = onDismiss
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            content
                .padding(.horizontal, 24)
        }
    }
}

private struct BookPressableNavigationRow<Label: View>: View {
    @Environment(\.appTheme) private var theme
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    let rowID: UUID
    @Binding var activeSwipeID: UUID?
    let label: Label
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onDownload: (() -> Void)?
    let onClearDownloadData: (() -> Void)?
    let onDelete: (() -> Void)?

    private let actionWidth: CGFloat = 62
    private let actionSpacing: CGFloat = 8
    private let actionCircleSize: CGFloat = 46

    private var actionCount: Int {
        (onClearDownloadData == nil ? 0 : 1) + (onDelete == nil ? 0 : 1)
    }

    private var revealedWidth: CGFloat {
        guard actionCount > 0 else { return 0 }
        return CGFloat(actionCount) * actionWidth + CGFloat(actionCount - 1) * actionSpacing
    }

    private var isOpen: Bool {
        activeSwipeID == rowID
    }

    private var displayedOffset: CGFloat {
        guard actionCount > 0 else { return 0 }
        if isDragging { return dragOffset }
        return isOpen ? -revealedWidth : 0
    }

    /// Native iOS swipe-actions slide in anchored to the row's trailing edge — they
    /// don't fade in. Action HStack is parked off-screen to the right when idle and
    /// pulled in 1:1 with the gesture.
    private var actionTrailingInset: CGFloat {
        guard revealedWidth > 0 else { return 0 }
        return max(0, revealedWidth + displayedOffset)
    }

    init(
        rowID: UUID,
        activeSwipeID: Binding<UUID?>,
        @ViewBuilder label: () -> Label,
        onTap: @escaping () -> Void,
        onLongPress: @escaping () -> Void,
        onDownload: (() -> Void)? = nil,
        onClearDownloadData: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.rowID = rowID
        self._activeSwipeID = activeSwipeID
        self.label = label()
        self.onTap = onTap
        self.onLongPress = onLongPress
        self.onDownload = onDownload
        self.onClearDownloadData = onClearDownloadData
        self.onDelete = onDelete
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if actionCount > 0 {
                HStack(spacing: actionSpacing) {
                    if let onClearDownloadData {
                        Button {
                            closeSwipe()
                            onClearDownloadData()
                        } label: {
                            mailStyleAction(
                                icon: "arrow.down.circle.dotted",
                                label: "清理缓存",
                                background: theme.accent
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if let onDelete {
                        Button(role: .destructive) {
                            withAnimation(librarySwipeSpring) {
                                onDelete()
                            }
                        } label: {
                            mailStyleAction(
                                icon: "trash.fill",
                                label: "删除",
                                background: Color.red
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: revealedWidth)
                .offset(x: actionTrailingInset)
                .allowsHitTesting(isOpen)
                .zIndex(1)
            }

            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: displayedOffset)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isOpen {
                        // Tapping the body of the row whose swipe is open just closes it,
                        // matching iOS Mail. Don't push into the reader from the open row.
                        withAnimation(librarySwipeSpring) {
                            activeSwipeID = nil
                        }
                    } else {
                        // Tapping a different row both opens the book and closes any active
                        // swipe (the LibraryView's simultaneousGesture handles the close in
                        // parallel — Mail behavior).
                        onTap()
                    }
                }
                .contextMenu {
                    Button {
                        onLongPress()
                    } label: {
                        SwiftUI.Label("移动到分类", systemImage: "folder")
                    }

                    if let onDownload {
                        Button {
                            onDownload()
                        } label: {
                            SwiftUI.Label("下载本书", systemImage: "arrow.down.circle")
                        }
                    }

                    if let onClearDownloadData {
                        Button {
                            onClearDownloadData()
                        } label: {
                            SwiftUI.Label("清理缓存", systemImage: "arrow.down.circle.dotted")
                        }
                    }

                    if let onDelete {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            SwiftUI.Label("删除", systemImage: "trash")
                        }
                    }
                }
                .simultaneousGesture(swipeGesture)
                .zIndex(0)
        }
        .clipped()
        .onChange(of: activeSwipeID) { _, newValue in
            if newValue != rowID && isDragging {
                isDragging = false
            }
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard actionCount > 0 else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                if !isDragging {
                    isDragging = true
                    if let active = activeSwipeID, active != rowID {
                        withAnimation(librarySwipeSpring) {
                            activeSwipeID = nil
                        }
                    }
                }

                let baseOffset: CGFloat = isOpen ? -revealedWidth : 0
                let raw = baseOffset + value.translation.width
                dragOffset = rubberBanded(raw)
            }
            .onEnded { value in
                guard actionCount > 0 else {
                    isDragging = false
                    return
                }
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                guard isHorizontal else {
                    isDragging = false
                    return
                }

                let velocity = value.predictedEndTranslation.width - value.translation.width
                let projected = dragOffset + velocity * 0.25

                let shouldOpen: Bool
                if isOpen {
                    shouldOpen = projected < -revealedWidth * 0.5
                } else {
                    shouldOpen = projected < -revealedWidth * 0.4
                }

                withAnimation(librarySwipeSpring) {
                    activeSwipeID = shouldOpen ? rowID : (isOpen ? nil : activeSwipeID)
                    isDragging = false
                }
            }
    }

    private func closeSwipe() {
        withAnimation(librarySwipeSpring) {
            if isOpen { activeSwipeID = nil }
            isDragging = false
        }
    }

    /// Mail-style action: a colored circle with a centered SF symbol, with a short
    /// label below in secondary text color.
    @ViewBuilder
    private func mailStyleAction(icon: String, label: String, background: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(background)
                    .frame(width: actionCircleSize, height: actionCircleSize)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .frame(width: actionWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private func rubberBanded(_ raw: CGFloat) -> CGFloat {
        if raw <= 0 && raw >= -revealedWidth { return raw }
        let limit: CGFloat = 140
        if raw > 0 {
            return rubberBandValue(raw, range: limit)
        }
        let over = -revealedWidth - raw
        return -revealedWidth - rubberBandValue(over, range: limit)
    }

    private func rubberBandValue(_ x: CGFloat, range: CGFloat) -> CGFloat {
        let constant: CGFloat = 0.55
        return (1 - 1 / (x * constant / range + 1)) * range
    }
}

/// Icon-only swipe wrapper used by surfaces where text labels would crowd the row
/// (the category popup and the wallet front card). Surfaces all four book actions —
/// move-to-category, download, clear cache, delete — driven by optional closures so
/// download/clear show up only when applicable for the book's current state.
private struct IconSwipeRow<Label: View>: View {
    @Environment(\.appTheme) private var theme
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    let rowID: UUID
    @Binding var activeSwipeID: UUID?
    let label: Label
    let onTap: () -> Void
    let onMoveToCategory: (() -> Void)?
    let onDownload: (() -> Void)?
    let onClearDownloadData: (() -> Void)?
    let onDelete: (() -> Void)?

    /// Mail-style swipe actions — each "button" is a tap target with a colored circle
    /// (icon) on top and a short label below. Width is wide enough for 4 CJK chars.
    private let actionWidth: CGFloat = 62
    private let actionSpacing: CGFloat = 8
    private let actionCircleSize: CGFloat = 38

    init(
        rowID: UUID,
        activeSwipeID: Binding<UUID?>,
        @ViewBuilder label: () -> Label,
        onTap: @escaping () -> Void,
        onMoveToCategory: (() -> Void)? = nil,
        onDownload: (() -> Void)? = nil,
        onClearDownloadData: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.rowID = rowID
        self._activeSwipeID = activeSwipeID
        self.label = label()
        self.onTap = onTap
        self.onMoveToCategory = onMoveToCategory
        self.onDownload = onDownload
        self.onClearDownloadData = onClearDownloadData
        self.onDelete = onDelete
    }

    private var actionCount: Int {
        (onMoveToCategory == nil ? 0 : 1) +
        (onDownload == nil ? 0 : 1) +
        (onClearDownloadData == nil ? 0 : 1) +
        (onDelete == nil ? 0 : 1)
    }

    private var revealedWidth: CGFloat {
        guard actionCount > 0 else { return 0 }
        return CGFloat(actionCount) * actionWidth + CGFloat(actionCount - 1) * actionSpacing
    }

    private var isOpen: Bool { activeSwipeID == rowID }

    private var displayedOffset: CGFloat {
        guard actionCount > 0 else { return 0 }
        if isDragging { return dragOffset }
        return isOpen ? -revealedWidth : 0
    }

    /// Native iOS swipe-actions slide in from the trailing edge anchored to the row's
    /// trailing edge — they don't fade in, they're pulled into view by the gesture.
    /// `displayedOffset` is negative when swiping left, so this clamps the actions to
    /// the right of the trailing edge until the row starts moving, then 1:1 follows
    /// the row in.
    private var actionTrailingInset: CGFloat {
        guard revealedWidth > 0 else { return 0 }
        return max(0, revealedWidth + displayedOffset)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if actionCount > 0 {
                HStack(spacing: actionSpacing) {
                    if let onMoveToCategory {
                        actionButton(
                            icon: "folder.fill",
                            label: "分类",
                            background: theme.secondaryText.opacity(0.85)
                        ) {
                            closeSwipe()
                            onMoveToCategory()
                        }
                    }
                    if let onDownload {
                        actionButton(
                            icon: "arrow.down",
                            label: "下载",
                            background: theme.accent
                        ) {
                            closeSwipe()
                            onDownload()
                        }
                    }
                    if let onClearDownloadData {
                        actionButton(
                            icon: "arrow.down.circle.dotted",
                            label: "清理缓存",
                            background: theme.accent.opacity(0.65)
                        ) {
                            closeSwipe()
                            onClearDownloadData()
                        }
                    }
                    if let onDelete {
                        actionButton(
                            icon: "trash.fill",
                            label: "删除",
                            background: Color.red,
                            role: .destructive
                        ) {
                            withAnimation(librarySwipeSpring) {
                                onDelete()
                            }
                        }
                    }
                }
                .frame(width: revealedWidth)
                .offset(x: actionTrailingInset)
                .allowsHitTesting(isOpen)
                .zIndex(1)
            }

            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: displayedOffset)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isOpen {
                        // Tapping the body of the row whose swipe is open just closes it,
                        // matching iOS Mail. Don't push into the reader from the open row.
                        withAnimation(librarySwipeSpring) {
                            activeSwipeID = nil
                        }
                    } else {
                        // Tapping a different row both opens the book and closes any active
                        // swipe (LibraryView's simultaneousGesture handles the close in
                        // parallel — Mail behavior).
                        onTap()
                    }
                }
                .contextMenu {
                    if let onMoveToCategory {
                        Button {
                            onMoveToCategory()
                        } label: {
                            SwiftUI.Label("移动到分类", systemImage: "folder")
                        }
                    }
                    if let onDownload {
                        Button {
                            onDownload()
                        } label: {
                            SwiftUI.Label("下载本书", systemImage: "arrow.down.circle")
                        }
                    }
                    if let onClearDownloadData {
                        Button {
                            onClearDownloadData()
                        } label: {
                            SwiftUI.Label("清理缓存", systemImage: "arrow.down.circle.dotted")
                        }
                    }
                    if let onDelete {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            SwiftUI.Label("删除", systemImage: "trash")
                        }
                    }
                }
                .simultaneousGesture(swipeGesture)
                .zIndex(0)
        }
        .clipped()
        .onChange(of: activeSwipeID) { _, newValue in
            if newValue != rowID && isDragging {
                isDragging = false
            }
        }
    }

    private func actionButton(
        icon: String,
        label: String,
        background: Color,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            ZStack {
                // Circle anchored to the row's vertical center.
                Circle()
                    .fill(background)
                    .frame(width: actionCircleSize, height: actionCircleSize)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.white)
                    }

                // Label trails the circle; doesn't have to be centered to the row.
                // Offset = circle radius + small gap + half the text line height.
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .offset(y: actionCircleSize / 2 + 4 + 7)
            }
            .frame(width: actionWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard actionCount > 0 else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                if !isDragging {
                    isDragging = true
                    if let active = activeSwipeID, active != rowID {
                        withAnimation(librarySwipeSpring) {
                            activeSwipeID = nil
                        }
                    }
                }

                let baseOffset: CGFloat = isOpen ? -revealedWidth : 0
                let raw = baseOffset + value.translation.width
                dragOffset = rubberBanded(raw)
            }
            .onEnded { value in
                guard actionCount > 0 else {
                    isDragging = false
                    return
                }
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                guard isHorizontal else {
                    isDragging = false
                    return
                }

                let velocity = value.predictedEndTranslation.width - value.translation.width
                let projected = dragOffset + velocity * 0.25

                let shouldOpen: Bool
                if isOpen {
                    shouldOpen = projected < -revealedWidth * 0.5
                } else {
                    shouldOpen = projected < -revealedWidth * 0.4
                }

                withAnimation(librarySwipeSpring) {
                    activeSwipeID = shouldOpen ? rowID : (isOpen ? nil : activeSwipeID)
                    isDragging = false
                }
            }
    }

    private func closeSwipe() {
        withAnimation(librarySwipeSpring) {
            if isOpen { activeSwipeID = nil }
            isDragging = false
        }
    }

    private func rubberBanded(_ raw: CGFloat) -> CGFloat {
        if raw <= 0 && raw >= -revealedWidth { return raw }
        let limit: CGFloat = 140
        if raw > 0 {
            return rubberBandValue(raw, range: limit)
        }
        let over = -revealedWidth - raw
        return -revealedWidth - rubberBandValue(over, range: limit)
    }

    private func rubberBandValue(_ x: CGFloat, range: CGFloat) -> CGFloat {
        let constant: CGFloat = 0.55
        return (1 - 1 / (x * constant / range + 1)) * range
    }
}

private struct CategoryEditOverlay: View {
    let novel: Novel
    @Binding var categories: [LibraryCategory]
    @Binding var newCategoryName: String
    @FocusState private var isNewCategoryFocused: Bool
    @Environment(\.appTheme) private var theme
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false
    let onDismiss: () -> Void

    var body: some View {
        CenteredOverlay {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("移动到分类")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.primaryText)

                    Text(displayed(novel.title))
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }

                if categories.isEmpty {
                    Text("还没有分类，可以先创建一个。")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(theme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(categories) { category in
                                Button {
                                    move(novel, toCategoryID: category.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(theme.accent)

                                        Text(category.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(theme.primaryText)
                                            .lineLimit(1)

                                        Spacer()

                                        Text("\(category.novels.count)")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(theme.secondaryText)

                                        if categoryContains(novel, categoryID: category.id) {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundStyle(theme.accent)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(theme.background)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("创建新分类")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)

                    HStack(spacing: 8) {
                        TextField("分类名称", text: $newCategoryName)
                            .focused($isNewCategoryFocused)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .font(.system(size: 14))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(theme.background)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .onSubmit {
                                createCategoryAndMove(novel)
                            }

                        Button("添加") {
                            createCategoryAndMove(novel)
                        }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.cardBackground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(trimmedNewCategoryName.isEmpty ? theme.secondaryText.opacity(0.45) : theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .disabled(trimmedNewCategoryName.isEmpty)
                    }
                }

                Button("取消") {
                    newCategoryName = ""
                    onDismiss()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity)
            }
            .padding(16)
            .frame(maxWidth: 340, alignment: .leading)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 12)
        } onDismiss: {
            newCategoryName = ""
            onDismiss()
        }
    }

    private var trimmedNewCategoryName: String {
        newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }

    private func move(_ novel: Novel, toCategoryID categoryID: UUID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            for index in categories.indices {
                categories[index].novels.removeAll { $0.id == novel.id }
            }

            guard let targetIndex = categories.firstIndex(where: { $0.id == categoryID }) else {
                newCategoryName = ""
                onDismiss()
                return
            }

            categories[targetIndex].novels.append(novel)
            newCategoryName = ""
            onDismiss()
        }
    }

    private func createCategoryAndMove(_ novel: Novel) {
        guard !trimmedNewCategoryName.isEmpty else { return }

        if let existingCategory = categories.first(where: { $0.name.caseInsensitiveCompare(trimmedNewCategoryName) == .orderedSame }) {
            move(novel, toCategoryID: existingCategory.id)
            return
        }

        let newCategory = LibraryCategory(name: trimmedNewCategoryName, novels: [])
        categories.append(newCategory)
        move(novel, toCategoryID: newCategory.id)
    }

    private func categoryContains(_ novel: Novel, categoryID: UUID) -> Bool {
        categories
            .first { $0.id == categoryID }?
            .novels
            .contains { $0.id == novel.id } ?? false
    }
}

private struct CompactSectionHeader: View {
    @Environment(\.appTheme) private var theme
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(theme.primaryText)
    }
}

private struct CompactReadingCard: View {
    @Environment(\.appTheme) private var theme
    let novel: Novel
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(displayed(novel.title))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 4)

                Text("\(Int(novel.progress * 100))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.accent)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text(displayed(novel.lastChapter))
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            ProgressView(value: novel.progress)
                .tint(theme.accent)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: theme.cardShadow, radius: 8, x: 0, y: 4)
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }
}

/// Inline pill that surfaces a book's download status on Library cards. Hidden when
/// a book has never been touched by the download manager (idle), so casually-imported
/// books don't get visual noise.
private struct DownloadStatusBadge: View {
    @Environment(\.appTheme) private var theme
    let state: BookDownloadState
    /// Compact variant trims label text; used on small-card layouts.
    var compact: Bool = false

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .downloading(let completed, let total):
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 10, weight: .bold))
                Text(compact ? "\(Int(state.fraction * 100))%" : "下载中 \(completed)/\(total)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.accent.opacity(0.14)))
        case .paused(let completed, let total):
            HStack(spacing: 4) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 10, weight: .bold))
                Text(compact ? "\(Int(state.fraction * 100))%" : "已暂停 \(completed)/\(total)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.secondaryText.opacity(0.12)))
        case .downloaded:
            HStack(spacing: 3) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("已下载")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.accent.opacity(0.14)))
        case .failed:
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10, weight: .bold))
                Text("未完成")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(Color.red.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red.opacity(0.10)))
        }
    }
}

private struct StackedCategoryShelf: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var downloadManager: BookDownloadManager
    let category: LibraryCategory
    let namespace: Namespace.ID
    let isExpanded: Bool
    @Binding var activeSwipeID: UUID?
    let onTopTap: (Novel) -> Void
    let onExpand: () -> Void
    let onMoveCategory: (Novel) -> Void
    let onDownload: (Novel) -> Void
    let onClearDownloadData: (Novel) -> Void
    let onDelete: (Novel) -> Void

    private let cardHeight: CGFloat = 88
    private let peekOffset: CGFloat = 22
    private let maxVisible = 3

    private var sortedNovels: [Novel] {
        category.novels.sorted { lhs, rhs in
            let lhsOpened = lhs.lastOpenedAt ?? .distantPast
            let rhsOpened = rhs.lastOpenedAt ?? .distantPast
            if lhsOpened != rhsOpened {
                return lhsOpened > rhsOpened
            }
            return lhs.readMinutes > rhs.readMinutes
        }
    }

    var body: some View {
        let visible = Array(sortedNovels.prefix(maxVisible))

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(category.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                Spacer()

                Text("\(category.novels.count) 本")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }

            if visible.isEmpty {
                EmptyCategoryRow()
            } else {
                // Negative spacing makes the cards overlap *in layout* — not just visually —
                // so SwiftUI's hit-testing routes a tap on the visible peek sliver to the
                // correct card (.offset() alone keeps every card at y=0 in the layout system,
                // so taps always go to the topmost zIndex card no matter where you actually
                // press).
                let frontID = visible.first?.id
                let isSwipeActive = frontID != nil && activeSwipeID == frontID
                VStack(spacing: -(cardHeight - peekOffset)) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, novel in
                        if index == 0 {
                            let actions = bookDownloadActions(for: novel, manager: downloadManager)
                            IconSwipeRow(
                                rowID: novel.id,
                                activeSwipeID: $activeSwipeID,
                                label: {
                                    StackBookCard(novel: novel)
                                        .frame(height: cardHeight)
                                        .matchedGeometryEffect(id: novel.id, in: namespace, isSource: !isExpanded)
                                },
                                onTap: { onTopTap(novel) },
                                onMoveToCategory: { onMoveCategory(novel) },
                                onDownload: actions.onDownload == nil ? nil : { onDownload(novel) },
                                onClearDownloadData: actions.onClearDownloadData == nil ? nil : { onClearDownloadData(novel) },
                                onDelete: { onDelete(novel) }
                            )
                            .zIndex(Double(maxVisible))
                            .opacity(isExpanded ? 0 : 1)
                            .allowsHitTesting(!isExpanded)
                        } else {
                            StackBookCard(novel: novel)
                                .frame(height: cardHeight)
                                .matchedGeometryEffect(id: novel.id, in: namespace, isSource: !isExpanded)
                                // Keep peek cards close to full width so the visible sliver
                                // remains an easy tap target (was 0.012, which made a 2-card
                                // stack's lone peek visibly narrower and easy to misclick).
                                .scaleEffect(1 - CGFloat(index) * 0.005, anchor: .top)
                                .zIndex(Double(maxVisible - index))
                                // Fade peek cards while a swipe is open so the action
                                // labels under the front card don't compete visually
                                // with the next card's title/last-chapter line.
                                .opacity(isExpanded ? 0 : (isSwipeActive ? 0.25 : 1))
                                .allowsHitTesting(!isExpanded && !isSwipeActive)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onExpand()
                                }
                                .contextMenu {
                                    bookContextMenuButtons(for: novel)
                                }
                        }
                    }
                }
                .animation(librarySwipeSpring, value: isSwipeActive)
            }
        }
    }

    @ViewBuilder
    private func bookContextMenuButtons(for novel: Novel) -> some View {
        let actions = bookDownloadActions(for: novel, manager: downloadManager)

        Button {
            onMoveCategory(novel)
        } label: {
            Label("移动到分类", systemImage: "folder")
        }

        if actions.onDownload != nil {
            Button {
                onDownload(novel)
            } label: {
                Label("下载本书", systemImage: "arrow.down.circle")
            }
        }

        if actions.onClearDownloadData != nil {
            Button {
                onClearDownloadData(novel)
            } label: {
                Label("清理缓存", systemImage: "arrow.down.circle.dotted")
            }
        }

        Button(role: .destructive) {
            onDelete(novel)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }
}

private struct StackBookCard: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var downloadManager: BookDownloadManager
    let novel: Novel
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false

    var body: some View {
        HStack(spacing: 12) {
            BookCover(novel: novel, width: 48, height: 68)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayed(novel.title))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    DownloadStatusBadge(state: downloadManager.state(for: novel), compact: true)
                }

                BookMetadataLine(novel: novel, usesTraditionalChinese: usesTraditionalChinese)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)

                Text(displayed(novel.lastChapter))
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text("\(Int(novel.progress * 100))%")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.accent)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: theme.cardShadow, radius: 8, x: 0, y: 4)
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }
}

/// Renders "{author} · {source}" so the source name pins to the right and the author truncates
/// from the tail when there isn't enough room. Without this, a long author hides the source.
private struct BookMetadataLine: View {
    let novel: Novel
    let usesTraditionalChinese: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(displayed(novel.author))
                .lineLimit(1)
                .truncationMode(.tail)

            if let source = BookSourceRegistry.displayName(for: novel.sourceURLString) {
                Text("·")
                    .layoutPriority(1)
                Text(displayed(source))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }
}

private struct ExpandedCategoryOverlay: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var downloadManager: BookDownloadManager
    @State private var activeSwipeID: UUID?
    let category: LibraryCategory
    let namespace: Namespace.ID
    let onDismiss: () -> Void
    let onSelect: (Novel) -> Void
    let onLongPress: (Novel) -> Void
    let onDelete: (Novel) -> Void
    let onDownload: (Novel) -> Void
    let onClearDownloadData: (Novel) -> Void

    private var sortedNovels: [Novel] {
        category.novels.sorted { lhs, rhs in
            let lhsOpened = lhs.lastOpenedAt ?? .distantPast
            let rhsOpened = rhs.lastOpenedAt ?? .distantPast
            if lhsOpened != rhsOpened {
                return lhsOpened > rhsOpened
            }
            return lhs.readMinutes > rhs.readMinutes
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
                .transition(.opacity)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                        Text("\(category.novels.count) 本")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                    }

                    Spacer()

                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                // Tapping the header area closes any open swipe — Mail-style: any
                // interaction that isn't an action button hides the actions.
                .contentShape(Rectangle())
                .onTapGesture { closeActiveSwipe() }

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sortedNovels) { novel in
                            let actions = bookDownloadActions(for: novel, manager: downloadManager)
                            IconSwipeRow(
                                rowID: novel.id,
                                activeSwipeID: $activeSwipeID,
                                label: {
                                    StackBookCard(novel: novel)
                                        .matchedGeometryEffect(id: novel.id, in: namespace, isSource: true)
                                },
                                onTap: { onSelect(novel) },
                                onMoveToCategory: { onLongPress(novel) },
                                onDownload: actions.onDownload == nil ? nil : { onDownload(novel) },
                                onClearDownloadData: actions.onClearDownloadData == nil ? nil : { onClearDownloadData(novel) },
                                onDelete: { onDelete(novel) }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: LibraryScrollOffsetKey.self,
                                value: proxy.frame(in: .named("OverlayScroll")).minY
                            )
                        }
                    )
                }
                .coordinateSpace(name: "OverlayScroll")
                .onPreferenceChange(LibraryScrollOffsetKey.self) { _ in
                    closeActiveSwipe()
                }
                // Mail-style global dismissal inside the popup: tap or vertical drag
                // anywhere closes the open swipe alongside whatever the child does.
                .simultaneousGesture(
                    TapGesture().onEnded { closeActiveSwipe() }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            if abs(value.translation.height) > abs(value.translation.width) {
                                closeActiveSwipe()
                            }
                        }
                )
            }
            .frame(maxWidth: .infinity)
            .background(theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 30, x: 0, y: 14)
            .padding(.horizontal, 16)
            .padding(.top, 60)
            .padding(.bottom, 32)
        }
        .onChange(of: category.novels.count) { _, _ in closeActiveSwipe() }
    }

    private func closeActiveSwipe() {
        guard activeSwipeID != nil else { return }
        withAnimation(librarySwipeSpring) {
            activeSwipeID = nil
        }
    }
}

private struct EmptyCategoryCard: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        Text("还没有分类")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(theme.cardBackground.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct EmptyCategoryRow: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(theme.accent.opacity(0.85))
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.accent.opacity(0.10)))

            VStack(alignment: .leading, spacing: 2) {
                Text("暂无书籍")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.primaryText.opacity(0.85))
                Text("前往「发现」搜索并导入")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.cardBackground.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    theme.accent.opacity(0.28),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
    }
}

private struct CategoryBookRow: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var downloadManager: BookDownloadManager
    let novel: Novel
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false

    var body: some View {
        HStack(spacing: 10) {
            BookCover(novel: novel, width: 44, height: 62)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayed(novel.title))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    DownloadStatusBadge(state: downloadManager.state(for: novel), compact: true)
                }

                BookMetadataLine(novel: novel, usesTraditionalChinese: usesTraditionalChinese)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)

                Text(displayed(novel.lastChapter))
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text("\(Int(novel.progress * 100))%")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.accent)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardBackground.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }
}

private enum CategorySortMode: String, CaseIterable, Identifiable {
    case recent = "最近阅读"
    case title = "书名"
    case author = "作者"

    var id: String { rawValue }
}

private struct CategoryDetailView: View {
    let categoryID: UUID
    @Binding var categories: [LibraryCategory]

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var downloadManager: BookDownloadManager
    @State private var searchText = ""
    @State private var sortMode: CategorySortMode = .recent
    @State private var categoryEditBook: Novel?
    @State private var newBookCategoryName = ""
    @State private var activeSwipeID: UUID?
    @State private var bookToOpen: Novel?

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 12 }
        return horizontalSizeClass == .compact ? 14 : 22
    }

    private var category: LibraryCategory? {
        categories.first { $0.id == categoryID }
    }

    private var categoryName: String {
        category?.name ?? "分类"
    }

    private var categoryNovels: [Novel] {
        category?.novels ?? []
    }

    private var visibleNovels: [Novel] {
        let searched = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [Novel]

        if searched.isEmpty {
            filtered = categoryNovels
        } else {
            filtered = categoryNovels.filter { novel in
                novel.title.localizedCaseInsensitiveContains(searched) ||
                novel.author.localizedCaseInsensitiveContains(searched) ||
                novel.lastChapter.localizedCaseInsensitiveContains(searched)
            }
        }

        switch sortMode {
        case .recent:
            return filtered.sorted { lhs, rhs in
                let lhsOpenedAt = lhs.lastOpenedAt ?? .distantPast
                let rhsOpenedAt = rhs.lastOpenedAt ?? .distantPast
                if lhsOpenedAt != rhsOpenedAt {
                    return lhsOpenedAt > rhsOpenedAt
                }
                return lhs.readMinutes > rhs.readMinutes
            }
        case .title:
            return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            return filtered.sorted { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        }
    }

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("排序", selection: $sortMode) {
                        ForEach(CategorySortMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if visibleNovels.isEmpty {
                        EmptyCategoryRow()
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(visibleNovels) { novel in
                                let actions = bookDownloadActions(for: novel, manager: downloadManager)
                                BookPressableNavigationRow(
                                    rowID: novel.id,
                                    activeSwipeID: $activeSwipeID,
                                    label: { CategoryBookRow(novel: novel) },
                                    onTap: { bookToOpen = novel },
                                    onLongPress: { presentCategoryEditor(for: novel) },
                                    onDownload: actions.onDownload,
                                    onClearDownloadData: actions.onClearDownloadData,
                                    onDelete: { delete(novel) }
                                )
                            }
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 18)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: LibraryScrollOffsetKey.self,
                            value: proxy.frame(in: .named("CategoryDetailScroll")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "CategoryDetailScroll")
            .onPreferenceChange(LibraryScrollOffsetKey.self) { _ in
                closeActiveSwipe()
            }
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .safeAreaPadding(.bottom, 12)

            if let categoryEditBook {
                CategoryEditOverlay(
                    novel: categoryEditBook,
                    categories: $categories,
                    newCategoryName: $newBookCategoryName,
                    onDismiss: {
                        self.categoryEditBook = nil
                        newBookCategoryName = ""
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(11)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: categoryEditBook?.id)
        .navigationTitle(categoryName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索书名、作者或章节")
        .navigationDestination(item: $bookToOpen) { novel in
            ReaderView(novel: novel)
        }
        .onChange(of: categoryEditBook?.id) { _, _ in closeActiveSwipe() }
        .onChange(of: searchText) { _, _ in closeActiveSwipe() }
        .onChange(of: sortMode) { _, _ in closeActiveSwipe() }
    }

    private func closeActiveSwipe() {
        guard activeSwipeID != nil else { return }
        withAnimation(librarySwipeSpring) {
            activeSwipeID = nil
        }
    }

    private func presentCategoryEditor(for novel: Novel) {
        newBookCategoryName = ""
        categoryEditBook = novel
    }

    private func delete(_ novel: Novel) {
        var updatedCategories = categories
        for index in updatedCategories.indices {
            updatedCategories[index].novels.removeAll { $0.id == novel.id }
        }
        categories = updatedCategories
    }

    private func clearDownloadedData(for novel: Novel) {
        downloadManager.clearState(for: novel)
        Task {
            await ChapterContentCache.shared.clearCache(for: novel)
        }
    }
}

private struct CategoryManagementView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var pendingDeletion: LibraryCategory?
    @State private var editingCategoryID: UUID?
    @State private var editingName: String = ""
    @State private var renameError: String?
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        List {
            ForEach(libraryStore.categories) { category in
                categoryRow(category)
                    .padding(.vertical, 4)
            }
            .onMove { source, destination in
                libraryStore.categories.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
        .navigationTitle("管理分类")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
                    .font(.body.weight(.semibold))
            }
        }
        .alert(
            "删除分类",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { category in
            Button("删除", role: .destructive) {
                deleteCategory(category)
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { category in
            if category.novels.isEmpty {
                Text("确定要删除「\(displayed(category.name))」吗？")
            } else {
                Text("「\(displayed(category.name))」中包含 \(category.novels.count) 本书，删除分类会同时删除其中的全部书籍，且无法恢复。")
            }
        }
        .overlay {
            if libraryStore.categories.isEmpty {
                Text("还没有分类")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .alert(
            "无法重命名",
            isPresented: Binding(
                get: { renameError != nil },
                set: { if !$0 { renameError = nil } }
            ),
            presenting: renameError
        ) { _ in
            Button("好的", role: .cancel) { renameError = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: LibraryCategory) -> some View {
        if editingCategoryID == category.id {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.accent)

                TextField("分类名称", text: $editingName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename(for: category) }

                Spacer(minLength: 6)

                Button("取消") { cancelRename() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .buttonStyle(.plain)

                Button("完成") { commitRename(for: category) }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .buttonStyle(.plain)
                    .disabled(editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayed(category.name))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    Text("\(category.novels.count) 本")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer()

                Button {
                    beginRename(for: category)
                } label: {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.accent, theme.accent.opacity(0.14))
                        .symbolRenderingMode(.palette)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重命名分类")

                // Explicit, always-visible delete control. No swipe needed — taps the
                // trash icon to bring up the confirmation alert.
                Button {
                    pendingDeletion = category
                } label: {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.red, Color.red.opacity(0.12))
                        .symbolRenderingMode(.palette)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除分类")
            }
        }
    }

    private func beginRename(for category: LibraryCategory) {
        editingName = category.name
        editingCategoryID = category.id
        renameError = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            renameFieldFocused = true
        }
    }

    private func cancelRename() {
        renameFieldFocused = false
        editingCategoryID = nil
        editingName = ""
        renameError = nil
    }

    private func commitRename(for category: LibraryCategory) {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if libraryStore.renameCategory(id: category.id, to: trimmed) {
            cancelRename()
        } else {
            renameError = "分类名称已被使用"
        }
    }

    private func deleteCategory(_ category: LibraryCategory) {
        let removedNovels = category.novels
        libraryStore.categories.removeAll { $0.id == category.id }

        // Books inside the deleted category are removed with it. Wipe their cached chapter
        // content too — orphaned cache entries are wasted disk.
        Task {
            for novel in removedNovels {
                await ChapterContentCache.shared.clearCache(for: novel)
            }
        }
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }
}

#Preview {
    LibraryView()
        .environmentObject(LibraryStore())
}
