import Foundation

/// Declarative description of one source site. A `SourceRule` is pure
/// data — no executable code — which is what lets us ship the rule editor
/// to the App Store: users author rules but the app interprets them, the
/// app never `eval`s anything.
///
/// One rule covers all four steps (search → detail → catalog → chapter)
/// because they almost always live on the same host with shared headers,
/// encoding, and engine selection. The `SearchStep` field is optional —
/// browser-only sources (Cloudflare-gated, etc.) omit it and ride the
/// in-app browser plus `DetectionStep` instead.
///
/// The rule editor UI sees this directly (Settings → Sources →
/// Add/Edit). Runtime consumers do not — they go through `BookSource`
/// and never reach into this schema. That separation is what makes
/// editing concerns orthogonal to runtime concerns.
public struct SourceRule: Codable, Sendable, Hashable, Identifiable {
    /// Storage identity — stable across edits to `name`, `homepage`, etc.
    /// Persisted by `EditableSourceStore`. Surfaced to runtime only inside
    /// the namespaced `BookSource.id` ("rule:<uuid>") so UUIDs don't leak
    /// into UI or diagnostics.
    public var id: UUID

    /// Schema version. Bumped when the engine learns a new transform or
    /// step shape that older binaries can't interpret. Older builds that
    /// see a rule with a future version disable the rule and surface a
    /// "needs newer app" notice rather than half-applying it.
    public var schemaVersion: Int

    /// User-visible name. Editable.
    public var name: String

    /// Homepage URL. Mostly informational ("open in browser" button) but
    /// the engine also uses its host as the throttling bucket key when a
    /// rule's per-step URLs scatter across subdomains.
    public var homepage: URL

    /// Capabilities the rule author asserts. The engine treats this as
    /// declaration: e.g., `supportsSearch = true` plus no `searchStep`
    /// is an invalid rule and surfaces `ruleIncomplete(field: "searchStep")`
    /// at first use.
    public var capabilities: SourceCapabilities

    /// Per-step engine selection (HTTP vs. headless render).
    public var enginePerStep: EnginePerStep

    /// Default character encoding for response bodies on this host.
    public var encoding: SourceEncoding

    /// Headers applied to every request issued for this source on top of
    /// the loader defaults. Common entries: User-Agent override, Accept-Language.
    public var defaultHeaders: [String: String]

    /// Detection step is required — that's what lets the in-app browser
    /// recognize the source's pages even if the rule has no search step.
    public var detection: DetectionStep

    /// Optional. Present when `capabilities.supportsSearch` is true.
    public var search: SearchStep?

    /// Required. The catalog yields the chapter list; the chapter step
    /// yields the body. Every functional rule must define both.
    public var detail: DetailStep
    public var catalog: CatalogStep
    public var chapter: ChapterStep

    /// Routes the rule onto the generic JSON-API engine instead of the
    /// HTML-selector engine. `nil` (the default for every hand-authored
    /// or analyzer-produced rule) means "use `RuleBasedBookSource`" and
    /// the engine consults `detection` / `detail` / `catalog` / `chapter`
    /// the usual way. A non-nil value carries every site-specific
    /// detail (endpoint templates, ID-extraction regexes, JSON paths,
    /// body transforms, boilerplate fragments) — the engine's Swift
    /// side is fully generic and contains no per-site URLs, which is
    /// what lets the App Store target run a JSON-API-shaped source
    /// after the user imports the JSON.
    ///
    /// The rule's step fields are still required by the schema when
    /// `jsonAPI != nil`, but the JSON-API engine ignores them at fetch
    /// time. Authors typically fill them with the same selectors a
    /// detail-page HTML scrape would use, so the in-app browser's
    /// detection step (which still runs against `detection`) keeps
    /// recognizing the site.
    public var jsonAPI: JSONAPIConfig?

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = SourceRule.currentSchemaVersion,
        name: String,
        homepage: URL,
        capabilities: SourceCapabilities,
        enginePerStep: EnginePerStep = .default,
        encoding: SourceEncoding = .auto,
        defaultHeaders: [String: String] = [:],
        detection: DetectionStep,
        search: SearchStep? = nil,
        detail: DetailStep,
        catalog: CatalogStep,
        chapter: ChapterStep,
        jsonAPI: JSONAPIConfig? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = name
        self.homepage = homepage
        self.capabilities = capabilities
        self.enginePerStep = enginePerStep
        self.encoding = encoding
        self.defaultHeaders = defaultHeaders
        self.detection = detection
        self.search = search
        self.detail = detail
        self.catalog = catalog
        self.chapter = chapter
        self.jsonAPI = jsonAPI
    }

    /// Schema version this binary writes. Bump when a non-backwards-
    /// compatible field is added.
    public static let currentSchemaVersion: Int = 1
}

