import SwiftUI
import LingyueCore
#if LINGYUE_INTERNAL
import LingyueInternalSources
#endif

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

    var body: some View {
        ZStack {
            ThemeBackgroundView()

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
                            Button {
                                selectedReviewEntry = entry
                            } label: {
                                ruleCard(entry)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            // Swipe-to-delete is gated on `.editable`
                            // origin: seeded rules ship inside the app
                            // bundle and would just be re-emitted on the
                            // next refresh, so deletion is meaningless
                            // for them. Users can still disable seeded
                            // rules via the toggle.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if entry.origin == .editable {
                                    // No `role: .destructive` here — the
                                    // List would treat the tap as a
                                    // committed delete and animate the
                                    // row out before our confirmation
                                    // alert resolves, causing the row to
                                    // flash out and back in if the user
                                    // cancels. `.tint(.red)` keeps the
                                    // destructive styling.
                                    Button {
                                        pendingDelete = entry
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .navigationTitle("书源")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAddingSource = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建书源")
            }
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
        // Sites without a search block can't seed the chain — there's no
        // URL to feed into detail. Skip; the user added the rule via
        // browser import and will exercise it that way.
        guard rule.search != nil else { return }
        let source = RuleBasedBookSource(rule: rule, loader: sourceStack.loader)
        let keyword = "一"

        guard let hits = try? await source.search(keyword), let firstHit = hits.first else {
            return
        }
        await persistVerification(rule: rule, block: .search, passed: true)

        guard let detail = try? await source.fetchDetail(url: firstHit.detailURL),
              !detail.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        await persistVerification(rule: rule, block: .detail, passed: true)

        guard let chapters = try? await source.fetchCatalog(url: detail.catalogURL),
              !chapters.isEmpty else {
            return
        }
        await persistVerification(rule: rule, block: .catalog, passed: true)

        // Many user-authored catalog rules use broad selectors (e.g.
        // `ul > li`) that scoop the site's top *and* bottom nav strips
        // alongside the real chapter rows — sampling first-N + last-N
        // still hits only nav junk on those sites. Real chapter URLs
        // cluster under one path directory (e.g. `/books/170611/…`)
        // while nav links scatter across `/`, `/list/`, etc. Filter to
        // the dominant directory before probing.
        let candidates = Self.likelyChapterLinks(chapters)
        let probes = Array(candidates.prefix(3)) + Array(candidates.suffix(3))
        var seen: Set<URL> = []
        for chapter in probes where seen.insert(chapter.url).inserted {
            if let content = try? await source.fetchChapter(url: chapter.url),
               !content.paragraphs.isEmpty {
                await persistVerification(rule: rule, block: .chapter, passed: true)
                return
            }
        }
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
#if LINGYUE_INTERNAL
        // Internal ships with seeded rules — an empty list here is
        // diagnostic, not first-launch.
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
        .sourcesListCard()
#else
        appStoreFirstLaunchCard
#endif
    }

#if !LINGYUE_INTERNAL
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
#endif

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
