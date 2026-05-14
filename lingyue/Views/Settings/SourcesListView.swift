import SwiftUI
import LingyueCore
import LingyueInternalSources

/// Phase 3.1 — sources management screen. Lists every rule available
/// to the runtime (seeded + user-authored), with per-rule enable/disable
/// toggles and drag-to-reorder. State lives in `SourcePreferenceStore`,
/// not in the rule JSON, so a user's on/off and ordering preferences are
/// per-install and never bleed into rules they share via the Phase 3.2
/// import flow.
///
/// What's intentionally NOT here yet:
/// - "Test" button — needs `SourceTestSheet` (task #20).
/// - Edit / delete — needs `SourceEditorView` (task #20).
/// - "Add Source" entry — Phase 3.2 work.
///
/// The view reads from `\.sourceStack` directly. Refresh runs on `.task`
/// and again on each toggle/reorder so persistence flushes hit the
/// store before the UI redraws — the registry's `enabledSources()`
/// snapshot becomes consistent without explicit invalidation.
struct SourcesListView: View {
    @Environment(\.sourceStack) private var sourceStack
    @Environment(\.appTheme) private var theme

    @State private var entries: [SourceEntry] = []
    @State private var loadError: String?
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if let loadError {
                ScrollView {
                    errorCard(loadError)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
            } else if !hasLoaded {
                ScrollView {
                    loadingCard
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
            } else if entries.isEmpty {
                ScrollView {
                    emptyCard
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
            } else {
                List {
                    ForEach(entries) { entry in
                        ruleCard(entry)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                    .onMove(perform: handleMove)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
            }
        }
        .navigationTitle("书源")
        .navigationBarTitleDisplayMode(.large)
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    /// Apply a user drag — reassign `priority` for the new order and persist
    /// every changed entry. Priorities are normalized to dense 0-based ints
    /// so a long history of moves can't drift values into absurd ranges.
    private func handleMove(from source: IndexSet, to destination: Int) {
        var reordered = entries
        reordered.move(fromOffsets: source, toOffset: destination)
        let normalized: [SourceEntry] = reordered.enumerated().map { index, entry in
            SourceEntry(
                rule: entry.rule,
                origin: entry.origin,
                isEnabled: entry.isEnabled,
                priority: index
            )
        }
        entries = normalized
        Task { await persistPriorities(normalized) }
    }

    private func persistPriorities(_ ordered: [SourceEntry]) async {
        do {
            for entry in ordered {
                try await sourceStack.preferenceStore.save(
                    SourcePreference(
                        ruleID: entry.rule.id,
                        isEnabled: entry.isEnabled,
                        priority: entry.priority
                    )
                )
            }
            await DiscoverySearchService.shared.invalidateRegistryCache()
        } catch {
            loadError = String(describing: error)
        }
    }

    private func refresh() async {
        do {
            let editable = try await sourceStack.editableStore.loadEditableSources()
            let seeded = LingyueInternalSources.bundledRules()
            // Dedup by id: a user override and its seeded original share UUID;
            // the editable copy wins because the user authored it.
            let editableIDs = Set(editable.map(\.id))
            let bundled = seeded.filter { !editableIDs.contains($0.id) }

            let preferences = (try? await sourceStack.preferenceStore.loadAll()) ?? [:]

            let merged: [SourceEntry] = (editable + bundled).map { rule in
                let pref = preferences[rule.id]
                return SourceEntry(
                    rule: rule,
                    origin: editableIDs.contains(rule.id) ? .editable : .seeded,
                    isEnabled: pref?.isEnabled ?? true,
                    priority: pref?.priority ?? .max
                )
            }
            entries = merged.sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.rule.name < rhs.rule.name
            }
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
        hasLoaded = true
    }

    private func toggleEnabled(for entry: SourceEntry, to newValue: Bool) {
        Task {
            do {
                let next = SourcePreference(
                    ruleID: entry.rule.id,
                    isEnabled: newValue,
                    priority: entry.priority
                )
                try await sourceStack.preferenceStore.save(next)
                // Drop the Discovery search service's per-process registry
                // cache so the next search round picks up the new enabled
                // set without waiting for app relaunch.
                await DiscoverySearchService.shared.invalidateRegistryCache()
                await refresh()
            } catch {
                loadError = String(describing: error)
            }
        }
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
            Label("还没有可用书源", systemImage: "tray")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
            Text("应用未检测到任何内置或自定义书源——这通常意味着资源未正确打包。")
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

    private func ruleCard(_ entry: SourceEntry) -> some View {
        let rule = entry.rule
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(rule.name)
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { entry.isEnabled },
                        set: { newValue in toggleEnabled(for: entry, to: newValue) }
                    )
                )
                .labelsHidden()
                .tint(theme.accent)
            }

            Text(rule.homepage.host(percentEncoded: false) ?? rule.homepage.absoluteString)
                .font(.footnote.monospaced())
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                originBadge(entry.origin)
                ForEach(capabilityBadges(for: rule), id: \.self) { badge in
                    capabilityBadge(badge)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerCard()
        .opacity(entry.isEnabled ? 1.0 : 0.55)
    }

    private func capabilityBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(theme.accent.opacity(0.12))
            .foregroundStyle(theme.accent)
            .clipShape(Capsule())
    }

    private func originBadge(_ origin: SourceEntry.Origin) -> some View {
        let label: String
        switch origin {
        case .seeded: label = "内置"
        case .editable: label = "自定义"
        }
        return Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(theme.secondaryText.opacity(0.12))
            .foregroundStyle(theme.secondaryText)
            .clipShape(Capsule())
    }

    private func capabilityBadges(for rule: SourceRule) -> [String] {
        var badges: [String] = []
        if rule.capabilities.supportsSearch { badges.append("搜索") }
        if rule.capabilities.supportsBrowserImport { badges.append("浏览导入") }
        if rule.capabilities.requiresWebRender { badges.append("需渲染") }
        return badges
    }
}

private struct SourceEntry: Identifiable, Hashable {
    enum Origin: Hashable { case seeded, editable }

    let rule: SourceRule
    let origin: Origin
    let isEnabled: Bool
    let priority: Int

    var id: UUID { rule.id }
}
