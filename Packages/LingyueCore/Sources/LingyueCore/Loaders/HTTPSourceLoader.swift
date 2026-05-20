import Foundation

/// `URLSession`-based `SourceHTMLLoading`. Issues a plain HTTP request,
/// decodes the body using the rule's declared `SourceEncoding`, and
/// returns a `WebPageSnapshot`. Pure Foundation — no `WebKit`, no
/// `UIKit` — so it lives in `LingyueCore` and is unit-testable with a
/// `URLProtocol` stub.
///
/// Engine selection per step is the caller's responsibility. When a rule
/// asserts `.web` for a step, runtime composes this loader with a
/// `WKWebView`-backed loader behind one `SourceHTMLLoading` (see
/// `CompositeSourceLoader` in the app target). On its own, this loader's
/// `renderHTML` throws — calling it for a render step is a programming
/// error.
public struct HTTPSourceLoader: SourceHTMLLoading {
    private let session: URLSession
    private let defaultUserAgent: String?

    public init(session: URLSession = .shared, defaultUserAgent: String? = nil) {
        self.session = session
        self.defaultUserAgent = defaultUserAgent
    }

    public func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        // iOS App Transport Security blocks plain `http://` for URLSession
        // even when WKWebView is allowed. Many seeded sites serve HTTPS
        // but ship `<link rel=canonical href="http://...">` and `<a
        // href="http://...">` in their HTML; passing those URLs through
        // unchanged would yield `loadFailed` for every rule's
        // fetchDetail / fetchCatalog. All 10 seeded hosts serve HTTPS
        // (survey 2026-05-14), so upgrading the scheme unconditionally
        // is strictly an improvement over the alternative.
        let requestURL = Self.upgradedToHTTPS(request.url)
        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = request.method.rawValue
        if let agent = defaultUserAgent, urlRequest.value(forHTTPHeaderField: "User-Agent") == nil {
            urlRequest.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        if let referer = request.referer {
            urlRequest.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if request.method == .post {
            urlRequest.httpBody = request.body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw BookSourceError.loadFailed(reason: "\(error)")
        }

        let httpResponse = response as? HTTPURLResponse
        let finalURL = response.url ?? requestURL
        let encoding = stringEncoding(for: request.encoding, response: httpResponse)
        let html: String
        if let decoded = String(data: data, encoding: encoding) {
            html = decoded
        } else if let decoded = Self.decodeWithFallbacks(data: data, preferred: encoding) {
            html = decoded
        } else {
            throw BookSourceError.loadFailed(
                reason: "could not decode body as \(request.encoding.rawValue)"
            )
        }
        return WebPageSnapshot(
            html: html,
            finalURL: finalURL,
            responseHeaders: lowercasedHeaders(from: httpResponse),
            statusCode: httpResponse?.statusCode
        )
    }

    public func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        throw BookSourceError.loadFailed(
            reason: "HTTPSourceLoader does not perform headless rendering"
        )
    }

    // MARK: - URL hygiene

    private static func upgradedToHTTPS(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http" else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? url
    }

    // MARK: - Encoding

    private func stringEncoding(
        for sourceEncoding: SourceEncoding,
        response: HTTPURLResponse?
    ) -> String.Encoding {
        switch sourceEncoding {
        case .utf8: return .utf8
        case .gb18030: return Self.cf(.GB_18030_2000)
        case .gbk: return Self.cf(.GBK_95)
        case .big5: return Self.cf(.big5_HKSCS_1999)
        case .auto:
            if
                let header = response?.value(forHTTPHeaderField: "Content-Type"),
                let charset = Self.charsetParameter(in: header),
                let encoding = Self.stringEncoding(charsetName: charset)
            {
                return encoding
            }
            return .utf8
        }
    }

    /// Try common CJK encodings when the declared one fails. Some sites
    /// mis-declare their charset (e.g. `charset=big5` for an HKSCS-extended
    /// page, or `charset=utf-8` for a GBK page). Walking a small ordered
    /// list of candidates is cheaper than reporting failure and is
    /// invisible when the preferred encoding decodes cleanly.
    private static func decodeWithFallbacks(data: Data, preferred: String.Encoding) -> String? {
        let candidates: [String.Encoding] = [
            .utf8,
            cf(.big5_HKSCS_1999),
            cf(.GB_18030_2000),
            cf(.GBK_95),
            .isoLatin1,
        ]
        for encoding in candidates where encoding != preferred {
            if let decoded = String(data: data, encoding: encoding) { return decoded }
        }
        return nil
    }

    private static func cf(_ cf: CFStringEncodings) -> String.Encoding {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue))
        return String.Encoding(rawValue: raw)
    }

    private static func charsetParameter(in contentType: String) -> String? {
        guard let range = contentType.range(of: "charset=", options: .caseInsensitive) else {
            return nil
        }
        let tail = contentType[range.upperBound...]
        let charset = tail.prefix(while: { c in
            c.isLetter || c.isNumber || c == "-" || c == "_"
        })
        return charset.isEmpty ? nil : String(charset)
    }

    private static func stringEncoding(charsetName: String) -> String.Encoding? {
        let normalized = charsetName.lowercased()
        switch normalized {
        case "utf-8", "utf8": return .utf8
        case "gb2312", "gbk": return cf(.GBK_95)
        case "gb18030": return cf(.GB_18030_2000)
        case "big5", "big5-hkscs", "cp950": return cf(.big5_HKSCS_1999)
        case "iso-8859-1", "latin1": return .isoLatin1
        default:
            let raw = CFStringConvertEncodingToNSStringEncoding(
                CFStringConvertIANACharSetNameToEncoding(normalized as CFString)
            )
            if raw == kCFStringEncodingInvalidId { return nil }
            return String.Encoding(rawValue: raw)
        }
    }

    private func lowercasedHeaders(from response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = (key as? String)?.lowercased(), let v = value as? String {
                out[k] = v
            }
        }
        return out
    }
}
