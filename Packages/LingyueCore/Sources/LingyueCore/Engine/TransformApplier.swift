import Foundation

/// Applies a `[SourceTransform]` chain to a string. One switch over the
/// closed enum; nothing here interprets code. The rule editor surfaces
/// authoring errors (bad regex) by routing the thrown `parseFailed`
/// back to the form.
///
/// Transforms run left-to-right in the order the rule lists them. The
/// engine builds the chain; callers pass values already extracted by
/// `SelectorEngine`.
public enum TransformApplier {
    /// Apply `transforms` to `value` in order. `baseURL` is required by
    /// `.absoluteURL` to resolve relative hrefs; pass the page's
    /// `finalURL` when applying a chain pulled from a `FieldSelector`.
    public static func apply(
        _ transforms: [SourceTransform],
        to value: String,
        baseURL: URL?
    ) throws -> String {
        var v = value
        for t in transforms {
            v = try applyOne(t, to: v, baseURL: baseURL)
        }
        return v
    }

    // MARK: -

    private static func applyOne(
        _ transform: SourceTransform,
        to value: String,
        baseURL: URL?
    ) throws -> String {
        switch transform {
        case .trim:
            return collapseInteriorWhitespace(value.trimmingCharacters(in: .whitespacesAndNewlines))

        case .collapseWhitespace:
            return collapseInteriorWhitespace(value)

        case .absoluteURL:
            return resolveAbsolute(value, baseURL: baseURL)

        case let .regexReplace(pattern, replacement):
            let regex = try compile(pattern: pattern)
            let range = NSRange(value.startIndex..., in: value)
            return regex.stringByReplacingMatches(
                in: value,
                options: [],
                range: range,
                withTemplate: replacement
            )

        case let .regexCapture(pattern):
            let regex = try compile(pattern: pattern)
            let range = NSRange(value.startIndex..., in: value)
            guard
                let match = regex.firstMatch(in: value, options: [], range: range),
                match.numberOfRanges > 1,
                let captureRange = Range(match.range(at: 1), in: value)
            else {
                return ""
            }
            return String(value[captureRange])

        case .stripHTML:
            return stripHTMLTags(value)

        case .brToNewline:
            // Match `<br>`, `<br/>`, `<br />` case-insensitively.
            let pattern = "<\\s*br\\s*/?\\s*>"
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                return value
            }
            let range = NSRange(value.startIndex..., in: value)
            return regex.stringByReplacingMatches(
                in: value,
                options: [],
                range: range,
                withTemplate: "\n"
            )

        case let .prefix(s):
            return s + value

        case let .suffix(s):
            return value + s

        case .decodeHTMLEntities:
            return decodeEntities(value)
        }
    }

    // MARK: - Helpers

    private static func compile(pattern: String) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            throw BookSourceError.parseFailed(field: "regex /\(pattern)/")
        }
    }

    private static func collapseInteriorWhitespace(_ s: String) -> String {
        // Collapse runs of any whitespace (incl. NBSP, ideographic space) to one regular space.
        let nbsp: Character = "\u{00A0}"
        let ideographic: Character = "\u{3000}"
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasWS = false
        for c in s {
            let isWS = c.isWhitespace || c == nbsp || c == ideographic
            if isWS {
                if !lastWasWS && !out.isEmpty {
                    out.append(" ")
                }
                lastWasWS = true
            } else {
                out.append(c)
                lastWasWS = false
            }
        }
        if out.last == " " { out.removeLast() }
        return out
    }

    private static func resolveAbsolute(_ value: String, baseURL: URL?) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = baseURL else { return trimmed }
        if let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL {
            return resolved.absoluteString
        }
        return trimmed
    }

    private static func stripHTMLTags(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else {
            return s
        }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(
            in: s,
            options: [],
            range: range,
            withTemplate: ""
        )
    }

    private static func decodeEntities(_ s: String) -> String {
        // Handle the common-five plus &nbsp;, plus numeric / hex entities.
        var out = s
        let named: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&nbsp;", " ")
        ]
        for (k, v) in named {
            out = out.replacingOccurrences(of: k, with: v)
        }
        // Numeric: &#NNNN;
        out = replaceMatches(in: out, pattern: "&#([0-9]+);") { hexStr in
            guard let scalar = UInt32(hexStr).flatMap(Unicode.Scalar.init) else { return nil }
            return String(scalar)
        }
        // Hex: &#xHHHH;
        out = replaceMatches(in: out, pattern: "&#[xX]([0-9a-fA-F]+);") { hexStr in
            guard let scalar = UInt32(hexStr, radix: 16).flatMap(Unicode.Scalar.init) else { return nil }
            return String(scalar)
        }
        return out
    }

    private static func replaceMatches(
        in input: String,
        pattern: String,
        replacement: (String) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }
        let nsInput = input as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        var result = ""
        var cursor = 0
        regex.enumerateMatches(in: input, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            let fullRange = match.range
            let captureRange = match.range(at: 1)
            result += nsInput.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))
            let captured = nsInput.substring(with: captureRange)
            if let replaced = replacement(captured) {
                result += replaced
            } else {
                result += nsInput.substring(with: fullRange)
            }
            cursor = fullRange.location + fullRange.length
        }
        if cursor < nsInput.length {
            result += nsInput.substring(with: NSRange(location: cursor, length: nsInput.length - cursor))
        }
        return result
    }
}
