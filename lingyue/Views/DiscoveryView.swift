import SwiftUI
import Foundation

struct DiscoveryView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTheme) private var theme

    @State private var searchText = ""
    @State private var activeSearchQuery: String?
    @State private var browserDestination: DiscoveryBrowserDestination?
    @FocusState private var isSearchFieldFocused: Bool

    // Search state lives at this level so popping back from an in-app browser doesn't
    // recreate DiscoverySearchResultsView from scratch and re-fire the search.
    @State private var searchResultsQuery: String?
    @State private var searchIsLoading = false
    @State private var searchFailedMessage: String?
    @State private var searchGroupedResults: [DiscoveryGroupedResult] = []

    // Recent searches are stored as a JSON-encoded `[String]` blob in @AppStorage so the
    // history persists across launches. JSON sidesteps separator-collision risks since
    // novel titles can contain almost any character.
    @AppStorage("discovery.recentSearches.v1") private var recentSearchesData = Data()
    private static let maxRecentSearches = 5

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 14 }
        return horizontalSizeClass == .compact ? 16 : 24
    }

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    searchBarWithRecents
                        .padding(.top, 10)
                        .padding(.bottom, 22)

                    libraryList
                }
                .padding(.bottom, 24)
            }
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .safeAreaPadding(.bottom, 12)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(
            isPresented: Binding(
                get: { activeSearchQuery != nil },
                set: { isActive in
                    if !isActive {
                        activeSearchQuery = nil
                    }
                }
            )
        ) {
            if let activeSearchQuery {
                DiscoverySearchResultsView(
                    query: activeSearchQuery,
                    sources: DiscoverySourceCatalog.searchableSources,
                    isLoading: searchIsLoading,
                    failedMessage: searchFailedMessage,
                    groupedResults: searchGroupedResults
                )
                .task(id: activeSearchQuery) {
                    await runSearchIfNeeded(query: activeSearchQuery)
                }
            }
        }
        // Browser pushed from a row tap on Discovery's *main* page (sourceRow).
        // Search-results-driven browser pushes are owned by DiscoverySearchResultsView
        // itself so dismissing the browser pops back to the search results, not all
        // the way to Discovery's home.
        .navigationDestination(item: $browserDestination) { destination in
            InAppBrowserView(url: destination.url, title: destination.title)
        }
    }

    /// Search field row only — no background. The fill is applied by `searchBarWithRecents`
    /// so the field and the recent-searches list share one continuous rounded container.
    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.headline)
                .foregroundStyle(theme.secondaryText)

            TextField("搜索小说名或关键词", text: $searchText)
                .focused($isSearchFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
                .onSubmit(triggerSearch)

            Button {
                triggerSearch()
            } label: {
                Text("搜索")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Search field + recent-searches list inside a single rounded `cardBackground`
    /// rectangle, separated by a hairline divider. This is the standard iOS pattern
    /// (Spotlight, Apple Books search) where the suggestions read as a continuation of
    /// the field rather than a separate floating card. Default insertion/removal lets
    /// SwiftUI animate the container height when focus changes.
    @ViewBuilder
    private var searchBarWithRecents: some View {
        let filtered = filteredRecentSearches
        let dropdownVisible = isSearchFieldFocused && !filtered.isEmpty

        VStack(spacing: 0) {
            searchBar

            if dropdownVisible {
                Divider()
                    .overlay(theme.secondaryText.opacity(0.25))

                ForEach(filtered, id: \.self) { query in
                    recentSearchRow(query)
                    if query != filtered.last {
                        Divider()
                            .overlay(theme.secondaryText.opacity(0.20))
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.18), value: dropdownVisible)
    }

    private var libraryList: some View {
        let sources = DiscoverySourceCatalog.searchableSources
            .sorted { discoveryPinyinSortKey($0.name) < discoveryPinyinSortKey($1.name) }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("书库")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)

                Text("\(sources.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
            }

            Text("以下来源会参与上方的聚合搜索")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .padding(.bottom, 4)

            VStack(spacing: 0) {
                ForEach(sources) { source in
                    sourceRow(source)

                    if source.id != sources.last?.id {
                        Divider()
                            .overlay(theme.secondaryText.opacity(0.18))
                    }
                }
            }
        }
    }

    private func sourceRow(_ source: DiscoverySource) -> some View {
        Button {
            openSource(source)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(source.name)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(source.tagline)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? 150 : 172, alignment: .trailing)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func triggerSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recordRecentSearch(trimmed)
        isSearchFieldFocused = false
        if trimmed != searchResultsQuery {
            // New query — clear stale cache so the results screen shows a loading spinner
            // instead of the previous query's results while the new search runs.
            searchGroupedResults = []
            searchFailedMessage = nil
            searchIsLoading = true
            searchResultsQuery = nil
        }
        activeSearchQuery = trimmed
    }

    private var recentSearches: [String] {
        guard !recentSearchesData.isEmpty else { return [] }
        return (try? JSONDecoder().decode([String].self, from: recentSearchesData)) ?? []
    }

    /// Recent searches filtered by what the user has typed so far. Empty input shows the
    /// full history; once typing begins, only entries containing the substring (case- and
    /// diacritic-insensitive) survive — matching the iOS-keyboard-style suggestion drop-down.
    private var filteredRecentSearches: [String] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = recentSearches
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private func saveRecentSearches(_ searches: [String]) {
        recentSearchesData = (try? JSONEncoder().encode(searches)) ?? Data()
    }

    private func recordRecentSearch(_ query: String) {
        var current = recentSearches
        current.removeAll { $0 == query }
        current.insert(query, at: 0)
        if current.count > Self.maxRecentSearches {
            current = Array(current.prefix(Self.maxRecentSearches))
        }
        saveRecentSearches(current)
    }

    private func removeRecentSearch(_ query: String) {
        var current = recentSearches
        current.removeAll { $0 == query }
        saveRecentSearches(current)
    }

    private func selectRecentSearch(_ query: String) {
        searchText = query
        triggerSearch()
    }

    private func recentSearchRow(_ query: String) -> some View {
        HStack(spacing: 12) {
            Button {
                selectRecentSearch(query)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.secondaryText)
                    Text(query)
                        .font(.system(size: 17))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                removeRecentSearch(query)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 14)
    }

    private func openSource(_ source: DiscoverySource) {
        if let homepageURL = source.homepageURL {
            browserDestination = DiscoveryBrowserDestination(url: homepageURL, title: source.name)
            return
        }

        browserDestination = DiscoveryBrowserDestination(url: source.fallbackSourceURL, title: source.name)
    }

    /// Runs a search only when the active query differs from the cached one. Re-entering the
    /// results screen with the same query is a no-op, so popping back from an in-app browser
    /// shows the previous results instantly. Otherwise consumes the streaming search so the
    /// UI shows hits as soon as the first source returns instead of waiting for every source.
    @MainActor
    private func runSearchIfNeeded(query: String) async {
        if searchResultsQuery == query, !searchGroupedResults.isEmpty || searchFailedMessage != nil {
            return
        }
        searchResultsQuery = query
        searchIsLoading = true
        searchFailedMessage = nil
        searchGroupedResults = []

        let stream = DiscoverySearchService.shared.searchStream(
            query: query,
            sources: DiscoverySourceCatalog.searchableSources
        )

        for await partialResults in stream {
            guard !Task.isCancelled, searchResultsQuery == query else { return }
            searchGroupedResults = partialResults
            // Drop the spinner the moment any source returns hits; subsequent sources just
            // stream in additional rows.
            if !partialResults.isEmpty {
                searchIsLoading = false
            }
        }

        guard !Task.isCancelled, searchResultsQuery == query else { return }
        searchIsLoading = false
    }
}

/// Stable pinyin-based sort key for Discovery source names. Names mix Chinese and
/// ASCII (e.g. "ESJ轻小说", "52书库"), so a raw `<` would sort by Unicode codepoint
/// and group all CJK names together. CFStringTransform converts Hanzi to romanized
/// pinyin while leaving ASCII alone; stripping diacritics drops tone marks so "ān"
/// and "an" sort the same; lowercasing makes the comparison case-insensitive.
private func discoveryPinyinSortKey(_ text: String) -> String {
    let mutable = NSMutableString(string: text)
    CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
    CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
    return (mutable as String).lowercased()
}

private struct DiscoveryBrowserDestination: Identifiable, Hashable {
    let id: String
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.id = "\(title)|\(url.absoluteString)"
        self.url = url
        self.title = title
    }
}

private struct DiscoverySearchResultsView: View {
    @Environment(\.appTheme) private var theme
    let query: String
    let sources: [DiscoverySource]
    let isLoading: Bool
    let failedMessage: String?
    let groupedResults: [DiscoveryGroupedResult]

