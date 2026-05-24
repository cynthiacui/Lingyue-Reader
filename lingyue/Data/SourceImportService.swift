import Foundation
import LingyueCore

/// JSON envelope for sharing one or more `SourceRule`s out-of-band — a
/// shape any user can hand-author or paste into a file picker.
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
/// appended.
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

/// Long-lived owner of the search→detail→catalog→chapter verification
/// chain. Kept out of any view so a verification started from
/// `SourcesListView` (the typical entry) keeps running when the user
/// navigates back, opens "添加书源", taps into another rule's review
/// screen, etc. The view subscribes to `verifyingIDs` (via
/// `@Published`) so the row's pill flips back from 检查中 to 可用/失败
/// automatically when the task finishes — no manual refresh needed.
///
/// Idempotent: calling `verify(rule:)` for an in-flight rule is a no-op,
/// so a re-render or a second import attempt doesn't fan out duplicate
/// requests against the same source.
@MainActor
final class SourceVerificationService: ObservableObject {
    /// Process-wide singleton. The service is stateful (running tasks,
    /// the in-flight set) and several views consult the same state, so
    /// keeping one instance per process is what makes "verification
    /// survives navigation" work.
    static let shared = SourceVerificationService()

    /// Rule IDs whose verification chain is currently running. Drives
    /// the 检查中 pill in `SourcesListView`. Updates on the main actor
    /// so SwiftUI sees the change immediately.
    @Published private(set) var verifyingIDs: Set<UUID> = []

    private var tasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    /// Pre-mark a batch as in-flight before kicking off the per-rule
    /// tasks. Without this the rows that haven't had their turn yet
    /// would render 需要检查 (orange) for the brief window between
    /// "import finished" and "first rule's task scheduled," which
    /// looks like verification already failed.
    func markVerifying(ruleIDs: [UUID]) {
        for id in ruleIDs { verifyingIDs.insert(id) }
    }

    /// Kick off the verification chain for `rule`. Returns immediately;
    /// the work runs in a detached background task whose lifetime is
    /// independent of any view's. Calling for an already-verifying rule
    /// is a no-op so a re-import or a UI re-entry doesn't double-fire.
    func verify(rule: SourceRule) {
        // Already-running task → don't double-schedule. A rule that's
        // only been pre-marked by `markVerifying` (in `verifyingIDs`
        // but no task yet) still needs to be scheduled here.
        guard tasks[rule.id] == nil else { return }
        verifyingIDs.insert(rule.id)
        let task = Task { [weak self] in
            await self?.performVerification(rule: rule)
            await self?.finish(ruleID: rule.id)
        }
        tasks[rule.id] = task
    }

    private func finish(ruleID: UUID) {
        verifyingIDs.remove(ruleID)
        tasks[ruleID] = nil
    }

    // MARK: - Chain

