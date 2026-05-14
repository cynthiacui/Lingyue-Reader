import Foundation
import LingyueCore

/// On-disk `SourcePreferenceStore` backed by a single JSON file at
/// `Application Support/Lingyue/source-preferences.json`. Mirrors
/// `FileEditableSourceStore` in storage layout and atomic-write
/// strategy so the two files behave consistently — a crash mid-write
/// leaves the previous JSON intact.
///
/// Preference state is intentionally separate from rule JSON because
/// rules travel between installs (Phase 3.2 JSON import) while
/// preferences are per-install: "which sources do I want enabled, in
/// what order" is my decision, not the rule author's. Keeping them in
/// a sibling file lets a user export rules to share without leaking
/// their on/off state to the recipient.
public actor FileSourcePreferenceStore: SourcePreferenceStore {
    private let fileURL: URL
    private var cache: [UUID: SourcePreference]?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = Self.defaultFileURL()
        }
    }

    public func loadAll() async throws -> [UUID: SourcePreference] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = [:]
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
            cache = [:]
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = try decoder.decode([SourcePreference].self, from: data)
        let map = Dictionary(uniqueKeysWithValues: list.map { ($0.ruleID, $0) })
        cache = map
        return map
    }

    public func save(_ preference: SourcePreference) async throws {
        var current = try await loadAll()
        var updated = preference
        updated.updatedAt = Date()
        current[updated.ruleID] = updated
        try persist(current)
    }

    public func delete(ruleID: UUID) async throws {
        var current = try await loadAll()
        guard current.removeValue(forKey: ruleID) != nil else { return }
        try persist(current)
    }

    public func replaceAll(_ preferences: [SourcePreference]) async throws {
        let map = Dictionary(uniqueKeysWithValues: preferences.map { ($0.ruleID, $0) })
        try persist(map)
    }

    // MARK: - Persistence

    private func persist(_ map: [UUID: SourcePreference]) throws {
        try ensureDirectoryExists()
        // Persist as a sorted array — same shape as the in-memory dictionary
        // but git-diffable for inspection. Sorting by ruleID keeps the file
        // stable across save calls so any tooling diffing the store sees
        // only meaningful changes.
        let sorted = map.values.sorted { $0.ruleID.uuidString < $1.ruleID.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sorted)
        try data.write(to: fileURL, options: .atomic)
        cache = map
    }

    private func ensureDirectoryExists() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
    }

    private static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Lingyue", isDirectory: true)
            .appendingPathComponent("source-preferences.json")
    }
}
