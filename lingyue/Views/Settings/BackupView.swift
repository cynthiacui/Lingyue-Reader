import SwiftUI
import UniformTypeIdentifiers
import LingyueCore

/// Phase 5.3 — Settings entry point for `.lingyue-backup` export +
/// import. Uses SwiftUI's first-party `.fileExporter` / `.fileImporter`
/// modifiers so the share/save surfaces come from `UIDocumentPicker`
/// without us having to bridge UIKit.
struct BackupView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.sourceStack) private var sourceStack
    @EnvironmentObject private var libraryStore: LibraryStore

    @State private var exportDocument: BackupJSONDocument?
    @State private var exportFilename: String = BackupService.suggestedFilename()
    @State private var isExporterPresented = false
    @State private var isImporterPresented = false
    @State private var pendingArchive: BackupArchive?
    @State private var isWorking = false
    @State private var status: BackupStatus?

    var body: some View {
        ZStack {
            ThemeBackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summarySection
                    actionsSection
                    notesSection
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .safeAreaPadding(.bottom, 12)

            if let status {
                CenterStatusToast(status: status)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("备份与恢复")
        .navigationBarTitleDisplayMode(.large)
        .animation(.easeInOut(duration: 0.22), value: status)
        .fileExporter(
            isPresented: $isExporterPresented,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success:
                presentStatus(.success("已导出备份"))
            case .failure(let error):
                presentStatus(.failure("导出失败：\(error.localizedDescription)"))
            }
            exportDocument = nil
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImporterResult(result)
        }
        .confirmationDialog(
            "确定要恢复备份吗？",
            isPresented: Binding(
                get: { pendingArchive != nil },
                set: { newValue in
                    if !newValue { pendingArchive = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingArchive
        ) { archive in
            Button("恢复（覆盖当前数据）", role: .destructive) {
                Task { await performRestore(archive) }
            }
            Button("取消", role: .cancel) {
                pendingArchive = nil
            }
        } message: { archive in
            Text(restoreSummary(for: archive))
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "备份内容")

            VStack(alignment: .leading, spacing: 10) {
                BackupSummaryRow(icon: "books.vertical", text: "书架与分类")
                BackupSummaryRow(icon: "chart.bar.xaxis", text: "阅读统计与日历记录")
                BackupSummaryRow(icon: "doc.text", text: "自定义书源（书源 JSON）")
                BackupSummaryRow(icon: "slider.horizontal.3", text: "书源启用与排序偏好")
                BackupSummaryRow(icon: "checkmark.seal", text: "书源测试记录")
            }
            .foregroundStyle(theme.primaryText)
            .readerCard()
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "操作")

            VStack(spacing: 12) {
                Button {
                    Task { await beginExport() }
                } label: {
                    Label("导出备份", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking)

                Button {
                    isImporterPresented = true
                } label: {
                    Label("导入备份", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isWorking)
            }
            .foregroundStyle(theme.primaryText)
            .readerCard()
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "说明")

            VStack(alignment: .leading, spacing: 8) {
                Text("• 备份文件为 JSON 格式，请妥善保存。")
                Text("• 导入备份会覆盖当前所有书架、书源与统计数据，无法撤销。")
                Text("• 备份不包含已下载的章节缓存。")
            }
            .font(.footnote)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .readerCard()
        }
    }

    private func beginExport() async {
        isWorking = true
        defer { isWorking = false }
        let service = BackupService(libraryStore: libraryStore, stack: sourceStack)
        do {
            let archive = try await service.makeArchive()
            let data = try service.encodeArchive(archive)
            exportDocument = BackupJSONDocument(data: data)
            exportFilename = BackupService.suggestedFilename(at: archive.createdAt)
            isExporterPresented = true
        } catch {
            presentStatus(.failure("生成备份失败：\(error.localizedDescription)"))
        }
    }

    private func handleImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await loadArchiveForConfirmation(at: url) }
        case .failure(let error):
            presentStatus(.failure("打开备份失败：\(error.localizedDescription)"))
        }
    }

    private func loadArchiveForConfirmation(at url: URL) async {
        // `.fileImporter` returns a security-scoped URL — must bracket
        // the read with start/stopAccessingSecurityScopedResource or
        // `Data(contentsOf:)` fails with -1100.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let service = BackupService(libraryStore: libraryStore, stack: sourceStack)
        do {
            let data = try Data(contentsOf: url)
            let archive = try service.decodeArchive(from: data)
            pendingArchive = archive
        } catch {
            presentStatus(.failure(error.localizedDescription))
        }
    }

    private func performRestore(_ archive: BackupArchive) async {
        pendingArchive = nil
        isWorking = true
        defer { isWorking = false }
        let service = BackupService(libraryStore: libraryStore, stack: sourceStack)
        do {
            try await service.restore(archive)
            presentStatus(.success("已恢复备份"))
        } catch {
            presentStatus(.failure("恢复失败：\(error.localizedDescription)"))
        }
    }

    private func restoreSummary(for archive: BackupArchive) -> String {
        let booksCount = archive.library.reduce(0) { $0 + $1.novels.count }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dateText = formatter.string(from: archive.createdAt)
        return "备份生成于 \(dateText)，包含 \(booksCount) 本书与 \(archive.editableSources.count) 个自定义书源。恢复后当前数据将被覆盖。"
    }

    private func presentStatus(_ next: BackupStatus) {
        status = next
        let captured = next
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if status == captured {
                status = nil
            }
        }
    }
}

private struct BackupSummaryRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
            Text(text)
            Spacer()
        }
        .font(.subheadline)
    }
}

private enum BackupStatus: Equatable {
    case success(String)
    case failure(String)

    var text: String {
        switch self {
        case .success(let s), .failure(let s): return s
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private struct CenterStatusToast: View {
    let status: BackupStatus

    var body: some View {
        Text(status.text)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(status.isSuccess
                          ? Color.black.opacity(0.78)
                          : Color.red.opacity(0.85))
            )
            .shadow(color: Color.black.opacity(0.25), radius: 14, x: 0, y: 6)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Plain Data-bearing `FileDocument` so SwiftUI's `.fileExporter`
/// modifier can hand off a freshly-encoded backup blob to UIDocumentPicker
/// without us having to bridge UIKit ourselves. JSON-typed because that's
/// what the file actually is — keeps Files.app preview honest.
struct BackupJSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    static let writableContentTypes: [UTType] = [.json]

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
