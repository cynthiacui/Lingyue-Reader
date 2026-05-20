import SwiftUI
import LingyueCore

/// Phase 3.1 — interactive tester for a `SourceRule` the user is
/// authoring. The user picks a step, supplies a query or URL, and the
/// sheet runs that step through a live `RuleBasedBookSource` built from
/// the in-memory draft (no save required). Results render structured
/// so each field of the rule has its resolved value visible — which is
/// the whole point of the editor → tester loop.
///
/// Detection runs separately: the in-app browser path takes a
/// `WebPageSnapshot`, not a URL, so testing detection here means
/// fetching the URL via the loader and feeding the resulting snapshot
/// into `RuleBasedBookSource.detectBook`.
struct SourceTestSheet: View {
    enum Step: String, CaseIterable, Identifiable {
        case search, detail, catalog, chapter, detection
        var id: String { rawValue }
        var label: String {
            switch self {
            case .search: return "搜索"
            case .detail: return "详情"
            case .catalog: return "目录"
            case .chapter: return "章节"
            case .detection: return "检测"
            }
        }
    }

    @Environment(\.sourceStack) private var sourceStack
    @Environment(\.dismiss) private var dismiss

    let rule: SourceRule
    /// Fires when `run()` finishes with a *successful* outcome for the
    /// currently-selected step. The Review screen reads this to flip the
    /// block status to 已识别 without forcing the user to interpret raw
    /// results themselves. The closure is also invoked on failure (with
    /// `passed: false`) so callers can mark a block 测试失败.
    var onResult: ((Step, _ passed: Bool) -> Void)?

    @State private var step: Step
    @State private var input: String
    @State private var isRunning = false
    @State private var outcome: Outcome?

    init(
        rule: SourceRule,
        initialStep: Step? = nil,
        initialInput: String? = nil,
        onResult: ((Step, _ passed: Bool) -> Void)? = nil
    ) {
        self.rule = rule
        self.onResult = onResult
        self._step = State(initialValue: initialStep ?? .search)
        self._input = State(initialValue: initialInput ?? "")
    }

