import SwiftUI
import Foundation

struct DiscoveryView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL

    @State private var searchText = ""
    @State private var activeSearchQuery: String?
    @State private var openingSourceID: String?

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 14 }
        return horizontalSizeClass == .compact ? 16 : 24
    }

    var body: some View {
        ZStack {
            Color.readerBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    searchBar
                        .padding(.top, 10)
                        .padding(.bottom, 14)

                    sourceList
                }
                .padding(.bottom, 24)
            }
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .safeAreaPadding(.bottom, 12)
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
                    sources: DiscoverySourceCatalog.searchableSources
                )
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.headline)
                .foregroundStyle(Color.readerMuted)

            TextField("搜索小说名或关键词", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
                .onSubmit(triggerSearch)

            Button {
                triggerSearch()
            } label: {
                Text("搜索")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.readerAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.readerSurface)
        )
    }

    private var sourceList: some View {
        VStack(spacing: 0) {
            ForEach(DiscoverySourceCatalog.sources) { source in
                Button {
                    openSource(source)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text(source.name)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.readerInk)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if openingSourceID == source.id {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.readerMuted)
                        }

                        Text(source.tagline)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.readerMuted)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                            .frame(width: dynamicTypeSize.isAccessibilitySize ? 150 : 172, alignment: .trailing)
                    }
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)

                Divider()
                    .overlay(Color.readerMuted.opacity(0.18))
            }
        }
    }

    private func triggerSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeSearchQuery = trimmed
    }

    private func openSource(_ source: DiscoverySource) {
        if let homepageURL = source.homepageURL {
            openURL(homepageURL)
            return
        }

        openingSourceID = source.id
        let fallback = source.fallbackSourceURL
        openURL(fallback)
        openingSourceID = nil
    }
}

private struct DiscoverySearchResultsView: View {
    @Environment(\.openURL) private var openURL

    let query: String
    let sources: [DiscoverySource]

    @State private var isLoading = true
    @State private var groupedResults: [DiscoveryGroupedResult] = []
    @State private var failedMessage: String?

    var body: some View {
        ZStack {
            Color.readerBackground.ignoresSafeArea()

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
        .task(id: query) {
            await runSearch()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Color.readerAccent)
            Text("正在搜索 \(sources.count) 个来源…")
                .font(.subheadline)
                .foregroundStyle(Color.readerMuted)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.readerMuted)

            Text("搜索失败")
                .font(.headline)
                .foregroundStyle(Color.readerInk)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.readerMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var emptyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("没有找到匹配内容")
                    .font(.headline)
                    .foregroundStyle(Color.readerInk)

                Text("你也可以直接按来源搜索：")
                    .font(.subheadline)
                    .foregroundStyle(Color.readerMuted)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(sources) { source in
                        Button {
                            if let url = source.searchURL(for: query) {
                                openURL(url)
                            }
                        } label: {
                            Text(source.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.readerInk)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .padding(.horizontal, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.readerSurface)
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
                    .foregroundStyle(Color.readerMuted)
                    .padding(.horizontal, 4)

                ForEach(groupedResults) { result in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(result.title)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.readerInk)
                            .lineSpacing(3)

                        if !result.summary.isEmpty {
                            Text(result.summary)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.readerMuted)
                                .lineLimit(3)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(result.sourceLinks) { sourceLink in
                                    Link(destination: sourceLink.url) {
                                        Text(sourceLink.source.name)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.readerInk)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 7)
                                            .background(
                                                Capsule()
                                                    .fill(Color.readerSurface)
                                            )
                                    }
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.readerBackground.opacity(0.68))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.readerMuted.opacity(0.2), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
    }

