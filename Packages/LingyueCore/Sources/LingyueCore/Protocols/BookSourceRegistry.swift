import Foundation

/// Aggregator of currently-enabled `BookSource`s. The Discovery search bar
/// and the in-app browser's detector each obtain their working set through
/// this protocol — they never instantiate sources themselves.
public protocol BookSourceRegistry: Sendable {
    /// Snapshot of currently-enabled sources, in user-visible priority
    /// order. Implementations should be reasonably cheap to call
    /// repeatedly — caches are encouraged.
    func enabledSources() async throws -> [any BookSource]

    /// Convenience subset used by the Discovery search bar: only sources
    /// whose `capabilities.supportsSearch` is true and whose
    /// `showInSearchBar` flag is set.
    func searchableSources() async throws -> [any BookSource]

    /// Look up a single source by its namespaced id. Used by deep links,
    /// diagnostics, and the reader when reopening a previously imported
    /// book whose source must still be reachable.
    func source(withID id: String) async throws -> (any BookSource)?
}
