import Foundation
import SwiftUI

/// Per-novel download status. `.idle` covers "never downloaded" and "fully cleared";
/// `.downloading` reports live progress; `.paused` retains the same counts but with no
/// active task so the user can resume; `.downloaded` is final; `.failed` retains a
/// partial count so the user can decide whether to retry.
enum BookDownloadState: Equatable {
    case idle
    case downloading(completed: Int, total: Int)
    case paused(completed: Int, total: Int)
    case downloaded(total: Int)
    case failed(message: String, completed: Int, total: Int)

    var isActive: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    var isFinished: Bool {
        if case .downloaded = self { return true }
        return false
    }

    /// Used as a uniform 0...1 value for progress bars. `.idle` returns 0, `.downloaded` returns 1.
    var fraction: Double {
        switch self {
        case .idle: return 0
        case .downloading(let completed, let total):
            guard total > 0 else { return 0 }
            return min(1, Double(completed) / Double(total))
        case .paused(let completed, let total):
            guard total > 0 else { return 0 }
            return min(1, Double(completed) / Double(total))
        case .downloaded: return 1
        case .failed(_, let completed, let total):
            guard total > 0 else { return 0 }
            return min(1, Double(completed) / Double(total))
        }
    }
}

@MainActor
final class BookDownloadManager: ObservableObject {
    /// Source of truth for download state. Keyed by `Novel.id`.
    @Published private(set) var states: [UUID: BookDownloadState] = [:]

    /// Live download tasks indexed by novel ID so they can be cancelled.
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// Caps concurrent chapter fetches per book. 4 is a soft balance — more would saturate
    /// flaky third-party sources, fewer makes downloads feel sluggish.
    private let maxConcurrentFetches = 4

    func state(for novel: Novel) -> BookDownloadState {
        states[novel.id] ?? .idle
    }

    func isActive(_ novel: Novel) -> Bool {
        state(for: novel).isActive
    }

    /// Books currently downloading or finished within this app session — what the
    /// downloads sheet renders. Idle/never-touched books aren't included to keep the
    /// sheet focused.
    var trackedNovelIDs: [UUID] {
        states
            .filter { $0.value != .idle }
            .map(\.key)
    }

    // MARK: - Public actions

