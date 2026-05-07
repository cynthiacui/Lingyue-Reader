import SwiftUI
import UniformTypeIdentifiers

private let librarySwipeSpring: Animation = .spring(response: 0.32, dampingFraction: 0.86)

private struct LibraryScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct LibraryView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var downloadManager: BookDownloadManager

    @State private var isAddingCategory = false
    @State private var newCategoryName = ""
    @State private var categoryEditBook: Novel?
    @State private var newBookCategoryName = ""
    @State private var activeSwipeID: UUID?
    @State private var expandedCategoryID: UUID?
    @State private var bookToOpen: Novel?
    @State private var isManagingCategories = false
    @State private var isShowingDownloads = false
    @State private var isShowingTxtPicker = false
    @State private var txtImportToast: String?
    @Namespace private var stackNamespace

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

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            if isLibraryEmpty {
                emptyStateView
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

            if let categoryEditBook {
                categoryEditOverlay(for: categoryEditBook)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(11)
            }

            if isAddingCategory {
                InputModalView(
                    title: "新建分类",
                    helperText: "分类会先创建为空，可以稍后加入书籍。",
                    placeholder: "分类名称",
                    text: $newCategoryName,
                    confirmTitle: "添加",
                    cancelTitle: "取消",
                    onConfirm: addCategory,
                    onDismiss: {
                        withAnimation(InputModalView.presentationAnimation) {
                            newCategoryName = ""
                            isAddingCategory = false
                        }
                    }
                )
                .transition(InputModalView.transition)
                .zIndex(12)
            }

            if let txtImportToast {
                LibraryCenterToast(text: txtImportToast)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
                    .zIndex(13)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: txtImportToast)
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
        .animation(.easeInOut(duration: 0.18), value: categoryEditBook?.id)
        .animation(InputModalView.presentationAnimation, value: isAddingCategory)
        .navigationTitle("书架")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await downloadManager.refreshStates(for: libraryStore.allNovels)
        }
        .onChange(of: libraryStore.categories) { _, _ in
            Task {
                await downloadManager.refreshStates(for: libraryStore.allNovels)
            }
        }
        .onChange(of: categoryEditBook?.id) { _, _ in closeActiveSwipe() }
        .onChange(of: isAddingCategory) { _, _ in closeActiveSwipe() }
    }

    private func closeActiveSwipe() {
        guard activeSwipeID != nil else { return }
        withAnimation(librarySwipeSpring) {
            activeSwipeID = nil
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
                closeActiveSwipe()
                newCategoryName = ""
                isAddingCategory = true
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

    @ViewBuilder
    private var currentlyReadingSection: some View {
        if !libraryStore.currentlyReading.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CompactSectionHeader(title: "最近阅读")

                LazyVGrid(columns: readingColumns, spacing: 10) {
                    ForEach(Array(libraryStore.currentlyReading.prefix(2))) { novel in
                        let actions = downloadActions(for: novel)
                        BookPressableNavigationRow(
                            rowID: novel.id,
                            activeSwipeID: $activeSwipeID,
                            label: { CompactReadingCard(novel: novel) },
                            onTap: { bookToOpen = novel },
                            onLongPress: { presentCategoryEditor(for: novel) },
                            onDownload: actions.onDownload,
                            onClearDownloadData: actions.onClearDownloadData,
                            onDelete: { libraryStore.deleteBook(novel) }
                        )
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
                        closeActiveSwipe()
                        newCategoryName = ""
                        isAddingCategory = true
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
        var updatedCategories = libraryStore.categories
        for index in updatedCategories.indices {
            updatedCategories[index].novels.removeAll { $0.id == novel.id }
        }
        libraryStore.categories = updatedCategories
    }

    private func categoryEditOverlay(for novel: Novel) -> some View {
        CategoryEditOverlay(
            novel: novel,
            categories: $libraryStore.categories,
            newCategoryName: $newBookCategoryName,
            onDismiss: {
                categoryEditBook = nil
                newBookCategoryName = ""
            }
        )
    }

    private func presentCategoryEditor(for novel: Novel) {
        newBookCategoryName = ""
        categoryEditBook = novel
    }

    private func addCategory() {
        let trimmedName = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        _ = libraryStore.addCategory(named: trimmedName)
        withAnimation(InputModalView.presentationAnimation) {
            newCategoryName = ""
            isAddingCategory = false
        }
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

    private let actionWidth: CGFloat = 86
    private let actionSpacing: CGFloat = 6

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

    private var deleteActionOpacity: CGFloat {
        guard revealedWidth > 0 else { return 0 }
        let progress = min(1, max(0, abs(displayedOffset) / (revealedWidth * 0.25)))
        return progress
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
                            VStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 17, weight: .bold))
                                Text("清理缓存")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(Color.white)
                            .frame(width: actionWidth)
                            .frame(maxHeight: .infinity)
                            .background(theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    if let onDelete {
                        Button(role: .destructive) {
                            withAnimation(librarySwipeSpring) {
                                onDelete()
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 17, weight: .bold))
                                Text("删除")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(Color.white)
                            .frame(width: actionWidth)
                            .frame(maxHeight: .infinity)
                            .background(Color.red)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: revealedWidth)
                .opacity(deleteActionOpacity)
                .allowsHitTesting(isOpen)
                .zIndex(1)
            }

            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: displayedOffset)
                .contentShape(Rectangle())
                .onTapGesture {
                    if activeSwipeID != nil {
                        withAnimation(librarySwipeSpring) {
                            activeSwipeID = nil
                        }
                    } else {
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
                        .font(.system(size: 18, weight: .bold, design: .rounded))
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
            .font(.system(size: 18, weight: .bold, design: .rounded))
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
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
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
    let onTopTap: (Novel) -> Void
    let onExpand: () -> Void
    let onMoveCategory: (Novel) -> Void
    let onDownload: (Novel) -> Void
    let onClearDownloadData: (Novel) -> Void
    let onDelete: (Novel) -> Void

    private let cardHeight: CGFloat = 88
    private let peekOffset: CGFloat = 22
    private let maxVisible = 5

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
                    .font(.system(size: 16, weight: .bold, design: .rounded))
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
                VStack(spacing: -(cardHeight - peekOffset)) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, novel in
                        StackBookCard(novel: novel)
                            .frame(height: cardHeight)
                            .matchedGeometryEffect(id: novel.id, in: namespace, isSource: !isExpanded)
                            // Keep peek cards close to full width so the visible sliver
                            // remains an easy tap target (was 0.012, which made a 2-card
                            // stack's lone peek visibly narrower and easy to misclick).
                            .scaleEffect(1 - CGFloat(index) * 0.005, anchor: .top)
                            .zIndex(Double(maxVisible - index))
                            .opacity(isExpanded ? 0 : 1)
                            .allowsHitTesting(!isExpanded)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if index == 0 {
                                    onTopTap(novel)
                                } else {
                                    onExpand()
                                }
                            }
                            .contextMenu {
                                bookContextMenuButtons(for: novel)
                            }
                    }
                }
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
                            .font(.system(size: 20, weight: .bold, design: .rounded))
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

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sortedNovels) { novel in
                            StackBookCard(novel: novel)
                                .matchedGeometryEffect(id: novel.id, in: namespace, isSource: true)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelect(novel)
                                }
                                .contextMenu {
                                    let actions = bookDownloadActions(for: novel, manager: downloadManager)

                                    Button {
                                        onLongPress(novel)
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
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .background(theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 30, x: 0, y: 14)
            .padding(.horizontal, 16)
            .padding(.top, 60)
            .padding(.bottom, 32)
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
