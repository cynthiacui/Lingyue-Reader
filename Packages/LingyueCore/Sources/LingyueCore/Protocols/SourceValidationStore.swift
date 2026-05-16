import Foundation
import CryptoKit

/// Block of a `SourceRule` that the validation pipeline scores
/// independently. The Review screen renders one row per block; the
/// validation store persists one test record per block.
public enum SourceBlock: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case search, detail, catalog, chapter
    public var id: String { rawValue }
}

/// Outcome of the last manual Test for a single block. `.notRun` is the
/// default for any block the user hasn't yet tested; `.passed` /
/// `.failed` reflect the most recent `SourceTestSheet` run.
public enum BlockTestStatus: String, Sendable, Hashable, Codable {
    case notRun, passed, failed
}

/// Per-block test history record. `inputFingerprint` captures the
/// rule's block-relevant shape at the time the test ran so a later
/// schema edit can invalidate the recorded pass automatically — see
/// `SourceValidationStore.statusEffective(_:rule:)`.
public struct BlockTestRecord: Sendable, Hashable, Codable {
    public var status: BlockTestStatus
    public var lastRunAt: Date
    public var failureSummary: String?
    public var inputFingerprint: String

    public init(
        status: BlockTestStatus,
        lastRunAt: Date,
        failureSummary: String? = nil,
        inputFingerprint: String
    ) {
        self.status = status
        self.lastRunAt = lastRunAt
        self.failureSummary = failureSummary
        self.inputFingerprint = inputFingerprint
    }
}

/// Aggregate validation state for a single rule. Keyed by `ruleID` so
/// the store is a flat dictionary on disk.
///
/// Phase 3 closeout keeps the analyzer's `AnalysisReport` in memory on
/// the Review screen only — it isn't persisted here. The Review screen
/// combines an in-session report with `tests[block]` to compute
/// `effectiveStatus`; reopening a rule from the Sources list starts
/// with a fresh blank report. Persisting the report (so a row-tap
/// reopen still shows analyzer pills) is a follow-up — see PHASES.md
/// §3.5.1 note. Storing only test history keeps this type free of
/// cross-target type dependencies and the JSON file forward-compatible.
public struct SourceValidation: Sendable, Hashable, Codable {
    public var ruleID: UUID
    public var tests: [SourceBlock: BlockTestRecord]
    public var updatedAt: Date

    public init(
        ruleID: UUID,
        tests: [SourceBlock: BlockTestRecord] = [:],
        updatedAt: Date = Date()
    ) {
        self.ruleID = ruleID
        self.tests = tests
        self.updatedAt = updatedAt
    }
}

/// Persistence surface for `SourceValidation` records. Backed by a
/// local file in production — see app-target `FileSourceValidationStore`.
///
/// **Device-local by design.** The Phase 3.2 JSON-import flow moves
/// rules between installs but never carries validation state with them;
/// an imported rule lands with no record here and the user must Test
/// before Enable. "Passed on my device" is not the same as "passed on
/// yours" — PHASES.md §3.5.1.
public protocol SourceValidationStore: Sendable {
    /// Full snapshot, keyed by `ruleID`. Used by Sources-list refresh
    /// and Review-screen mount.
    func loadAll() async throws -> [UUID: SourceValidation]

    /// Read a single rule's record, or nil when no tests have ever
    /// been recorded for it. Convenience over `loadAll` for hot paths.
    func load(ruleID: UUID) async throws -> SourceValidation?

    /// Write one block's test outcome. Implementations merge into the
    /// existing record for the rule (or create one). `updatedAt` is
    /// refreshed on every call.
    func recordTest(
        ruleID: UUID,
        block: SourceBlock,
        record: BlockTestRecord
    ) async throws

    /// Drop a rule's record — used when the user deletes the rule.
    /// No-op when the rule id is unknown.
    func delete(ruleID: UUID) async throws
}

public extension SourceValidationStore {
    /// Resolve the *effective* status of a block for a rule. Returns
    /// `.notRun` (i.e. "needs check") when no record exists yet OR when
    /// the recorded `inputFingerprint` no longer matches the rule's
    /// current fingerprint for that block. The store never silently
    /// rewrites stale records: they live on disk until the user
    /// re-tests, but `statusEffective` won't count them.
    func statusEffective(_ block: SourceBlock, rule: SourceRule) async throws -> BlockTestStatus {
        let record = try await load(ruleID: rule.id)?.tests[block]
        guard let record else { return .notRun }
        let current = rule.blockFingerprint(block)
        return current == record.inputFingerprint ? record.status : .notRun
    }
}

// MARK: - Block fingerprints

public extension SourceRule {
    /// Stable, deterministic fingerprint of the rule's block-relevant
    /// shape. Two rules with the same `search` definition (or both
    /// missing one) produce the same fingerprint for `.search`. The
    /// validation store uses this to invalidate test passes when the
    /// user edits selectors / transforms / templates inside the block.
    func blockFingerprint(_ block: SourceBlock) -> String {
        switch block {
        case .search: return Self.sha256(of: search)
        case .detail: return Self.sha256(of: detail)
        case .catalog: return Self.sha256(of: catalog)
        case .chapter: return Self.sha256(of: chapter)
        }
    }

    private static func sha256<T: Encodable>(of value: T) -> String {
        // Wrap in a single-field object so the top-level container is
        // always present (JSONEncoder rejects top-level Optional /
        // primitive). Sorted keys give canonical output — two
        // encodings of equal values produce byte-identical JSON
        // regardless of field-order quirks. Without canonicalization
        // the fingerprint would flip on every re-encode and
        // stale-detection would fire constantly.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(FingerprintEnvelope(v: value)))
            ?? Data("nil".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct FingerprintEnvelope<V: Encodable>: Encodable {
    let v: V
}
