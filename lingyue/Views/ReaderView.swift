import SwiftUI
import Foundation
import UIKit
import NaturalLanguage

/// One row of the Reader first-launch help popup. Icon + short title +
/// one-line detail, mapped to a specific reader affordance so the icon
/// matches the actual toolbar button the user will look for.
private struct ReaderHelpItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

private let readerHelpItems: [ReaderHelpItem] = [
    ReaderHelpItem(icon: "hand.tap", title: "翻页方式", detail: "左右两侧轻点翻页 · 中央轻点呼出工具栏 · 横向滑动同样可翻页"),
    ReaderHelpItem(icon: "list.bullet", title: "章节目录", detail: "工具栏右侧的列表按钮可跨章节快速跳转"),
    ReaderHelpItem(icon: "textformat.size", title: "字号与排版", detail: "调节字号、行距、字体与翻页方式，可开启滚读"),
    ReaderHelpItem(icon: "sun.max", title: "亮度调节", detail: "太阳按钮独立调整屏幕亮度，不影响系统设置"),
    ReaderHelpItem(icon: "arrow.left.arrow.right", title: "切换书源", detail: "同一本书在不同源之间一键切换")
]

struct ReaderView: View {
    let novel: Novel

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryStore: LibraryStore
    /// Device's actual user-interface style, observed independently of any
    /// `.preferredColorScheme(...)` override the app theme applies. Drives the
    /// reader's follow-system-dark logic so 夜读 auto-activates from the OS
    /// setting regardless of which app theme is selected.
    @StateObject private var systemAppearance = SystemAppearance()
    /// Live window safe-area insets, read from the active key window. Used to clear the
    /// landscape Dynamic Island / notch / iPad rounded-corner safe area, which the
    /// outer `.ignoresSafeArea()` zeroes out of `proxy.safeAreaInsets`.
    @StateObject private var windowInsets = WindowSafeAreaInsets()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("reader.fontSize") private var fontSize = 18.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    /// Paragraph-spacing multiplier expressed as a fraction of the rendered font's size
    /// (≈ line height). 0 collapses paragraphs to back-to-back, 1.5 is loose; 0.5 is the
    /// modern default and replaces the previous `lineSpacing * 1.25` rule, which produced
    /// visibly wide paragraph gaps.
    @AppStorage("reader.paragraphSpacing") private var paragraphSpacingMultiplier: Double = 0.5
    @AppStorage("reader.fontFamily") private var fontFamilyRaw = ReaderFontFamily.system.rawValue
    @AppStorage("reader.pageTransition") private var pageTransitionRaw = PageTransitionStyle.instant.rawValue
    @AppStorage("reader.twoColumn") private var twoColumnLayout = false
    @AppStorage("reader.theme") private var themeRawValue = ReadingTheme.paper.rawValue
    @AppStorage("reader.followSystemDark") private var followSystemDark = false
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false
    @AppStorage("reader.autoScroll") private var autoScroll = false
    @AppStorage("reader.autoScrollSeconds") private var autoScrollSeconds = 6.0
    @AppStorage("reader.cacheEnabled") private var cacheEnabled = true
    /// One-shot onboarding flag for the in-reader help popup. Flipped to
    /// `true` the first time the user dismisses the overlay; persists across
    /// launches so the popup never reappears after the first read.
    @AppStorage("reader.hasSeenHelpOverlay") private var hasSeenReaderHelpOverlay = false

    @State private var currentChapterIndex = 0
    @State private var currentChapterPageIndex = 0
    @State private var visiblePages: [ReaderPageItem] = []
    @State private var visiblePageSignature: String?
    @State private var showControls = false
    @State private var showChapterPicker = false
    @State private var showPreferences = false
    /// Brightness popup, presented from its own top-bar button next to AA. Mutually
    /// exclusive with `showPreferences` and `showChapterPicker` — opening any one closes
    /// the others.
    @State private var showBrightness = false
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
    /// Most recent container size observed by the body. Used by `useTwoColumn` and by tap-zone /
    /// auto-scroll code that runs outside a render pass and otherwise has no access to the
    /// container width. Zero until the first GeometryReader pass settles.
    @State private var lastContainerSize: CGSize = .zero
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var browserDestination: URL?
    @State private var showSourceSwitcher = false
    /// Live downward drag distance on the preferences popup. The popup follows the finger
    /// (resisted slightly upward) and either snaps back or dismisses depending on the
    /// drag's projected end position — same feel as a sheet's dismiss-on-drag.
    @State private var preferencesDragOffset: CGFloat = 0
    /// Live downward drag distance on the brightness popup. Parallel to
    /// `preferencesDragOffset` — kept separate so each popup's dismiss animation has its
    /// own state and there's no risk of one popup inheriting a stale offset from the other.
    @State private var brightnessDragOffset: CGFloat = 0
    /// Mirrors `UIScreen.main.brightness` for the preferences-overlay brightness slider.
    /// Initialized to the current device brightness when the reader opens and refreshed
    /// every time the preferences overlay is shown — Control Center / external changes
    /// while the overlay is closed are picked up on the next open. We don't persist this
    /// to AppStorage; the system reclaims brightness on background, matching how Apple
    /// Books behaves.
    @State private var brightnessLevel: Double = Double(UIScreen.main.brightness)
    /// Bumps after a rotation so the pager rebuilds with the post-rotation safeArea
    /// settled. SwiftUI's GeometryReader sometimes reports stale `safeAreaInsets` on the first
    /// render after rotation when its parent uses `.ignoresSafeArea()`, so the previously-visible
    /// page renders with the wrong top padding until the next state change kicks a re-render.
    @State private var rotationLayoutVersion = 0
    /// Max-seen safe-area top/bottom insets. Toggling `.statusBarHidden(!showControls)`
    /// shrinks `safeAreaInsets.top` on devices where the status bar contributes to the
    /// inset (older iPhones, iPad in some configs), which would otherwise reflow the page
    /// content by a few points on every controls-toggle. Stabilizing against the maximum
    /// observed inset matches how Apple Books / Kindle hold their text steady while the
    /// system bar fades in and out.
    @State private var stableSafeAreaTop: CGFloat
    @State private var stableSafeAreaBottom: CGFloat
    /// Page index at the moment a slide/pageCurl drag begins, so we know whether the user
    /// started the swipe at a chapter boundary. By `.onEnded` time UIPageViewController may
    /// have already committed an in-chapter turn and mutated `currentChapterPageIndex`.
    @State private var boundarySwipeStartPageIndex: Int?
    private let paginationCacheCapacity = 24

    init(novel: Novel) {
        self.novel = novel
        // Seed stabilized insets from the active key window *before* the first body
        // evaluation. The previous screen's status bar is still visible at this moment,
        // so the window's `safeAreaInsets` reflect the with-status-bar maximum — the
        // value pagination should lock onto. Without this, first render would compute
        // textSize against `proxy.safeAreaInsets = 0`, then re-paginate a frame later
        // once the inset settled, causing a visible content shift.
        let insets = Self.currentKeyWindowSafeAreaInsets()
        _stableSafeAreaTop = State(initialValue: insets.top)
        _stableSafeAreaBottom = State(initialValue: insets.bottom)
    }

