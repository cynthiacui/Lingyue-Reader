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
    /// Drives the "导出所选书源" file exporter. The selected editable rules
    /// are encoded into a `lingyue-sources` envelope (the same shape the
    /// import channels read) and wrapped in `BackupJSONDocument` so
    /// SwiftUI's `.fileExporter` can hand it to the system save/share sheet.
    @State private var exportDocument: BackupJSONDocument?
    @State private var exportFilename = "lingyue-sources.json"
    @State private var isExportingSelection = false
    @State private var exportError: String?

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
            // Selection-mode action bar: 导出 + 删除, two frosted circles
            // matching the tab bar they replace. Always present, shown/hidden
            // via opacity+offset rather than an `if`. The `.animation(value:
            // editMode)` below drives the bar on BOTH transitions regardless
            // of whether the mutation rode a withAnimation block — so it still
            // slides out on 取消, where the editMode flip is deliberately left
            // unanimated (an animated exit leaves the List's selection circles
            // stuck on). The enter transition (选择) does ride withAnimation so
            // the circles and this bar animate in together.
            HStack(spacing: 24) {
                exportFloatingButton
                deleteFloatingButton
            }
            .padding(.bottom, 28)
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
        // Export side of the same JSON picker: the selected editable rules
        // go out as a `lingyue-sources` envelope — the exact shape the
        // 从 JSON 文件导入 / 从网址导入 channels read back in.
        .fileExporter(
            isPresented: $isExportingSelection,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success:
                // Saved/shared — drop out of selection mode the way a
                // finished batch action would.
                selectedIDs.removeAll()
                editMode = .inactive
            case .failure(let error):
                exportError = error.localizedDescription
            }
            exportDocument = nil
        }
        .alert(
            "导出失败",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("好", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
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
    /// glyph. Dims to neutral and disables until at least one row is selected.
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
        .accessibilityLabel("删除所选书源")
    }

    /// Floating share button beside 删除: encodes the selected editable rules
    /// into a `lingyue-sources` JSON and hands it to `.fileExporter`. Same
    /// frosted-circle treatment as 删除, tinted to the theme accent.
    @ViewBuilder
    private var exportFloatingButton: some View {
        let count = selectedIDs.count
        Button {
            beginExportSelection()
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(count == 0 ? Color.secondary : theme.accent)
                .frame(width: 58, height: 58)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityLabel("导出所选书源")
    }

    /// Encode the selected editable rules into the canonical
    /// `lingyue-sources` envelope and trigger the file exporter. List order
    /// is preserved. Seeded rows can't be selected (see `selectionDisabled`),
    /// so we filter on `.editable` defensively and bail if nothing remains.
    private func beginExportSelection() {
        let rules = entries
            .filter { $0.origin == .editable && selectedIDs.contains($0.id) }
            .map(\.rule)
        guard !rules.isEmpty else { return }
        let payload = SourceImportPayload(
            kind: SourceImportPayload.kindTag,
            version: SourceImportPayload.currentVersion,
            createdAt: Date(),
            sources: rules
        )
        let encoder = JSONEncoder()
        // Match the import decoder (ISO8601 dates) and the editable store's
        // on-disk shape (pretty-printed, sorted keys); unescaped slashes keep
        // URLs readable for anyone who opens the file in a text editor.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(payload)
            exportDocument = BackupJSONDocument(data: data)
            exportFilename = "lingyue-sources.json"
            isExportingSelection = true
        } catch {
            exportError = error.localizedDescription
        }
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
                        // Animate ONLY the enter transition: the List's
                        // selection circles slide in together with the
                        // floating delete button rising, matching Mail.
                        // Exit (取消) stays unanimated — wrapping the
                        // editMode = .inactive flip in withAnimation is what
                        // left the circles stuck on; the floating button
                        // still slides out via its own scoped .animation.
                        withAnimation(.snappy) {
                            editMode = .active
                        }
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
            // Newest-added first: the editable store appends on add and
            // replaces edits in place, so its array is oldest→newest —
            // reversing puts a freshly-imported source at the top, where the
            // row-insertion animation lands. Order is independent of
            // enabled/verification state, so rows never reshuffle as a pill
            // settles (需要检查 → 检查中 → 可用). Seeded rules (Internal target
            // only; empty on App Store) trail after, in their bundled order.
            let editableEntries = merged.filter { $0.origin == .editable }.reversed()
            let seededEntries = merged.filter { $0.origin == .seeded }
            let sorted = Array(editableEntries) + seededEntries
            // Animate so freshly-imported rows slide in and status-pill
            // changes settle smoothly rather than snapping on each refresh.
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
            NavigationLink {
                SourceGuideView()
            } label: {
                HStack(spacing: 4) {
                    Text("想了解如何导入书源？查看使用指南")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.subheadline)
                .foregroundStyle(theme.accent)
                .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
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
                        Text("粘贴一份书源配置文件（JSON）的网址，灵阅会下载并预览要导入的书源。请确认你有权访问该来源的内容。")
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

/// In-app copy of the repo's 使用指南 — so users who can't reach GitHub can
/// still learn how to add / import / share book sources. Pushed from the
/// 书源 empty-state card and from 我 → 关于. Content mirrors README.md's
/// 使用指南 (manual add with the public-domain Wikisource example, the two
/// JSON import paths, and exporting a source pack via 选择 → 导出). Defined
/// here rather than in its own file because the project references sources
/// explicitly in the pbxproj (no synchronized groups), so a new file would
/// need manual build-phase surgery; co-locating it keeps the add reliable.
struct SourceGuideView: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    introCard
                    manualAddCard
                    importCard
                    shareCard
                }
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
        }
        .navigationTitle("使用指南")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Cards

    private var introCard: some View {
        Text("灵阅支持「手动添加 / 从 JSON 文件导入 / 从网址导入」三种方式添加书源。下面以版权自由的「维基文库」为例，讲解如何手动添加、导入现成的 JSON，以及把书源分享给别人。")
            .font(.subheadline)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .readerCard()
    }

    private var manualAddCard: some View {
        section("手动添加书源（以维基文库为例）") {
            paragraph("「手动添加」让灵阅根据你在浏览器里实际打开过的几个页面 URL 自动识别书源结构，你不必懂任何选择器或正则。")
            step("①", "进入「书源」页，点右上角「＋」→「手动添加」。")
            step("②", "按下面的字段填写。只有「书源主页」必填，其余示例 URL 建议尽量都填——给得越全，识别越准：")
            field("书源主页 URL（必填）", "网站首页", "https://zh.wikisource.org/")
            field("书源名称（可选）", "留空则取网站标题", "维基文库")
            field("书籍详情页 URL", "一本书的总目录页", "https://zh.wikisource.org/wiki/紅樓夢")
            field("章节正文 URL", "其中某一章的正文页", "https://zh.wikisource.org/wiki/紅樓夢/第001回")
            field("搜索结果页 URL", "站内搜索某关键词后的结果页", "https://zh.wikisource.org/w/index.php?search=紅樓夢&fulltext=1&ns0=1")
            field("搜索关键词", "上面那个搜索 URL 里实际搜的词", "紅樓夢")
            step("③", "点右上角「分析」。灵阅会抓取这些页面、自动推断出「搜索 / 目录 / 章节正文」的解析规则，并进入「书源详情」审核页。")
            step("④", "在审核页逐个点「测试」验证；个别环节识别不准时，点「高级修复（手动编辑规则）」微调。")
            step("⑤", "点「保存与启用」完成。该书源随即出现在列表中，「发现」页也能直接搜到它的书。")
            note("示例 URL 直接从浏览器地址栏复制最稳妥。维基文库、古腾堡、公版经典这类版权自由的站点最适合练手，分享出去也没有任何顾虑。")
        }
    }

    private var importCard: some View {
        section("导入现成的书源 JSON") {
            paragraph("如果别人已经给了你一份打包好的书源配置文件（JSON 格式），用下面任意一种方式导入即可。")
            subheading("从 JSON 文件导入")
            step("1", "把 .json 文件存到 iPhone 的「文件」App。")
            step("2", "进入「书源」页，点「＋」→「从 JSON 文件导入」，选中该文件。")
            step("3", "确认对话框提示「新增 / 覆盖 / 未变更」的条数，点「导入」完成。")
            subheading("从网址导入")
            step("1", "进入「书源」页，点「＋」→「从网址导入」。")
            step("2", "粘贴指向该书源 JSON 文件的 http(s) 网址（只填域名会自动补全为 https://），点「导入」。")
            step("3", "灵阅会下载该配置，并同样弹出「新增 / 覆盖 / 未变更」确认。")
            note("也可以用 lingyue://import?url=<网址> 深链一键唤起导入。请确认你有权访问该网址的内容。")
        }
    }

    private var shareCard: some View {
        section("把书源分享给别人") {
            paragraph("把你添加好的书源导出成一份书源 JSON 文件，发给别人即可导入。")
            step("①", "进入「书源」页，点右上角「选择」。")
            step("②", "勾选要分享的书源（只有自己添加的书源可选）。")
            step("③", "点底部的「导出」按钮（分享图标）。")
            step("④", "在系统面板里选「存储到文件」「隔空投送」等方式发出去。")
            note("对方收到后用「从 JSON 文件导入」即可。若把它放到一个能直接返回原文的网址上，对方还能用「从网址导入」一键添加。")
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: title)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .readerCard()
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subheading(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.primaryText)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ marker: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(theme.accent)
                .frame(minWidth: 18, alignment: .leading)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ name: String, _ desc: String, _ example: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Text(desc)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Text(example)
                .font(.caption.monospaced())
                .foregroundStyle(theme.accent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 26)
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lightbulb")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Text(text)
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}

