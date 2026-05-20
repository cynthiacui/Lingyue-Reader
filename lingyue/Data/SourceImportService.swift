import Foundation
import LingyueCore

/// JSON envelope for sharing one or more `SourceRule`s out-of-band — the
/// shape that ships in `docs/lingyue-sources.json` and that any user can
/// hand-author or paste into a file picker.
///
/// Kept narrower than `BackupArchive`: this carries rules only, not the
/// user's library / stats / preferences. Sharing a source set should not
/// require sharing the user's reading history.
struct SourceImportPayload: Codable {
    /// Stable string tag so a future "lingyue-something-else" envelope
    /// can land in the same file picker without us silently swallowing
    /// the wrong shape.
    static let kindTag = "lingyue-sources"
    static let currentVersion = 1

    var kind: String
    var version: Int
    var createdAt: Date?
    var sources: [SourceRule]
}

enum SourceImportError: LocalizedError {
    case unsupportedKind(String)
    case unsupportedVersion(Int)
    case decodeFailed(String)
    case emptyPayload

    var errorDescription: String? {
        switch self {
        case .unsupportedKind(let kind):
            return "无法识别的文件类型：\(kind)。请选择 lingyue-sources 书源文件。"
        case .unsupportedVersion(let v):
            return "不支持的书源文件版本：\(v)。请使用更新版本的灵阅打开此文件。"
        case .decodeFailed(let detail):
            return "书源文件解析失败：\(detail)"
        case .emptyPayload:
            return "书源文件中没有可导入的书源。"
        }
    }
}

/// Outcome counts surfaced to the confirm dialog so the user sees what
/// will (or did) change before tapping 确认。
struct SourceImportSummary: Equatable {
    /// Rules whose UUID is not in the editable store yet — would be
    /// added on import.
    var newRules: [SourceRule]
    /// Rules whose UUID matches an existing editable rule but whose
    /// content differs — would overwrite the local copy on import.
    var updatedRules: [(local: SourceRule, incoming: SourceRule)]
    /// Rules whose UUID + content match an existing rule exactly — no-op.
    var unchangedRules: [SourceRule]

    var totalIncoming: Int { newRules.count + updatedRules.count + unchangedRules.count }
    var totalChanging: Int { newRules.count + updatedRules.count }

    static func == (lhs: SourceImportSummary, rhs: SourceImportSummary) -> Bool {
        lhs.newRules.map(\.id) == rhs.newRules.map(\.id)
            && lhs.updatedRules.map { $0.incoming.id } == rhs.updatedRules.map { $0.incoming.id }
            && lhs.unchangedRules.map(\.id) == rhs.unchangedRules.map(\.id)
    }
}

/// Decode a `.json` book-source file and merge it into the editable
/// store. The merge is UUID-based: an incoming rule whose UUID is
/// already in the store replaces the existing rule; everything else is
/// appended. This is the same dedup policy `InternalSourceRegistry`
/// already applies between user rules and seeded rules, so importing
/// the bundled `lingyue-sources.json` on the App Store target gives the
/// user the same source set the Internal build ships with.
struct SourceImportService {
    let editableStore: any EditableSourceStore

    /// Decode bytes from a `.json` book-source file. Accepts two shapes:
    /// the canonical envelope (`{kind, version, sources}`) and a bare
    /// `[SourceRule]` array, since a hand-authored file may legitimately
    /// omit the envelope. The envelope path is preferred — it catches
    /// "wrong file type" before we surface garbled rule errors.
    func decode(from data: Data) throws -> [SourceRule] {
        let decoder = JSONDecoder()
        // The envelope's `createdAt` is written as an ISO8601 string by
        // `Scripts/build-sources-json.sh` and any hand-authored file is
        // expected to follow suit. Without this strategy the envelope
        // path silently falls through to the bare-array fallback for
        // every well-formed envelope that includes a timestamp.
        decoder.dateDecodingStrategy = .iso8601

        if let payload = try? decoder.decode(SourceImportPayload.self, from: data) {
            guard payload.kind == SourceImportPayload.kindTag else {
                throw SourceImportError.unsupportedKind(payload.kind)
            }
            guard payload.version <= SourceImportPayload.currentVersion else {
                throw SourceImportError.unsupportedVersion(payload.version)
            }
            guard !payload.sources.isEmpty else {
                throw SourceImportError.emptyPayload
            }
            return payload.sources
        }

        // Bare-array fallback. If it decodes, accept it; if not, surface
        // the envelope decoder's error since that's the canonical shape.
        do {
            let rules = try decoder.decode([SourceRule].self, from: data)
            guard !rules.isEmpty else { throw SourceImportError.emptyPayload }
            return rules
        } catch {
            throw SourceImportError.decodeFailed(error.localizedDescription)
        }
    }

    /// Build a preview of what an import would do without writing
    /// anything. Powers the confirm dialog.
    func summarize(incoming: [SourceRule]) async throws -> SourceImportSummary {
        let existing = try await editableStore.loadEditableSources()
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        var newRules: [SourceRule] = []
        var updated: [(SourceRule, SourceRule)] = []
        var unchanged: [SourceRule] = []

        for rule in incoming {
            if let local = existingByID[rule.id] {
                if local == rule {
                    unchanged.append(rule)
                } else {
                    updated.append((local, rule))
                }
            } else {
                newRules.append(rule)
            }
        }
        return SourceImportSummary(
            newRules: newRules,
            updatedRules: updated,
            unchangedRules: unchanged
        )
    }

    /// Apply the merge. Uses `replaceAll` so it lands as one atomic
    /// write — partial state after a crash would be worse than the
    /// previous state surviving intact.
    @discardableResult
    func apply(incoming: [SourceRule]) async throws -> SourceImportSummary {
        let summary = try await summarize(incoming: incoming)
        let existing = try await editableStore.loadEditableSources()
        var merged: [UUID: SourceRule] = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.id, $0) }
        )
        for rule in incoming {
            merged[rule.id] = rule
        }
        // Preserve existing order for already-present rules; append new
        // rules at the end in the order they appeared in the file.
        var ordered: [SourceRule] = []
        var seen: Set<UUID> = []
        for rule in existing {
            ordered.append(merged[rule.id] ?? rule)
            seen.insert(rule.id)
        }
        for rule in incoming where !seen.contains(rule.id) {
            ordered.append(rule)
            seen.insert(rule.id)
        }
        try await editableStore.replaceAll(ordered)
        return summary
    }
}
