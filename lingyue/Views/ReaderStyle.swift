import SwiftUI
import UIKit

/// Curated reader body-text font set. Four intentional choices — sans, serif, modern
/// minimalist, rounded — chosen to feel distinct without overlap. App chrome (titles,
/// labels, book covers) always renders in the system font; this selection only drives
/// reader body content.
///
/// Raw values are preserved across enum revisions so persisted `@AppStorage` settings
/// don't regress when entries are dropped. The legacy `kaiti` / `systemLight` / `heiti`
/// rawValues fall through to `.system` via the `?? .system` rescue at every read site.
enum ReaderFontFamily: String, CaseIterable, Identifiable {
    /// 苹方 — PingFang SC, the default. Modern, clean, balanced for long sessions.
    case system

    /// 思源宋体 — bundled Source Han Serif SC. Stock-iOS Songti / Hiragino Mincho act as
    /// the safety net if the OTF is somehow absent at runtime.
    case songtiSerif = "songti"

    /// 文楷 — bundled LXGW WenKai GB Lite. A humanist kai (楷) face: warmer and more
    /// hand-written than Songti. The GB Lite subset covers everyday simplified Chinese;
    /// any rarer glyph falls back per-character to the system font, so no tofu.
    case wenkai

    /// MiSans — bundled Xiaomi MiSans Regular. Falls back to PingFang via the system
    /// font path when the TTF is missing.
    case misans

    /// 圆体 — Hiragino Maru ProN W4 (iOS-bundled). Critical for CJK rendering because
    /// `Font.system(design: .rounded)` only applies SF Rounded to Latin glyphs; Han
    /// characters fall back to PingFang and read identically to 苹方. Hiragino Maru has
    /// comprehensive CJK Han coverage and renders Chinese in a true rounded style.
    case yuanti

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:       return "苹方"
        case .songtiSerif:  return "思源宋体"
        case .wenkai:       return "文楷"
        case .misans:       return "MiSans"
        case .yuanti:       return "圆体"
        }
    }

    /// Postscript names to try, in order. The first one that resolves wins. Empty list
    /// means "use the plain system font" (PingFang for CJK).
    private var postScriptCandidates: [String] {
        switch self {
        case .system:
            return []
        case .songtiSerif:
            return [
                "SourceHanSerifSC-Regular",
                "SourceHanSerifCN-Regular",
                "STSongti-SC-Regular",
                "HiraMinProN-W3"
            ]
        case .wenkai:
            return ["LXGWWenKaiGBLite-Regular", "STKaiti", "Kaiti SC"]
        case .misans:
            return ["MiSans-Regular", "MiSans-Normal"]
        case .yuanti:
            return ["HiraMaruProN-W4"]
        }
    }

    /// True when the *ultimate* system-font fallback should apply SF Rounded. Used only
    /// if `.yuanti`'s postscript candidates all fail to resolve — in practice Hiragino
    /// Maru is bundled on iOS, so this branch is defensive.
    private var usesRoundedDesign: Bool {
        self == .yuanti
    }

    var resolvedPostScriptName: String? {
        postScriptCandidates.first { UIFont(name: $0, size: 12) != nil }
    }

    func uiFont(size: CGFloat) -> UIFont {
        if let name = resolvedPostScriptName, let font = UIFont(name: name, size: size) {
            return font
        }
        let base = UIFont.systemFont(ofSize: size, weight: .regular)
        if usesRoundedDesign, let descriptor = base.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    func swiftUIFont(size: CGFloat) -> Font {
        if let name = resolvedPostScriptName {
            return Font.custom(name, size: size)
        }
        return Font.system(
            size: size,
            weight: .regular,
            design: usesRoundedDesign ? .rounded : .default
        )
    }
}

/// How the reader animates a within-chapter page turn. Chapter-boundary swaps remain
/// instant regardless of style — V1 only animates inside a chapter.
enum PageTransitionStyle: String, CaseIterable, Identifiable {
    case instant
    case slide
    case pageCurl

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .instant:  return "无动画"
        case .slide:    return "滑动"
        case .pageCurl: return "仿真翻页"
        }
    }
}

