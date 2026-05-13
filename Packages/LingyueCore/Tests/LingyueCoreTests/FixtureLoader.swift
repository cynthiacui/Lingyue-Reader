import Foundation
@testable import LingyueCore

/// Test stub for `SourceHTMLLoading`. Resolves requests to fixture HTML
/// files on disk by exact URL string. Used to drive `RuleBasedBookSource`
/// end-to-end against canned pages, so the rule engine is exercised
/// without ever touching the network.
struct FixtureLoader: SourceHTMLLoading {
    let baseDirectory: URL
    let mapping: [String: String]

    func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        try snapshot(for: request.url)
    }

    func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        try snapshot(for: request.url)
    }

    private func snapshot(for url: URL) throws -> WebPageSnapshot {
        let key = url.absoluteString
        guard let filename = mapping[key] else {
            throw BookSourceError.unsupportedURL(url)
        }
        let fileURL = baseDirectory.appendingPathComponent(filename)
        let html = try String(contentsOf: fileURL, encoding: .utf8)
        return WebPageSnapshot(
            html: html,
            finalURL: url,
            responseHeaders: [:],
            statusCode: 200
        )
    }
}
