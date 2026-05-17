import SwiftUI
import LingyueCore

/// Phase 3.2 — primary "Add Source" entry point. The user pastes a
/// handful of URLs from their browser (homepage required; detail /
/// chapter / search-results pages optional but recommended) plus an
/// optional custom name and search keyword. Tapping 分析 runs
/// `SourceAnalyzer.analyze` and pushes `SourceReviewView` with the
/// resulting draft + report.
///
/// This view is the humane front door defined in PHASES.md §3.2. The
/// raw schema editor (`SourceEditorView`) is reachable only as the
/// "advanced repair" disclosure from the Review screen — a novice user
/// should never have to look at `FieldSelector` or `SourceTransform`
/// to add a source. Each example URL widens what the analyzer can
/// auto-fill (catalog selectors, chapter body, search template), so
/// the user only ever pastes URLs they already have in their browser.
///
/// Hosted in a sheet from `SourcesListView`. The `onComplete` closure
/// dismisses the sheet after a successful save. It does NOT fire on
/// cancel — SwiftUI's standard `.dismiss` from the toolbar handles
/// that path.
struct AddSourceURLView: View {
    @Environment(\.dismiss) private var dismiss

    let onComplete: () -> Void

    @State private var homepageInput: String = ""
    @State private var customNameInput: String = ""
    @State private var detailURLInput: String = ""
    @State private var chapterURLInput: String = ""
    @State private var searchURLInput: String = ""
    @State private var keywordInput: String = ""
    @State private var inputError: String?
    @State private var isAnalyzing = false
    @State private var pendingReview: AnalyzerResult?

    var body: some View {
        Form {
            requiredSection
            nameSection
            samplesSection
            if let inputError {
                Section {
                    Text(inputError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("添加书源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await analyze() }
                } label: {
                    if isAnalyzing {
                        ProgressView()
                    } else {
                        Text("分析")
                    }
                }
                .disabled(homepageInput.isEmpty || isAnalyzing)
            }
        }
        .navigationDestination(item: $pendingReview) { result in
            SourceReviewView(
                rule: result.rule,
                report: result.report,
                analyzerInput: result.analyzerInput,
                onComplete: onComplete
            )
        }
    }

    // MARK: - Sections

    private var requiredSection: some View {
        Section {
            TextField("https://example.com", text: $homepageInput)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("书源主页 URL")
        } footer: {
            Text("粘贴你想阅读的网站首页地址。")
        }
    }

    private var nameSection: some View {
        Section {
            TextField("自动从网站标题识别", text: $customNameInput)
                .autocorrectionDisabled()
        } header: {
            Text("书源名称（可选）")
        } footer: {
            Text("不填则使用网站的标题作为名称。")
        }
    }

    private var samplesSection: some View {
        Section {
            TextField("书籍详情页 URL", text: $detailURLInput)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("章节正文 URL", text: $chapterURLInput)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("搜索结果页 URL", text: $searchURLInput)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("搜索时使用的关键词", text: $keywordInput)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("示例 URL（建议提供）")
        } footer: {
            Text("贴上你在浏览器里实际访问过的页面 URL，灵阅会据此自动识别书源结构。提供得越多，自动配置越准确；搜索关键词请填写「搜索结果页 URL」里实际搜的那个词。")
        }
    }

    // MARK: - Actions

    private func analyze() async {
        inputError = nil
        guard let homepage = normalizedURL(homepageInput) else {
            inputError = "请输入有效的主页 URL（包含 http:// 或 https://）。"
            return
        }

        let detailURL = normalizedOptionalURL(detailURLInput, label: "书籍详情页")
        if case .failure(let msg) = detailURL { inputError = msg; return }
        let chapterURL = normalizedOptionalURL(chapterURLInput, label: "章节正文")
        if case .failure(let msg) = chapterURL { inputError = msg; return }
        let searchURL = normalizedOptionalURL(searchURLInput, label: "搜索结果页")
        if case .failure(let msg) = searchURL { inputError = msg; return }

        let keyword = keywordInput.trimmingCharacters(in: .whitespaces)
        let name = customNameInput.trimmingCharacters(in: .whitespaces)

        let input = AnalyzerInput(
            homepage: homepage,
            exampleBookURL: detailURL.value,
            chapterURL: chapterURL.value,
            searchResultURL: searchURL.value,
            testKeyword: keyword.isEmpty ? nil : keyword,
            customName: name.isEmpty ? nil : name
        )

        isAnalyzing = true
        let (rule, report) = await SourceAnalyzer.analyze(input)
        isAnalyzing = false
        pendingReview = AnalyzerResult(rule: rule, report: report, analyzerInput: input)
    }

    /// Result of parsing an optional URL field. `.empty` means the user
    /// left the box blank (carry through as `nil`); `.value` is a parsed
    /// URL; `.failure` short-circuits analyze() with a user-facing error.
    private enum OptionalURLResult {
        case empty
        case value(URL)
        case failure(String)

        var value: URL? {
            if case .value(let url) = self { return url }
            return nil
        }
    }

    private func normalizedOptionalURL(_ raw: String, label: String) -> OptionalURLResult {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        guard let url = normalizedURL(trimmed) else {
            return .failure("\(label) URL 格式不正确。")
        }
        return .value(url)
    }

    /// Accept input with or without a scheme; default to `https://` when
    /// missing so users can paste `example.com` and get a working URL.
    /// Rejects whitespace-only and obviously malformed strings.
    private func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let candidate: String = {
            if trimmed.contains("://") { return trimmed }
            return "https://" + trimmed
        }()
        guard let url = URL(string: candidate), url.host(percentEncoded: false) != nil else {
            return nil
        }
        return url
    }
}

/// Bundles the analyzer's outputs so SwiftUI's `navigationDestination(item:)`
/// has a single Hashable carrier to detect "user tapped 分析" transitions.
/// Carries the original `AnalyzerInput` forward so the Review screen can
/// pre-fill per-block test inputs (search → keyword, detail → example
/// book URL) without forcing the user to re-type them.
struct AnalyzerResult: Identifiable, Hashable {
    let id = UUID()
    let rule: SourceRule
    let report: AnalysisReport
    let analyzerInput: AnalyzerInput

    static func == (lhs: AnalyzerResult, rhs: AnalyzerResult) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