    private static func currentKeyWindowSafeAreaInsets() -> UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })
            ?? scenes.first?.windows.first
        return window?.safeAreaInsets ?? .zero
    }

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

    /// Snapshot of "where the user is" for the diagnostics log. Reads from the
    /// reader's @State, so callers must be on the main actor.
    private var diagnosticsSnapshot: ReaderStateSnapshot {
        ReaderStateSnapshot(
            novelID: activeNovel.id,
            novelTitle: activeNovel.title,
            chapterIndex: currentChapterIndex,
            totalChapters: baseChapters.count,
            chapterTitle: currentChapter.map { displayed($0.title) } ?? "",
            pageIndex: currentChapterPageIndex,
            totalPages: visiblePages.count,
            pageSignature: visiblePageSignature
        )
    }

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 16 }
        return horizontalSizeClass == .compact ? 20 : 36
    }

    private var currentTheme: ReadingTheme {
        ReadingTheme.effective(
            rawValue: themeRawValue,
            followSystemDark: followSystemDark,
            deviceIsInDarkMode: systemAppearance.isDark
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

    private var readerFontFamily: ReaderFontFamily {
        ReaderFontFamily(rawValue: fontFamilyRaw) ?? .system
    }

    /// Normalizing binding for the in-reader font picker — a stale stored value (e.g. an old
    /// case that no longer exists) resolves to `.system` so the menu always shows a checkmark.
    private var fontFamilyBinding: Binding<String> {
        Binding(
            get: { readerFontFamily.rawValue },
            set: { fontFamilyRaw = $0 }
        )
    }

    private var pageTransitionStyle: PageTransitionStyle {
        PageTransitionStyle(rawValue: pageTransitionRaw) ?? .instant
    }

    /// Slider-friendly Binding that writes through to `UIScreen.main.brightness` on every
    /// drag tick. Keeps `brightnessLevel` in sync so the slider thumb tracks the finger.
    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { brightnessLevel },
            set: { newValue in
                brightnessLevel = newValue
                UIScreen.main.brightness = CGFloat(newValue)
            }
        )
    }

    /// Two-column landscape spread is only meaningful when the container is actually wider
    /// than it is tall — on phones in portrait, two narrow columns are worse than one. Gate
    /// strictly on the observed container size so the user can leave the setting on and have
    /// it automatically engage in landscape on any device.
    private var useTwoColumn: Bool {
        twoColumnLayout
            && lastContainerSize.width > lastContainerSize.height
            && lastContainerSize.width > 0
    }

    /// Horizontal space between the two columns in a spread. Matches `horizontalMargin` so the
    /// gap between columns reads the same weight as the outer page margins.
    private var twoColumnGutter: CGFloat { 32 }

    private var pageTransitionBinding: Binding<String> {
        Binding(
            get: { pageTransitionStyle.rawValue },
            set: { pageTransitionRaw = $0 }
        )
    }

    var body: some View {
        GeometryReader { proxy in
            // Pin the insets we feed into layout to the maximum value we've observed so
            // far. The page text reads against `stableInsets`, so toggling the system
            // status bar (which mutates `proxy.safeAreaInsets.top` on non-notched devices)
            // never reflows the body. Chrome that visually tracks the status bar — the
            // controls top bar, the readerHeader, the bottom bar — also reads the stable
            // value, so they sit where the status bar would be even when it's hidden.
            let stableTop = max(stableSafeAreaTop, proxy.safeAreaInsets.top)
            let stableBottom = max(stableSafeAreaBottom, proxy.safeAreaInsets.bottom)
            // Pull horizontal insets from the live key window (see WindowSafeAreaInsets).
            // proxy.safeAreaInsets reads as 0 here because the outer .ignoresSafeArea()
            // already consumed the safe area, so it cannot be used to clear the landscape
            // Dynamic Island / notch.
            let stableInsets = EdgeInsets(
                top: stableTop,
                leading: windowInsets.insets.left,
                bottom: stableBottom,
                trailing: windowInsets.insets.right
            )
            let textSize = readerTextSize(containerSize: proxy.size, safeAreaInsets: stableInsets)
            let pages = activeVisiblePages()
            let currentPage = currentPage(in: pages)
            let pageSignature = paginationSignature(textSize: textSize)

            ZStack {
                pageBackground.ignoresSafeArea()

                // The page renderer branches on the user's pageTransition setting. All three
                // paths share `pageView(...)` for the page itself — only the container differs.
                // rotationLayoutVersion forces a re-render after rotation so GeometryReader's
                // safeAreaInsets settle.
                switch pageTransitionStyle {
                case .instant:
                    instantPageContent(
                        currentPage: currentPage,
                        pages: pages,
                        textSize: textSize,
                        safeAreaInsets: stableInsets,
                        containerSize: proxy.size
                    )
                case .slide:
                    slidePageContent(
                        pages: pages,
                        textSize: textSize,
                        safeAreaInsets: stableInsets,
                        containerSize: proxy.size
                    )
                case .pageCurl:
                    pageCurlPageContent(
                        pages: pages,
                        textSize: textSize,
                        safeAreaInsets: stableInsets,
                        containerSize: proxy.size
                    )
                }

                if showControls {
                    controlsTopBar(
                        safeTop: stableTop,
                        safeLeading: stableInsets.leading,
                        safeTrailing: stableInsets.trailing,
                        currentPage: currentPage
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))

                    controlsBottomBar(
                        safeBottom: stableBottom,
                        safeLeading: stableInsets.leading,
                        safeTrailing: stableInsets.trailing,
                        pages: pages,
                        currentPage: currentPage
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if !showControls {
                    readerHeader(
                        safeTop: stableTop,
                        safeLeading: stableInsets.leading,
                        safeTrailing: stableInsets.trailing
                    )
                    .transition(.opacity)
                }

                if showChapterPicker {
                    chapterPickerOverlay(pages: pages, currentPage: currentPage)
                        .transition(ModalStyle.transition)
                }

                if showPreferences {
                    preferencesOverlay(
                        safeBottom: stableBottom,
                        safeLeading: stableInsets.leading,
                        safeTrailing: stableInsets.trailing
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if showBrightness {
                    brightnessOverlay(
                        safeBottom: stableBottom,
                        safeLeading: stableInsets.leading,
                        safeTrailing: stableInsets.trailing
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // First-launch help popup. Sits at the top of the ZStack so its
                // dim scrim covers every reader chrome layer, and its own gesture
                // swallows taps so the user can't accidentally page-turn while
                // the introduction is up.
                if !hasSeenReaderHelpOverlay {
                    ReaderHelpPopup(onDismiss: dismissReaderHelpOverlay)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.28), value: hasSeenReaderHelpOverlay)
            .onAppear {
                ratchetStableSafeAreaInsets(top: proxy.safeAreaInsets.top,
                                            bottom: proxy.safeAreaInsets.bottom)
                lastContainerSize = proxy.size
                setInitialChapterIfNeeded(textSize: textSize)
                lastKnownTextSize = textSize
                if autoScroll { startAutoScroll() }
                // Side effects that mutate libraryStore propagate
                // objectWillChange through every tab that observes it as an
                // EnvironmentObject — invalidating LibraryView, Stats, and Me
                // mid-transition. Hop those (and diagnostics file I/O) one
                // runloop later so the navigation-push frame ships first.
                let initialPages = pages
                let novelTitle = activeNovel.title
                let initialChapter = currentChapterIndex
                let chapterCount = baseChapters.count
                let initialPage = currentChapterPageIndex
                let initialTextSize = textSize
                let snapshot = diagnosticsSnapshot
                DispatchQueue.main.async {
                    startReadingStatsSession(pages: initialPages)
                    persistReadingState(pages: initialPages)
                    ReaderDiagnostics.shared.log(.lifecycle, "ReaderView onAppear", context: [
                        "novel": novelTitle,
                        "ch": String(initialChapter),
                        "chCount": String(chapterCount),
                        "page": String(initialPage),
                        "textSize": "\(Int(initialTextSize.width))x\(Int(initialTextSize.height))"
                    ])
                    ReaderDiagnostics.shared.snapshot(snapshot)
                }
            }
            .onChange(of: proxy.safeAreaInsets.top) { _, newValue in
                ratchetStableSafeAreaInsets(top: newValue, bottom: nil)
            }
            .onChange(of: proxy.safeAreaInsets.bottom) { _, newValue in
                ratchetStableSafeAreaInsets(top: nil, bottom: newValue)
            }
            .onDisappear {
                ReaderDiagnostics.shared.log(.lifecycle, "ReaderView onDisappear", context: [
                    "ch": String(currentChapterIndex),
                    "page": String(currentChapterPageIndex)
                ])
                ReaderDiagnostics.shared.flushNow()
                persistReadingState(pages: pages, force: true)
                stopAutoScroll()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase != .active else { return }
                ReaderDiagnostics.shared.log(.lifecycle, "scenePhase change", context: [
                    "phase": String(describing: newPhase),
                    "ch": String(currentChapterIndex),
                    "page": String(currentChapterPageIndex)
                ])
                persistReadingState(pages: pages, force: true)
                if newPhase == .background {
                    Task { await libraryStore.flush() }
                }
            }
            .onChange(of: textSize) { _, newValue in
                if newValue.width > 0, newValue.height > 0 {
                    lastKnownTextSize = newValue
                }
            }
            .onChange(of: verticalSizeClass) { _, _ in
                // Defer to the next runloop tick so SwiftUI has finished propagating the new
                // safeAreaInsets through GeometryReader before we rebuild the pager. Without
                // the dispatch the rebuild reads the same stale insets we're trying to escape.
                resetStableSafeAreaInsetsForOrientationChange()
                windowInsets.refresh()
                lastContainerSize = proxy.size
                DispatchQueue.main.async {
                    windowInsets.refresh()
                    rotationLayoutVersion &+= 1
                }
            }
            .onChange(of: horizontalSizeClass) { _, _ in
                resetStableSafeAreaInsetsForOrientationChange()
                windowInsets.refresh()
                lastContainerSize = proxy.size
                DispatchQueue.main.async {
                    windowInsets.refresh()
                    rotationLayoutVersion &+= 1
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
        .background(TabBarVisibility(isHidden: true).frame(width: 0, height: 0))
        // Mirror Apple Books / Kindle: the system status bar fades back in with the
        // reveal of the top/bottom controls, and our custom `readerHeader` covers
        // immersive mode when controls are hidden. The page layout is stabilized
        // against the maximum safe-area inset (see `stableSafeAreaTop/Bottom`), so
        // toggling the status bar never reflows the body.
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
        // Vertically center the time row with the Dynamic Island / status bar pill.
        // iPhone 15 Pro safeTop≈59 → 27pt (≈ island vertical center); iPhone SE
        // safeTop≈20 → 12pt floor; iPad safeTop≈24 → 12pt floor.
        max(safeTop - 32, 12)
    }

    /// Reset stabilized insets to the current key window's values so a portrait → landscape
    /// flip doesn't carry the portrait notch height into landscape (or vice versa). The
    /// existing ratchet handlers will then bump the values back up if the new orientation's
    /// status bar is currently visible and contributes more.
    private func resetStableSafeAreaInsetsForOrientationChange() {
        let insets = Self.currentKeyWindowSafeAreaInsets()
        stableSafeAreaTop = insets.top
        stableSafeAreaBottom = insets.bottom
    }

    /// Update the cached stable insets if a fresh observation exceeds them. Pass `nil`
    /// for an axis you don't want to update on this call.
    private func ratchetStableSafeAreaInsets(top: CGFloat?, bottom: CGFloat?) {
        if let top, top > stableSafeAreaTop { stableSafeAreaTop = top }
        if let bottom, bottom > stableSafeAreaBottom { stableSafeAreaBottom = bottom }
    }

    private func contentTopPadding(safeAreaInsets: EdgeInsets) -> CGFloat {
        // Body starts just past the safe-area inset so the Dynamic Island / status bar
        // doesn't overlap glyphs. The time row above already sits closer to the screen
        // edge — this is the gap between body text and that row.
        let gapBelowHeader: CGFloat = dynamicTypeSize.isAccessibilitySize ? 18 : 0
        let minimum: CGFloat = dynamicTypeSize.isAccessibilitySize ? 56 : 36
        return max(safeAreaInsets.top + gapBelowHeader, minimum)
    }

    private func contentBottomPadding(safeAreaInsets: EdgeInsets) -> CGFloat {
        // Footer (chapter title + page index) tucks alongside the home-indicator inset
        // — sits ~safeBottom-6pt up so the row clears the indicator gesture line by
        // ~20pt without floating high above it. iPhone 15 Pro safeBottom≈34 → 28pt;
        // iPhone SE safeBottom=0 → 18pt floor; iPad safeBottom≈20 → 20pt.
        let minimum: CGFloat = dynamicTypeSize.isAccessibilitySize ? 30 : 18
        let extra: CGFloat = dynamicTypeSize.isAccessibilitySize ? 6 : -6
        return max(safeAreaInsets.bottom + extra, minimum)
    }

    private func controlsTopPadding(safeTop: CGFloat) -> CGFloat {
        max(safeTop + 8, 52)
    }

    /// In a two-column spread, the column on the left of the gutter, the column on the right,
    /// or — when not in two-column mode — a single full-width column that uses both outer
    /// margins. The padding rules per side are computed in `pageView`.
    private enum PageColumnSide { case full, left, right }

    private func pageView(
        for page: ReaderPageItem,
        safeAreaInsets: EdgeInsets,
        textSize: CGSize,
        columnSide: PageColumnSide = .full
    ) -> some View {
        let halfGutter = twoColumnGutter / 2
        let leadingPadding: CGFloat = {
            switch columnSide {
            case .full, .left: return max(horizontalMargin, safeAreaInsets.leading)
            case .right:       return halfGutter
            }
        }()
        let trailingPadding: CGFloat = {
            switch columnSide {
            case .full, .right: return max(horizontalMargin, safeAreaInsets.trailing)
            case .left:         return halfGutter
            }
        }()

        return VStack(alignment: .leading, spacing: 8) {
            JustifiedReaderText(
                text: page.content,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                paragraphSpacing: paragraphSpacingMultiplier,
                fontFamily: readerFontFamily,
                color: UIColor(pageForeground),
                onLookup: { term in ReaderDictionary.present(term: term) }
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
        // Landscape: the Dynamic Island / notch lives on one horizontal edge, so
        // safeAreaInsets.leading or .trailing reports ~50pt. Pad the body away from
        // that edge by at least the inset so glyphs never slide under the cutout.
        // In two-column mode, the inner edge of each column uses half the gutter
        // instead of a full outer margin so the two columns sit close to the center.
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        .padding(.top, contentTopPadding(safeAreaInsets: safeAreaInsets))
        .padding(.bottom, contentBottomPadding(safeAreaInsets: safeAreaInsets))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Renders one two-column spread: the page at `currentChapterPageIndex` on the left and
    /// the next page on the right. When the chapter has an odd page count the trailing right
    /// column is left empty so the last spread's geometry stays consistent with the others.
    private func spreadView(
        leftPage: ReaderPageItem,
        rightPage: ReaderPageItem?,
        safeAreaInsets: EdgeInsets,
        textSize: CGSize
    ) -> some View {
        HStack(spacing: 0) {
            pageView(for: leftPage,
                     safeAreaInsets: safeAreaInsets,
                     textSize: textSize,
                     columnSide: .left)
                .frame(maxWidth: .infinity)

            if let rightPage {
                pageView(for: rightPage,
                         safeAreaInsets: safeAreaInsets,
                         textSize: textSize,
                         columnSide: .right)
                    .frame(maxWidth: .infinity)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .padding(.leading, twoColumnGutter / 2)
                    .padding(.trailing, max(horizontalMargin, safeAreaInsets.trailing))
            }
        }
    }

    /// Discrete swipe-to-turn handler. Uses `predictedEndTranslation` so a quick flick is
    /// recognized even when the actual finger travel is short — the page only changes on
    /// release, never during the drag, which avoids the "follow-finger" sliding effect.
    private func handleReaderSwipe(translation: CGSize, predictedEnd: CGSize, pages: [ReaderPageItem]) {
        // Ignore drags that are clearly vertical (e.g., the user is just resting a finger
        // and shifting it slightly downward). Horizontal motion has to dominate.
        guard abs(predictedEnd.width) > abs(predictedEnd.height) else { return }

        let threshold: CGFloat = 50
        let effective = abs(predictedEnd.width) >= threshold ? predictedEnd.width : translation.width
        guard abs(effective) >= threshold else { return }

        // A real swipe — if any overlay is up, dismiss it as part of turning the page so
        // the user gets the bar out of the way without a separate tap.
        if showControls || showChapterPicker || showPreferences || showBrightness {
            hideControls()
        }

        if effective < 0 {
            goToNextPage(pages: pages)
        } else {
            goToPreviousPage(pages: pages)
        }
    }

    /// Parallel drag gesture used in slide/pageCurl modes. UIPageViewController only knows
    /// about the current chapter's pages (its dataSource returns nil at either end); this
    /// catches boundary swipes and routes them to `goToChapter` so the user can swipe through
    /// to the previous/next chapter (instant transition — V1 doesn't animate across chapters).
    private func boundarySwipeGesture(pages: [ReaderPageItem]) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { _ in
                if boundarySwipeStartPageIndex == nil {
                    boundarySwipeStartPageIndex = currentChapterPageIndex
                }
            }
            .onEnded { value in
                let startIndex = boundarySwipeStartPageIndex ?? currentChapterPageIndex
                boundarySwipeStartPageIndex = nil
                handleBoundarySwipe(
                    startPageIndex: startIndex,
                    pageCount: pages.count,
                    translation: value.translation,
                    predictedEnd: value.predictedEndTranslation
                )
            }
    }

    private func handleBoundarySwipe(
        startPageIndex: Int,
        pageCount: Int,
        translation: CGSize,
        predictedEnd: CGSize
    ) {
        guard abs(predictedEnd.width) > abs(predictedEnd.height) else { return }

        let threshold: CGFloat = 60
        let effective = abs(predictedEnd.width) >= threshold ? predictedEnd.width : translation.width
        guard abs(effective) >= threshold else { return }

        // In two-column mode the pager has spread-count items, not page-count items. A swipe
        // at the last spread starts on a page that's >= 2 less than the total (or == pageCount-1
        // when the chapter has an odd page count and the last spread's right column is blank).
        let atFirstPage: Bool
        let atLastPage: Bool
        if useTwoColumn {
            atFirstPage = startPageIndex < 2
            let spreadCount = (pageCount + 1) / 2
            let lastSpreadStart = max((spreadCount - 1) * 2, 0)
            atLastPage = startPageIndex >= lastSpreadStart
        } else {
            atFirstPage = startPageIndex == 0
            atLastPage = startPageIndex >= pageCount - 1
        }
        let overlayVisible = showControls || showChapterPicker || showPreferences || showBrightness

        if effective < 0, atLastPage, currentChapterIndex < baseChapters.count - 1 {
            if overlayVisible { hideControls() }
            goToChapter(currentChapterIndex + 1, pageIndex: 0)
        } else if effective > 0, atFirstPage, currentChapterIndex > 0 {
            if overlayVisible { hideControls() }
            goToChapter(currentChapterIndex - 1, pageIndex: 0, landOnLastPage: true)
        } else if overlayVisible {
            // Within-chapter swipe: the pager already turned the page through the binding.
            // We just dismiss the overlay so the bar gets out of the user's way.
            hideControls()
        }
    }

    /// Routes a reader-area tap to the matching action based on horizontal position. Apple
    /// Books-style: left ~30% turns back, right ~30% turns forward, middle toggles controls.
    private func handleReaderTap(at location: CGPoint, in size: CGSize, pages: [ReaderPageItem]) {
        // While any overlay (controls / chapter picker / preferences) is visible, treat any
        // tap as "dismiss overlay" so the user can't accidentally turn pages while interacting
        // with the chrome.
        if showControls || showChapterPicker || showPreferences || showBrightness {
            hideControls()
            return
        }

        let width = max(size.width, 1)
        let x = location.x

        if x < width * 0.32 {
            goToPreviousPage(pages: pages)
        } else if x > width * 0.68 {
            goToNextPage(pages: pages)
        } else {
            toggleControls()
        }
    }

    /// Discrete page-swap renderer (current behavior). The page replaces in place when the
    /// user crosses the swipe threshold or taps an edge — no follow-finger motion.
    private func instantPageContent(
        currentPage: ReaderPageItem,
        pages: [ReaderPageItem],
        textSize: CGSize,
        safeAreaInsets: EdgeInsets,
        containerSize: CGSize
    ) -> some View {
        let pageBody: AnyView = {
            if useTwoColumn(containerSize: containerSize) {
                let leftIndex = currentChapterPageIndex - (currentChapterPageIndex % 2)
                let leftPage = pages.indices.contains(leftIndex) ? pages[leftIndex] : currentPage
                let rightIndex = leftIndex + 1
                let rightPage = pages.indices.contains(rightIndex) ? pages[rightIndex] : nil
                return AnyView(
                    spreadView(leftPage: leftPage,
                               rightPage: rightPage,
                               safeAreaInsets: safeAreaInsets,
                               textSize: textSize)
                )
            }
            return AnyView(
                pageView(for: currentPage, safeAreaInsets: safeAreaInsets, textSize: textSize)
            )
        }()

        return pageBody
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .id("\(currentChapterIndex)-\(currentChapterPageIndex)-\(rotationLayoutVersion)")
            .ignoresSafeArea()
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        handleReaderSwipe(translation: value.translation,
                                          predictedEnd: value.predictedEndTranslation,
                                          pages: pages)
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .onEnded { event in
                        handleReaderTap(at: event.location, in: containerSize, pages: pages)
                    }
            )
    }

    /// Same shape as the computed `useTwoColumn`, but reads container size from a direct
    /// argument. Render passes always know the current container; the stored
    /// `lastContainerSize` exists for navigation helpers that run outside a render frame.
    private func useTwoColumn(containerSize: CGSize) -> Bool {
        twoColumnLayout
            && containerSize.width > containerSize.height
            && containerSize.width > 0
    }

    /// Follow-finger horizontal slide via UIPageViewController(.scroll). Used to be a
    /// SwiftUI TabView(.page), but TabView wrote its post-bounce selection to the binding
    /// asynchronously — racing with `boundarySwipeGesture.onEnded` and stranding the user
    /// in the middle of the next chapter when they swiped at a chapter boundary.
    /// UIPageViewController returns nil from `viewControllerAfter` at the last page, so a
    /// boundary swipe rubber-bands without ever writing a binding value, and goToChapter
    /// is the only path that mutates currentChapterPageIndex on the boundary.
    private func slidePageContent(
        pages: [ReaderPageItem],
        textSize: CGSize,
        safeAreaInsets: EdgeInsets,
        containerSize: CGSize
    ) -> some View {
        kitPagerContent(
            transitionStyle: .scroll,
            pages: pages,
            textSize: textSize,
            safeAreaInsets: safeAreaInsets,
            containerSize: containerSize
        )
    }

    /// Real-book curl via UIPageViewController(.pageCurl). Same shape as slide mode — only
    /// the transition style differs.
    private func pageCurlPageContent(
        pages: [ReaderPageItem],
        textSize: CGSize,
        safeAreaInsets: EdgeInsets,
        containerSize: CGSize
    ) -> some View {
        kitPagerContent(
            transitionStyle: .pageCurl,
            pages: pages,
            textSize: textSize,
            safeAreaInsets: safeAreaInsets,
            containerSize: containerSize
        )
    }

    private func kitPagerContent(
        transitionStyle: UIPageViewController.TransitionStyle,
        pages: [ReaderPageItem],
        textSize: CGSize,
        safeAreaInsets: EdgeInsets,
        containerSize: CGSize
    ) -> some View {
        let usingTwoColumn = useTwoColumn(containerSize: containerSize)
        let pagerCount = usingTwoColumn ? (pages.count + 1) / 2 : pages.count
        let pagerBinding: Binding<Int> = usingTwoColumn
            ? Binding(
                get: { currentChapterPageIndex / 2 },
                set: { newSpread in currentChapterPageIndex = newSpread * 2 }
            )
            : $currentChapterPageIndex

        return PageCurlPager(
            transitionStyle: transitionStyle,
            pageCount: pagerCount,
            currentIndex: pagerBinding,
            backgroundColor: UIColor(pageBackground),
            renderPage: { [pages] index in
                if usingTwoColumn {
                    let leftIdx = index * 2
                    let rightIdx = leftIdx + 1
                    guard let leftPage = pages.indices.contains(leftIdx) ? pages[leftIdx] : pages.last else {
                        return AnyView(self.pageBackground.ignoresSafeArea())
                    }
                    let rightPage = pages.indices.contains(rightIdx) ? pages[rightIdx] : nil
                    return AnyView(
                        spreadView(leftPage: leftPage,
                                   rightPage: rightPage,
                                   safeAreaInsets: safeAreaInsets,
                                   textSize: textSize)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(self.pageBackground)
                    )
                }
                guard let page = pages.indices.contains(index) ? pages[index] : pages.last else {
                    return AnyView(self.pageBackground.ignoresSafeArea())
                }
                return AnyView(
                    pageView(for: page, safeAreaInsets: safeAreaInsets, textSize: textSize)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(self.pageBackground)
                )
            }
        )
        .ignoresSafeArea()
        .id("\(currentChapterIndex)-\(rotationLayoutVersion)-\(usingTwoColumn ? "2" : "1")")
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .local)
                .onEnded { event in
                    handleReaderTap(at: event.location, in: containerSize, pages: pages)
                }
        )
        .simultaneousGesture(boundarySwipeGesture(pages: pages))
    }

    private func readerHeader(safeTop: CGFloat, safeLeading: CGFloat, safeTrailing: CGFloat) -> some View {
        VStack {
            HStack(alignment: .center, spacing: 14) {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    Text(timeString(from: timeline.date))
                        .monospacedDigit()
                }
                .frame(alignment: .leading)

                Spacer()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(secondaryForeground)
            .frame(maxWidth: .infinity)
            .padding(.leading, max(horizontalMargin, safeLeading))
            .padding(.trailing, max(horizontalMargin, safeTrailing))
            .padding(.top, headerTopPadding(safeTop: safeTop))

            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func controlsTopBar(
        safeTop: CGFloat,
        safeLeading: CGFloat,
        safeTrailing: CGFloat,
        currentPage: ReaderPageItem
    ) -> some View {
        let chapterURL = chapterBrowserURL(for: currentChapter)

        // Layer the chapter title over the button row so it sits at the actual
        // midpoint of the screen instead of the midpoint of the gap between the
        // (wider) left group and the (narrower) right group. titleSidePadding
        // clamps the label so it can never get closer than `minGap` to either
        // button group, and middle-truncates when it would otherwise overlap.
        let backWidth: CGFloat = 52
        let globeWidth: CGFloat = chapterURL != nil ? 40 : 0
        let switcherWidth: CGFloat = 40
        let brightnessWidth: CGFloat = 44
        let fontWidth: CGFloat = 44
        let listWidth: CGFloat = 52
        let leftGroupWidth = backWidth + globeWidth + switcherWidth
        let rightGroupWidth = brightnessWidth + fontWidth + listWidth
        let minGap: CGFloat = 12
        let titleSidePadding = max(leftGroupWidth, rightGroupWidth) + minGap

        return VStack {
            VStack(spacing: 0) {
                // Row 1 — Book title. Full bar width, centered, semibold so it reads
                // as the primary identifier; truncates middle for long titles.
                Text(displayed(activeNovel.title))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(pageForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)

                // Row 2 — Button row with chapter title overlaid in the center.
                ZStack {
                    HStack(spacing: 0) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 19, weight: .semibold))
                                .frame(width: backWidth, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if let chapterURL {
                            Button {
                                browserDestination = chapterURL
                            } label: {
                                Image(systemName: "globe")
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: globeWidth, height: 44)
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
                                .frame(width: switcherWidth, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("切换书源")

                        Spacer()

                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showBrightness = true
                                showPreferences = false
                                showChapterPicker = false
                            }
                        } label: {
                            Image(systemName: "sun.max")
                                .font(.system(size: 19, weight: .semibold))
                                .frame(width: brightnessWidth, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("亮度")

                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showPreferences = true
                                showBrightness = false
                                showChapterPicker = false
                            }
                        } label: {
                            Image(systemName: "textformat.size")
                                .font(.system(size: 19, weight: .semibold))
                                .frame(width: fontWidth, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            withAnimation(ModalStyle.presentationAnimation) {
                                showChapterPicker = true
                                showPreferences = false
                                showBrightness = false
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 19, weight: .semibold))
                                .frame(width: listWidth, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Text(currentPage.chapterTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(secondaryForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, titleSidePadding)
                        .allowsHitTesting(false)
                }
            }
            .foregroundStyle(pageForeground)
            .padding(.leading, max(8, safeLeading))
            .padding(.trailing, max(8, safeTrailing))
            .padding(.top, controlsTopPadding(safeTop: safeTop))
            .padding(.bottom, 12)
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
        safeLeading: CGFloat,
        safeTrailing: CGFloat,
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
            .padding(.leading, max(8, safeLeading))
            .padding(.trailing, max(8, safeTrailing))
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
                    var next = min(max(Int(newValue.rounded()), 0), pageCount - 1)
                    // Two-column mode navigates by spread; snap any in-between drop to the
                    // spread's left page so we never strand the user on a right-column page.
                    if useTwoColumn { next -= next % 2 }
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
                                var clamped = min(max(target, 0), pageCount - 1)
                                if useTwoColumn { clamped -= clamped % 2 }
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
                        .font(.system(size: 18, weight: .semibold))
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

    private func preferencesOverlay(
        safeBottom: CGFloat,
        safeLeading: CGFloat,
        safeTrailing: CGFloat
    ) -> some View {
        ZStack {
            Color.black.opacity(currentTheme == .night ? 0.35 : 0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissPreferencesAndControls()
                }

            VStack {
                Spacer()

                VStack(alignment: .leading, spacing: 16) {
                    Capsule()
                        .fill(secondaryForeground.opacity(0.35))
                        .frame(width: 38, height: 4)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, -6)
                        .accessibilityHidden(true)

                    preferenceSliderRow(
                        title: "字号",
                        systemImage: "textformat.size",
                        value: $fontSize,
                        range: 12...35,
                        step: 1,
                        format: { "\(Int($0))" }
                    )

                    preferenceSliderRow(
                        title: "行距",
                        systemImage: "line.3.horizontal",
                        value: $lineSpacing,
                        range: 0...24,
                        step: 1,
                        format: { "\(Int($0))" }
                    )

                    preferenceSliderRow(
                        title: "段距",
                        systemImage: "text.alignleft",
                        value: $paragraphSpacingMultiplier,
                        range: 0...1.5,
                        step: 0.1,
                        format: { String(format: "%.1f", $0) }
                    )

                    preferenceFontRow

                    preferencePageTransitionRow

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
                        preferenceTogglePill(
                            label: "双栏",
                            systemImage: "rectangle.split.2x1",
                            isOn: $twoColumnLayout
                        )
                    }

                    if autoScroll {
                        preferenceSliderRow(
                            title: "停留",
                            systemImage: "timer",
                            value: $autoScrollSeconds,
                            range: 2...30,
                            step: 1,
                            format: { "\(Int($0))秒" }
                        )
                    }
                }
                .padding(.leading, max(18, safeLeading))
                .padding(.trailing, max(18, safeTrailing))
                .padding(.top, 14)
                .padding(.bottom, max(safeBottom + 16, 22))
                .background(
                    Rectangle()
                        .fill(currentTheme.chromeBackground)
                        .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: -3)
                )
                .offset(y: preferencesDragOffset)
                .gesture(preferencesDismissGesture)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    /// Drag-down to dismiss for the preferences popup. The card follows the finger 1:1
    /// downward with light upward resistance, then either snaps back or animates off
    /// screen based on the drag's projected end — same feel as a system sheet.
    private var preferencesDismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let h = value.translation.height
                preferencesDragOffset = h > 0 ? h : h * 0.18
            }
            .onEnded { value in
                let dismissThreshold: CGFloat = 110
                let projected = value.predictedEndTranslation.height
                let shouldDismiss = projected > dismissThreshold
                    || value.translation.height > dismissThreshold

                if shouldDismiss {
                    dismissPreferencesAndControls()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        preferencesDragOffset = 0
                    }
                }
            }
    }

    /// Close the preferences popup and the top/bottom control bars together. Tapping the
    /// backdrop or sliding the popup down should put the reader back into immersive mode,
    /// not leave the chrome stranded behind a now-invisible popup.
    private func dismissPreferencesAndControls() {
        withAnimation(.easeInOut(duration: 0.22)) {
            showPreferences = false
            showControls = false
        }
        // Reset after the dismiss transition completes so the next presentation animates
        // in from offscreen, not from a stale offset.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            preferencesDragOffset = 0
        }
    }

    /// Minimal popup that mirrors `preferencesOverlay`'s shape (dim backdrop, bottom card,
    /// drag-to-dismiss) but only houses the brightness slider — so the user can dim/brighten
    /// without paging through the AA settings.
    private func brightnessOverlay(
        safeBottom: CGFloat,
        safeLeading: CGFloat,
        safeTrailing: CGFloat
    ) -> some View {
        ZStack {
            Color.black.opacity(currentTheme == .night ? 0.35 : 0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissBrightnessAndControls()
                }

            VStack {
                Spacer()

                VStack(alignment: .leading, spacing: 16) {
                    Capsule()
                        .fill(secondaryForeground.opacity(0.35))
                        .frame(width: 38, height: 4)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, -6)
                        .accessibilityHidden(true)

                    preferenceSliderRow(
                        title: "亮度",
                        systemImage: "sun.max",
                        value: brightnessBinding,
                        range: 0...1,
                        step: 0.01,
                        format: { "\(Int(($0 * 100).rounded()))%" }
                    )
                }
                .padding(.leading, max(18, safeLeading))
                .padding(.trailing, max(18, safeTrailing))
                .padding(.top, 14)
                .padding(.bottom, max(safeBottom + 16, 22))
                .background(
                    Rectangle()
                        .fill(currentTheme.chromeBackground)
                        .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: -3)
                )
                .offset(y: brightnessDragOffset)
                .gesture(brightnessDismissGesture)
                .onAppear {
                    // Resync from the screen each time the popup is shown — the user may
                    // have changed brightness via Control Center while the popup was closed.
                    brightnessLevel = Double(UIScreen.main.brightness)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var brightnessDismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let h = value.translation.height
                brightnessDragOffset = h > 0 ? h : h * 0.18
            }
            .onEnded { value in
                let dismissThreshold: CGFloat = 110
                let projected = value.predictedEndTranslation.height
                let shouldDismiss = projected > dismissThreshold
                    || value.translation.height > dismissThreshold

                if shouldDismiss {
                    dismissBrightnessAndControls()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        brightnessDragOffset = 0
                    }
                }
            }
    }

    private func dismissBrightnessAndControls() {
        withAnimation(.easeInOut(duration: 0.22)) {
            showBrightness = false
            showControls = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            brightnessDragOffset = 0
        }
    }

    private func preferenceSliderRow(
        title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(pageForeground)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(pageForeground)
                Spacer(minLength: 0)
                Text(format(value.wrappedValue))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(pageForeground)
            }

            Slider(value: value, in: range, step: step)
                .tint(pageForeground.opacity(0.85))
        }
    }

    private var preferenceFontRow: some View {
        HStack(spacing: 12) {
            Text("字体")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondaryForeground)
                .frame(width: 36, alignment: .leading)

            Spacer(minLength: 0)

            Picker("字体", selection: fontFamilyBinding) {
                ForEach(ReaderFontFamily.allCases) { family in
                    Text(family.displayName)
                        .font(family.swiftUIFont(size: 16))
                        .tag(family.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(pageForeground)
        }
    }

    private var preferencePageTransitionRow: some View {
        HStack(spacing: 12) {
            Text("翻页")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondaryForeground)
                .frame(width: 36, alignment: .leading)

            Spacer(minLength: 0)

            Picker("翻页", selection: pageTransitionBinding) {
                ForEach(PageTransitionStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(pageForeground)
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

        // Defensive clamp: in the (vanishingly rare) case currentChapterPageIndex
        // is negative — e.g. a stale write from an in-flight gesture/setter — bare
        // `min(..., pages.count-1)` would still subscript with a negative index and
        // crash. Pin to a known-good range before subscripting.
        let clampedIndex = max(0, min(currentChapterPageIndex, pages.count - 1))
        return pages[clampedIndex]
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

    private func setInitialChapterIfNeeded(textSize: CGSize) {
        guard !didSetInitialPage else { return }

        if let chapterIndex = restoredChapterIndex() {
            let chapterPageIndex = max(activeNovel.currentChapterPageIndex ?? 0, 0)
            pendingRestoreChapterKey = chapterCacheKey(baseChapters[chapterIndex])
            pendingRestoreChapterPageIndex = chapterPageIndex
            currentChapterIndex = chapterIndex
            // Leave the page index at 0 until pagination produces real pages.
            // Seeding it with `chapterPageIndex` here while `visiblePages` is still
            // empty makes the slide/pageCurl pager initialize with currentIndex
            // out of bounds (pageCount == 1, currentIndex == 3), which leaves it
            // showing a blank page until the user manually flips. Restore happens
            // in `applyPendingPageRestoreIfNeeded` after pagination completes
            // (sync below for the cached path, or async via .task for uncached).
            currentChapterPageIndex = 0
        } else {
            currentChapterIndex = fallbackChapterIndexFromProgress()
            currentChapterPageIndex = 0
        }

        loadDiskCachedChapterImmediately(at: currentChapterIndex)

        // Sync paginate when the chapter is already loaded so the first rendered
        // frame after onAppear lands on the saved page directly. Without this,
        // the user briefly sees the start of the chapter (the placeholder page,
        // which renders the entire chapter content as a single page) before the
        // async .task pagination runs and `applyPendingPageRestoreIfNeeded` snaps
        // to the saved index. Cost is bounded by single-chapter pagination
        // (~tens of ms for typical chapters); falls back to the async path if
        // textSize hasn't settled yet or the chapter content isn't available.
        paginateSynchronouslyForRestoreIfPossible(textSize: textSize)

        didSetInitialPage = true
    }

    /// Paginates the restored chapter on the main thread when content is already
    /// in memory (disk cache hit), seeds `visiblePages`, and lets the existing
    /// `applyPendingPageRestoreIfNeeded` plumbing snap `currentChapterPageIndex`
    /// to the saved value before SwiftUI renders again. No-ops when the chapter
    /// hasn't loaded yet, when the saved page is 0 (nothing to restore), or
    /// when GeometryReader hasn't produced a usable size.
    private func paginateSynchronouslyForRestoreIfPossible(textSize: CGSize) {
        guard let chapterPageIndex = pendingRestoreChapterPageIndex,
              chapterPageIndex > 0,
              textSize.width > 0, textSize.height > 0,
              let chapter = currentChapter else { return }

        let content = displayed(readerContent(for: chapter, chapterIndex: currentChapterIndex))
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        ReaderDiagnostics.shared.log(.paginationStart, "sync restore", context: [
            "ch": String(currentChapterIndex),
            "len": String(content.count),
            "restoreTo": String(chapterPageIndex)
        ])
        let start = Date()

        let signature = paginationSignature(textSize: textSize)
        let pageContents = Self.paginate(
            content: content,
            textSize: textSize,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacingMultiplier,
            fontFamily: readerFontFamily
        )
        let durMs = Int(Date().timeIntervalSince(start) * 1000)
        guard !pageContents.isEmpty else {
            ReaderDiagnostics.shared.log(.paginationFail, "sync restore — empty result", context: [
                "ch": String(currentChapterIndex),
                "durMs": String(durMs)
            ])
            return
        }

        rememberPaginatedPages(pageContents, for: signature)
        ReaderDiagnostics.shared.log(.paginationEnd, "sync restore", context: [
            "ch": String(currentChapterIndex),
            "pages": String(pageContents.count),
            "durMs": String(durMs)
        ])
        let chapterTitle = displayed(chapter.title)
        let items = pageItems(
            from: pageContents,
            chapterIndex: currentChapterIndex,
            chapterTitle: chapterTitle
        )
        applyVisiblePages(items, signature: signature)
        ReaderDiagnostics.shared.snapshot(diagnosticsSnapshot)
    }

    private func clampCurrentPage(to pages: [ReaderPageItem]) {
        guard !pages.isEmpty else {
            currentChapterPageIndex = 0
            return
        }

        // In two-column mode, the visible "page" is actually a spread that always starts on an
        // even page index. Snap into that grid so the user can never land mid-spread (e.g.
        // after a font-size change re-paginates and the old index now points at a right-column).
        let lastIndex = max(pages.count - 1, 0)
        let lastNavigableIndex = useTwoColumn
            ? max(((pages.count + 1) / 2 - 1) * 2, 0)
            : lastIndex

        if shouldJumpToLastPageAfterPagination {
            shouldJumpToLastPageAfterPagination = false
            // After a backward chapter jump (prev-page from page 0), the just-paginated chapter
            // wants to land on its last page. Snap without animation so the pager doesn't
            // slide forward (0 → last) immediately after the chapter swap.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                currentChapterPageIndex = lastNavigableIndex
            }
        } else {
            var clamped = min(currentChapterPageIndex, lastNavigableIndex)
            if useTwoColumn { clamped -= clamped % 2 }
            currentChapterPageIndex = max(clamped, 0)
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls.toggle()
            if !showControls {
                showChapterPicker = false
                showPreferences = false
                showBrightness = false
            }
        }
    }

    private func hideControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls = false
            showChapterPicker = false
            showPreferences = false
            showBrightness = false
        }
    }

    private func dismissReaderHelpOverlay() {
        withAnimation(.easeInOut(duration: 0.28)) {
            hasSeenReaderHelpOverlay = true
        }
    }

    private func goToPreviousPage(pages: [ReaderPageItem]) {
        guard !showChapterPicker else { return }
        let step = useTwoColumn ? 2 : 1
        if currentChapterPageIndex >= step {
            setChapterPageIndexAnimatingIfNeeded(currentChapterPageIndex - step)
        } else if currentChapterIndex > 0 {
            goToChapter(currentChapterIndex - 1, pageIndex: 0, landOnLastPage: true)
        }
    }

    private func goToNextPage(pages: [ReaderPageItem]) {
        guard !showChapterPicker else { return }
        let step = useTwoColumn ? 2 : 1
        // In two-column mode, the next spread starts at currentChapterPageIndex + 2. If only
        // one page remains in the chapter (the right column of the last spread is blank),
        // a step forward should still flip to the next chapter, not advance into a phantom page.
        let lastNavigablePageIndex = useTwoColumn
            ? max(((pages.count + 1) / 2 - 1) * 2, 0)
            : pages.count - 1
        if currentChapterPageIndex < lastNavigablePageIndex {
            setChapterPageIndexAnimatingIfNeeded(min(currentChapterPageIndex + step, lastNavigablePageIndex))
        } else if currentChapterIndex < baseChapters.count - 1 {
            goToChapter(currentChapterIndex + 1, pageIndex: 0)
        }
    }

    /// Tap zones / auto-scroll mutate the page index directly; the pager observes the
    /// adjacency in `updateUIViewController` and animates via `setViewControllers(animated:)`
    /// for both slide and pageCurl. Instant mode renders via `.id` so an animated transaction
    /// would crossfade what should be a hard swap — we deliberately avoid `withAnimation`.
    private func setChapterPageIndexAnimatingIfNeeded(_ newIndex: Int) {
        currentChapterPageIndex = newIndex
    }

    @MainActor
    private func startAutoScroll() {
        stopAutoScroll()
        ReaderDiagnostics.shared.log(.taskStart, "autoScroll loop", context: [
            "interval": String(format: "%.1f", autoScrollSeconds)
        ])
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled, autoScroll {
                let seconds = max(autoScrollSeconds, 1)
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, autoScroll else { return }
                // Pause whenever any overlay is showing — gives the user breathing room
                // to interact with controls without losing their place.
                if showControls || showChapterPicker || showPreferences || showBrightness { continue }
                advanceAutoScrollPage()
            }
        }
    }

    @MainActor
    private func stopAutoScroll() {
        if autoScrollTask != nil {
            ReaderDiagnostics.shared.log(.taskCancel, "autoScroll loop")
        }
        autoScrollTask?.cancel()
        autoScrollTask = nil
    }

    @MainActor
    private func advanceAutoScrollPage() {
        let pages = activeVisiblePages()
        let step = useTwoColumn ? 2 : 1
        let lastNavigablePageIndex = useTwoColumn
            ? max(((pages.count + 1) / 2 - 1) * 2, 0)
            : pages.count - 1
        if currentChapterPageIndex < lastNavigablePageIndex {
            withAnimation(.easeInOut(duration: 0.45)) {
                currentChapterPageIndex = min(currentChapterPageIndex + step, lastNavigablePageIndex)
            }
        } else if currentChapterIndex < baseChapters.count - 1 {
            goToChapter(currentChapterIndex + 1, pageIndex: 0)
        } else {
            // Reached the end of the book — turn the toggle off so the task exits and the
            // user sees the preference reflected.
            autoScroll = false
        }
    }

    private func goToChapter(_ chapterIndex: Int, pageIndex: Int, landOnLastPage: Bool = false) {
        guard baseChapters.indices.contains(chapterIndex) else {
            ReaderDiagnostics.shared.log(.chapterJump, "rejected out-of-range", context: [
                "target": String(chapterIndex),
                "chCount": String(baseChapters.count)
            ])
            return
        }
        ReaderDiagnostics.shared.log(.chapterJump, "goToChapter", context: [
            "from": String(currentChapterIndex),
            "to": String(chapterIndex),
            "page": String(pageIndex),
            "landLast": landOnLastPage ? "1" : "0"
        ])
        // Suppress pager animation: changing currentChapterPageIndex (e.g., 5 → 0) while
        // pages are being swapped to a new chapter would otherwise animate backwards on a
        // forward jump (and vice versa). Snapping is the right behavior for explicit chapter
        // navigation. The "land on last page" flag is set inside the same transaction so a
        // partially-applied state (flag set without index, or vice versa) can never leak to
        // another navigation in flight.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            currentChapterIndex = chapterIndex
            currentChapterPageIndex = max(pageIndex, 0)
            shouldJumpToLastPageAfterPagination = landOnLastPage
        }
        // Stale boundary-swipe state from an interrupted drag in the previous chapter must
        // not leak into the next chapter's gesture session, or the next swipe could think
        // it started at a boundary when it didn't.
        boundarySwipeStartPageIndex = nil
        // Once the user explicitly navigates, the original auto-restore intent (the page
        // index recorded for the chapter the book opened to) no longer applies. Without
        // this, a chapter that was still loading when the user swiped away from it would,
        // on its delayed pagination completing, snap the page to the originally-saved
        // position even after the user has navigated back to it expecting page 0 — the
        // "swipe to next chapter lands in the middle" symptom.
        pendingRestoreChapterKey = nil
        pendingRestoreChapterPageIndex = nil
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
    private func startReadingStatsSession(pages: [ReaderPageItem]) {
        guard didSetInitialPage, !catalogNeedsRepair, !pages.isEmpty else { return }
        guard pendingRestoreChapterKey == nil else { return }

        let currentPage = currentPage(in: pages)
        guard baseChapters.indices.contains(currentPage.chapterIndex) else { return }

        let currentChapter = baseChapters[currentPage.chapterIndex]
        libraryStore.startReadingSession(
            for: activeNovel.id,
            progress: readingProgress(for: currentPage),
            chapterIndex: currentPage.chapterIndex,
            chapterPageIndex: currentPage.pageIndex,
            chapterSourceURLString: currentChapter.sourceURLString
        )
    }

    @MainActor
    private func persistReadingState(pages: [ReaderPageItem], force: Bool = false) {
        guard didSetInitialPage, !catalogNeedsRepair, !pages.isEmpty else { return }
        guard pendingRestoreChapterKey == nil else { return }

        let currentPage = currentPage(in: pages)
        guard baseChapters.indices.contains(currentPage.chapterIndex) else { return }

        let currentChapter = baseChapters[currentPage.chapterIndex]
        let progress = readingProgress(for: currentPage)
        let stateKey = "\(activeNovel.id.uuidString)-\(currentPage.chapterIndex)-\(currentPage.pageIndex)-\(pages.count)"
        guard force || stateKey != lastPersistedReadingState else { return }

        lastPersistedReadingState = stateKey
        libraryStore.updateReadingState(
            for: activeNovel.id,
            chapterTitle: currentChapter.title,
            progress: progress,
            chapterIndex: currentPage.chapterIndex,
            chapterPageIndex: currentPage.pageIndex,
            chapterSourceURLString: currentChapter.sourceURLString,
            pageTextCharacterCount: readableCharacterCount(in: currentPage.content)
        )
    }

    private func readableCharacterCount(in text: String) -> Int {
        text.unicodeScalars.filter { !$0.properties.isWhitespace }.count
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
            // Snap without animation. Restoring saved state shouldn't visibly
            // slide / page-curl from page 0 to the saved index — that's a one-frame
            // setup operation, not user-initiated navigation.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                currentChapterPageIndex = targetPageIndex
            }
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
            "\(paragraphSpacingMultiplier)",
            fontFamilyRaw,
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
            ReaderDiagnostics.shared.log(.paginationEnd, "cache hit", context: [
                "ch": String(chapterIndex),
                "pages": String(cached.count),
                "sig": signature
            ])
            let items = pageItems(from: cached, chapterIndex: chapterIndex, chapterTitle: chapterTitle)
            applyVisiblePages(items, signature: signature)
            ReaderDiagnostics.shared.snapshot(diagnosticsSnapshot)
            return
        }

        let content = displayed(readerContent(for: chapter, chapterIndex: chapterIndex))
        let fontSize = self.fontSize
        let lineSpacing = self.lineSpacing
        let paragraphSpacing = self.paragraphSpacingMultiplier
        let fontFamily = readerFontFamily

        ReaderDiagnostics.shared.log(.paginationStart, "async", context: [
            "ch": String(chapterIndex),
            "len": String(content.count),
            "textSize": "\(Int(textSize.width))x\(Int(textSize.height))",
            "fontSize": String(format: "%.1f", fontSize)
        ])
        let paginationStart = Date()

        let work = Task.detached(priority: .userInitiated) {
            Self.paginate(
                content: content,
                textSize: textSize,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                paragraphSpacing: paragraphSpacing,
                fontFamily: fontFamily
            )
        }
        let pageContents = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }

        let durMs = Int(Date().timeIntervalSince(paginationStart) * 1000)
        if Task.isCancelled || pageContents.isEmpty {
            ReaderDiagnostics.shared.log(.paginationCancel, "async", context: [
                "ch": String(chapterIndex),
                "durMs": String(durMs),
                "cancelled": Task.isCancelled ? "1" : "0",
                "empty": pageContents.isEmpty ? "1" : "0"
            ])
            return
        }

        rememberPaginatedPages(pageContents, for: signature)

        ReaderDiagnostics.shared.log(.paginationEnd, "async", context: [
            "ch": String(chapterIndex),
            "pages": String(pageContents.count),
            "durMs": String(durMs),
            "sig": signature
        ])

        let items = pageItems(from: pageContents, chapterIndex: chapterIndex, chapterTitle: chapterTitle)
        applyVisiblePages(items, signature: signature)
        ReaderDiagnostics.shared.snapshot(diagnosticsSnapshot)
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
            return readerBodyWithChapterTitle(for: chapter, content: chapter.content)
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
            return readerBodyWithChapterTitle(for: chapter, content: cached.content)
        }

        if loadingChapterKeys.contains(key) {
            return "\(chapter.title)\n\n正在加载章节内容..."
        }

        return "\(chapter.title)\n\n正在加载章节内容..."
    }

    private func readerBodyWithChapterTitle(for chapter: NovelChapter, content: String) -> String {
        let chapterTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = stripLeadingTitleRepeats(
            in: content,
            chapterTitle: chapter.title
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        // Imports normalize paragraph breaks as `\n\n` (blank line between paragraphs), but
        // rendering that literally adds a full empty line that 段距=0 can't shrink. Collapse
        // any run of two-plus newlines to a single one here so the gap is fully controlled
        // by `paragraphStyle.paragraphSpacing` — the slider now spans "tight" to "loose"
        // instead of "loose" to "looser".
        let compactedBody = body.replacingOccurrences(
            of: #"\n\s*\n+"#,
            with: "\n",
            options: .regularExpression
        )

        guard !chapterTitle.isEmpty else { return compactedBody }
        guard !compactedBody.isEmpty else { return chapterTitle }
        return "\(chapterTitle)\n\(compactedBody)"
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
            ReaderDiagnostics.shared.log(.taskStart, "chapter prefetch", context: [
                "ch": String(chapterIndex),
                "key": String(key.prefix(16))
            ])
            Task {
                let start = Date()
                do {
                    let loadedChapter = try await ChapterContentCache.shared.chapter(for: chapter)
                    let merged = mergedOverride(loaded: loadedChapter, matching: chapter)
                    await MainActor.run {
                        loadedChapterOverrides[key] = merged
                        downloadedChapterKeys.insert(key)
                        _ = prefetchingChapterKeys.remove(key)
                    }
                    await prePaginate(chapter: merged, originalChapter: chapter, chapterIndex: chapterIndex)
                    ReaderDiagnostics.shared.log(.taskEnd, "chapter prefetch", context: [
                        "ch": String(chapterIndex),
                        "durMs": String(Int(Date().timeIntervalSince(start) * 1000))
                    ])
                } catch {
                    await MainActor.run {
                        _ = prefetchingChapterKeys.remove(key)
                    }
                    ReaderDiagnostics.shared.log(.taskEnd, "chapter prefetch failed", context: [
                        "ch": String(chapterIndex),
                        "durMs": String(Int(Date().timeIntervalSince(start) * 1000)),
                        "err": String(describing: error).prefix(80).description
                    ])
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

        let content = readerBodyWithChapterTitle(for: chapter, content: chapter.content)
        let displayedContent = displayed(content)
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
        let paragraphSpacing = self.paragraphSpacingMultiplier
        let fontFamily = readerFontFamily
        ReaderDiagnostics.shared.log(.paginationStart, "prefetch prePaginate", context: [
            "ch": String(chapterIndex),
            "len": String(displayedContent.count)
        ])
        let start = Date()
        let pages = await Task.detached(priority: .utility) {
            Self.paginate(
                content: displayedContent,
                textSize: textSize,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                paragraphSpacing: paragraphSpacing,
                fontFamily: fontFamily
            )
        }.value

        let durMs = Int(Date().timeIntervalSince(start) * 1000)
        guard !pages.isEmpty else {
            ReaderDiagnostics.shared.log(.paginationCancel, "prefetch prePaginate", context: [
                "ch": String(chapterIndex),
                "durMs": String(durMs)
            ])
            return
        }
        rememberPaginatedPages(pages, for: signature)
        ReaderDiagnostics.shared.log(.paginationEnd, "prefetch prePaginate", context: [
            "ch": String(chapterIndex),
            "pages": String(pages.count),
            "durMs": String(durMs)
        ])
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

    /// Drop leading lines from scraped chapter content that just repeat the book title,
    /// the chapter title, or the two concatenated. Many sources (黄金屋, 笔趣阁 forks,
    /// etc.) prepend the chapter header to the body, which is redundant once the
    /// reader chrome already shows both. We compare against the live `activeNovel`
    /// title — and the catalog `chapterTitle` rather than `chapter.title` — so this
    /// also strips the source's own header even when it doesn't match the catalog
    /// title verbatim.
    private func stripLeadingTitleRepeats(in content: String, chapterTitle: String) -> String {
        let bookTitle = activeNovel.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let chapter = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build the set of leading-line variants worth stripping. Combinations cover
        // "{book} {chapter}" and "{chapter} {book}" with optional separator whitespace.
        var candidates: Set<String> = []
        if !bookTitle.isEmpty { candidates.insert(bookTitle) }
        if !chapter.isEmpty { candidates.insert(chapter) }
        if !bookTitle.isEmpty && !chapter.isEmpty {
            candidates.insert("\(bookTitle) \(chapter)")
            candidates.insert("\(bookTitle)\(chapter)")
            candidates.insert("\(chapter) \(bookTitle)")
            candidates.insert("\(chapter)\(bookTitle)")
        }
        guard !candidates.isEmpty else { return content }

        // Inspect at most the first 4 lines — anything further in is unlikely to be a
        // header repeat and we don't want to accidentally swallow real story text.
        var lines = content.components(separatedBy: "\n")
        var droppedAny = false
        var inspected = 0
        while inspected < 4, let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // Blank line at the top; just drop it and keep scanning.
                lines.removeFirst()
                droppedAny = true
                continue
            }
            if candidates.contains(trimmed) {
                lines.removeFirst()
                droppedAny = true
                inspected += 1
                continue
            }
            break
        }

        guard droppedAny else { return content }
        // Also clean any blank lines left behind at the new top.
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
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
        // Mirror the asymmetric horizontal padding applied in `pageView` so paginated
        // line widths match the actual rendered text width — otherwise landscape with
        // a Dynamic Island would over-fill lines and glyphs would slide under the cutout.
        let leading = max(horizontalMargin, safeAreaInsets.leading)
        let trailing = max(horizontalMargin, safeAreaInsets.trailing)
        let totalWidth = max(containerSize.width - leading - trailing, 120)
        // Two-column landscape spread halves the per-column width (minus the gutter between
        // columns) so the paginator produces pages that fit one column. The renderer then
        // shows two consecutive pages side by side as a single spread.
        let usingTwoColumn = twoColumnLayout
            && containerSize.width > containerSize.height
            && containerSize.width > 0
        let columnWidth = usingTwoColumn
            ? max((totalWidth - twoColumnGutter) / 2, 120)
            : totalWidth
        let height = max(
            containerSize.height
            - contentTopPadding(safeAreaInsets: safeAreaInsets)
            - contentBottomPadding(safeAreaInsets: safeAreaInsets)
            - footerHeight
            - footerSpacing,
            160
        )

        return CGSize(width: columnWidth, height: height)
    }

    private var footerTextHeight: CGFloat {
        let font = UIFont.systemFont(ofSize: 11, weight: .medium)
        return ceil(font.lineHeight)
    }

    nonisolated private static func paginate(
        content: String,
        textSize: CGSize,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        fontFamily: ReaderFontFamily
    ) -> [String] {
        var remaining = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if remaining.isEmpty { return [""] }

        let attributes = readerAttributes(
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            fontFamily: fontFamily
        )
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
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        fontFamily: ReaderFontFamily
    ) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .justified
        paragraphStyle.baseWritingDirection = .leftToRight
        paragraphStyle.lineSpacing = lineSpacing
        // Multiplier is taken against font size (≈ line height) so paragraph gaps stay
        // visually consistent across font sizes and don't collapse to zero when the user
        // dials lineSpacing down to 0.
        paragraphStyle.paragraphSpacing = fontSize * paragraphSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping

        return [
            .font: fontFamily.uiFont(size: fontSize),
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
    let paragraphSpacing: CGFloat
    let fontFamily: ReaderFontFamily
    let color: UIColor
    var onLookup: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onLookup: onLookup)
    }

    func makeUIView(context: Context) -> ReaderTextView {
        let textView = ReaderTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        // Stay non-interactive when no lookup handler is wired so the existing tap-to-flip
        // and drag gestures keep their fast path. With a handler, enable interaction and
        // attach a single long-press recognizer that defers to (rather than steals from)
        // the parent SwiftUI gestures via cancelsTouchesInView=false + simultaneous delegate.
        textView.isUserInteractionEnabled = (onLookup != nil)
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

        if onLookup != nil {
            let lp = UILongPressGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleLongPress(_:))
            )
            lp.minimumPressDuration = 0.45
            lp.cancelsTouchesInView = false
            lp.delegate = context.coordinator
            textView.addGestureRecognizer(lp)
        }

        return textView
    }

    func updateUIView(_ textView: ReaderTextView, context: Context) {
        context.coordinator.onLookup = onLookup

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .justified
        paragraphStyle.baseWritingDirection = .leftToRight
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacing = fontSize * paragraphSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping

        textView.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: fontFamily.uiFont(size: fontSize),
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
        )
        textView.updateContainerSize()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onLookup: ((String) -> Void)?

        init(onLookup: ((String) -> Void)?) {
            self.onLookup = onLookup
        }

        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began,
                  let tv = gr.view as? ReaderTextView,
                  let onLookup else { return }
            let location = gr.location(in: tv)
            guard let term = tv.lookupTerm(at: location), !term.isEmpty else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            onLookup(term)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
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

    /// Returns the natural-language "word" at `point`, segmented via NLTokenizer so multi-
    /// character Chinese terms (双字词 / 成语) come back intact instead of single hanzi.
    /// Returns nil if the touch missed every glyph or the tokenizer couldn't produce a
    /// non-empty range — caller treats nil as "do nothing".
    func lookupTerm(at point: CGPoint) -> String? {
        guard attributedText.length > 0 else { return nil }

        // Sanity-check that the touch is near an actual glyph. characterIndex(for:in:) will
        // clamp far-out points to the nearest character, but we don't want a long-press in
        // the empty bottom margin to look up the last word on the page.
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.insetBy(dx: -6, dy: -6).contains(point) else { return nil }

        let charIndex = layoutManager.characterIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard charIndex >= 0, charIndex < attributedText.length else { return nil }

        // charIndex is in UTF-16 code units; map back through the UTF16View so non-BMP
        // characters (rare in Chinese fiction but possible in emoji or extended hanzi)
        // don't desync the index.
        let plain = attributedText.string
        let utf16 = plain.utf16
        guard let utf16Position = utf16.index(utf16.startIndex,
                                              offsetBy: charIndex,
                                              limitedBy: utf16.endIndex),
              let strIndex = utf16Position.samePosition(in: plain) else {
            return nil
        }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = plain
        // Hint Simplified Chinese so the segmenter picks the Chinese word model rather than
        // falling back to whitespace-only segmentation (which would treat the whole page as
        // a single token for unspaced CJK text).
        tokenizer.setLanguage(.simplifiedChinese)
        let range = tokenizer.tokenRange(at: strIndex)
        let term = String(plain[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? nil : term
    }
}

/// Wraps `UIReferenceLibraryViewController` for in-reader long-press lookups. Presents
/// modally on the top-most view controller — bypassing SwiftUI's sheet machinery — because
/// the reference VC owns its own nav chrome and dismisses itself via UIKit, which a
/// SwiftUI sheet host doesn't always forward cleanly.
enum ReaderDictionary {
    static func present(term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let top = topmostViewController() else { return }
        let vc = UIReferenceLibraryViewController(term: trimmed)
        top.present(vc, animated: true)
    }

    private static func topmostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = activeScene?.windows.first(where: { $0.isKeyWindow })
            ?? activeScene?.windows.first else { return nil }
        var top: UIViewController? = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
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

/// First-launch help popup shown the first time the user opens a reader.
/// Mirror of `LibraryHelpPopup` but with reader-specific affordances. The
/// dim scrim ignores safe areas so it covers the status-bar region even
/// while the reader keeps the bar hidden.
private struct ReaderHelpPopup: View {
    @Environment(\.appTheme) private var theme

    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text("开始阅读")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    Text("阅读手势速览")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                }

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(readerHelpItems) { item in
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
                    Text("开始阅读")
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
