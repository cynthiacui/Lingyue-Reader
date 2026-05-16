import Foundation

/// Pairs a `BookDetection` with the source that produced it. Returned to
/// the in-app browser so the Import affordance can show
/// `从 <sourceName> 导入` and the import action can route by `sourceID`
/// without re-resolving the source.
public struct DetectionResult: Sendable, Hashable {
    public var detection: BookDetection
    public var sourceID: String
    public var sourceName: String

    public init(detection: BookDetection, sourceID: String, sourceName: String) {
        self.detection = detection
        self.sourceID = sourceID
        self.sourceName = sourceName
    }
}

/// Fan-out detector for the in-app browser. Every page load in
/// `InAppBrowserView` builds a `WebPageSnapshot` and calls `detect(in:)`;
/// the detector races `BookSource.detectBook(in:)` across every enabled,
/// browser-import-capable source, picks the highest-confidence non-nil
/// hit (registry order breaks ties), and caches the outcome keyed by
/// post-redirect `finalURL` plus the rendered HTML hash so back/forward
/// navigation is cheap without freezing an early incomplete DOM miss.
///
/// **Module boundary.** Depends only on `BookSourceRegistry` —
/// LingyueCore must not link `LingyueInternalSources` here. Both
/// `InternalSourceRegistry` and the future App Store registry conform
/// to the protocol; callers pick the right concrete instance.
///
/// **Cache invalidation.** The cache is keyed by page snapshot, but it
/// still has no knowledge of which source produced each cached hit. When
/// the user toggles a source on/off, reorders the list, edits or deletes
/// a rule, or flips a validation result, callers must call
/// `invalidateCache()` — otherwise a now-disabled source's prior hit will
/// keep flashing on matching pages. Phase 4 §4.6 wires these call sites.
public actor PageDetector {
    private let registry: any BookSourceRegistry
    private let cacheCapacity: Int
    private var cache: [String: CachedEntry] = [:]
    private var order: [String] = []

    public init(registry: any BookSourceRegistry, cacheCapacity: Int = 64) {
        self.registry = registry
        self.cacheCapacity = max(1, cacheCapacity)
    }

    /// Race every browser-import-capable source's detector against the
    /// snapshot. Per-source thrown errors are treated as misses
    /// (debug-logged) rather than failing the whole pass — a single
    /// rule with a broken `detectBook` must not blind the browser to
    /// every other source on the page.
    public func detect(in snapshot: WebPageSnapshot) async -> DetectionResult? {
        let key = cacheKey(for: snapshot)
        if let cached = cache[key] {
            touch(key)
            #if DEBUG
            print("[PageDetector] cache hit \(key) — source=\(cached.result?.sourceID ?? "nil")")
            #endif
            return cached.result
        }

        #if DEBUG
        let started = DispatchTime.now()
        #endif
        let result = await runFanOut(snapshot: snapshot)
        record(key: key, result: result)
        #if DEBUG
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        print(String(
            format: "[PageDetector] fan-out %.1fms url=%@ winner=%@",
            elapsedMs,
            key,
            result?.sourceID ?? "nil"
        ))
        #endif
        return result
    }

    /// Drop every cached entry. Call from any code path that changes
    /// the *set* of detectable sources — enable/disable toggle, rule
    /// save/delete, validation Enable, registry refresh. The snapshot
    /// cache otherwise has no way to know its prior winner is gone.
    public func invalidateCache() {
        cache.removeAll()
        order.removeAll()
    }

    private func cacheKey(for snapshot: WebPageSnapshot) -> String {
        "\(snapshot.finalURL.absoluteString)#html=\(snapshot.html.hashValue)"
    }

    // MARK: - Fan-out

    private func runFanOut(snapshot: WebPageSnapshot) async -> DetectionResult? {
        let sources: [any BookSource]
        do {
            sources = try await registry.enabledSources()
        } catch {
            #if DEBUG
            print("[PageDetector] enabledSources failed: \(error)")
            #endif
            return nil
        }

        // Browser-import detection only fans out across sources whose
        // detail+catalog+chapter blocks validated (capability derivation
        // gates that). Search-only rules don't claim to recognize a page
        // and would only produce noise here.
        let candidates: [(index: Int, source: any BookSource)] = sources
            .enumerated()
            .compactMap { offset, source in
                source.capabilities.supportsBrowserImport ? (offset, source) : nil
            }

        guard !candidates.isEmpty else { return nil }

        let hits: [DetectionHit] = await withTaskGroup(of: DetectionHit?.self) { group in
            for entry in candidates {
                let index = entry.index
                let source = entry.source
                group.addTask {
                    do {
                        guard let detection = try await source.detectBook(in: snapshot) else {
                            return nil
                        }
                        return DetectionHit(
                            registryIndex: index,
                            detection: detection,
                            sourceID: source.id,
                            sourceName: source.displayName
                        )
                    } catch {
                        #if DEBUG
                        print("[PageDetector] \(source.id) detect threw: \(error)")
                        #endif
                        return nil
                    }
                }
            }
            var collected: [DetectionHit] = []
            for await hit in group {
                if let hit { collected.append(hit) }
            }
            return collected
        }

        guard let winner = hits.sorted(by: Self.tiebreak).first else { return nil }
        return DetectionResult(
            detection: winner.detection,
            sourceID: winner.sourceID,
            sourceName: winner.sourceName
        )
    }

    /// Confidence desc, registry index asc. Equal confidence falls
    /// back to the user's source-list ordering (lower index = higher
    /// priority).
    private static func tiebreak(_ lhs: DetectionHit, _ rhs: DetectionHit) -> Bool {
        if lhs.detection.confidence != rhs.detection.confidence {
            return lhs.detection.confidence > rhs.detection.confidence
        }
        return lhs.registryIndex < rhs.registryIndex
    }

    // MARK: - LRU bookkeeping

    private func touch(_ key: String) {
        if let position = order.firstIndex(of: key) {
            order.remove(at: position)
            order.append(key)
        }
    }

    private func record(key: String, result: DetectionResult?) {
        cache[key] = CachedEntry(result: result)
        if let position = order.firstIndex(of: key) {
            order.remove(at: position)
        }
        order.append(key)
        while cache.count > cacheCapacity, let evict = order.first {
            cache.removeValue(forKey: evict)
            order.removeFirst()
        }
    }
}

/// Wrapper so the cache can store "ran the fan-out, nothing matched"
/// distinctly from "haven't checked this URL yet" — a plain
/// `[String: DetectionResult?]` would force a double-optional read.
private struct CachedEntry: Sendable {
    let result: DetectionResult?
}

/// Internal tally for the fan-out. Carries the registry position so the
/// tiebreak can prefer earlier sources without re-resolving them.
private struct DetectionHit: Sendable {
    let registryIndex: Int
    let detection: BookDetection
    let sourceID: String
    let sourceName: String
}
