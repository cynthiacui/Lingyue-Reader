import SwiftUI
import LingyueCore
#if LINGYUE_INTERNAL
import LingyueInternalSources
#endif

/// Phase 3.3 — Review screen. Lands after `AddSourceURLView` and shows
/// the analyzer's per-block confidence as the user's primary mental
/// model (identity / detection read-only above; search / detail /
/// catalog / chapter status pills below). The Review screen NEVER
/// authors `SourceCapabilities` directly — those are derived at save
/// time from rule shape plus per-block effective status from
/// `SourceValidationStore` (PHASES.md §3.5.2).
///
/// **Slice 6 lifts validation state onto disk.** Per-block test results
/// persist via `FileSourceValidationStore` keyed by `ruleID`. A passing
/// test survives an app restart; editing the rule's selectors in the
/// advanced editor flips the recorded fingerprint, which makes
/// `statusEffective` treat the prior pass as `.notRun` until the user
/// re-tests. That's the §3.5.1 "stale passes don't count" semantic.
///
/// 修复 deep-link: slice 6 still pushes the existing `SourceEditorView`
/// as the advanced surface without scrolling to a section. After the
/// editor pops, the Review screen re-reads both the rule (from
/// `editableStore`) and the validation snapshot (which now reports
/// stale entries as `.notRun` automatically through fingerprint
/// invalidation).
struct SourceReviewView: View {
    @Environment(\.sourceStack) private var sourceStack
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    /// Nil when the Review screen is opened from `SourcesListView`'s
    /// row tap — i.e. the user is re-inspecting an existing saved rule
    /// rather than landing here right after running the analyzer. Test
    /// sheets fall back to empty prefills in that case (the rule lives
    /// on disk; there's no example-book-URL/keyword to recall).
    let analyzerInput: AnalyzerInput?
    let onComplete: () -> Void

    @State private var draft: SourceRule
    @State private var report: AnalysisReport
    @State private var blockStatuses: [SourceBlock: BlockTestStatus] = [:]
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var testingBlock: SourceBlock?
    @State private var pendingAdvancedEdit: AdvancedEditDestination?
    @State private var hasAppearedOnce = false
    /// True when this rule lives in `editableStore` (i.e. it's a saved
    /// user-authored source). Drives whether the delete action surfaces
    /// at the bottom of the screen — seeded rules are bundle-resident
    /// and can't be deleted, and a freshly-analyzed draft (not yet
    /// saved) has nothing to delete either.
    @State private var canDelete = false
    @State private var pendingDelete = false
    @State private var isDeleting = false
    /// True when the rule lives in `editableStore`. Drives `canDelete`
    /// (the delete button only surfaces for editable rows).
    @State private var isEditableRule = false
    /// True when the rule's id matches a bundled (seeded) rule. The
    /// bundle vouches for the rule's authored capabilities, so the
    /// Review pills trust those claims rather than reporting 需要检查
    /// for every block. This holds even if the user imported the same
    /// rule into `editableStore` via JSON import — the curated bundle
    /// is still the source of truth for whether the rule should work.
    @State private var isSeededOriginal = false

    /// Wrapper for `navigationDestination(item:)`. Carries both the
    /// rule snapshot the editor opens against and the deep-link target
    /// section — per-block 修复 buttons scroll the editor to the
    /// failing block, while the generic 高级修复 button leaves
    /// `anchor` nil so the editor opens at the top.
    struct AdvancedEditDestination: Hashable {
        var rule: SourceRule
        var anchor: SourceEditorView.ScrollAnchor?
    }

    init(
        rule: SourceRule,
        report: AnalysisReport = AnalysisReport(),
        analyzerInput: AnalyzerInput? = nil,
        onComplete: @escaping () -> Void
    ) {
        self.analyzerInput = analyzerInput
        self.onComplete = onComplete
        self._draft = State(initialValue: rule)
        self._report = State(initialValue: report)
    }

