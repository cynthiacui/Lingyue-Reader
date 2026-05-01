import SwiftUI
import Foundation
import UIKit

struct ReaderView: View {
    let novel: Novel

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("reader.fontSize") private var fontSize = 18.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.theme") private var themeRawValue = ReadingTheme.paper.rawValue
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false
    @AppStorage("reader.cacheEnabled") private var cacheEnabled = true

    @State private var currentChapterIndex = 0
    @State private var currentChapterPageIndex = 0
    @State private var visiblePages: [ReaderPageItem] = []
    @State private var visiblePageSignature: String?
    @State private var showControls = false
    @State private var showChapterPicker = false
    @State private var didSetInitialPage = false
    @State private var loadedChapterOverrides: [String: NovelChapter] = [:]
    @State private var loadingChapterKeys: Set<String> = []
    @State private var chapterLoadErrors: [String: String] = [:]
    @State private var repairedNovel: Novel?
    @State private var isRepairingCatalog = false
    @State private var catalogRepairError: String?
    @State private var lastPersistedReadingState: String?
    @State private var pendingRestoreChapterKey: String?
    @State private var pendingRestoreChapterPageIndex: Int?
    @State private var prefetchingChapterKeys: Set<String> = []
    @State private var downloadedChapterKeys: Set<String> = []
    @State private var shouldJumpToLastPageAfterPagination = false
    /// Cache of paginated page contents keyed by paginationSignature. Lets revisits to a
    /// chapter (and visits to chapters pre-paginated by the prefetch loop) skip the async
    /// pagination step entirely so the reader doesn't flash a placeholder.
    @State private var paginationCache: [String: [String]] = [:]
    @State private var lastKnownTextSize: CGSize = .zero
    private let paginationCacheCapacity = 24

    private var activeNovel: Novel {
        repairedNovel ?? novel
    }

    private var baseChapters: [NovelChapter] {
        if catalogNeedsRepair {
            let message = catalogRepairError.map { "目录修复失败：\($0)" } ?? "正在修复章节目录..."
            return [NovelChapter(title: activeNovel.title, content: message)]
        }

        return activeNovel.chapters.isEmpty ? MockData.chapters(for: activeNovel) : activeNovel.chapters
    }

    private var chapters: [NovelChapter] {
        baseChapters.map { chapter in
            loadedChapterOverrides[chapterCacheKey(chapter)] ?? chapter
        }
    }