    private func performVerification(rule: SourceRule) async {
        let stack = SourceStack.live
        // Route through the rule's own factory so jsonAPI rules reach
        // `JSONAPIBookSource` instead of the HTML scraper. Without this
        // every block fails verification for those rules because the
        // scraper hits the API endpoint and gets JSON.
        let source = rule.makeBookSource(loader: stack.loader)

        // Build a candidate list: search hits first (when the rule has a
        // search step), then homepage anchors matching the detection
        // pathPattern. Walk this list rather than just taking the first
        // entry — some sites poison search results and homepage listings
        // with stub IDs that 404, so the first few candidates routinely
        // fail. Stopping at the first working book lets the chain produce
        // all four ✓ even when most candidates are dead.
        var candidates: [URL] = []
        if rule.search != nil || rule.jsonAPI?.search != nil {
            // Probe with a single common char first, then a 2-char fallback.
            // A few mainland CMS clones reject keywords whose GB18030
            // byte length is < 4 — a single Chinese char is 2 bytes
            // and produces a "关键字过短" error page, so the smoke test for
            // those sites never marks search as 已识别 without the fallback.
            for probe in ["一", "小说"] {
                if let hits = try? await source.search(probe), !hits.isEmpty {
                    await persistVerification(rule: rule, block: .search, passed: true)
                    candidates.append(contentsOf: hits.prefix(8).map(\.detailURL))
                    break
                }
            }
        }
        let homepageCandidates = await findHomepageDetailURLs(rule: rule, limit: 8, stack: stack)
        for url in homepageCandidates where !candidates.contains(url) {
            candidates.append(url)
        }
        guard !candidates.isEmpty else { return }

        // Walk candidates. Persist each block as soon as ANY candidate
        // passes it, but keep walking until we find one candidate that
        // satisfies the full detail+catalog+chapter chain — otherwise a
        // 404 stub with a stray <h1> would mark detail as 已识别 while
        // catalog/chapter stay at 需要检查 forever.
        var detailPassedOnce = false
        var catalogPassedOnce = false
        var seenDetail: Set<URL> = []
        for candidateURL in candidates where seenDetail.insert(candidateURL).inserted {
            guard let detail = try? await source.fetchDetail(url: candidateURL),
                  !detail.title.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            if !detailPassedOnce {
                await persistVerification(rule: rule, block: .detail, passed: true)
                detailPassedOnce = true
            }
            guard let chapters = try? await source.fetchCatalog(url: detail.catalogURL),
                  !chapters.isEmpty
            else { continue }
            if !catalogPassedOnce {
                await persistVerification(rule: rule, block: .catalog, passed: true)
                catalogPassedOnce = true
            }
            // Many user-authored catalog rules use broad selectors (e.g.
            // `ul > li`) that scoop the site's top *and* bottom nav strips
            // alongside the real chapter rows — sampling first-N + last-N
            // still hits only nav junk on those sites. Real chapter URLs
            // cluster under one path directory (e.g. `/books/170611/…`)
            // while nav links scatter across `/`, `/list/`, etc. Filter to
            // the dominant directory before probing.
            let chapterCandidates = Self.likelyChapterLinks(chapters)
            let probes = Array(chapterCandidates.prefix(3)) + Array(chapterCandidates.suffix(3))
            var seenChapter: Set<URL> = []
            for chapter in probes where seenChapter.insert(chapter.url).inserted {
                if let content = try? await source.fetchChapter(url: chapter.url),
                   !content.paragraphs.isEmpty {
                    await persistVerification(rule: rule, block: .chapter, passed: true)
                    return
                }
            }
        }
    }

    /// Fetch the rule's homepage and return up to `limit` anchors whose
    /// paths match `detection.pathPattern`. Used as the search-less seed
    /// for the verification chain and to backfill ghost-ID search misses.
    private func findHomepageDetailURLs(rule: SourceRule, limit: Int, stack: SourceStack) async -> [URL] {
        let request = SourceRequest(
            url: rule.homepage,
            headers: rule.defaultHeaders,
            encoding: rule.encoding,
            referer: nil
        )
        guard let snapshot = try? await stack.loader.fetchHTML(request) else {
            return []
        }
        return rule.detailURLs(in: snapshot, limit: limit)
    }

    /// Filter a noisy catalog to the entries that look like real
    /// chapters. Heuristic: group by URL directory (path up to the
    /// final `/`) and keep only the dominant group. On well-authored
    /// rules the dominant group is the whole catalog, so the filter is
    /// a no-op; on broad-selector rules the dominant group is the real
    /// chapter directory because nav links scatter across `/`, `/list/`,
    /// `/static/`, etc. while every real chapter shares the book's path.
    private static func likelyChapterLinks(_ chapters: [ChapterLink]) -> [ChapterLink] {
        guard chapters.count > 1 else { return chapters }
        func directory(_ url: URL) -> String {
            let path = url.path
            guard let slash = path.lastIndex(of: "/") else { return path }
            return String(path[...slash])
        }
        var counts: [String: Int] = [:]
        for link in chapters { counts[directory(link.url), default: 0] += 1 }
        guard
            let dominant = counts.max(by: { $0.value < $1.value })?.key,
            // Require a meaningful majority — if no single directory
            // dominates, the catalog is probably structured weirdly and
            // we shouldn't second-guess it.
            (counts[dominant] ?? 0) >= chapters.count / 2
        else {
            return chapters
        }
        return chapters.filter { directory($0.url) == dominant }
    }

    private func persistVerification(rule: SourceRule, block: SourceBlock, passed: Bool) async {
        let record = BlockTestRecord(
            status: passed ? .passed : .failed,
            lastRunAt: Date(),
            failureSummary: passed ? nil : "自动验证未通过",
            inputFingerprint: rule.blockFingerprint(block)
        )
        try? await SourceStack.live.validationStore.recordTest(
            ruleID: rule.id,
            block: block,
            record: record
        )
    }
}
