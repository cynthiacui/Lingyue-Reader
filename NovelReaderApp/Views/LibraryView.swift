import SwiftUI

struct LibraryView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var categories = LibraryCategory.seeded(from: MockData.novels)
    @State private var isAddingCategory = false
    @State private var newCategoryName = ""
    @State private var actionBook: Novel?
    @State private var categoryEditBook: Novel?
    @State private var newBookCategoryName = ""

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
            }
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .safeAreaPadding(.bottom, 12)

            if let actionBook {
                bookActionOverlay(for: actionBook)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(10)
            }

            if let categoryEditBook {
                categoryEditOverlay(for: categoryEditBook)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(11)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: actionBook?.id)
        .animation(.easeInOut(duration: 0.18), value: categoryEditBook?.id)
        .navigationTitle("书架")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newCategoryName = ""
                    isAddingCategory = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建分类")
            }
        }
        .alert("新建分类", isPresented: $isAddingCategory) {
            TextField("分类名称", text: $newCategoryName)

            Button("取消", role: .cancel) {
                newCategoryName = ""
            }

            Button("添加") {
                addCategory()
            }
        } message: {
            Text("分类会先创建为空，可以稍后加入书籍。")
        }
    }

    private var currentlyReadingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CompactSectionHeader(title: "继续阅读")

            LazyVGrid(columns: readingColumns, spacing: 10) {
                ForEach(Array(MockData.currentlyReading.prefix(2))) { novel in
                    NavigationLink {
                        ReaderView(novel: novel)
                    } label: {
                        CompactReadingCard(novel: novel)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.45)
                            .onEnded { _ in
                                presentBookActions(for: novel)
                            }
                    )
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
                    newCategoryName = ""
                    isAddingCategory = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.readerAccent)
                }
                .accessibilityLabel("新建分类")
            }

            if categories.isEmpty {
                EmptyCategoryCard()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(categories) { category in
                        CategoryShelf(
                            category: category,
                            categories: $categories,
                            onBookLongPress: presentBookActions
                        )
                    }
                }
            }
        }
    }

    private func bookActionOverlay(for novel: Novel) -> some View {
        BookActionOverlay(novel: novel) {
            newBookCategoryName = ""
            actionBook = nil
            categoryEditBook = novel
        } onDismiss: {
            actionBook = nil
        }
    }

    private func categoryEditOverlay(for novel: Novel) -> some View {
        CategoryEditOverlay(
            novel: novel,
            categories: $categories,
            newCategoryName: $newBookCategoryName
        ) {
            categoryEditBook = nil
        } onDismiss: {
            categoryEditBook = nil
            newBookCategoryName = ""
        }
    }

    private func presentBookActions(for novel: Novel) {
        actionBook = novel
    }

    private func addCategory() {
        let trimmedName = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let exists = categories.contains {
            $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
        guard !exists else {
            newCategoryName = ""
            return
        }

        categories.append(LibraryCategory(name: trimmedName, novels: []))
        newCategoryName = ""
    }
}

private struct LibraryCategory: Identifiable {
    let id = UUID()
    let name: String
    var novels: [Novel]

    static func seeded(from novels: [Novel]) -> [LibraryCategory] {
        var categoryNames: [String] = []

        for novel in novels {
            if !categoryNames.contains(novel.genre) {
                categoryNames.append(novel.genre)
            }
        }

        return categoryNames.map { categoryName in
            LibraryCategory(
                name: categoryName,
                novels: novels.filter { $0.genre == categoryName }
            )
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

private struct BookActionOverlay: View {
    let novel: Novel
    let onEditCategory: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        CenteredOverlay {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(novel.title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.readerInk)
                        .lineLimit(1)

                    Text("选择操作")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.readerMuted)
                }

                Button(action: onEditCategory) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 17, weight: .semibold))

                        Text("编辑书籍分类")
                            .font(.system(size: 15, weight: .semibold))

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.readerMuted)
                    }
                    .foregroundStyle(Color.readerInk)
                    .padding(12)
                    .background(Color.readerBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button("取消", action: onDismiss)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.readerMuted)
                    .frame(maxWidth: .infinity)
            }
            .padding(16)
            .frame(maxWidth: 320, alignment: .leading)
            .background(Color.readerSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 12)
        } onDismiss: {
            onDismiss()
        }
    }
}

private struct CategoryEditOverlay: View {
    let novel: Novel
    @Binding var categories: [LibraryCategory]
    @Binding var newCategoryName: String
    let onMove: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        CenteredOverlay {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("移动到分类")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.readerInk)

                    Text(novel.title)
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
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 14))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(Color.readerBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

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
            onMove()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(novel.title)
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

            Text(novel.lastChapter)
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
}

private struct CategoryShelf: View {
    let category: LibraryCategory
    @Binding var categories: [LibraryCategory]
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
                        NavigationLink {
                            ReaderView(novel: novel)
                        } label: {
                            CategoryBookRow(novel: novel, categoryName: category.name)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.45)
                                .onEnded { _ in
                                    onBookLongPress(novel)
                                }
                        )
                    }
                }
            }
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
    let categoryName: String?

    init(novel: Novel, categoryName: String? = nil) {
        self.novel = novel
        self.categoryName = categoryName
    }

    var body: some View {
        HStack(spacing: 10) {
            BookCover(novel: novel, width: 44, height: 62)

            VStack(alignment: .leading, spacing: 4) {
                Text(novel.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.readerInk)
                    .lineLimit(1)

                Text("\(novel.author) · \(categoryName ?? novel.genre)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.readerMuted)
                    .lineLimit(1)

                Text(novel.lastChapter)
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
    @State private var actionBook: Novel?
    @State private var categoryEditBook: Novel?
    @State private var newBookCategoryName = ""

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
            return filtered.sorted { $0.readMinutes > $1.readMinutes }
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
                                NavigationLink {
                                    ReaderView(novel: novel)
                                } label: {
                                    CategoryBookRow(novel: novel, categoryName: categoryName)
                                }
                                .buttonStyle(.plain)
                                .simultaneousGesture(
                                    LongPressGesture(minimumDuration: 0.45)
                                        .onEnded { _ in
                                            actionBook = novel
                                        }
                                )
                            }
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 18)
            }
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .safeAreaPadding(.bottom, 12)

            if let actionBook {
                BookActionOverlay(novel: actionBook) {
                    newBookCategoryName = ""
                    self.actionBook = nil
                    categoryEditBook = actionBook
                } onDismiss: {
                    self.actionBook = nil
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(10)
            }

            if let categoryEditBook {
                CategoryEditOverlay(
                    novel: categoryEditBook,
                    categories: $categories,
                    newCategoryName: $newBookCategoryName
                ) {
                    self.categoryEditBook = nil
                } onDismiss: {
                    self.categoryEditBook = nil
                    newBookCategoryName = ""
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(11)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: actionBook?.id)
        .animation(.easeInOut(duration: 0.18), value: categoryEditBook?.id)
        .navigationTitle(categoryName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索书名、作者或章节")
    }
}

#Preview {
    LibraryView()
}
