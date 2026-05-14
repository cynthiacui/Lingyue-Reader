import SwiftUI
import LingyueCore

/// Phase 3.1 — form-driven editor over the full `SourceRule` schema.
///
/// Every field is bound directly to the `draft` rule. Saving writes
/// through `\.sourceStack.editableStore`, which means editing a seeded
/// rule writes a same-UUID copy into the editable store; the registry's
/// dedup-by-id then suppresses the bundled original so the user's
/// version wins. That is the intended "fork on first edit" behavior —
/// users never mutate the seeded bundle in place.
///
/// Closed enums (`SourceEncoding`, `SearchStep.Method`, `EnginePerStep.Engine`,
/// and every `SourceTransform` case) are exposed via Picker / Menu only.
/// There is no free-text path that lets a user type executable code into
/// a rule — that constraint is what makes user-authored rules safe for
/// App Store review.
struct SourceEditorView: View {
    enum Origin: Hashable { case seeded, editable }

    @Environment(\.sourceStack) private var sourceStack
    @Environment(\.dismiss) private var dismiss

    let origin: Origin
    /// Original rule snapshot. Used to detect "no changes" and to drive
    /// the "revert to bundled" affordance on editable forks of seeded rules.
    let original: SourceRule

    @State private var draft: SourceRule
    @State private var loadError: String?
    @State private var showingTestSheet = false
    @State private var pendingDelete = false

    init(rule: SourceRule, origin: Origin) {
        self.origin = origin
        self.original = rule
        self._draft = State(initialValue: rule)
    }