// MARK: - Field selectors

/// One extraction: an optional CSS selector, an attribute (or `text` for
/// `Element.text()`), and a chain of transforms.
///
/// `selector == nil` means "operate on the page as a whole" — used for
/// e.g. running a regex against the raw HTML when the site has no clean
/// selector to grab. `attribute == nil` defaults to `text`.
public struct FieldSelector: Codable, Sendable, Hashable {
    public var selector: String?
    public var attribute: String?
    public var transforms: [SourceTransform]

    public init(
        selector: String? = nil,
        attribute: String? = nil,
        transforms: [SourceTransform] = []
    ) {
        self.selector = selector
        self.attribute = attribute
        self.transforms = transforms
    }
}

// MARK: - Detection

/// Recognizes whether a given `WebPageSnapshot` is a book-detail page for
/// this source. Used by the in-app browser's Import affordance.
public struct DetectionStep: Codable, Sendable, Hashable {
    /// Host patterns that must match `snapshot.finalURL.host`. Glob style:
    /// `*.example.com` or `example.com`. Empty means "any host" (rare;
    /// usually a misconfiguration).
    public var hostPatterns: [String]

    /// URL path regex. The page is only considered a candidate if the
    /// path matches. Common pattern: `^/book/\d+/?$`.
    public var pathPattern: String?

    /// Selector that, when it resolves to a non-empty element, confirms
    /// this is a book-detail page. Lets a rule distinguish a detail page
    /// from a search results page that share the host.
    public var confirmSelector: String?

    /// Optional extraction of the canonical detail URL. When omitted the
    /// engine falls back to `snapshot.finalURL`.
    public var canonicalURL: FieldSelector?

    public init(
        hostPatterns: [String],
        pathPattern: String? = nil,
        confirmSelector: String? = nil,
        canonicalURL: FieldSelector? = nil
    ) {
        self.hostPatterns = hostPatterns
        self.pathPattern = pathPattern
        self.confirmSelector = confirmSelector
        self.canonicalURL = canonicalURL
    }
}

// MARK: - Search

/// Search endpoint description. Templated URL/body — `{query}` is
/// substituted with the percent-encoded user query at request time.
public struct SearchStep: Codable, Sendable, Hashable {
    public enum Method: String, Codable, Sendable, Hashable {
        case get
        case post
    }

    public var method: Method

    /// URL template. `{query}` is replaced with the URL-encoded query.
    /// Example: `https://example.com/search?q={query}&type=book`.
    public var urlTemplate: String

    /// Body template for `POST`. `nil` for `GET`. Same `{query}` rule.
    public var bodyTemplate: String?

    /// Encoding applied to the user's query before it is substituted into
    /// `urlTemplate` / `bodyTemplate`. `nil` ⇒ UTF-8.
    /// Why: legacy mainland CMS deployments (Empire CMS clones especially)
    /// still percent-decode form fields as GB18030 server-side. A UTF-8
    /// query reaches the search handler as garbled bytes and silently
    /// returns zero results, which looks like a working source until you
    /// try a real query. Optional for backward compatibility with seeded
    /// rules written before the field existed.
    public var queryEncoding: SourceEncoding?

