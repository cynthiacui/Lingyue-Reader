import Foundation

/// Persistence + editing surface for user-authored source rules. Used by
/// Settings → Sources and the Add-source flow. Runtime consumers
/// (Discovery, reader) do not see this — they go through
/// `BookSourceRegistry` and `BookSource` instead, so editing concerns are
/// orthogonal to runtime concerns.
public protocol EditableSourceStore: Sendable {
    /// Load all editable rules. Returned in user-visible priority order.
    func loadEditableSources() async throws -> [SourceRule]

    /// Insert or replace a single rule by its `id`. Implementations should
    /// be atomic — partial writes after a crash must leave the store in a
    /// valid state.
    func saveEditableSource(_ rule: SourceRule) async throws

    /// Remove a rule by id. No-ops if the id is unknown.
    func deleteSource(id: UUID) async throws

    /// Bulk replace — used by import-from-file flows. Implementations
    /// should treat this as a single transaction.
    func replaceAll(_ rules: [SourceRule]) async throws
}