    var body: some View {
        Form {
            identitySection
            capabilitiesSection
            engineSection
            headersSection
            detectionSection
            if draft.capabilities.supportsSearch {
                searchSection
            }
            detailSection
            catalogSection
            chapterSection
            if origin == .editable {
                dangerSection
            }
            if let loadError {
                Section {
                    Text(loadError)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(draft.name.isEmpty ? "编辑书源" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await save() } }
                    .disabled(!hasChanges)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingTestSheet = true
                } label: {
                    Image(systemName: "play.circle")
                }
                .accessibilityLabel("测试")
            }
        }
        .sheet(isPresented: $showingTestSheet) {
            NavigationStack {
                SourceTestSheet(rule: draft)
            }
        }
        .alert("删除该书源？", isPresented: $pendingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await delete() } }
        } message: {
            Text("书源 “\(draft.name)” 会从「我的书源」中移除。若该书源同时存在内置版本，内置版会重新生效。")
        }
        .onChange(of: draft.capabilities.supportsSearch) { _, newValue in
            // Auto-materialize a blank SearchStep so the section has
            // something to bind to. Re-disabling the toggle preserves
            // whatever the user typed; we only clear on save when the
            // capability is off, so toggling back on doesn't blank work.
            if newValue && draft.search == nil {
                draft.search = SourceEditorView.makeBlankSearchStep()
            }
        }
    }

    private var hasChanges: Bool { draft != original }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            LabeledTextField(label: "名称", text: $draft.name, prompt: "用户看到的名字")
            LabeledTextField(
                label: "主页",
                text: Binding(
                    get: { draft.homepage.absoluteString },
                    set: { newValue in
                        if let url = URL(string: newValue) { draft.homepage = url }
                    }
                ),
                prompt: "https://example.com",
                keyboard: .URL
            )
            Picker("编码", selection: $draft.encoding) {
                ForEach(SourceEncoding.allCases, id: \.self) { encoding in
                    Text(encodingLabel(encoding)).tag(encoding)
                }
            }
        } header: {
            Text("基础信息")
        } footer: {
            Text("主页的 host 用作每站点的请求节流键；编码用于解码响应字节，遇到 GB18030 / GBK 站点请显式选择。")
        }
    }

    private var capabilitiesSection: some View {
        Section {
            Toggle("支持搜索", isOn: $draft.capabilities.supportsSearch)
            Toggle("出现在搜索栏聚合中", isOn: $draft.capabilities.showInSearchBar)
                .disabled(!draft.capabilities.supportsSearch)
            Toggle("支持浏览器导入", isOn: $draft.capabilities.supportsBrowserImport)
            Toggle("需要无头渲染", isOn: $draft.capabilities.requiresWebRender)
            Stepper(
                "最大并发：\(draft.capabilities.maxConcurrentRequests)",
                value: $draft.capabilities.maxConcurrentRequests,
                in: 1...8
            )
            Stepper(
                "请求间隔：\(draft.capabilities.requestIntervalMillis) ms",
                value: $draft.capabilities.requestIntervalMillis,
                in: 0...10_000,
                step: 100
            )
        } header: {
            Text("能力")
        } footer: {
            Text("能力字段是声明性的：如启用「支持搜索」却没有搜索步骤，规则在首次使用时会被拒绝。")
        }
    }

    private var engineSection: some View {
        Section {
            enginePicker("搜索", selection: $draft.enginePerStep.search)
            enginePicker("详情", selection: $draft.enginePerStep.detail)
            enginePicker("目录", selection: $draft.enginePerStep.catalog)
            enginePicker("正文", selection: $draft.enginePerStep.chapter)
        } header: {
            Text("引擎选择")
        } footer: {
            Text("默认 HTTP；若步骤的页面需要执行 JS 才能拿到 DOM，请选择「无头渲染」。渲染开销远大于 HTTP，请按需开启。")
        }
    }

    private var headersSection: some View {
        Section {
            HeaderDictionaryEditor(headers: $draft.defaultHeaders)
        } header: {
            Text("默认请求头")
        } footer: {
            Text("会叠加在加载器的默认请求头上。常见用法：覆盖 User-Agent、Accept-Language。")
        }
    }

    private var detectionSection: some View {
        Section {
            StringListEditor(
                values: $draft.detection.hostPatterns,
                addLabel: "添加 host pattern",
                placeholder: "*.example.com 或 example.com"
            )
            LabeledOptionalTextField(
                label: "路径正则",
                value: $draft.detection.pathPattern,
                prompt: "例如 ^/book/\\d+/?$"
            )
            LabeledOptionalTextField(
                label: "确认选择器",
                value: $draft.detection.confirmSelector,
                prompt: "区分详情页与搜索结果页"
            )
            OptionalFieldSelectorEditor(
                title: "规范 URL",
                hint: "将带跟踪参数的 URL 重写为干净形式；省略则使用响应最终 URL。",
                value: $draft.detection.canonicalURL
            )
        } header: {
            Text("检测")
        } footer: {
            Text("即使没有搜索步骤，检测仍是必填——它让应用内浏览器在用户访问书页时能识别归属。")
        }
    }

    private var searchSection: some View {
        Section {
            if let searchBinding = bindSearch() {
                Picker("方法", selection: searchBinding.method) {
                    Text("GET").tag(SearchStep.Method.get)
                    Text("POST").tag(SearchStep.Method.post)
                }
                LabeledTextField(
                    label: "URL 模板",
                    text: searchBinding.urlTemplate,
                    prompt: "https://example.com/s?q={query}"
                )
                if searchBinding.method.wrappedValue == .post {
                    LabeledOptionalTextField(
                        label: "Body 模板",
                        value: searchBinding.bodyTemplate,
                        prompt: "keyword={query}&submit=1"
                    )
                }
                Picker(
                    "查询编码",
                    selection: Binding(
                        get: { searchBinding.queryEncoding.wrappedValue ?? .utf8 },
                        set: { searchBinding.queryEncoding.wrappedValue = $0 }
                    )
                ) {
                    ForEach(SourceEncoding.allCases, id: \.self) { e in
                        if e != .auto { Text(encodingLabel(e)).tag(e) }
                    }
                }
                LabeledTextField(
                    label: "结果选择器",
                    text: searchBinding.resultsSelector,
                    prompt: "如 .result-item"
                )
                FieldSelectorEditor(title: "标题字段", value: searchBinding.titleField)
                FieldSelectorEditor(title: "详情链接字段", value: searchBinding.detailURLField)
                OptionalFieldSelectorEditor(title: "作者字段", value: searchBinding.authorField)
                OptionalFieldSelectorEditor(title: "封面字段", value: searchBinding.coverField)
                OptionalFieldSelectorEditor(title: "简介字段", value: searchBinding.snippetField)
            }
        } header: {
            Text("搜索")
        } footer: {
            Text("URL / Body 中的 {query} 会按「查询编码」对用户搜索词作 percent-encoding 后替换；GB18030 / GBK 站点常需要 utf8 之外的编码。")
        }
    }

    private var detailSection: some View {
        Section {
            FieldSelectorEditor(title: "标题字段", value: $draft.detail.titleField)
            OptionalFieldSelectorEditor(title: "作者字段", value: $draft.detail.authorField)
            OptionalFieldSelectorEditor(title: "封面字段", value: $draft.detail.coverField)
            OptionalFieldSelectorEditor(title: "简介字段", value: $draft.detail.descriptionField)
            OptionalFieldSelectorEditor(title: "状态字段", value: $draft.detail.statusField)
            OptionalFieldSelectorEditor(title: "统计字段", value: $draft.detail.statisticsField)
            OptionalFieldSelectorEditor(title: "标签列表字段", value: $draft.detail.tagsField)
            FieldSelectorEditor(title: "目录 URL 字段", value: $draft.detail.catalogURLField)
        } header: {
            Text("书籍详情")
        } footer: {
            Text("目录 URL 字段是必填；某些站点目录嵌在详情页，这种情况将其设为指回详情页自身的选择器。")
        }
    }

    private var catalogSection: some View {
        Section {
            LabeledTextField(
                label: "章节行选择器",
                text: $draft.catalog.chaptersSelector,
                prompt: "如 .catalog li"
            )
            FieldSelectorEditor(title: "章节标题字段", value: $draft.catalog.titleField)
            FieldSelectorEditor(title: "章节 URL 字段", value: $draft.catalog.urlField)
            OptionalFieldSelectorEditor(title: "卷标题字段", value: $draft.catalog.volumeField)
            OptionalFieldSelectorEditor(title: "下一页字段", value: $draft.catalog.nextPageField)
            Stepper(
                "最大翻页：\(draft.catalog.maxPages)",
                value: $draft.catalog.maxPages,
                in: 1...1000,
                step: 10
            )
        } header: {
            Text("目录")
        } footer: {
            Text("卷标题字段允许选择器命中分组的 DOM 元素；引擎会把最近一次卷名向后沿用。")
        }
    }

    private var chapterSection: some View {
        Section {
            FieldSelectorEditor(title: "标题字段", value: $draft.chapter.titleField)
            FieldSelectorEditor(title: "正文字段", value: $draft.chapter.bodyField)
            OptionalFieldSelectorEditor(title: "下一章字段", value: $draft.chapter.nextChapterField)
            OptionalFieldSelectorEditor(title: "上一章字段", value: $draft.chapter.previousChapterField)
            OptionalFieldSelectorEditor(title: "正文翻页字段", value: $draft.chapter.nextBodyPageField)
            Stepper(
                "最大正文翻页：\(draft.chapter.maxBodyPages)",
                value: $draft.chapter.maxBodyPages,
                in: 1...100
            )
        } header: {
            Text("章节")
        } footer: {
            Text("正文常用 .brToNewline + .stripHTML + .collapseWhitespace 这套变换；可在每个字段的「变换」中按顺序追加。")
        }
    }

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                pendingDelete = true
            } label: {
                Label("删除自定义书源", systemImage: "trash")
            }
        }
    }

    // MARK: - Save / delete

    private func save() async {
        do {
            // When the capability is off, drop the search step on save so
            // it doesn't pollute exported JSON. Editor keeps the value
            // around in memory until then so toggling on/off mid-edit
            // doesn't lose work.
            var snapshot = draft
            if !snapshot.capabilities.supportsSearch {
                snapshot.search = nil
            }
            try await sourceStack.editableStore.saveEditableSource(snapshot)
            await DiscoverySearchService.shared.invalidateRegistryCache()
            dismiss()
        } catch {
            loadError = String(describing: error)
        }
    }

    private func delete() async {
        do {
            try await sourceStack.editableStore.deleteSource(id: draft.id)
            await DiscoverySearchService.shared.invalidateRegistryCache()
            dismiss()
        } catch {
            loadError = String(describing: error)
        }
    }

    // MARK: - Helpers

    private func enginePicker(_ label: String, selection: Binding<EnginePerStep.Engine>) -> some View {
        Picker(label, selection: selection) {
            Text("HTTP").tag(EnginePerStep.Engine.http)
            Text("无头渲染").tag(EnginePerStep.Engine.web)
        }
    }

    private func encodingLabel(_ encoding: SourceEncoding) -> String {
        switch encoding {
        case .auto: return "自动"
        case .utf8: return "UTF-8"
        case .gb18030: return "GB18030"
        case .gbk: return "GBK"
        case .big5: return "Big5"
        }
    }

    /// SwiftUI bindings into an optional `SearchStep`. Returns nil when
    /// the step is absent — callers gate the section behind it.
    private func bindSearch() -> SearchStepBinding? {
        guard draft.search != nil else { return nil }
        return SearchStepBinding(
            method: Binding(
                get: { draft.search?.method ?? .get },
                set: { draft.search?.method = $0 }
            ),
            urlTemplate: Binding(
                get: { draft.search?.urlTemplate ?? "" },
                set: { draft.search?.urlTemplate = $0 }
            ),
            bodyTemplate: Binding(
                get: { draft.search?.bodyTemplate },
                set: { draft.search?.bodyTemplate = $0 }
            ),
            queryEncoding: Binding(
                get: { draft.search?.queryEncoding },
                set: { draft.search?.queryEncoding = $0 }
            ),
            resultsSelector: Binding(
                get: { draft.search?.resultsSelector ?? "" },
                set: { draft.search?.resultsSelector = $0 }
            ),
            titleField: Binding(
                get: { draft.search?.titleField ?? FieldSelector() },
                set: { draft.search?.titleField = $0 }
            ),
            detailURLField: Binding(
                get: { draft.search?.detailURLField ?? FieldSelector() },
                set: { draft.search?.detailURLField = $0 }
            ),
            authorField: Binding(
                get: { draft.search?.authorField },
                set: { draft.search?.authorField = $0 }
            ),
            coverField: Binding(
                get: { draft.search?.coverField },
                set: { draft.search?.coverField = $0 }
            ),
            snippetField: Binding(
                get: { draft.search?.snippetField },
                set: { draft.search?.snippetField = $0 }
            )
        )
    }

    static func makeBlankSearchStep() -> SearchStep {
        SearchStep(
            method: .get,
            urlTemplate: "",
            resultsSelector: "",
            titleField: FieldSelector(),
            detailURLField: FieldSelector()
        )
    }
}