/// One source of truth for the reader and 我 → 阅读偏好 controls. Both surfaces
/// intentionally use the same typography and dimensions even though their colors
/// and containers differ.
enum ReaderPreferenceControlMetrics {
    static let rowSpacing: CGFloat = 6
    static let iconSize: CGFloat = 14
    static let labelSize: CGFloat = 15
    static let menuLabelWidth: CGFloat = 36
    static let swatchSize: CGFloat = 28
    static let swatchIconSize: CGFloat = 11
}

struct ReaderPreferenceSliderRow: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let foregroundColor: Color
    let valueColor: Color
    let tintColor: Color
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: ReaderPreferenceControlMetrics.rowSpacing) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(
                        size: ReaderPreferenceControlMetrics.iconSize,
                        weight: .semibold
                    ))
                    .foregroundStyle(foregroundColor)

                Text(title)
                    .font(.system(
                        size: ReaderPreferenceControlMetrics.labelSize,
                        weight: .medium
                    ))
                    .foregroundStyle(foregroundColor)

                Spacer(minLength: 0)

                Text(format(value))
                    .font(.system(
                        size: ReaderPreferenceControlMetrics.labelSize,
                        weight: .semibold
                    ).monospacedDigit())
                    .foregroundStyle(valueColor)
            }

            Slider(value: $value, in: range, step: step)
                .tint(tintColor)
        }
    }
}

struct ReaderPreferenceMenuRow<SelectionValue: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    let foregroundColor: Color
    let tintColor: Color
    @ViewBuilder let options: () -> Options

    init(
        title: String,
        selection: Binding<SelectionValue>,
        foregroundColor: Color,
        tintColor: Color,
        @ViewBuilder options: @escaping () -> Options
    ) {
        self.title = title
        self._selection = selection
        self.foregroundColor = foregroundColor
        self.tintColor = tintColor
        self.options = options
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(
                    size: ReaderPreferenceControlMetrics.labelSize,
                    weight: .medium
                ))
                .foregroundStyle(foregroundColor)
                .frame(
                    width: ReaderPreferenceControlMetrics.menuLabelWidth,
                    alignment: .leading
                )

            Spacer(minLength: 0)

            Picker(title, selection: $selection) {
                options()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(tintColor)
        }
    }
}

/// Shared attributed-text construction for settings preview, pagination measurement,
/// and the visible reader page. Keeping paragraph style and font resolution here
/// prevents nominally identical settings from producing different line geometry.
enum ReaderTextLayout {
    static func attributes(
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        fontFamily: ReaderFontFamily,
        color: UIColor
    ) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .justified
        paragraphStyle.baseWritingDirection = .leftToRight
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacing = fontSize * paragraphSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping

        return [
            .font: fontFamily.uiFont(size: fontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
    }
}

extension Color {
    static let readerBackground = Color(red: 0.9333, green: 0.9804, blue: 0.9333)
    static let readerSurface = Color(red: 0.984, green: 0.973, blue: 0.949)
    // Softened from near-black toward a warm graphite so long-form reading feels less
    // like high-contrast print and more like a MUJI / Apple Books paper page.
    static let readerInk = Color(red: 0.18, green: 0.16, blue: 0.14)
    static let readerMuted = Color(red: 0.45, green: 0.41, blue: 0.37)
    static let readerAccent = Color(red: 0.36, green: 0.43, blue: 0.32)
    static let readerIndigo = Color(red: 0.32, green: 0.36, blue: 0.56)
    static let readerTeal = Color(red: 0.21, green: 0.49, blue: 0.48)
    static let readerRose = Color(red: 0.61, green: 0.34, blue: 0.39)
    static let readerBlue = Color(red: 0.23, green: 0.42, blue: 0.62)
    static let readerAmber = Color(red: 0.70, green: 0.50, blue: 0.22)
}

extension ReadingTheme {
    /// Resolves the reading theme actually shown to the reader. When `followSystemDark` is on,
    /// the dark `.night` (夜读) variant activates only while the device is in dark mode;
    /// otherwise the user's manual pick is used (downgraded to `.paper` if it itself was
    /// `.night`, so the reader doesn't appear "stuck on night" after enabling follow-system).
    ///
    /// `deviceIsInDarkMode` must reflect the *device's* actual mode — not SwiftUI's
    /// `\.colorScheme` env, which the app's `.preferredColorScheme(...)` override masks.
    /// `SystemAppearance` reads it from the active scene's screen trait collection, where
    /// the override has no effect.
    static func effective(
        rawValue: String,
        followSystemDark: Bool,
        deviceIsInDarkMode: Bool
    ) -> ReadingTheme {
        let manual = ReadingTheme(rawValue: rawValue) ?? .paper
        guard followSystemDark else { return manual }
        if deviceIsInDarkMode { return .night }
        return manual == .night ? .paper : manual
    }

