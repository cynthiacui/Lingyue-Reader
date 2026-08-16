import SwiftUI

enum CategoryShelfMetrics {
    static let cardHeight: CGFloat = 88
    static let peekOffset: CGFloat = 22
    static let maximumVisibleBooks = 3
    static let previewCornerRadius: CGFloat = 18
    static let minimumPreviewWidth: CGFloat = 320
    static let maximumPreviewWidth: CGFloat = 430
}

/// Identifies one physical drag attempt independently from the category being moved.
/// A session ID also keeps teardown idempotent if a view disappears while its gesture
/// recognizer is already delivering an end or cancel callback.
struct CategoryReorderSession: Equatable, Sendable {
    let id: UUID
    let categoryID: UUID

    init(id: UUID = UUID(), categoryID: UUID) {
        self.id = id
        self.categoryID = categoryID
    }
}

enum CategoryDragAutoScrollDirection: Hashable, Sendable {
    case up
    case down
}

struct CategoryDragAutoScrollRequest: Hashable, Sendable {
    let sessionID: UUID
    let direction: CategoryDragAutoScrollDirection
}

struct CategoryReorderMove: Equatable, Sendable {
    let sourceCategoryID: UUID
    let targetCategoryID: UUID
}

/// The single source of truth for a category reorder gesture. The source identifier
/// intentionally survives finger-up until SwiftUI performs the drop; visual selection
/// does not. This keeps the UI responsive without losing the data needed to reorder.
struct CategoryReorderState: Equatable {
    enum Phase: Equatable {
        case idle
        case pressing(CategoryReorderSession)
        case dragging(CategoryReorderSession)
        case released(CategoryReorderSession)
    }

    private(set) var phase: Phase = .idle
    private(set) var targetCategoryID: UUID?

    private var interactionSession: CategoryReorderSession? {
        switch phase {
        case .pressing(let session), .dragging(let session), .released(let session):
            return session
        case .idle:
            return nil
        }
    }

    var sourceCategoryID: UUID? {
        switch phase {
        case .dragging(let session), .released(let session):
            return session.categoryID
        case .idle, .pressing:
            return nil
        }
    }

    var transferIsActive: Bool {
        sourceCategoryID != nil
    }

    var activeSessionID: UUID? {
        interactionSession?.id
    }

    func isSourceHighlighted(_ categoryID: UUID) -> Bool {
        guard case .dragging(let session) = phase else { return false }
        return session.categoryID == categoryID
    }

    mutating func touchBegan(session: CategoryReorderSession) {
        guard phase == .idle else { return }
        phase = .pressing(session)
        targetCategoryID = nil
    }

    mutating func dragBegan(session: CategoryReorderSession) {
        switch phase {
        case .pressing(let activeSession) where activeSession.id == session.id:
            phase = .dragging(session)
            targetCategoryID = nil
        case .idle:
            // The UIKit drag callback can occasionally beat the passive touch
            // observer. Accept that ordering only when no other session is active.
            phase = .dragging(session)
            targetCategoryID = nil
        default:
            break
        }
    }

    mutating func touchEnded(sessionID: UUID) {
        switch phase {
        case .pressing(let session) where session.id == sessionID:
            finish()
        case .dragging(let session) where session.id == sessionID:
            phase = .released(session)
        default:
            break
        }
    }

    mutating func enteredTarget(categoryID: UUID) {
        guard let sourceCategoryID, sourceCategoryID != categoryID else {
            targetCategoryID = nil
            return
        }
        targetCategoryID = categoryID
    }

    mutating func updateTarget(categoryID: UUID?, sessionID: UUID) {
        guard interactionSession?.id == sessionID else { return }
        let resolvedTarget = categoryID == sourceCategoryID ? nil : categoryID
        guard targetCategoryID != resolvedTarget else { return }
        targetCategoryID = resolvedTarget
    }

    mutating func exitedTarget(categoryID: UUID) {
        if targetCategoryID == categoryID {
            targetCategoryID = nil
        }
    }

    mutating func finish() {
        phase = .idle
        targetCategoryID = nil
    }

    mutating func finish(sessionID: UUID) {
        guard interactionSession?.id == sessionID else { return }
        finish()
    }

    mutating func complete(sessionID: UUID) -> CategoryReorderMove? {
        guard interactionSession?.id == sessionID else { return nil }
        defer { finish() }
        guard let sourceCategoryID,
              let targetCategoryID,
              sourceCategoryID != targetCategoryID else {
            return nil
        }
        return CategoryReorderMove(
            sourceCategoryID: sourceCategoryID,
            targetCategoryID: targetCategoryID
        )
    }
}

enum CategoryDropIndicatorEdge: Equatable {
    case top
    case bottom
}

struct CategoryDropIndicator: View {
    @Environment(\.appTheme) private var theme
    let edge: CategoryDropIndicatorEdge?

    @ViewBuilder
    var body: some View {
        if let edge {
            VStack(spacing: 0) {
                if edge == .bottom { Spacer(minLength: 0) }

                Capsule()
                    .fill(theme.accent)
                    .frame(height: 3)
                    .padding(.horizontal, 6)
                    .shadow(color: theme.accent.opacity(0.28), radius: 3)

                if edge == .top { Spacer(minLength: 0) }
            }
            .offset(y: edge == .top ? -11 : 11)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }
}