    @MainActor
    private func runSearch() async {
        isLoading = true
        failedMessage = nil
        groupedResults = []

        do {
            let found = try await DiscoverySearchService.shared.search(query: query, sources: sources)
            groupedResults = found
            isLoading = false
        } catch {
            failedMessage = error.localizedDescription
            isLoading = false
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
            sourceID: "书林文学",
            endpoint: "https://www.baozhijixie.com/search",
            method: .post,
            queryKey: "searchkey"
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
        DiscoverySource(name: "书林文学", tagline: "最新完结小说，速度快", homepageURLString: "https://www.baozhijixie.com/", searchRoute: route(for: "书林文学")),
        DiscoverySource(name: "ESJ轻小说", tagline: "日韩轻小说在线阅读", homepageURLString: "https://www.esjzone.cc/", searchRoute: route(for: "ESJ轻小说")),
        DiscoverySource(name: "思兔閱讀", tagline: "繁體熱門在線書庫", homepageURLString: "https://sto9.com/", searchRoute: route(for: "思兔閱讀")),
        DiscoverySource(name: "就爱读小说", tagline: "各类网络文学作品齐全", homepageURLString: "https://www.5dxs.net/", searchRoute: route(for: "就爱读小说")),
        DiscoverySource(name: "国学导航", tagline: "各类冷门国学典籍"),
        DiscoverySource(name: "大美书网", tagline: "耽美书网替代网站"),
        DiscoverySource(name: "256文学", tagline: "热门网络小说齐全速度快"),
        DiscoverySource(name: "UU看书", tagline: "老牌热门网络小说书库", homepageURLString: "https://www.uuks.org/"),
        DiscoverySource(name: "玫瑰言情网", tagline: "专业的言情小说阅读平台"),
        DiscoverySource(name: "同人社", tagline: "各类热门同人小说齐全"),
        DiscoverySource(name: "全本同人网", tagline: "热门同人全本小说阅读"),

        DiscoverySource(name: "时空小说网", tagline: "热门网络小说齐全"),
        DiscoverySource(name: "梦想岛中文", tagline: "各类网络文学作品齐全"),
        DiscoverySource(name: "同人圈", tagline: "各類同人小說齊全", homepageURLString: "https://tongrenquan.org/", searchRoute: route(for: "同人圈")),
        DiscoverySource(name: "虚阁上", tagline: "古典文学经典名作"),
        DiscoverySource(name: "101小说", tagline: "繁體精品小說典藏網"),
        DiscoverySource(name: "微风小说1", tagline: "知名人气站点作品齐全"),
        DiscoverySource(name: "轻小说百科", tagline: "热门轻小说文库", homepageURLString: "https://lnovel.org/"),
        DiscoverySource(name: "天翼文学", tagline: "知名网络小说站点，书全速度快"),
        DiscoverySource(name: "梦远书城", tagline: "老牌书城，古典文学经典名作"),
        DiscoverySource(name: "笔趣阁小说", tagline: "知名人气站点繁體版"),
        DiscoverySource(name: "轻小说文库", tagline: "最新最全日系轻小说"),
        DiscoverySource(name: "饭饭小说", tagline: "热门网络小说齐全"),
        DiscoverySource(name: "飘天文学网", tagline: "人气站点(副)，书全质优", homepageURLString: "https://www.piaotian8.com/"),
        DiscoverySource(name: "天涯书库", tagline: "全球华人文学，经典书库"),
        DiscoverySource(name: "52书库", tagline: "快穿甜宠文小说书库", searchRoute: route(for: "52书库")),
        DiscoverySource(name: "古籍大全", tagline: "国学典籍，古今图书集成"),
        DiscoverySource(name: "铅笔小说", tagline: "各类图书小说，质好速度快"),
        DiscoverySource(name: "努努书坊", tagline: "国内外各类作品，速度快", homepageURLString: "https://www.nunucom.com/", searchRoute: route(for: "努努书坊")),

        DiscoverySource(name: "樱下书院", tagline: "热门网络小说电子书"),
        DiscoverySource(name: "零点看书", tagline: "各类热门网络小说质量好"),
        DiscoverySource(name: "宙斯小说", tagline: "各类热门小说，速度快"),
        DiscoverySource(name: "无忧书城", tagline: "古典现代外国等各类文学书籍"),
        DiscoverySource(name: "神凑轻小说", tagline: "最新最全日系轻小说"),
        DiscoverySource(name: "书海阁小说", tagline: "各类热门网络小说齐全"),
        DiscoverySource(name: "福书网", tagline: "完本耽美小说文库"),
        DiscoverySource(name: "小說王", tagline: "各類熱門小說齊全"),
        DiscoverySource(name: "笔趣阁移动", tagline: "老牌热门网站移动版，作品齐全"),
        DiscoverySource(name: "吾要讀", tagline: "热门网文，另类小说等齐全"),
        DiscoverySource(name: "腐小说", tagline: "完本耽美小说文库"),
        DiscoverySource(name: "同人小说网", tagline: "各类热门同人小说齐全", homepageURLString: "https://trxs.org/", searchRoute: route(for: "同人小说网")),
        DiscoverySource(name: "小说狂人", tagline: "各類熱門小說齊全"),
        DiscoverySource(name: "讀小說", tagline: "冷门小说等各类作品全"),
        DiscoverySource(name: "台灣小說網", tagline: "熱門小說台灣站", homepageURLString: "https://www.xsw.tw/", searchRoute: route(for: "台灣小說網")),
        DiscoverySource(name: "黄金屋中文", tagline: "繁體電子書城，書多質量好"),
        DiscoverySource(name: "青柠言情网", tagline: "最全的言情小说书库"),
        DiscoverySource(name: "69书吧", tagline: "知名人气站点，书全质优", homepageURLString: "https://www.69shuba.com/"),

        DiscoverySource(name: "笔趣阁", tagline: "知名人气站点，作品齐全更新快"),
        DiscoverySource(name: "全本小说", tagline: "老牌书城各类小说齐全"),
        DiscoverySource(name: "元小说", tagline: "热门网络小说，速度快"),
        DiscoverySource(name: "芒果书坊", tagline: "热门网络小说齐全速度快"),
        DiscoverySource(name: "书书屋小说", tagline: "精选网络文学书多质量好"),
        DiscoverySource(name: "镇魂小说", tagline: "优质纯爱言情小说"),
        DiscoverySource(name: "繁體小說網1", tagline: "台灣熱門小說網，書全質量好"),
        DiscoverySource(name: "2k小说网", tagline: "知名人气站点作品齐全"),
        DiscoverySource(name: "半夏小说", tagline: "優質在線小說閱讀"),
        DiscoverySource(name: "四库书屋", tagline: "热门网络小说齐全速度快"),
        DiscoverySource(name: "蜂鸟小说网", tagline: "言情小说，书全更新快"),
        DiscoverySource(name: "西方奇幻网", tagline: "优质西方奇幻小说"),
        DiscoverySource(name: "微风小说網", tagline: "热门网络书库，各类作品齐全"),
        DiscoverySource(name: "提莫書屋", tagline: "熱門繁體書庫，作品齊全"),
        DiscoverySource(name: "52书库2", tagline: "热门网络小说齐全速度快", searchRoute: route(for: "52书库2")),
        DiscoverySource(name: "老笔趣阁", tagline: "知名人气站点，作品齐全更新快"),
        DiscoverySource(name: "天天书吧", tagline: "各类网络小说齐全速度快"),
        DiscoverySource(name: "飘天文学", tagline: "人气站点(主)，书全质优")
    ]
}

private struct DiscoveryRawSearchHit: Hashable {
    let source: DiscoverySource
    let title: String
    let novelTitle: String
    let summary: String
    let url: URL
    let rank: Int
}

private struct DiscoveryGroupedResult: Identifiable {
    let id: String
    let title: String
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

private actor DiscoverySearchService {
    static let shared = DiscoverySearchService()

    private let session: URLSession
    private let redirectDelegate = DiscoveryRedirectDelegate()

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7"
        ]
        self.session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    func search(query: String, sources: [DiscoverySource]) async throws -> [DiscoveryGroupedResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let searchableSources = sources.filter { $0.searchRoute != nil }
        guard !searchableSources.isEmpty else { return [] }

        var allHits: [DiscoveryRawSearchHit] = []
        let batches = searchableSources.chunked(into: 6)

        for batch in batches {
            let batchHits = await searchBatch(batch, query: trimmed)
            allHits.append(contentsOf: batchHits)
        }

        return groupAndSort(allHits, query: trimmed)
    }

