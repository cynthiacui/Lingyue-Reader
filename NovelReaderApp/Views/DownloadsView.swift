import SwiftUI

/// Top-right Library toolbar control. Renders a static download icon when nothing is
/// happening and a circular progress ring (with a small badge count) while downloads
/// are in flight, so the user can glance up and see *something is happening here*
/// without opening the sheet.
struct LibraryDownloadToolbarButton: View {
    @Binding var isPresented: Bool
    let novels: [Novel]

    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var downloadManager: BookDownloadManager

    private var activeNovels: [Novel] {
        novels.filter { downloadManager.isActive($0) }
    }

    private var aggregateProgress: Double {
        let actives = activeNovels
        guard !actives.isEmpty else { return 0 }
        let sum = actives.reduce(0.0) { $0 + downloadManager.state(for: $1).fraction }
        return sum / Double(actives.count)
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            ZStack {
                if activeNovels.isEmpty {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.accent)
                } else {
                    ZStack {
                        Circle()
                            .stroke(theme.accent.opacity(0.22), lineWidth: 2.4)
                            .frame(width: 22, height: 22)

                        Circle()
                            .trim(from: 0, to: max(0.04, aggregateProgress))
                            .stroke(
                                theme.accent,
                                style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                            )
                            .frame(width: 22, height: 22)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.25), value: aggregateProgress)

                        Image(systemName: "arrow.down")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(theme.accent)
                    }

                    if activeNovels.count > 1 {
                        Text("\(activeNovels.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.accent))
                            .offset(x: 14, y: -10)
                    }
                }
            }
            .frame(minWidth: 32, minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("下载管理")
    }
}

/// Modal sheet that lists every book the download manager is currently tracking,
/// grouped by status. Lets the user cancel/clear/retry per-book.
struct DownloadsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var downloadManager: BookDownloadManager
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false

    private var trackedNovels: [(Novel, BookDownloadState)] {
        libraryStore.allNovels.compactMap { novel in
            let state = downloadManager.state(for: novel)
            if state == .idle { return nil }
            return (novel, state)
        }
    }

    private var activeBooks: [(Novel, BookDownloadState)] {
        trackedNovels.filter { $0.1.isActive || $0.1.isPaused }
    }

    private var failedBooks: [(Novel, BookDownloadState)] {
        trackedNovels.filter {
            if case .failed = $0.1 { return true }
            return false
        }
    }

    private var completedBooks: [(Novel, BookDownloadState)] {
        trackedNovels.filter { $0.1.isFinished }
    }

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if trackedNovels.isEmpty {
                        emptyState
                    } else {
                        if !activeBooks.isEmpty {
                            section(title: "下载中", books: activeBooks)
                        }
                        if !failedBooks.isEmpty {
                            section(title: "未完成", books: failedBooks)
                        }
                        if !completedBooks.isEmpty {
                            section(title: "已下载", books: completedBooks)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
                    .font(.body.weight(.semibold))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(theme.accent.opacity(0.6))

            Text("暂无下载")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)

            Text("长按书架中的书，选择「下载本书」即可离线阅读。")
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func section(title: String, books: [(Novel, BookDownloadState)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .textCase(.uppercase)
                .tracking(0.6)

            VStack(spacing: 8) {
                ForEach(books, id: \.0.id) { entry in
                    DownloadRow(
                        novel: entry.0,
                        state: entry.1,
                        usesTraditionalChinese: usesTraditionalChinese
                    )
                }
            }
        }
    }
}

private struct DownloadRow: View {
    let novel: Novel
    let state: BookDownloadState
    let usesTraditionalChinese: Bool

    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var downloadManager: BookDownloadManager

    var body: some View {
        HStack(spacing: 12) {
            BookCover(novel: novel, width: 44, height: 62)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayed(novel.title))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(theme.secondaryText.opacity(0.18))

                        Capsule()
                            .fill(progressColor)
                            .frame(width: max(2, proxy.size.width * state.fraction))
                            .animation(.easeInOut(duration: 0.18), value: state.fraction)
                    }
                }
                .frame(height: 4)
            }

            Spacer(minLength: 6)

            actionButton
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: theme.cardShadow, radius: 8, x: 0, y: 4)
    }

    private var statusText: String {
        switch state {
        case .idle:
            return "等待中"
        case .downloading(let completed, let total):
            return "下载中 \(completed)/\(total)"
        case .paused(let completed, let total):
            return "已暂停 \(completed)/\(total) · 点击继续"
        case .downloaded(let total):
            return "已下载 · \(total) 章"
        case .failed(_, let completed, let total):
            return "已下载 \(completed)/\(total) · 点击重试"
        }
    }

    private var statusColor: Color {
        switch state {
        case .failed: return Color.red.opacity(0.85)
        case .downloaded: return theme.accent
        case .paused: return theme.secondaryText
        default: return theme.secondaryText
        }
    }

    private var progressColor: Color {
        switch state {
        case .failed: return Color.red.opacity(0.75)
        case .paused: return theme.secondaryText.opacity(0.6)
        default: return theme.accent
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .downloading:
            Button {
                downloadManager.pauseDownload(for: novel)
            } label: {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("暂停下载")

        case .paused:
            Button {
                downloadManager.resumeDownload(for: novel)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("继续下载")

        case .failed:
            Button {
                downloadManager.startDownload(novel)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重试下载")

        case .downloaded:
            Button {
                downloadManager.clearState(for: novel)
                Task {
                    await ChapterContentCache.shared.clearCache(for: novel)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.system(size: 13, weight: .semibold))
                    Text("清理缓存")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .strokeBorder(theme.secondaryText.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清理缓存")

        case .idle:
            EmptyView()
        }
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }
}
