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
    /// Rule IDs currently being auto-verified after a toggle-on. Used to
    /// render an in-row 检查中… indicator so the user knows their flip
    /// kicked off a real-site verification round.
    @State private var verifyingIDs: Set<UUID> = []
    /// Drives the JSON file-picker. Flipped from the "+" menu's
    /// 从 JSON 导入 entry. After the picker resolves the rules are held
    /// in `pendingImport` so the confirm dialog can surface the
    /// add / overwrite / unchanged counts before any write happens.
    @State private var isImportingJSON = false
    @State private var pendingImport: PendingImport?
    @State private var importError: String?
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
        .navigationTitle("书源")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
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
        .alert(
            "导入书源",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            ),
            presenting: pendingImport
        ) { incoming in
            Button("取消", role: .cancel) {
                pendingImport = nil
            }
            Button("导入（\(incoming.summary.totalChanging) 项）") {
                let target = incoming
                pendingImport = nil
                Task { await applyImport(target) }
            }
            .disabled(incoming.summary.totalChanging == 0)
        } message: { incoming in
            Text(importDialogMessage(for: incoming.summary))
        }
        .alert(
            "导入失败",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            ),
            presenting: importError
        ) { _ in
            Button("好") { importError = nil }
        } message: { message in
            Text(message)
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editMode == .active {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") {
                    editMode = .inactive
                    selectedIDs.removeAll()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    pendingBatchDelete = true
                } label: {
                    Text(selectedIDs.isEmpty ? "删除" : "删除 (\(selectedIDs.count))")
                        .foregroundStyle(.red)
                }
                .disabled(selectedIDs.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isAddingSource = true
                    } label: {
                        Label("手动添加", systemImage: "link.badge.plus")
                    }
                    Button {
                        isImportingJSON = true
                    } label: {
                        Label("从 JSON 导入", systemImage: "square.and.arrow.down")
                    }
                    if entries.contains(where: { $0.origin == .editable }) {
                        Divider()
                        Button {
                            editMode = .active
                            selectedIDs.removeAll()
                        } label: {
                            Label("批量删除", systemImage: "checkmark.circle")
                        }
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
            editMode = .inactive
            selectedIDs.removeAll()
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
            editMode = .inactive
            selectedIDs.removeAll()
            await refresh()
        } catch {
            loadError = String(describing: error)
        }
    }

    // MARK: - JSON import

    private func handleImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await stageImport(at: url) }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    /// Read + decode the picked file and stage the result for the
    /// confirm dialog. The file write itself doesn't run until the user
    /// taps 导入, so a wrong file selection costs the user a tap, never
    /// a partial overwrite of their existing rules.
    private func stageImport(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let service = SourceImportService(editableStore: sourceStack.editableStore)
        do {
            let data = try Data(contentsOf: url)
            let rules = try service.decode(from: data)
            let summary = try await service.summarize(incoming: rules)
            pendingImport = PendingImport(rules: rules, summary: summary)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func applyImport(_ incoming: PendingImport) async {
        let service = SourceImportService(editableStore: sourceStack.editableStore)
        do {
            let summary = try await service.apply(incoming: incoming.rules)
            await DiscoverySearchService.shared.invalidateRegistryCache()
            await sourceStack.pageDetector.invalidateCache()
            await refresh()
            // Without this, every freshly-imported row sits at 需要检查
            // until the user toggles each one off-and-on to trigger
            // verifyAndPersist via toggleEnabled. Run the same chain
            // automatically so the pills land at 可用 on first paint.
            // Sequential keeps the per-source request throttle honest;
            // verifyAndPersist already refreshes the row when it finishes.
            // Search-less rules (jsonAPI, browser-import-only) reach the
            // detail URL via homepage discovery inside verifyAndPersist,
            // so they get verified too.
            let toVerify = summary.newRules + summary.updatedRules.map(\.incoming)
            // Pre-mark every queued rule as in-flight before kicking off
            // the sequential chain. Without this the rows that haven't
            // had their turn yet still render 需要检查 (orange), which
            // looks like a verification failure on first paint. Pills
            // flip to 检查中 (gray ProgressView) for the whole batch at
            // once, then resolve to 可用/失败 as each chain completes.
            for rule in toVerify { verifyingIDs.insert(rule.id) }
            await refresh()
            for rule in toVerify {
                await verifyAndPersist(rule: rule)
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importDialogMessage(for summary: SourceImportSummary) -> String {
        if summary.totalIncoming == 0 {
            return "未发现可导入的书源。"
        }
        var lines: [String] = []
        if summary.newRules.count > 0 {
            lines.append("将新增 \(summary.newRules.count) 个书源。")
        }
        if summary.updatedRules.count > 0 {
            lines.append("将覆盖 \(summary.updatedRules.count) 个同 ID 的本地书源。")
        }
        if summary.unchangedRules.count > 0 {
            lines.append("有 \(summary.unchangedRules.count) 个书源与本地一致，无需更新。")
        }
        return lines.joined(separator: "\n")
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
            entries = merged.sorted { lhs, rhs in
                lhs.rule.name.localizedStandardCompare(rhs.rule.name) == .orderedAscending
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
                    await verifyAndPersist(rule: entry.rule)
                }
            } catch {
                loadError = String(describing: error)
            }
        }
    }

    /// Run the live verification chain for `rule` and persist each
    /// passing block to `validationStore`. Silent on failure — verification
    /// is a background nicety, not a blocking save path. The user can
    /// always tap into Review and run the per-block tests manually.
    private func verifyAndPersist(rule: SourceRule) async {
        verifyingIDs.insert(rule.id)
        defer {
            verifyingIDs.remove(rule.id)
            Task { await refresh() }
        }
        // Route through the rule's own factory so jsonAPI rules (5dxs,
        // biquge) reach `JSONAPIBookSource` instead of the HTML scraper.
        // Without this every block fails verification for those rules
        // because the scraper hits the API endpoint and gets JSON.
        let source = rule.makeBookSource(loader: sourceStack.loader)

        // Build a candidate list: search hits first (when the rule has a
        // search step), then homepage anchors matching the detection
        // pathPattern. Walk this list rather than just taking the first
        // entry — some sites (xsw.tw) poison search results and homepage
        // listings with stub IDs that 404, so the first few candidates
        // routinely fail. Stopping at the first working book lets the
        // chain produce all four ✓ even when most candidates are dead.
        var candidates: [URL] = []
        if rule.search != nil || rule.jsonAPI?.search != nil {
            // Probe with a single common char first, then a 2-char fallback.
            // A few mainland CMS clones (daweixs) reject keywords whose
            // GB18030 byte length is < 4 — a single Chinese char is 2 bytes
            // and produces a "关键字过短" error page, so the smoke test for
            // those sites never marks search as 已识别 without the fallback.
            for probe in ["一", "小说"] {
                if let hits = try? await source.search(probe), !hits.isEmpty {
                    await persistVerification(rule: rule, block: .search, passed: true)
                    candidates.append(contentsOf: hits.prefix(8).map(\.detailURL))
                    break
                }
            }
        }
        let homepageCandidates = await findHomepageDetailURLs(rule: rule, limit: 8)
        for url in homepageCandidates where !candidates.contains(url) {
            candidates.append(url)
        }
        guard !candidates.isEmpty else { return }

        // Walk candidates. Persist each block as soon as ANY candidate
        // passes it, but keep walking until we find one candidate that
        // satisfies the full detail+catalog+chapter chain — otherwise a
        // 404 stub with a stray <h1> would mark detail as 已识别 while
        // catalog/chapter stay at 需要检查 forever.
        var detailPassedOnce = false
        var catalogPassedOnce = false
        var seenDetail: Set<URL> = []
        for candidateURL in candidates where seenDetail.insert(candidateURL).inserted {
            guard let detail = try? await source.fetchDetail(url: candidateURL),
                  !detail.title.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            if !detailPassedOnce {
                await persistVerification(rule: rule, block: .detail, passed: true)
                detailPassedOnce = true
            }
            guard let chapters = try? await source.fetchCatalog(url: detail.catalogURL),
                  !chapters.isEmpty
            else { continue }
            if !catalogPassedOnce {
                await persistVerification(rule: rule, block: .catalog, passed: true)
                catalogPassedOnce = true
            }
            // Many user-authored catalog rules use broad selectors (e.g.
            // `ul > li`) that scoop the site's top *and* bottom nav strips
            // alongside the real chapter rows — sampling first-N + last-N
            // still hits only nav junk on those sites. Real chapter URLs
            // cluster under one path directory (e.g. `/books/170611/…`)
            // while nav links scatter across `/`, `/list/`, etc. Filter to
            // the dominant directory before probing.
            let chapterCandidates = Self.likelyChapterLinks(chapters)
            let probes = Array(chapterCandidates.prefix(3)) + Array(chapterCandidates.suffix(3))
            var seenChapter: Set<URL> = []
            for chapter in probes where seenChapter.insert(chapter.url).inserted {
                if let content = try? await source.fetchChapter(url: chapter.url),
                   !content.paragraphs.isEmpty {
                    await persistVerification(rule: rule, block: .chapter, passed: true)
                    return
                }
            }
        }
    }

    /// Fetch the rule's homepage and return up to `limit` anchors whose
    /// paths match `detection.pathPattern`. Used as the search-less seed
    /// for the verification chain and to backfill ghost-ID search misses.
    private func findHomepageDetailURLs(rule: SourceRule, limit: Int) async -> [URL] {
        let request = SourceRequest(
            url: rule.homepage,
            headers: rule.defaultHeaders,
            encoding: rule.encoding,
            referer: nil
        )
        guard let snapshot = try? await sourceStack.loader.fetchHTML(request) else {
            return []
        }
        return rule.detailURLs(in: snapshot, limit: limit)
    }

    /// Filter a noisy catalog to the entries that look like real
    /// chapters. Heuristic: group by URL directory (path up to the
    /// final `/`) and keep only the dominant group. On well-authored
    /// rules the dominant group is the whole catalog, so the filter is
    /// a no-op. On rules where `ul > li` over-matches nav, the dominant
    /// group is the real chapter directory because nav links scatter
    /// across `/`, `/list/`, `/static/`, etc. while every real chapter
    /// lives under the book's path.
    private static func likelyChapterLinks(_ chapters: [ChapterLink]) -> [ChapterLink] {
        guard chapters.count > 1 else { return chapters }
        func directory(_ url: URL) -> String {
            let path = url.path
            guard let slash = path.lastIndex(of: "/") else { return path }
            return String(path[...slash])
        }
        var counts: [String: Int] = [:]
        for link in chapters { counts[directory(link.url), default: 0] += 1 }
        guard
            let dominant = counts.max(by: { $0.value < $1.value })?.key,
            // Require a meaningful majority — if no single directory
            // dominates, the catalog is probably structured weirdly and
            // we shouldn't second-guess it.
            (counts[dominant] ?? 0) >= chapters.count / 2
        else {
            return chapters
        }
        return chapters.filter { directory($0.url) == dominant }
    }

    private func persistVerification(rule: SourceRule, block: SourceBlock, passed: Bool) async {
        let record = BlockTestRecord(
            status: passed ? .passed : .failed,
            lastRunAt: Date(),
            failureSummary: passed ? nil : "自动验证未通过",
            inputFingerprint: rule.blockFingerprint(block)
        )
        try? await sourceStack.validationStore.recordTest(
            ruleID: rule.id,
            block: block,
            record: record
        )
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
                if verifyingIDs.contains(entry.rule.id) {
                    verifyingPill
                } else {
                    statusPill(entry.rowStatus)
                }
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

/// Local carrier for the JSON-import confirm dialog. Wraps the decoded
/// rule list plus the pre-computed diff against the editable store so
/// the dialog message and the apply step share one snapshot.
private struct PendingImport: Identifiable {
    let id = UUID()
    let rules: [SourceRule]
    let summary: SourceImportSummary
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
