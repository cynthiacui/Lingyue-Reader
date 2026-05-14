import SwiftUI
import LingyueCore

/// Phase 3.1 — read-only listing of user-authored source rules from
/// `EditableSourceStore`. Renders one card per rule with name, host,
/// and a capability summary. Empty state is the common case until
/// Phase 3.2 lands the Add-source flow, so the empty copy invites
/// authoring without pretending the surface is broken.
///
/// What's intentionally NOT here yet:
/// - Enable/disable toggle and priority drag — both need a per-install
///   state model (rule JSON doesn't carry user preference) that I want
///   to design in its own commit.
/// - "Test" button — needs `SourceTestSheet`.
/// - "Add Source" entry — needs the Phase 3.2 scope-review on the URL
///   Analyzer ambition level before the editor's confidence UI can be
///   finalized.
///
/// The view reads from `\.sourceStack.editableStore` directly rather
/// than caching anywhere, so a Phase 3.2 save lands here on the next
/// `.task` / refresh without any plumbing.
struct SourcesListView: View {
    @Environment(\.sourceStack) private var sourceStack
    @Environment(\.appTheme) private var theme

    @State private var rules: [SourceRule] = []
    @State private var loadError: String?
    @State private var hasLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let loadError {
                    errorCard(loadError)
                } else if !hasLoaded {
                    loadingCard
                } else if rules.isEmpty {
                    emptyCard
                } else {
                    ForEach(rules) { rule in
                        ruleCard(rule)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .navigationTitle("书源")
        .navigationBarTitleDisplayMode(.large)
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        do {
            let loaded = try await sourceStack.editableStore.loadEditableSources()
            rules = loaded
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
        hasLoaded = true
    }

    // MARK: - Subviews

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("加载中…")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerCard()
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("还没有自定义书源", systemImage: "tray")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
            Text("使用规则编辑器添加新书源后，会显示在这里。内置书源不在此列表中——它们随版本更新。")
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerCard()
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("无法加载书源", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
            Text(message)
                .font(.footnote.monospaced())
                .foregroundStyle(theme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerCard()
    }

    private func ruleCard(_ rule: SourceRule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rule.name)
                .font(.headline)
                .foregroundStyle(theme.primaryText)
                .lineLimit(2)

            Text(rule.homepage.host(percentEncoded: false) ?? rule.homepage.absoluteString)
                .font(.footnote.monospaced())
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                ForEach(capabilityBadges(for: rule), id: \.self) { badge in
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.accent.opacity(0.12))
                        .foregroundStyle(theme.accent)
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerCard()
    }

    private func capabilityBadges(for rule: SourceRule) -> [String] {
        var badges: [String] = []
        if rule.capabilities.supportsSearch { badges.append("搜索") }
        if rule.capabilities.supportsBrowserImport { badges.append("浏览导入") }
        if rule.capabilities.requiresWebRender { badges.append("需渲染") }
        return badges
    }
}
