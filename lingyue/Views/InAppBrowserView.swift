import SwiftUI
import WebKit

struct InAppBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var libraryStore: LibraryStore

    let url: URL
    let title: String

    @StateObject private var browserState = InAppBrowserState()
    @State private var detectedBook: WebBookCandidate?
    @State private var replacementCandidate: WebBookCandidate?
    @State private var categoryPrompt: CategoryPromptState?
    @State private var ignoredBookURLs: Set<String> = []
    @State private var importStatus: BrowserImportStatus?
    @State private var importResult: BrowserImportResult?
    @State private var bookToOpen: Novel?

    private var hasBlockingOverlay: Bool {
        detectedBook != nil
            || replacementCandidate != nil
            || categoryPrompt != nil
            || importStatus != nil
            || importResult != nil
    }

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            VStack(spacing: 0) {
                browserControls

                ZStack(alignment: .top) {
                    InAppWebView(
                        url: url,
                        state: browserState,
                        onPageLoaded: inspectPageForBook
                    )
                    .allowsHitTesting(!hasBlockingOverlay)

                    if browserState.isLoading {
                        ProgressView(value: browserState.estimatedProgress)
                            .progressViewStyle(.linear)
                            .tint(theme.accent)
                            .frame(height: 2)
                    }
                }
            }

            if let importStatus {
                importOverlay(status: importStatus)
                    .transition(ModalStyle.transition)
                    .zIndex(3)
            }

            if let detectedBook {
                importPromptOverlay(candidate: detectedBook)
                    .transition(ModalStyle.transition)
                    .zIndex(4)
            }

            if let replacementCandidate {
                replacementPromptOverlay(candidate: replacementCandidate)
                    .transition(ModalStyle.transition)
                    .zIndex(5)
            }

            if let categoryPrompt {
                categoryPromptOverlay(prompt: categoryPrompt)
                    .transition(BrandedPopupStyle.bottomTransition)
                    .zIndex(6)
            }

            if let importResult {
                importResultOverlay(result: importResult)
                    .transition(ModalStyle.transition)
                    .zIndex(7)
            }
        }
        .navigationDestination(item: $bookToOpen) { novel in
            ReaderView(novel: novel)
        }
        .animation(ModalStyle.presentationAnimation, value: detectedBook?.sourceURL)
        .animation(ModalStyle.presentationAnimation, value: replacementCandidate?.sourceURL)
        .animation(ModalStyle.presentationAnimation, value: categoryPrompt?.id)
        .animation(ModalStyle.presentationAnimation, value: importStatus)
        .animation(ModalStyle.presentationAnimation, value: importResult?.id)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        // Don't pin the nav bar background — let the system's translucent material
        // pick up `ThemeBackgroundView` underneath (matches Library / Discovery).
        // Forcing `theme.background` here painted a flat color that didn't match
        // the gradient / image pattern themes use for the rest of the chrome.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let target = browserState.currentURL ?? url
                    UIApplication.shared.open(target)
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .foregroundStyle(theme.primaryText)
                .accessibilityLabel("在 Safari 中打开")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .foregroundStyle(theme.primaryText)
                .accessibilityLabel("关闭")
            }
        }
    }

    private func importPromptOverlay(candidate: WebBookCandidate) -> some View {
        let dismiss = {
            withAnimation(ModalStyle.presentationAnimation) {
                ignoredBookURLs.insert(candidate.sourceURL.absoluteString)
                detectedBook = nil
            }
        }

        return CustomAlertView(
            type: .info,
            title: "发现书籍",
            bookTitle: candidate.title,
            message: "是否将此书导入到书架？",
            primaryButton: .primary("导入") {
                // Mark this URL as handled before kicking off the import flow,
                // otherwise the delayed page-load inspections (0.6s/1.5s after
                // didFinish) will re-detect the same book and re-show this popup
                // on top of the category prompt.
                ignoredBookURLs.insert(candidate.sourceURL.absoluteString)
                withAnimation(ModalStyle.presentationAnimation) {
                    detectedBook = nil
                }
                requestImport(candidate)
            },
            secondaryButton: .secondary("暂不", action: dismiss),
            onDismiss: dismiss
        )
    }

    private func replacementPromptOverlay(candidate: WebBookCandidate) -> some View {
        let dismiss = {
            withAnimation(ModalStyle.presentationAnimation) {
                ignoredBookURLs.insert(candidate.sourceURL.absoluteString)
                replacementCandidate = nil
            }
        }

        return CustomAlertView(
            type: .info,
            title: "书籍已存在",
            bookTitle: candidate.title,
            message: "书架里已经有这本书啦。\n要用当前页面的内容更新一下吗？",
            primaryButton: .primary("更新书籍") {
                withAnimation(ModalStyle.presentationAnimation) {
                    replacementCandidate = nil
                }
                promptForCategory(candidate, isReplacing: true)
            },
            secondaryButton: .secondary("先不了", action: dismiss),
            iconOverride: "books.vertical.circle.fill",
            tintOverride: Color.readerAccent,
            onDismiss: dismiss
        )
    }

    private func inspectPageForBook(url: URL, pageTitle: String?, html: String) {
#if DEBUG
        print("[Browser] inspect \(url.absoluteString) — htmlBytes=\(html.count) detected=\(detectedBook != nil) ignored=\(ignoredBookURLs.contains(url.absoluteString))")
#endif
        guard replacementCandidate == nil,
              categoryPrompt == nil,
              importStatus == nil,
              importResult == nil else { return }
        guard !ignoredBookURLs.contains(url.absoluteString) else { return }

        Task {
            let candidate = await Task.detached(priority: .userInitiated) {
                BookImportService.shared.detectBook(html: html, url: url, pageTitle: pageTitle)
            }.value
            guard let candidate else { return }
            await MainActor.run {
#if DEBUG
                print("[Browser] candidate ready for \(url.absoluteString) — title=\(candidate.title)")
#endif
                guard replacementCandidate == nil,
                      categoryPrompt == nil,
                      importStatus == nil,
                      importResult == nil,
                      !ignoredBookURLs.contains(url.absoluteString) else {
#if DEBUG
                    print("[Browser] candidate dropped — guard triggered")
#endif
                    return
                }
                if let detectedBook,
                   !shouldReplaceDetectedBook(detectedBook, with: candidate) {
#if DEBUG
                    print("[Browser] candidate dropped — existing candidate is better")
#endif
                    return
                }
                detectedBook = candidate
#if DEBUG
                print("[Browser] popup armed for \(url.absoluteString)")
#endif
            }
        }
    }

    private func shouldReplaceDetectedBook(_ existing: WebBookCandidate, with candidate: WebBookCandidate) -> Bool {
        guard existing.sourceURL == candidate.sourceURL else { return false }
        if candidate.detectedChapterCount > existing.detectedChapterCount {
            return true
        }
        if isGenericDetectedTitle(existing.title), !isGenericDetectedTitle(candidate.title) {
            return true
        }
        return false
    }

    private func isGenericDetectedTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        let genericParts = [
            "笔趣阁", "筆趣閣", "免费阅读", "免費閱讀",
            "小说网", "小說網", "书库", "書庫", "首页", "首頁"
        ]
        return genericParts.contains { lowered.contains($0.lowercased()) }
    }

    private func requestImport(_ candidate: WebBookCandidate) {
        if libraryStore.containsBook(sourceURLString: candidate.sourceURL.absoluteString, title: candidate.title) {
            replacementCandidate = candidate
            return
        }

        promptForCategory(candidate, isReplacing: false)
    }

    private func promptForCategory(_ candidate: WebBookCandidate, isReplacing: Bool) {
        let existing = libraryStore.categoryName(
            forBookWith: candidate.sourceURL.absoluteString,
            title: candidate.title
        )
        categoryPrompt = CategoryPromptState(
            candidate: candidate,
            isReplacing: isReplacing,
            initialCategory: existing
        )
    }

    private func startImport(_ candidate: WebBookCandidate, isReplacing: Bool, categoryName: String) {
        ignoredBookURLs.insert(candidate.sourceURL.absoluteString)
        importStatus = BrowserImportStatus(title: candidate.title)

        Task {
            do {
                let enrichedCandidate = await enrichedCandidateForImport(candidate)
                let novel = try await BookImportService.shared.importBook(from: enrichedCandidate)
                let inserted = libraryStore.addImportedNovel(novel, categoryName: categoryName)
                importStatus = nil
                let resultType: CustomAlertType = inserted ? .success : .info
                let title = inserted ? "导入成功" : "已在书架"
                let message: String
                if isReplacing {
                    message = "已替换旧记录，加入「\(categoryName)」。打开章节时会联网加载正文。"
                } else if inserted {
                    message = "已加入「\(categoryName)」。打开章节时会联网加载正文。"
                } else {
                    message = "这本书已经在你的书架中了。"
                }

                importResult = BrowserImportResult(
                    type: resultType,
                    title: title,
                    bookTitle: novel.title,
                    message: message,
                    novel: inserted ? novel : nil
                )
            } catch {
                importStatus = nil
                importResult = BrowserImportResult(
                    type: .error,
                    title: "导入失败",
                    bookTitle: candidate.title,
                    message: error.localizedDescription,
                    novel: nil
                )
            }
        }
    }

    private func enrichedCandidateForImport(_ candidate: WebBookCandidate) async -> WebBookCandidate {
        var htmlParts = [candidate.htmlSnapshot]
        let originalChapterCount = BookImportService.shared.detectedChapterCount(
            in: candidate.htmlSnapshot,
            baseURL: candidate.sourceURL
        )

        if let expandedHTML = await browserState.expandedCatalogHTML() {
            let expandedChapterCount = BookImportService.shared.detectedChapterCount(
                in: expandedHTML,
                baseURL: candidate.sourceURL
            )
            if expandedChapterCount > max(candidate.detectedChapterCount, originalChapterCount)
                || expandedHTML.count > candidate.htmlSnapshot.count {
                htmlParts.append(expandedHTML)
            }
        }

        let catalogURLs = BookImportService.shared.likelyCatalogURLs(for: candidate)
        for catalogURL in catalogURLs.prefix(6) {
            guard let catalogHTML = await browserState.fetchHTML(from: catalogURL),
                  catalogHTML.count > 200,
                  !catalogHTML.contains("加载中……") else {
                continue
            }
            htmlParts.append(catalogHTML)
        }

        guard htmlParts.count > 1 else { return candidate }
        let combinedHTML = htmlParts.joined(separator: "\n")
        let chapterCount = BookImportService.shared.detectedChapterCount(in: combinedHTML, baseURL: candidate.sourceURL)
        return candidate.replacingHTMLSnapshot(
            combinedHTML,
            detectedChapterCount: max(candidate.detectedChapterCount, chapterCount)
        )
    }

    private func importOverlay(status: BrowserImportStatus) -> some View {
        ModalContainer(dismissOnTapOutside: false) {
            ModalCard(maxWidth: 320) {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.readerAccent.opacity(0.14))
                            .frame(width: 56, height: 56)
                        ProgressView()
                            .tint(Color.readerAccent)
                            .scaleEffect(1.1)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 6) {
                        Text("正在导入")
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)

                        Text("《\(status.title)》")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("正在保存书籍信息和章节目录，正文会在阅读时加载。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func importResultOverlay(result: BrowserImportResult) -> some View {
        let dismiss = {
            withAnimation(ModalStyle.presentationAnimation) {
                self.importResult = nil
            }
        }

        let primary: CustomAlertButton
        let secondary: CustomAlertButton?
        if let novel = result.novel, result.type == .success {
            primary = .primary("打开阅读") {
                withAnimation(ModalStyle.presentationAnimation) {
                    self.importResult = nil
                }
                bookToOpen = novel
            }
            secondary = .secondary("好的", action: dismiss)
        } else {
            primary = .primary("好的", action: dismiss)
            secondary = nil
        }

        return CustomAlertView(
            type: result.type,
            title: result.title,
            bookTitle: result.bookTitle,
            message: result.message,
            primaryButton: primary,
            secondaryButton: secondary,
            onDismiss: dismiss
        )
    }

    private func categoryPromptOverlay(prompt: CategoryPromptState) -> some View {
        BrandedPopupContainer(alignment: .bottom, dismissOnScrim: true) {
            withAnimation(ModalStyle.presentationAnimation) {
                categoryPrompt = nil
            }
        } content: {
            BrandedCategoryCard(
                prompt: prompt,
                existingCategoryNames: libraryStore.categories.map(\.name),
                onCancel: {
                    withAnimation(ModalStyle.presentationAnimation) {
                        categoryPrompt = nil
                    }
                },
                onConfirm: { name in
                    let chosen = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let categoryName = chosen.isEmpty ? LibraryStore.uncategorizedName : chosen
                    let candidate = prompt.candidate
                    let isReplacing = prompt.isReplacing
                    withAnimation(ModalStyle.presentationAnimation) {
                        categoryPrompt = nil
                    }
                    startImport(candidate, isReplacing: isReplacing, categoryName: categoryName)
                }
            )
        }
    }

    private var browserControls: some View {
        HStack(spacing: 18) {
            Button {
                browserState.goBack()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .disabled(!browserState.canGoBack)

            Button {
                browserState.goForward()
            } label: {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .disabled(!browserState.canGoForward)

            Text(browserState.hostText)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            Button {
                browserState.reloadOrStop()
            } label: {
                Image(systemName: browserState.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
        }
        .foregroundStyle(theme.accent)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(
            theme.background.ignoresSafeArea()
        )
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(theme.secondaryText.opacity(0.18))
        }
    }
}

private struct InAppWebView: UIViewRepresentable {
    let url: URL
    @ObservedObject var state: InAppBrowserState
    let onPageLoaded: (URL, String?, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, onPageLoaded: onPageLoaded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // Make the web view transparent so the active app theme shows through before
        // the page paints, in the bounce-overscroll area, and anywhere the page itself
        // doesn't draw an opaque background. Most novel mirrors set their own opaque
        // body background in CSS, so visible-while-rendered surface remains the page's
        // own choice — this only affects edges and the loading state.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Many Chinese novel mirrors (笔趣阁 family, daweixs.com, …) sit behind
        // nginx WAF rules that 502 anything missing the Version/* and Safari/*
        // tokens — WKWebView's default UA omits both. Force a full mobile-Safari
        // UA so the in-app browser is treated identically to Safari.
        webView.customUserAgent = Self.mobileSafariUserAgent

        state.attach(webView)
        context.coordinator.observe(webView)
        webView.load(URLRequest(url: url))

        return webView
    }

    private static let mobileSafariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/17.5 Mobile/15E148 Safari/604.1"

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url == nil, !webView.isLoading {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let state: InAppBrowserState
        private let onPageLoaded: (URL, String?, String) -> Void
        private var observations: [NSKeyValueObservation] = []

        init(state: InAppBrowserState, onPageLoaded: @escaping (URL, String?, String) -> Void) {
            self.state = state
            self.onPageLoaded = onPageLoaded
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                    self?.refresh(from: webView)
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                    self?.refresh(from: webView)
                },
                webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
                    self?.refresh(from: webView)
                },
                webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                    self?.refresh(from: webView)
                },
                webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                    self?.refresh(from: webView)
                }
            ]
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            refresh(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            refresh(from: webView)
            inspectLoadedPage(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            refresh(from: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            refresh(from: webView)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        private func refresh(from webView: WKWebView) {
            DispatchQueue.main.async { [state] in
                state.refresh(from: webView)
            }
        }

        private func inspectLoadedPage(_ webView: WKWebView) {
            inspectLoadedPage(webView, after: 0)
            inspectLoadedPage(webView, after: 0.6)
            inspectLoadedPage(webView, after: 1.5)
        }

        private func inspectLoadedPage(_ webView: WKWebView, after delay: TimeInterval) {
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.inspectLoadedPageNow(webView)
                }
                return
            }

            inspectLoadedPageNow(webView)
        }

        private func inspectLoadedPageNow(_ webView: WKWebView) {
            guard let url = webView.url else { return }

            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self, weak webView] result, _ in
                guard let self, let webView else { return }
                let html = result as? String ?? ""
                DispatchQueue.main.async {
                    self.onPageLoaded(url, webView.title, html)
                }
            }
        }
    }
}

