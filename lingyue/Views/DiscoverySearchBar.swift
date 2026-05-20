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
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button {
                    text = ""
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardBackground)
        )
    }
}
