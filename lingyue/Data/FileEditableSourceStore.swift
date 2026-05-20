import Foundation
import LingyueCore

/// On-disk `EditableSourceStore` backed by a single JSON file at
/// `Application Support/lingyue/user-sources.json`. Both registries
/// (`InternalSourceRegistry` and `AppStoreSourceRegistry`) read from
/// this store, so a rule the user authors is visible to whichever
/// target is running. Each target keeps its own sandboxed copy of the
/// file — iOS isolates `Application Support` per bundle ID — which is
/// the intentional Phase 5 behaviour.
///
/// Writes go through `Data.write(options: .atomic)`: the new content
/// lands in a temp file in the same directory, then `rename(2)`s on top
/// of the target. A crash mid-write leaves either the previous version
/// or the new version on disk — never a partial JSON. We also persist
/// pretty-printed, sorted keys so the file is git-diffable when a user
/// shares one out-of-band.
///
/// Concurrency: the type is an `actor` so the protocol's `Sendable`
/// requirement holds and concurrent saves cannot race the same file.
public actor FileEditableSourceStore: EditableSourceStore {
    private let fileURL: URL
    private var cache: [SourceRule]?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = Self.defaultFileURL()
        }
    }

    public func loadEditableSources() async throws -> [SourceRule] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            return []
        }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            cache = []
            return []
        }
        let rules = try JSONDecoder().decode([SourceRule].self, from: data)
        let (migrated, didMigrate) = Self.applyMigrations(to: rules)
        if didMigrate {
            try persist(migrated)
            return migrated
        }
        cache = rules
        return rules
    }

    /// One-shot rewrites for rules already on disk. Each migration matches
    /// an exact stale value so we never touch a user's hand-edited copy,
    /// and re-running the migration on already-migrated data is a no-op.
    ///
    /// Currently rewrites: the 笔趣阁 (json-api:biquge-api) search step's
    /// `detailURLTemplate`, which used to synthesize `bqgl.cc/look/{id}/`
    /// URLs. Those IDs are apiqu.cc's, not bqgl.cc's — every search-result
    /// click landed on the wrong book or a 404. The new template points
    /// at the bqg303.xyz SPA mirror, which shares apiqu's backend.
    static func applyMigrations(to rules: [SourceRule]) -> ([SourceRule], Bool) {
        let staleBiqugeTemplate = "https://www.bqgl.cc/look/{id}/"
        let newBiqugeTemplate = "https://9b0.bqg303.xyz/#/book/{id}/"
        var didMigrate = false
        let migrated: [SourceRule] = rules.map { rule in
            guard var jsonAPI = rule.jsonAPI,
                  var search = jsonAPI.search,
                  search.detailURLTemplate == staleBiqugeTemplate
            else { return rule }
            search.detailURLTemplate = newBiqugeTemplate
            jsonAPI.search = search
            didMigrate = true
            var copy = rule
            copy.jsonAPI = jsonAPI
            return copy
        }
        return (migrated, didMigrate)
    }

    public func saveEditableSource(_ rule: SourceRule) async throws {
        var rules = try await loadEditableSources()
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
        } else {
            rules.append(rule)
        }
        try persist(rules)
    }

    public func deleteSource(id: UUID) async throws {
        var rules = try await loadEditableSources()
        rules.removeAll { $0.id == id }
        try persist(rules)
    }

    public func replaceAll(_ rules: [SourceRule]) async throws {
        try persist(rules)
    }

    // MARK: - Persistence

    private func persist(_ rules: [SourceRule]) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        try data.write(to: fileURL, options: .atomic)
        cache = rules
    }

    private func ensureDirectoryExists() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
    }

    /// Default location: `Application Support/lingyue/user-sources.json`.
    /// The subfolder name is lowercase to match `LibraryStore`'s
    /// `Application Support/lingyue/` — sharing the same directory entry
    /// avoids a case-only collision on the case-insensitive iOS
    /// filesystem, which has been observed to put `createDirectory` into
    /// an EIO state on iOS 26 simulator builds.
    /// Falls back to the documents dir if Application Support is
    /// unavailable for some reason — should never happen on iOS, but
    /// the fallback keeps unit-test environments happy without a
    /// special case.
    private static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("lingyue", isDirectory: true)
            .appendingPathComponent("user-sources.json")
    }
}
