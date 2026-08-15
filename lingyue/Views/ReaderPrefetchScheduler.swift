import Foundation
import Combine

/// Capability handed to a prefetch job. Work may finish after the reader has moved to a
/// different chapter; all state/cache writes must pass through `commit` so stale results
/// cannot mutate the new reading window.
@MainActor
final class ReaderPrefetchTicket {
    private(set) var isValid = true

    @discardableResult
    func commit(_ updates: () -> Void) -> Bool {
        guard isValid, !Task.isCancelled else { return false }
        updates()
        return true
    }

    fileprivate func invalidate() {
        isValid = false
    }
}

/// A small reader-scoped scheduler for speculative chapter work.
///
/// - Replacing the desired window cancels jobs that are no longer relevant.
/// - Job ids coalesce duplicate requests across repeated SwiftUI updates.
/// - Cancelled jobs keep occupying their slot until their underlying await unwinds, so
///   actual network/layout concurrency never exceeds `maxConcurrentJobs`.
@MainActor
final class ReaderPrefetchScheduler: ObservableObject {
    struct Metrics: Sendable, Equatable {
        let concurrencyLimit: Int
        let running: Int
        let queued: Int
        let maximumRunning: Int
        let maximumQueued: Int
        let started: Int
        let completed: Int
        let cancelled: Int
    }

    struct Job {
        let id: String
        let operation: @MainActor (ReaderPrefetchTicket) async -> Void
    }

    private struct RunningJob {
        let ticket: ReaderPrefetchTicket
        let task: Task<Void, Never>
    }

    private let maxConcurrentJobs: Int
    private var desiredIDs: Set<String> = []
    private var completedIDs: Set<String> = []
    private var queuedJobs: [Job] = []
    private var runningJobs: [String: RunningJob] = [:]
    private var maximumRunningCount = 0
    private var maximumQueuedCount = 0
    private var startedCount = 0
    private var completedCount = 0
    private var cancelledCount = 0

    init(maxConcurrentJobs: Int = 2) {
        self.maxConcurrentJobs = max(maxConcurrentJobs, 1)
    }

    var runningCount: Int { runningJobs.count }
    var queuedCount: Int { queuedJobs.count }
    var isIdle: Bool { runningJobs.isEmpty && queuedJobs.isEmpty }
    var metrics: Metrics {
        Metrics(
            concurrencyLimit: maxConcurrentJobs,
            running: runningJobs.count,
            queued: queuedJobs.count,
            maximumRunning: maximumRunningCount,
            maximumQueued: maximumQueuedCount,
            started: startedCount,
            completed: completedCount,
            cancelled: cancelledCount
        )
    }

    /// Replaces the complete desired working set. Input order is priority order.
    func replaceDesiredJobs(_ jobs: [Job]) {
        var uniqueJobs: [Job] = []
        var seen: Set<String> = []
        for job in jobs where seen.insert(job.id).inserted {
            uniqueJobs.append(job)
        }

        let nextDesiredIDs = Set(uniqueJobs.map(\.id))
        desiredIDs = nextDesiredIDs
        completedIDs.formIntersection(nextDesiredIDs)

        let queuedBeforeReplacement = queuedJobs.count
        queuedJobs.removeAll { !nextDesiredIDs.contains($0.id) }
        cancelledCount &+= queuedBeforeReplacement - queuedJobs.count
        for (id, running) in runningJobs where !nextDesiredIDs.contains(id) {
            guard running.ticket.isValid else { continue }
            running.ticket.invalidate()
            running.task.cancel()
            cancelledCount &+= 1
        }

        // Replace queued closures with the latest view/session snapshot while keeping
        // priority stable according to the newest requested window.
        let queuedIDs = Set(queuedJobs.map(\.id))
        queuedJobs = uniqueJobs.filter { job in
            if completedIDs.contains(job.id) { return false }
            if let running = runningJobs[job.id], running.ticket.isValid { return false }
            return queuedIDs.contains(job.id) || runningJobs[job.id] == nil || runningJobs[job.id]?.ticket.isValid == false
        }
        maximumQueuedCount = max(maximumQueuedCount, queuedJobs.count)

        pump()
    }

    func cancelAll() {
        desiredIDs.removeAll()
        completedIDs.removeAll()
        cancelledCount &+= queuedJobs.count
        queuedJobs.removeAll()
        for running in runningJobs.values {
            guard running.ticket.isValid else { continue }
            running.ticket.invalidate()
            running.task.cancel()
            cancelledCount &+= 1
        }
    }

    private func pump() {
        queuedJobs.removeAll { !desiredIDs.contains($0.id) }
        while runningJobs.count < maxConcurrentJobs,
              let nextIndex = queuedJobs.firstIndex(where: { runningJobs[$0.id] == nil }) {
            let job = queuedJobs.remove(at: nextIndex)

            let ticket = ReaderPrefetchTicket()
            let task = Task { @MainActor [weak self] in
                await job.operation(ticket)
                self?.finish(jobID: job.id, ticket: ticket)
            }
            runningJobs[job.id] = RunningJob(ticket: ticket, task: task)
            startedCount &+= 1
            maximumRunningCount = max(maximumRunningCount, runningJobs.count)
        }
    }

    private func finish(jobID: String, ticket: ReaderPrefetchTicket) {
        guard let running = runningJobs[jobID], running.ticket === ticket else { return }
        runningJobs[jobID] = nil
        if ticket.isValid, desiredIDs.contains(jobID), !Task.isCancelled {
            completedIDs.insert(jobID)
            completedCount &+= 1
        }
        pump()
    }
}
