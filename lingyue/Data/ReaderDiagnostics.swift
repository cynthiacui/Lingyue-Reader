import Foundation
import SwiftUI
import UIKit

/// In-app diagnostic log specifically for the reader. Buffers a recent
/// window of events to disk so we can reconstruct what the reader was
/// doing in the seconds before a crash that Apple's Organizer / MetricKit
/// captured a stack trace for. The two work together: Apple gives us the
/// "where it died", this gives us the "what was running."
///
/// Per-session model:
///   - On launch, the prior session's `current.json` is rotated to
///     `previous.json` and parsed into `previous` — this is the log shown
///     in Settings → 诊断.
///   - The new session writes to `current.json` (throttled atomic writes
///     ~ every second, plus an immediate flush on memory warning / scene
///     background — i.e. the moments when the next thing that happens
///     might be a crash).
///   - The in-memory `current` buffer is bounded to `maxEntries` so log
///     volume doesn't bloat memory; the file mirrors the buffer.
@MainActor
final class ReaderDiagnostics: ObservableObject {
    static let shared = ReaderDiagnostics()

    /// True for Debug builds and TestFlight installs; false on App Store
    /// releases. App Store builds use a production `receipt`, while
    /// TestFlight uses `sandboxReceipt` — checking the receipt URL is the
    /// canonical Apple-blessed way to distinguish the two without
    /// hard-coding bundle versions or relying on private API.
    static var isInternalBuild: Bool {
        #if DEBUG
        return true
        #else
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return url.lastPathComponent == "sandboxReceipt"
        #endif
    }

    @Published private(set) var current: [Entry] = []
    @Published private(set) var previous: [Entry] = []
    @Published private(set) var sessionStartedAt: Date = Date()

    /// Hard cap on retained events. 300 ≈ 5–10 min of normal reader
    /// activity (pagination + page turns + state snapshots), which more
    /// than covers the "what was happening before the crash" goal while
    /// keeping the JSON small (< 100KB).
    private let maxEntries = 300

    private let currentURL: URL
    private let previousURL: URL
    private var flushTask: Task<Void, Never>?
    private var memoryObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var willResignObserver: NSObjectProtocol?

    /// File path the uncaught-exception handler appends to. The handler is a
    /// plain C function pointer (no captured state) and runs synchronously
    /// before `abort()`, so it can't reach the actor — it reads/writes this
    /// URL directly on the crashing thread.
    nonisolated(unsafe) fileprivate static var handlerURL: URL?

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base
            .appendingPathComponent("lingyue", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.currentURL = dir.appendingPathComponent("current.json")
        self.previousURL = dir.appendingPathComponent("previous.json")

        rotateSessionFiles()
        observeLifecycleNotifications()
        Self.installUncaughtExceptionHandler(currentURL: currentURL)

        log(.lifecycle, "session start", context: [
            "build": Self.buildString(),
            "ios": UIDevice.current.systemVersion,
            "device": UIDevice.current.model
        ])
    }

    deinit {
        let center = NotificationCenter.default
        if let memoryObserver { center.removeObserver(memoryObserver) }
        if let backgroundObserver { center.removeObserver(backgroundObserver) }
        if let willResignObserver { center.removeObserver(willResignObserver) }
    }

    // MARK: - Public API

    func log(_ kind: Kind, _ message: String, context: [String: String] = [:]) {
        appendEntry(Entry(timestamp: Date(), kind: kind, message: message, context: context))
    }

    /// Records the reader's current high-level state. Call this at every
    /// state-changing boundary (after pagination, after a page turn, after
    /// a chapter jump) — these snapshots are the "where was the user?"
    /// breadcrumbs we read back during crash reconstruction.
    func snapshot(_ state: ReaderStateSnapshot) {
        appendEntry(Entry(
            timestamp: Date(),
            kind: .state,
            message: "reader state",
            context: state.asContext()
        ))
    }

    /// Cross-actor entry point. Use from `Task.detached`/non-MainActor code
    /// paths (e.g. pagination workers) — internally hops to main to mutate
    /// the published buffer.
    nonisolated func logFromAnywhere(_ kind: Kind, _ message: String, context: [String: String] = [:]) {
        let entry = Entry(timestamp: Date(), kind: kind, message: message, context: context)
        Task { @MainActor [weak self] in
            self?.appendEntry(entry)
        }
    }

