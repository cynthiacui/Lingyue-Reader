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

extension View {
    func readerCard() -> some View {
        self
            .padding(16)
            .background(Color.readerSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 6)
    }
}

struct BookCover: View {
    let novel: Novel
    var width: CGFloat = 72
    var height: CGFloat = 104

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [novel.coverColor.opacity(0.96), novel.coverColor.opacity(0.68)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Text(novel.title)
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
}

struct SectionHeader: View {
    let title: String
    var actionTitle: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.readerInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer()

            if let actionTitle {
                Button(actionTitle) { }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.readerAccent)
            }
        }
    }
}
