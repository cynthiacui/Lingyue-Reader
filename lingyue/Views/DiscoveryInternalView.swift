import SwiftUI
import Foundation

#if LINGYUE_INTERNAL
/// Internal-build Discovery: search bar, recent searches, and a 2-column
/// grid of seeded sources ("书库"). The App Store build uses
/// `DiscoveryAppStoreView` instead — it has no built-in source list and
/// drives the in-app browser off the user's own rules.
struct DiscoveryInternalView: View {
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

    @AppStorage(DiscoveryRecentSearches.storageKey) private var recentSearchesData = Data()

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 14 }
        return horizontalSizeClass == .compact ? 16 : 24
    }

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DiscoverySearchBar(
                        text: $searchText,
                        focus: $isSearchFieldFocused,
                        onSubmit: triggerSearch
                    )
                    .padding(.top, 10)

                    if !recentSearches.isEmpty {
                        DiscoveryRecentSearchesCard(onSelect: selectRecentSearch)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    libraryList
                        .padding(.top, 10)
                }
                .padding(.bottom, 24)
                .animation(.easeInOut(duration: 0.18), value: recentSearches)
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

    private var libraryList: some View {
        let sources = DiscoverySourceCatalog.searchableSources
            .sorted { discoveryPinyinSortKey($0.name) < discoveryPinyinSortKey($1.name) }

        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("书库")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Text("\(sources.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(sources) { source in
                    sourceCard(source)
                }
            }
        }
    }

    private func sourceCard(_ source: DiscoverySource) -> some View {
        let monogram = sourceMonogram(for: source.name)
        let tint = sourceTint(for: source.name)

        return Button {
            openSource(source)
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

                Text(source.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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

    /// Pulls a 1–2 character "monogram" off the front of a source name. ASCII/digit
    /// runs (e.g. "52书库", "ESJ轻小说") get up to 2 chars so the avatar carries enough
    /// signal; CJK names get the leading character only.
    private func sourceMonogram(for name: String) -> String {
        guard let first = name.first else { return "" }
        let isAsciiAlphanumeric: (Character) -> Bool = { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber)
        }
        if isAsciiAlphanumeric(first) {
            return String(name.prefix(while: isAsciiAlphanumeric).prefix(2))
        }
        return String(first)
    }

    /// Stable per-source accent — uses unicode-scalar sum so the same name always
    /// maps to the same swatch across launches (Swift's `hashValue` is randomized).
    private func sourceTint(for name: String) -> Color {
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

    private func triggerSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DiscoveryRecentSearches.record(trimmed)
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

    private func selectRecentSearch(_ query: String) {
        searchText = query
        triggerSearch()
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

#Preview {
    NavigationStack {
        DiscoveryInternalView()
    }
}
#endif
