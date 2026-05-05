import SwiftUI

extension Color {
    static let readerBackground = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let readerSurface = Color(red: 1.0, green: 0.99, blue: 0.96)
    static let readerInk = Color(red: 0.11, green: 0.10, blue: 0.09)
    static let readerMuted = Color(red: 0.43, green: 0.39, blue: 0.34)
    static let readerAccent = Color(red: 0.36, green: 0.43, blue: 0.32)
    static let readerIndigo = Color(red: 0.32, green: 0.36, blue: 0.56)
    static let readerTeal = Color(red: 0.21, green: 0.49, blue: 0.48)
    static let readerRose = Color(red: 0.61, green: 0.34, blue: 0.39)
    static let readerBlue = Color(red: 0.23, green: 0.42, blue: 0.62)
    static let readerAmber = Color(red: 0.70, green: 0.50, blue: 0.22)
}

extension ReadingTheme {
    var pageBackground: Color {
        switch self {
        case .paper: return Color(red: 0.97, green: 0.96, blue: 0.93)
        case .warm:  return Color(red: 0.98, green: 0.92, blue: 0.82)
        case .mint:  return Color(red: 0.83, green: 0.91, blue: 0.83)
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
