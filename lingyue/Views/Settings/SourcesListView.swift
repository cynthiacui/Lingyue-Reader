import SwiftUI
import LingyueCore
#if LINGYUE_INTERNAL
import LingyueInternalSources
#endif

/// Phase 3.1 — sources management screen. Lists every rule available
/// to the runtime (seeded + user-authored), with per-rule enable/disable
/// toggles and drag-to-reorder. State lives in `SourcePreferenceStore`,
/// not in the rule JSON, so a user's on/off and ordering preferences are
/// per-install and never bleed into rules they share via the Phase 3.2
/// import flow.
///
/// Phase 3.2 — toolbar "+" pushes `SourceEditorView` with an empty draft
/// (the "from scratch" entry point). URL Analyzer (3.2.1) and JSON import
/// land as additional entries later; they will fold into a menu when a
/// second option exists.
///
/// The view reads from `\.sourceStack` directly. Refresh runs on `.task`
/// and again on each toggle/reorder so persistence flushes hit the
/// store before the UI redraws — the registry's `enabledSources()`
/// snapshot becomes consistent without explicit invalidation. `.onAppear`
/// re-runs on pop-back from the editor so newly-added / edited rules
/// land in the list without a manual pull-to-refresh.
struct SourcesListView: View {
    @Environment(\.sourceStack) private var sourceStack
    @Environment(\.appTheme) private var theme
    @Environment(\.editMode) private var editMode

