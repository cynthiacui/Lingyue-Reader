import SwiftUI
import UniformTypeIdentifiers
import LingyueCore

/// Phase 3.1 — sources management screen. Lists every rule available
/// to the runtime (seeded + user-authored), with per-rule enable/disable
/// toggles and trailing-swipe delete on user-authored rows. State lives
/// in `SourcePreferenceStore`, not in the rule JSON, so a user's on/off
/// preferences are per-install and never bleed into rules they share
/// via the Phase 3.2 import flow.
///
/// Phase 3.2 — toolbar "+" pushes `SourceEditorView` with an empty draft
/// (the "from scratch" entry point). URL Analyzer (3.2.1) and JSON import
/// land as additional entries later; they will fold into a menu when a
/// second option exists.
///
/// The view reads from `\.sourceStack` directly. Refresh runs on `.task`
/// and again on each toggle so persistence flushes hit the store before
/// the UI redraws — the registry's `enabledSources()` snapshot becomes
/// consistent without explicit invalidation. `.onAppear` re-runs on
/// pop-back from the editor so newly-added / edited rules land in the
/// list without a manual pull-to-refresh.
struct SourcesListView: View {
    @Environment(\.sourceStack) private var sourceStack
    @Environment(\.appTheme) private var theme
    /// Root-owned import funnel shared with the URL and deep-link channels.
    /// Staging + the confirm dialog + apply all live here so every entry
    /// point behaves identically; this view only kicks off a staging call
    /// and lets the root present the confirm.
    @EnvironmentObject private var importCoordinator: SourceImportCoordinator

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
    /// Trailing-swipe delete target. Set when the user taps Delete on a
    /// row's swipe action; drives the confirmation alert. Cleared on
    /// confirm or cancel.
    @State private var pendingDelete: SourceEntry?
    /// Background verification owner. Lives outside the view so a
    /// chain that's mid-flight when the user navigates back (or
    /// dismisses the sheet) keeps running and the pill updates
    /// correctly on return.
    @ObservedObject private var verifier = SourceVerificationService.shared
    /// Drives the JSON file-picker. Flipped from the "+" menu's
    /// 从 JSON 文件导入 entry. The picked file's bytes are handed to
    /// `importCoordinator`, which stages the add / overwrite / unchanged
    /// diff and presents the confirm dialog at the app root.
    @State private var isImportingJSON = false
    /// Presents the "从网址导入" URL-paste sheet.
    @State private var isImportingURL = false
    /// Multi-select state. Active when the user taps 选择 in the toolbar.
    /// Selection is restricted to editable rows — seeded rules can't be
    /// deleted (the bundle re-emits them on next launch), so they render
    /// without a checkmark even in edit mode.
    @State private var editMode: EditMode = .inactive
    @State private var selectedIDs: Set<UUID> = []
    @State private var pendingBatchDelete = false

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            contentBody
        }
        .navigationTitle(editMode == .active ? selectionTitle : "书源")
        // Keep the title large in both modes. Toggling .inline → .large
        // programmatically is a known SwiftUI bug: the large title doesn't
        // re-expand on exit and stays collapsed/small even at scroll-top.
        .navigationBarTitleDisplayMode(.large)
        // Selection mode mirrors Mail / Photos: drop the back chevron and
        // tab bar so the screen is dedicated to selecting, with 全选 / 取消
        // in the nav bar and 删除 in a bottom bar where the tab bar was.
        .navigationBarBackButtonHidden(editMode == .active)
        .toolbar(editMode == .active ? .hidden : .automatic, for: .tabBar)
        .toolbar { toolbarContent }
        // Floating delete button (replaces the tab bar while selecting):
        // a circular frosted button with a red trash glyph, floating at the
        // bottom center over the list. The selection count stays in the nav
        // title, so the icon alone carries the action.
        .overlay(alignment: .bottom) {
            // Always present, shown/hidden via opacity+offset rather than an
            // `if`, so the *editMode change itself* never rides an animation
            // transaction. Wrapping editMode in withAnimation left the List's
            // selection circles stuck on after 取消; the animation is scoped
            // here to this button only.
            deleteFloatingButton
                .opacity(editMode == .active ? 1 : 0)
                .offset(y: editMode == .active ? 0 : 56)
                .allowsHitTesting(editMode == .active)
                .animation(.snappy, value: editMode)
        }
        .alert(
            "删除该书源？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { entry in
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                let target = entry
                pendingDelete = nil
                Task { await deleteEntry(target) }
            }
        } message: { entry in
            Text("书源「\(entry.rule.name)」会从书源列表中移除。该操作无法撤销。")
        }
        .alert(
            "删除 \(selectedIDs.count) 个书源？",
            isPresented: $pendingBatchDelete
        ) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await deleteSelected() }
            }
        } message: {
            Text("所选书源会从书源列表中移除。该操作无法撤销。")
        }
        .sheet(isPresented: $isAddingSource) {
            // Sheet-hosted URL form. The Review screen sits inside the
            // same NavigationStack so 分析 → 保存 → 列表 lives in one
            // modal. `onComplete` from Review fires after a successful
            // save, closing the sheet so the user lands back on the
            // updated source list.
            //
            // `AddSourceFlowView` is the Phase 6.1 gate wrapper: on the
            // App Store target it presents `IPAttestationView` until
            // the user accepts (once per install), then forwards to
            // `AddSourceURLView`. Internal builds skip the gate at
            // compile time.
            NavigationStack {
                AddSourceFlowView(onComplete: {
                    isAddingSource = false
                    Task { await refresh() }
                })
            }
        }
        .fileImporter(
            isPresented: $isImportingJSON,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImporterResult(result)
        }
        .sheet(isPresented: $isImportingURL) {
            ImportFromURLView { url in
                isImportingURL = false
                Task { await importCoordinator.stage(remoteURL: url) }
            }
        }
        .task { await refresh() }
        .onAppear {
            // Re-fire on pop-back from the editor. `.task` only runs on
            // first appear, so without this a newly-saved rule wouldn't
            // surface until pull-to-refresh.
            if hasLoaded { Task { await refresh() } }
        }
        // Re-pull validation status when the verification service flips
        // a rule out of the in-flight set — that's when 检查中 needs to
        // become 可用/失败 in the list.
        .onChange(of: verifier.verifyingIDs) { _, _ in
            Task { await refresh() }
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

    @ViewBuilder
    private var contentBody: some View {
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
            sourcesList
        }
    }

    private var sourcesList: some View {
        List(selection: $selectedIDs) {
            ForEach(entries) { entry in
                listRow(for: entry)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
    }

    private func listRow(for entry: SourceEntry) -> some View {
        Button {
            if editMode == .active {
                // Whole-card tap toggles selection in batch-delete mode —
                // the List's built-in leading checkmark is a small target,
                // so mirror its behavior across the full row. Seeded rows
                // ignore the tap (deleteDisabled hides their checkmark).
                guard entry.origin == .editable else { return }
                if selectedIDs.contains(entry.id) {
                    selectedIDs.remove(entry.id)
                } else {
                    selectedIDs.insert(entry.id)
                }
            } else {
                selectedReviewEntry = entry
            }
        } label: {
            ruleCard(entry)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .tag(entry.id)
        // Seeded rules can't be deleted (bundle re-emits them on next
        // launch). `selectionDisabled` hides the multi-select circle in
        // edit mode; `deleteDisabled` gates the swipe.
        .selectionDisabled(entry.origin != .editable)
        .deleteDisabled(entry.origin != .editable)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if entry.origin == .editable {
                // No `role: .destructive` here — the List would treat
                // the tap as a committed delete and animate the row out
                // before our confirmation alert resolves, causing the
                // row to flash out and back in if the user cancels.
                // `.tint(.red)` keeps the destructive styling.
                Button {
                    pendingDelete = entry
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .tint(.red)
            }
        }
    }

    /// Inline nav title while selecting — shows the running count the way
    /// Mail / Photos do ("已选择 N 项"), or a prompt when nothing's picked.
    private var selectionTitle: String {
        selectedIDs.isEmpty ? "选择书源" : "已选择 \(selectedIDs.count) 项"
    }

    /// Every deletable (user-authored) row. Seeded rows can't be deleted,
    /// so 全选 targets only these — matching the per-row `selectionDisabled`.
    private var editableEntryIDs: Set<UUID> {
        Set(entries.filter { $0.origin == .editable }.map(\.id))
    }

    private var allEditableSelected: Bool {
        let ids = editableEntryIDs
        return !ids.isEmpty && ids.isSubset(of: selectedIDs)
    }

    private func toggleSelectAll() {
        if allEditableSelected {
            selectedIDs.removeAll()
        } else {
            selectedIDs = editableEntryIDs
        }
    }

    /// Floating destructive button shown while selecting: a circular frosted
    /// button (matching the frosted tab bar it replaces) with a red trash
    /// glyph, floating bottom-center over the list. Dims to neutral and
    /// disables until at least one row is selected.
    @ViewBuilder
    private var deleteFloatingButton: some View {
        let count = selectedIDs.count
        Button {
            pendingBatchDelete = true
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(count == 0 ? Color.secondary : Color.red)
                .frame(width: 58, height: 58)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .padding(.bottom, 28)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editMode == .active {
            ToolbarItem(placement: .topBarLeading) {
                Button(allEditableSelected ? "取消全选" : "全选") {
                    toggleSelectAll()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("取消") {
                    selectedIDs.removeAll()
                    editMode = .inactive
                }
            }
        } else {
            // Separate toolbar items so 选择 and + each render as their own
            // pill (a ToolbarItemGroup crams both into one capsule). "+" stays
            // purely "add a source"; 选择 owns the destructive flow, matching
            // Mail / Files.
            if entries.contains(where: { $0.origin == .editable }) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("选择") {
                        selectedIDs.removeAll()
                        editMode = .active
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isAddingSource = true
                    } label: {
                        Label("手动添加", systemImage: "link.badge.plus")
                    }

                    Divider()

                    Button {
                        isImportingJSON = true
                    } label: {
                        Label("从 JSON 文件导入", systemImage: "doc")
                    }
                    Button {
                        isImportingURL = true
                    } label: {
                        Label("从网址导入", systemImage: "globe")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建书源")
            }
        }
    }

    /// Delete a user-authored source across all three persistence
    /// stores. Validation + preference records key on `ruleID`; without
    /// the parallel delete a later re-import with the same UUID would
    /// inherit the deleted rule's test history and enable/priority,
    /// which is wrong by construction (matches `SourceEditorView.delete`).
    private func deleteEntry(_ entry: SourceEntry) async {
        do {
            try await sourceStack.editableStore.deleteSource(id: entry.rule.id)
            try await sourceStack.validationStore.delete(ruleID: entry.rule.id)
            try await sourceStack.preferenceStore.delete(ruleID: entry.rule.id)
            await DiscoverySearchService.shared.invalidateRegistryCache()
            // PageDetector caches per-URL hits with no per-source key —
            // a deleted source's prior result would keep flashing on
            // matching pages otherwise (PHASES.md §4.6).
            await sourceStack.pageDetector.invalidateCache()
            await refresh()
        } catch {
            loadError = String(describing: error)
        }
    }

    /// Multi-row equivalent of `deleteEntry`. Iterates the editable
    /// selection sequentially so the three persistence stores stay in
    /// sync per rule, then invalidates downstream caches once at the end
    /// instead of per row. Seeded IDs in `selectedIDs` are filtered out
    /// — `deleteDisabled(true)` should already prevent them from being
    /// added, but the filter is belt-and-suspenders in case the user
    /// taps a seeded row before edit mode latches its disabled state.
    private func deleteSelected() async {
        let editableIDs = Set(
            entries.filter { $0.origin == .editable }.map(\.id)
        )
        let targets = selectedIDs.intersection(editableIDs)
        guard !targets.isEmpty else {
            selectedIDs.removeAll()
            editMode = .inactive
            return
        }
        do {
            for id in targets {
                try await sourceStack.editableStore.deleteSource(id: id)
                try await sourceStack.validationStore.delete(ruleID: id)
                try await sourceStack.preferenceStore.delete(ruleID: id)
            }
            await DiscoverySearchService.shared.invalidateRegistryCache()
            await sourceStack.pageDetector.invalidateCache()
            selectedIDs.removeAll()
            editMode = .inactive
            await refresh()
        } catch {
            loadError = String(describing: error)
        }
    }

    // MARK: - Import entry points

    /// File-picker result handler. Reads the picked file's bytes while the
    /// security-scoped resource is open, then hands them to the shared
    /// coordinator — staging + the confirm dialog + apply all live at the
    /// root so every import channel behaves identically. The list refreshes
    /// reactively via `onChange(of: verifier.verifyingIDs)` once the
    /// coordinator's apply kicks off verification.
    private func handleImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                Task { await importCoordinator.stage(data: data) }
            } catch {
                importCoordinator.errorMessage = error.localizedDescription
            }
        case .failure(let error):
            importCoordinator.errorMessage = error.localizedDescription
        }
    }

    private func refresh() async {
        do {
            let editable = try await sourceStack.editableStore.loadEditableSources()
            // Seeded rules are an Internal-target concept. The App Store
            // target ships with no bundled rules — the user starts with
            // an empty list and authors their own via §3.2.
            let seeded: [SourceRule] = []
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
            let sorted = merged.sorted { lhs, rhs in
                lhs.rule.name.localizedStandardCompare(rhs.rule.name) == .orderedAscending
            }
            // Animate so freshly-imported rows slide in and status-pill
            // changes (需要检查 → 检查中 → 可用) settle smoothly rather than
            // snapping on each refresh.
            withAnimation(.easeInOut(duration: 0.25)) {
                entries = sorted
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
                // Auto-verify on enable: re-running the search→detail→
                // catalog→chapter chain against the live site refreshes
                // every block's persisted test status, so disable→enable
                // cycles no longer reset the pills to 需要检查 for blocks
                // the user never manually tested. Editable rules only —
                // seeded rules trust their authored capabilities.
                if newValue && entry.origin == .editable {
                    verifier.verify(rule: entry.rule)
                }
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
        .sourcesListCard()
    }

    @ViewBuilder
    private var emptyCard: some View {
        appStoreFirstLaunchCard
    }

    private var appStoreFirstLaunchCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("尚未添加任何来源", systemImage: "books.vertical")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
            Text("点击右上角 + 添加您要读取的网页来源。")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sourcesListCard()
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
        .sourcesListCard()
    }

    private func ruleCard(_ entry: SourceEntry) -> some View {
        let rule = entry.rule
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
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
                Group {
                    if verifier.verifyingIDs.contains(entry.rule.id) {
                        verifyingPill
                            .transition(.opacity)
                    } else {
                        statusPill(entry.rowStatus)
                            .transition(.opacity)
                    }
                }
                // Crossfade the 检查中 ↔ 可用/需要检查 pill swap.
                .animation(.easeInOut(duration: 0.2), value: verifier.verifyingIDs.contains(entry.rule.id))
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sourcesListCard()
    }

    private var verifyingPill: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            Text("检查中…")
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(theme.secondaryText.opacity(0.12))
        .foregroundStyle(theme.secondaryText)
        .clipShape(Capsule())
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

/// Local card style for the 书源 list. Uses `Color(.systemBackground)` instead of
/// `theme.cardBackground` so cards read as a whiter "raised" surface against the
/// theme-tinted page background. Keeping it local avoids changing every other
/// `.readerCard()` caller (Settings / Backup / etc.) where pure white would
/// clash with the surrounding chrome.
private struct SourcesListCardModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: theme.cardShadow, radius: 12, x: 0, y: 6)
    }
}

private extension View {
    func sourcesListCard() -> some View {
        modifier(SourcesListCardModifier())
    }
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

/// "从网址导入" sheet — paste an http(s) link to a `lingyue-sources` JSON
/// config (e.g. a raw gist URL). `onSubmit` hands a validated URL back to
/// the caller, which routes it through `SourceImportCoordinator`. A bare
/// host (no scheme) is upgraded to `https://` so a pasted "example.com/x"
/// still resolves.
private struct ImportFromURLView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var urlText = ""
    let onSubmit: (URL) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeBackgroundView()
                Form {
                    Section {
                        TextField("https://example.com/sources.json", text: $urlText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .onSubmit(submit)
                    } header: {
                        Text("书源配置链接")
                    } footer: {
                        Text("粘贴一份 lingyue-sources JSON 配置的网址，灵阅会下载并预览要导入的书源。请确认你有权访问该来源的内容。")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("从网址导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导入", action: submit)
                        .fontWeight(.semibold)
                        .disabled(normalizedURL == nil)
                }
            }
        }
    }

    private var normalizedURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private func submit() {
        guard let url = normalizedURL else { return }
        onSubmit(url)
    }
}