    private var currentChapter: NovelChapter? {
        guard baseChapters.indices.contains(currentChapterIndex) else { return nil }
        let chapter = baseChapters[currentChapterIndex]
        return loadedChapterOverrides[chapterCacheKey(chapter)] ?? chapter
    }

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 16 }
        return horizontalSizeClass == .compact ? 18 : 36
    }

    private var currentTheme: ReadingTheme {
        ReadingTheme(rawValue: themeRawValue) ?? .paper
    }

    private var catalogNeedsRepair: Bool {
        repairedNovel == nil && BookImportService.shared.catalogNeedsRepair(for: novel)
    }

    private var pageBackground: Color { currentTheme.pageBackground }
    private var pageForeground: Color { currentTheme.pageForeground }
    private var secondaryForeground: Color { currentTheme.secondaryForeground }

    var body: some View {
        GeometryReader { proxy in
            let textSize = readerTextSize(containerSize: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
            let pages = activeVisiblePages()
            let currentPage = currentPage(in: pages)
            let pageSignature = paginationSignature(textSize: textSize)

            ZStack {
                pageBackground.ignoresSafeArea()

                TabView(selection: $currentChapterPageIndex) {
                    ForEach(pages.indices, id: \.self) { index in
                        pageView(for: pages[index], safeAreaInsets: proxy.safeAreaInsets, textSize: textSize)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // Rebuild the page TabView whenever the chapter changes so its underlying
                // UIPageViewController doesn't animate the selection-index jump (e.g. 5 → 0)
                // as a backwards swipe. .transition(.identity) ensures the rebuild is
                // instant rather than fading/sliding.
                .id(currentChapterIndex)
                .transition(.identity)
                .ignoresSafeArea()

                pageTapZones(pages: pages)

                if showControls {
                    controlsTopBar(safeTop: proxy.safeAreaInsets.top, currentPage: currentPage)
                        .transition(.move(edge: .top).combined(with: .opacity))

                    controlsBottomBar(
                        safeBottom: proxy.safeAreaInsets.bottom,
                        pages: pages,
                        currentPage: currentPage
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if !showControls {
                    readerHeader(safeTop: proxy.safeAreaInsets.top)
                        .transition(.opacity)
                }

                if showChapterPicker {
                    chapterPickerOverlay(pages: pages, currentPage: currentPage)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .onAppear {
                setInitialChapterIfNeeded()
                persistReadingState(pages: pages)
                lastKnownTextSize = textSize
            }
            .onChange(of: textSize) { _, newValue in
                if newValue.width > 0, newValue.height > 0 {
                    lastKnownTextSize = newValue
                }
            }
            .onChange(of: currentChapterPageIndex) {
                persistReadingState(pages: activeVisiblePages())
            }
            .onChange(of: visiblePages.count) {
                let activePages = activeVisiblePages()
                clampCurrentPage(to: activePages)
                applyPendingPageRestoreIfNeeded(pages: activePages)
                persistReadingState(pages: activePages)
            }
            .task(id: pageSignature) {
                await rebuildVisiblePagesIfNeeded(textSize: textSize, signature: pageSignature)
            }
            .task(id: currentChapterIndex) {
                persistReadingState(pages: activeVisiblePages())
                await prepareChapter(at: currentChapterIndex)
            }
            .task {
                await repairCatalogIfNeeded()
            }
            .task(id: showChapterPicker) {
                guard showChapterPicker else { return }
                await refreshDownloadedChapterKeys()
            }
        }
        .ignoresSafeArea()
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showControls)
    }

    private func headerTopPadding(safeTop: CGFloat) -> CGFloat {
        max(safeTop - 24, 26)
    }

    private func contentTopPadding(safeAreaInsets: EdgeInsets) -> CGFloat {
        let gapBelowHeader: CGFloat = dynamicTypeSize.isAccessibilitySize ? 40 : 20
        let minimum: CGFloat = dynamicTypeSize.isAccessibilitySize ? 82 : 68
        return max(safeAreaInsets.top + gapBelowHeader, minimum)
    }

    private func contentBottomPadding(safeAreaInsets: EdgeInsets) -> CGFloat {
        let minimum: CGFloat = dynamicTypeSize.isAccessibilitySize ? 72 : 56
        return max(safeAreaInsets.bottom + 24, minimum)
    }

    private func controlsTopPadding(safeTop: CGFloat) -> CGFloat {
        max(safeTop + 8, 52)
    }

    private func pageView(for page: ReaderPageItem, safeAreaInsets: EdgeInsets, textSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            JustifiedReaderText(
                text: page.content,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                color: UIColor(pageForeground)
            )
            .frame(width: textSize.width, height: textSize.height, alignment: .topLeading)

            HStack {
                Text(page.chapterTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer()

                Text("\(page.pageIndex + 1) / \(page.chapterPageCount)")
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(secondaryForeground)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, horizontalMargin)
        .padding(.top, contentTopPadding(safeAreaInsets: safeAreaInsets))
        .padding(.bottom, contentBottomPadding(safeAreaInsets: safeAreaInsets))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pageTapZones(pages: [ReaderPageItem]) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: proxy.size.width * 0.32)
                    .onTapGesture {
                        goToPreviousPage(pages: pages)
                    }

                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: proxy.size.width * 0.36)
                    .onTapGesture {
                        toggleControls()
                    }

                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: proxy.size.width * 0.32)
                    .onTapGesture {
                        goToNextPage(pages: pages)
                    }
            }
        }
        .ignoresSafeArea()
    }

    private func readerHeader(safeTop: CGFloat) -> some View {
        VStack {
            HStack(alignment: .center, spacing: 14) {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    Text(timeString(from: timeline.date))
                        .monospacedDigit()
                }
                .frame(alignment: .leading)

                Spacer()

                Text(displayed(activeNovel.title))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(alignment: .trailing)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(secondaryForeground)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalMargin)
            .padding(.top, headerTopPadding(safeTop: safeTop))

            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func controlsTopBar(safeTop: CGFloat, currentPage: ReaderPageItem) -> some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(currentPage.chapterTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(secondaryForeground)
                    .lineLimit(1)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showChapterPicker = true
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(pageForeground)
            .padding(.horizontal, 18)
            .padding(.top, controlsTopPadding(safeTop: safeTop))
            .padding(.bottom, 14)
            .background(
                Rectangle()
                    .fill(currentTheme.chromeBackground)
                    .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 3)
            )

            Spacer()
        }
        .ignoresSafeArea(edges: .top)
    }

    private func controlsBottomBar(
        safeBottom: CGFloat,
        pages: [ReaderPageItem],
        currentPage: ReaderPageItem
    ) -> some View {
        let pageCount = max(currentPage.chapterPageCount, 1)
        let canGoPrevChapter = currentChapterIndex > 0
        let canGoNextChapter = currentChapterIndex < baseChapters.count - 1

        return VStack {
            Spacer()

            VStack(spacing: 6) {
                Text("本章进度")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondaryForeground)

                HStack(spacing: 12) {
                    Button {
                        guard canGoPrevChapter else { return }
                        goToChapter(currentChapterIndex - 1, pageIndex: 0)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canGoPrevChapter)
                    .opacity(canGoPrevChapter ? 1 : 0.35)

                    pageProgressSlider(pageCount: pageCount)

                    Button {
                        guard canGoNextChapter else { return }
                        goToChapter(currentChapterIndex + 1, pageIndex: 0)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canGoNextChapter)
                    .opacity(canGoNextChapter ? 1 : 0.35)
                }
            }
            .foregroundStyle(pageForeground)
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, max(safeBottom + 8, 18))
            .background(
                Rectangle()
                    .fill(currentTheme.chromeBackground)
                    .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: -3)
            )
        }
        .ignoresSafeArea(edges: .bottom)
    }

    @ViewBuilder
    private func pageProgressSlider(pageCount: Int) -> some View {
        if pageCount > 1 {
            let upperBound = Double(pageCount - 1)
            let clampedIndex = min(max(currentChapterPageIndex, 0), pageCount - 1)
            let sliderValue = Binding<Double>(
                get: { Double(clampedIndex) },
                set: { newValue in
                    let next = min(max(Int(newValue.rounded()), 0), pageCount - 1)
                    if next != currentChapterPageIndex {
                        currentChapterPageIndex = next
                    }
                }
            )
            GeometryReader { proxy in
                Slider(value: sliderValue, in: 0...upperBound, step: 1)
                    .tint(Color.readerAccent)
                    .simultaneousGesture(
                        SpatialTapGesture(coordinateSpace: .local)
                            .onEnded { event in
                                guard proxy.size.width > 0 else { return }
                                let fraction = max(0, min(1, event.location.x / proxy.size.width))
                                let target = Int((fraction * upperBound).rounded())
                                let clamped = min(max(target, 0), pageCount - 1)
                                if clamped != currentChapterPageIndex {
                                    currentChapterPageIndex = clamped
                                }
                            }
                    )
            }
            .frame(height: 32)
        } else {
            Capsule()
                .fill(secondaryForeground.opacity(0.25))
                .frame(height: 4)
                .padding(.vertical, 14)
        }
    }

    private func chapterPickerOverlay(pages: [ReaderPageItem], currentPage: ReaderPageItem) -> some View {
        ZStack {
            Color.black.opacity(currentTheme == .night ? 0.45 : 0.22)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("章节目录")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(pageForeground)

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showChapterPicker = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(secondaryForeground)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(chapters.indices, id: \.self) { index in
                                Button {
                                    goToChapter(index, pageIndex: 0)
                                    Task {
                                        await prepareChapter(at: index)
                                    }
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        showChapterPicker = false
                                        showControls = false
                                    }
                                } label: {
                                    HStack {
                                        Text(displayed(chapters[index].title))
                                            .font(.system(size: 15, weight: currentPage.chapterIndex == index ? .bold : .regular))
                                            .lineLimit(1)

                                        if isChapterDownloaded(chapters[index]) {
                                            Image(systemName: "arrow.down.circle.fill")
                                                .font(.system(size: 12, weight: .semibold))
                                                .accessibilityLabel("已下载")
                                        }

                                        Spacer()

                                        if currentPage.chapterIndex == index {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .bold))
                                        }
                                    }
                                    .foregroundStyle(currentPage.chapterIndex == index ? Color.readerAccent : pageForeground)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(currentPage.chapterIndex == index ? Color.readerAccent.opacity(0.12) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(currentPage.chapterIndex, anchor: .center)
                        Task {
                            await refreshDownloadedChapterKeys()
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 330, maxHeight: 430, alignment: .topLeading)
            .background(currentTheme.surfaceBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
            .padding(.horizontal, 28)
        }
    }

    private func currentPage(in pages: [ReaderPageItem]) -> ReaderPageItem {
        guard !pages.isEmpty else {
            return placeholderPage(forChapterAt: currentChapterIndex)
        }

        return pages[min(currentChapterPageIndex, pages.count - 1)]
    }

    private func activeVisiblePages() -> [ReaderPageItem] {
        guard visiblePages.first?.chapterIndex == currentChapterIndex else {
            return [placeholderPage(forChapterAt: currentChapterIndex)]
        }

        return visiblePages.isEmpty ? [placeholderPage(forChapterAt: currentChapterIndex)] : visiblePages
    }

    private func placeholderPage(forChapterAt chapterIndex: Int) -> ReaderPageItem {
        let chapter = baseChapters.indices.contains(chapterIndex) ? baseChapters[chapterIndex] : nil
        let title = displayed(chapter?.title ?? activeNovel.title)
        return ReaderPageItem(
            chapterIndex: max(0, chapterIndex),
            pageIndex: 0,
            chapterPageCount: 1,
            chapterTitle: title,
            content: displayed(readerContent(for: chapter, chapterIndex: chapterIndex))
        )
    }

    private func setInitialChapterIfNeeded() {
        guard !didSetInitialPage else { return }

        if let chapterIndex = restoredChapterIndex() {
            let chapterPageIndex = max(activeNovel.currentChapterPageIndex ?? 0, 0)
            pendingRestoreChapterKey = chapterCacheKey(baseChapters[chapterIndex])
            pendingRestoreChapterPageIndex = chapterPageIndex
            currentChapterIndex = chapterIndex
            currentChapterPageIndex = chapterPageIndex
        } else {
            currentChapterIndex = fallbackChapterIndexFromProgress()
            currentChapterPageIndex = 0
        }

        loadDiskCachedChapterImmediately(at: currentChapterIndex)
        didSetInitialPage = true
    }

    private func clampCurrentPage(to pages: [ReaderPageItem]) {
        guard !pages.isEmpty else {
            currentChapterPageIndex = 0
            return
        }

        if shouldJumpToLastPageAfterPagination {
            shouldJumpToLastPageAfterPagination = false
            // After a backward chapter jump (prev-page from page 0), the just-paginated chapter
            // wants to land on its last page. Snap without animation so the TabView doesn't
            // slide forward (0 → last) immediately after the chapter swap.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                currentChapterPageIndex = max(pages.count - 1, 0)
            }
        } else {
            currentChapterPageIndex = min(currentChapterPageIndex, pages.count - 1)
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls.toggle()
            if !showControls {
                showChapterPicker = false
            }
        }
    }

    private func hideControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls = false
            showChapterPicker = false
        }
    }

    private func goToPreviousPage(pages: [ReaderPageItem]) {
        if showControls {
            hideControls()
            return
        }

        guard !showChapterPicker else { return }
        if currentChapterPageIndex > 0 {
            currentChapterPageIndex -= 1
        } else if currentChapterIndex > 0 {
            shouldJumpToLastPageAfterPagination = true
            goToChapter(currentChapterIndex - 1, pageIndex: 0)
        }
    }

    private func goToNextPage(pages: [ReaderPageItem]) {
        if showControls {
            hideControls()
            return
        }

        guard !showChapterPicker else { return }
        if currentChapterPageIndex < pages.count - 1 {
            currentChapterPageIndex += 1
        } else if currentChapterIndex < baseChapters.count - 1 {
            goToChapter(currentChapterIndex + 1, pageIndex: 0)
        }
    }

    private func goToChapter(_ chapterIndex: Int, pageIndex: Int) {
        guard baseChapters.indices.contains(chapterIndex) else { return }
        // Suppress TabView animation: changing currentChapterPageIndex (e.g., 5 → 0) while
        // pages are being swapped to a new chapter would otherwise animate backwards on a
        // forward jump (and vice versa). Snapping is the right behavior for explicit chapter
        // navigation.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            currentChapterIndex = chapterIndex
            currentChapterPageIndex = max(pageIndex, 0)
        }
        loadDiskCachedChapterImmediately(at: chapterIndex)
    }

    private func loadDiskCachedChapterImmediately(at index: Int) {
        guard baseChapters.indices.contains(index) else { return }

        let chapter = baseChapters[index]
        guard chapter.sourceURLString != nil,
              chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let key = chapterCacheKey(chapter)
        guard loadedChapterOverrides[key] == nil,
              let cachedChapter = ChapterContentCache.diskCachedChapter(for: chapter) else {
            return
        }

        loadedChapterOverrides[key] = cachedChapter
        downloadedChapterKeys.insert(key)
    }

    @MainActor
    private func persistReadingState(pages: [ReaderPageItem]) {
        guard didSetInitialPage, !catalogNeedsRepair, !pages.isEmpty else { return }
        guard pendingRestoreChapterKey == nil else { return }

        let currentPage = currentPage(in: pages)
        guard baseChapters.indices.contains(currentPage.chapterIndex) else { return }

        let currentChapter = baseChapters[currentPage.chapterIndex]
        let progress = readingProgress(for: currentPage)
        let stateKey = "\(activeNovel.id.uuidString)-\(currentPage.chapterIndex)-\(currentPage.pageIndex)-\(pages.count)"
        guard stateKey != lastPersistedReadingState else { return }

        lastPersistedReadingState = stateKey
        libraryStore.updateReadingState(
            for: activeNovel.id,
            chapterTitle: currentChapter.title,
            progress: progress,
            chapterIndex: currentPage.chapterIndex,
            chapterPageIndex: currentPage.pageIndex,
            chapterSourceURLString: currentChapter.sourceURLString
        )
    }

    private func restoredChapterIndex() -> Int? {
        if let sourceURLString = activeNovel.currentChapterSourceURLString,
           let sourceIndex = baseChapters.firstIndex(where: { $0.sourceURLString == sourceURLString }) {
            return sourceIndex
        }

        if let chapterIndex = activeNovel.currentChapterIndex,
           baseChapters.indices.contains(chapterIndex) {
            return chapterIndex
        }

        let trimmedLastChapter = activeNovel.lastChapter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLastChapter.isEmpty,
           let titleIndex = baseChapters.firstIndex(where: {
               $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedLastChapter
           }) {
            return titleIndex
        }

        return nil
    }

    private func fallbackChapterIndexFromProgress() -> Int {
        guard !baseChapters.isEmpty else { return 0 }
        let maxChapterIndex = max(baseChapters.count - 1, 0)
        return min(max(Int((Double(maxChapterIndex) * activeNovel.progress).rounded()), 0), maxChapterIndex)
    }

    private func applyPendingPageRestoreIfNeeded(pages: [ReaderPageItem]) {
        guard let chapterKey = pendingRestoreChapterKey,
              let chapterPageIndex = pendingRestoreChapterPageIndex,
              let chapterIndex = baseChapters.firstIndex(where: { chapterCacheKey($0) == chapterKey }),
              chapterIndex == currentChapterIndex,
              !pages.isEmpty else {
            return
        }

        let targetPageIndex = min(max(chapterPageIndex, 0), max(pages.count - 1, 0))
        if currentChapterPageIndex != targetPageIndex {
            currentChapterPageIndex = targetPageIndex
        }

        let chapter = baseChapters[chapterIndex]
        let chapterIsLoaded = loadedChapterOverrides[chapterKey] != nil
            || !chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || chapter.sourceURLString == nil
            || chapterLoadErrors[chapterKey] != nil

        if chapterPageIndex == 0 || chapterIsLoaded {
            pendingRestoreChapterKey = nil
            pendingRestoreChapterPageIndex = nil
        }
    }

    private func readingProgress(for page: ReaderPageItem) -> Double {
        guard baseChapters.count > 1 else {
            return page.chapterPageCount <= 1 ? 0 : Double(page.pageIndex) / Double(max(page.chapterPageCount - 1, 1))
        }

        let chapterFraction = page.chapterPageCount <= 1
            ? 0
            : Double(page.pageIndex) / Double(max(page.chapterPageCount - 1, 1))
        let rawProgress = (Double(page.chapterIndex) + chapterFraction) / Double(baseChapters.count - 1)
        return min(max(rawProgress, 0), 1)
    }

    private func paginationSignature(textSize: CGSize) -> String {
        let chapter = currentChapter
        return paginationSignature(
            chapterIndex: currentChapterIndex,
            chapter: chapter,
            contentLength: chapter?.content.count ?? 0,
            textSize: textSize
        )
    }

    private func paginationSignature(
        chapterIndex: Int,
        chapter: NovelChapter?,
        contentLength: Int,
        textSize: CGSize
    ) -> String {
        let chapterKey = chapter.map(chapterCacheKey) ?? "\(chapterIndex)"
        let loadState = loadingChapterKeys.contains(chapterKey) ? "loading" : "idle"
        let errorState = chapterLoadErrors[chapterKey] ?? ""
        let width = Int(textSize.width.rounded())
        let height = Int(textSize.height.rounded())
        return [
            "\(chapterIndex)",
            chapterKey,
            "\(contentLength)",
            loadState,
            errorState,
            "\(width)x\(height)",
            "\(fontSize)",
            "\(lineSpacing)",
            "\(usesTraditionalChinese)"
        ].joined(separator: "|")
    }

    @MainActor
    private func rebuildVisiblePagesIfNeeded(textSize: CGSize, signature: String) async {
        guard visiblePageSignature != signature else { return }

        guard let chapter = currentChapter else {
            applyVisiblePages([placeholderPage(forChapterAt: currentChapterIndex)], signature: signature)
            return
        }

        let chapterIndex = currentChapterIndex
        let chapterTitle = displayed(chapter.title)

        // Cache hit: apply paginated pages synchronously so the reader doesn't flash a
        // placeholder while waiting on Task.detached. Covers revisits and chapters that the
        // prefetch loop has already pre-paginated for the current settings.
        if let cached = paginationCache[signature], !cached.isEmpty {
            let items = pageItems(from: cached, chapterIndex: chapterIndex, chapterTitle: chapterTitle)
            applyVisiblePages(items, signature: signature)
            return
        }

        let content = displayed(readerContent(for: chapter, chapterIndex: chapterIndex))
        let fontSize = self.fontSize
        let lineSpacing = self.lineSpacing

        let work = Task.detached(priority: .userInitiated) {
            Self.paginate(content: content, textSize: textSize, fontSize: fontSize, lineSpacing: lineSpacing)
        }
        let pageContents = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }

        if Task.isCancelled || pageContents.isEmpty { return }

        rememberPaginatedPages(pageContents, for: signature)

        let items = pageItems(from: pageContents, chapterIndex: chapterIndex, chapterTitle: chapterTitle)
        applyVisiblePages(items, signature: signature)
    }

    private func pageItems(from contents: [String], chapterIndex: Int, chapterTitle: String) -> [ReaderPageItem] {
        contents.enumerated().map { pageIndex, pageContent in
            ReaderPageItem(
                chapterIndex: chapterIndex,
                pageIndex: pageIndex,
                chapterPageCount: contents.count,
                chapterTitle: chapterTitle,
                content: pageContent
            )
        }
    }

    @MainActor
    private func rememberPaginatedPages(_ pages: [String], for signature: String) {
        paginationCache[signature] = pages
        if paginationCache.count > paginationCacheCapacity {
            // Drop an arbitrary older entry — fine for our purposes; full LRU is overkill.
            if let stale = paginationCache.keys.first(where: { $0 != signature }) {
                paginationCache[stale] = nil
            }
        }
    }

    @MainActor
    private func applyVisiblePages(_ items: [ReaderPageItem], signature: String) {
        visiblePages = items
        visiblePageSignature = signature
        clampCurrentPage(to: items)
        applyPendingPageRestoreIfNeeded(pages: items)
        persistReadingState(pages: items)
    }

    private func readerContent(for chapter: NovelChapter?, chapterIndex: Int) -> String {
        guard let chapter else {
            return activeNovel.title
        }

        if !chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return chapter.content
        }

        guard chapter.sourceURLString != nil else {
            return chapter.title
        }

        let key = chapterCacheKey(chapter)
        if let errorMessage = chapterLoadErrors[key] {
            return "\(chapter.title)\n\n章节加载失败：\(errorMessage)"
        }

        if loadingChapterKeys.contains(key) {
            return "\(chapter.title)\n\n正在加载章节内容..."
        }

        return "\(chapter.title)\n\n正在加载章节内容..."
    }

    @MainActor
    private func prepareChapter(at index: Int) async {
        guard baseChapters.indices.contains(index) else { return }
        await loadCachedChapterIfAvailable(at: index)
        prefetchUpcomingChapters(after: index)
        await loadChapterIfNeeded(at: index)
    }

    @MainActor
    private func loadCachedChapterIfAvailable(at index: Int) async {
        guard baseChapters.indices.contains(index) else { return }

        let chapter = baseChapters[index]
        guard chapter.sourceURLString != nil,
              chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let key = chapterCacheKey(chapter)
        guard loadedChapterOverrides[key] == nil else { return }

        if let cachedChapter = await ChapterContentCache.shared.cachedChapter(for: chapter) {
            loadedChapterOverrides[key] = cachedChapter
            downloadedChapterKeys.insert(key)
        }
    }

    @MainActor
    private func prefetchUpcomingChapters(after index: Int) {
        guard cacheEnabled else { return }

        let upcomingChapters = Array(baseChapters.dropFirst(index + 1).prefix(2)).enumerated()
        for (offset, chapter) in upcomingChapters {
            let chapterIndex = index + 1 + offset
            guard chapter.sourceURLString != nil,
                  chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let key = chapterCacheKey(chapter)
            guard loadedChapterOverrides[key] == nil,
                  !loadingChapterKeys.contains(key),
                  !prefetchingChapterKeys.contains(key) else {
                continue
            }

            prefetchingChapterKeys.insert(key)
            Task {
                do {
                    let loadedChapter = try await ChapterContentCache.shared.chapter(for: chapter)
                    await MainActor.run {
                        loadedChapterOverrides[key] = loadedChapter
                        downloadedChapterKeys.insert(key)
                        _ = prefetchingChapterKeys.remove(key)
                    }
                    await prePaginate(chapter: loadedChapter, originalChapter: chapter, chapterIndex: chapterIndex)
                } catch {
                    await MainActor.run {
                        _ = prefetchingChapterKeys.remove(key)
                    }
                }
            }
        }
    }

    /// Paginate a prefetched chapter using the most recently observed text size and current
    /// font/line settings, then stash the result in paginationCache. When the user actually
    /// navigates to this chapter and the signature matches, the visible-pages rebuild becomes
    /// a synchronous cache hit — no placeholder flash.
    @MainActor
    private func prePaginate(chapter: NovelChapter, originalChapter: NovelChapter, chapterIndex: Int) async {
        let textSize = lastKnownTextSize
        guard textSize.width > 0, textSize.height > 0 else { return }

        let displayedContent = displayed(chapter.content)
        guard !displayedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let signature = paginationSignature(
            chapterIndex: chapterIndex,
            chapter: chapter,
            contentLength: chapter.content.count,
            textSize: textSize
        )
        guard paginationCache[signature] == nil else { return }

        let fontSize = self.fontSize
        let lineSpacing = self.lineSpacing
        let pages = await Task.detached(priority: .utility) {
            Self.paginate(content: displayedContent, textSize: textSize, fontSize: fontSize, lineSpacing: lineSpacing)
        }.value

        guard !pages.isEmpty else { return }
        rememberPaginatedPages(pages, for: signature)
    }

    @MainActor
    private func loadChapterIfNeeded(at index: Int) async {
        guard baseChapters.indices.contains(index) else { return }

        let chapter = baseChapters[index]
        guard chapter.sourceURLString != nil,
              chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let key = chapterCacheKey(chapter)
        guard loadedChapterOverrides[key] == nil, !loadingChapterKeys.contains(key) else {
            return
        }

        loadingChapterKeys.insert(key)
        chapterLoadErrors[key] = nil

        do {
            let loadedChapter = try await ChapterContentCache.shared.chapter(for: chapter)
            loadedChapterOverrides[key] = loadedChapter
            downloadedChapterKeys.insert(key)
        } catch {
            chapterLoadErrors[key] = error.localizedDescription
        }

        loadingChapterKeys.remove(key)
    }

    @MainActor
    private func repairCatalogIfNeeded() async {
        guard !isRepairingCatalog,
              repairedNovel == nil,
              BookImportService.shared.catalogNeedsRepair(for: novel),
              let sourceURLString = novel.sourceURLString,
              let sourceURL = URL(string: sourceURLString) else {
            return
        }

        isRepairingCatalog = true
        catalogRepairError = nil

        do {
            let repaired = try await BookImportService.shared.importBook(from: sourceURL, fallbackTitle: novel.title)
            repairedNovel = repaired
            loadedChapterOverrides.removeAll()
            loadingChapterKeys.removeAll()
            chapterLoadErrors.removeAll()
            prefetchingChapterKeys.removeAll()
            downloadedChapterKeys.removeAll()
            currentChapterIndex = 0
            currentChapterPageIndex = 0
            visiblePages.removeAll()
            visiblePageSignature = nil
            didSetInitialPage = true
            libraryStore.addImportedNovel(repaired)
            libraryStore.updateReadingState(
                for: repaired.id,
                chapterTitle: repaired.chapters.first?.title ?? repaired.title,
                progress: 0,
                chapterIndex: 0,
                chapterPageIndex: 0,
                chapterSourceURLString: repaired.chapters.first?.sourceURLString
            )
        } catch {
            catalogRepairError = error.localizedDescription
        }

        isRepairingCatalog = false
    }

    private func chapterCacheKey(_ chapter: NovelChapter) -> String {
        chapter.sourceURLString ?? chapter.id.uuidString
    }

    private func isChapterDownloaded(_ chapter: NovelChapter) -> Bool {
        guard chapter.sourceURLString != nil else { return false }

        let key = chapterCacheKey(chapter)
        return downloadedChapterKeys.contains(key)
            || loadedChapterOverrides[key] != nil
            || !chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private func refreshDownloadedChapterKeys() async {
        let cachedKeys = await ChapterContentCache.shared.cachedKeys(for: baseChapters)
        downloadedChapterKeys = cachedKeys.union(loadedChapterOverrides.keys)
    }

    private func readerTextSize(containerSize: CGSize, safeAreaInsets: EdgeInsets) -> CGSize {
        let footerHeight = footerTextHeight
        let footerSpacing: CGFloat = 8
        let width = max(containerSize.width - horizontalMargin * 2, 120)
        let height = max(
            containerSize.height
            - contentTopPadding(safeAreaInsets: safeAreaInsets)
            - contentBottomPadding(safeAreaInsets: safeAreaInsets)
            - footerHeight
            - footerSpacing,
            160
        )

        return CGSize(width: width, height: height)
    }

    private var footerTextHeight: CGFloat {
        let font = UIFont.systemFont(ofSize: 11, weight: .medium)
        return ceil(font.lineHeight)
    }

    nonisolated private static func paginate(
        content: String,
        textSize: CGSize,
        fontSize: CGFloat,
        lineSpacing: CGFloat
    ) -> [String] {
        var remaining = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if remaining.isEmpty { return [""] }

        let attributes = readerAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
        var result: [String] = []

        while !remaining.isEmpty {
            if Task.isCancelled { return [] }
            let splitIndex = fittingSplitIndex(in: remaining, textSize: textSize, attributes: attributes)
            let pageText = String(remaining[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(pageText.isEmpty ? String(remaining[..<splitIndex]) : pageText)
            remaining = String(remaining[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }

    nonisolated private static func fittingSplitIndex(
        in text: String,
        textSize: CGSize,
        attributes: [NSAttributedString.Key: Any]
    ) -> String.Index {
        guard !text.isEmpty else { return text.startIndex }

        let nsText = text as NSString
        let totalLength = nsText.length

        var lowerBound = 1
        var upperBound = totalLength
        var bestLength = 1

        while lowerBound <= upperBound {
            if Task.isCancelled { break }
            let midpoint = (lowerBound + upperBound) / 2
            let candidate = nsText.substring(to: midpoint)
            let candidateHeight = measuredHeight(candidate, width: textSize.width, attributes: attributes)

            if candidateHeight <= textSize.height + 0.5 {
                bestLength = midpoint
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint - 1
            }
        }

        guard bestLength < totalLength else {
            return text.endIndex
        }

        let nsRange = NSRange(location: 0, length: bestLength)
        return Range(nsRange, in: text)?.upperBound ?? text.index(after: text.startIndex)
    }

    nonisolated private static func measuredHeight(
        _ text: String,
        width: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let bounds = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        return ceil(bounds.height)
    }

    nonisolated private static func readerAttributes(
        fontSize: CGFloat,
        lineSpacing: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .justified
        paragraphStyle.baseWritingDirection = .leftToRight
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacing = lineSpacing * 1.25
        paragraphStyle.lineBreakMode = .byWordWrapping

        return [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle
        ]
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private struct ReaderPageItem: Identifiable {
    let chapterIndex: Int
    let pageIndex: Int
    let chapterPageCount: Int
    let chapterTitle: String
    let content: String

    var id: String {
        "\(chapterIndex)-\(pageIndex)"
    }
}

private struct JustifiedReaderText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let color: UIColor

    func makeUIView(context: Context) -> ReaderTextView {
        let textView = ReaderTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        textView.clipsToBounds = true
        textView.contentInset = .zero
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: ReaderTextView, context: Context) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .justified
        paragraphStyle.baseWritingDirection = .leftToRight
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacing = lineSpacing * 1.25
        paragraphStyle.lineBreakMode = .byWordWrapping

        textView.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
        )
        textView.updateContainerSize()
    }
}

private final class ReaderTextView: UITextView {
    override func layoutSubviews() {
        super.layoutSubviews()
        updateContainerSize()
    }

    func updateContainerSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard textContainer.size != bounds.size else { return }
        textContainer.size = bounds.size
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: attributedText.length), actualCharacterRange: nil)
    }
}

#Preview {
    NavigationStack {
        ReaderView(novel: MockData.novels[0])
    }
    .environmentObject(LibraryStore())
}
