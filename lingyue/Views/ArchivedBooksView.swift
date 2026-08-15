import SwiftUI

struct ArchivedLibraryEntry: View {
    @Environment(\.appTheme) private var theme
    let bookCount: Int

    var body: some View {
        NavigationLink {
            ArchivedBooksView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(theme.accent.opacity(0.12)))

                VStack(alignment: .leading, spacing: 3) {
                    Text("已归档")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    Text("读完的书在这里安静保存")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer(minLength: 8)

                Text("\(bookCount) 本")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.secondaryText.opacity(0.7))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.cardBackground.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("已归档，\(bookCount) 本")
        .accessibilityHint("查看已归档书籍")
    }
}

private enum ArchiveSortMode: String, CaseIterable, Identifiable {
    case archivedAt = "最近归档"
    case title = "书名"
    case author = "作者"

    var id: String { rawValue }
}

struct ArchivedBooksView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var downloadManager: BookDownloadManager
    @EnvironmentObject private var overlayManager: OverlayManager
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false

    @State private var searchText = ""
    @State private var sortMode: ArchiveSortMode = .archivedAt
    @State private var bookToOpen: Novel?
    @State private var pendingDeletion: Novel?
    @State private var newBookCategoryName = ""

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 12 }
        return horizontalSizeClass == .compact ? 16 : 24
    }

    private var coverSize: (width: CGFloat, height: CGFloat) {
        dynamicTypeSize.isAccessibilitySize ? (82, 116) : (94, 132)
    }

    private var columns: [GridItem] {
        let minimum: CGFloat = dynamicTypeSize.isAccessibilitySize ? 82 : 94
        return [GridItem(.adaptive(minimum: minimum, maximum: 124), spacing: 16, alignment: .top)]
    }

    private var visibleRecords: [ArchivedBookRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = libraryStore.archivedBooks.filter { record in
            query.isEmpty ||
            record.novel.title.localizedCaseInsensitiveContains(query) ||
            record.novel.author.localizedCaseInsensitiveContains(query)
        }

        switch sortMode {
        case .archivedAt:
            return filtered.sorted { $0.archivedAt > $1.archivedAt }
        case .title:
            return filtered.sorted {
                $0.novel.title.localizedStandardCompare($1.novel.title) == .orderedAscending
            }
        case .author:
            return filtered.sorted {
                let comparison = $0.novel.author.localizedStandardCompare($1.novel.author)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return $0.novel.title.localizedStandardCompare($1.novel.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            if visibleRecords.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(visibleRecords) { record in
                            archiveBookCell(record.novel)
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            }
        }
        .navigationTitle("已归档")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索书名或作者")
        .navigationDestination(item: $bookToOpen) { novel in
            ReaderView(novel: novel)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(ArchiveSortMode.allCases) { mode in
                        Button {
                            sortMode = mode
                        } label: {
                            if sortMode == mode {
                                Label(mode.rawValue, systemImage: "checkmark")
                            } else {
                                Text(mode.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(theme.accent)
                }
                .accessibilityLabel("排序")
            }
        }
        .alert(
            "删除书籍",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { novel in
            Button("删除", role: .destructive) {
                libraryStore.deleteBook(novel)
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { novel in
            Text("确定删除《\(displayed(novel.title))》吗？书籍和已下载内容会被移除，阅读统计仍会保留。")
        }
        .task {
            await downloadManager.refreshStates(for: libraryStore.archivedNovels)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: searchText.isEmpty ? "archivebox" : "magnifyingglass")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(theme.secondaryText.opacity(0.65))
            Text(searchText.isEmpty ? "还没有归档书籍" : "没有匹配的书籍")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            if searchText.isEmpty {
                Text("在书架中长按一本书，选择“整理书籍”即可归档")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
    }

    private func archiveBookCell(_ novel: Novel) -> some View {
        let actions = bookDownloadActions(for: novel, manager: downloadManager)
        return Button {
            bookToOpen = novel
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                BookCover(novel: novel, width: coverSize.width, height: coverSize.height)
                    .shadow(color: theme.cardShadow.opacity(0.75), radius: 8, x: 0, y: 4)

                Text(displayed(novel.title))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !novel.author.isEmpty {
                    Text(displayed(novel.author))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: coverSize.width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                presentCategoryEditor(for: novel)
            } label: {
                Label("移动到分类", systemImage: "folder")
            }

            if let onDownload = actions.onDownload {
                Button(action: onDownload) {
                    Label("下载本书", systemImage: "arrow.down.circle")
                }
            }

            if let onClearDownloadData = actions.onClearDownloadData {
                Button(action: onClearDownloadData) {
                    Label("清理缓存", systemImage: "arrow.down.circle.dotted")
                }
            }

            Button(role: .destructive) {
                pendingDeletion = novel
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(displayed(novel.title))，\(displayed(novel.author))")
        .accessibilityHint("打开阅读器")
    }

    private func presentCategoryEditor(for novel: Novel) {
        newBookCategoryName = ""
        overlayManager.present {
            CategoryEditOverlay(
                novel: novel,
                newCategoryName: $newBookCategoryName,
                onDismiss: {
                    newBookCategoryName = ""
                    overlayManager.dismiss()
                }
            )
        }
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }
}
