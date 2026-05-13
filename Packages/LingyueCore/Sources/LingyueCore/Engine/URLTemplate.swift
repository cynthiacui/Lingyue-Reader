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
    public static func expand(_ template: String, query: String) throws -> String {
        let encoded = query.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? query

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
}
