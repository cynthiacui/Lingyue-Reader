import XCTest
@testable import LingyueCore

/// End-to-end check that the actual `docs/lingyue-sources.json` shipped
/// with the repo decodes cleanly under the App Store target's import
/// path. The Swift Package test target can't link the iOS app's
/// `SourceImportService`, but it can rebuild the same decoder against
/// the same envelope, which is what `SourceImportService.decode()`
/// does internally.
///
/// What this verifies, beyond the per-file `Phase2SeededRuleTests`:
///   - The aggregated envelope produced by `Scripts/build-sources-json.sh`
///     round-trips through `JSONDecoder` exactly as user-imported bytes
///     would.
///   - Every rule in the envelope, jsonAPI-flagged or not, instantiates
///     a `BookSource` via `makeBookSource(loader:)`.
///   - The two jsonAPI rules route to `JSONAPIBookSource` and carry the
///     correct `sourceID`s (`json-api:5dxs`, `json-api:biquge-api`),
///     which are the IDs `BookImportService` looks up on the App Store
///     target to reach the registry-routed catalog/chapter path.
final class SourceImportRoundTripTests: XCTestCase {

    /// The same envelope shape `lingyue/Data/SourceImportService.swift`
    /// expects. Duplicated here on purpose — the test exercises the
    /// envelope contract, not the production type, so a typo in either
    /// side surfaces as a test failure rather than a runtime decode
    /// error in front of the user.
    private struct EnvelopePayload: Decodable {
        let kind: String
        let version: Int
        let sources: [SourceRule]
    }

    func testDocsSourcesJSONDecodesAndRoutes() throws {
        let url = try Self.locateDocsJSON()
        let data = try Data(contentsOf: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: EnvelopePayload
        do {
            payload = try decoder.decode(EnvelopePayload.self, from: data)
        } catch {
            XCTFail("docs/lingyue-sources.json failed to decode: \(error)")
            return
        }

        XCTAssertEqual(payload.kind, "lingyue-sources")
        XCTAssertEqual(payload.version, 1)
        XCTAssertFalse(payload.sources.isEmpty, "envelope should ship at least one rule")

        let loader = StubLoader()
        var jsonAPIIDs: [String] = []
        for rule in payload.sources {
            let source = rule.makeBookSource(loader: loader)
            XCTAssertFalse(source.id.isEmpty, "rule \(rule.name) produced empty BookSource.id")
            if let api = rule.jsonAPI {
                XCTAssertTrue(
                    source is JSONAPIBookSource,
                    "rule with jsonAPI should route to JSONAPIBookSource: \(rule.name)"
                )
                XCTAssertEqual(source.id, api.sourceID)
                jsonAPIIDs.append(api.sourceID)
            } else {
                XCTAssertTrue(
                    source is RuleBasedBookSource,
                    "rule without jsonAPI should route to RuleBasedBookSource: \(rule.name)"
                )
            }
        }

        let expected: Set<String> = ["json-api:5dxs", "json-api:biquge-api"]
        XCTAssertEqual(
            Set(jsonAPIIDs), expected,
            "docs JSON must expose both jsonAPI sources for App Store imports"
        )
    }

    private static func locateDocsJSON() throws -> URL {
        // Walk up from this source file to the repo root, then point at
        // docs/lingyue-sources.json. Avoiding bundle resources here keeps
        // the test honest — it reads the same file a user would download.
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = current
                .appendingPathComponent("docs")
                .appendingPathComponent("lingyue-sources.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            current.deleteLastPathComponent()
        }
        throw XCTSkip("docs/lingyue-sources.json not found; run Scripts/build-sources-json.sh")
    }
}

private struct StubLoader: SourceHTMLLoading {
    func fetchHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        throw BookSourceError.loadFailed(reason: "stub")
    }
    func renderHTML(_ request: SourceRequest) async throws -> WebPageSnapshot {
        throw BookSourceError.loadFailed(reason: "stub")
    }
}