private enum BrandedPopupStyle {
    static var bottomTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        )
    }
}

private struct BrandedPopupContainer<Content: View>: View {
    enum Alignment { case center, bottom }

    let alignment: Alignment
    let dismissOnScrim: Bool
    let onScrimTap: () -> Void
    let content: Content

    init(
        alignment: Alignment,
        dismissOnScrim: Bool,
        onScrimTap: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.dismissOnScrim = dismissOnScrim
        self.onScrimTap = onScrimTap
        self.content = content()
    }

    var body: some View {
        ZStack {
            scrim

            switch alignment {
            case .center:
                content
                    .padding(.horizontal, 28)
            case .bottom:
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    content
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private var scrim: some View {
        Color.black.opacity(0.40)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                if dismissOnScrim { onScrimTap() }
            }
            .accessibilityHidden(true)
    }
}

private struct BrandedSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)

            Color.readerSurface.opacity(colorScheme == .dark ? 0.0 : 0.32)

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.06 : 0.20),
                    Color.white.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .center
            )
            .blendMode(.softLight)
        }
    }
}

private struct BrandedPressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct BrowserImportStatus: Equatable {
    let title: String
}

private struct BrowserImportResult: Identifiable {
    let id = UUID()
    let type: CustomAlertType
    let title: String
    let bookTitle: String?
    let message: String
    let novel: Novel?
}

