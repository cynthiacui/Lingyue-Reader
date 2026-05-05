import SwiftUI
import Foundation
import UIKit

struct ReaderView: View {
    let novel: Novel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.appForcesColorScheme) private var appForcesColorScheme
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("reader.fontSize") private var fontSize = 18.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.theme") private var themeRawValue = ReadingTheme.paper.rawValue
    @AppStorage("reader.followSystemDark") private var followSystemDark = false
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false
    @AppStorage("reader.autoScroll") private var autoScroll = false
    @AppStorage("reader.autoScrollSeconds") private var autoScrollSeconds = 6.0
    @AppStorage("reader.cacheEnabled") private var cacheEnabled = true

    @State private var currentChapterIndex = 0
    @State private var currentChapterPageIndex = 0
    @State private var visiblePages: [ReaderPageItem] = []
    @State private var visiblePageSignature: String?
    @State private var showControls = false
    @State private var showChapterPicker = false
    @State private var showPreferences = false
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
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var browserDestination: URL?
    @State private var showSourceSwitcher = false
    private let paginationCacheCapacity = 24

    private var activeNovel: Novel {
        repairedNovel ?? novel
    }

    private var baseChapters: [NovelChapter] {
        if catalogNeedsRepair {
            let message = catalogRepairError.map { "目录修复失败：\($0)" } ?? "正在修复章节目录..."
            return [NovelChapter(title: activeNovel.title, content: message)]
        }

        return activeNovel.chapters
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
        ReadingTheme.effective(
            rawValue: themeRawValue,
            followSystemDark: followSystemDark,
            systemColorScheme: systemColorScheme,
            appForcesColorScheme: appForcesColorScheme
        )
    }

    /// Theme the user explicitly picked from the swatches — used to draw the "selected"
    /// highlight on the swatch even when follow-system has overridden the active theme.
    private var manualTheme: ReadingTheme {
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
                        .transition(ModalStyle.transition)
                }

                if showPreferences {
                    preferencesOverlay(safeBottom: proxy.safeAreaInsets.bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                setInitialChapterIfNeeded()
                persistReadingState(pages: pages)
                lastKnownTextSize = textSize
                if autoScroll { startAutoScroll() }
            }
            .onDisappear {
                stopAutoScroll()
            }
            .onChange(of: textSize) { _, newValue in
                if newValue.width > 0, newValue.height > 0 {
                    lastKnownTextSize = newValue
                }
            }
            .onChange(of: autoScroll) { _, newValue in
                if newValue {
                    startAutoScroll()
                } else {
                    stopAutoScroll()
                }
            }
            .onChange(of: autoScrollSeconds) { _, _ in
                if autoScroll { startAutoScroll() }
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
        .navigationDestination(item: $browserDestination) { url in
            InAppBrowserView(url: url, title: activeNovel.title)
        }
        .sheet(isPresented: $showSourceSwitcher) {
            BookSourceSwitcherSheet(
                novelTitle: activeNovel.title,
                currentSourceURLString: activeNovel.sourceURLString
            ) { url in
                showSourceSwitcher = false
                // Wait for the sheet's dismiss animation to finish before pushing
                // the in-app browser, otherwise SwiftUI drops the navigation push.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    browserDestination = url
                }
            }
        }
    }

    /// URL to open in the in-app browser when the user taps the globe icon. Falls
    /// back from the chapter's own source URL to the novel's catalog URL so the
    /// button still works while the chapter content URL is loading. Returns nil
    /// for locally-imported `.txt` books (sentinel scheme is not a real web page).
    private func chapterBrowserURL(for chapter: NovelChapter?) -> URL? {
        let candidates: [String?] = [chapter?.sourceURLString, activeNovel.sourceURLString]
        for candidate in candidates {
            guard let candidate,
                  let url = URL(string: candidate),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            return url
        }
        return nil
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
        let sourceLabel = BookSourceRegistry.displayName(for: activeNovel.sourceURLString)
        let chapterURL = chapterBrowserURL(for: currentChapter)

        return VStack {
            HStack(spacing: 0) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 64, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                VStack(spacing: 2) {
                    Text(currentPage.chapterTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(secondaryForeground)
                        .lineLimit(1)

                    if let sourceLabel {
                        Text(sourceLabel)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(secondaryForeground.opacity(0.65))
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showPreferences = true
                        showChapterPicker = false
                    }
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 40, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let chapterURL {
                    Button {
                        browserDestination = chapterURL
                    } label: {
                        Image(systemName: "globe")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 40, height: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("在浏览器中查看")
                }

                Button {
                    showSourceSwitcher = true
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换书源")

                Button {
                    withAnimation(ModalStyle.presentationAnimation) {
                        showChapterPicker = true
                        showPreferences = false
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(pageForeground)
            .padding(.horizontal, 8)
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

                HStack(spacing: 8) {
                    Button {
                        guard canGoPrevChapter else { return }
                        goToChapter(currentChapterIndex - 1, pageIndex: 0)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 64, height: 48)
                            .contentShape(Rectangle())
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
                            .frame(width: 64, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canGoNextChapter)
                    .opacity(canGoNextChapter ? 1 : 0.35)
                }
            }
            .foregroundStyle(pageForeground)
            .padding(.horizontal, 8)
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
        ModalContainer(
            dismissOnTapOutside: true,
            onDismiss: {
                withAnimation(ModalStyle.presentationAnimation) {
                    showChapterPicker = false
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("章节目录")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(pageForeground)

                    Spacer()

                    Button {
                        withAnimation(ModalStyle.presentationAnimation) {
                            showChapterPicker = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(secondaryForeground)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(chapters.indices, id: \.self) { index in
                                Button {
                                    goToChapter(index, pageIndex: 0)
                                    Task {
                                        await prepareChapter(at: index)
                                    }
                                    withAnimation(ModalStyle.presentationAnimation) {
                                        showChapterPicker = false
                                        showControls = false
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(displayed(chapters[index].title))
                                            .font(.system(size: 15, weight: currentPage.chapterIndex == index ? .bold : .regular))
                                            .lineLimit(1)

                                        if isChapterDownloaded(chapters[index]) {
                                            Image(systemName: "arrow.down.circle.fill")
                                                .font(.system(size: 12, weight: .semibold))
                                                .accessibilityLabel("已下载")
                                        }

                                        Spacer(minLength: 8)
                                    }
                                    .foregroundStyle(currentPage.chapterIndex == index ? Color.readerAccent : pageForeground)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 44)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(currentPage.chapterIndex == index ? Color.readerAccent.opacity(0.12) : Color.clear)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .frame(maxWidth: 360, maxHeight: 460, alignment: .topLeading)
            .background(currentTheme.surfaceBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
        }
    }

    private func preferencesOverlay(safeBottom: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(currentTheme == .night ? 0.35 : 0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showPreferences = false
                    }
                }

            VStack {
                Spacer()

                VStack(alignment: .leading, spacing: 16) {
                    preferenceStepperRow(
                        title: "字号",
                        value: $fontSize,
                        range: 12...32,
                        step: 1,
                        format: { "\(Int($0))" }
                    )

                    preferenceStepperRow(
                        title: "行距",
                        value: $lineSpacing,
                        range: 0...24,
                        step: 1,
                        format: { "\(Int($0))" }
                    )

                    preferenceThemeRow

                    HStack(spacing: 10) {
                        preferenceTogglePill(
                            label: "繁体",
                            systemImage: "character.book.closed",
                            isOn: $usesTraditionalChinese
                        )
                        preferenceTogglePill(
                            label: "滚读",
                            systemImage: "arrow.down.to.line.compact",
                            isOn: $autoScroll
                        )
                    }

                    if autoScroll {
                        preferenceStepperRow(
                            title: "停留",
                            value: $autoScrollSeconds,
                            range: 2...30,
                            step: 1,
                            format: { "\(Int($0))秒" }
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, max(safeBottom + 16, 22))
                .background(
                    Rectangle()
                        .fill(currentTheme.chromeBackground)
                        .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: -3)
                )
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func preferenceStepperRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondaryForeground)
                .frame(width: 36, alignment: .leading)

            Spacer(minLength: 0)

            CompactStepper(
                value: value,
                range: range,
                step: step,
                format: format,
                background: currentTheme.surfaceBackground,
                foreground: pageForeground,
                dividerColor: secondaryForeground.opacity(0.18)
            )
        }
    }

    private var preferenceThemeRow: some View {
        HStack(spacing: 12) {
            Text("背景")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondaryForeground)
                .frame(width: 36, alignment: .leading)

            HStack(spacing: 10) {
                ForEach(ReadingTheme.allCases) { theme in
                    let isSelected = theme == manualTheme
                    let isAutoManaged = followSystemDark && theme == .night
                    Button {
                        themeRawValue = theme.rawValue
                    } label: {
                        Circle()
                            .fill(theme.pageBackground)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        isSelected ? Color.readerAccent : Color.black.opacity(0.18),
                                        lineWidth: isSelected ? 2.5 : 1
                                    )
                            )
                            .overlay(alignment: .center) {
                                if isAutoManaged {
                                    Image(systemName: "circle.lefthalf.filled")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(theme.pageForeground)
                                } else if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(theme.pageForeground)
                                }
                            }
                            .opacity(isAutoManaged ? 0.55 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .disabled(isAutoManaged)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func preferenceTogglePill(label: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(isOn.wrappedValue ? Color.white : pageForeground)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOn.wrappedValue ? Color.readerAccent : currentTheme.surfaceBackground)
            )
        }
        .buttonStyle(.plain)
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
        // Resolve through loadedChapterOverrides so a chapter that was populated
        // by loadDiskCachedChapterImmediately (synchronous disk hit on chapter
        // switch) shows its content right away instead of flashing the
        // "正在加载章节内容..." placeholder before rebuildVisiblePagesIfNeeded
        // catches up.
        let rawChapter = baseChapters.indices.contains(chapterIndex) ? baseChapters[chapterIndex] : nil
        let chapter = rawChapter.map { loadedChapterOverrides[chapterCacheKey($0)] ?? $0 }
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
                showPreferences = false
            }
        }
    }

    private func hideControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls = false
            showChapterPicker = false
            showPreferences = false
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

    @MainActor
    private func startAutoScroll() {
        stopAutoScroll()
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled, autoScroll {
                let seconds = max(autoScrollSeconds, 1)
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, autoScroll else { return }
                // Pause whenever any overlay is showing — gives the user breathing room
                // to interact with controls without losing their place.
                if showControls || showChapterPicker || showPreferences { continue }
                advanceAutoScrollPage()
            }
        }
    }

    @MainActor
    private func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
    }

    @MainActor
    private func advanceAutoScrollPage() {
        let pages = activeVisiblePages()
        if currentChapterPageIndex < pages.count - 1 {
            withAnimation(.easeInOut(duration: 0.45)) {
                currentChapterPageIndex += 1
            }
        } else if currentChapterIndex < baseChapters.count - 1 {
            goToChapter(currentChapterIndex + 1, pageIndex: 0)
        } else {
            // Reached the end of the book — turn the toggle off so the task exits and the
            // user sees the preference reflected.
            autoScroll = false
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

        loadedChapterOverrides[key] = mergedOverride(loaded: cachedChapter, matching: chapter)
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

        // Last-chance synchronous disk hit. Async cache hydration
        // (loadCachedChapterIfAvailable) yields the actor before populating
        // loadedChapterOverrides, so a downloaded chapter would otherwise flash
        // the loading placeholder during the actor hop. Reading the JSON off
        // disk directly is fast enough to do inline on the render pass.
        if let cached = ChapterContentCache.diskCachedChapter(for: chapter),
           !cached.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cached.content
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
            loadedChapterOverrides[key] = mergedOverride(loaded: cachedChapter, matching: chapter)
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
                    let merged = mergedOverride(loaded: loadedChapter, matching: chapter)
                    await MainActor.run {
                        loadedChapterOverrides[key] = merged
                        downloadedChapterKeys.insert(key)
                        _ = prefetchingChapterKeys.remove(key)
                    }
                    await prePaginate(chapter: merged, originalChapter: chapter, chapterIndex: chapterIndex)
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
            loadedChapterOverrides[key] = mergedOverride(loaded: loadedChapter, matching: chapter)
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
            let existingCategory = libraryStore.categoryName(
                forBookWith: novel.sourceURLString,
                title: novel.title
            ) ?? LibraryStore.uncategorizedName
            libraryStore.addImportedNovel(repaired, categoryName: existingCategory)
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

    /// Some sources (e.g. 破万卷小说) prefix every chapter's parsed title with the book name,
    /// while the catalog/imported list shows just "第N章". Re-wrap the loaded chapter with
    /// the catalog row's title + id, and rewrite the leading title line in the content body
    /// so the rendered page header matches the catalog title (and the picker, and the
    /// reader's top/bottom chrome).
    private func mergedOverride(loaded: NovelChapter, matching catalog: NovelChapter) -> NovelChapter {
        NovelChapter(
            id: catalog.id,
            title: catalog.title,
            content: rewriteLeadingTitle(in: loaded.content, from: loaded.title, to: catalog.title),
            sourceURLString: loaded.sourceURLString ?? catalog.sourceURLString
        )
    }

    private func rewriteLeadingTitle(in content: String, from oldTitle: String, to newTitle: String) -> String {
        let trimmedOld = oldTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOld.isEmpty, trimmedOld != newTitle else { return content }

        let leadingWhitespace = content.prefix { $0.isWhitespace || $0.isNewline }
        let body = content.dropFirst(leadingWhitespace.count)
        guard body.hasPrefix(trimmedOld) else { return content }

        let remainder = body.dropFirst(trimmedOld.count)
        return String(leadingWhitespace) + newTitle + String(remainder)
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

/// Sheet that re-runs the Discovery aggregated search for the current book and lists every
/// known source for it. Tapping a row hands the URL back to the reader, which closes the
/// sheet and pushes the in-app browser — from there the existing detect-and-replace flow
/// updates the book in the library.
private struct BookSourceSwitcherSheet: View {
    let novelTitle: String
    let currentSourceURLString: String?
    let onSelectSource: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var candidates: [BookSourceCandidate] = []
    @State private var hasFinishedLoading = false
    @State private var streamTask: Task<Void, Never>?

    private var currentSourceName: String? {
        BookSourceRegistry.displayName(for: currentSourceURLString)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                if !hasFinishedLoading && candidates.isEmpty {
                    loadingView
                } else if hasFinishedLoading && candidates.isEmpty {
                    emptyView
                } else {
                    candidateList
                }
            }
            .navigationTitle("切换书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(theme.accent)
                }
            }
        }
        .task {
            await loadCandidates()
        }
        .onDisappear {
            streamTask?.cancel()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(theme.accent)
            Text("正在为《\(novelTitle)》搜索书源…")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Text("未找到其他书源")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
            Text("可以稍后再试，或在“发现”页直接搜索这本书。")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var candidateList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("《\(novelTitle)》")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 4)

                Text("点击书源即可在内置浏览器中打开对应章节页。在浏览器中确认导入后，灵阅会用新的书源替换当前书架记录。")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 4)

                VStack(spacing: 8) {
                    ForEach(candidates) { candidate in
                        candidateRow(candidate)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
    }

    private func candidateRow(_ candidate: BookSourceCandidate) -> some View {
        let isCurrent = currentSourceName == candidate.sourceName

        return Button {
            onSelectSource(candidate.url)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(candidate.sourceName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)

                        if isCurrent {
                            Text("当前")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(theme.accent.opacity(0.14))
                                )
                        }
                    }

                    Text(candidate.url.host(percentEncoded: false) ?? candidate.url.absoluteString)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isCurrent ? theme.accent.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func loadCandidates() async {
        streamTask?.cancel()
        candidates = []
        hasFinishedLoading = false

        let task = Task {
            for await batch in DiscoverySearchService.shared.sourceCandidatesStream(for: novelTitle) {
                if Task.isCancelled { return }
                await MainActor.run {
                    candidates = batch
                }
            }
            await MainActor.run {
                hasFinishedLoading = true
            }
        }
        streamTask = task
        await task.value
    }
}

