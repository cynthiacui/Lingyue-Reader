import SwiftUI
import LingyueCore

/// Discovery page for the App Store build. Ships with no seeded sources,
/// so this view exposes only what the user has added:
///
/// 1. A top-right toolbar button that pushes `SourcesListView` for
///    add/edit/reorder. This entry used to live under Settings → 书源;
///    moving it to Discovery makes it reachable on the tab the user
///    lands on when looking for something to read.
/// 2. **我添加的书源** — a 2-column grid of the user's saved sources.
///    Tapping a card opens the source's homepage in `InAppBrowserView`,
///    where the existing rule-driven import flow handles auto-detection.
///
/// The view reads `SourceRule`s from `EditableSourceStore` directly
/// (rather than going through `BookSourceRegistry`) because we need
/// each rule's `homepage` URL — `BookSource` deliberately hides that
/// detail since runtime consumers don't need it.
struct DiscoveryAppStoreView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTheme) private var theme
    @Environment(\.sourceStack) private var sourceStack
    @EnvironmentObject private var importCoordinator: SourceImportCoordinator

    @State private var sources: [SavedSource] = []
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var browserDestination: BrowserDestination?

    // Search state. The App Store build has no seeded source catalog, so the search
    // bar drives `DiscoverySearchService` with an empty seed list — the service
    // auto-fans the user's own rules into every query.
    @State private var searchText = ""
    @State private var activeSearchQuery: String?
    @State private var searchResultsQuery: String?
    @State private var searchIsLoading = false
    @State private var searchFailedMessage: String?
    @State private var searchGroupedResults: [DiscoveryGroupedResult] = []
    @FocusState private var isSearchFieldFocused: Bool

    @AppStorage(DiscoveryRecentSearches.storageKey) private var recentSearchesData = Data()

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 14 }
        return horizontalSizeClass == .compact ? 16 : 24
    }

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DiscoverySearchBar(
                        text: $searchText,
                        focus: $isSearchFieldFocused,
                        onSubmit: triggerSearch
                    )

                    if !recentSearches.isEmpty {
                        DiscoveryRecentSearchesCard(onSelect: selectRecentSearch)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    websitesSection
                        // Extra breathing room above the websites section. The outer
                        // VStack uses `spacing: 18` to keep the search bar and history
                        // chips tight; this padding adds an additional visual gap
                        // before the "我添加的书源" header so the two zones read as
                        // separate sections rather than one continuous list.
                        .padding(.top, 16)
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
                .animation(.easeInOut(duration: 0.18), value: recentSearches)
            }
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .safeAreaPadding(.bottom, 12)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await refresh() }
        }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SourcesListView()
                } label: {
                    Image(systemName: "globe")
                        .accessibilityLabel("我的书源")
                }
            }
        }
        .task { await refresh() }
        .onAppear {
            // Refresh when popping back from SourcesListView so newly
            // added / deleted rules surface without a manual pull-to-refresh.
            if hasLoaded { Task { await refresh() } }
        }
        .navigationDestination(
            isPresented: Binding(
                get: { activeSearchQuery != nil },
                set: { isActive in
                    if !isActive { activeSearchQuery = nil }
                }
            )
        ) {
            if let activeSearchQuery {
                // No seeded sources in this build — pass [] so the empty-state
                // fallback grid doesn't appear. `DiscoverySearchService` still
                // fans the user's enabled rules into every query internally.
                DiscoverySearchResultsView(
                    query: activeSearchQuery,
                    sources: [],
                    isLoading: searchIsLoading,
                    failedMessage: searchFailedMessage,
                    groupedResults: searchGroupedResults
                )
                .task(id: activeSearchQuery) {
                    await runSearchIfNeeded(query: activeSearchQuery)
                }
            }
        }
        .navigationDestination(item: $browserDestination) { destination in
            InAppBrowserView(url: destination.url, title: destination.title)
        }
        // Auto-push the 书源 page after an external import (deep link / shared
        // file). ContentView switches to this tab; the coordinator flag drives
        // the push here. Popping back clears the flag via the binding setter.
        .navigationDestination(
            isPresented: Binding(
                get: { importCoordinator.shouldShowSources },
                set: { isActive in
                    if !isActive { importCoordinator.shouldShowSources = false }
                }
            )
        ) {
            SourcesListView()
        }
    }

    // MARK: - Search

    private var recentSearches: [String] {
        guard !recentSearchesData.isEmpty else { return [] }
        return (try? JSONDecoder().decode([String].self, from: recentSearchesData)) ?? []
    }

    private func triggerSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DiscoveryRecentSearches.record(trimmed)
        isSearchFieldFocused = false
        if trimmed != searchResultsQuery {
            searchGroupedResults = []
            searchFailedMessage = nil
            searchIsLoading = true
            searchResultsQuery = nil
        }
        activeSearchQuery = trimmed
    }

    private func selectRecentSearch(_ query: String) {
        searchText = query
        triggerSearch()
    }

    @MainActor
    private func runSearchIfNeeded(query: String) async {
        if searchResultsQuery == query, !searchGroupedResults.isEmpty || searchFailedMessage != nil {
            return
        }
        searchResultsQuery = query
        searchIsLoading = true
        searchFailedMessage = nil
        searchGroupedResults = []

        let stream = DiscoverySearchService.shared.searchStream(query: query, sources: [])

        for await partialResults in stream {
            guard !Task.isCancelled, searchResultsQuery == query else { return }
            searchGroupedResults = partialResults
        }

        guard !Task.isCancelled, searchResultsQuery == query else { return }
        searchIsLoading = false
    }

    // MARK: - Websites section (我添加的书源)

    private var websitesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("我添加的书源")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Text("点击你添加的书源网站，在内置浏览器中浏览。")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            websitesContent
        }
    }

    @ViewBuilder
    private var websitesContent: some View {
        Group {
            if let loadError {
                errorCard(loadError)
            } else if !hasLoaded {
                loadingCard
            } else if sources.isEmpty {
                emptyCard
            } else {
                sourceGrid
            }
        }
        // Crossfade loading → grid, and animate tiles in/out when the user
        // adds or removes a source and pops back here.
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: hasLoaded)
        .animation(.easeInOut(duration: 0.25), value: sources)
    }

    private var sourceGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(sources) { source in
                sourceCard(source)
                    .transition(.opacity)
            }
        }
    }

    private func sourceCard(_ source: SavedSource) -> some View {
        let monogram = Self.monogram(for: source.name)
        let tint = Self.tint(for: source.name)

        return Button {
            browserDestination = BrowserDestination(url: source.homepage, title: source.name)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16))
                        .frame(width: 32, height: 32)
                    Text(monogram)
                        .font(.system(size: monogram.count > 1 ? 12 : 15, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(source.hostLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: theme.cardShadow, radius: 6, x: 0, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("还没有添加书源", systemImage: "globe")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
            Text("点击右上角的书源按钮添加你想阅读的网页书源，添加后即可在此处直接打开。")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: theme.cardShadow, radius: 8, x: 0, y: 4)
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("加载中…")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: theme.cardShadow, radius: 8, x: 0, y: 4)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("无法加载书源", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
            Text(message)
                .font(.footnote.monospaced())
                .foregroundStyle(theme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: theme.cardShadow, radius: 8, x: 0, y: 4)
    }

    // MARK: - Data

    private func refresh() async {
        do {
            let rules = try await sourceStack.editableStore.loadEditableSources()
            // Honour user enable/disable preferences — a disabled rule shouldn't
            // clutter the browse grid since the user has explicitly hidden it
            // elsewhere (and our import flow won't fire for disabled rules).
            let preferences = (try? await sourceStack.preferenceStore.loadAll()) ?? [:]
            let enabledRules = rules.filter { preferences[$0.id]?.isEnabled ?? true }

            sources = enabledRules
                .map { SavedSource(rule: $0) }
                .sorted { Self.pinyinSortKey($0.name) < Self.pinyinSortKey($1.name) }
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
        hasLoaded = true
    }

    // MARK: - Helpers

    /// 1–2 character monogram for the source avatar. ASCII/digit-leading
    /// names get up to 2 chars; pure-CJK names get one.
    private static func monogram(for name: String) -> String {
        guard let first = name.first else { return "" }
        let isAsciiAlphanumeric: (Character) -> Bool = { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber)
        }
        if isAsciiAlphanumeric(first) {
            return String(name.prefix(while: isAsciiAlphanumeric).prefix(2))
        }
        return String(first)
    }

    /// Stable per-name accent so the same source always gets the same
    /// swatch across launches (Swift's `hashValue` is randomized).
    private static func tint(for name: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.78, green: 0.41, blue: 0.42),
            Color(red: 0.36, green: 0.55, blue: 0.78),
            Color(red: 0.30, green: 0.62, blue: 0.55),
            Color(red: 0.74, green: 0.54, blue: 0.30),
            Color(red: 0.55, green: 0.40, blue: 0.66),
            Color(red: 0.46, green: 0.56, blue: 0.40),
            Color(red: 0.72, green: 0.46, blue: 0.62),
            Color(red: 0.40, green: 0.50, blue: 0.62)
        ]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(sum) % palette.count]
    }

    /// Pinyin-based sort so CJK and ASCII names interleave alphabetically
    /// instead of clustering CJK at the end of the Unicode codepoint range.
    private static func pinyinSortKey(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased()
    }
}

private struct SavedSource: Identifiable, Hashable {
    let id: UUID
    let name: String
    let homepage: URL
    let hostLabel: String

    init(rule: SourceRule) {
        self.id = rule.id
        self.name = rule.name
        self.homepage = rule.homepage
        self.hostLabel = rule.homepage.host(percentEncoded: false) ?? rule.homepage.absoluteString
    }
}

private struct BrowserDestination: Identifiable, Hashable {
    let id: String
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.id = "\(title)|\(url.absoluteString)"
        self.url = url
        self.title = title
    }
}