private struct CategoryPromptState: Identifiable {
    let id = UUID()
    let candidate: WebBookCandidate
    let isReplacing: Bool
    let initialCategory: String?
}

private struct BrandedCategoryRow: View {
    let name: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.readerAccent : Color.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.readerAccent)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.readerAccent.opacity(0.12)
                            : Color.clear
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(BrandedPressableButtonStyle(pressedScale: 0.985))
    }
}

private struct BrandedNewCategoryField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let trimmedDraft: String
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.readerAccent)
                .symbolRenderingMode(.hierarchical)

            TextField("新建分类", text: $text)
                .focused(isFocused)
                .submitLabel(.done)
                .onSubmit(onCommit)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .tint(Color.readerAccent)

            if !trimmedDraft.isEmpty {
                Button(action: onCommit) {
                    Text("添加")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.readerAccent)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct BrandedCategoryCard: View {
    let prompt: CategoryPromptState
    let existingCategoryNames: [String]
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var selectedName: String
    @State private var newCategoryDraft: String = ""
    @State private var locallyCreatedNames: [String] = []
    @State private var scrollTarget: String?
    @State private var scrollTick = 0
    @FocusState private var newFieldFocused: Bool

    init(
        prompt: CategoryPromptState,
        existingCategoryNames: [String],
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (String) -> Void
    ) {
        self.prompt = prompt
        self.existingCategoryNames = existingCategoryNames
        self.onCancel = onCancel
        self.onConfirm = onConfirm

        let initial = prompt.initialCategory
            ?? existingCategoryNames.first
            ?? LibraryStore.uncategorizedName
        _selectedName = State(initialValue: initial)
    }

    private var allCategoryNames: [String] {
        var names: [String] = []
        if !existingCategoryNames.contains(LibraryStore.uncategorizedName) {
            names.append(LibraryStore.uncategorizedName)
        }
        names.append(contentsOf: existingCategoryNames)
        for name in locallyCreatedNames where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    private var trimmedDraft: String {
        newCategoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 36, height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("选择分类")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                Text("《\(prompt.candidate.title)》")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(allCategoryNames, id: \.self) { name in
                            BrandedCategoryRow(
                                name: name,
                                isSelected: selectedName == name
                            ) {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                    selectedName = name
                                }
                            }
                            .id(name)
                        }

                        BrandedNewCategoryField(
                            text: $newCategoryDraft,
                            isFocused: $newFieldFocused,
                            trimmedDraft: trimmedDraft,
                            onCommit: commitNewCategory
                        )
                        .animation(.easeInOut(duration: 0.18), value: trimmedDraft.isEmpty)
                    }
                    .animation(.spring(response: 0.42, dampingFraction: 0.84), value: allCategoryNames)
                }
                .frame(maxHeight: 280)
                .onChange(of: scrollTick) { _, _ in
                    guard let target = scrollTarget else { return }
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                        proxy.scrollTo(target, anchor: .bottom)
                    }
                }
            }

            HStack(spacing: 10) {
                ModalButton(title: "取消", role: .secondary, action: onCancel)
                ModalButton(title: "加入", role: .primary) {
                    onConfirm(selectedName)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandedSurface())
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: 12)
    }

    private func commitNewCategory() {
        let trimmed = trimmedDraft
        guard !trimmed.isEmpty else { return }

        let resolvedName: String
        if let existing = allCategoryNames.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedName = existing
            }
            resolvedName = existing
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                locallyCreatedNames.append(trimmed)
                selectedName = trimmed
            }
            resolvedName = trimmed
        }

        newCategoryDraft = ""
        newFieldFocused = false

        scrollTarget = resolvedName
        scrollTick &+= 1
    }
}

