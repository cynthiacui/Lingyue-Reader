import SwiftUI

/// Reusable Discovery search bar — a magnifying-glass icon, a TextField, and a
/// trailing "搜索" button. Used by both the internal and App Store Discovery
/// pages so the bar stays visually and behaviourally identical across builds.
/// The parent owns the query text and focus state so it can drive recent-history
/// recording and navigation from a single place.
struct DiscoverySearchBar: View {
    @Environment(\.appTheme) private var theme
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
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
            }
            .buttonStyle(.plain)
            // An empty query is a no-op, so render the button as inactive rather
            // than letting it look tappable while doing nothing.
            .opacity(text.isEmpty ? 0.4 : 1)
            .disabled(text.isEmpty)
        }
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