    var body: some View {
        Form {
            Section {
                Picker("步骤", selection: $step) {
                    ForEach(Step.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent(inputLabel) {
                    TextField(inputPrompt, text: $input)
                        .keyboardType(step == .search ? .default : .URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .multilineTextAlignment(.trailing)
                }

                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        if isRunning {
                            ProgressView().controlSize(.small)
                        }
                        Text(isRunning ? "运行中…" : "运行")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isRunning || input.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("测试直接走当前编辑器中的草稿（包含未保存改动），不会污染线上规则。")
            }

            if let outcome {
                resultsSection(outcome)
            }
        }
        .navigationTitle("测试 \(rule.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }

    // MARK: - Inputs

    private var inputLabel: String {
        switch step {
        case .search: return "查询词"
        case .detail: return "详情页 URL"
        case .catalog: return "目录页 URL"
        case .chapter: return "章节 URL"
        case .detection: return "任意页 URL"
        }
    }

    private var inputPrompt: String {
        switch step {
        case .search: return "如：诡秘之主"
        case .detail, .catalog, .chapter, .detection:
            return "https://…"
        }
    }

    // MARK: - Run

    private func run() async {
        isRunning = true
        outcome = nil
        // Route through the rule's own factory so jsonAPI rules reach
        // `JSONAPIBookSource`. The HTML scraper would hit the API
        // endpoint and parse JSON as HTML, which fails every block.
        let source = rule.makeBookSource(loader: sourceStack.loader)
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: Outcome
        do {
            switch step {
            case .search:
                let hits = try await source.search(trimmed)
                result = .search(hits)
            case .detail:
                guard let url = URL(string: trimmed) else {
                    result = .failure("无法解析 URL")
                    break
                }
                let detail = try await source.fetchDetail(url: url)
                result = .detail(detail)
            case .catalog:
                guard let url = URL(string: trimmed) else {
                    result = .failure("无法解析 URL")
                    break
                }
                let chapters = try await source.fetchCatalog(url: url)
                result = .catalog(chapters)
            case .chapter:
                guard let url = URL(string: trimmed) else {
                    result = .failure("无法解析 URL")
                    break
                }
                let content = try await source.fetchChapter(url: url)
                result = .chapter(content)
            case .detection:
                guard let url = URL(string: trimmed) else {
                    result = .failure("无法解析 URL")
                    break
                }
                let request = SourceRequest(
                    url: url,
                    headers: rule.defaultHeaders,
                    encoding: rule.encoding,
                    referer: rule.homepage
                )
                let snapshot: WebPageSnapshot
                if rule.enginePerStep.detail == .web {
                    snapshot = try await sourceStack.loader.renderHTML(request)
                } else {
                    snapshot = try await sourceStack.loader.fetchHTML(request)
                }
                let detection = try await source.detectBook(in: snapshot)
                result = .detection(detection, snapshot: snapshot)
            }
        } catch {
            result = .failure(String(describing: error))
        }
        outcome = result
        isRunning = false
        if let passed = Self.didPass(result) {
            onResult?(step, passed)
        }
    }

    /// "Did this outcome demonstrate the step actually works?" — used by
    /// the Review screen to flip per-block status. `nil` means
    /// inconclusive: don't write a verdict, leave whatever was there.
    /// Search with 0 hits is the canonical inconclusive case — the
    /// request succeeded so the selectors aren't obviously broken; the
    /// user may have simply typed a keyword the site doesn't index.
    /// Power users still see the raw "无结果" in the sheet.
    private static func didPass(_ outcome: Outcome) -> Bool? {
        switch outcome {
        case .search(let hits): return hits.isEmpty ? nil : true
        case .detail(let detail): return !detail.title.isEmpty
        case .catalog(let chapters): return !chapters.isEmpty
        case .chapter(let content): return !content.paragraphs.isEmpty
        case .detection(let detection, _): return detection != nil
        case .failure: return false
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func resultsSection(_ outcome: Outcome) -> some View {
        switch outcome {
        case .failure(let message):
            Section("错误") {
                Text(message)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        case .search(let hits):
            Section("搜索结果 (\(hits.count))") {
                if hits.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("无结果").foregroundStyle(.secondary)
                        Text("如果你确信搜索接口没问题,可能是该关键词在此站点没有匹配的书。请换一个该站点肯定收录的关键词(例如某本书的书名)再试。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(Array(hits.prefix(20).enumerated()), id: \.offset) { _, hit in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.title).font(.subheadline.weight(.medium))
                            if let author = hit.author {
                                Text("作者：\(author)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let snippet = hit.snippet {
                                Text(snippet).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text(hit.detailURL.absoluteString)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        case .detail(let detail):
            Section("书籍详情") {
                resultRow("标题", detail.title)
                if let a = detail.author { resultRow("作者", a) }
                if let d = detail.description { resultRow("简介", d) }
                if let s = detail.status { resultRow("状态", s) }
                if let s = detail.statistics { resultRow("统计", s) }
                if !detail.tags.isEmpty { resultRow("标签", detail.tags.joined(separator: " / ")) }
                if let cover = detail.coverURL { resultRow("封面", cover.absoluteString) }
                resultRow("目录 URL", detail.catalogURL.absoluteString)
            }
        case .catalog(let chapters):
            Section("目录 (\(chapters.count))") {
                if chapters.isEmpty {
                    Text("无章节").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(chapters.prefix(30).enumerated()), id: \.offset) { _, chapter in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chapter.title).font(.subheadline)
                            if let volume = chapter.volume {
                                Text("卷：\(volume)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(chapter.url.absoluteString)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                    if chapters.count > 30 {
                        Text("… 还有 \(chapters.count - 30) 章")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .chapter(let content):
            Section("章节") {
                resultRow("标题", content.title)
                resultRow("段落数", "\(content.paragraphs.count)")
                if let next = content.nextChapterURL { resultRow("下一章", next.absoluteString) }
                if let prev = content.previousChapterURL { resultRow("上一章", prev.absoluteString) }
            }
            if !content.paragraphs.isEmpty {
                Section("正文预览") {
                    ForEach(Array(content.paragraphs.prefix(10).enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    if content.paragraphs.count > 10 {
                        Text("… 还有 \(content.paragraphs.count - 10) 段")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .detection(let detection, let snapshot):
            Section("响应") {
                resultRow("最终 URL", snapshot.finalURL.absoluteString)
                if let status = snapshot.statusCode {
                    resultRow("HTTP", "\(status)")
                }
                resultRow("HTML 字节", "\(snapshot.html.utf8.count)")
            }
            Section("检测结果") {
                if let detection {
                    resultRow("置信度", String(format: "%.2f", detection.confidence))
                    resultRow("详情 URL", detection.detailURL.absoluteString)
                    if let title = detection.title { resultRow("标题", title) }
                    resultRow("来源 ID", detection.sourceID)
                } else {
                    Text("未识别为书籍页面").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func resultRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Outcome envelope

    enum Outcome {
        case search([BookSearchResult])
        case detail(BookDetail)
        case catalog([ChapterLink])
        case chapter(ChapterContent)
        case detection(BookDetection?, snapshot: WebPageSnapshot)
        case failure(String)
    }
}