private final class InAppBrowserState: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var estimatedProgress = 0.0
    @Published var isLoading = false
    @Published var currentURL: URL?

    private weak var webView: WKWebView?

    var hostText: String {
        guard let host = currentURL?.host(percentEncoded: false), !host.isEmpty else {
            return "网页"
        }
        return host
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        refresh(from: webView)
    }

    func refresh(from webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        estimatedProgress = webView.estimatedProgress
        isLoading = webView.isLoading
        currentURL = webView.url
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reloadOrStop() {
        guard let webView else { return }
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    @MainActor
    func fetchHTML(from url: URL) async -> String? {
        guard let webView else { return nil }
        let urlLiteral = Self.javaScriptStringLiteral(url.absoluteString)
        let script = """
        (async () => {
            try {
                const response = await fetch(\(urlLiteral), { credentials: "include" });
                if (!response.ok) { return ""; }
                return await response.text();
            } catch (_) {
                return "";
            }
        })();
        """

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    @MainActor
    func expandedCatalogHTML() async -> String? {
        guard let webView else { return nil }
        let script = """
        (async () => {
            const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));
            const snapshots = [document.documentElement.outerHTML];
            const pattern = /(查看更多章节|更多章节|全部章节|全部目录|全部目錄|完整目录|完整目錄|章节目录|章節目錄)/;
            const textFor = (element) => [
                element.innerText,
                element.textContent,
                element.value,
                element.getAttribute("aria-label"),
                element.getAttribute("title")
            ].filter(Boolean).join(" ").trim();
            const elements = Array.from(document.querySelectorAll("a,button,div,span,input,p,li,[onclick],[data-href],[data-url]"))
                .map(element => ({ element, text: textFor(element) }))
                .filter(item => pattern.test(item.text))
                .sort((left, right) => left.text.length - right.text.length);

            for (const item of elements.slice(0, 12)) {
                const element = item.element;
                const href = element.href
                    || element.getAttribute("href")
                    || element.getAttribute("data-href")
                    || element.getAttribute("data-url")
                    || element.dataset?.href
                    || element.dataset?.url
                    || "";
                const realHref = href && href !== "#" && !href.toLowerCase().startsWith("javascript:");

                if (realHref) {
                    try {
                        const url = new URL(href, location.href).href;
                        const response = await fetch(url, { credentials: "include" });
                        if (response.ok) {
                            snapshots.push(await response.text());
                        }
                    } catch (_) {}
                    continue;
                }

                try { element.scrollIntoView({ block: "center" }); } catch (_) {}
                try { element.click(); } catch (_) {}
                await sleep(900);
                snapshots.push(document.documentElement.outerHTML);
            }

            return snapshots.join("\\n<!-- CATALOG_SNAPSHOT_BREAK -->\\n");
        })();
        """

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let encodedArray = String(data: data, encoding: .utf8),
            encodedArray.count >= 2
        else {
            return "\"\""
        }

        return String(encodedArray.dropFirst().dropLast())
    }
}
