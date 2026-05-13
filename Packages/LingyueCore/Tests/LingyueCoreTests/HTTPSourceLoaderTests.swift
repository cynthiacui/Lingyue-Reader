import XCTest
@testable import LingyueCore

/// `URLProtocol`-stubbed tests for `HTTPSourceLoader`. The stub intercepts
/// every request made on the configured session, lets the test assert on
/// the outgoing URLRequest, and returns canned (status, headers, body).
/// This exercises request building, redirect-aware final URL, status
/// pass-through, header lowercasing, and encoding decoding without
/// touching the network.
final class HTTPSourceLoaderTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testFetchHTMLDecodesUTF8AndPassesThroughStatus() async throws {
        let url = URL(string: "https://example.test/page")!
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.url, url)
            XCTAssertEqual(req.httpMethod, "GET")
            let body = "<html>hello</html>".data(using: .utf8)!
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, body)
        }
        let loader = HTTPSourceLoader(session: makeSession())
        let snapshot = try await loader.fetchHTML(
            SourceRequest(url: url, encoding: .auto)
        )
        XCTAssertEqual(snapshot.html, "<html>hello</html>")
        XCTAssertEqual(snapshot.finalURL, url)
        XCTAssertEqual(snapshot.statusCode, 200)
        XCTAssertEqual(snapshot.responseHeaders["content-type"], "text/html; charset=utf-8")
    }

    func testFetchHTMLAppliesRefererAndCustomHeaders() async throws {
        let url = URL(string: "https://example.test/page")!
        let referer = URL(string: "https://example.test/")!
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Referer"), referer.absoluteString)
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Test"), "abc")
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [:]
            )!
            return (response, Data())
        }
        let loader = HTTPSourceLoader(session: makeSession())
        _ = try await loader.fetchHTML(
            SourceRequest(
                url: url,
                method: .get,
                headers: ["X-Test": "abc"],
                referer: referer
            )
        )
    }

    func testFetchHTMLDecodesExplicitGBK() async throws {
        let url = URL(string: "https://example.test/cn")!
        let gbkEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GBK_95.rawValue)
            )
        )
        let body = "你好世界".data(using: gbkEncoding)!
        StubURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, body)
        }
        let loader = HTTPSourceLoader(session: makeSession())
        let snapshot = try await loader.fetchHTML(
            SourceRequest(url: url, encoding: .gbk)
        )
        XCTAssertEqual(snapshot.html, "你好世界")
    }

    func testFetchHTMLHonorsContentTypeCharsetOnAuto() async throws {
        let url = URL(string: "https://example.test/cn")!
        let gbkEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GBK_95.rawValue)
            )
        )
        let body = "测试".data(using: gbkEncoding)!
        StubURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=GBK"]
            )!
            return (response, body)
        }
        let loader = HTTPSourceLoader(session: makeSession())
        let snapshot = try await loader.fetchHTML(
            SourceRequest(url: url, encoding: .auto)
        )
        XCTAssertEqual(snapshot.html, "测试")
    }

    func testPostSendsBody() async throws {
        let url = URL(string: "https://example.test/search")!
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            // URLProtocol presents the body via httpBodyStream rather than
            // httpBody when issued through URLSession. Drain it.
            let body = req.httpBodyStream.map { Self.drain($0) } ?? req.httpBody ?? Data()
            XCTAssertEqual(String(data: body, encoding: .utf8), "q=hello")
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [:]
            )!
            return (response, "OK".data(using: .utf8)!)
        }
        let loader = HTTPSourceLoader(session: makeSession())
        let snapshot = try await loader.fetchHTML(
            SourceRequest(
                url: url,
                method: .post,
                body: "q=hello".data(using: .utf8)
            )
        )
        XCTAssertEqual(snapshot.html, "OK")
    }

    func testRenderHTMLThrows() async {
        let loader = HTTPSourceLoader()
        do {
            _ = try await loader.renderHTML(
                SourceRequest(url: URL(string: "https://example.test/")!)
            )
            XCTFail("renderHTML should have thrown")
        } catch let error as BookSourceError {
            if case .loadFailed = error {
                // expected
            } else {
                XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var buf = [UInt8](repeating: 0, count: 1024)
        var out = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: buf.count)
            if read <= 0 { break }
            out.append(buf, count: read)
        }
        return out
    }
}

// MARK: - URLProtocol stub

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    nonisolated(unsafe) static var handler: Handler?

    static func reset() { handler = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL)
            )
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
