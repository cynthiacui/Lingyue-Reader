import SwiftUI

/// Phase 6.1 — first-launch info screen for the App Store target's
/// "Add Source" flow. Frames Lingyue as a personal web-reading tool
/// and shows the two ways to add a source (paste a URL, or import a
/// JSON config). Tapping 继续 persists
/// `@AppStorage("onboarding.ipAttestationAccepted")` via `onAccept`
/// and the parent flow swaps to `AddSourceURLView` — one-time per
/// install, not per-sheet.
///
/// Only reachable from `AddSourceFlowView`, which is itself
/// `#if !LINGYUE_INTERNAL` — Internal builds ship with seeded rules,
/// so this onboarding doesn't apply. The store key keeps its original
/// name so upgrading users don't see the screen again.
struct IPAttestationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    let onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(theme.accent)

                    Text("添加你的网页书源")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)

                Text("灵阅是一款个人化的网页阅读工具——把你喜欢的网页加为书源，灵阅会自动识别页面上的书籍，方便你随时翻阅。")
                    .font(.subheadline)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 16) {
                    Text("两种添加方式")
                        .font(.headline)
                        .foregroundStyle(theme.primaryText)

                    InfoRow(
                        icon: "link",
                        title: "粘贴网址",
                        detail: "在下一步直接粘贴网页地址，灵阅会自动分析页面结构并生成书源。"
                    )

                    InfoRow(
                        icon: "square.and.arrow.down",
                        title: "导入配置文件",
                        detail: "如果你拿到了别人分享的书源配置（JSON 文件），可以直接导入，一键完成添加。"
                    )
                }

                Text("小贴士：请添加你可以访问、有权阅读的网页内容，比如个人博客、公开内容或你自己的网站。")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(theme.cardBackground.ignoresSafeArea())
        .navigationTitle("添加书源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("继续") { onAccept() }
                    .fontWeight(.semibold)
            }
        }
    }
}

private struct InfoRow: View {
    @Environment(\.appTheme) private var theme
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 28, height: 28)
                .background(theme.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)

                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
