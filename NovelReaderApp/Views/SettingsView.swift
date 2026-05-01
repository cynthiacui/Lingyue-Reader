import SwiftUI

struct SettingsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @AppStorage("reader.fontSize") private var fontSize = 18.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.theme") private var themeRawValue = ReadingTheme.paper.rawValue
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false
    @AppStorage("reader.autoScroll") private var autoScroll = false
    @AppStorage("reader.cacheEnabled") private var cacheEnabled = true

    @State private var cacheSizeText = "计算中"
    @State private var cacheNotice: String?
    @State private var previewScrollOffset: CGFloat = 0

    private let previewBaseText = """
    长安夜色如墨，雨声落在青石板上。沈砚合上残卷，忽然听见城楼方向传来三更鼓。
    他披衣起身，推开木窗，远处灯火三两，江风拂面，带着早春未散的寒意。
    案头摊着未写完的家书，墨迹尚新，字句却迟迟未能落下。
    人在长安，剑在鞘中，少年志气未老，只是离家已远。
    巷口有人轻声唱着旧时曲，依稀还是江南口音，听得人心下一动。
    """

    private let previewScrollDistance: CGFloat = 140

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 14 }
        return horizontalSizeClass == .compact ? 16 : 24
    }

    private var selectedTheme: ReadingTheme {
        ReadingTheme(rawValue: themeRawValue) ?? .paper
    }

    private var displayedPreviewText: String {
        ChineseTextConverter.display(previewBaseText, usesTraditionalChinese: usesTraditionalChinese)
    }

    var body: some View {
        ZStack {
            Color.readerBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    previewSection
                    readingControlsSection
                    storageSection
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .safeAreaPadding(.bottom, 12)
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await refreshCacheSize()
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "阅读预览")

            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    Text(displayedPreviewText)
                        .font(.system(size: fontSize, weight: .regular, design: .serif))
                        .foregroundStyle(selectedTheme.pageForeground)
                        .lineSpacing(lineSpacing)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .offset(y: previewScrollOffset)
                }
                .frame(height: 168, alignment: .topLeading)
                .clipped()

                Text("当前：\(selectedTheme.rawValue) · \(usesTraditionalChinese ? "繁体" : "简体") · 字号 \(Int(fontSize)) · 行距 \(Int(lineSpacing))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(selectedTheme.secondaryForeground)
            }
            .padding(16)
            .background(selectedTheme.pageBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 6)
        }
        .onChange(of: autoScroll) { _, newValue in
            triggerPreviewScroll(enabled: newValue)
        }
        .onChange(of: fontSize) { _, _ in
            previewScrollOffset = 0
            if autoScroll { triggerPreviewScroll(enabled: true) }
        }
        .onChange(of: lineSpacing) { _, _ in
            previewScrollOffset = 0
            if autoScroll { triggerPreviewScroll(enabled: true) }
        }
        .onAppear {
            if autoScroll { triggerPreviewScroll(enabled: true) }
        }
    }

    private var readingControlsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "阅读偏好")

            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("字号", systemImage: "textformat.size")
                        Spacer()
                        Text("\(Int(fontSize))")
                            .foregroundStyle(Color.readerMuted)
                    }
                    .font(.headline)

                    Slider(value: $fontSize, in: 12...32, step: 1)
                        .tint(.readerAccent)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("行距", systemImage: "text.line.first.and.arrowtriangle.forward")
                        Spacer()
                        Text("\(Int(lineSpacing))")
                            .foregroundStyle(Color.readerMuted)
                    }
                    .font(.headline)

                    Slider(value: $lineSpacing, in: 0...24, step: 1)
                        .tint(.readerAccent)
                }

                themePicker

                Toggle(isOn: $usesTraditionalChinese) {
                    Label("繁体中文显示", systemImage: "character.book.closed")
                }

                Toggle(isOn: $autoScroll) {
                    Label("自动滚读", systemImage: "arrow.down.to.line.compact")
                }
            }
            .foregroundStyle(Color.readerInk)
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
                        .foregroundStyle(Color.readerMuted)
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

                if let cacheNotice {
                    Text(cacheNotice)
                        .font(.caption)
                        .foregroundStyle(Color.readerMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .foregroundStyle(Color.readerInk)
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
        await ChapterContentCache.shared.clearAll()
        cacheNotice = "已清理全部下载数据"
        await refreshCacheSize()
    }

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("背景颜色", systemImage: "paintpalette")
                .font(.headline)

            HStack(alignment: .top, spacing: 6) {
                ForEach(ReadingTheme.allCases) { theme in
                    Button {
                        themeRawValue = theme.rawValue
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(theme.pageBackground)
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            theme == selectedTheme ? Color.readerAccent : Color.black.opacity(0.12),
                                            lineWidth: theme == selectedTheme ? 2.5 : 1
                                        )
                                )
                                .overlay(alignment: .center) {
                                    if theme == selectedTheme {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(theme.pageForeground)
                                    }
                                }

                            Text(theme.rawValue)
                                .font(.caption)
                                .foregroundStyle(theme == selectedTheme ? Color.readerAccent : Color.readerMuted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func triggerPreviewScroll(enabled: Bool) {
        if enabled {
            previewScrollOffset = 0
            withAnimation(.linear(duration: 2.0)) {
                previewScrollOffset = -previewScrollDistance
            }
        } else {
            withAnimation(.easeOut(duration: 0.3)) {
                previewScrollOffset = 0
            }
        }
    }
}

#Preview {
    SettingsView()
}
