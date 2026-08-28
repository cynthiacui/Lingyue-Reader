import SwiftUI

/// Reusable Discovery search bar — a magnifying-glass icon, a TextField, and a
/// trailing "搜索" button. Used by both the internal and App Store Discovery
/// pages so the bar stays visually and behaviourally identical across builds.
/// The parent owns the query text and focus state so it can drive recent-history
/// recording and navigation from a single place.
///
/// Responds to the standard `.disabled(_:)` modifier: SwiftUI already blocks the
/// field, buttons, and tap gesture, so the bar only has to dim its contents to
/// read as inert. The App Store Discovery page disables it when the user has no
/// book sources, since search would have nothing to query.
struct DiscoverySearchBar: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        // At accessibility sizes the placeholder and the trailing 搜索 label both
        // grow until 10pt of spacing reads as an ordinary space between CJK
        // glyphs, and the bar renders as one run of text — "搜索小说名或关键词 搜索".
        // Widen the gap and give the button a tinted capsule so it stays a
        // distinct control. Matches how the parent view already branches on
        // `isAccessibilitySize` for its horizontal margin.
        HStack(spacing: dynamicTypeSize.isAccessibilitySize ? 14 : 10) {
            Image(systemName: "magnifyingglass")
                .font(.headline)
                .foregroundStyle(theme.secondaryText)

            TextField("搜索小说名或关键词", text: $text)
                .focused(focus)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
                // Fire the same search action when the user taps the keyboard's
                // "search" return key, not just the trailing 搜索 button.
                .onSubmit(onSubmit)
                .lineLimit(1)
                // Pin the field to the available width. Without this, pasting a
                // very long single-line string makes the TextField report a huge
                // intrinsic content width, which blows the HStack out past the
                // screen edge and pushes the icon / clear / 搜索 button off-screen.
                // Capping at maxWidth: .infinity forces the text to scroll inside
                // the field instead of dictating the bar's width.
                .frame(maxWidth: .infinity)

            if !text.isEmpty {
                Button {
                    text = ""
                    // Keep editing after clearing: if the keyboard was dismissed
                    // (e.g. user scrolled it away), tapping the clear button brings
                    // it back so they can immediately type a new query.
                    focus.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除")
            }

            Button(action: onSubmit) {
                Text("搜索")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    // Never let the growing placeholder squeeze the label — the
                    // TextField yields width instead.
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 12 : 0)
                    .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 6 : 0)
                    .background {
                        if dynamicTypeSize.isAccessibilitySize {
                            Capsule().fill(theme.accent.opacity(0.14))
                        }
                    }
            }
            .buttonStyle(.plain)
            // An empty query is a no-op, so render the button as inactive rather
            // than letting it look tappable while doing nothing.
            .opacity(text.isEmpty ? 0.4 : 1)
            .disabled(text.isEmpty)
        }
        // Dim the contents rather than the whole bar so the card still reads as
        // a field sitting on the page — a faded background would nearly vanish
        // against `theme.cardBackground`.
        .opacity(isEnabled ? 1 : 0.45)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardBackground)
        )
        // Tapping anywhere in the bar (icon, padding, the dimmed 搜索 button's
        // area) starts editing, matching a native search field. Guard on the
        // current focus so taps that land on the TextField still position the
        // cursor normally instead of being intercepted.
        .contentShape(Rectangle())
        .onTapGesture {
            if !focus.wrappedValue { focus.wrappedValue = true }
        }
    }
}