    var body: some View {
        Form {
            identitySection
            detectionSection
            blocksSection
            actionsSection
            if report.isStub {
                stubNoticeSection
            }
            if let saveError {
                Section {
                    Text(saveError)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            if canDelete {
                deleteSection
            }
        }
        .navigationTitle("书源详情")
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除该书源？", isPresented: $pendingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await deleteDraft() }
            }
        } message: {
            Text("书源「\(draft.name)」会从书源列表中移除。该操作无法撤销。")
        }
        .task { await refreshValidation() }
        .sheet(item: $testingBlock) { block in
            NavigationStack {
                SourceTestSheet(
                    rule: draft,
                    initialStep: block.testStep,
                    initialInput: defaultTestInput(for: block),
                    onResult: { step, passed in
                        guard step == block.testStep else { return }
                        Task { await recordTestResult(block, passed: passed) }
                    }
                )
            }
        }
        .navigationDestination(item: $pendingAdvancedEdit) { destination in
            SourceEditorView(
                rule: destination.rule,
                origin: .editable,
                scrollTo: destination.anchor
            )
        }
        .onAppear {
            // First appear is right after the analyzer ran — keep the
            // freshly-analyzed draft. Every subsequent appear is a
            // pop-back from the advanced editor, where the user may
            // have saved schema changes; re-read both the rule and the
            // validation snapshot so the per-block pills reflect any
            // fingerprint invalidation that just happened.
            if hasAppearedOnce {
                Task {
                    await reloadDraftFromStore()
                    await refreshValidation()
                }
            } else {
                hasAppearedOnce = true
            }
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            TextField("书源名称", text: $draft.name)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            HStack {
                Text("主页")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(draft.homepage.absoluteString)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } header: {
            Text("基础信息")
        } footer: {
            if let suggested = report.suggestedName, !suggested.isEmpty {
                Text("分析建议名称:\(suggested)")
            }
        }
    }

    private var detectionSection: some View {
        // Row-tap entries come with an empty AnalysisReport — the analyzer
        // only runs on Add-via-URL. Fall back to the rule's persisted
        // hostPatterns so seeded sources don't display "未能识别域名".
        let hosts = report.detectedHosts.isEmpty ? draft.detection.hostPatterns : report.detectedHosts
        return Section {
            if hosts.isEmpty {
                Text("未能识别域名")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hosts, id: \.self) { host in
                    HStack {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                        Text(host)
                            .font(.footnote.monospaced())
                    }
                }
            }
            if let note = report.notes["detection"] {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("检测到的域名")
        } footer: {
            Text("应用内浏览器与搜索路由会用这些域名识别本书源。默认不可编辑——如需调整请进入「高级修复」。")
        }
    }

    private var blocksSection: some View {
        // Hide the 搜索 row when the rule has no search step — biquge,
        // 5dxs and similar browser-import-only sources don't search, so
        // surfacing 需要检查 there reads as "broken" when there's nothing
        // to test in the first place.
        let visibleBlocks = SourceBlock.allCases.filter { block in
            block != .search || draft.search != nil
        }
        return Section {
            ForEach(visibleBlocks, id: \.self) { block in
                blockRow(block)
            }
        } header: {
            Text("识别状态")
        } footer: {
            Text("点击「测试」会用真实站点验证该步骤;通过后状态变为「已识别」。如果该步骤的选择器之后被修改,先前的通过记录会自动失效。")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await save(enable: false) }
            } label: {
                HStack {
                    if isSaving { ProgressView() }
                    Text("保存草稿")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)

            Button {
                Task { await save(enable: true) }
            } label: {
                HStack {
                    if isSaving { ProgressView() }
                    Text("启用书源")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!canEnable || isSaving)

            Button {
                pendingAdvancedEdit = AdvancedEditDestination(rule: draft, anchor: nil)
            } label: {
                Label("高级修复(手动编辑规则)", systemImage: "wrench.and.screwdriver")
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Text("保存与启用")
        } footer: {
            Text("「启用书源」要求至少书籍详情、目录、章节三项均已识别——这是浏览导入的最低条件。搜索若未通过测试,该书源不会出现在搜索栏。")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                pendingDelete = true
            } label: {
                HStack {
                    if isDeleting { ProgressView() }
                    Label("删除书源", systemImage: "trash")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(isDeleting)
        } footer: {
            Text("删除后该书源的规则、测试记录和启用状态都会一并清除。")
        }
    }

    private var stubNoticeSection: some View {
        Section {
            Label(
                "主页抓取或解析失败,当前仅按 URL 推断域名。请运行「测试」或在「高级修复」中手动配置。",
                systemImage: "exclamationmark.triangle"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
        }
    }

    private func blockRow(_ block: SourceBlock) -> some View {
        let status = effectiveStatus(block)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(block.label)
                if let note = report.notes[block.rawValue], !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            statusPill(status)
            Button("测试") {
                testingBlock = block
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            // Per-block 修复 deep-link (PHASES.md §3.4): pushes the
            // advanced editor pre-scrolled to this block's section so
            // the user lands on the failing selectors rather than the
            // top of the form. Anchor stays in lock-step with the
            // editor's `ScrollAnchor` enum via `block.scrollAnchor`.
            Button("修复") {
                pendingAdvancedEdit = AdvancedEditDestination(
                    rule: draft,
                    anchor: block.scrollAnchor
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func statusPill(_ status: BlockTestStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .passed: return ("已识别", .green)
            case .failed: return ("测试失败", .red)
            case .notRun: return ("需要检查", .orange)
            }
        }()
        return Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - Computed gating

    private var canEnable: Bool {
        // Browse-only enable per PHASES.md §3.3: detail + catalog + chapter
        // all 已识别 is the minimum bar. Search is optional — when it's
        // not passed the source is hidden from Discovery but still
        // routable via in-app browser import. Analyzer-green counts as
        // a soft pass here (see `effectiveStatus`), so a clean analyze →
        // enable round-trip works without forcing a manual Test.
        let core: [SourceBlock] = [.detail, .catalog, .chapter]
        return core.allSatisfy { effectiveStatus($0) == .passed }
            && !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Combine the persisted test record with the analyzer's confidence
    /// for `block`. Test record wins when it's passed or failed (and
    /// matches the current fingerprint via `refreshValidation`).
    /// Otherwise analyzer-green acts as a soft `.passed` so the Review
    /// pills + Enable gate reflect what the analyzer just found instead
    /// of demanding a manual Test for every clean analyze. Analyzer
    /// yellow/red/notRun keep the block at `.notRun` — the user still
    /// needs to inspect or test before relying on those.
    private func effectiveStatus(_ block: SourceBlock) -> BlockTestStatus {
        if let recorded = blockStatuses[block], recorded != .notRun {
            return recorded
        }
        // Seeded rules ship through the curated bundle — the per-block
        // pills should trust their authored capabilities rather than
        // demanding a live test for blocks the bundle vouches for.
        // Without this every seeded source opens with all rows at 需要检查
        // because the validation store has no records for bundle rules.
        // Also covers the case where the user has an editable copy of a
        // bundled rule (e.g., imported via JSON) — the bundle still
        // vouches for it.
        if isSeededOriginal, let trusted = seededTrustedStatus(for: block) {
            return trusted
        }
        return analyzerSoftStatus(for: block)
    }

    /// Returns `.passed` when the bundle's authored capabilities vouch
    /// for the block — search relies on `supportsSearch`; detail / catalog
    /// / chapter ride on `supportsBrowserImport` (the minimum browse
    /// bar). Returns nil when the capability is off, in which case the
    /// caller falls through to the analyzer soft-status path.
    private func seededTrustedStatus(for block: SourceBlock) -> BlockTestStatus? {
        switch block {
        case .search:
            return draft.capabilities.supportsSearch ? .passed : nil
        case .detail, .catalog, .chapter:
            return draft.capabilities.supportsBrowserImport ? .passed : nil
        }
    }

    private func analyzerSoftStatus(for block: SourceBlock) -> BlockTestStatus {
        let confidence: AnalysisReport.BlockConfidence
        switch block {
        case .search: confidence = report.search
        case .detail: confidence = report.detail
        case .catalog: confidence = report.catalog
        case .chapter: confidence = report.chapter
        }
        return confidence == .green ? .passed : .notRun
    }

    // MARK: - Validation store integration

    private func refreshValidation() async {
        do {
            let snapshot = try await sourceStack.validationStore.load(ruleID: draft.id)
            var statuses: [SourceBlock: BlockTestStatus] = [:]
            for block in SourceBlock.allCases {
                if let record = snapshot?.tests[block] {
                    // Apply the fingerprint stale-check here so the UI
                    // reflects the same semantic as `statusEffective`.
                    let current = draft.blockFingerprint(block)
                    statuses[block] = current == record.inputFingerprint
                        ? record.status
                        : .notRun
                } else {
                    statuses[block] = .notRun
                }
            }
            blockStatuses = statuses
            // Delete is only meaningful for rules that already live in
            // editableStore: seeded bundle rules would just re-emerge on
            // the next refresh, and a freshly-analyzed-but-not-saved
            // draft isn't on disk yet so there's nothing to remove.
            let editable = try await sourceStack.editableStore.loadEditableSources()
            let editableHit = editable.contains { $0.id == draft.id }
            canDelete = editableHit
            isEditableRule = editableHit
            // Compute seeded-original membership from the bundled rule
            // list. Used by `effectiveStatus` to trust authored
            // capabilities for bundle rules regardless of whether an
            // editable copy also exists.
#if LINGYUE_INTERNAL
            let bundledIDs = Set(LingyueInternalSources.bundledRules().map(\.id))
            isSeededOriginal = bundledIDs.contains(draft.id)
#else
            isSeededOriginal = false
#endif
        } catch {
            saveError = String(describing: error)
        }
    }

    private func deleteDraft() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await sourceStack.editableStore.deleteSource(id: draft.id)
            try await sourceStack.validationStore.delete(ruleID: draft.id)
            try await sourceStack.preferenceStore.delete(ruleID: draft.id)
            await DiscoverySearchService.shared.invalidateRegistryCache()
            await sourceStack.pageDetector.invalidateCache()
            onComplete()
        } catch {
            saveError = String(describing: error)
        }
    }

    private func recordTestResult(_ block: SourceBlock, passed: Bool) async {
        let record = BlockTestRecord(
            status: passed ? .passed : .failed,
            lastRunAt: Date(),
            failureSummary: passed ? nil : "用户测试未通过",
            inputFingerprint: draft.blockFingerprint(block)
        )
        do {
            try await sourceStack.validationStore.recordTest(
                ruleID: draft.id,
                block: block,
                record: record
            )
            blockStatuses[block] = passed ? .passed : .failed
        } catch {
            saveError = String(describing: error)
        }
    }

    // MARK: - Save

    private func save(enable: Bool) async {
        isSaving = true
        defer { isSaving = false }
        do {
            var snapshot = draft
            // Capability derivation runs against the validation store
            // every save (PHASES.md §3.5.2). A passing test elsewhere
            // and a fresh edit here keep the rule's `capabilities`
            // honest — we never write a stale `supportsSearch = true`.
            // We keep `snapshot.search` even when the capability flag
            // stays false: the analyzer's best-effort step is still
            // the user's best chance at search working, and the
            // Discovery fan-out attempts any rule with a configured
            // step (capability flag remains the verified-for-badges
            // signal, not the gate on whether to *try*).
            snapshot.capabilities = try await derivedCapabilities(for: snapshot)
            try await sourceStack.editableStore.saveEditableSource(snapshot)
            // Persist analyzer soft-passes to the validation store so the
            // pills survive disable→enable cycles and app restarts. Without
            // this the Review screen's analyzer report (held only in
            // memory) is the lone source for detail/catalog/chapter
            // "passed", and the moment the user pops back the pills reset
            // to 需要检查. Only writes when nothing newer (manual test)
            // already passed for that block.
            let now = Date()
            for block in SourceBlock.allCases {
                let existing = blockStatuses[block] ?? .notRun
                if existing == .passed { continue }
                guard analyzerSoftStatus(for: block) == .passed else { continue }
                let record = BlockTestRecord(
                    status: .passed,
                    lastRunAt: now,
                    failureSummary: nil,
                    inputFingerprint: snapshot.blockFingerprint(block)
                )
                try await sourceStack.validationStore.recordTest(
                    ruleID: snapshot.id,
                    block: block,
                    record: record
                )
            }
            try await sourceStack.preferenceStore.save(
                SourcePreference(
                    ruleID: snapshot.id,
                    isEnabled: enable,
                    priority: Int.max
                )
            )
            await DiscoverySearchService.shared.invalidateRegistryCache()
            // Capability flips and per-source enable changes both alter
            // the detector's source set — drop its URL-keyed cache so
            // the in-app browser stops surfacing stale rule hits
            // (PHASES.md §4.6).
            await sourceStack.pageDetector.invalidateCache()
            onComplete()
        } catch {
            saveError = String(describing: error)
        }
    }

    private func derivedCapabilities(for rule: SourceRule) async throws -> SourceCapabilities {
        let store = sourceStack.validationStore
        // Analyzer-green counts as a soft pass here so `supportsSearch`
        // can flip on without the user being forced through a manual
        // Test for every analyze cycle. The same logic mirrors
        // `effectiveStatus` on the UI side — keep these in lock-step.
        func passed(_ block: SourceBlock, analyzer: AnalysisReport.BlockConfidence) async throws -> Bool {
            let status = try await store.statusEffective(block, rule: rule)
            if status == .passed { return true }
            if status == .failed { return false }
            return analyzer == .green
        }
        let searchPassed = try await passed(.search, analyzer: report.search)
        let detailPassed = try await passed(.detail, analyzer: report.detail)
        let catalogPassed = try await passed(.catalog, analyzer: report.catalog)
        let chapterPassed = try await passed(.chapter, analyzer: report.chapter)
        let browseReady = detailPassed && catalogPassed && chapterPassed

        return SourceCapabilities(
            supportsSearch: searchPassed && rule.search != nil,
            // Mirrors `supportsSearch` — the visible search capability
            // and the aggregator-visibility flag are one user-facing
            // concept now. PHASES.md §3.5.2 retires `showInSearchBar`
            // as an authored field entirely.
            showInSearchBar: searchPassed && rule.search != nil,
            supportsBrowserImport: browseReady && !rule.detection.hostPatterns.isEmpty,
            // Carried forward from the rule's prior value (today always
            // false for new drafts). Slice 8 wires this to the real P3
            // classifier; advanced-toggle override lives in §3.4.
            requiresWebRender: rule.capabilities.requiresWebRender
        )
    }

    /// Re-sync `draft` after the user pops back from the advanced
    /// editor. The editor saves through `editableStore` directly, so
    /// any field they touched is already on disk; this view's `draft`
    /// state was a snapshot taken before they navigated. Without this
    /// re-read the user's next Save would write Review's stale copy
    /// over the editor's fresh edits.
    private func reloadDraftFromStore() async {
        do {
            let editable = try await sourceStack.editableStore.loadEditableSources()
            if let refreshed = editable.first(where: { $0.id == draft.id }) {
                draft = refreshed
            }
        } catch {
            saveError = String(describing: error)
        }
    }

    private func defaultTestInput(for block: SourceBlock) -> String? {
        switch block {
        case .search: return analyzerInput?.testKeyword
        case .detail: return analyzerInput?.exampleBookURL?.absoluteString
        case .catalog:
            // Catalog test fires against the example book URL — same
            // input the detail block uses. The analyzer's same-page
            // catalog-URL field (rule.detail.catalogURLField with
            // `.useBaseURL`) will resolve back to this URL at execution,
            // so the user only types the example book once.
            return analyzerInput?.exampleBookURL?.absoluteString
        case .chapter:
            // P4 records the first chapter link it followed; surface
            // that as the chapter test default rather than asking the
            // user to dig it out of the book's TOC again.
            return report.firstChapterURL?.absoluteString
        }
    }
}

// MARK: - SourceBlock UI metadata

private extension SourceBlock {
    var label: String {
        switch self {
        case .search: return "搜索"
        case .detail: return "书籍详情"
        case .catalog: return "目录"
        case .chapter: return "章节"
        }
    }

    var testStep: SourceTestSheet.Step {
        switch self {
        case .search: return .search
        case .detail: return .detail
        case .catalog: return .catalog
        case .chapter: return .chapter
        }
    }

    var scrollAnchor: SourceEditorView.ScrollAnchor {
        switch self {
        case .search: return .search
        case .detail: return .detail
        case .catalog: return .catalog
        case .chapter: return .chapter
        }
    }
}
