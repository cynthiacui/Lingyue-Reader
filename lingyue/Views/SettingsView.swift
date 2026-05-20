import SwiftUI

struct SettingsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var systemColorScheme
    @StateObject private var systemAppearance = SystemAppearance()
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var downloadManager: BookDownloadManager
    @EnvironmentObject private var libraryStore: LibraryStore

    @AppStorage("reader.fontSize") private var fontSize = 18.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.paragraphSpacing") private var paragraphSpacingMultiplier: Double = 0.5
    @AppStorage("reader.fontFamily") private var fontFamilyRaw = ReaderFontFamily.system.rawValue
    @AppStorage("reader.pageTransition") private var pageTransitionRaw = PageTransitionStyle.instant.rawValue
    @AppStorage("reader.twoColumn") private var twoColumnLayout = false
    @AppStorage("reader.theme") private var themeRawValue = ReadingTheme.paper.rawValue
    @AppStorage("reader.followSystemDark") private var readerFollowSystemDark = false
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false
    @AppStorage("reader.autoScroll") private var autoScroll = false
    @AppStorage("reader.autoScrollSeconds") private var autoScrollSeconds = 6.0
    @AppStorage("reader.cacheEnabled") private var cacheEnabled = true

    @State private var cacheSizeText = "计算中"
    @State private var cacheNotice: String?

    private let previewBaseText = """
    长安夜色如墨，雨声落在青石板上。沈砚合上残卷，忽然听见城楼方向传来三更鼓。
    他披衣起身，推开木窗，江风拂面，带着早春未散的寒意。
    """

    /// Theme actually used to render the preview — respects follow-system when on.
    private var selectedTheme: ReadingTheme {
        ReadingTheme.effective(
            rawValue: themeRawValue,
            followSystemDark: readerFollowSystemDark,
            deviceIsInDarkMode: systemAppearance.isDark
        )
    }

    /// Theme the user explicitly picked from the swatches. Used for swatch selection state so
    /// the user's pick stays highlighted even while follow-system has overridden the preview.
    private var manualReadingTheme: ReadingTheme {
        ReadingTheme(rawValue: themeRawValue) ?? .paper
    }

    private var displayedPreviewText: String {
        ChineseTextConverter.display(previewBaseText, usesTraditionalChinese: usesTraditionalChinese)
    }

    /// Split paragraphs the same way the reader does (collapse blank-line runs to single
    /// newlines, then break on each). Lets the VStack spacing below visually represent the
    /// `paragraphSpacing` multiplier the reader applies via NSParagraphStyle.
    private var previewParagraphs: [String] {
        displayedPreviewText
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private var selectedFontFamily: ReaderFontFamily {
        ReaderFontFamily(rawValue: fontFamilyRaw) ?? .system
    }

    /// Routes the picker through `selectedFontFamily` so a stale storage value (e.g. an old
    /// `"kaiti"` left over from before the case was removed) still resolves to a valid tag,
    /// otherwise the menu would render with no selection visible.
    private var fontFamilyBinding: Binding<String> {
        Binding(
            get: { selectedFontFamily.rawValue },
            set: { fontFamilyRaw = $0 }
        )
    }

    private var selectedPageTransition: PageTransitionStyle {
        PageTransitionStyle(rawValue: pageTransitionRaw) ?? .instant
    }

    private var pageTransitionBinding: Binding<String> {
        Binding(
            get: { selectedPageTransition.rawValue },
            set: { pageTransitionRaw = $0 }
        )
    }

    /// "1.4.2 (203)" style version label for the 关于 row. Reads
    /// CFBundleShortVersionString + CFBundleVersion straight from the
    /// active bundle so internal vs App Store builds each show their own.
    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            List {
                heroSection
                metricsSection
                appearanceSection
                dataSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)

            if let cacheNotice {
                CenterToast(text: cacheNotice)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: cacheNotice)
        .navigationTitle("我")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await refreshCacheSize()
        }
    }

    // MARK: - Sections

    /// 我 hero — bookmark-shaped reading-identity card. Extends the wallet-stacked
    /// metaphor from 书架 into 我 by carrying the user's reading streak, this-week
    /// minutes, and the cover/progress of the book they're currently in. The whole
    /// card is the tap target that pushes `ReadingStatsView`, so it doubles as the
    /// snapshot row that previously lived here.
    ///
    /// Rendered edge-to-edge with a transparent list row background so the card's
    /// own warm-paper gradient reads cleanly against the chrome theme.
    private var heroSection: some View {
        Section {
            NavigationLink {
                ReadingStatsView()
            } label: {
                ReadingIdentityCard(
                    streak: currentStreak,
                    weeklyMinutes: weeklyMinutes,
                    currentBook: mostRecentlyOpenedBook
                )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// Three-up mini metrics under the hero: 已读 / 正在读 / 已读字数. Reads from the
    /// same `readingStats.books` ledger the 统计 tab uses, so the numbers stay in
    /// sync without re-deriving from raw events.
    private var metricsSection: some View {
        Section {
            HStack(spacing: 10) {
                MetricChip(value: booksFinishedLabel, label: "已读")
                MetricChip(value: booksInProgressLabel, label: "正在读")
                MetricChip(value: totalCharactersLabel, label: "已读字数")
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - Hero data

    /// Most recently opened novel across all categories — drives the "current book"
    /// row inside the hero card. Returns `nil` for a freshly installed library so
    /// the hero can fall back to a "尚未开卷" empty state.
    private var mostRecentlyOpenedBook: Novel? {
        libraryStore.allNovels
            .filter { $0.lastOpenedAt != nil }
            .max(by: { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) })
    }

    /// Consecutive reading-streak length counted back from today. Mirrors the logic
    /// in `ReadingStatsView.currentStreak(days:)` so the badge inside the hero card
    /// matches the streak shown on the 统计 tab.
    private var currentStreak: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let activeDays = Set(libraryStore.readingStats.events.map { calendar.startOfDay(for: $0.timestamp) })
        var streak = 0
        var cursor = today
        while activeDays.contains(cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        // If today is empty but yesterday was active, fall through with the
        // running streak counted from yesterday so the badge doesn't blink to 0
        // first thing each morning.
        if streak == 0, let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            cursor = yesterday
            while activeDays.contains(cursor) {
                streak += 1
                guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = prev
            }
        }
        return streak
    }

    /// Reading minutes accumulated within the last 7 days (rolling, not calendar
    /// week) — keeps the hero responsive without making "本周" reset abruptly at
    /// midnight on Sunday.
    private var weeklyMinutes: Int {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let seconds = libraryStore.readingStats.events
            .filter { $0.timestamp >= cutoff }
            .reduce(0.0) { $0 + $1.durationSeconds }
        return max(Int(seconds / 60), 0)
    }

    private var booksFinishedLabel: String {
        let count = libraryStore.readingStats.books.filter { !$0.isDeleted && $0.currentProgress >= 0.99 }.count
        return "\(count)"
    }

    private var booksInProgressLabel: String {
        let count = libraryStore.readingStats.books.filter {
            !$0.isDeleted && $0.currentProgress > 0 && $0.currentProgress < 0.99
        }.count
        return "\(count)"
    }

    /// Total characters read across the entire ledger, condensed into `万/亿` units
    /// so the chip never overflows. Mirrors the format used elsewhere in 统计.
    private var totalCharactersLabel: String {
        let total = libraryStore.readingStats.events.reduce(0) { $0 + $1.characterCount }
        if total < 10_000 { return "\(total)" }
        if total < 100_000_000 {
            let wan = Double(total) / 10_000
            if wan < 10 { return String(format: "%.1f万", wan) }
            return "\(Int(wan.rounded()))万"
        }
        let yi = Double(total) / 100_000_000
        return String(format: "%.1f亿", yi)
    }

    private var appearanceSection: some View {
        Section {
            previewRow
            fontSizeRow
            lineSpacingRow
            paragraphSpacingRow
            fontFamilyPickerRow
            pageTransitionPickerRow
            twoColumnRow
            readingThemeRow
            appThemeRow
            traditionalRow
            autoScrollRow
            if autoScroll {
                autoScrollSecondsRow
            }
        } header: {
            Text("外观")
        }
        .listRowBackground(theme.cardBackground)
    }

    private var dataSection: some View {
        Section {
#if LINGYUE_INTERNAL
            // App Store builds reach 我的书源 from the Discovery tab; only
            // the Internal build keeps the 设置 entry, since its Discovery
            // page is busy with the seeded 书库 grid.
            sourcesNavRow
#endif
            backupNavRow
            cachePrefetchRow
            cacheSizeRow
            clearCacheRow
        } header: {
            Text("数据")
        }
        .listRowBackground(theme.cardBackground)
    }

    private var aboutSection: some View {
        Section {
#if LINGYUE_INTERNAL
            diagnosticsNavRow
#endif
            aboutVersionRow
        } header: {
            Text("关于")
        }
        .listRowBackground(theme.cardBackground)
    }

    // MARK: - Appearance rows

    /// Live theme/font preview, rendered through the same UITextView path the
    /// reader uses so on-device font metrics match what the user actually sees
    /// while reading. Stretches edge-to-edge with `.listRowInsets(.zero)` and
    /// uses the reading theme's pageBackground for its own card surface, so it
    /// stays distinct from the list's row background.
    private var previewRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: fontSize * paragraphSpacingMultiplier) {
                ForEach(Array(previewParagraphs.enumerated()), id: \.offset) { _, paragraph in
                    SettingsPreviewParagraph(
                        text: paragraph,
                        fontSize: fontSize,
                        lineSpacing: lineSpacing,
                        fontFamily: selectedFontFamily,
                        color: UIColor(selectedTheme.pageForeground)
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            Text("当前：\(selectedTheme.rawValue) · \(selectedFontFamily.displayName) · \(usesTraditionalChinese ? "繁体" : "简体") · 字号 \(Int(fontSize)) · 行距 \(Int(lineSpacing)) · 段距 \(String(format: "%.1f", paragraphSpacingMultiplier))")
                .font(.caption.weight(.medium))
                .foregroundStyle(selectedTheme.secondaryForeground)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectedTheme.pageBackground)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
    }

    private var fontSizeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("字号", systemImage: "textformat.size")
                Spacer()
                Text("\(Int(fontSize))")
                    .foregroundStyle(theme.secondaryText)
            }
            .font(.headline)

            Slider(value: $fontSize, in: 12...35, step: 1)
                .tint(theme.accent)
        }
    }

    private var lineSpacingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("行距", systemImage: "text.line.first.and.arrowtriangle.forward")
                Spacer()
                Text("\(Int(lineSpacing))")
                    .foregroundStyle(theme.secondaryText)
            }
            .font(.headline)

            Slider(value: $lineSpacing, in: 0...24, step: 1)
                .tint(theme.accent)
        }
    }

    private var paragraphSpacingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("段距", systemImage: "text.alignleft")
                Spacer()
                Text(String(format: "%.1f", paragraphSpacingMultiplier))
                    .foregroundStyle(theme.secondaryText)
            }
            .font(.headline)

            Slider(value: $paragraphSpacingMultiplier, in: 0...1.5, step: 0.1)
                .tint(theme.accent)
        }
    }

    private var fontFamilyPickerRow: some View {
        HStack {
            Label("字体", systemImage: "character.book.closed.fill")
                .font(.headline)
            Spacer()
            Picker("字体", selection: fontFamilyBinding) {
                ForEach(ReaderFontFamily.allCases) { family in
                    Text(family.displayName)
                        .font(family.swiftUIFont(size: 16))
                        .tag(family.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(theme.accent)
        }
    }

    private var pageTransitionPickerRow: some View {
        HStack {
            Label("翻页效果", systemImage: "book.pages")
                .font(.headline)
            Spacer()
            Picker("翻页效果", selection: pageTransitionBinding) {
                ForEach(PageTransitionStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(theme.accent)
        }
    }

    private var twoColumnRow: some View {
        Toggle(isOn: $twoColumnLayout) {
            Label("横屏双栏", systemImage: "rectangle.split.2x1")
                .font(.headline)
        }
    }

    private var readingThemeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("背景颜色", systemImage: "paintpalette")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 6) {
                ForEach(ReadingTheme.allCases) { readingTheme in
                    let isSelected = readingTheme == manualReadingTheme
                    let isAutoManaged = readerFollowSystemDark && readingTheme == .night
                    Button {
                        themeRawValue = readingTheme.rawValue
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(readingTheme.pageBackground)
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            isSelected ? theme.accent : Color.black.opacity(0.12),
                                            lineWidth: isSelected ? 2.5 : 1
                                        )
                                )
                                .overlay(alignment: .center) {
                                    if isAutoManaged {
                                        Image(systemName: "circle.lefthalf.filled")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(readingTheme.pageForeground)
                                    } else if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(readingTheme.pageForeground)
                                    }
                                }

                            Text(readingTheme.rawValue)
                                .font(.caption)
                                .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .opacity(isAutoManaged ? 0.55 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .disabled(isAutoManaged)
                }
            }

            Toggle(isOn: Binding(
                get: { readerFollowSystemDark },
                set: { newValue in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        readerFollowSystemDark = newValue
                        // Mirror the app-theme behavior: if the user's manual pick was the
                        // dark variant, downgrade it to the default light theme so the
                        // light-mode fallback doesn't stay stuck on 夜读.
                        if newValue, themeRawValue == ReadingTheme.night.rawValue {
                            themeRawValue = ReadingTheme.paper.rawValue
                        }
                    }
                }
            )) {
                Label("跟随系统深色模式", systemImage: "circle.lefthalf.filled")
                    .font(.subheadline)
            }
            .padding(.top, 4)

            if readerFollowSystemDark {
                Text("系统切换深色时自动启用「夜读」，浅色时使用上方所选背景。")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appThemeRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("外观主题", systemImage: "sparkles")
                .font(.headline)

            HStack(alignment: .top, spacing: 6) {
                ForEach(AppTheme.allCases) { option in
                    let isSelected = themeManager.current == option
                    let isAutoManaged = themeManager.followSystemDark && option == .starryNight
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            themeManager.select(option)
                        }
                    } label: {
                        VStack(spacing: 6) {
                            appThemeSwatch(for: option)

                            Text(option.displayName)
                                .font(.caption)
                                .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.displayName)
                    // When follow-system is on, the dark theme is auto-managed — block manual
                    // selection so the swatch reads as informational rather than tappable.
                    .disabled(isAutoManaged)
                }
            }

            Toggle(isOn: Binding(
                get: { themeManager.followSystemDark },
                set: { newValue in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        themeManager.setFollowSystemDark(newValue)
                    }
                }
            )) {
                Label("跟随系统深色模式", systemImage: "circle.lefthalf.filled")
                    .font(.subheadline)
            }

            if themeManager.followSystemDark {
                Text("系统切换深色时自动启用「星夜」，浅色时使用上方所选主题。")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var traditionalRow: some View {
        Toggle(isOn: $usesTraditionalChinese) {
            Label("繁体中文显示", systemImage: "character.book.closed")
                .font(.headline)
        }
    }

    private var autoScrollRow: some View {
        Toggle(isOn: $autoScroll) {
            Label("自动滚读", systemImage: "arrow.down.to.line.compact")
                .font(.headline)
        }
    }

    private var autoScrollSecondsRow: some View {
        HStack {
            Label("每页停留", systemImage: "timer")
                .font(.headline)
            Spacer()
            CompactStepper(
                value: $autoScrollSeconds,
                range: 2...30,
                step: 1,
                format: { "\(Int($0))秒" }
            )
        }
    }

    private func appThemeSwatch(for option: AppTheme) -> some View {
        let isSelected = themeManager.current == option
        let isAutoManaged = themeManager.followSystemDark && option == .starryNight
        return ZStack {
            if let imageName = option.swatchImageName {
                // Scale past the swatch frame so the white border baked into the source
                // artwork gets cropped out by the outer .clipShape(RoundedRectangle).
                Image(imageName)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.8)
            } else {
                LinearGradient(
                    colors: option.swatchGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                option.swatchOverlay
                    .allowsHitTesting(false)
            }

            if isAutoManaged {
                // The swatch is locked to system dark mode — show an "Auto" glyph instead of a
                // checkmark so the user understands the toggle below controls when it activates.
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(option.accent))
            } else if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(option.accent))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? theme.accent : theme.secondaryText.opacity(0.22),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .opacity(isAutoManaged ? 0.55 : 1.0)
    }

    // MARK: - Data rows

#if LINGYUE_INTERNAL
    private var sourcesNavRow: some View {
        NavigationLink {
            SourcesListView()
        } label: {
            Label("我的书源", systemImage: "books.vertical")
                .font(.headline)
        }
    }
#endif

    private var backupNavRow: some View {
        NavigationLink {
            BackupView()
        } label: {
            Label("导出与导入数据", systemImage: "externaldrive.badge.timemachine")
                .font(.headline)
        }
    }

    private var cachePrefetchRow: some View {
        Toggle(isOn: $cacheEnabled) {
            Label("自动预载后续章节", systemImage: "externaldrive")
                .font(.headline)
        }
    }

    private var cacheSizeRow: some View {
        HStack {
            Label("下载数据", systemImage: "internaldrive")
                .font(.headline)
            Spacer()
            Text(cacheSizeText)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var clearCacheRow: some View {
        Button(role: .destructive) {
            Task {
                await clearAllCache()
            }
        } label: {
            Label("清理全部下载数据", systemImage: "trash.slash")
                .font(.headline)
        }
    }

    // MARK: - About rows

#if LINGYUE_INTERNAL
    private var diagnosticsNavRow: some View {
        NavigationLink {
            ReaderDiagnosticsView()
        } label: {
            Label("阅读诊断", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
        }
    }
#endif

    private var aboutVersionRow: some View {
        HStack {
            Label("版本", systemImage: "info.circle")
                .font(.headline)
            Spacer()
            Text(appVersionString)
                .foregroundStyle(theme.secondaryText)
        }
    }

    // MARK: - Cache helpers

    @MainActor
    private func refreshCacheSize() async {
        let sizeBytes = await ChapterContentCache.shared.cacheSizeBytes()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        cacheSizeText = formatter.string(fromByteCount: sizeBytes)
    }

    @MainActor
    private func clearAllCache() async {
        downloadManager.clearAllStates()
        await ChapterContentCache.shared.clearAll()
        await refreshCacheSize()
        cacheNotice = "已清理全部下载数据"
        // Auto-dismiss the center toast after a brief read window. Re-tap of
        // the clear button just resets the same notice, so the latest tap
        // always controls when it disappears.
        let dismissedNotice = cacheNotice
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if cacheNotice == dismissedNotice {
                cacheNotice = nil
            }
        }
    }
}

/// Transient pill-shaped notice anchored at screen center. Used for one-shot
/// confirmations (e.g. "已清理全部下载数据") that the user only needs to glance at.
private struct CenterToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.78))
            )
            .shadow(color: Color.black.opacity(0.25), radius: 14, x: 0, y: 6)
            .accessibilityAddTraits(.isStaticText)
    }
}