    var pageBackground: Color {
        switch self {
        // MUJI-style off-white cream — slightly desaturated from the previous warmer
        // beige so the page reads as modern paper rather than aged paperback. The
        // eye-strain green lives under `.mint` ("护眼") below.
        case .paper: return Color(red: 0.9569, green: 0.9451, blue: 0.9216)
        case .warm:  return Color(red: 0.9725, green: 0.9373, blue: 0.8510)
        case .mint:  return Color(red: 0.8902, green: 0.9255, blue: 0.8824)
        case .sky:   return Color(red: 0.85, green: 0.91, blue: 0.96)
        case .night: return Color(red: 0.08, green: 0.08, blue: 0.075)
        }
    }

    var pageForeground: Color {
        self == .night ? Color(red: 0.88, green: 0.85, blue: 0.78) : .readerInk
    }

    var secondaryForeground: Color {
        self == .night ? Color(red: 0.66, green: 0.63, blue: 0.56) : .readerMuted
    }

    /// Background for reader chrome (top/bottom bars). Darker than the page in night mode so
    /// the bars read as elevated; matches the page in light themes.
    var chromeBackground: Color {
        self == .night ? Color(red: 0.12, green: 0.12, blue: 0.11) : pageBackground
    }

    /// Background for floating panels (e.g., chapter picker overlay).
    var surfaceBackground: Color {
        self == .night ? Color(red: 0.13, green: 0.13, blue: 0.12) : .readerSurface
    }
}

extension View {
    func readerCard() -> some View {
        modifier(ReaderCardModifier())
    }
}

private struct ReaderCardModifier: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: theme.cardShadow, radius: 12, x: 0, y: 6)
    }
}

struct BookCover: View {
    let novel: Novel
    var width: CGFloat = 72
    var height: CGFloat = 104
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false

    var body: some View {
        let centered = !hasCoverImage
        ZStack(alignment: centered ? .center : .bottomLeading) {
            coverBackground

            Text(displayed(novel.title))
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
                .lineSpacing(4)
                .lineLimit(3)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(centered ? .center : .leading)
                .padding(centered ? 8 : 10)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
    }

    private var hasCoverImage: Bool {
        guard let s = novel.coverImageURLString,
              URL(string: s) != nil else { return false }
        return true
    }

    @ViewBuilder
    private var coverBackground: some View {
        ZStack {
            fallbackCover

            if let coverImageURLString = novel.coverImageURLString,
               URL(string: coverImageURLString) != nil {
                StoredBookCoverImage(
                    bookID: novel.id,
                    remoteURLString: coverImageURLString
                )
            }
        }
    }

    private var fallbackCover: some View {
        LinearGradient(
            colors: [novel.coverColor.opacity(0.96), novel.coverColor.opacity(0.68)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func displayed(_ text: String) -> String {
        ChineseTextConverter.display(text, usesTraditionalChinese: usesTraditionalChinese)
    }
}

struct SectionHeader: View {
    let title: String
    var actionTitle: String?

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer()

            if let actionTitle {
                Button(actionTitle) { }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.accent)
            }
        }
    }
}

/// Pill displayed next to a book title when its `ReadingStatsBook` is `isDeleted`. Used
/// by the stats top-books card and the browsing-history list, so it's intentionally
/// theme-agnostic — a warm beige/clay so the pill reads as a soft "archived" tag
/// instead of generic theme-tinted grey.
struct RemovedFromLibraryBadge: View {
    var body: some View {
        Text("已移出书架")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color(red: 0.478, green: 0.349, blue: 0.275))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Color(red: 0.949, green: 0.886, blue: 0.820)))
            .overlay(Capsule().stroke(Color(red: 0.769, green: 0.643, blue: 0.522).opacity(0.45), lineWidth: 0.6))
    }
}