    /// Selector matching each search result row.
    public var resultsSelector: String

    /// Sub-selectors run within each result row.
    public var titleField: FieldSelector
    public var detailURLField: FieldSelector
    public var authorField: FieldSelector?
    public var coverField: FieldSelector?
    public var snippetField: FieldSelector?

    /// When `true`, the engine rewrites the user's query before it is sent:
    /// `_ | ｜ · ・` separators become spaces and `【…】（…）[…]` annotation
    /// blocks are dropped. Why: some sites store a book's title munged with
    /// its author and a status tag — `霸宠_笑佳人【完结】` — and their search
    /// backend tokenizes on spaces with AND semantics. A literal `霸宠_笑佳人`
    /// matches nothing, but `霸宠 笑佳人` matches. This makes pasting a
    /// displayed result title (or a `书名_作者` string) actually find the
    /// book. `nil` ⇒ no rewrite (the default; required for path-based query
    /// templates like `/list/{query}.html` where a space would break the URL).
    public var normalizeQuerySeparators: Bool?

    /// Optional title-autocomplete endpoint. When present, the engine first
    /// queries it, then runs the normal search for the user's query *plus*
    /// the top suggestions, merging the hits. Why: a class of sites
    /// (52书库 et al.) expose `/so/search.php` as a *full-text* search that
    /// dilutes short title queries into unrelated filler — searching the real
    /// title `霸宠` never surfaces `霸宠_笑佳人`. Their autocomplete endpoint,
    /// by contrast, prefix-matches titles (`term=霸宠` → `["霸宠暗卫","霸宠 笑佳人",…]`),
    /// and each suggestion fed back into the search returns the exact book.
    public var suggest: SuggestStep?

    public init(
        method: Method = .get,
        urlTemplate: String,
        bodyTemplate: String? = nil,
        queryEncoding: SourceEncoding? = nil,
        resultsSelector: String,
        titleField: FieldSelector,
        detailURLField: FieldSelector,
        authorField: FieldSelector? = nil,
        coverField: FieldSelector? = nil,
        snippetField: FieldSelector? = nil,
        normalizeQuerySeparators: Bool? = nil,
        suggest: SuggestStep? = nil
    ) {
        self.method = method
        self.urlTemplate = urlTemplate
        self.bodyTemplate = bodyTemplate
        self.queryEncoding = queryEncoding
        self.resultsSelector = resultsSelector
        self.titleField = titleField
        self.detailURLField = detailURLField
        self.authorField = authorField
        self.coverField = coverField
        self.snippetField = snippetField
        self.normalizeQuerySeparators = normalizeQuerySeparators
        self.suggest = suggest
    }
}

// MARK: - Suggest

/// Title-autocomplete endpoint paired with a `SearchStep`. The endpoint is
/// expected to return a JSON array of strings — the shape every mainstream
/// Chinese novel site's search-box autocomplete uses, e.g.
/// `["霸宠暗卫","霸宠 笑佳人","霸宠天下"]`.
public struct SuggestStep: Codable, Sendable, Hashable {
    /// URL template for the autocomplete endpoint. `{query}` is replaced
    /// with the URL-encoded query. Example:
    /// `https://www.52shuku.net/so/suggest.php?term={query}`.
    public var urlTemplate: String

    /// How many of the returned suggestions to expand into real searches.
    /// `nil` ⇒ a conservative default (5). Capped to bound request fan-out.
    public var maxSuggestions: Int?

    public init(urlTemplate: String, maxSuggestions: Int? = nil) {
        self.urlTemplate = urlTemplate
        self.maxSuggestions = maxSuggestions
    }
}

// MARK: - Detail

/// Extracts a `BookDetail` from a detail page snapshot.
public struct DetailStep: Codable, Sendable, Hashable {
    public var titleField: FieldSelector
    public var authorField: FieldSelector?
    public var coverField: FieldSelector?
    public var descriptionField: FieldSelector?
    public var statusField: FieldSelector?
    public var statisticsField: FieldSelector?