    /// Force any in-memory entries to disk now. Called on memory warning,
    /// scene background, and app will-resign-active — the moments when
    /// the next thing that happens might be a crash.
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        let snapshot = current
        let url = currentURL
        Task.detached(priority: .userInitiated) {
            Self.write(snapshot, to: url)
        }
    }

    func clearAll() {
        current.removeAll()
        previous.removeAll()
        try? FileManager.default.removeItem(at: currentURL)
        try? FileManager.default.removeItem(at: previousURL)
    }

    /// Plain-text export used by the share sheet in Settings → 诊断.
    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.timeZone = TimeZone.current

        var lines: [String] = []
        lines.append("Lingyue Reader Diagnostics")
        lines.append("Generated: \(Date())")
        lines.append("Build: \(Self.buildString())  iOS: \(UIDevice.current.systemVersion)")
        lines.append("")
        lines.append("=== PREVIOUS SESSION (\(previous.count) entries) ===")
        for entry in previous {
            lines.append(format(entry, formatter: formatter))
        }
        lines.append("")
        lines.append("=== CURRENT SESSION (\(current.count) entries) ===")
        for entry in current {
            lines.append(format(entry, formatter: formatter))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Internals

    private func appendEntry(_ entry: Entry) {
        current.append(entry)
        if current.count > maxEntries {
            current.removeFirst(current.count - maxEntries)
        }
        scheduleFlush()
    }

    /// Debounced atomic flush. We coalesce bursty logging (page-turn
    /// gestures fire 5–10 events in tight sequence) into one disk write
    /// while bounding the loss-window to ~250ms — tight enough that the
    /// trailing entries before a crash are almost always on disk.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            let snapshot = self.current
            let url = self.currentURL
            self.flushTask = nil
            await Task.detached(priority: .utility) {
                Self.write(snapshot, to: url)
            }.value
        }
    }

    private nonisolated static func write(_ entries: [Entry], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Installs a process-wide ObjC uncaught-exception handler. The handler
    /// runs synchronously on the throwing thread right before `abort()` —
    /// no MainActor, no async — so it reads `current.json` from disk,
    /// appends a `.uncaughtException` entry with the exception's
    /// name/reason/stack, and writes back atomically. With 250 ms flush
    /// debounce upstream, the file usually already contains everything the
    /// reader logged up to the moment of the throw.
    private nonisolated static func installUncaughtExceptionHandler(currentURL: URL) {
        handlerURL = currentURL
        NSSetUncaughtExceptionHandler { exception in
            guard let url = ReaderDiagnostics.handlerURL else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var entries: [Entry] = []
            if let data = try? Data(contentsOf: url),
               let decoded = try? decoder.decode([Entry].self, from: data) {
                entries = decoded
            }
            let stack = exception.callStackSymbols.prefix(20).joined(separator: " | ")
            entries.append(Entry(
                timestamp: Date(),
                kind: .uncaughtException,
                message: exception.name.rawValue,
                context: [
                    "reason": exception.reason ?? "",
                    "stack": stack
                ]
            ))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let outData = try? encoder.encode(entries) {
                try? outData.write(to: url, options: .atomic)
            }
        }
    }

    private func rotateSessionFiles() {
        let fm = FileManager.default
        // Move the previous run's "current" → "previous" so the prior
        // session's log is what the diagnostics screen displays. If the
        // app was force-quit or crashed during that session, this file
        // still holds whatever the throttled flusher had written.
        if fm.fileExists(atPath: currentURL.path) {
            try? fm.removeItem(at: previousURL)
            try? fm.moveItem(at: currentURL, to: previousURL)
        }
        if let data = try? Data(contentsOf: previousURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([Entry].self, from: data) {
                previous = decoded
            }
        }
    }

    private func observeLifecycleNotifications() {
        let center = NotificationCenter.default
        memoryObserver = center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log(.memoryWarning, "didReceiveMemoryWarning")
                self.flushNow()
            }
        }
        backgroundObserver = center.addObserver(
            forName: UIScene.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log(.lifecycle, "scene didEnterBackground")
                self.flushNow()
            }
        }
        willResignObserver = center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log(.lifecycle, "app willResignActive")
                self.flushNow()
            }
        }
    }

    private func format(_ entry: Entry, formatter: DateFormatter) -> String {
        let ts = formatter.string(from: entry.timestamp)
        let ctx: String
        if entry.context.isEmpty {
            ctx = ""
        } else {
            let pairs = entry.context
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
            ctx = " {" + pairs.joined(separator: ", ") + "}"
        }
        return "\(ts) [\(entry.kind.rawValue)] \(entry.message)\(ctx)"
    }

    private static func buildString() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

extension ReaderDiagnostics {
    /// Categories of events the reader emits. Strings are stable for
    /// JSON round-tripping; do not rename without a migration.
    enum Kind: String, Codable, Sendable, CaseIterable {
        case paginationStart
        case paginationEnd
        case paginationCancel
        case paginationFail
        case pageTurnStart
        case pageTurnEnd
        case chapterJump
        case taskStart
        case taskEnd
        case taskCancel
        case memoryWarning
        case uncaughtException
        case lifecycle
        case state
        case info

        /// SF Symbol used in the diagnostics list for quick visual scan.
        var symbolName: String {
            switch self {
            case .paginationStart, .paginationEnd, .paginationCancel, .paginationFail:
                return "doc.text"
            case .pageTurnStart, .pageTurnEnd, .chapterJump:
                return "arrow.left.arrow.right"
            case .taskStart, .taskEnd, .taskCancel:
                return "circle.dashed"
            case .memoryWarning:
                return "exclamationmark.triangle"
            case .uncaughtException:
                return "exclamationmark.octagon"
            case .lifecycle:
                return "power"
            case .state:
                return "location"
            case .info:
                return "info.circle"
            }
        }
    }

    struct Entry: Codable, Identifiable, Sendable, Hashable {
        let id: UUID
        let timestamp: Date
        let kind: Kind
        let message: String
        let context: [String: String]

        init(timestamp: Date, kind: Kind, message: String, context: [String: String]) {
            self.id = UUID()
            self.timestamp = timestamp
            self.kind = kind
            self.message = message
            self.context = context
        }
    }
}

/// High-level snapshot of "what the reader is doing right now." Logged at
/// every state-changing boundary so the prior session's last few entries
/// answer "where was the user when it crashed?" without needing to replay
/// every event by hand.
struct ReaderStateSnapshot: Sendable {
    let novelID: UUID
    let novelTitle: String
    let chapterIndex: Int
    let totalChapters: Int
    let chapterTitle: String
    let pageIndex: Int
    let totalPages: Int
    let pageSignature: String?

    func asContext() -> [String: String] {
        var ctx: [String: String] = [
            "novel": novelTitle,
            "novelID": novelID.uuidString.prefix(8).description,
            "ch": "\(chapterIndex)/\(max(totalChapters - 1, 0))",
            "chTitle": chapterTitle,
            "page": "\(pageIndex)/\(max(totalPages - 1, 0))"
        ]
        if let pageSignature, !pageSignature.isEmpty {
            ctx["sig"] = pageSignature
        }
        return ctx
    }
}
