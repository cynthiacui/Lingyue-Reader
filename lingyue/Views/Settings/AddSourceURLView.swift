import SwiftUI
import LingyueCore

/// Phase 3.2 — primary "Add Source" entry point. The user pastes a
/// homepage URL (required) plus optional example book URL and test
/// keyword; tapping 分析 runs `SourceAnalyzer.analyze` and pushes
/// `SourceReviewView` with the resulting draft + report.
///
/// This view is the humane front door defined in PHASES.md §3.2. The
/// raw schema editor (`SourceEditorView`) is reachable only as the
/// "advanced repair" disclosure from the Review screen — a novice user
/// should never have to look at `FieldSelector` or `SourceTransform`
/// to add a source.
///
/// Hosted in a sheet from `SourcesListView`. The `onComplete` closure
/// dismisses the sheet after a successful save. It does NOT fire on
/// cancel — SwiftUI's standard `.dismiss` from the toolbar handles
/// that path.
struct AddSourceURLView: View {
    @Environment(\.dismiss) private var dismiss

    let onComplete: () -> Void

    @State private var homepageInput: String = ""
    @State private var exampleBookInput: String = ""
    @State private var keywordInput: String = ""
    @State private var inputError: String?
    @State private var isAnalyzing = false
    @State private var pendingReview: AnalyzerResult?

    var body: some View {
        Form {
            urlSection
            optionalSection
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

    private var urlSection: some View {
        Section {
            TextField("https://example.com", text: $homepageInput)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("主页 URL")
        } footer: {
            Text("粘贴书源站点的首页地址。Lingyue 会从主页识别域名并推断站点结构。")
        }
    }

    private var optionalSection: some View {
        Section {
            TextField("书籍详情页 URL（可选）", text: $exampleBookInput)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("测试搜索词（可选）", text: $keywordInput)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("可选信息")
        } footer: {
            Text("提供任意一本书的详情页地址，可让分析更准确；测试搜索词用于验证搜索功能。")
        }
    }

    // MARK: - Actions

    private func analyze() async {
        inputError = nil
        guard let homepage = normalizedURL(homepageInput) else {
            inputError = "请输入有效的主页 URL（包含 http:// 或 https://）。"
            return
        }
        let exampleBookURL = exampleBookInput.isEmpty ? nil : normalizedURL(exampleBookInput)
        if !exampleBookInput.isEmpty && exampleBookURL == nil {
            inputError = "示例书籍 URL 格式不正确。"
            return
        }
        let keyword = keywordInput.trimmingCharacters(in: .whitespaces)
        let input = AnalyzerInput(
            homepage: homepage,
            exampleBookURL: exampleBookURL,
            testKeyword: keyword.isEmpty ? nil : keyword
        )

        isAnalyzing = true
        let (rule, report) = await SourceAnalyzer.analyze(input)
        isAnalyzing = false
        pendingReview = AnalyzerResult(rule: rule, report: report, analyzerInput: input)
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
