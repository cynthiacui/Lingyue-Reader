import Foundation

/// Text encoding to apply when decoding response bytes. Some Chinese
/// novel sites still serve GB18030 / GBK content with a misleading
/// `Content-Type` header, so the rule must be able to declare encoding
/// explicitly. Hoisted to the top level (rather than nested inside
/// `SourceRule`) so lower-level types like `SourceRequest` can refer to
/// it without depending on the rule schema.
public enum SourceEncoding: String, Codable, Sendable, Hashable, CaseIterable {
    /// Let the loader sniff `Content-Type` and BOMs. Default for well-behaved
    /// sites.
    case auto
    case utf8
    case gb18030
    case gbk
    case big5

    /// Canonical IANA charset name. `auto` returns `nil` to signal the
    /// loader should sniff.
    public var ianaName: String? {
        switch self {
        case .auto: return nil
        case .utf8: return "utf-8"
        case .gb18030: return "gb18030"
        case .gbk: return "gbk"
        case .big5: return "big5"
        }
    }
}
