import SwiftUI

/// Settings → 阅读诊断. Shows the reader event log captured by
/// `ReaderDiagnostics` so we can reconstruct what was happening before a
/// crash — meant to be paired with Apple's Organizer stack trace.
///
/// Default tab is "上次会话" (the prior run, whose final entries are the
/// run-up to whatever crash or kill ended that session); the live session
/// is reachable for debugging-in-real-time.
struct ReaderDiagnosticsView: View {
    @StateObject private var diagnostics = ReaderDiagnostics.shared
    @Environment(\.appTheme) private var theme
    @State private var scope: Scope = .previous
    @State private var expandedID: UUID?
    @State private var showClearConfirmation = false

    enum Scope: String, CaseIterable, Identifiable {
        case previous, current
        var id: String { rawValue }
        var label: String { self == .previous ? "上次会话" : "本次会话" }
    }

    private var entries: [ReaderDiagnostics.Entry] {
        scope == .previous ? diagnostics.previous : diagnostics.current
    }

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            VStack(spacing: 0) {
                Picker("范围", selection: $scope) {
                    ForEach(Scope.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .tint(theme.accent)

                if entries.isEmpty {
                    emptyState
                } else {
                    summaryCard
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                    List {
                        ForEach(entries.reversed()) { entry in
                            entryRow(entry)
                                .listRowBackground(theme.cardBackground.opacity(0.5))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .navigationTitle("阅读诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(
                        item: diagnostics.exportText(),
                        preview: SharePreview("Lingyue 阅读诊断")
                    ) {
                        Label("导出为文本", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("清除日志", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(theme.accent)
            }
        }
        .confirmationDialog(
            "清除诊断日志？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) { diagnostics.clearAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会同时清除本次和上次会话的记录。")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(theme.secondaryText)
            Text(scope == .previous ? "没有上次会话的记录。" : "尚未记录本次会话事件。")
                .foregroundStyle(theme.secondaryText)
            Text("打开阅读器并翻几页后再回来查看。")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryCard: some View {
        let counts = countsByKind(entries)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                Text("\(entries.count) 条 · \(rangeDescription(entries))")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            FlowChips(items: counts) { kind, count in
                summaryChip(kind: kind, count: count)
            }
        }
        .padding(12)
        .background(theme.cardBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func summaryChip(kind: ReaderDiagnostics.Kind, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text("\(kind.rawValue) ×\(count)")
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.accent.opacity(0.15), in: Capsule())
        .foregroundStyle(theme.primaryText)
    }

    private func entryRow(_ entry: ReaderDiagnostics.Entry) -> some View {
        let isExpanded = expandedID == entry.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: entry.kind.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 16)
                Text(timeFormatter.string(from: entry.timestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                Text(entry.kind.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
            }
            Text(entry.message)
                .font(.footnote)
                .foregroundStyle(theme.primaryText)

            if !entry.context.isEmpty {
                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entry.context.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            HStack(alignment: .top, spacing: 6) {
                                Text(key)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(theme.secondaryText)
                                Text(value)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(theme.primaryText)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 2)
                } else {
                    Text(inlineContextPreview(entry.context))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedID = isExpanded ? nil : entry.id
            }
        }
    }

    // MARK: - Helpers

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func countsByKind(_ entries: [ReaderDiagnostics.Entry]) -> [(ReaderDiagnostics.Kind, Int)] {
        var bucket: [ReaderDiagnostics.Kind: Int] = [:]
        for entry in entries { bucket[entry.kind, default: 0] += 1 }
        return ReaderDiagnostics.Kind.allCases.compactMap { kind in
            bucket[kind].map { (kind, $0) }
        }
    }

    private func rangeDescription(_ entries: [ReaderDiagnostics.Entry]) -> String {
        guard let first = entries.first?.timestamp,
              let last = entries.last?.timestamp else { return "" }
        let span = last.timeIntervalSince(first)
        let mins = Int(span / 60)
        let secs = Int(span.truncatingRemainder(dividingBy: 60))
        return "跨度 \(mins)m \(secs)s"
    }

    private func inlineContextPreview(_ context: [String: String]) -> String {
        context.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }
}

/// Minimal wrap-on-overflow row used for the kind-counts chip strip.
/// SwiftUI's built-in `Grid` / `LazyHGrid` don't wrap based on intrinsic
/// child widths, so this lays the chips out manually.
private struct FlowChips<Content: View, Key: Hashable>: View {
    let items: [(Key, Int)]
    let content: (Key, Int) -> Content

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.0) { key, count in
                content(key, count)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rows[rows.count - 1] + size.width > maxWidth, rows[rows.count - 1] > 0 {
                totalHeight += rowHeight + spacing
                rows.append(0)
                rowHeight = 0
            }
            rows[rows.count - 1] += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rows.max() ?? 0, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        _ = maxWidth
    }
}
