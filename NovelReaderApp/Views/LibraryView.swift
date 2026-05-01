import SwiftUI

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
    @EnvironmentObject private var libraryStore: LibraryStore

    @State private var isAddingCategory = false
    @State private var newCategoryName = ""
    @State private var categoryEditBook: Novel?
    @State private var newBookCategoryName = ""
    @State private var activeSwipeID: UUID?

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

    var body: some View {
        ZStack {
            Color.readerBackground.ignoresSafeArea()

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

            if let categoryEditBook {
                categoryEditOverlay(for: categoryEditBook)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(11)
            }

            if isAddingCategory {
                NewCategoryOverlay(
                    categoryName: $newCategoryName,
                    onAdd: addCategory,
                    onDismiss: {
                        newCategoryName = ""
                        isAddingCategory = false
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(12)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: categoryEditBook?.id)
        .animation(.easeInOut(duration: 0.18), value: isAddingCategory)
        .navigationTitle("书架")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    closeActiveSwipe()
                    newCategoryName = ""
                    isAddingCategory = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建分类")
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

    private var currentlyReadingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CompactSectionHeader(title: "最近阅读")

            LazyVGrid(columns: readingColumns, spacing: 10) {
                ForEach(Array(libraryStore.currentlyReading.prefix(2))) { novel in
                    BookPressableNavigationRow(
                        rowID: novel.id,
                        activeSwipeID: $activeSwipeID
                    ) {
                        ReaderView(novel: novel)
                    } label: {
                        CompactReadingCard(novel: novel)
                    } onLongPress: {
                        presentCategoryEditor(for: novel)
                    } onClearDownloadData: {
                        clearDownloadedData(for: novel)
                    } onDelete: {
                        libraryStore.deleteBook(novel)
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

                Button {
                    closeActiveSwipe()
                    newCategoryName = ""
                    isAddingCategory = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.readerAccent)
                }
                .accessibilityLabel("新建分类")
            }

            if libraryStore.categories.isEmpty {
                EmptyCategoryCard()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(libraryStore.categories) { category in
                        CategoryShelf(
                            category: category,
                            categories: $libraryStore.categories,
                            activeSwipeID: $activeSwipeID,
                            onBookLongPress: presentCategoryEditor
                        )
                    }
                }
            }
        }
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
        newCategoryName = ""
        isAddingCategory = false
    }

    private func clearDownloadedData(for novel: Novel) {
        Task {
            await ChapterContentCache.shared.clearCache(for: novel)
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

private struct BookPressableNavigationRow<Destination: View, Label: View>: View {
    @State private var isNavigating = false
    @State private var didLongPress = false
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    let rowID: UUID
    @Binding var activeSwipeID: UUID?
    let destination: Destination
    let label: Label
    let onLongPress: () -> Void
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
        @ViewBuilder destination: () -> Destination,
        @ViewBuilder label: () -> Label,
        onLongPress: @escaping () -> Void,
        onClearDownloadData: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.rowID = rowID
        self._activeSwipeID = activeSwipeID
        self.destination = destination()
        self.label = label()
        self.onLongPress = onLongPress
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
                                Text("清缓存")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(Color.white)
                            .frame(width: actionWidth)
                            .frame(maxHeight: .infinity)
                            .background(Color.readerAccent)
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
                .navigationDestination(isPresented: $isNavigating) {
                    destination
                }
                .onTapGesture {
                    guard !didLongPress else { return }
                    if activeSwipeID != nil {
                        withAnimation(librarySwipeSpring) {
                            activeSwipeID = nil
                        }
                    } else {
                        isNavigating = true
                    }
                }
                .onLongPressGesture(minimumDuration: 0.45) {
                    guard activeSwipeID == nil else {
                        withAnimation(librarySwipeSpring) {
                            activeSwipeID = nil
                        }
                        return
                    }

                    didLongPress = true
                    onLongPress()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        didLongPress = false
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

private struct NewCategoryOverlay: View {
    @Binding var categoryName: String
    @FocusState private var isNameFocused: Bool

    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        CenteredOverlay {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("新建分类")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.readerInk)

                    Text("分类会先创建为空，可以稍后加入书籍。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.readerMuted)
                }

                TextField("分类名称", text: $categoryName)
                    .focused($isNameFocused)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color.readerBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onSubmit(addIfPossible)

                HStack(spacing: 10) {
                    Button("取消") {
                        onDismiss()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.readerMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.readerBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Button("添加") {
                        addIfPossible()
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.readerSurface)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(trimmedCategoryName.isEmpty ? Color.readerMuted.opacity(0.45) : Color.readerAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .disabled(trimmedCategoryName.isEmpty)
                }
            }
            .padding(16)
            .frame(maxWidth: 340, alignment: .leading)
            .background(Color.readerSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 12)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    isNameFocused = true
                }
            }
        } onDismiss: {
            onDismiss()
        }
    }

    private var trimmedCategoryName: String {
        categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addIfPossible() {
        guard !trimmedCategoryName.isEmpty else { return }
        onAdd()
    }
}

private struct CategoryEditOverlay: View {
    let novel: Novel
    @Binding var categories: [LibraryCategory]
    @Binding var newCategoryName: String
    @FocusState private var isNewCategoryFocused: Bool
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false
    let onDismiss: () -> Void

    var body: some View {
        CenteredOverlay {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("移动到分类")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.readerInk)

                    Text(displayed(novel.title))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.readerMuted)
                        .lineLimit(1)
                }

                if categories.isEmpty {
                    Text("还没有分类，可以先创建一个。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.readerMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.readerBackground)
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
                                            .foregroundStyle(Color.readerAccent)

                                        Text(category.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(Color.readerInk)
                                            .lineLimit(1)

                                        Spacer()

                                        Text("\(category.novels.count)")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.readerMuted)

                                        if categoryContains(novel, categoryID: category.id) {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundStyle(Color.readerAccent)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(Color.readerBackground)
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
                        .foregroundStyle(Color.readerMuted)

                    HStack(spacing: 8) {
                        TextField("分类名称", text: $newCategoryName)
                            .focused($isNewCategoryFocused)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .font(.system(size: 14))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(Color.readerBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .onSubmit {
                                createCategoryAndMove(novel)
                            }

                        Button("添加") {
                            createCategoryAndMove(novel)
                        }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.readerSurface)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(trimmedNewCategoryName.isEmpty ? Color.readerMuted.opacity(0.45) : Color.readerAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .disabled(trimmedNewCategoryName.isEmpty)
                    }
                }

                Button("取消") {
                    newCategoryName = ""
                    onDismiss()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.readerMuted)
                .frame(maxWidth: .infinity)
            }
            .padding(16)
            .frame(maxWidth: 340, alignment: .leading)
            .background(Color.readerSurface)
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
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(Color.readerInk)
    }
}

private struct CompactReadingCard: View {
    let novel: Novel
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(displayed(novel.title))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.readerInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 4)

                Text("\(Int(novel.progress * 100))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.readerAccent)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text(displayed(novel.lastChapter))
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(Color.readerMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            ProgressView(value: novel.progress)
                .tint(.readerAccent)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Color.readerSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.035), radius: 8, x: 0, y: 4)
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }
}

private struct CategoryShelf: View {
    let category: LibraryCategory
    @Binding var categories: [LibraryCategory]
    @Binding var activeSwipeID: UUID?
    let onBookLongPress: (Novel) -> Void

    private let previewLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(category.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.readerInk)
                    .lineLimit(1)

                Spacer()

                Text("\(category.novels.count) 本")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.readerMuted)

                if !category.novels.isEmpty {
                    NavigationLink {
                        CategoryDetailView(
                            categoryID: category.id,
                            categories: $categories
                        )
                    } label: {
                        Text("查看全部")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color.readerAccent)
                }
            }

            if category.novels.isEmpty {
                EmptyCategoryRow()
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(category.novels.prefix(previewLimit))) { novel in
                        BookPressableNavigationRow(
                            rowID: novel.id,
                            activeSwipeID: $activeSwipeID
                        ) {
                            ReaderView(novel: novel)
                        } label: {
                            CategoryBookRow(novel: novel)
                        } onLongPress: {
                            onBookLongPress(novel)
                        } onClearDownloadData: {
                            clearDownloadedData(for: novel)
                        } onDelete: {
                            delete(novel)
                        }
                    }
                }
            }
        }
    }

    private func delete(_ novel: Novel) {
        var updatedCategories = categories
        for index in updatedCategories.indices {
            updatedCategories[index].novels.removeAll { $0.id == novel.id }
        }
        categories = updatedCategories
    }

    private func clearDownloadedData(for novel: Novel) {
        Task {
            await ChapterContentCache.shared.clearCache(for: novel)
        }
    }
}

