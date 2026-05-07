import SwiftUI

struct SettingsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.appForcesColorScheme) private var appForcesColorScheme
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var downloadManager: BookDownloadManager

    @AppStorage("reader.fontSize") private var fontSize = 18.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.fontFamily") private var fontFamilyRaw = ReaderFontFamily.system.rawValue
    @AppStorage("reader.pageTransition") private var pageTransitionRaw = PageTransitionStyle.instant.rawValue
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

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 14 }
        return horizontalSizeClass == .compact ? 16 : 24
    }

    /// Theme actually used to render the preview — respects follow-system when on.
    private var selectedTheme: ReadingTheme {
        ReadingTheme.effective(
            rawValue: themeRawValue,
            followSystemDark: readerFollowSystemDark,
            systemColorScheme: systemColorScheme,
            appForcesColorScheme: appForcesColorScheme
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

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    previewCard
                    readingControlsSection
                    appThemeSection
                    storageSection
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .safeAreaPadding(.bottom, 12)

            if let cacheNotice {
                CenterToast(text: cacheNotice)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: cacheNotice)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await refreshCacheSize()
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(displayedPreviewText)
                .font(selectedFontFamily.swiftUIFont(size: fontSize))
                .foregroundStyle(selectedTheme.pageForeground)
                .lineSpacing(lineSpacing)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            Text("当前：\(selectedTheme.rawValue) · \(selectedFontFamily.displayName) · \(usesTraditionalChinese ? "繁体" : "简体") · 字号 \(Int(fontSize)) · 行距 \(Int(lineSpacing))")
                .font(.caption.weight(.medium))
                .foregroundStyle(selectedTheme.secondaryForeground)
        }
        .padding(16)
        .background(selectedTheme.pageBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: theme.cardShadow, radius: 12, x: 0, y: 6)
    }

    private var appThemeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "外观主题")

            VStack(alignment: .leading, spacing: 14) {
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
                }
                .font(.subheadline)
                .foregroundStyle(theme.primaryText)

                if themeManager.followSystemDark {
                    Text("系统切换深色时自动启用「星夜」，浅色时使用上方所选主题。")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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

    private var readingControlsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "阅读偏好")

            VStack(spacing: 12) {
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

                fontFamilyPicker

                pageTransitionPicker

                // The trailing padding pushes the next toggle far enough below themePicker that
                // the nested 跟随系统深色模式 row reads as part of the 背景颜色 group, not as the
                // first of the lower toggles.
                themePicker
                    .padding(.bottom, 8)

                Toggle(isOn: $usesTraditionalChinese) {
                    Label("繁体中文显示", systemImage: "character.book.closed")
                        .font(.headline)
                }
                .frame(minHeight: 36)

                Toggle(isOn: $autoScroll) {
                    Label("自动滚读", systemImage: "arrow.down.to.line.compact")
                        .font(.headline)
                }
                .frame(minHeight: 36)

                if autoScroll {
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
            }
            .foregroundStyle(theme.primaryText)
            .readerCard()
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "离线与缓存")

            VStack(spacing: 14) {
                Toggle(isOn: $cacheEnabled) {
                    Label("自动预载后续章节", systemImage: "externaldrive")
                }

                HStack {
                    Label("下载数据", systemImage: "internaldrive")
                    Spacer()
                    Text(cacheSizeText)
                        .foregroundStyle(theme.secondaryText)
                }

                Button(role: .destructive) {
                    Task {
                        await clearAllCache()
                    }
                } label: {
                    Label("清理全部下载数据", systemImage: "trash.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .foregroundStyle(theme.primaryText)
            .readerCard()
        }
    }

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

    private var fontFamilyPicker: some View {
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
        .frame(minHeight: 36)
    }

    private var pageTransitionPicker: some View {
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
        .frame(minHeight: 36)
    }

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            // minHeight matches fontFamilyPicker / pageTransitionPicker so the visual rhythm
            // between the three "row" labels in 阅读偏好 is even — without it, the gap above
            // 背景颜色 is shorter than the gap above 翻页效果.
            Label("背景颜色", systemImage: "paintpalette")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)

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
                // Stays at .subheadline (lighter than the section's .headline labels) because
                // this toggle is a sub-option of 背景颜色, not a top-level reading setting.
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
