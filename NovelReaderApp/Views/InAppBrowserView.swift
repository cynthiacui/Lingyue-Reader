import SwiftUI
import WebKit

struct InAppBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryStore: LibraryStore

    let url: URL
    let title: String

    @StateObject private var browserState = InAppBrowserState()
    @State private var detectedBook: WebBookCandidate?
    @State private var replacementCandidate: WebBookCandidate?
    @State private var ignoredBookURLs: Set<String> = []
    @State private var importStatus: BrowserImportStatus?
    @State private var importResult: BrowserImportResult?

    private var hasBlockingOverlay: Bool {
        detectedBook != nil || replacementCandidate != nil || importStatus != nil || importResult != nil
    }

    var body: some View {
        ZStack {
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
                            .tint(Color.readerAccent)
                            .frame(height: 2)
                    }
                }
            }

            if let importStatus {
                importOverlay(status: importStatus)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(3)
            }

            if let detectedBook {
                importPromptOverlay(candidate: detectedBook)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(4)
            }

            if let replacementCandidate {
                replacementPromptOverlay(candidate: replacementCandidate)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(5)
            }

            if let importResult {
                importResultOverlay(result: importResult)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(6)
            }
        }
        .background(Color.readerBackground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .foregroundStyle(Color.readerInk)
                .accessibilityLabel("关闭")
            }
        }
    }

    private func importPromptOverlay(candidate: WebBookCandidate) -> some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("发现书籍")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.readerInk)

                    Text(importPromptMessage(for: candidate))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.readerMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        ignoredBookURLs.insert(candidate.sourceURL.absoluteString)
                        detectedBook = nil
                    } label: {
                        OverlayActionLabel(title: "暂不", style: .secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        detectedBook = nil
                        requestImport(candidate)
                    } label: {
                        OverlayActionLabel(title: "导入到书架", style: .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(maxWidth: 340, alignment: .leading)
            .background(Color.readerSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 12)
            .padding(.horizontal, 28)
        }
    }

    private func replacementPromptOverlay(candidate: WebBookCandidate) -> some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("替换已有书籍？")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.readerInk)

                    Text("《\(candidate.title)》已经在书架中。替换后会用当前网页重新导入书籍信息和章节目录。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.readerMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        ignoredBookURLs.insert(candidate.sourceURL.absoluteString)
                        replacementCandidate = nil
                    } label: {
                        OverlayActionLabel(title: "取消", style: .secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        replacementCandidate = nil
                        startImport(candidate, isReplacing: true)
                    } label: {
                        OverlayActionLabel(title: "替换", style: .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(maxWidth: 340, alignment: .leading)
            .background(Color.readerSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 12)
            .padding(.horizontal, 28)
        }
    }

    private func inspectPageForBook(url: URL, pageTitle: String?, html: String) {
#if DEBUG
        print("[Browser] inspect \(url.absoluteString) — htmlBytes=\(html.count) detected=\(detectedBook != nil) ignored=\(ignoredBookURLs.contains(url.absoluteString))")
#endif
        guard replacementCandidate == nil,
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

        startImport(candidate, isReplacing: false)
    }

    private func startImport(_ candidate: WebBookCandidate, isReplacing: Bool) {
        ignoredBookURLs.insert(candidate.sourceURL.absoluteString)
        importStatus = BrowserImportStatus(title: candidate.title)

        Task {
            do {
                let enrichedCandidate = await enrichedCandidateForImport(candidate)
                let novel = try await BookImportService.shared.importBook(from: enrichedCandidate)
                let inserted = libraryStore.addImportedNovel(novel)
                importStatus = nil
                importResult = BrowserImportResult(
                    message: isReplacing
                        ? "《\(novel.title)》已替换书架中的旧记录，共 \(novel.chapters.count) 章。打开章节时会联网加载正文。"
                        : inserted
                        ? "《\(novel.title)》已加入「\(LibraryStore.uncategorizedName)」，共 \(novel.chapters.count) 章。打开章节时会联网加载正文。"
                        : "《\(novel.title)》已经在书架中。"
                )
            } catch {
                importStatus = nil
                importResult = BrowserImportResult(message: error.localizedDescription)
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

    private func importPromptMessage(for candidate: WebBookCandidate) -> String {
        "是否将《\(candidate.title)》导入到书架的「\(LibraryStore.uncategorizedName)」分类？"
    }

    private func importOverlay(status: BrowserImportStatus) -> some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(spacing: 12) {
                ProgressView()
                    .tint(Color.readerAccent)

                Text("正在导入《\(status.title)》")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.readerInk)
                    .multilineTextAlignment(.center)

                Text("正在保存书籍信息和章节目录。正文会在阅读时加载。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.readerMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(18)
            .frame(maxWidth: 320)
            .background(Color.readerSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 12)
            .padding(.horizontal, 28)
        }
    }

    private func importResultOverlay(result: BrowserImportResult) -> some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 14) {
                Text("导入结果")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.readerInk)

                Text(result.message)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.readerMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    importResult = nil
                } label: {
                    OverlayActionLabel(title: "好", style: .primary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .frame(maxWidth: 340, alignment: .leading)
            .background(Color.readerSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 12)
            .padding(.horizontal, 28)
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
                .foregroundStyle(Color.readerMuted)
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
        .foregroundStyle(Color.readerAccent)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(
            Color.readerBackground.ignoresSafeArea()
        )
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(Color.readerMuted.opacity(0.18))
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

        state.attach(webView)
        context.coordinator.observe(webView)
        webView.load(URLRequest(url: url))

        return webView
    }

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

private struct OverlayActionLabel: View {
    enum Style { case primary, secondary }

    let title: String
    let style: Style

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: style == .primary ? .bold : .semibold))
            .foregroundStyle(style == .primary ? Color.readerSurface : Color.readerMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(style == .primary ? Color.readerAccent : Color.readerBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
    }
}

private struct BrowserImportStatus: Equatable {
    let title: String
}

private struct BrowserImportResult: Identifiable {
    let id = UUID()
    let message: String
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