// MARK: - Search binding bundle

private struct SearchStepBinding {
    let method: Binding<SearchStep.Method>
    let urlTemplate: Binding<String>
    let bodyTemplate: Binding<String?>
    let queryEncoding: Binding<SourceEncoding?>
    let resultsSelector: Binding<String>
    let titleField: Binding<FieldSelector>
    let detailURLField: Binding<FieldSelector>
    let authorField: Binding<FieldSelector?>
    let coverField: Binding<FieldSelector?>
    let snippetField: Binding<FieldSelector?>
}

// MARK: - Generic form rows

private struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }
}

private struct LabeledOptionalTextField: View {
    let label: String
    @Binding var value: String?
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(
                prompt,
                text: Binding(
                    get: { value ?? "" },
                    set: { value = $0.isEmpty ? nil : $0 }
                )
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        }
    }
}

private struct StringListEditor: View {
    @Binding var values: [String]
    let addLabel: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(values.indices, id: \.self) { idx in
                HStack {
                    TextField(
                        placeholder,
                        text: Binding(
                            get: { values[idx] },
                            set: { values[idx] = $0 }
                        )
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    Spacer()
                    Button(role: .destructive) {
                        values.remove(at: idx)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                values.append("")
            } label: {
                Label(addLabel, systemImage: "plus.circle")
                    .font(.footnote)
            }
        }
    }
}

private struct HeaderDictionaryEditor: View {
    @Binding var headers: [String: String]

