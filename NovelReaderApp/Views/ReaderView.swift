import SwiftUI
import Foundation
import UIKit

struct ReaderView: View {
    let novel: Novel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("reader.fontSize") private var fontSize = 18.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.theme") private var themeRawValue = ReadingTheme.paper.rawValue
    @AppStorage("reader.usesTraditionalChinese") private var usesTraditionalChinese = false

    @State private var currentPageIndex = 0
    @State private var showControls = false
    @State private var showChapterPicker = false
    @State private var didSetInitialPage = false

    private var chapters: [NovelChapter] {
        MockData.chapters(for: novel)
    }

    private var horizontalMargin: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 16 }
        return horizontalSizeClass == .compact ? 18 : 36
    }

    private var currentTheme: ReadingTheme {
        ReadingTheme(rawValue: themeRawValue) ?? .paper
    }

    private var pageBackground: Color {
        switch currentTheme {
        case .paper:
            return Color.readerBackground
        case .warm:
            return Color(red: 0.98, green: 0.92, blue: 0.82)
        case .night:
            return Color(red: 0.08, green: 0.08, blue: 0.075)
        }
    }

    private var pageForeground: Color {
        currentTheme == .night ? Color(red: 0.88, green: 0.85, blue: 0.78) : .readerInk
    }

    private var secondaryForeground: Color {
        currentTheme == .night ? Color(red: 0.66, green: 0.63, blue: 0.56) : .readerMuted
    }

    var body: some View {
        GeometryReader { proxy in
            let textSize = readerTextSize(containerSize: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
            let pages = readerPages(textSize: textSize)
            let currentPage = currentPage(in: pages)

            ZStack {
                pageBackground.ignoresSafeArea()

                TabView(selection: $currentPageIndex) {
                    ForEach(pages.indices, id: \.self) { index in
                        pageView(for: pages[index], safeAreaInsets: proxy.safeAreaInsets, textSize: textSize)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()

                pageTapZones(pages: pages)

                if showControls {
                    controlsTopBar(safeTop: proxy.safeAreaInsets.top, currentPage: currentPage)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if !showControls {
                    readerHeader(safeTop: proxy.safeAreaInsets.top)
                        .transition(.opacity)
                }

                if showChapterPicker {
                    chapterPickerOverlay(pages: pages, currentPage: currentPage)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .onAppear {
                setInitialPageIfNeeded(pages: pages)
            }
            .onChange(of: pages.count) {
                clampCurrentPage(to: pages)
            }
        }
        .ignoresSafeArea()
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showControls)
    }

    private func headerTopPadding(safeTop: CGFloat) -> CGFloat {
        max(safeTop - 24, 26)
    }

    private func contentTopPadding(safeAreaInsets: EdgeInsets) -> CGFloat {
        let gapBelowHeader: CGFloat = dynamicTypeSize.isAccessibilitySize ? 40 : 20
        let minimum: CGFloat = dynamicTypeSize.isAccessibilitySize ? 82 : 68
        return max(safeAreaInsets.top + gapBelowHeader, minimum)
    }

    private func contentBottomPadding(safeAreaInsets: EdgeInsets) -> CGFloat {
        let minimum: CGFloat = dynamicTypeSize.isAccessibilitySize ? 72 : 56
        return max(safeAreaInsets.bottom + 24, minimum)
    }

    private func controlsTopPadding(safeTop: CGFloat) -> CGFloat {
        max(safeTop + 8, 52)
    }

    private func pageView(for page: ReaderPageItem, safeAreaInsets: EdgeInsets, textSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            JustifiedReaderText(
                text: page.content,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                color: UIColor(pageForeground)
            )
            .frame(width: textSize.width, height: textSize.height, alignment: .topLeading)

            HStack {
                Text(page.chapterTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer()

                Text("\(page.pageIndex + 1) / \(page.chapterPageCount)")
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(secondaryForeground)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, horizontalMargin)
        .padding(.top, contentTopPadding(safeAreaInsets: safeAreaInsets))
        .padding(.bottom, contentBottomPadding(safeAreaInsets: safeAreaInsets))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pageTapZones(pages: [ReaderPageItem]) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: proxy.size.width * 0.32)
                    .onTapGesture {
                        goToPreviousPage(pages: pages)
                    }

                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: proxy.size.width * 0.36)
                    .onTapGesture {
                        toggleControls()
                    }

                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: proxy.size.width * 0.32)
                    .onTapGesture {
                        goToNextPage(pages: pages)
                    }
            }
        }
        .ignoresSafeArea()
    }

    private func readerHeader(safeTop: CGFloat) -> some View {
        VStack {
            HStack(alignment: .center, spacing: 14) {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    Text(timeString(from: timeline.date))
                        .monospacedDigit()
                }
                .frame(alignment: .leading)

                Spacer()

                Text(displayed(novel.title))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(alignment: .trailing)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(secondaryForeground)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalMargin)
            .padding(.top, headerTopPadding(safeTop: safeTop))

            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func controlsTopBar(safeTop: CGFloat, currentPage: ReaderPageItem) -> some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(currentPage.chapterTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(secondaryForeground)
                    .lineLimit(1)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showChapterPicker = true
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(pageForeground)
            .padding(.horizontal, 18)
            .padding(.top, controlsTopPadding(safeTop: safeTop))
            .padding(.bottom, 14)
            .background(
                Rectangle()
                    .fill(currentTheme == .night ? Color(red: 0.12, green: 0.12, blue: 0.11) : pageBackground)
                    .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 3)
            )

            Spacer()
        }
        .ignoresSafeArea(edges: .top)
    }

    private func chapterPickerOverlay(pages: [ReaderPageItem], currentPage: ReaderPageItem) -> some View {
        ZStack {
            Color.black.opacity(currentTheme == .night ? 0.45 : 0.22)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("章节目录")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(pageForeground)

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showChapterPicker = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(secondaryForeground)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(chapters.indices, id: \.self) { index in
                                Button {
                                    currentPageIndex = firstPageIndex(forChapterAt: index, in: pages)
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        showChapterPicker = false
                                        showControls = false
                                    }
                                } label: {
                                    HStack {
                                        Text(displayed(chapters[index].title))
                                            .font(.system(size: 15, weight: currentPage.chapterIndex == index ? .bold : .regular))
                                            .lineLimit(1)

                                        Spacer()

                                        if currentPage.chapterIndex == index {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .bold))
                                        }
                                    }
                                    .foregroundStyle(currentPage.chapterIndex == index ? Color.readerAccent : pageForeground)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(currentPage.chapterIndex == index ? Color.readerAccent.opacity(0.12) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(currentPage.chapterIndex, anchor: .center)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 330, maxHeight: 430, alignment: .topLeading)
            .background(currentTheme == .night ? Color(red: 0.13, green: 0.13, blue: 0.12) : Color.readerSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
            .padding(.horizontal, 28)
        }
    }

    private func currentPage(in pages: [ReaderPageItem]) -> ReaderPageItem {
        guard !pages.isEmpty else {
            return ReaderPageItem(
                chapterIndex: 0,
                pageIndex: 0,
                chapterPageCount: 1,
                chapterTitle: novel.title,
                content: ""
            )
        }

        return pages[min(currentPageIndex, pages.count - 1)]
    }

    private func firstPageIndex(forChapterAt chapterIndex: Int, in pages: [ReaderPageItem]) -> Int {
        pages.firstIndex { $0.chapterIndex == chapterIndex } ?? 0
    }

    private func setInitialPageIfNeeded(pages: [ReaderPageItem]) {
        guard !didSetInitialPage, !pages.isEmpty else { return }
        currentPageIndex = min(max(Int(Double(pages.count) * novel.progress), 0), pages.count - 1)
        didSetInitialPage = true
    }

    private func clampCurrentPage(to pages: [ReaderPageItem]) {
        guard !pages.isEmpty else {
            currentPageIndex = 0
            return
        }

        currentPageIndex = min(currentPageIndex, pages.count - 1)
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls.toggle()
            if !showControls {
                showChapterPicker = false
            }
        }
    }

    private func hideControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls = false
            showChapterPicker = false
        }
    }

    private func goToPreviousPage(pages: [ReaderPageItem]) {
        if showControls {
            hideControls()
            return
        }

        guard !showChapterPicker else { return }
        if currentPageIndex > 0 {
            currentPageIndex -= 1
        }
    }

    private func goToNextPage(pages: [ReaderPageItem]) {
        if showControls {
            hideControls()
            return
        }

        guard !showChapterPicker else { return }
        if currentPageIndex < pages.count - 1 {
            currentPageIndex += 1
        }
    }

    private func readerPages(textSize: CGSize) -> [ReaderPageItem] {
        return chapters.enumerated().flatMap { chapterIndex, chapter in
            let chapterTitle = displayed(chapter.title)
            let chapterPages = splitIntoPages(displayed(chapter.content), textSize: textSize)

            return chapterPages.enumerated().map { pageIndex, content in
                ReaderPageItem(
                    chapterIndex: chapterIndex,
                    pageIndex: pageIndex,
                    chapterPageCount: chapterPages.count,
                    chapterTitle: chapterTitle,
                    content: content
                )
            }
        }
    }

    private func readerTextSize(containerSize: CGSize, safeAreaInsets: EdgeInsets) -> CGSize {
        let footerHeight = footerTextHeight
        let footerSpacing: CGFloat = 8
        let width = max(containerSize.width - horizontalMargin * 2, 120)
        let height = max(
            containerSize.height
            - contentTopPadding(safeAreaInsets: safeAreaInsets)
            - contentBottomPadding(safeAreaInsets: safeAreaInsets)
            - footerHeight
            - footerSpacing,
            160
        )

        return CGSize(width: width, height: height)
    }

    private var footerTextHeight: CGFloat {
        let font = UIFont.systemFont(ofSize: 11, weight: .medium)
        return ceil(font.lineHeight)
    }

    private func splitIntoPages(_ content: String, textSize: CGSize) -> [String] {
        var remaining = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String] = []

        while !remaining.isEmpty {
            let splitIndex = fittingSplitIndex(in: remaining, textSize: textSize)
            let pageText = String(remaining[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)

            result.append(pageText.isEmpty ? String(remaining[..<splitIndex]) : pageText)
            remaining = String(remaining[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result.isEmpty ? [""] : result
    }

    private func fittingSplitIndex(in text: String, textSize: CGSize) -> String.Index {
        guard !text.isEmpty else { return text.startIndex }

        let nsText = text as NSString
        let totalLength = nsText.length
        let textView = measuringTextView(width: textSize.width)

        var lowerBound = 1
        var upperBound = totalLength
        var bestLength = 1

        while lowerBound <= upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            let candidate = nsText.substring(to: midpoint)
            let candidateHeight = measuredTextHeight(candidate, using: textView, width: textSize.width)

            if candidateHeight <= textSize.height + 0.5 {
                bestLength = midpoint
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint - 1
            }
        }

        guard bestLength < totalLength else {
            return text.endIndex
        }

        let nsRange = NSRange(location: 0, length: bestLength)
        return Range(nsRange, in: text)?.upperBound ?? text.index(after: text.startIndex)
    }

    private func measuringTextView(width: CGFloat) -> UITextView {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: width, height: 1))
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        textView.clipsToBounds = true
        textView.contentInset = .zero
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        return textView
    }

    private func measuredTextHeight(_ text: String, using textView: UITextView, width: CGFloat) -> CGFloat {
        textView.attributedText = attributedReaderText(text, color: .label)
        let fittingSize = textView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return ceil(fittingSize.height)
    }

    private func attributedReaderText(_ text: String, color: UIColor) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: readerTextAttributes(color: color)
        )
    }

    private func readerTextAttributes(color: UIColor) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .justified
        paragraphStyle.baseWritingDirection = .leftToRight
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacing = lineSpacing * 1.25
        paragraphStyle.lineBreakMode = .byWordWrapping

        return [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
    }

    private func displayed(_ text: String) -> String {
        usesTraditionalChinese ? simplifiedToTraditional(text) : text
    }

    private func simplifiedToTraditional(_ text: String) -> String {
        text.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false) ?? text
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private struct ReaderPageItem: Identifiable {
    let chapterIndex: Int
    let pageIndex: Int
    let chapterPageCount: Int
    let chapterTitle: String
    let content: String

    var id: String {
        "\(chapterIndex)-\(pageIndex)"
    }
}

private struct JustifiedReaderText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let color: UIColor

    func makeUIView(context: Context) -> ReaderTextView {
        let textView = ReaderTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        textView.clipsToBounds = true
        textView.contentInset = .zero
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: ReaderTextView, context: Context) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .justified
        paragraphStyle.baseWritingDirection = .leftToRight
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacing = lineSpacing * 1.25
        paragraphStyle.lineBreakMode = .byWordWrapping

        textView.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
        )
        textView.updateContainerSize()
    }
}

private final class ReaderTextView: UITextView {
    override func layoutSubviews() {
        super.layoutSubviews()
        updateContainerSize()
    }

    func updateContainerSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard textContainer.size != bounds.size else { return }
        textContainer.size = bounds.size
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: attributedText.length), actualCharacterRange: nil)
    }
}

#Preview {
    NavigationStack {
        ReaderView(novel: MockData.novels[0])
    }
}
