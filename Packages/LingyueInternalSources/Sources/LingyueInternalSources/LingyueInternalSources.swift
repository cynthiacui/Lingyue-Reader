import Foundation
import LingyueCore

/// Phase 0 stub. The real `InternalSourceRegistry`, fast-path adapters,
/// and seeded rule bundles land in Phase 2 once the rule engine
/// (`RuleBasedBookSource`) is in place.
///
/// This file exists so the package builds with an empty source list, and
/// so anyone grepping for an entry point lands here first.
public enum LingyueInternalSources {
    /// Version of the seeded rule bundle this binary carries. Bumped when
    /// the bundled rules ship a new schema or new entries. Surfaced in
    /// diagnostics, not user-visible.
    public static let bundledRulesVersion: Int = 0

    /// Phase-0 placeholder. Returns an empty array until the seeded
    /// bundle and fast-path adapters land.
    public static func bundledSources() -> [any BookSource] { [] }
}