    private func searchBatch(_ batch: [DiscoverySource], query: String) async -> [DiscoveryRawSearchHit] {
        await withTaskGroup(of: [DiscoveryRawSearchHit].self) { group in
            for source in batch {
                group.addTask {
                    await self.searchSingleSource(source, query: query)
                }
            }

            var merged: [DiscoveryRawSearchHit] = []
            for await sourceHits in group {
                merged.append(contentsOf: sourceHits)
            }
            return merged
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
            let parsedResults = Array(parseDirectResults(source: source, html: html).prefix(10))
            let hits = parsedResults.enumerated().compactMap { index, result in
                makeDirectSourceHit(
                    source: source,
                    title: result.title,
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

    private func makeDirectSourceHit(
        source: DiscoverySource,
        title: String,
        summary: String,
        url: URL,
        rank: Int,
        query: String
    ) -> DiscoveryRawSearchHit? {
        let cleanedTitle = DiscoveryTextCleaner.cleanTitle(title)
        guard !cleanedTitle.isEmpty else { return nil }

        // Direct source parsers read the source's own result title field.
        // Keep it whole so bracketed tags like [诡秘之主同人] are not mistaken
        // for the entire novel title.
        return DiscoveryRawSearchHit(
            source: source,
            title: cleanedTitle,
            novelTitle: cleanedTitle,
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
            summary: summary,
            url: url,
            rank: rank
        )
    }

    private struct ParsedSourceResult {
        let title: String
        let summary: String
        let url: URL
    }

    private func parseDirectResults(source: DiscoverySource, html: String) -> [ParsedSourceResult] {
        switch source.id {
        case "ESJ轻小说":
            return parseESJResults(html: html)
        case "书林文学":
            return parseXbiqugeStyleResults(html: html, baseURLString: "https://www.baozhijixie.com")
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
        case "努努书坊":
            return parseNunuResults(html: html)
        case "破万卷小说":
            return parsePowanjuanResults(html: html)
        default:
            return parseGenericLinkResults(html: html, source: source)
        }
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

    private func parseXbiqugeStyleResults(html: String, baseURLString: String) -> [ParsedSourceResult] {
        let blocks = regexMatches(
            pattern: #"<div[^>]*class=["']item["'][^>]*>[\s\S]*?<div[^>]*class=["']clear["'][^>]*>\s*</div>\s*</div>"#,
            in: html
        )
        var results: [ParsedSourceResult] = []
        var seen: Set<String> = []

        for block in blocks {
            guard
                let href = regexFirstMatch(pattern: #"<dt>\s*<a[^>]+href=["']([^"']+)["']"#, in: block)
                    ?? regexFirstMatch(pattern: #"<a[^>]+href=["']([^"']+/kanshu/\d+/?)["']"#, in: block),
                let url = URL(string: href, relativeTo: URL(string: baseURLString))
            else { continue }

            let rawTitle = regexFirstMatch(pattern: #"<dt>\s*<a[^>]*>([\s\S]*?)</a>\s*</dt>"#, in: block)
                ?? regexFirstMatch(pattern: #"<a[^>]+title=["']([^"']+)["']"#, in: block)
                ?? ""
            let title = DiscoveryTextCleaner.cleanTitle(rawTitle)
            guard !title.isEmpty else { continue }

            let summary = DiscoveryTextCleaner.cleanSummary(
                regexFirstMatch(pattern: #"<dd>([\s\S]*?)</dd>"#, in: block) ?? ""
            )

            let key = "\(title)|\(url.absoluteString)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, summary: summary, url: url.absoluteURL))
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
            let summary = [author, intro]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")

            let key = "\(title)|\(url.absoluteString)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, summary: summary, url: url.absoluteURL))
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
            guard
                let href = regexFirstMatch(pattern: #"<div[^>]*class=["']title["'][\s\S]*?<a[^>]+href=["']([^"']+)["']"#, in: block),
                let url = URL(string: href, relativeTo: URL(string: "https://www.xsw.tw"))
            else { continue }

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
            results.append(ParsedSourceResult(title: title, summary: summary, url: url.absoluteURL))
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
            let summary = [author, latestChapter]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")

            let key = "\(title)|\(url.absoluteString)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(ParsedSourceResult(title: title, summary: summary, url: url.absoluteURL))
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
            if results.count >= 10 { break }
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
                snippets: [],
                linksBySourceID: [:],
                relevance: 0
            )

            if bucket.canonicalTitle.count > cleanedDisplayTitle.count {
                bucket.canonicalTitle = cleanedDisplayTitle
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

            bucket.relevance += score
            grouped[key] = bucket
        }

        let results = grouped.map { key, bucket in
            DiscoveryGroupedResult(
                id: key,
                title: bucket.canonicalTitle,
                summary: bucket.snippets.first ?? "",
                sourceLinks: bucket.linksBySourceID.values.sorted { $0.source.name < $1.source.name },
                relevance: bucket.relevance + Double(bucket.linksBySourceID.count) * 1.4
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

    static func cleanSummary(_ text: String) -> String {
        clean(text)
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

        text = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

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
        let titleLower = title.lowercased()
        let summaryLower = summary.lowercased()
        let queryLower = query.lowercased()
        let sourceLower = sourceName.lowercased()

        var score = 0.0

        if titleLower.contains(queryLower) {
            score += 12
        }

        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。;；|/"))
        let tokens = queryLower
            .components(separatedBy: separators)
            .filter { !$0.isEmpty && $0.count >= 2 }

        for token in tokens {
            if titleLower.contains(token) {
                score += 2.8
            } else if summaryLower.contains(token) {
                score += 1.4
            }
        }

        if titleLower.contains(sourceLower) || summaryLower.contains(sourceLower) {
            score += 2
        }

        score += max(0, 5 - Double(rank))

        return score
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
