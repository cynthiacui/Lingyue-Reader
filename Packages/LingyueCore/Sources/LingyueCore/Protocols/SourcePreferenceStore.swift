import Foundation

/// Per-install user preference for a single rule. Keyed by `SourceRule.id`
/// so a seeded rule and its user-override copy share preference (both
/// rules carry the same UUID — the override is a refinement, not a fork).
///
/// Lives outside `SourceRule` on purpose: rule JSON is portable across
/// installs and across users (the JSON import flow in Phase 3.2 moves it
/// between people), so it cannot encode anything that belongs to a single
/// install's view of "which sources do I want enabled, in what order."
public struct SourcePreference: Sendable, Hashable, Codable {
    public var ruleID: UUID

    /// User-facing enable/disable. The default for an unknown rule (i.e.
    /// one the user has never expressed an opinion about) is `true` —
    /// see `SourcePreferenceStore.isEnabled(_:)`.
    public var isEnabled: Bool

    /// Smaller values come earlier in the user-visible list. Tests should
    /// not rely on specific values — only ordering. Default for unknown
    /// rules is `Int.max`, so freshly-seeded rules sink to the bottom
    /// until the user re-orders them; the registry's secondary sort by
    /// `displayName` then provides a stable ordering inside that bucket.
    public var priority: Int

    /// Bookkeeping for diagnostics + future "recently changed" surfaces.
    public var updatedAt: Date

    public init(
        ruleID: UUID,
        isEnabled: Bool = true,
        priority: Int = .max,
        updatedAt: Date = Date()
    ) {
        self.ruleID = ruleID
        self.isEnabled = isEnabled
        self.priority = priority
        self.updatedAt = updatedAt
    }
}

/// Persistence surface for `SourcePreference` records. Backed by a local
/// file in production — see app-target `FileSourcePreferenceStore`.
///
/// Implementations must treat unknown rule IDs as "user has no opinion":
/// `isEnabled` returns `true`, `priority` returns `Int.max`. This lets
/// freshly-seeded rules show up enabled without forcing every install to
/// migrate its preference file on rule bundle updates.
public protocol SourcePreferenceStore: Sendable {
    /// Snapshot of every stored preference, keyed by `ruleID`. Order is
    /// not meaningful — callers sort on `priority` themselves.
    func loadAll() async throws -> [UUID: SourcePreference]

    /// Insert or replace a single preference. Atomicity is on the
    /// implementation.
    func save(_ preference: SourcePreference) async throws

    /// Drop a preference. No-op when the rule id is unknown — used when a
    /// rule is deleted so its preference doesn't leak forward.
    func delete(ruleID: UUID) async throws

    /// Bulk replace. Used by reset-to-defaults flows. Implementations
    /// should treat this as a single transaction.
    func replaceAll(_ preferences: [SourcePreference]) async throws
}

public extension SourcePreferenceStore {
    /// Sugar that resolves "is this rule visible to the user right now"
    /// without forcing callers to handle the missing-key case.
    func isEnabled(_ ruleID: UUID) async throws -> Bool {
        let all = try await loadAll()
        return all[ruleID]?.isEnabled ?? true
    }

    /// Sugar that resolves a rule's sort key, falling back to `Int.max`
    /// when the user has never reordered.
    func priority(_ ruleID: UUID) async throws -> Int {
        let all = try await loadAll()
        return all[ruleID]?.priority ?? .max
    }
}
