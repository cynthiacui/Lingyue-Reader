import Foundation
import LingyueCore

/// Entry point + diagnostics for the `LingyueInternalSources` package.
///
/// Runtime consumers reach the seeded rule set and fast-path adapters
/// through `InternalSourceRegistry` rather than this enum — that's
/// where `BookSource` instances are constructed against a real loader.
/// The helpers here are for diagnostics and for tests that want a
/// rule-list snapshot without paying for HTML loading.
public enum LingyueInternalSources {
    /// Version of the seeded rule bundle this binary carries. Bump when
    /// the bundled rules ship a new schema or new entries. Surfaced in
    /// diagnostics, not user-visible.
    public static let bundledRulesVersion: Int = 1

    /// Decode every bundled `SourceRule` JSON. Convenience over
    /// `SeededRuleLoader.loadAll().rules` for callers that just want
    /// the rule list.
    public static func bundledRules() -> [SourceRule] {
        SeededRuleLoader.loadAll().rules
    }
}
