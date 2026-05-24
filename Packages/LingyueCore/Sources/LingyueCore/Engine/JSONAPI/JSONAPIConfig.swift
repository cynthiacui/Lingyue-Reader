import Foundation

/// Declarative config for the JSON-API engine. Lives on a `SourceRule`
/// whose backing site exposes catalog/chapter data over JSON endpoints
/// instead of HTML.
/// Carries every site-specific bit — hosts, URL templates, ID-extraction
/// regexes, JSON paths, body transforms, boilerplate fragments — so the
/// engine itself stays generic and contains no per-site URLs. The
/// App Store binary can import a rule for any matching site and reach it
/// the moment the rule lands in `EditableSourceStore`.
///
/// The config is intentionally narrower than `SourceRule` (no search,
/// no detection — those still live on the rule). Catalog + chapter are
/// where the rule schema couldn't express what these sites do; the rest
/// stays declarative as before.
public struct JSONAPIConfig: Codable, Sendable, Hashable {
    /// Stable string identity the runtime exposes via `BookSource.id`.
    /// Lets legacy import-service paths look up a specific adapter by
    /// well-known string (e.g., `"json-api:my-adapter"`). Two rules
    /// claiming the same `sourceID` is a config bug — the loader does
    /// not deduplicate by this field, dedup remains UUID-based.
    public var sourceID: String

    /// Token name → regex patterns. The engine tries each pattern in
    /// order against the URL's path; the first match contributes its
    /// first capture group to the token. Tokens populate `{bookID}`,
    /// `{chapterID}`, etc. in URL templates below. A required token that
    /// no pattern resolves causes the request to throw `parseFailed`.
    ///
    /// For SPA-style hosts that put the route in `#/fragment`, the
    /// engine consults the fragment when `url.path` is empty or "/".
    public var idExtractors: [String: [String]]

    public var catalog: Catalog?
    public var chapter: Chapter?
    public var search: Search?
    public var detail: Detail?

    public init(
        sourceID: String,
        idExtractors: [String: [String]],
        catalog: Catalog? = nil,
        chapter: Chapter? = nil,
        search: Search? = nil,
        detail: Detail? = nil
    ) {
        self.sourceID = sourceID
        self.idExtractors = idExtractors
        self.catalog = catalog
        self.chapter = chapter
        self.search = search
        self.detail = detail
    }

    // MARK: - Search

    /// JSON-API search step. Used by sites that load search results from
    /// a JSON endpoint instead of an HTML search results page. A typical
    /// shape returns `{data:[{id,title,author,intro},…]}`; the rule's
    /// HTML `search` block stays optional — if both are present the JSON
    /// path wins.
    ///
    /// Two ways to resolve each result's detail URL:
    ///   1. `detailURLField` — path to a URL string inside the item.
    ///   2. `detailURLTemplate` + `idField` — synthesize from a numeric/string
    ///      ID. Required when the search endpoint returns IDs but not URLs
    ///      (the consumer then pivots from `{id}` back to a detail URL).
    /// Exactly one of these must be present; if both are set, the field path
    /// wins (it's the more authoritative source).
    public struct Search: Codable, Sendable, Hashable {
        /// Endpoint template list tried in order. First non-empty response
        /// wins. `{query}` is substituted via `URLTemplate.expand`.
        /// Mirror endpoints land here (sites that serve identical
        /// responses from multiple hostnames).
        public var endpointTemplates: [String]
        public var method: String?
        public var headers: [String: String]?
        public var queryEncoding: SourceEncoding?

        /// Dotted path into the JSON whose value is the items array.
        /// Empty string = the JSON root is itself the array.
        public var itemsPath: String

        public var titleField: String

        /// Path inside an item to a relative-or-absolute URL string. `nil`
        /// means the engine synthesizes detail URLs via `detailURLTemplate`.
        public var detailURLField: String?

        /// Used when `detailURLField` is nil. Token names match item field
        /// paths via `idField`. e.g., `https://www.bqgl.cc/book/{id}/` paired
        /// with `idField: "id"`. Numeric values are stringified, so a JSON
        /// `id: 15089` substitutes as `15089`.
        public var detailURLTemplate: String?
        public var idField: String?

        public var authorField: String?
        public var snippetField: String?
        public var coverField: String?

        public var titleTransforms: [TitleTransform]?

        public init(
            endpointTemplates: [String],
            method: String? = nil,
            headers: [String: String]? = nil,
            queryEncoding: SourceEncoding? = nil,
            itemsPath: String = "",
            titleField: String,
            detailURLField: String? = nil,
            detailURLTemplate: String? = nil,
            idField: String? = nil,
            authorField: String? = nil,
            snippetField: String? = nil,
            coverField: String? = nil,
            titleTransforms: [TitleTransform]? = nil
        ) {
            self.endpointTemplates = endpointTemplates
            self.method = method
            self.headers = headers
            self.queryEncoding = queryEncoding
            self.itemsPath = itemsPath
            self.titleField = titleField
            self.detailURLField = detailURLField
            self.detailURLTemplate = detailURLTemplate
            self.idField = idField
            self.authorField = authorField
            self.snippetField = snippetField
            self.coverField = coverField
            self.titleTransforms = titleTransforms
        }
    }

    // MARK: - Catalog