    /// Tag list — selector resolves to multiple elements; transforms apply
    /// to each. Empty selector → empty tag list.
    public var tagsField: FieldSelector?

    /// Where to find the catalog URL. Some sites put chapters inline on
    /// the detail page; for those the rule sets `catalogURLField` to a
    /// selector that resolves back to the detail page itself.
    public var catalogURLField: FieldSelector

    public init(
        titleField: FieldSelector,
        authorField: FieldSelector? = nil,
        coverField: FieldSelector? = nil,
        descriptionField: FieldSelector? = nil,
        statusField: FieldSelector? = nil,
        statisticsField: FieldSelector? = nil,
        tagsField: FieldSelector? = nil,
        catalogURLField: FieldSelector
    ) {
        self.titleField = titleField
        self.authorField = authorField
        self.coverField = coverField
        self.descriptionField = descriptionField
        self.statusField = statusField
        self.statisticsField = statisticsField
        self.tagsField = tagsField
        self.catalogURLField = catalogURLField
    }
}

// MARK: - Catalog

/// Extracts a list of `ChapterLink`s from a catalog page. Pagination is
/// followed by the engine when `nextPageField` resolves to a non-empty URL.
public struct CatalogStep: Codable, Sendable, Hashable {
    /// Selector matching each chapter row.
    public var chaptersSelector: String

    /// Sub-selectors within each chapter row.
    public var titleField: FieldSelector
    public var urlField: FieldSelector

    /// Optional volume label — selector resolves to the volume heading
    /// that precedes a group of chapters in the DOM. Engine carries the
    /// most recent volume forward as it walks chapter rows.
    public var volumeField: FieldSelector?

    /// Selector for "next catalog page" link. When it resolves, the
    /// engine follows the link, parses again, and concatenates. Empty
    /// resolution stops the walk.
    public var nextPageField: FieldSelector?

    /// Sanity cap on pagination depth. Stops a runaway crawl in case a
    /// rule's `nextPageField` accidentally matches a non-pagination link.
    public var maxPages: Int

    public init(
        chaptersSelector: String,
        titleField: FieldSelector,
        urlField: FieldSelector,
        volumeField: FieldSelector? = nil,
        nextPageField: FieldSelector? = nil,
        maxPages: Int = 200
    ) {
        self.chaptersSelector = chaptersSelector
        self.titleField = titleField
        self.urlField = urlField
        self.volumeField = volumeField
        self.nextPageField = nextPageField
        self.maxPages = maxPages
    }
}

// MARK: - Chapter

/// Extracts the body of one chapter page.
public struct ChapterStep: Codable, Sendable, Hashable {
    public var titleField: FieldSelector

    /// Selector matching the chapter body container. Transforms typically
    /// include `.brToNewline`, `.stripHTML`, `.collapseWhitespace`.
    public var bodyField: FieldSelector

    /// "next chapter" link, optional.
    public var nextChapterField: FieldSelector?

    /// "previous chapter" link, optional.
    public var previousChapterField: FieldSelector?

    /// If the chapter body is itself paginated across multiple URLs, the
    /// engine follows this selector and concatenates. Empty resolution
    /// stops the walk.
    public var nextBodyPageField: FieldSelector?

    /// Sanity cap on body pagination depth.
    public var maxBodyPages: Int

    public init(
        titleField: FieldSelector,
        bodyField: FieldSelector,
        nextChapterField: FieldSelector? = nil,
        previousChapterField: FieldSelector? = nil,
        nextBodyPageField: FieldSelector? = nil,
        maxBodyPages: Int = 20
    ) {
        self.titleField = titleField
        self.bodyField = bodyField
        self.nextChapterField = nextChapterField
        self.previousChapterField = previousChapterField
        self.nextBodyPageField = nextBodyPageField
        self.maxBodyPages = maxBodyPages
    }
}