    /// Backing array form keeps the row order stable while the user types
    /// — driving the form directly off a `[String: String]` would shuffle
    /// the rows on every keystroke. We sync back to the dict whenever the
    /// pairs change.
    @State private var pairs: [HeaderPair] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pairs.indices, id: \.self) { idx in
                HStack {
                    TextField("Header", text: Binding(
                        get: { pairs[idx].key },
                        set: { pairs[idx].key = $0; sync() }
                    ))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: 140)
                    TextField("Value", text: Binding(
                        get: { pairs[idx].value },
                        set: { pairs[idx].value = $0; sync() }
                    ))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    Button(role: .destructive) {
                        pairs.remove(at: idx)
                        sync()
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                pairs.append(HeaderPair(key: "", value: ""))
            } label: {
                Label("添加请求头", systemImage: "plus.circle").font(.footnote)
            }
        }
        .onAppear { hydrate() }
    }

    private func hydrate() {
        pairs = headers.sorted { $0.key < $1.key }.map { HeaderPair(key: $0.key, value: $0.value) }
    }

    private func sync() {
        var next: [String: String] = [:]
        for pair in pairs where !pair.key.isEmpty {
            next[pair.key] = pair.value
        }
        headers = next
    }

    private struct HeaderPair: Hashable {
        var key: String
        var value: String
    }
}