    // Owned here (not on DiscoveryView) so the browser sits in the stack as a child of
    // search results — closing the browser pops back here instead of back to Discovery.
    @State private var browserDestination: DiscoveryBrowserDestination?

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            if isLoading {
                loadingView
            } else if let failedMessage {
                errorView(message: failedMessage)
            } else if groupedResults.isEmpty {
                emptyView
            } else {
                resultsList
            }
        }
        .navigationTitle("搜索结果")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $browserDestination) { destination in
            InAppBrowserView(url: destination.url, title: destination.title)
        }
    }

    private func openSource(url: URL, title: String) {
        browserDestination = DiscoveryBrowserDestination(url: url, title: title)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(theme.accent)
            Text("正在搜索 \(sources.count) 个来源…")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(theme.secondaryText)

            Text("搜索失败")
                .font(.headline)
                .foregroundStyle(theme.primaryText)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var emptyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("没有找到匹配内容")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)

                Text("你也可以直接按来源搜索：")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(sources) { source in
                        Button {
                            if let url = source.searchURL(for: query) {
                                openSource(url: url, title: source.name)
                            }
                        } label: {
                            Text(source.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .padding(.horizontal, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(theme.cardBackground)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
    }

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("“\(query)” 相关结果")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 4)

                ForEach(groupedResults) { result in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(result.title)
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                                .lineSpacing(3)

                            if !result.author.isEmpty {
                                Text(result.author)
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }

                        if !result.summary.isEmpty {
                            Text(result.summary)
                                .font(.system(size: 14))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(3)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(result.sourceLinks) { sourceLink in
                                    Button {
                                        openSource(url: sourceLink.url, title: sourceLink.source.name)
                                    } label: {
                                        Text(sourceLink.source.name)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(theme.primaryText)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 7)
                                            .background(
                                                Capsule()
                                                    .fill(theme.cardBackground)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(theme.subtleCardBackground)
                    )
                    .shadow(color: theme.cardShadow, radius: 6, x: 0, y: 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
    }

}

private struct DiscoverySource: Identifiable, Hashable {
    let id: String
    let name: String
    let tagline: String
    let homepageURL: URL?
    let searchRoute: DiscoverySourceSearchRoute?

    init(name: String, tagline: String, homepageURLString: String? = nil, searchRoute: DiscoverySourceSearchRoute? = nil) {
        self.id = name
        self.name = name
        self.tagline = tagline
        self.searchRoute = searchRoute
        if let homepageURLString {
            self.homepageURL = URL(string: homepageURLString)
        } else {
            self.homepageURL = nil
        }
    }

    var queryName: String {
        let strippedNumber = name.replacingOccurrences(of: #"\d+$"#, with: "", options: .regularExpression)
        return strippedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var fallbackSourceURL: URL {
        if let directSearchURL = searchRoute?.resolvedURL(for: queryName) {
            return directSearchURL
        }
        if let routeEndpoint = searchRoute?.endpointURL {
            return routeEndpoint
        }
        if let homepageURL {
            return homepageURL
        }
        return URL(string: "https://www.52shuku.net/")!
    }

    func makeSearchRequest(for query: String) -> URLRequest? {
        searchRoute?.buildRequest(query: query)
    }

    func searchURL(for query: String) -> URL? {
        if let route = searchRoute {
            return route.resolvedURL(for: query) ?? route.endpointURL
        }
        return homepageURL
    }
}

private enum DiscoveryHTTPMethod: String, Hashable {
    case get
    case post
}

private enum DiscoveryQueryEncoding: Hashable {
    case utf8
    case gb18030

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8:
            return .utf8
        case .gb18030:
            return .gb_18030_2000
        }
    }

    var charsetLabel: String {
        switch self {
        case .utf8:
            return "utf-8"
        case .gb18030:
            return "gb18030"
        }
    }
}

private struct DiscoveryRouteParam: Hashable {
    let key: String
    let value: String
}

private struct DiscoverySourceSearchRoute: Hashable {
    let sourceID: String
    let endpoint: String
    let method: DiscoveryHTTPMethod
    let queryKey: String
    let fixedParams: [DiscoveryRouteParam]
    let queryEncoding: DiscoveryQueryEncoding

    init(
        sourceID: String,
        endpoint: String,
        method: DiscoveryHTTPMethod,
        queryKey: String = "",
        fixedParams: [DiscoveryRouteParam] = [],
        queryEncoding: DiscoveryQueryEncoding = .utf8
    ) {
        self.sourceID = sourceID
        self.endpoint = endpoint
        self.method = method
        self.queryKey = queryKey
        self.fixedParams = fixedParams
        self.queryEncoding = queryEncoding
    }

    var endpointURL: URL? {
        URL(string: endpoint)
    }

    func resolvedURL(for query: String) -> URL? {
        if endpoint.contains("{query}") {
            let encodedQuery = query.percentEncodedPathSegment()
            return URL(string: endpoint.replacingOccurrences(of: "{query}", with: encodedQuery))
        }

        guard method == .get, var components = URLComponents(string: endpoint) else { return nil }
        var items = fixedParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: queryKey, value: query))
        components.queryItems = items
        return components.url
    }

    func buildRequest(query: String) -> URLRequest? {
        switch method {
        case .get:
            guard let url = resolvedURL(for: query) else { return nil }
            var request = URLRequest(url: url)
            applyBrowserHeaders(to: &request)
            return request
        case .post:
            guard let url = URL(string: endpoint) else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=\(queryEncoding.charsetLabel)", forHTTPHeaderField: "Content-Type")
            applyBrowserHeaders(to: &request)
            var params = fixedParams
            params.append(DiscoveryRouteParam(key: queryKey, value: query))
            let body = params
                .map {
                    "\($0.key.formURLEncoded(using: queryEncoding.stringEncoding))=\($0.value.formURLEncoded(using: queryEncoding.stringEncoding))"
                }
                .joined(separator: "&")
            request.httpBody = body.data(using: .utf8)
            return request
        }
    }

    private func applyBrowserHeaders(to request: inout URLRequest) {
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh-Hans;q=0.9,zh;q=0.8,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        if let endpointURL, let scheme = endpointURL.scheme, let host = endpointURL.host {
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
    }
}

private enum DiscoverySourceCatalog {
    static let searchRoutes: Set<DiscoverySourceSearchRoute> = [
        DiscoverySourceSearchRoute(
            sourceID: "ESJ轻小说",
            endpoint: "https://www.esjzone.cc/tags/{query}/",
            method: .get
        ),
        DiscoverySourceSearchRoute(
            sourceID: "52书库",
            endpoint: "https://www.52shuku.net/so/search.php",
            method: .get,
            queryKey: "q",
            fixedParams: []
        ),
        DiscoverySourceSearchRoute(
            sourceID: "52书库2",
            endpoint: "https://www.52shuku.net/so/search.php",
            method: .get,
            queryKey: "q",
            fixedParams: []
        ),
        DiscoverySourceSearchRoute(
            sourceID: "思兔閱讀",
            endpoint: "https://sto9.com/search",
            method: .post,
            queryKey: "searchkey",
            fixedParams: [DiscoveryRouteParam(key: "searchtype", value: "all")]
        ),
        DiscoverySourceSearchRoute(
            sourceID: "就爱读小说",
            endpoint: "https://www.5dxs.net/search/{query}.html",
            method: .get
        ),
        DiscoverySourceSearchRoute(
            sourceID: "同人圈",
            endpoint: "https://tongrenquan.org/e/search/indexstart.php",
            method: .post,
            queryKey: "keyboard",
            fixedParams: [
                DiscoveryRouteParam(key: "show", value: "title"),
                DiscoveryRouteParam(key: "classid", value: "0")
            ],
            queryEncoding: .gb18030
        ),
        DiscoverySourceSearchRoute(
            sourceID: "同人小说网",
            endpoint: "https://trxs.org/e/search/index.php",
            method: .post,
            queryKey: "keyboard",
            fixedParams: [
                DiscoveryRouteParam(key: "show", value: "title"),
                DiscoveryRouteParam(key: "classid", value: "0")
            ],
            queryEncoding: .gb18030
        ),
        DiscoverySourceSearchRoute(
            sourceID: "台灣小說網",
            endpoint: "https://www.xsw.tw/modules/article/search.php",
            method: .get,
            queryKey: "searchkey",
            fixedParams: [DiscoveryRouteParam(key: "searchtype", value: "articlename")]
        ),
        DiscoverySourceSearchRoute(
            sourceID: "半夏小说",
            endpoint: "https://www.xbanxia.cc/modules/article/search_t.php",
            method: .post,
            queryKey: "searchkey",
            fixedParams: [DiscoveryRouteParam(key: "Submit", value: "")]
        ),
        DiscoverySourceSearchRoute(
            sourceID: "笔趣阁小说",
            endpoint: "https://m.bqgl.cc/user/search.html",
            method: .get,
            queryKey: "q"
        ),
        DiscoverySourceSearchRoute(
            sourceID: "宙斯小说",
            endpoint: "https://www.zhswx.com/list/{query}.html",
            method: .get
        ),
        DiscoverySourceSearchRoute(
            sourceID: "黄金屋中文",
            endpoint: "https://tw.hjwzw.com/List/{query}",
            method: .get
        ),
        DiscoverySourceSearchRoute(
            sourceID: "努努书坊",
            endpoint: "https://www.nunucom.com/search/",
            method: .post,
            queryKey: "searchkey"
        ),
        DiscoverySourceSearchRoute(
            sourceID: "破万卷小说",
            endpoint: "https://www.powanjuan.cc/e/search/index.php",
            method: .post,
            queryKey: "keyboard",
            fixedParams: [
                DiscoveryRouteParam(key: "show", value: "title"),
                DiscoveryRouteParam(key: "classid", value: "0")
            ],
            queryEncoding: .gb18030
        ),
        DiscoverySourceSearchRoute(
            sourceID: "大尾笔趣阁",
            endpoint: "https://www.daweixs.com/modules/article/search.php",
            method: .post,
            queryKey: "searchkey",
            queryEncoding: .gb18030
        ),
        DiscoverySourceSearchRoute(
            sourceID: "无忧书城",
            endpoint: "https://www.51shucheng.net/search",
            method: .get,
            queryKey: "q"
        )
    ]

    private static let routeBySourceID: [String: DiscoverySourceSearchRoute] = {
        Dictionary(uniqueKeysWithValues: searchRoutes.map { ($0.sourceID, $0) })
    }()

    static func route(for sourceID: String) -> DiscoverySourceSearchRoute? {
        routeBySourceID[sourceID]
    }

    static var searchableSources: [DiscoverySource] {
        sources.filter { $0.searchRoute != nil }
    }

    static let sources: [DiscoverySource] = [
        DiscoverySource(name: "破万卷小说", tagline: "各類小說作品齊全", homepageURLString: "https://www.powanjuan.cc/", searchRoute: route(for: "破万卷小说")),
        DiscoverySource(name: "大尾笔趣阁", tagline: "笔趣阁热门书库", homepageURLString: "https://www.daweixs.com/", searchRoute: route(for: "大尾笔趣阁")),
        DiscoverySource(name: "ESJ轻小说", tagline: "日韩轻小说在线阅读", homepageURLString: "https://www.esjzone.cc/", searchRoute: route(for: "ESJ轻小说")),
        DiscoverySource(name: "思兔閱讀", tagline: "繁體熱門在線書庫", homepageURLString: "https://sto9.com/", searchRoute: route(for: "思兔閱讀")),
        DiscoverySource(name: "就爱读小说", tagline: "各类网络文学作品齐全", homepageURLString: "https://www.5dxs.net/", searchRoute: route(for: "就爱读小说")),
        DiscoverySource(name: "同人圈", tagline: "各類同人小說齊全", homepageURLString: "https://tongrenquan.org/", searchRoute: route(for: "同人圈")),
        DiscoverySource(name: "笔趣阁小说", tagline: "知名人气站点繁體版", homepageURLString: "https://m.bqgl.cc/", searchRoute: route(for: "笔趣阁小说")),
        DiscoverySource(name: "52书库", tagline: "快穿甜宠文小说书库", searchRoute: route(for: "52书库")),
        DiscoverySource(name: "努努书坊", tagline: "国内外各类作品，速度快", homepageURLString: "https://www.nunucom.com/", searchRoute: route(for: "努努书坊")),
        DiscoverySource(name: "宙斯小说", tagline: "各类热门小说，速度快", homepageURLString: "https://www.zhswx.com/", searchRoute: route(for: "宙斯小说")),
        DiscoverySource(name: "同人小说网", tagline: "各类热门同人小说齐全", homepageURLString: "https://trxs.org/", searchRoute: route(for: "同人小说网")),
        DiscoverySource(name: "台灣小說網", tagline: "熱門小說台灣站", homepageURLString: "https://www.xsw.tw/", searchRoute: route(for: "台灣小說網")),
        DiscoverySource(name: "黄金屋中文", tagline: "繁體電子書城，書多質量好", homepageURLString: "https://tw.hjwzw.com/", searchRoute: route(for: "黄金屋中文")),
        DiscoverySource(name: "半夏小说", tagline: "優質在線小說閱讀", homepageURLString: "https://www.xbanxia.cc/", searchRoute: route(for: "半夏小说")),
        DiscoverySource(name: "52书库2", tagline: "热门网络小说齐全速度快", searchRoute: route(for: "52书库2")),
        DiscoverySource(name: "无忧书城", tagline: "古典名著與經典在線閱讀", homepageURLString: "https://www.51shucheng.net/", searchRoute: route(for: "无忧书城"))
    ]
}

private struct DiscoveryRawSearchHit: Hashable {
    let source: DiscoverySource
    let title: String
    let novelTitle: String
    let author: String
    let summary: String
    let url: URL
    let rank: Int
}

private struct DiscoveryGroupedResult: Identifiable {
    let id: String
    let title: String
    let author: String
    let summary: String
    let sourceLinks: [DiscoverySourceLink]
    let relevance: Double
}

private struct DiscoverySourceLink: Identifiable {
    let id: String
    let source: DiscoverySource
    let url: URL

    init(source: DiscoverySource, url: URL) {
        self.id = source.id + "|" + url.absoluteString
        self.source = source
        self.url = url
    }
}

/// Lightweight (sourceName, URL) pair surfaced by `DiscoverySearchService.sourceCandidatesStream`
/// so callers outside DiscoveryView (e.g., the reader's source switcher) don't need to depend on
/// the file-private DiscoverySource / DiscoveryGroupedResult types.
struct BookSourceCandidate: Identifiable, Hashable, Sendable {
    let sourceName: String
    let url: URL
    var id: String { "\(sourceName)|\(url.absoluteString)" }
}

actor DiscoverySearchService {
    static let shared = DiscoverySearchService()

    private let session: URLSession
    private let redirectDelegate = DiscoveryRedirectDelegate()
    // In-memory paywall cache keyed by probe chapter URL. Process-lifetime only — copyright
    // takedowns shift slowly, so a cold restart will simply re-probe and converge again.
    private var paywallProbeCache: [String: Bool] = [:]

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        // 6s per request: most sources respond in well under 2s; anything past 6s is almost
        // certainly down or rate-limited and shouldn't keep the spinner alive for the whole
        // batch. Resource timeout stays a bit higher for slow CDNs.
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7"
        ]
        self.session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    /// Streams partial result sets as each source finishes. Wall-clock time is bound by the
    /// slowest single source (not the sum of sequential batches), and the UI sees the first
    /// hits within a few hundred ms instead of waiting for every source.
    fileprivate nonisolated func searchStream(
        query: String,
        sources: [DiscoverySource]
    ) -> AsyncStream<[DiscoveryGroupedResult]> {
        AsyncStream { continuation in
            let task = Task { [self] in
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    continuation.finish()
                    return
                }
                let searchableSources = sources.filter { $0.searchRoute != nil }
                guard !searchableSources.isEmpty else {
                    continuation.finish()
                    return
                }

                var allHits: [DiscoveryRawSearchHit] = []
                await withTaskGroup(of: [DiscoveryRawSearchHit].self) { group in
                    for source in searchableSources {
                        group.addTask { [self] in
                            await self.searchSingleSource(source, query: trimmed)
                        }
                    }

                    for await sourceHits in group {
                        if Task.isCancelled { break }
                        allHits.append(contentsOf: sourceHits)
                        let grouped = await self.groupAndSort(allHits, query: trimmed)
                        continuation.yield(grouped)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    fileprivate func search(query: String, sources: [DiscoverySource]) async throws -> [DiscoveryGroupedResult] {
        var latest: [DiscoveryGroupedResult] = []
        for await results in searchStream(query: query, sources: sources) {
            latest = results
        }
        return latest
    }

    /// Streams the per-source links for a single book, identified by its `novelTitle`. Each
    /// emission is the live set of (sourceName, URL) pairs whose normalized title key matches
    /// the requested book — i.e. exactly the one row the user would tap in
    /// DiscoverySearchResultsView. Used by the reader's source-switcher button.
    nonisolated func sourceCandidatesStream(for novelTitle: String) -> AsyncStream<[BookSourceCandidate]> {
        AsyncStream { continuation in
            let trimmed = novelTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedTitle = DiscoveryTextCleaner.cleanTitle(trimmed)
            let targetKey = DiscoveryTextCleaner.normalizedTitleKey(cleanedTitle)

            guard !targetKey.isEmpty else {
                continuation.finish()
                return
            }

            let task = Task { [self] in
                for await grouped in self.searchStream(
                    query: trimmed,
                    sources: DiscoverySourceCatalog.searchableSources
                ) {
                    if Task.isCancelled { break }
                    let candidates: [BookSourceCandidate]
                    if let match = grouped.first(where: { $0.id == targetKey }) {
                        candidates = match.sourceLinks.map {
                            BookSourceCandidate(sourceName: $0.source.name, url: $0.url)
                        }
                    } else {
                        candidates = []
                    }
                    continuation.yield(candidates)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func searchSingleSource(_ source: DiscoverySource, query: String) async -> [DiscoveryRawSearchHit] {
        guard let request = source.makeSearchRequest(for: query) else {
#if DEBUG
            print("[DiscoverySearch] skipped (no direct route): \(source.name)")
#endif
            return []
        }

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .gb_18030_2000) else {
#if DEBUG
                print("[DiscoverySearch] decode failed: \(source.name) | status=\(statusCode) bytes=\(data.count)")
#endif
                return []
            }
            guard !DiscoveryTextCleaner.isChallengePage(html) else {
#if DEBUG
                print("[DiscoverySearch] challenge page: \(source.name) | status=\(statusCode) bytes=\(data.count)")
#endif
                return []
            }
            let parsedResults = Array(parseDirectResults(source: source, html: html).prefix(20))
            let probedResults = await filterPaywalledHits(parsedResults)
            let hits = probedResults.enumerated().compactMap { index, result in
                makeDirectSourceHit(
                    source: source,
                    title: result.title,
                    author: result.author,
                    summary: result.summary,
                    url: result.url,
                    rank: index,
                    query: query
                )
            }
#if DEBUG
            if parsedResults.isEmpty {
                let sample = html
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .prefix(180)
                print("[DiscoverySearch] parsed 0: \(source.name) | status=\(statusCode) bytes=\(data.count) sample=\(sample)")
            } else {
                print("[DiscoverySearch] \(source.name): parsed \(parsedResults.count), direct \(hits.count)")
            }
#endif
            return hits
        } catch {
#if DEBUG
            print("[DiscoverySearch] request failed: \(source.name) | \(error.localizedDescription)")
#endif
            return []
        }
    }

    /// Drops hits whose `probeChapterURL` returns a copyright-takedown body. Sources that
    /// don't populate `probeChapterURL` (everything except 努努书坊 today) pass through
    /// unchanged, so this is effectively a no-op for them. Probes run concurrently so the
    /// added latency is bounded by the slowest single chapter fetch, not their sum.
    private func filterPaywalledHits(_ results: [ParsedSourceResult]) async -> [ParsedSourceResult] {
        let probeIndices = results.indices.filter { results[$0].probeChapterURL != nil }
        guard !probeIndices.isEmpty else { return results }

        var dropped: Set<Int> = []
        await withTaskGroup(of: (Int, Bool).self) { group in
            for i in probeIndices {
                let url = results[i].probeChapterURL!
                group.addTask { [self] in
                    let blocked = await self.isProbeURLPaywalled(url)
                    return (i, blocked)
                }
            }
            for await (i, blocked) in group {
                if blocked { dropped.insert(i) }
            }
        }
        return results.enumerated().compactMap { dropped.contains($0.offset) ? nil : $0.element }
    }

    private func isProbeURLPaywalled(_ url: URL) async -> Bool {
        let key = url.absoluteString
        if let cached = paywallProbeCache[key] { return cached }
        do {
            let (data, response) = try await session.data(from: url)
            // Treat non-2xx as "unknown" rather than paywalled — a 404 on a stub chapter
            // means the book is broken on this source, but that's a different failure mode.
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }
            let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .gb_18030_2000) ?? ""
            // xsw.tw responds with a tiny `info err.` body (≈9 bytes, HTTP 200) for book
            // IDs that no longer exist in the catalog. Treat that as a takedown so dead
            // search hits get filtered out the same way as 努努书坊 paywall stubs.
            let looksLikeXSWInfoErr = data.count < 32
                && html.lowercased().contains("info err")
            let blocked = html.contains("请下载努努书坊APP")
                || html.contains("請下載努努書坊APP")
                || html.contains("由于版权问题不能显示")
                || html.contains("由於版權問題不能顯示")
                || looksLikeXSWInfoErr
            paywallProbeCache[key] = blocked
            return blocked
        } catch {
            return false
        }
    }

    private func makeDirectSourceHit(
        source: DiscoverySource,
        title: String,
        author: String,
        summary: String,
        url: URL,
        rank: Int,
        query: String
    ) -> DiscoveryRawSearchHit? {
        let cleanedTitle = DiscoveryTextCleaner.cleanTitle(title)
        guard !cleanedTitle.isEmpty else { return nil }
        guard !DiscoveryTextCleaner.isSearchEngineSuggestionTitle(cleanedTitle) else { return nil }

        // Strip a `_authorName` suffix (or other plausibly-author tail) from the display
        // title so identical books from different sources collapse into one row at the
        // grouping step — see `groupAndSort`. Done before storing on the hit so both
        // grouping and rendering see the same cleaned title.
        let strippedTitle = DiscoveryTextCleaner.stripAuthorFromTitle(cleanedTitle, author: author)

        // Direct source parsers read the source's own result title field.
        // Keep it whole so bracketed tags like [诡秘之主同人] are not mistaken
        // for the entire novel title.
        return DiscoveryRawSearchHit(
            source: source,
            title: strippedTitle,
            novelTitle: strippedTitle,
            author: author,
            summary: summary,
            url: url,
            rank: rank
        )
    }

    private func makeSearchHit(
        source: DiscoverySource,
        title: String,
        summary: String,
        url: URL,
        rank: Int,
        query: String
    ) -> DiscoveryRawSearchHit? {
        let cleanedTitle = DiscoveryTextCleaner.cleanTitle(title)
        guard !cleanedTitle.isEmpty else { return nil }
        guard !DiscoveryTextCleaner.isSearchEngineSuggestionTitle(cleanedTitle) else { return nil }

        let novelTitle = DiscoveryTextCleaner.extractNovelTitle(
            fromTitle: title,
            summary: summary,
            query: query,
            sourceName: source.name
        )

        let cleanedNovelTitle = DiscoveryTextCleaner.cleanTitle(novelTitle)
        let keepByRelevance = DiscoveryTextCleaner.isRelevantNovelHit(
            title: title,
            novelTitle: novelTitle,
            summary: summary,
            query: query,
            sourceName: source.name,
            sourceHomepageURL: source.homepageURL,
            url: url
        )

        // Direct-source pages are already scoped to that source's own search result.
        // Keep a tolerant fallback path so valid novels are not over-filtered.
        let keepByDirectSignal = DiscoveryTextCleaner.hasDirectSourceSignal(
            title: cleanedTitle,
            novelTitle: cleanedNovelTitle,
            summary: summary,
            query: query
        )

        guard keepByRelevance || keepByDirectSignal else {
#if DEBUG
            print("[DiscoverySearch] rejected: \(source.name) | \(cleanedTitle)")
#endif
            return nil
        }

        return DiscoveryRawSearchHit(
            source: source,
            title: cleanedTitle,
            novelTitle: cleanedNovelTitle.isEmpty ? cleanedTitle : cleanedNovelTitle,
            author: "",
            summary: summary,
            url: url,
            rank: rank
        )
    }

    private struct ParsedSourceResult {
        let title: String
        let author: String
        let summary: String
        let url: URL
        // For sources with selective paywalling (currently 努努书坊): a chapter URL we can
        // fetch to detect copyright-takedown markers before showing the source to the user.
        // nil means "no probe needed" (the source either has no paywall, or we couldn't
        // extract a chapter URL — in which case we keep the hit rather than filter blindly).
        let probeChapterURL: URL?

        init(title: String, author: String = "", summary: String, url: URL, probeChapterURL: URL? = nil) {
            self.title = title
            self.author = author
            self.summary = summary
            self.url = url
            self.probeChapterURL = probeChapterURL
        }
    }

    private func parseDirectResults(source: DiscoverySource, html: String) -> [ParsedSourceResult] {
        switch source.id {
        case "ESJ轻小说":
            return parseESJResults(html: html)
        case "52书库", "52书库2":
            return parse52ShukuResults(html: html)
        case "思兔閱讀":
            return parseSto9Results(html: html)
        case "就爱读小说":
            return parseJieqiResults(html: html, baseURLString: "https://www.5dxs.net")
        case "同人圈":
            return parseEmpireCMSBookResults(html: html, baseURLString: "https://tongrenquan.org")
        case "同人小说网":
            return parseEmpireCMSBookResults(html: html, baseURLString: "https://trxs.org")
        case "台灣小說網":
            return parseXSWResults(html: html)
        case "半夏小说":
            return parseBanxiaResults(html: html)
        case "笔趣阁小说":
            return parseBQGLResults(payload: html)
        case "宙斯小说":
            return parseZhswxResults(html: html)
        case "黄金屋中文":
            return parseHJWZWResults(html: html)
        case "努努书坊":
            return parseNunuResults(html: html)
        case "破万卷小说":
            return parsePowanjuanResults(html: html)
        case "大尾笔趣阁":
            return parseDaweixsResults(html: html)
        default:
            return parseGenericLinkResults(html: html, source: source)
        }
    }

    /// daweixs.com search returns a `<ul class="txt-list txt-list-row5">` whose `<li>`s carry
    /// the columns `s1` (category) … `s5` (date). The first `<li>` is a header with `<b>`
    /// labels and no `<a>`, so we filter it by requiring a real link inside the `s2` cell.
    /// Without this, the generic `<a href>` parser swept up every nav/footer link on the page
    /// (首页 / 完本 / 排行 / 收藏 / 书架 / 都市言情 …) and listed them as bogus matches.
    private func parseDaweixsResults(html: String) -> [ParsedSourceResult] {
        let blocks = regexMatches(
            pattern: #"<li>\s*<span[^>]*class=["']s1["'][^>]*>[\s\S]*?</li>"#,
            in: html
        )
        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []
        let baseURL = URL(string: "https://www.daweixs.com")

        for block in blocks {
            guard
                let href = regexFirstMatch(
                    pattern: #"<span[^>]*class=["']s2["'][^>]*>\s*<a[^>]+href=["']([^"']+)["']"#,
                    in: block
                ),
                let url = URL(string: href, relativeTo: baseURL)
            else { continue }

            let rawTitle = regexFirstMatch(
                pattern: #"<span[^>]*class=["']s2["'][^>]*>\s*<a[^>]*>([\s\S]*?)</a>"#,
                in: block
            ) ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard !title.isEmpty else { continue }

            let author = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(
                    pattern: #"<span[^>]*class=["']s4["'][^>]*>([\s\S]*?)</span>"#,
                    in: block
                ) ?? ""
            )

            let key = "\(title)|\(url.absoluteString)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, author: author, summary: "", url: url.absoluteURL))
        }

        return results
    }

    private func parseESJResults(html: String) -> [ParsedSourceResult] {
        let blocks = regexMatches(
            pattern: #"<h5[^>]*class=["'][^"']*\bcard-title\b[^"']*["'][^>]*>[\s\S]*?</h5>"#,
            in: html
        )
        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []

        for block in blocks {
            guard
                let href = regexFirstMatch(pattern: #"<a[^>]+href=["']([^"']+)["']"#, in: block),
                let url = URL(string: href, relativeTo: URL(string: "https://www.esjzone.cc"))
            else { continue }

            let rawTitle = regexFirstMatch(pattern: #"<a[^>]*>([\s\S]*?)</a>"#, in: block) ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard !title.isEmpty else { continue }

            let key = "\(title)|\(url.absoluteString)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, summary: "", url: url.absoluteURL))
        }

        return results
    }

    private func parse52ShukuResults(html: String) -> [ParsedSourceResult] {
        let articleBlocks = regexMatches(
            pattern: #"<article[^>]*class=["'][^"']*\bexcerpt\b[^"']*["'][^>]*>[\s\S]*?</article>"#,
            in: html
        )
        let fallbackLinkBlocks = regexMatches(
            pattern: #"<a[^>]+href=["'][^"']+["'][^>]*>\s*<h4[^>]*>[\s\S]*?</h4>\s*</a>"#,
            in: html
        )
        let blocks = articleBlocks.isEmpty ? fallbackLinkBlocks : articleBlocks
        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []

        for block in blocks {
            append52ShukuResult(from: block, results: &results, seen: &seen)
        }

        return results
    }

    private func append52ShukuResult(
        from block: String,
        results: inout [ParsedSourceResult],
        seen: inout Set<String>
    ) {
        guard
            let href = regexFirstMatch(pattern: #"<a[^>]+href=["']([^"']+)["']"#, in: block),
            let url = URL(string: href, relativeTo: URL(string: "https://www.52shuku.net"))
        else { return }

        let rawTitle = regexFirstMatch(pattern: #"<h4[^>]*>([\s\S]*?)</h4>"#, in: block) ?? ""
        let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            .replacingOccurrences(of: #"^\s*\d+\.\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        let summary = DiscoveryTextCleaner.cleanSummary(
            regexFirstMatch(pattern: #"<span[^>]*class=["'][^"']*\bnote\b[^"']*["'][^>]*>([\s\S]*?)<p[^>]*class=["'][^"']*\bauth-span\b"#, in: block)
            ?? regexFirstMatch(pattern: #"<span[^>]*class=["'][^"']*\bnote\b[^"']*["'][^>]*>([\s\S]*?)</span>"#, in: block)
            ?? ""
        )

        let key = "\(title)|\(url.absoluteString)"
        guard !seen.contains(key) else { return }
        seen.insert(key)
        results.append(ParsedSourceResult(title: title, summary: summary, url: url.absoluteURL))
    }

    private func parseSto9Results(html: String) -> [ParsedSourceResult] {
        let listHTML = regexFirstMatch(pattern: #"<ul id=\"article_list_content\">([\s\S]*?)</ul>"#, in: html) ?? ""
        guard !listHTML.isEmpty else { return [] }

        let blocks = regexMatches(pattern: #"<li>[\s\S]*?</li>"#, in: listHTML)
        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []

        for block in blocks {
            guard
                let href = regexFirstMatch(pattern: #"<h3><a[^>]*href=\"([^\"]+)\""#, in: block)
                    ?? regexFirstMatch(pattern: #"href=\"([^\"]+/book/\d+\.html)\""#, in: block),
                let url = URL(string: href, relativeTo: URL(string: "https://sto9.com"))
            else { continue }

            let rawTitle = regexFirstMatch(pattern: #"<h3><a[^>]*>([\s\S]*?)</a></h3>"#, in: block) ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard !title.isEmpty else { continue }

            let summary = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"<ol class=\"ellipsis_2\">([\s\S]*?)</ol>"#, in: block) ?? ""
            )

            let key = "\(title)|\(url.absoluteString)"
            if seen.contains(key) { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, summary: summary, url: url))
        }

        return results
    }

    private func parseJieqiResults(html: String, baseURLString: String) -> [ParsedSourceResult] {
        let blocks = regexMatches(
            pattern: #"<div[^>]*class=["']c_row["'][^>]*>[\s\S]*?(?=<div[^>]*class=["']c_row["']|<div[^>]*class=["']pagelink["']|</div>\s*</div>\s*</div>)"#,
            in: html
        )
        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []

        for block in blocks {
            guard
                let href = regexFirstMatch(pattern: #"<span[^>]*class=["']c_subject["'][\s\S]*?<a[^>]+href=["']([^"']+)["']"#, in: block),
                let url = URL(string: href, relativeTo: URL(string: baseURLString))
            else { continue }

            let rawTitle = regexFirstMatch(pattern: #"<span[^>]*class=["']c_subject["'][\s\S]*?<a[^>]*>([\s\S]*?)</a>"#, in: block) ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard !title.isEmpty else { continue }

            let summary = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"<div[^>]*class=["']c_description["'][^>]*>([\s\S]*?)</div>"#, in: block) ?? ""
            )

            let key = "\(title)|\(url.absoluteString)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, summary: summary, url: url.absoluteURL))
        }

        return results
    }

    private func parseBanxiaResults(html: String) -> [ParsedSourceResult] {
        let blocks = regexMatches(
            pattern: #"<li[^>]*class=["']pop-book2["'][^>]*>[\s\S]*?</li>"#,
            in: html
        )
        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []

        for block in blocks {
            guard let href = regexFirstMatch(pattern: #"<a[^>]+href=["']([^"']+)["'][^>]*title=["'][^"']+["']"#, in: block)
                    ?? regexFirstMatch(pattern: #"<a[^>]+href=["']([^"']+)["'][\s\S]*?<h2[^>]*class=["']pop-tit["']"#, in: block)
            else { continue }

            let normalizedHref = href.replacingOccurrences(of: "http://www.xbanxia.cc", with: "https://www.xbanxia.cc")
            guard let url = URL(string: normalizedHref, relativeTo: URL(string: "https://www.xbanxia.cc")) else { continue }

            let rawTitle = regexFirstMatch(pattern: #"<h2[^>]*class=["']pop-tit["'][^>]*>([\s\S]*?)</h2>"#, in: block)
                ?? regexFirstMatch(pattern: #"title=["']([^"']+)["']"#, in: block)
                ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard !title.isEmpty else { continue }

            let author = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"<span[^>]*class=["']pop-intro["'][^>]*title=["']([^"']*)["']"#, in: block)
                ?? regexFirstMatch(pattern: #"<span[^>]*class=["']pop-intro["'][^>]*>([\s\S]*?)</span>"#, in: block)
                ?? ""
            )

            let key = "\(title)|\(url.absoluteString)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, author: author, summary: "", url: url.absoluteURL))
        }

        return results
    }

    private func parseBQGLResults(payload: String) -> [ParsedSourceResult] {
        guard
            let data = payload.data(using: .utf8),
            let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }

        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []
        let baseURL = URL(string: "https://m.bqgl.cc")

        for object in objects {
            let rawTitle = (object["articlename"] as? String) ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard !title.isEmpty else { continue }

            guard
                let href = object["url_list"] as? String,
                let url = URL(string: href, relativeTo: baseURL)
            else { continue }

            let author = DiscoveryTextCleaner.cleanSummary((object["author"] as? String) ?? "")
            let intro = DiscoveryTextCleaner.cleanSummary((object["intro"] as? String) ?? "")

            let key = "\(title)|\(url.absoluteString)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, author: author, summary: intro, url: url.absoluteURL))
        }

        return results
    }

    private func parseZhswxResults(html: String) -> [ParsedSourceResult] {
        let rows = regexMatches(
            pattern: #"<tr[^>]*class=["'](?:odd|even)["'][^>]*>[\s\S]*?</tr>"#,
            in: html
        )
        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []

        for row in rows {
            guard
                let titleCell = regexFirstMatch(pattern: #"<td[^>]*class=["']td2["'][^>]*>([\s\S]*?)</td>"#, in: row),
                let href = regexFirstMatch(pattern: #"<a[^>]+href=["']([^"']+)["']"#, in: titleCell),
                let url = URL(string: href, relativeTo: URL(string: "https://www.zhswx.com"))
            else { continue }

            let rawTitle = regexFirstMatch(pattern: #"<a[^>]*>([\s\S]*?)</a>"#, in: titleCell)
                ?? regexFirstMatch(pattern: #"title=["']([^"']+)["']"#, in: titleCell)
                ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard !title.isEmpty else { continue }

            let author = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"<td[^>]*class=["']td4["'][^>]*>([\s\S]*?)</td>"#, in: row) ?? ""
            )
            let latestChapter = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"<td[^>]*class=["']td3["'][^>]*>([\s\S]*?)</td>"#, in: row) ?? ""
            )

            let key = "\(title)|\(url.absoluteString)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, author: author, summary: latestChapter, url: url.absoluteURL))
        }

        return results
    }

    private func parseHJWZWResults(html: String) -> [ParsedSourceResult] {
        let blocks = regexMatches(
            pattern: #"<table[^>]*height=["']128px["'][^>]*>[\s\S]*?</table>\s*<hr\s*/?>"#,
            in: html
        )
        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []

        for block in blocks {
            guard
                let href = regexFirstMatch(pattern: #"<span[^>]*class=["']wd10["'][\s\S]*?<a[^>]+href=["']([^"']+)["']"#, in: block)
                    ?? regexFirstMatch(pattern: #"<a[^>]+href=["'](/Book/\d+)["']"#, in: block),
                let url = URL(string: href, relativeTo: URL(string: "https://tw.hjwzw.com"))
            else { continue }

            let rawTitle = regexFirstMatch(pattern: #"<span[^>]*class=["']wd10["'][\s\S]*?<a[^>]*>([\s\S]*?)</a>"#, in: block)
                ?? regexFirstMatch(pattern: #"<a[^>]+title=["']([^"']+)["']"#, in: block)
                ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard !title.isEmpty else { continue }

            let author = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"作者[：:]\s*<a[^>]*>([\s\S]*?)</a>"#, in: block) ?? ""
            )
            let intro = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"<span[^>]*class=["']wd9["'][^>]*>([\s\S]*?)</span>"#, in: block) ?? ""
            )

            let key = "\(title)|\(url.absoluteString)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, author: author, summary: intro, url: url.absoluteURL))
        }

        return results
    }

    private func parseEmpireCMSBookResults(html: String, baseURLString: String) -> [ParsedSourceResult] {
        let blocks = regexMatches(
            pattern: #"<div[^>]*class=["']bk["'][^>]*>[\s\S]*?(?=<div[^>]*class=["']bk["']|<div[^>]*class=["']page["']|</body>)"#,
            in: html
        )
        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []

        for block in blocks {
            guard
                let href = regexFirstMatch(pattern: #"<h3>\s*<a[^>]+href=["']([^"']+)["']"#, in: block),
                let url = URL(string: href, relativeTo: URL(string: baseURLString))
            else { continue }

            let rawTitle = regexFirstMatch(pattern: #"<h3>\s*<a[^>]*>([\s\S]*?)</a>\s*</h3>"#, in: block) ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard !title.isEmpty else { continue }

            let author = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"作者[：:]\s*([^<]+)"#, in: block) ?? ""
            )
            let intro = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"<p>\s*简介[：:]\s*([\s\S]*?)</p>"#, in: block) ?? ""
            )

            let key = "\(title)|\(url.absoluteString)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, author: author, summary: intro, url: url.absoluteURL))
        }

        return results
    }

    private func parseXSWResults(html: String) -> [ParsedSourceResult] {
        let blocks = regexMatches(
            pattern: #"<div[^>]*id=["']alistbox["'][^>]*>[\s\S]*?(?=<div[^>]*id=["']alistbox["']|<div[^>]*class=["']pagelink["']|</body>)"#,
            in: html
        )
        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []

        for block in blocks {
            // xsw.tw's search results page returns book hrefs in the legacy
            // `/book/<id>.html` shape, but that path now 404s on both www and m hosts.
            // The currently-served canonical path is `/<id>/` on m.xsw.tw — rewrite to
            // that before building the URL so tapping a result actually loads the book.
            guard
                let rawHref = regexFirstMatch(pattern: #"<div[^>]*class=["']title["'][\s\S]*?<a[^>]+href=["']([^"']+)["']"#, in: block)
            else { continue }

            let canonicalHref: String = {
                let pattern = #"^/book/(\d+)\.html$"#
                guard let range = rawHref.range(of: pattern, options: .regularExpression) else {
                    return rawHref
                }
                let captured = rawHref[range]
                    .dropFirst("/book/".count)
                    .dropLast(".html".count)
                return "/\(captured)/"
            }()

            guard let url = URL(string: canonicalHref, relativeTo: URL(string: "https://m.xsw.tw")) else {
                continue
            }

            let rawTitle = regexFirstMatch(pattern: #"<div[^>]*class=["']title["'][\s\S]*?<a[^>]*>([\s\S]*?)</a>"#, in: block)
                ?? regexFirstMatch(pattern: #"title=["']([^"']+)["']"#, in: block)
                ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard !title.isEmpty else { continue }

            let summary = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"<div[^>]*class=["']intro["'][^>]*>([\s\S]*?)</div>"#, in: block) ?? ""
            )

            let key = "\(title)|\(url.absoluteString)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            // xsw.tw's search index still references books that have been removed from the
            // catalog — those IDs return a 9-byte `info err.` stub at every path. Use the
            // book detail URL as its own probe so `filterPaywalledHits` drops dead entries
            // before they reach the user.
            results.append(
                ParsedSourceResult(
                    title: title,
                    summary: summary,
                    url: url.absoluteURL,
                    probeChapterURL: url.absoluteURL
                )
            )
        }

        return results
    }

    private func parseNunuResults(html: String) -> [ParsedSourceResult] {
        let blocks = regexMatches(pattern: #"<li>\s*<span[^>]*class=["']s1["'][\s\S]*?</li>"#, in: html)
        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []

        for block in blocks {
            guard
                let href = regexFirstMatch(pattern: #"<span[^>]*class=["']s2["'][\s\S]*?<a[^>]+href=["']([^"']+)["']"#, in: block),
                let url = URL(string: href, relativeTo: URL(string: "https://www.nunucom.com"))
            else { continue }

            let rawTitle = regexFirstMatch(pattern: #"<span[^>]*class=["']s2["'][\s\S]*?<a[^>]*>([\s\S]*?)</a>"#, in: block) ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard !title.isEmpty else { continue }

            let latestChapter = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"<span[^>]*class=["']s3["'][^>]*>([\s\S]*?)</span>"#, in: block) ?? ""
            )
            let author = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"<span[^>]*class=["']s4["'][^>]*>([\s\S]*?)</span>"#, in: block) ?? ""
            )

            // s3's anchor links to the latest chapter — use it as a paywall probe target
            // since the chapter body is where 努努书坊 emits "请下载努努书坊APP" / "由于版权问题"
            // for copyright-blocked books. Detail pages don't carry the marker.
            let probeChapterURL: URL? = regexFirstMatch(
                pattern: #"<span[^>]*class=["']s3["'][\s\S]*?<a[^>]+href=["']([^"']+)["']"#,
                in: block
            ).flatMap { URL(string: $0, relativeTo: URL(string: "https://www.nunucom.com"))?.absoluteURL }

            let key = "\(title)|\(url.absoluteString)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(
                title: title,
                author: author,
                summary: latestChapter,
                url: url.absoluteURL,
                probeChapterURL: probeChapterURL
            ))
        }

        return results
    }

    private func parseGenericLinkResults(html: String, source: DiscoverySource) -> [ParsedSourceResult] {
        let blocks = regexMatches(pattern: #"<a[^>]+href=\"([^\"]+)\"[^>]*>([\s\S]*?)</a>"#, in: html, captureGroup: 0)
        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []

        for block in blocks {
            guard
                let href = regexFirstMatch(pattern: #"href=\"([^\"]+)\""#, in: block),
                let baseURL = source.homepageURL,
                let url = URL(string: href, relativeTo: baseURL)
            else { continue }

            let rawTitle = regexFirstMatch(pattern: #">([\s\S]*?)</a>"#, in: block) ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard title.count >= 2 else { continue }

            let key = "\(title)|\(url.absoluteString)"
            if seen.contains(key) { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, summary: "", url: url))
            if results.count >= 20 { break }
        }

        return results
    }

    private func parsePowanjuanResults(html: String) -> [ParsedSourceResult] {
        let blocks = regexMatches(pattern: #"<li>\s*<div class=\"cover\">[\s\S]*?</li>"#, in: html)
        guard !blocks.isEmpty else { return [] }

        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []

        for block in blocks {
            guard
                let href = regexFirstMatch(pattern: #"<strong><a[^>]*href=\"([^\"]+)\""#, in: block),
                let url = URL(string: href, relativeTo: URL(string: "https://www.powanjuan.cc"))
            else { continue }

            let rawTitle = regexFirstMatch(pattern: #"<strong><a[^>]*>([\s\S]*?)</a></strong>"#, in: block) ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard !title.isEmpty else { continue }

            let summary = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"<div class=\"descript\">\s*<a[^>]*>([\s\S]*?)</a>\s*</div>"#, in: block) ?? ""
            )

            let key = "\(title)|\(url.absoluteString)"
            if seen.contains(key) { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, summary: summary, url: url))
        }

        return results
    }

    private func regexFirstMatch(pattern: String, in text: String, captureGroup: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let capture = Range(match.range(at: captureGroup), in: text) else {
            return nil
        }
        return String(text[capture])
    }

    private func regexMatches(pattern: String, in text: String, captureGroup: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let capture = Range(match.range(at: captureGroup), in: text) else { return nil }
            return String(text[capture])
        }
    }

    private func groupAndSort(_ hits: [DiscoveryRawSearchHit], query: String) -> [DiscoveryGroupedResult] {
        guard !hits.isEmpty else { return [] }

        struct GroupBucket {
            var canonicalTitle: String
            var author: String
            var snippets: [String]
            var linksBySourceID: [String: DiscoverySourceLink]
            var relevance: Double
        }

        var grouped: [String: GroupBucket] = [:]

        for hit in hits {
            let cleanedNovelTitle = DiscoveryTextCleaner.cleanTitle(hit.novelTitle)
            let cleanedDisplayTitle = cleanedNovelTitle.isEmpty
                ? DiscoveryTextCleaner.cleanTitle(hit.title)
                : cleanedNovelTitle
            guard !cleanedDisplayTitle.isEmpty else { continue }

            let key = DiscoveryTextCleaner.normalizedTitleKey(cleanedDisplayTitle)
            guard !key.isEmpty else { continue }

            let score = DiscoveryRelevance.score(
                title: cleanedDisplayTitle,
                summary: hit.summary,
                query: query,
                sourceName: hit.source.name,
                rank: hit.rank
            )

            var bucket = grouped[key] ?? GroupBucket(
                canonicalTitle: cleanedDisplayTitle,
                author: "",
                snippets: [],
                linksBySourceID: [:],
                relevance: 0
            )

            if bucket.canonicalTitle.count > cleanedDisplayTitle.count {
                bucket.canonicalTitle = cleanedDisplayTitle
            }

            if bucket.author.isEmpty, !hit.author.isEmpty {
                bucket.author = hit.author
            }

            if !hit.summary.isEmpty, bucket.snippets.count < 3 {
                let cleanedSummary = DiscoveryTextCleaner.cleanSummary(hit.summary)
                if !cleanedSummary.isEmpty, !bucket.snippets.contains(cleanedSummary) {
                    bucket.snippets.append(cleanedSummary)
                }
            }

            if bucket.linksBySourceID[hit.source.id] == nil {
                bucket.linksBySourceID[hit.source.id] = DiscoverySourceLink(source: hit.source, url: hit.url)
            }

            bucket.relevance = max(bucket.relevance, score)
            grouped[key] = bucket
        }

        let results = grouped.map { key, bucket in
            DiscoveryGroupedResult(
                id: key,
                title: bucket.canonicalTitle,
                author: bucket.author,
                summary: bucket.snippets.first ?? "",
                sourceLinks: bucket.linksBySourceID.values.sorted { $0.source.name < $1.source.name },
                relevance: bucket.relevance
            )
        }

        return results
            .filter { !$0.sourceLinks.isEmpty }
            .sorted { lhs, rhs in
                if lhs.relevance == rhs.relevance {
                    return lhs.title.count < rhs.title.count
                }
                return lhs.relevance > rhs.relevance
            }
    }
}

private final class DiscoveryRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if request.url?.scheme?.lowercased() == "http" {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private enum DiscoveryTextCleaner {
    static func cleanTitle(_ text: String) -> String {
        clean(text)
            .replacingOccurrences(of: #"^《|》$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 52shuku.net pages embed sogou-style suggestion blocks ("您是不是要找：…") whose
    // chips parse as fake hits. Drop them at the earliest point so they never reach
    // the grouped result list.
    static func isSearchEngineSuggestionTitle(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let markers = [
            "您是不是要找",
            "您是不是想找",
            "您可能想搜",
            "您可能想找",
            "相关搜索",
            "为您找到",
            "搜狗",
            "搜狗搜索"
        ]
        for marker in markers {
            if normalized.contains(marker) { return true }
        }
        if normalized.range(of: #"约\s*[\d,]+\s*条结果"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    static func cleanSummary(_ text: String) -> String {
        clean(text)
    }

    /// Strip a `_<author>` (or other plausibly-author) tail off a scraped book title so
    /// e.g. `凡人修仙传_忘语` and `凡人修仙传` from different sources collapse into one
    /// row at the grouping step. Two passes:
    ///   1. If the parser handed us a real `author` and the title ends with that exact
    ///      author after `_`, `|`, `｜`, `-`, ` `, or ` - `, strip it. Always safe.
    ///   2. Heuristic fallback: when the title contains an underscore separator and the
    ///      tail looks like a Chinese name (2–4 Hanzi, no spaces/punctuation), strip it.
    ///      Underscore-separated tails on novel titles are almost exclusively author
    ///      names in this corpus, so the false-positive risk is low.
    static func stripAuthorFromTitle(_ title: String, author: String) -> String {
        var working = title
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedAuthor.isEmpty {
            for separator in ["_", "|", "｜", " - ", "-", " "] {
                let suffix = "\(separator)\(trimmedAuthor)"
                if working.hasSuffix(suffix) {
                    working = String(working.dropLast(suffix.count))
                    break
                }
            }
        }

        // Underscore-suffix heuristic. Only run when no other separator is present so we
        // don't accidentally chew off a meaningful subtitle like `三国演义 - 罗贯中正版`.
        if let underscoreRange = working.range(of: "_", options: .backwards) {
            let tail = String(working[underscoreRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let looksLikeAuthor = tail.range(
                of: #"^[一-鿿]{2,4}$"#,
                options: .regularExpression
            ) != nil
            if looksLikeAuthor {
                working = String(working[..<underscoreRange.lowerBound])
            }
        }

        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractNovelTitle(fromTitle title: String, summary: String, query: String, sourceName: String) -> String {
        let titleText = clean(title)
        let summaryText = clean(summary)

        if let quoted = firstBookTitle(in: titleText) {
            return quoted
        }
        if let quoted = firstBookTitle(in: summaryText) {
            return quoted
        }

        let cleanedTitle = cleanTitle(titleText)
        let titleSegments = splitTitleSegments(cleanedTitle)
        let cleanedQuery = stripNovelDecorators(query, sourceName: sourceName)
        let normalizedQuery = normalizedComparableText(cleanedQuery)

        if !normalizedQuery.isEmpty {
            for segment in titleSegments {
                let normalizedSegment = normalizedComparableText(segment)
                if normalizedSegment.contains(normalizedQuery) {
                    let parsed = stripNovelDecorators(segment, sourceName: sourceName)
                    if isLikelyNovelTitle(parsed) {
                        return parsed
                    }
                }
            }
        }

        for segment in titleSegments {
            let parsed = stripNovelDecorators(segment, sourceName: sourceName)
            if isLikelyNovelTitle(parsed) {
                return parsed
            }
        }

        let fallback = stripNovelDecorators(cleanedTitle, sourceName: sourceName)
        if isLikelyNovelTitle(fallback) {
            return fallback
        }
        return cleanedTitle
    }

    static func isRelevantNovelHit(
        title: String,
        novelTitle: String,
        summary: String,
        query: String,
        sourceName: String,
        sourceHomepageURL: URL?,
        url: URL
    ) -> Bool {
        let cleanedTitle = cleanTitle(title)
        let cleanedNovelTitle = cleanTitle(novelTitle)
        let cleanedSummary = cleanSummary(summary)
        let normalizedQuery = normalizedComparableText(query)
        let normalizedTitle = normalizedComparableText(cleanedTitle)
        let normalizedNovelTitle = normalizedComparableText(cleanedNovelTitle)
        let normalizedSummary = normalizedComparableText(cleanedSummary)

        guard !normalizedQuery.isEmpty else { return false }

        let hasExactQueryEvidence = normalizedTitle.contains(normalizedQuery)
            || normalizedNovelTitle.contains(normalizedQuery)
            || normalizedSummary.contains(normalizedQuery)

        let queryTokens = queryFragments(from: query)
        let tokenMatches = queryTokens.filter { token in
            normalizedTitle.contains(token)
                || normalizedNovelTitle.contains(token)
                || normalizedSummary.contains(token)
        }.count
        let hasTokenEvidence = !queryTokens.isEmpty && tokenMatches >= 1

        guard hasExactQueryEvidence || hasTokenEvidence else { return false }
        guard isLikelyNovelTitle(cleanedNovelTitle) else { return false }

        let normalizedHost = (url.host ?? "").lowercased()
        let blockedHosts = [
            "translate.google.com",
            "support.microsoft.com",
            "spotify.com",
            "www.spotify.com"
        ]
        if blockedHosts.contains(where: { normalizedHost == $0 || normalizedHost.hasSuffix(".\($0)") }) {
            return false
        }

        return true
    }

    static func hasDirectSourceSignal(title: String, novelTitle: String, summary: String, query: String) -> Bool {
        let normalizedTitle = normalizedComparableText(title)
        let normalizedNovelTitle = normalizedComparableText(novelTitle)
        let normalizedSummary = normalizedComparableText(summary)
        let fragments = queryFragments(from: query)

        guard !fragments.isEmpty else { return false }
        return fragments.contains { fragment in
            normalizedTitle.contains(fragment)
                || normalizedNovelTitle.contains(fragment)
                || normalizedSummary.contains(fragment)
        }
    }

    static func isChallengePage(_ html: String) -> Bool {
        let lowered = html.lowercased()
        let hasSearchResultContent = lowered.contains("class=\"excerpt\"")
            || lowered.contains("class='excerpt'")
            || lowered.contains("id=\"article_list_content\"")
            || lowered.contains("id='article_list_content'")
            || lowered.contains("class=\"result")
            || lowered.contains("class='result")
            || lowered.contains("card-title")
            || lowered.contains("layout-tit")
            || lowered.contains("href=\"/books-")
            || lowered.contains("href='/books-")

        if hasSearchResultContent {
            return false
        }

        return lowered.contains("enable javascript and cookies to continue")
            || lowered.contains("just a moment...")
            || lowered.contains("checking if the site connection is secure")
            || lowered.contains("cf-browser-verification")
            || lowered.contains("antispider")
            || lowered.contains("/cdn-cgi/challenge-platform/")
    }

    static func normalizedTitleKey(_ title: String) -> String {
        var cleaned = title
        let removableParts = [
            "全文阅读", "免费阅读", "最新章节", "在线阅读", "无弹窗", "笔趣阁", "小说网", "小说"
        ]
        for part in removableParts {
            cleaned = cleaned.replacingOccurrences(of: part, with: "")
        }

        cleaned = cleaned
            .replacingOccurrences(of: #"[《》【】\[\]（）()<>]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[_|｜].*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.count > 28 {
            cleaned = String(cleaned.prefix(28))
        }

        return cleaned.lowercased()
    }

    private static func firstBookTitle(in text: String) -> String? {
        guard
            let regex = try? NSRegularExpression(pattern: #"[《〈「『]\s*([^》〉」』]{1,40})\s*[》〉」』]"#, options: []),
            let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)),
            let capture = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        let candidate = stripNovelDecorators(String(text[capture]), sourceName: "")
        return candidate.isEmpty ? nil : candidate
    }

    private static func splitTitleSegments(_ title: String) -> [String] {
        let separators = [" - ", " | ", " ｜ ", " _ ", "_", "：", ":", "—", "–", "|", "｜"]
        var parts: [String] = [title]

        for separator in separators {
            var next: [String] = []
            for part in parts {
                let segments = part
                    .components(separatedBy: separator)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if segments.isEmpty {
                    next.append(part)
                } else {
                    next.append(contentsOf: segments)
                }
            }
            parts = next
        }

        // Keep stable order while removing duplicates.
        var seen: Set<String> = []
        var unique: [String] = []
        for part in parts {
            if !seen.contains(part) {
                seen.insert(part)
                unique.append(part)
            }
        }
        return unique
    }

    private static func stripNovelDecorators(_ text: String, sourceName: String) -> String {
        var cleaned = cleanTitle(text)
        guard !cleaned.isEmpty else { return "" }

        if !sourceName.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: sourceName, with: "", options: [.literal, .caseInsensitive])
        }

        let removableFragments = [
            "最新章节目录更新", "最新章节目录", "最新章节", "章节目录", "章节更新",
            "全文阅读", "在线阅读", "免费阅读", "无弹窗", "txt下载",
            "小说介绍", "原著小说", "首发", "手机版", "手机端",
            "小说网", "小说"
        ]
        for fragment in removableFragments {
            cleaned = cleaned.replacingOccurrences(of: fragment, with: "")
        }

        cleaned = cleaned
            .replacingOccurrences(of: #"[《》【】\[\]（）()<>]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^[\s\p{P}·•\-—–:：|｜_]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s\p{P}·•\-—–:：|｜_]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }

    private static func normalizedComparableText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[^\p{L}\p{N}]"#, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLikelyNovelTitle(_ text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.count < 2 || candidate.count > 30 { return false }
        let normalized = normalizedComparableText(candidate)
        if normalized.isEmpty { return false }

        let disallowed = ["今日头条", "百度", "腾讯", "知乎", "微博", "下载", "阅读", "目录"]
        for marker in disallowed where candidate.contains(marker) && candidate.count <= marker.count + 2 {
            return false
        }
        return true
    }

    private static func meaningfulQueryTokens(_ query: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。;；|/·_-"))
        return query
            .components(separatedBy: separators)
            .map { normalizedComparableText($0) }
            .filter { $0.count >= 2 }
    }

    private static func queryFragments(from query: String) -> [String] {
        let normalized = normalizedComparableText(query)
        guard !normalized.isEmpty else { return [] }

        var fragments = Set(meaningfulQueryTokens(query))
        fragments.insert(normalized)

        // CJK queries often have no spaces; add contiguous 2~4 character windows
        // so "诡秘之主" can match titles containing "诡秘" or "之主".
        let chars = Array(normalized)
        if chars.count >= 2 {
            let minLen = 2
            let maxLen = min(4, chars.count)
            for length in minLen...maxLen {
                for start in 0...(chars.count - length) {
                    fragments.insert(String(chars[start..<(start + length)]))
                }
            }
        }

        return fragments
            .filter { $0.count >= 2 }
            .sorted { $0.count > $1.count }
    }

    private static func containsNovelContext(_ text: String) -> Bool {
        let markers = [
            "小说", "章节", "目录", "全文", "阅读", "作者", "连载", "完结",
            "番外", "书库", "书城", "文库", "txt", "起点", "晋江"
        ]
        return markers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func sourceMatches(sourceName: String, sourceHomepageURL: URL?, title: String, summary: String, url: URL) -> Bool {
        if let expectedHost = sourceHomepageURL?.host, hostMatches(url.host, expectedHost: expectedHost) {
            return true
        }

        let normalizedSource = normalizedComparableText(sourceName)
        guard !normalizedSource.isEmpty else { return false }

        let normalizedText = normalizedComparableText("\(title) \(summary)")
        if normalizedText.contains(normalizedSource) {
            return true
        }

        let host = normalizedComparableText(url.host ?? "")
        return host.contains(normalizedSource)
    }

    private static func hostMatches(_ actualHost: String?, expectedHost: String) -> Bool {
        guard let actualHost else { return false }
        let actual = normalizedHost(actualHost)
        let expected = normalizedHost(expectedHost)
        return actual == expected || actual.hasSuffix(".\(expected)") || expected.hasSuffix(".\(actual)")
    }

    private static func normalizedHost(_ host: String) -> String {
        let lowercased = host.lowercased()
        if lowercased.hasPrefix("www.") {
            return String(lowercased.dropFirst(4))
        }
        return lowercased
    }

    private static func clean(_ rawText: String) -> String {
        var text = rawText
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        text = decodeNumericHTMLEntities(in: text)

        let entities: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&#x27;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&mdash;": "-",
            "&ndash;": "-",
            "&hellip;": "..."
        ]

        for (entity, decoded) in entities {
            text = text.replacingOccurrences(of: entity, with: decoded)
        }

        text = simplifiedChinese(text)

        text = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    private static func simplifiedChinese(_ text: String) -> String {
        let transformIDs = ["Traditional-Simplified", "Any-Hans"]

        for transformID in transformIDs {
            let mutableText = NSMutableString(string: text)
            if CFStringTransform(mutableText, nil, transformID as CFString, false) {
                return mutableText as String
            }
        }

        return text
    }

    private static func decodeNumericHTMLEntities(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|\d+);"#, options: []) else {
            return text
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return text }

        var decoded = ""
        var cursor = text.startIndex

        for match in matches {
            guard
                let fullRange = Range(match.range(at: 0), in: text),
                let valueRange = Range(match.range(at: 1), in: text)
            else { continue }

            decoded.append(contentsOf: text[cursor..<fullRange.lowerBound])

            let token = String(text[valueRange])
            let value: UInt32?
            if token.lowercased().hasPrefix("x") {
                value = UInt32(String(token.dropFirst()), radix: 16)
            } else {
                value = UInt32(token, radix: 10)
            }

            if let value, let scalar = UnicodeScalar(value) {
                decoded.append(Character(scalar))
            } else {
                decoded.append(contentsOf: text[fullRange])
            }

            cursor = fullRange.upperBound
        }

        decoded.append(contentsOf: text[cursor..<text.endIndex])
        return decoded
    }
}

private enum DiscoveryRelevance {
    static func score(title: String, summary: String, query: String, sourceName: String, rank: Int) -> Double {
        let normalizedTitle = normalizedComparableText(title)
        let normalizedSummary = normalizedComparableText(summary)
        let normalizedQuery = normalizedComparableText(query)

        guard !normalizedQuery.isEmpty else { return 0 }

        if normalizedTitle == normalizedQuery {
            return 1_000
        }

        let titleMatch = matchPercentage(candidate: normalizedTitle, query: normalizedQuery)
        let summaryMatch = matchPercentage(candidate: normalizedSummary, query: normalizedQuery) * 0.35

        return max(titleMatch, summaryMatch) * 100
    }

    private static func matchPercentage(candidate: String, query: String) -> Double {
        guard !candidate.isEmpty, !query.isEmpty else { return 0 }
        if candidate.contains(query) {
            return 1
        }

        let matchedCount = longestCommonSubsequenceLength(Array(candidate), Array(query))
        return Double(matchedCount) / Double(query.count)
    }

    private static func longestCommonSubsequenceLength(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }

        var previous = Array(repeating: 0, count: rhs.count + 1)
        var current = previous

        for leftIndex in lhs.indices {
            for rightOffset in 0..<rhs.count {
                if lhs[leftIndex] == rhs[rightOffset] {
                    current[rightOffset + 1] = previous[rightOffset] + 1
                } else {
                    current[rightOffset + 1] = max(previous[rightOffset + 1], current[rightOffset])
                }
            }
            swap(&previous, &current)
            current = Array(repeating: 0, count: rhs.count + 1)
        }

        return previous[rhs.count]
    }

    private static func normalizedComparableText(_ text: String) -> String {
        DiscoveryTextCleaner.cleanTitle(text)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]"#, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func percentEncodedPathSegment() -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    func formURLEncoded(using encoding: String.Encoding = .utf8) -> String {
        guard let data = data(using: encoding) ?? data(using: .utf8) else {
            return self
        }

        var output = ""
        output.reserveCapacity(data.count * 3)

        for byte in data {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x2A:
                output.append(Character(UnicodeScalar(byte)))
            case 0x20:
                output.append("+")
            default:
                output.append(String(format: "%%%02X", byte))
            }
        }
        return output
    }
}

private extension String.Encoding {
    static let gb_18030_2000 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
}

private extension Array {
    func chunked(into chunkSize: Int) -> [[Element]] {
        guard chunkSize > 0 else { return [self] }
        var chunks: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: chunkSize, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index..<end]))
            index = end
        }
        return chunks
    }
}

#Preview {
    NavigationStack {
        DiscoveryView()
    }
}
