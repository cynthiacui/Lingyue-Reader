import SwiftUI
import UIKit

/// Reader body-text font choice. iOS 17 ships PingFang SC plus the Hiragino Japanese family
/// (Mincho-style serif and a rounded "Maru" sans), but does *not* bundle Songti / Kaiti /
/// Yuanti anymore — those families are absent from `UIFont.familyNames`. So 宋体/黑体/圆体
/// route to the closest visually-distinct on-device face, and 楷体 is satisfied by the
/// open-source LXGW WenKai Screen TTF bundled in `SupportingFiles/Fonts/`.
enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case system
    case systemLight
    case songti
    case kaiti
    case heiti
    case yuanti

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:      return "苹方"
        case .systemLight: return "苹方细"
        case .songti:      return "宋体"
        case .kaiti:       return "楷体"
        case .heiti:       return "黑体"
        case .yuanti:      return "圆体"
        }
    }

    /// Postscript names to try, in order. The first one that resolves wins. `kaiti` uses the
    /// bundled LXGW WenKai Screen (registered via `UIAppFonts`); the others are stock iOS.
    /// `systemLight` explicitly requests PingFang SC Light so the user can pick a lighter
    /// body weight without affecting the default `system` rendering.
    private var postScriptCandidates: [String] {
        switch self {
        case .system:      return []
        case .systemLight: return ["PingFangSC-Light"]
        case .songti:      return ["HiraMinProN-W3"]
        case .kaiti:       return ["LXGWWenKaiScreen"]
        case .heiti:       return ["HiraginoSans-W6", "HiraginoSans-W3"]
        case .yuanti:      return ["HiraMaruProN-W4"]
        }
    }

    var resolvedPostScriptName: String? {
        postScriptCandidates.first { UIFont(name: $0, size: 12) != nil }
    }

    func uiFont(size: CGFloat) -> UIFont {
        if let name = resolvedPostScriptName, let font = UIFont(name: name, size: size) {
            return font
        }
        return UIFont.systemFont(ofSize: size, weight: .regular)
    }

    func swiftUIFont(size: CGFloat) -> Font {
        if let name = resolvedPostScriptName {
            return Font.custom(name, size: size)
        }
        return Font.system(size: size, weight: .regular)
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
        case .mint:  return Color(red: 0.9333, green: 0.9804, blue: 0.9333)
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
        ZStack(alignment: .bottomLeading) {
            coverBackground

            Text(displayed(novel.title))
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
                .lineSpacing(4)
                .lineLimit(3)
                .minimumScaleFactor(0.75)
                .padding(10)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var coverBackground: some View {
        if let coverImageURLString = novel.coverImageURLString,
           let url = URL(string: coverImageURLString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .overlay(Color.black.opacity(0.24))
                default:
                    fallbackCover
                }
            }
        } else {
            fallbackCover
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

/// Compact `[ − ] value [ ＋ ]` stepper used in Settings and the reader preferences popup.
/// Tap targets are fixed-width cells with hairline dividers so taps near the value text
/// don't accidentally change it.
struct CompactStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var background: Color = Color(.tertiarySystemFill)
    var foreground: Color? = nil
    var dividerColor: Color? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        let resolvedForeground = foreground ?? theme.primaryText
        let resolvedDivider = dividerColor ?? theme.secondaryText.opacity(0.25)

        let canDecrement = value > range.lowerBound
        let canIncrement = value < range.upperBound

        HStack(spacing: 0) {
            Button {
                guard canDecrement else { return }
                value = max(range.lowerBound, value - step)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canDecrement)
            .opacity(canDecrement ? 1 : 0.35)

            Rectangle()
                .fill(resolvedDivider)
                .frame(width: 1, height: 18)

            Text(format(value))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 6)
                .frame(minWidth: 52, minHeight: 32)

            Rectangle()
                .fill(resolvedDivider)
                .frame(width: 1, height: 18)

            Button {
                guard canIncrement else { return }
                value = min(range.upperBound, value + step)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canIncrement)
            .opacity(canIncrement ? 1 : 0.35)
        }
        .foregroundStyle(resolvedForeground)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background)
        )
    }
}

struct SectionHeader: View {
    let title: String
    var actionTitle: String?

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
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