    func startDownload(_ novel: Novel) {
        // Repeated taps on a downloading or finished book are no-ops; paused/failed
        // books fall through and resume from where they stopped.
        if let current = states[novel.id], current.isActive || current.isFinished {
            return
        }

        let fetchable = chaptersNeedingFetch(in: novel)
        guard !fetchable.isEmpty else {
            // Inline-content books have nothing to fetch; mark as downloaded so the badge
            // still surfaces.
            states[novel.id] = .downloaded(total: novel.chapters.count)
            return
        }

        let total = fetchable.count
        // Show an immediate "starting" state so the UI reacts before the async cache
        // probe lands. The probe below replaces this with the accurate completed count.
        let optimisticCompleted: Int = {
            switch states[novel.id] {
            case .paused(let completed, _), .failed(_, let completed, _):
                return completed
            default: return 0
            }
        }()
        states[novel.id] = .downloading(completed: optimisticCompleted, total: total)

        let novelID = novel.id
        let concurrency = maxConcurrentFetches
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            // Probe the cache first so resumed downloads start with an accurate count
            // and skip already-fetched chapters entirely.
            let cachedKeys = await ChapterContentCache.shared.cachedKeys(for: fetchable)
            let remaining = fetchable.filter { chapter in
                let key = chapter.sourceURLString ?? chapter.id.uuidString
                return !cachedKeys.contains(key)
            }
            let initialCompleted = total - remaining.count

            await self.runDownload(
                novelID: novelID,
                chapters: remaining,
                initialCompleted: initialCompleted,
                total: total,
                concurrency: concurrency
            )
        }
        activeTasks[novelID] = task
    }

    /// User-initiated pause. Cancels the active task and stamps the state as `.paused`
    /// so the UI swaps the stop button for a play button.
    func pauseDownload(for novel: Novel) {
        guard let current = states[novel.id], case .downloading(let completed, let total) = current else {
            return
        }
        activeTasks[novel.id]?.cancel()
        activeTasks[novel.id] = nil
        states[novel.id] = .paused(completed: completed, total: total)
    }

    /// Mirror of `startDownload` — kept as a separate name so call sites read clearly
    /// at the UI layer ("the user tapped the play button").
    func resumeDownload(for novel: Novel) {
        startDownload(novel)
    }

    func cancelDownload(for novel: Novel) {
        cancelDownload(novelID: novel.id)
    }

    func cancelDownload(novelID: UUID) {
        activeTasks[novelID]?.cancel()
        activeTasks[novelID] = nil
        // The running download task observes Task.isCancelled and stamps its own
        // final `.paused(completed:, total:)` state so partial progress survives.
    }

    /// Cancels any in-flight download and drops cached state so the UI immediately reflects
    /// "not downloaded". Call this *before* clearing the cache itself, so observers don't
    /// momentarily see a stale "downloaded" tag.
    func clearState(for novel: Novel) {
        activeTasks[novel.id]?.cancel()
        activeTasks[novel.id] = nil
        states[novel.id] = .idle
    }

    /// Wipes every per-novel state — used when the user taps "清理全部下载数据" in Settings.
    func clearAllStates() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
        states.removeAll()
    }

    /// Re-derives a single novel's state from the on-disk cache. Useful after returning
    /// from the reader (which may have cached additional chapters opportunistically).
    func refreshState(for novel: Novel) async {
        // Don't stomp on an in-flight download — it owns its own state transitions.
        if states[novel.id]?.isActive == true { return }

        let fetchable = chaptersNeedingFetch(in: novel)
        guard !fetchable.isEmpty else {
            // Inline-only novel: only mark as downloaded if the user has explicitly
            // started a download in the past. Otherwise leave as idle so we don't
            // splatter "已下载" tags across books the user never touched.
            if case .downloaded = states[novel.id] {
                states[novel.id] = .downloaded(total: novel.chapters.count)
            }
            return
        }

        let cachedKeys = await ChapterContentCache.shared.cachedKeys(for: fetchable)
        let cachedCount = cachedKeys.count

        if cachedCount >= fetchable.count {
            states[novel.id] = .downloaded(total: fetchable.count)
        } else if cachedCount > 0 {
            // Partial cache — could be incidental from reading, or a paused/failed
            // download. Only surface this when an explicit non-idle state already
            // exists, so we don't claim every casually-opened book is "in progress".
            switch states[novel.id] {
            case .downloading:
                states[novel.id] = .downloading(completed: cachedCount, total: fetchable.count)
            case .paused:
                states[novel.id] = .paused(completed: cachedCount, total: fetchable.count)
            case .failed(let message, _, _):
                states[novel.id] = .failed(message: message, completed: cachedCount, total: fetchable.count)
            default:
                break
            }
        } else {
            // Nothing cached — idle.
            if case .downloaded = states[novel.id] {
                states[novel.id] = .idle
            }
        }
    }

    /// Bulk refresh used when the Library appears — keeps downloaded badges accurate
    /// across cold launches.
    func refreshStates(for novels: [Novel]) async {
        for novel in novels {
            // Bootstrap entries for novels we've never seen so the bulk refresh below
            // can promote them to `.downloaded` if their cache is already complete.
            if states[novel.id] == nil {
                let fetchable = chaptersNeedingFetch(in: novel)
                if !fetchable.isEmpty {
                    let cachedKeys = await ChapterContentCache.shared.cachedKeys(for: fetchable)
                    if cachedKeys.count >= fetchable.count {
                        states[novel.id] = .downloaded(total: fetchable.count)
                    }
                }
            } else {
                await refreshState(for: novel)
            }
        }
    }

    // MARK: - Private

    private func chaptersNeedingFetch(in novel: Novel) -> [NovelChapter] {
        novel.chapters.filter { chapter in
            chapter.sourceURLString != nil &&
            chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func runDownload(
        novelID: UUID,
        chapters: [NovelChapter],
        initialCompleted: Int,
        total: Int,
        concurrency: Int
    ) async {
        var completed = initialCompleted
        var failure: Error?

        // Publish the post-probe count immediately so a resumed download doesn't
        // briefly flash to its optimistic pre-probe value.
        states[novelID] = .downloading(completed: completed, total: total)

        if chapters.isEmpty {
            // All remaining chapters were already cached — short-circuit to .downloaded.
            activeTasks[novelID] = nil
            states[novelID] = .downloaded(total: total)
            return
        }

        await withTaskGroup(of: Result<Void, Error>.self) { group in
            var iterator = chapters.makeIterator()
            var inflight = 0

            // Prime the task group up to the concurrency cap.
            while inflight < concurrency, let chapter = iterator.next() {
                group.addTask {
                    do {
                        _ = try await ChapterContentCache.shared.chapter(for: chapter)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
                inflight += 1
            }

            while let result = await group.next() {
                inflight -= 1

                if Task.isCancelled {
                    group.cancelAll()
                    break
                }

                switch result {
                case .success:
                    completed += 1
                    // Publish progress incrementally; keeps the sheet's progress bars lively.
                    if !Task.isCancelled {
                        states[novelID] = .downloading(completed: completed, total: total)
                    }
                case .failure(let error):
                    if failure == nil { failure = error }
                }

                if let chapter = iterator.next() {
                    group.addTask {
                        do {
                            _ = try await ChapterContentCache.shared.chapter(for: chapter)
                            return .success(())
                        } catch {
                            return .failure(error)
                        }
                    }
                    inflight += 1
                }
            }
        }

        activeTasks[novelID] = nil

        if Task.isCancelled {
            // Cancellation routes through pause: pauseDownload(for:) already stamped
            // .paused before cancelling, but a system-level cancel (e.g. clearAllStates)
            // may have skipped that. Only overwrite when we're still mid-download —
            // never clobber a paused/cleared state.
            if case .downloading = states[novelID] {
                states[novelID] = .paused(completed: completed, total: total)
            }
            return
        }

        if completed >= total {
            states[novelID] = .downloaded(total: total)
        } else if let failure {
            states[novelID] = .failed(
                message: failure.localizedDescription,
                completed: completed,
                total: total
            )
        } else {
            // Shouldn't reach here unless cancellation slipped through; fall back to paused.
            states[novelID] = .paused(completed: completed, total: total)
        }
    }
}
