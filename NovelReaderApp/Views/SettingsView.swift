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

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 14 }
        return horizontalSizeClass == .compact ? 16 : 24
    }

    private var themeBinding: Binding<ReadingTheme> {
        Binding {
            ReadingTheme(rawValue: themeRawValue) ?? .paper
        } set: { newValue in
            themeRawValue = newValue.rawValue
        }
    }

    private var selectedTheme: ReadingTheme {
        ReadingTheme(rawValue: themeRawValue) ?? .paper
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
                Text("长安夜色如墨，雨声落在青石板上。沈砚合上残卷，忽然听见城楼方向传来三更鼓。")
                    .font(.system(size: fontSize, weight: .regular, design: .serif))
                    .foregroundStyle(Color.readerInk)
                    .lineSpacing(lineSpacing)
                    .minimumScaleFactor(0.9)

                Text("当前：\(selectedTheme.rawValue) · \(usesTraditionalChinese ? "繁体" : "简体")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.readerMuted)
            }
            .readerCard()
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

                    Slider(value: $fontSize, in: 16...26, step: 1)
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

                    Slider(value: $lineSpacing, in: 4...14, step: 1)
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

    @ViewBuilder
    private var themePicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("主题", selection: themeBinding) {
                ForEach(ReadingTheme.allCases) { theme in
                    Text(theme.rawValue).tag(theme)
                }
            }
            .pickerStyle(.menu)
        } else {
            Picker("主题", selection: themeBinding) {
                ForEach(ReadingTheme.allCases) { theme in
                    Text(theme.rawValue).tag(theme)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

#Preview {
    SettingsView()
}
