import SwiftUI

struct DiscoveryView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 14 }
        return horizontalSizeClass == .compact ? 16 : 24
    }

    private var categoryMinimum: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 170 : (horizontalSizeClass == .compact ? 148 : 196)
    }

    private var featuredSectionHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 380 : 300
    }

    var body: some View {
        ZStack {
            Color.readerBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    featuredSection
                    categoriesSection
                    trendingSection
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .safeAreaPadding(.bottom, 12)
        }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.large)
    }

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "今日推荐")

            GeometryReader { proxy in
                let cardWidth: CGFloat = max(min(proxy.size.width * 0.9, 420), 250)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(MockData.featuredNovels) { novel in
                            FeaturedNovelCard(novel: novel, cardWidth: cardWidth)
                        }
                    }
                    .padding(.vertical, 2)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
            .frame(height: featuredSectionHeight)
        }
    }

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "分类浏览")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: categoryMinimum), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(MockData.categories) { category in
                    CategoryPill(category: category)
                }
            }
        }
    }

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "热门上升")

            VStack(spacing: 12) {
                ForEach(Array(MockData.trendingNovels.enumerated()), id: \.element.id) { index, novel in
                    TrendingRow(rank: index + 1, novel: novel)
                }
            }
        }
    }
}

private struct FeaturedNovelCard: View {
    let novel: Novel
    let cardWidth: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var summaryLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 4
    }

    private var coverWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 72 : 86
    }

    private var coverHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 104 : 124
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    BookCover(novel: novel, width: coverWidth, height: coverHeight)
                    cardDetails
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        BookCover(novel: novel, width: coverWidth, height: coverHeight)
                        cardDetails
                    }
                }
            }

            Button {
            } label: {
                Label("加入书架", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.readerAccent)
            .controlSize(.large)
        }
        .frame(width: cardWidth, alignment: .leading)
        .readerCard()
    }

    private var cardDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(novel.title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.readerInk)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Text("\(novel.author) · \(novel.genre)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.readerAccent)
                .lineLimit(2)

            Text(novel.summary)
                .font(.system(size: 17, design: .serif))
                .foregroundStyle(Color.readerMuted)
                .lineSpacing(6)
                .lineLimit(summaryLineLimit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CategoryPill: View {
    let category: NovelCategory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: category.symbol)
                .font(.headline)
                .foregroundStyle(Color.readerAccent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.headline)
                    .foregroundStyle(Color.readerInk)

                Text("\(category.count) 本")
                    .font(.caption)
                    .foregroundStyle(Color.readerMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerCard()
    }
}

private struct TrendingRow: View {
    let rank: Int
    let novel: Novel

    var body: some View {
        HStack(spacing: 14) {
            Text(String(rank))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(rank <= 3 ? Color.readerAccent : Color.readerMuted)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(novel.title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.readerInk)

                Text(novel.summary)
                    .font(.system(size: 16, design: .serif))
                    .foregroundStyle(Color.readerMuted)
                    .lineSpacing(5)
                    .lineLimit(2)
            }

            Spacer()
        }
        .readerCard()
    }
}

#Preview {
    DiscoveryView()
}