    public struct Catalog: Codable, Sendable, Hashable {
        /// URL templates tried in order. Any `{tokenName}` is replaced
        /// with the value extracted via `idExtractors`. Mirrors land
        /// here — first non-empty result wins.
        public var endpointTemplates: [String]

        /// Optional extra request headers (e.g., `Accept: application/json`).
        public var headers: [String: String]?

        /// Dotted path into the response JSON whose value is the array
        /// of chapter items. e.g., `"items"` or `"data.list"`.
        public var itemsPath: String

        /// Path inside an item to the chapter title. `nil` means the
        /// item is itself a bare string (shape: `{list:[...]}`).
        public var titleField: String?

        /// Path inside an item to a relative or absolute URL. `nil`
        /// means the engine synthesizes URLs via `urlTemplate`.
        public var urlField: String?

        /// Used when `urlField` is nil. `{index}` is the 1-based array
        /// position; any `idExtractors` token is also available. e.g.,
        /// `"/book/{bookID}/{index}.html"`.
        public var urlTemplate: String?

        public var titleTransforms: [TitleTransform]?

        public init(
            endpointTemplates: [String],
            headers: [String: String]? = nil,
            itemsPath: String,
            titleField: String? = nil,
            urlField: String? = nil,
            urlTemplate: String? = nil,
            titleTransforms: [TitleTransform]? = nil
        ) {
            self.endpointTemplates = endpointTemplates
            self.headers = headers
            self.itemsPath = itemsPath
            self.titleField = titleField
            self.urlField = urlField
            self.urlTemplate = urlTemplate
            self.titleTransforms = titleTransforms
        }
    }

    public enum TitleTransform: String, Codable, Sendable, Hashable {
        case decodeEntities
        case stripHTML
        case collapseWhitespace
        case trim
    }

    // MARK: - Chapter

    public struct Chapter: Codable, Sendable, Hashable {
        public var endpointTemplates: [String]
        public var headers: [String: String]?

        /// Dotted path to the chapter title. `nil` means the engine
        /// keeps the title carried in the originating `ChapterLink`.
        public var titleField: String?

        /// Dotted path to the chapter body string.
        public var bodyField: String

        /// Body cleanup pipeline applied in array order. Each transform
        /// is named below; unknown names are ignored so a future binary
        /// can extend the list without breaking older callers.
        public var bodyTransforms: [BodyTransform]?

        /// Strings the `filterBoilerplate` transform drops when found
        /// in a line short enough (≤ 80 chars) to plausibly be footer
        /// nav. Site-specific. The engine never hard-codes any of these.
        public var boilerplateFragments: [String]?

        public init(
            endpointTemplates: [String],
            headers: [String: String]? = nil,
            titleField: String? = nil,
            bodyField: String,
            bodyTransforms: [BodyTransform]? = nil,
            boilerplateFragments: [String]? = nil
        ) {
            self.endpointTemplates = endpointTemplates
            self.headers = headers
            self.titleField = titleField
            self.bodyField = bodyField
            self.bodyTransforms = bodyTransforms
            self.boilerplateFragments = boilerplateFragments
        }
    }

    // MARK: - Detail

    /// JSON-API detail step. Used by sites whose book pages are SPA
    /// shells (`<div id="app"></div>` with all data fetched client-side):
    /// the HTML fallback can't find a title or author because nothing has
    /// rendered yet. Biquge's `apiqu.cc/api/book?id=<bookID>` returns the
    /// metadata the SPA would normally hydrate from. Optional — if absent,
    /// the engine falls back to `RuleBasedBookSource.fetchDetail` (HTML).
    public struct Detail: Codable, Sendable, Hashable {
        /// Mirror list tried in order; first 2xx with the title field
        /// resolved wins. `{bookID}` and other `idExtractors` tokens are
        /// substituted via `applyTemplate`.
        public var endpointTemplates: [String]
        public var headers: [String: String]?

        /// Dotted path into the response JSON. Empty string = the JSON
        /// root is itself the detail object.
        public var itemsPath: String?

        public var titleField: String
        public var authorField: String?
        public var introField: String?
        public var categoryField: String?
        public var coverField: String?
        public var statusField: String?
        public var lastChapterField: String?

        public var titleTransforms: [TitleTransform]?

        public init(
            endpointTemplates: [String],
            headers: [String: String]? = nil,
            itemsPath: String? = nil,
            titleField: String,
            authorField: String? = nil,
            introField: String? = nil,
            categoryField: String? = nil,
            coverField: String? = nil,
            statusField: String? = nil,
            lastChapterField: String? = nil,
            titleTransforms: [TitleTransform]? = nil
        ) {
            self.endpointTemplates = endpointTemplates
            self.headers = headers
            self.itemsPath = itemsPath
            self.titleField = titleField
            self.authorField = authorField
            self.introField = introField
            self.categoryField = categoryField
            self.coverField = coverField
            self.statusField = statusField
            self.lastChapterField = lastChapterField
            self.titleTransforms = titleTransforms
        }
    }

    public enum BodyTransform: String, Codable, Sendable, Hashable {
        case normalizeLineEndings
        case brToNewline
        case stripHTML
        case decodeEntities
        case filterBoilerplate
        case splitLines
        case trim
    }
}
