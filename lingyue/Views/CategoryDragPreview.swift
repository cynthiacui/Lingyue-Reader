import SwiftUI

/// Immutable display data captured at lift time. The drag preview deliberately does
/// not observe download managers, app storage, or asynchronous cover tasks: UIKit only
/// needs one stable image, and dynamic dependencies make that render slower and easier
/// to invalidate midway through a gesture.
struct CategoryDragPreviewModel: Equatable {
    struct Book: Equatable, Identifiable {
        let id: UUID
        let title: String
        let author: String
        let sourceName: String?
        let lastChapter: String
        let progressPercent: Int
        let coverPalette: NovelCoverPalette
    }

    let categoryName: String
    let bookCount: Int
    let books: [Book]

    init(
        category: LibraryCategory,
        visibleNovels: [Novel],
        usesTraditionalChinese: Bool
    ) {
        func displayed(_ text: String) -> String {
            ChineseTextConverter.display(
                text,
                usesTraditionalChinese: usesTraditionalChinese
            )
        }

        categoryName = displayed(category.name)
        bookCount = category.novels.count
        books = visibleNovels.map { novel in
            Book(
                id: novel.id,
                title: displayed(novel.title),
                author: displayed(novel.author),
                sourceName: BookSourceRegistry.displayName(for: novel.sourceURLString)
                    .map(displayed),
                lastChapter: displayed(novel.lastChapter),
                progressPercent: Int(novel.progress * 100),
                coverPalette: novel.coverPalette
            )
        }
    }
}

struct CategoryDragPreview: View {
    @Environment(\.appTheme) private var theme
    let model: CategoryDragPreviewModel
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.categoryName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(model.bookCount) 本")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(minHeight: 34)

            if model.books.isEmpty {
                CategoryDragEmptyRow()
            } else {
                VStack(
                    spacing: -(
                        CategoryShelfMetrics.cardHeight
                            - CategoryShelfMetrics.peekOffset
                    )
                ) {
                    ForEach(Array(model.books.enumerated()), id: \.element.id) { index, book in
                        CategoryDragBookRow(book: book)
                            .frame(height: CategoryShelfMetrics.cardHeight)
                            .scaleEffect(1 - CGFloat(index) * 0.005, anchor: .top)
                            .zIndex(Double(model.books.count - index))
                    }
                }
            }
        }
        .padding(12)
        .frame(
            width: min(
                max(width, CategoryShelfMetrics.minimumPreviewWidth),
                CategoryShelfMetrics.maximumPreviewWidth
            )
        )
        .background(theme.cardBackground.opacity(0.98))
        .clipShape(
            RoundedRectangle(
                cornerRadius: CategoryShelfMetrics.previewCornerRadius,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: CategoryShelfMetrics.previewCornerRadius,
                style: .continuous
            )
            .stroke(theme.accent.opacity(0.24), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 18, x: 0, y: 10)
        .allowsHitTesting(false)
    }
}

private struct CategoryDragBookRow: View {
    @Environment(\.appTheme) private var theme
    let book: CategoryDragPreviewModel.Book

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                LinearGradient(
                    colors: [
                        book.coverPalette.color.opacity(0.96),
                        book.coverPalette.color.opacity(0.68)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Text(book.title)
                    .font(.system(size: 11, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                    .padding(5)
            }
            .frame(width: 48, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(book.author)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let sourceName = book.sourceName {
                        Text("·")
                            .layoutPriority(1)
                        Text(sourceName)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)

                Text(book.lastChapter)
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text("\(book.progressPercent)%")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.accent)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: theme.cardShadow, radius: 8, x: 0, y: 4)
    }
}

private struct CategoryDragEmptyRow: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 48, height: 58)
                .background(theme.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("这里还没有书")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Text("可以把新书移到这里哦")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: CategoryShelfMetrics.cardHeight)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
