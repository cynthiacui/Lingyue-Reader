import Foundation
import LingyueCore

/// On-disk `SourceValidationStore` backed by a single JSON file at
/// `Application Support/lingyue/source-validation.json`. Sibling to
/// `FileSourcePreferenceStore` and `FileEditableSourceStore`; same
/// actor + atomic-write pattern so a crash mid-write leaves the
/// previous JSON intact.
///
/// **Device-local on purpose.** The Phase 3.2 JSON-import path on the
/// Internal target ingests rules only — never this file. "Passed on my
/// device" doesn't grant Enable on a rule shared to another install;
/// see PHASES.md §3.5.1.
public actor FileSourceValidationStore: SourceValidationStore {
    private let fileURL: URL
    private var cache: [UUID: SourceValidation]?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = Self.defaultFileURL()
        }
    }

    public func loadAll() async throws -> [UUID: SourceValidation] {
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
        let list = try decoder.decode([SourceValidation].self, from: data)
        let map = Dictionary(uniqueKeysWithValues: list.map { ($0.ruleID, $0) })
        cache = map
        return map
    }

    public func load(ruleID: UUID) async throws -> SourceValidation? {
        let all = try await loadAll()
        return all[ruleID]
    }

    public func recordTest(
        ruleID: UUID,
        block: SourceBlock,
        record: BlockTestRecord
    ) async throws {
        var current = try await loadAll()
        var existing = current[ruleID] ?? SourceValidation(ruleID: ruleID)
        existing.tests[block] = record
        existing.updatedAt = Date()
        current[ruleID] = existing
        try persist(current)
    }

    public func delete(ruleID: UUID) async throws {
        var current = try await loadAll()
        guard current.removeValue(forKey: ruleID) != nil else { return }
        try persist(current)
    }

    /// Phase 5.3 restore hook. Destructive: drops any existing records
    /// and replaces with `validations`. Not in the `SourceValidationStore`
    /// protocol because the store is device-local by design — only the
    /// backup-restore path on the *same* device legitimately blows the
    /// file away.
    public func replaceAll(_ validations: [SourceValidation]) async throws {
        let map = Dictionary(uniqueKeysWithValues: validations.map { ($0.ruleID, $0) })
        try persist(map)
    }

    // MARK: - Persistence

    private func persist(_ map: [UUID: SourceValidation]) throws {
        try ensureDirectoryExists()
        // Sorted-by-ruleID array shape: mirrors FileSourcePreferenceStore
        // so the file is git-diffable for inspection and stable across
        // save calls (only meaningful changes show up in diffs).
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

    /// Default location: `Application Support/lingyue/source-validation.json`.
    /// Lowercase `lingyue/` matches the rest of the store family so all
    /// four files share one directory entry — see the case-collision
    /// note in `FileSourcePreferenceStore.defaultFileURL()`.
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
            .appendingPathComponent("source-validation.json")
    }
}
