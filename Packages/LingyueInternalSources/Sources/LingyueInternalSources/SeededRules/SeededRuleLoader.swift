import Foundation
import LingyueCore

/// Loads bundled `SourceRule` JSONs that ship in
/// `Resources/SeededRules/` inside the `LingyueInternalSources`
/// package. The Internal target's `BookSourceRegistry` merges these on
/// top of user-authored rules so testers get a working source list
/// without authoring from scratch.
///
/// The App Store target never links this package, so seeded rules
/// cannot leak into the App Store binary — see the multi-surface scan
/// in Phase 5.4.
///
/// Decoding errors are not silently swallowed: a malformed bundled
/// JSON is a build bug, and `loadAll()` surfaces it as an empty result
/// plus a diagnostic on `decodeFailures`. Tests assert the bundled set
/// decodes cleanly so a broken JSON never ships.
public enum SeededRuleLoader {
    /// Result of a load pass. `rules` are the cleanly decoded entries,
    /// `decodeFailures` lists per-file errors so a failing JSON does
    /// not block the rest of the bundle but also does not vanish.
    public struct LoadResult: Sendable {
        public let rules: [SourceRule]
        public let decodeFailures: [(filename: String, error: String)]
    }

    /// Loads every JSON under `Resources/SeededRules/` from the package
    /// bundle and decodes it as a `SourceRule`. Order is filename-sorted
    /// for determinism.
    public static func loadAll() -> LoadResult {
        loadAll(bundle: .module)
    }

    /// Same as `loadAll()` but lets a caller override the bundle. Used
    /// only by tests that want to point at a fixture directory; the
    /// production path always uses `.module`.
    static func loadAll(bundle: Bundle) -> LoadResult {
        guard let urls = bundle.urls(
            forResourcesWithExtension: "json",
            subdirectory: "SeededRules"
        ) else {
            return LoadResult(rules: [], decodeFailures: [])
        }
        let sorted = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var rules: [SourceRule] = []
        var failures: [(String, String)] = []
        let decoder = JSONDecoder()
        for url in sorted {
            do {
                let data = try Data(contentsOf: url)
                let rule = try decoder.decode(SourceRule.self, from: data)
                rules.append(rule)
            } catch {
                failures.append((url.lastPathComponent, String(describing: error)))
            }
        }
        return LoadResult(rules: rules, decodeFailures: failures)
    }
}
