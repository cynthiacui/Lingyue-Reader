import SwiftUI

/// Browsing history surfaced from `readingStats.events`: one row per book, latest event
/// within the last 3 months. Tapping a row opens the reader if the book is still in the
/// library; deleted books are shown but disabled so the row still reads as a record.
struct ReadingHistoryView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.appTheme) private var theme
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false
    @State private var bookToOpen: Novel?

    private let calendar = Calendar.current

    private var cutoffDate: Date {
        calendar.date(byAdding: .month, value: -3, to: Date()) ?? Date()
    }

    private var recentEntries: [HistoryEntry] {
        let cutoff = cutoffDate
        let booksByID = Dictionary(uniqueKeysWithValues: libraryStore.readingStats.books.map { ($0.id, $0) })

        var latest: [UUID: ReadingStatsEvent] = [:]
        for event in libraryStore.readingStats.events where event.timestamp >= cutoff {
            if let existing = latest[event.bookID], existing.timestamp >= event.timestamp { continue }
            latest[event.bookID] = event
        }

        return latest.values
            .compactMap { event -> HistoryEntry? in
                guard let book = booksByID[event.bookID] else { return nil }
                return HistoryEntry(book: book, lastEvent: event)
            }
            .sorted { $0.lastEvent.timestamp > $1.lastEvent.timestamp }
    }

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            if recentEntries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(recentEntries) { entry in
                            historyRow(entry)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("浏览记录")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $bookToOpen) { novel in
            ReaderView(novel: novel)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.secondaryText)
            Text("最近三个月还没有阅读记录")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func historyRow(_ entry: HistoryEntry) -> some View {
        // Render unavailable rows as plain views (not a disabled Button) so SwiftUI's
        // disabled-state desaturation doesn't fade the title/cover — only the row's
        // background should read as muted.
        if let novel = libraryStore.allNovels.first(where: { $0.id == entry.book.id }) {
            Button {
                bookToOpen = novel
            } label: {
                rowContent(entry: entry, isAvailable: true)
            }
            .buttonStyle(.plain)
        } else {
            rowContent(entry: entry, isAvailable: false)
        }
    }

    private func rowContent(entry: HistoryEntry, isAvailable: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HistoryBookCover(book: entry.book, width: 44, height: 62)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayed(entry.book.title))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    if !isAvailable {
                        RemovedFromLibraryBadge()
                    }
                }

                if !entry.lastEvent.chapterTitle.isEmpty {
                    Text(displayed(entry.lastEvent.chapterTitle))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(relativeLabel(for: entry.lastEvent.timestamp))
                    Text("·")
                        .foregroundStyle(theme.secondaryText.opacity(0.55))
                    Text("进度 \(Int((entry.lastEvent.progress * 100).rounded()))%")
                }
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
            }

            Spacer(minLength: 0)

            if isAvailable {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryText.opacity(0.5))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                theme.cardBackground
                if !isAvailable {
                    theme.secondaryText.opacity(0.10)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }

    /// 今天 HH:mm / 昨天 HH:mm / N 天前 / M月d日 — keeps the row line compact and scannable.
    private func relativeLabel(for date: Date) -> String {
        if calendar.isDateInToday(date) {
            return "今天 " + Self.timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 " + Self.timeFormatter.string(from: date)
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        if days < 7 {
            return "\(days) 天前"
        }
        return Self.monthDayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()
}

private struct HistoryEntry: Identifiable {
    let book: ReadingStatsBook
    let lastEvent: ReadingStatsEvent
    var id: UUID { book.id }
}

private struct HistoryBookCover: View {
    let book: ReadingStatsBook
    let width: CGFloat
    let height: CGFloat
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            coverBackground

            Text(displayed(book.title))
                .font(.system(size: 9, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(5)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var coverBackground: some View {
        ZStack {
            fallback

            if let coverImageURLString = book.coverImageURLString,
               URL(string: coverImageURLString) != nil {
                StoredBookCoverImage(
                    bookID: book.id,
                    remoteURLString: coverImageURLString,
                    allowsRemoteFetch: !book.isDeleted
                )
            }
        }
    }

    private var fallback: some View {
        LinearGradient(
            colors: [book.coverPalette.color.opacity(0.96), book.coverPalette.color.opacity(0.68)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }
}
