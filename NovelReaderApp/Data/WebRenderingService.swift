import Foundation
import UIKit
import WebKit

@MainActor
final class WebRenderingService: NSObject {
    static let shared = WebRenderingService()

    private let webView: WKWebView
    private var pendingNavigation: CheckedContinuation<Void, Never>?
    private var serializer: Task<Void, Never> = Task {}
    private var isAttached = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 414, height: 896),
            configuration: configuration
        )
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        super.init()
        webView.navigationDelegate = self
    }

    func renderHTML(
        at url: URL,
        settleAfter: TimeInterval = 1.5,
        timeout: TimeInterval = 12
    ) async -> String? {
        let previous = serializer
        let work = Task<String?, Never> { @MainActor [weak self] in
            _ = await previous.value
            guard let self else { return nil }
            return await self.performRender(url: url, settleAfter: settleAfter, timeout: timeout)
        }
        serializer = Task<Void, Never> { _ = await work.value }
        return await work.value
    }

    private func performRender(
        url: URL,
        settleAfter: TimeInterval,
        timeout: TimeInterval
    ) async -> String? {
        attachToWindowIfNeeded()
        webView.stopLoading()
        resumePendingNavigation()

        webView.load(URLRequest(url: url))

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                await withCheckedContinuation { continuation in
                    self.pendingNavigation = continuation
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
            }
            _ = await group.next()
            group.cancelAll()
            for await _ in group {}
        }
        resumePendingNavigation()

        try? await Task.sleep(for: .seconds(settleAfter))

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    private func resumePendingNavigation() {
        guard let continuation = pendingNavigation else { return }
        pendingNavigation = nil
        continuation.resume()
    }

    private func attachToWindowIfNeeded() {
        guard !isAttached, webView.superview == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first
        guard let window else { return }
        webView.alpha = 0.001
        webView.isUserInteractionEnabled = false
        window.addSubview(webView)
        isAttached = true
    }
}

extension WebRenderingService: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in resumePendingNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in resumePendingNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in resumePendingNavigation() }
    }
}