    @State private var entries: [SourceEntry] = []
    @State private var loadError: String?
    @State private var hasLoaded = false
    @State private var isAddingSource = false
    /// Drives the row-tap navigation destination. Per the revised
    /// Phase 3 UX, tapping a row pushes the Review screen (not the
    /// raw schema editor) — see PHASES.md §3.3. The editor is only
    /// reachable from inside Review via the 高级修复 button.
    /// `nil` after `onComplete` pops the destination back to this list.
    @State private var selectedReviewEntry: SourceEntry?

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing == true
    }

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
                        // While editing, drop the NavigationLink wrapper.
                        // SwiftUI applies `.disabled` to nav-link labels
                        // inside a list in edit mode (the tap can't fire),
                        // which desaturates text, badges, and chevrons —
                        // making the whole list read as "disabled" even
                        // though the user only entered reorder mode. A
                        // bare card renders at full strength.
                        Group {
                            if isEditing {
                                ruleCard(entry)
                            } else {
                                Button {
                                    selectedReviewEntry = entry
                                } label: {
                                    ruleCard(entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                    .onMove(perform: handleMove)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("书源")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Standard SwiftUI EditButton: drives the list's edit mode so
            // `.onMove` activates only when the user opts in. Forcing
            // `.editMode = .active` (an earlier attempt) made the whole
            // list look disabled — toggles render in their disabled
            // appearance and NavigationLink rows stop responding to taps.
            ToolbarItem(placement: .topBarLeading) {
                if !entries.isEmpty { EditButton() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAddingSource = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建书源")
            }
        }
        .sheet(isPresented: $isAddingSource) {
            // Sheet-hosted URL form. The Review screen sits inside the
            // same NavigationStack so 分析 → 保存 → 列表 lives in one
            // modal. `onComplete` from Review fires after a successful
            // save, closing the sheet so the user lands back on the
            // updated source list.
            NavigationStack {
                AddSourceURLView(onComplete: {
                    isAddingSource = false
                    Task { await refresh() }
                })
            }
        }
        .task { await refresh() }
        .onAppear {
            // Re-fire on pop-back from the editor. `.task` only runs on
            // first appear, so without this a newly-saved rule wouldn't
            // surface until pull-to-refresh.
            if hasLoaded { Task { await refresh() } }
        }
        .refreshable { await refresh() }
        // Row-tap destination. Pushed when `selectedReviewEntry` becomes
        // non-nil; popping happens by the Review screen's `onComplete`
        // setting it back to nil. Using `navigationDestination(item:)`
        // rather than a NavigationLink keeps the dismiss path symmetric
        // with the sheet-hosted Add flow — both routes converge on a
        // single onComplete that pops and refreshes.
        .navigationDestination(item: $selectedReviewEntry) { entry in
            SourceReviewView(
                rule: entry.rule,
                onComplete: {
                    selectedReviewEntry = nil
                    Task { await refresh() }
                }
            )
        }
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
                priority: index,
                rowStatus: entry.rowStatus
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
            // The PageDetector cache is URL-keyed and has no idea which
            // source produced each cached hit — reorder/toggle must drop
            // it or a now-disabled source's prior result keeps flashing
            // on matching pages (PHASES.md §4.6).
            await sourceStack.pageDetector.invalidateCache()
        } catch {
            loadError = String(describing: error)
        }
    }

    private func refresh() async {
        do {
            let editable = try await sourceStack.editableStore.loadEditableSources()
            // Seeded rules are an Internal-target concept. The App Store
            // target ships with no bundled rules — the user starts with
            // an empty list and authors their own via §3.2.
#if LINGYUE_INTERNAL
            let seeded = LingyueInternalSources.bundledRules()
#else
            let seeded: [SourceRule] = []
#endif
            // Dedup by id: a user override and its seeded original share UUID;
            // the editable copy wins because the user authored it.
            let editableIDs = Set(editable.map(\.id))
            let bundled = seeded.filter { !editableIDs.contains($0.id) }

            let preferences = (try? await sourceStack.preferenceStore.loadAll()) ?? [:]
            let validations = (try? await sourceStack.validationStore.loadAll()) ?? [:]

            let merged: [SourceEntry] = (editable + bundled).map { rule in
                let pref = preferences[rule.id]
                let isEditable = editableIDs.contains(rule.id)
                return SourceEntry(
                    rule: rule,
                    origin: isEditable ? .editable : .seeded,
                    isEnabled: pref?.isEnabled ?? true,
                    priority: pref?.priority ?? .max,
                    rowStatus: Self.computeRowStatus(
                        rule: rule,
                        isEditable: isEditable,
                        isEnabled: pref?.isEnabled ?? true,
                        validation: validations[rule.id]
                    )
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
                await sourceStack.pageDetector.invalidateCache()
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

                // SwiftUI dims interactive controls inside a List in
                // edit mode regardless of their actual `isEnabled` value,
                // which made the page read as "everything disabled" when
                // the user only wanted to reorder. Hide the toggle while
                // editing — matches Apple's own pattern (Settings ›
                // Edit Home Screen drops toggle affordances while in
                // reorder mode).
                if !isEditing {
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
            }

            Text(rule.homepage.host(percentEncoded: false) ?? rule.homepage.absoluteString)
                .font(.footnote.monospaced())
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                originBadge(entry.origin)
                statusPill(entry.rowStatus)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerCard()
        .opacity(isEditing || entry.isEnabled ? 1.0 : 0.55)
    }

    private func statusPill(_ status: RowStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .ready: return ("可用", .green)
            case .needsCheck: return ("需要检查", .orange)
            case .failed: return ("测试失败", .red)
            case .disabled: return ("已关闭", theme.secondaryText)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
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

    /// Pill state per row. Seeded rules trust their authored
    /// `capabilities` (the bundle's curated rules don't need test
    /// records to be considered usable). User-authored rules read
    /// from `SourceValidationStore` — required blocks are
    /// `.detail + .catalog + .chapter`, matching the browse-only
    /// minimum from §3.3. Search is optional for the pill: a
    /// user-authored rule with detail+catalog+chapter passing but
    /// search untested still reports 可用 because import-from-browser
    /// works.
    static func computeRowStatus(
        rule: SourceRule,
        isEditable: Bool,
        isEnabled: Bool,
        validation: SourceValidation?
    ) -> RowStatus {
        guard isEnabled else { return .disabled }
        if !isEditable {
            let hasCapability = rule.capabilities.supportsSearch
                || rule.capabilities.supportsBrowserImport
            return hasCapability ? .ready : .needsCheck
        }
        let required: [SourceBlock] = [.detail, .catalog, .chapter]
        let effectiveStatuses = required.map { effectiveStatus($0, rule: rule, validation: validation) }
        if effectiveStatuses.contains(.failed) { return .failed }
        if effectiveStatuses.allSatisfy({ $0 == .passed }) { return .ready }
        return .needsCheck
    }

    /// Inline mirror of `SourceValidationStore.statusEffective` —
    /// avoids the protocol's async load-per-call overhead during list
    /// refresh, since we already have the full validation snapshot in
    /// memory.
    private static func effectiveStatus(
        _ block: SourceBlock,
        rule: SourceRule,
        validation: SourceValidation?
    ) -> BlockTestStatus {
        guard let record = validation?.tests[block] else { return .notRun }
        return rule.blockFingerprint(block) == record.inputFingerprint
            ? record.status
            : .notRun
    }
}

enum RowStatus: Hashable {
    case ready
    case needsCheck
    case failed
    case disabled
}

private struct SourceEntry: Identifiable, Hashable {
    enum Origin: Hashable { case seeded, editable }

    let rule: SourceRule
    let origin: Origin
    let isEnabled: Bool
    let priority: Int
    let rowStatus: RowStatus

    var id: UUID { rule.id }
}
