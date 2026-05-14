import Foundation

/// `{query}` substitution for `SearchStep.urlTemplate` and
/// `SearchStep.bodyTemplate`. Pure data — never `eval`s anything.
///
/// Rejects unknown placeholders at expand time so authoring errors
/// surface as a clear `ruleIncomplete` rather than as a malformed
/// request. Only one placeholder is supported today (`{query}`); when we
/// add `{page}` or `{cookie}` later, extend `allowedPlaceholders`.
public enum URLTemplate {
    public static let allowedPlaceholders: Set<String> = ["query"]

    /// Expand a template by substituting `{query}` with `query`,
    /// percent-encoded with `.urlQueryAllowed`. Throws
    /// `BookSourceError.ruleIncomplete` if the template contains an
    /// unknown placeholder.
    ///
    /// `encoding` controls the byte representation of the query before
    /// percent-encoding. `.utf8` (the default) is the common path. For
    /// legacy mainland CMS deployments that decode form fields as
    /// GB18030/GBK server-side, pass the rule's `queryEncoding` so the
    /// percent-escaped bytes match what the server expects.
    public static func expand(
        _ template: String,
        query: String,
        encoding: SourceEncoding = .utf8
    ) throws -> String {
        let encoded = percentEncode(query: query, using: encoding)

        var output = ""
        output.reserveCapacity(template.count + encoded.count)

        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            if c == "{" {
                guard let close = template[i...].firstIndex(of: "}") else {
                    output.append(c)
                    i = template.index(after: i)
                    continue
                }
                let nameRange = template.index(after: i)..<close
                let name = String(template[nameRange])
                guard allowedPlaceholders.contains(name) else {
                    throw BookSourceError.ruleIncomplete(
                        field: "urlTemplate placeholder {\(name)}"
                    )
                }
                switch name {
                case "query":
                    output.append(encoded)
                default:
                    // unreachable while allowedPlaceholders == ["query"];
                    // listed so the switch stays exhaustive as we grow.
                    throw BookSourceError.ruleIncomplete(
                        field: "urlTemplate placeholder {\(name)}"
                    )
                }
                i = template.index(after: close)
            } else {
                output.append(c)
                i = template.index(after: i)
            }
        }
        return output
    }

    /// Percent-encode `query` using `encoding`'s byte representation.
    /// UTF-8 takes the standard `addingPercentEncoding` fast path. Non-UTF-8
    /// encodings round-trip through `String.data(using:)` then percent-escape
    /// every byte that isn't in `.urlQueryAllowed` (ASCII URL-safe set), so
    /// `é` in GB18030 becomes `%E9` not `%C3%A9`. Characters that don't
    /// round-trip into the target encoding are dropped (`allowLossyConversion:
    /// true`), matching what browsers do when a legacy form posts a character
    /// the charset can't represent.
    private static func percentEncode(query: String, using encoding: SourceEncoding) -> String {
        if encoding == .utf8 || encoding == .auto {
            return query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        }
        guard
            let stringEncoding = encoding.stringEncoding,
            let data = query.data(using: stringEncoding, allowLossyConversion: true)
        else {
            return query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        }
        let allowed = CharacterSet.urlQueryAllowed
        var out = ""
        out.reserveCapacity(data.count * 3)
        for byte in data {
            if let scalar = Unicode.Scalar(UInt32(byte)),
               byte < 0x80,
               allowed.contains(scalar) {
                out.append(Character(scalar))
            } else {
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }
}