// MARK: - FieldSelector editing

private struct FieldSelectorEditor: View {
    let title: String
    @Binding var value: FieldSelector

    var body: some View {
        DisclosureGroup {
            FieldSelectorBody(value: $value)
        } label: {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                if let selector = value.selector, !selector.isEmpty {
                    Text(selector)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("(整页)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct OptionalFieldSelectorEditor: View {
    let title: String
    var hint: String? = nil
    @Binding var value: FieldSelector?

    var body: some View {
        if let _ = value {
            DisclosureGroup {
                FieldSelectorBody(
                    value: Binding(
                        get: { value ?? FieldSelector() },
                        set: { value = $0 }
                    )
                )
                Button(role: .destructive) {
                    value = nil
                } label: {
                    Label("移除该字段", systemImage: "minus.circle")
                        .font(.footnote)
                }
            } label: {
                HStack {
                    Text(title).font(.subheadline)
                    Spacer()
                    if let selector = value?.selector, !selector.isEmpty {
                        Text(selector).font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    value = FieldSelector()
                } label: {
                    Label("添加 \(title)", systemImage: "plus.circle")
                        .font(.subheadline)
                }
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct FieldSelectorBody: View {
    @Binding var value: FieldSelector

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledTextField(
                label: "选择器",
                text: Binding(
                    get: { value.selector ?? "" },
                    set: { value.selector = $0.isEmpty ? nil : $0 }
                ),
                prompt: "如 .book-title 或留空对整页操作"
            )
            LabeledTextField(
                label: "属性",
                text: Binding(
                    get: { value.attribute ?? "" },
                    set: { value.attribute = $0.isEmpty ? nil : $0 }
                ),
                prompt: "默认取 text；常用 href / src / html"
            )
            TransformEditor(transforms: $value.transforms)
        }
    }
}

private struct TransformEditor: View {
    @Binding var transforms: [SourceTransform]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("变换链").font(.caption).foregroundStyle(.secondary)
            ForEach(transforms.indices, id: \.self) { idx in
                TransformRow(
                    transform: Binding(
                        get: { transforms[idx] },
                        set: { transforms[idx] = $0 }
                    ),
                    onDelete: { transforms.remove(at: idx) }
                )
            }
            Menu {
                ForEach(TransformCatalog.all, id: \.self) { kind in
                    Button(kind.label) { transforms.append(kind.makeBlank()) }
                }
            } label: {
                Label("添加变换", systemImage: "plus.circle").font(.footnote)
            }
        }
    }
}

private struct TransformRow: View {
    @Binding var transform: SourceTransform
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(TransformCatalog.label(for: transform))
                    .font(.subheadline)
                inlineEditor
            }
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var inlineEditor: some View {
        switch transform {
        case .prefix(let s):
            TextField("前缀", text: Binding(
                get: { s },
                set: { transform = .prefix($0) }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        case .suffix(let s):
            TextField("后缀", text: Binding(
                get: { s },
                set: { transform = .suffix($0) }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        case .regexCapture(let p):
            TextField("正则", text: Binding(
                get: { p },
                set: { transform = .regexCapture(pattern: $0) }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        case .regexReplace(let p, let r):
            TextField("正则", text: Binding(
                get: { p },
                set: { transform = .regexReplace(pattern: $0, replacement: r) }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            TextField("替换", text: Binding(
                get: { r },
                set: { transform = .regexReplace(pattern: p, replacement: $0) }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        default:
            EmptyView()
        }
    }
}

/// Closed catalog of `SourceTransform` cases for the Menu. The enum's
/// associated values can't be enumerated by reflection, so we keep this
/// table in sync with the cases by hand. New transform = one line here.
private enum TransformCatalog {
    static let all: [Kind] = [
        .trim, .collapseWhitespace, .absoluteURL,
        .stripHTML, .brToNewline, .decodeHTMLEntities,
        .prefix, .suffix, .regexCapture, .regexReplace
    ]

    enum Kind: Hashable {
        case trim, collapseWhitespace, absoluteURL
        case stripHTML, brToNewline, decodeHTMLEntities
        case prefix, suffix, regexCapture, regexReplace

        var label: String {
            switch self {
            case .trim: return "trim"
            case .collapseWhitespace: return "collapseWhitespace"
            case .absoluteURL: return "absoluteURL"
            case .stripHTML: return "stripHTML"
            case .brToNewline: return "brToNewline"
            case .decodeHTMLEntities: return "decodeHTMLEntities"
            case .prefix: return "prefix(…)"
            case .suffix: return "suffix(…)"
            case .regexCapture: return "regexCapture(…)"
            case .regexReplace: return "regexReplace(…)"
            }
        }

        func makeBlank() -> SourceTransform {
            switch self {
            case .trim: return .trim
            case .collapseWhitespace: return .collapseWhitespace
            case .absoluteURL: return .absoluteURL
            case .stripHTML: return .stripHTML
            case .brToNewline: return .brToNewline
            case .decodeHTMLEntities: return .decodeHTMLEntities
            case .prefix: return .prefix("")
            case .suffix: return .suffix("")
            case .regexCapture: return .regexCapture(pattern: "")
            case .regexReplace: return .regexReplace(pattern: "", replacement: "")
            }
        }
    }

    static func label(for transform: SourceTransform) -> String {
        switch transform {
        case .trim: return "trim"
        case .collapseWhitespace: return "collapseWhitespace"
        case .absoluteURL: return "absoluteURL"
        case .stripHTML: return "stripHTML"
        case .brToNewline: return "brToNewline"
        case .decodeHTMLEntities: return "decodeHTMLEntities"
        case .prefix: return "prefix"
        case .suffix: return "suffix"
        case .regexCapture: return "regexCapture"
        case .regexReplace: return "regexReplace"
        }
    }
}
