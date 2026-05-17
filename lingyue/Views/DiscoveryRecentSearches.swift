import SwiftUI

/// Persistence facade for Discovery's recent-searches list. Stored as a
/// JSON-encoded `[String]` blob in `UserDefaults` (key
/// `discovery.recentSearches.v1`) so the history survives launches and
/// novel titles containing separators round-trip safely. Mutations are
/// static functions so both the internal and App Store Discovery views
/// can record a query without holding a shared instance — they're already
/// observing the same `@AppStorage` key, so writes propagate via SwiftUI's
/// UserDefaults observation.
enum DiscoveryRecentSearches {
    static let storageKey = "discovery.recentSearches.v1"
    /// Storage cap for the persisted history. The visible card clips to two FlowLayout
    /// rows regardless, so this just bounds how much history is available to fill those
    /// two rows when chips happen to be narrow (short titles).
    static let limit = 20

    static func load() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: storageKey), !data.isEmpty else {
            return []
        }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func save(_ entries: [String]) {
        let encoded = (try? JSONEncoder().encode(entries)) ?? Data()
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }

    static func record(_ query: String) {
        var current = load()
        current.removeAll { $0 == query }
        current.insert(query, at: 0)
        if current.count > limit {
            current = Array(current.prefix(limit))
        }
        save(current)
    }

    static func remove(_ query: String) {
        var current = load()
        current.removeAll { $0 == query }
        save(current)
    }

    static func clear() {
        save([])
    }
}

/// Transparent recent-searches card displayed beneath the Discovery search
/// bar. Chips wrap onto multiple rows via `FlowLayout` (clipped to two rows)
/// so titles of any length stay readable. The card has no fill — it sits
/// directly on the page background.
struct DiscoveryRecentSearchesCard: View {
    @Environment(\.appTheme) private var theme
    @AppStorage(DiscoveryRecentSearches.storageKey) private var data = Data()
    /// Invoked when a user taps a history chip. The parent typically writes
    /// the value back into the search text and re-triggers the search.
    var onSelect: (String) -> Void

    private var entries: [String] {
        guard !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("历史记录")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)

                Spacer()

                Button {
                    DiscoveryRecentSearches.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            FlowLayout(spacing: 10, rowSpacing: 10, maxRows: 2) {
                ForEach(entries, id: \.self) { query in
                    chip(query)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private func chip(_ query: String) -> some View {
        HStack(spacing: 6) {
            Button {
                onSelect(query)
            } label: {
                Text(query)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                DiscoveryRecentSearches.remove(query)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .overlay(
            Capsule()
                .stroke(theme.secondaryText.opacity(0.30), lineWidth: 1)
        )
    }
}

/// Wrapping layout for the recent-searches chips. `maxRows` clips overflow
/// (parking offscreen chips with a zero proposal) so the card never grows
/// taller than two rows regardless of history length.
fileprivate struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8
    var maxRows: Int? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let limit = maxRows ?? Int.max
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var currentRow = 1

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let widthIfAppended = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            if widthIfAppended > maxWidth, rowWidth > 0 {
                if currentRow >= limit { break }
                totalHeight += rowHeight + rowSpacing
                totalWidth = max(totalWidth, rowWidth)
                currentRow += 1
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = widthIfAppended
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        let limit = maxRows ?? Int.max
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        var currentRow = 1
        var stopped = false

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !stopped, x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                if currentRow >= limit {
                    stopped = true
                } else {
                    x = bounds.minX
                    y += rowHeight + rowSpacing
                    rowHeight = 0
                    currentRow += 1
                }
            }
            if stopped {
                subview.place(at: CGPoint(x: -10_000, y: -10_000), anchor: .topLeading, proposal: .zero)
            } else {
                subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
    }
}