#Preview {
    SettingsView()
}

/// Renders a single preview paragraph through the same UITextView/NSAttributedString
/// path the reader uses, so the Settings preview reflects the actual on-page font
/// metrics. Earlier the preview used SwiftUI `Text` with `Font.custom/system`, which
/// on real hardware rendered noticeably larger than the reader at the same nominal
/// point size — a UIKit/SwiftUI text-rendering divergence, not Dynamic Type.
///
/// Reports its own height to SwiftUI via `sizeThatFits` so the parent VStack can
/// lay it out within the preview card. Without an explicit width proposal, the
/// wrapped UITextView would request a single-line width and overflow the screen.
private struct SettingsPreviewParagraph: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let fontFamily: ReaderFontFamily
    let color: UIColor

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.attributedText = NSAttributedString(string: text, attributes: attributes)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let measured = NSAttributedString(string: text, attributes: attributes)
            .boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                context: nil
            )
        return CGSize(width: width, height: ceil(measured.height))
    }

    private var attributes: [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .justified
        paragraphStyle.baseWritingDirection = .leftToRight
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping
        return [
            .font: fontFamily.uiFont(size: fontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
    }
}

// MARK: - 我 hero

/// Bookmark-card hero shown at the top of the 我 tab. Carries the user's reading
/// streak, this-week minutes, and a thumbnail + progress bar for the most recently
/// opened novel. The whole card is wrapped in a `NavigationLink` by the parent so
/// tapping anywhere pushes `ReadingStatsView`.
private struct ReadingIdentityCard: View {
    @Environment(\.appTheme) private var theme
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false

    let streak: Int
    let weeklyMinutes: Int
    let currentBook: Novel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            streakRow
                .padding(.top, 16)
            divider
                .padding(.top, 16)
            currentBookRow
                .padding(.top, 12)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .background(
            LinearGradient(
                colors: theme.heroGradientStops,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            // Subtle 1-pt inner ring in the seal color at low opacity — gives the
            // card a "stamped document" edge without competing with the seal badge.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(theme.seal.opacity(0.18), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: theme.cardShadow.opacity(1.4), radius: 14, x: 0, y: 8)
    }

    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("READING JOURNAL")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(3.5)
                    .foregroundStyle(theme.seal.opacity(0.85))
                Text(lunarLikeDateString)
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .foregroundStyle(cardSecondaryText)
            }
            Spacer()
            sealBadge
        }
    }

    /// Square 印章-style badge. Rendered as a tilted red square with 灵阅 inside —
    /// matches the visual mark used on the README hero and the Library wallet card.
    private var sealBadge: some View {
        Text("灵阅")
            .font(.system(size: 13, weight: .bold, design: .serif))
            .foregroundStyle(Color(red: 0.97, green: 0.94, blue: 0.86))
            .frame(width: 42, height: 42)
            .background(theme.seal)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .inset(by: 3)
                    .stroke(Color(red: 0.97, green: 0.94, blue: 0.86).opacity(0.35), lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .rotationEffect(.degrees(2))
            .shadow(color: theme.seal.opacity(0.30), radius: 4, x: 0, y: 2)
    }

    private var streakRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text("\(streak)")
                .font(.system(size: 56, weight: .bold, design: .serif))
                .foregroundStyle(cardPrimaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(streakTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(cardPrimaryText)
                Text(weeklyMinutesText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(cardSecondaryText)
            }
            Spacer()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.seal.opacity(0.30))
            .frame(height: 0.5)
    }

    @ViewBuilder
    private var currentBookRow: some View {
        if let book = currentBook {
            HStack(spacing: 12) {
                miniCover(for: book)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayed(book.title))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(cardPrimaryText)
                        .lineLimit(1)
                    Text(progressLine(for: book))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(cardSecondaryText)
                    progressBar(progress: book.progress)
                        .padding(.top, 4)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(cardSecondaryText.opacity(0.7))
            }
        } else {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(cardSecondaryText.opacity(0.15))
                    .frame(width: 32, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("尚未开卷")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(cardPrimaryText)
                    Text("打开书架，挑一本开始阅读")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(cardSecondaryText)
                }
                Spacer()
            }
        }
    }

    private func miniCover(for book: Novel) -> some View {
        ZStack {
            LinearGradient(
                colors: [book.coverColor.opacity(0.96), book.coverColor.opacity(0.62)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(displayed(book.title))
                .font(.system(size: 8, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 3)
        }
        .frame(width: 32, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.6)
        )
        .shadow(color: Color.black.opacity(0.20), radius: 3, x: 0, y: 1)
    }

    private func progressBar(progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.seal.opacity(0.10))
                Capsule()
                    .fill(theme.seal)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: 3)
    }

    // MARK: card typography helpers

    /// Hero text reads against the cream gradient on light themes and against the
    /// deep slate gradient on starryNight; route both through the theme palette so
    /// adding a future dark theme doesn't require touching this view.
    private var cardPrimaryText: Color {
        theme == .starryNight ? theme.primaryText : Color(red: 0.13, green: 0.10, blue: 0.07)
    }

    private var cardSecondaryText: Color {
        theme == .starryNight ? theme.secondaryText : Color(red: 0.42, green: 0.35, blue: 0.27)
    }

    private var streakTitle: String {
        streak > 0 ? "连读 \(streak) 天" : "新的一卷"
    }

    private var weeklyMinutesText: String {
        if weeklyMinutes <= 0 { return "本周 0 分钟" }
        if weeklyMinutes < 60 { return "本周 \(weeklyMinutes) 分钟" }
        let hours = weeklyMinutes / 60
        let mins = weeklyMinutes % 60
        if mins == 0 { return "本周 \(hours) 小时" }
        return "本周 \(hours) 小时 \(mins) 分"
    }

    private func progressLine(for book: Novel) -> String {
        let pct = Int((book.progress * 100).rounded())
        let chapter = book.lastChapter.isEmpty ? "尚未开始" : book.lastChapter
        if pct <= 0 { return chapter }
        return "\(chapter) · 已读 \(pct)%"
    }

    /// Friendly date in the Chinese chrome the rest of the chrome uses — e.g.
    /// "五月二十日 · 周三". We keep it civil/Gregorian rather than running an actual
    /// lunar calendar conversion so the line stays low-cost to render and matches
    /// the date format users already see in 统计.
    private var lunarLikeDateString: String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 · EEEE"
        return formatter.string(from: now)
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }
}

/// Three-up mini metric chip used in the row directly under the hero card.
/// Reuses the chrome theme's card surface so it visually anchors to the rest of
/// the list (vs the hero's standalone warm-paper gradient).
private struct MetricChip: View {
    @Environment(\.appTheme) private var theme

    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: theme.cardShadow, radius: 6, x: 0, y: 3)
    }
}
