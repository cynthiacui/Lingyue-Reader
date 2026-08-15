import Foundation
import LingyueCore

/// Phase 5.3 — `.lingyue-backup` envelope. A single Codable JSON file
/// covering everything the user would lose on reinstall: library +
/// locally stored covers + reading-stats ledger + editable rules +
/// per-rule preferences + per-rule validation history.
///
/// Versioned at the envelope level. `currentVersion` bumps whenever a
/// new build writes data an older build must not silently discard. The
/// decoder still accepts explicitly supported older versions so backups
/// remain forward-migratable.
///
/// `buildVariant` records whether the archive was produced by an
/// Internal or AppStore build. We don't reject cross-variant restores
/// — a user moving from Internal → AppStore should be able to bring
/// their library along — but the field is preserved so the restore UI
/// can warn if the recipient build won't recognize some rules.
struct BackupArchive: Codable {
    var version: Int
    var createdAt: Date
    var buildVariant: String
    var library: [LibraryCategory]
    var archivedBooks: [ArchivedBookRecord]? = nil
    var readingStats: ReadingStatsLedger
    var editableSources: [SourceRule]
    var sourcePreferences: [SourcePreference]
    var sourceValidations: [SourceValidation]
    var bookCovers: [String: Data]?

    static let currentVersion = 2
    static let supportedVersions = 1...currentVersion
}

enum BackupError: LocalizedError {
    case unsupportedVersion(Int)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "不支持的备份版本：\(v)。请使用更新版本的灵阅打开此文件。"
        case .decodeFailed(let detail):
            return "备份文件解析失败：\(detail)"
        }
    }
}

/// Bundles the stores, library, and local covers into a single export/import unit.
/// Lives on the main actor because `LibraryStore` is main-actor isolated
/// and the published `categories` / `readingStats` setters must be
/// touched from the main thread. The actor-typed store calls (editable /
/// preference / validation) hop off main to read JSON; that's fine —
/// `await` handles the actor switch.
@MainActor
struct BackupService {
    let libraryStore: LibraryStore
    let stack: SourceStack

    /// Snapshot every backed-up surface into an archive ready to encode.
    func makeArchive() async throws -> BackupArchive {
        let editable = try await stack.editableStore.loadEditableSources()
        let prefs = try await stack.preferenceStore.loadAll()
        let validations = try await stack.validationStore.loadAll()
        let bookIDs = Set(libraryStore.allNovels.map(\.id))
        let bookCovers = await BookCoverStore.shared.exportedCovers(for: bookIDs)
        return BackupArchive(
            version: BackupArchive.currentVersion,
            createdAt: Date(),
            buildVariant: buildVariantTag,
            library: libraryStore.categories,
            archivedBooks: libraryStore.archivedBooks,
            readingStats: libraryStore.readingStats,
            editableSources: editable,
            sourcePreferences: Array(prefs.values),
            sourceValidations: Array(validations.values),
            bookCovers: bookCovers
        )
    }

    func encodeArchive(_ archive: BackupArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }

    func decodeArchive(from data: Data) throws -> BackupArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive: BackupArchive
        do {
            archive = try decoder.decode(BackupArchive.self, from: data)
        } catch {
            throw BackupError.decodeFailed(error.localizedDescription)
        }
        guard BackupArchive.supportedVersions.contains(archive.version) else {
            throw BackupError.unsupportedVersion(archive.version)
        }
        return archive
    }

    /// Replace every backed-up surface in place. Destructive — caller
    /// owns the confirm-dialog. Stores are replaced before the library
    /// so a partial failure leaves the user looking at the rule set the
    /// library expects to reference; the library/stats swap then runs
    /// in one main-actor hop so the published `didSet` fires once per
    /// property. A final `flush()` makes sure the JSON files land on
    /// disk before the user can quit the app.
    func restore(_ archive: BackupArchive) async throws {
        try await stack.editableStore.replaceAll(archive.editableSources)
        try await stack.preferenceStore.replaceAll(archive.sourcePreferences)
        if let file = stack.validationStore as? FileSourceValidationStore {
            try await file.replaceAll(archive.sourceValidations)
        }
        libraryStore.replaceLibrary(
            categories: archive.library,
            archivedBooks: archive.archivedBooks ?? []
        )
        libraryStore.replaceReadingStats(archive.readingStats)
        let activeBookIDs = Set(
            archive.library.flatMap(\.novels).map(\.id)
            + (archive.archivedBooks ?? []).map(\.id)
        )
        await BookCoverStore.shared.restoreCovers(
            archive.bookCovers ?? [:],
            keeping: activeBookIDs
        )
        await libraryStore.flush()
    }

    /// Suggested filename for the share sheet / file exporter.
    /// `lingyue-backup-YYYY-MM-DD.json` — date-stamped so a user keeping
    /// multiple backups doesn't accidentally overwrite an older one.
    static func suggestedFilename(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "lingyue-backup-\(formatter.string(from: date)).json"
    }

    private var buildVariantTag: String { "appstore" }
}