private struct EmptyCategoryCard: View {
    var body: some View {
        Text("还没有分类")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.readerMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.readerSurface.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct EmptyCategoryRow: View {
    var body: some View {
        Text("暂无书籍")
            .font(.system(size: 13))
            .foregroundStyle(Color.readerMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.readerSurface.opacity(0.58))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CategoryBookRow: View {
    let novel: Novel
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false

    private var metadataLine: String {
        let author = displayed(novel.author)
        guard let source = BookSourceRegistry.displayName(for: novel.sourceURLString) else {
            return author
        }
        return "\(author) · \(displayed(source))"
    }

    var body: some View {
        HStack(spacing: 10) {
            BookCover(novel: novel, width: 44, height: 62)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayed(novel.title))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.readerInk)
                    .lineLimit(1)

                Text(metadataLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.readerMuted)
                    .lineLimit(1)

                Text(displayed(novel.lastChapter))
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(Color.readerMuted)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text("\(Int(novel.progress * 100))%")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.readerAccent)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.readerSurface.opacity(0.78))
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
    @State private var searchText = ""
    @State private var sortMode: CategorySortMode = .recent
    @State private var categoryEditBook: Novel?
    @State private var newBookCategoryName = ""
    @State private var activeSwipeID: UUID?

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
            Color.readerBackground.ignoresSafeArea()

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
                                BookPressableNavigationRow(
                                    rowID: novel.id,
                                    activeSwipeID: $activeSwipeID
                                ) {
                                    ReaderView(novel: novel)
                                } label: {
                                    CategoryBookRow(novel: novel)
                                } onLongPress: {
                                    presentCategoryEditor(for: novel)
                                } onClearDownloadData: {
                                    clearDownloadedData(for: novel)
                                } onDelete: {
                                    delete(novel)
                                }
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
        Task {
            await ChapterContentCache.shared.clearCache(for: novel)
        }
    }
}

#Preview {
    LibraryView()
        .environmentObject(LibraryStore())
}
