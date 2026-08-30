import Foundation
import Combine

/// Navigation-only state. Keeping chapter/page transitions together gives the pager one
/// source of truth and prevents loading/pagination code from growing its own shadow index.
@MainActor
final class ReaderNavigationState: ObservableObject {
    @Published var chapterIndex = 0
    @Published var chapterPageIndex = 0
    @Published var didSetInitialPage = false
    @Published var lastPersistedReadingState: String?
    @Published var pendingRestoreChapterKey: String?
    @Published var pendingRestoreChapterPageIndex: Int?
    @Published var pagerVersion = 0
    /// Bumped for every explicit navigation (buttons, picker, slider, boundary
    /// fallback). The continuous pager voids in-flight gesture landings that began
    /// under an older epoch instead of being torn down via `.id` — a mid-session
    /// identity swap permanently stopped SwiftUI representable updates on iOS 26.
    @Published var navigationEpoch = 0
    @Published var boundarySwipeStartPageIndex: Int?
}

/// Owns chapter acquisition/catalog-repair state. ReaderView renders these values but no
/// longer stores a second copy of the repository lifecycle in unrelated UI state.
@MainActor
final class ReaderChapterRepository: ObservableObject {
    @Published var loadedOverrides: [String: NovelChapter] = [:]
    @Published var loadingKeys: Set<String> = []
    @Published var loadErrors: [String: String] = [:]
    @Published var downloadedKeys: Set<String> = []
    @Published var repairedNovel: Novel?
    @Published var isRepairingCatalog = false
    @Published var catalogRepairError: String?
}

/// Bounded least-recently-used pagination cache. Reads and writes both promote an entry;
/// protected signatures let the reader keep its current navigation window resident while
/// speculative work fills more distant chapters.
struct ReaderPaginationCache {
    struct Metrics: Sendable, Equatable {
        let capacity: Int
        let entries: Int
        let hitCount: Int
        let missCount: Int
        let evictionCount: Int
        let memoryTrimmedCount: Int
    }

    private let capacity: Int
    private var pagesBySignature: [String: [String]] = [:]
    private var accessOrder: [String] = []
    private var hitCount = 0
    private var missCount = 0
    private var evictionCount = 0
    private var memoryTrimmedCount = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    subscript(signature: String) -> [String]? {
        mutating get { pages(for: signature) }
    }

    var count: Int { pagesBySignature.count }

    var metrics: Metrics {
        Metrics(
            capacity: capacity,
            entries: pagesBySignature.count,
            hitCount: hitCount,
            missCount: missCount,
            evictionCount: evictionCount,
            memoryTrimmedCount: memoryTrimmedCount
        )
    }

    mutating func pages(for signature: String) -> [String]? {
        guard let pages = pagesBySignature[signature] else {
            missCount &+= 1
            return nil
        }
        hitCount &+= 1
        touch(signature)
        return pages
    }

    mutating func insert(
        _ pages: [String],
        for signature: String,
        protecting protectedSignatures: Set<String> = []
    ) {
        pagesBySignature[signature] = pages
        touch(signature)

        let protected = protectedSignatures.union([signature])
        while pagesBySignature.count > capacity {
            let staleIndex = accessOrder.firstIndex(where: {
                pagesBySignature[$0] != nil && !protected.contains($0)
            }) ?? accessOrder.firstIndex(where: {
                pagesBySignature[$0] != nil && $0 != signature
            })
            guard let staleIndex else { break }
            let staleSignature = accessOrder.remove(at: staleIndex)
            pagesBySignature[staleSignature] = nil
            evictionCount &+= 1
        }
    }

    private mutating func touch(_ signature: String) {
        accessOrder.removeAll { $0 == signature }
        accessOrder.append(signature)
    }

    mutating func removeAll() {
        pagesBySignature.removeAll()
        accessOrder.removeAll()
    }

    /// Releases speculative entries under memory pressure while retaining the reader's
    /// immediate navigation window. Returns the number of discarded page arrays.
    @discardableResult
    mutating func retainOnly(signatures: Set<String>) -> Int {
        let staleSignatures = pagesBySignature.keys.filter { !signatures.contains($0) }
        guard !staleSignatures.isEmpty else { return 0 }
        for signature in staleSignatures {
            pagesBySignature[signature] = nil
        }
        accessOrder.removeAll { pagesBySignature[$0] == nil }
        memoryTrimmedCount &+= staleSignatures.count
        return staleSignatures.count
    }
}

/// Stable, process-independent content revision for pagination cache keys.
enum ReaderContentRevision {
    static func fingerprint(title: String, content: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        func absorb(_ bytes: String.UTF8View) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
        }

        absorb(title.utf8)
        hash ^= 0
        hash = hash &* prime
        absorb(content.utf8)
        return String(hash, radix: 16)
    }
}

/// Reader-lifetime memoization of chapter revisions. Values are bounded so metadata cannot
/// grow with an arbitrarily large catalog.
@MainActor
final class ReaderContentRevisionStore {
    private struct Entry {
        let title: String
        let content: String
        let revision: String
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var accessOrder: [String] = []

    init(capacity: Int = 128) {
        self.capacity = max(capacity, 1)
    }

    func revision(for chapter: NovelChapter, key: String) -> String {
        if let entry = entries[key],
           entry.title == chapter.title,
           entry.content == chapter.content {
            touch(key)
            return entry.revision
        }

        let revision = ReaderContentRevision.fingerprint(
            title: chapter.title,
            content: chapter.content
        )
        entries[key] = Entry(title: chapter.title, content: chapter.content, revision: revision)
        touch(key)
        trimIfNeeded()
        return revision
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func trimIfNeeded() {
        while entries.count > capacity, let stale = accessOrder.first {
            accessOrder.removeFirst()
            entries.removeValue(forKey: stale)
        }
    }

    func removeAll() {
        entries.removeAll()
        accessOrder.removeAll()
    }
}

/// Owns all pagination products and their cache. Layout calculation remains a pure helper
/// in ReaderView for now; moving state first keeps this extraction behavior-preserving.
@MainActor
final class ReaderPaginationCoordinator: ObservableObject {
    @Published var visiblePages: [ReaderPageItem] = []
    @Published var visibleSignature: String?
    @Published var lastTextSize: CGSize = .zero
    @Published var shouldJumpToLastPage = false
    let contentRevisions = ReaderContentRevisionStore()
    private var cache = ReaderPaginationCache(capacity: 24)

    var cacheCount: Int { cache.count }
    var cacheMetrics: ReaderPaginationCache.Metrics { cache.metrics }

    /// Cache hits update LRU metadata without publishing a SwiftUI state change. Publishing
    /// from a body-time read would cause a render feedback loop.
    func cachedPages(for signature: String) -> [String]? {
        cache.pages(for: signature)
    }

    func storePages(
        _ pages: [String],
        for signature: String,
        protecting protectedSignatures: Set<String>
    ) {
        objectWillChange.send()
        cache.insert(pages, for: signature, protecting: protectedSignatures)
    }

    func clearCache() {
        guard cache.count > 0 else { return }
        objectWillChange.send()
        cache.removeAll()
    }

    @discardableResult
    func handleMemoryPressure(protecting protectedSignatures: Set<String>) -> Int {
        contentRevisions.removeAll()
        let removedCount = cache.retainOnly(signatures: protectedSignatures)
        if removedCount > 0 {
            objectWillChange.send()
        }
        return removedCount
    }
}
