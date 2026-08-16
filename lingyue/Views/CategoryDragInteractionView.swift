import SwiftUI
import UIKit

@MainActor
enum CategoryDragSnapshotRenderer {
    static func image<Content: View>(
        for content: Content,
        displayScale: CGFloat
    ) -> UIImage? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = max(displayScale, 1)
        return renderer.uiImage
    }
}

/// Owns the complete long-press lifecycle. Unlike `UIDragInteraction`, this recognizer
/// receives the real finger-up event instead of a delayed system cancellation callback.
struct CategoryDragInteractionView<Preview: View>: UIViewRepresentable {
    let identifier: UUID
    let onTouchBegan: (CategoryReorderSession) -> Void
    let onDragBegan: (CategoryReorderSession) -> Void
    let onDragMoved: (UUID, CGPoint) -> Void
    let onDragEdgeChanged: (UUID, CategoryDragAutoScrollDirection?) -> Void
    let onTouchReleased: (UUID) -> Void
    let onDragEnded: (UUID, Bool) -> Void
    let preview: () -> Preview

    init(
        identifier: UUID,
        onTouchBegan: @escaping (CategoryReorderSession) -> Void,
        onDragBegan: @escaping (CategoryReorderSession) -> Void,
        onDragMoved: @escaping (UUID, CGPoint) -> Void,
        onDragEdgeChanged: @escaping (UUID, CategoryDragAutoScrollDirection?) -> Void,
        onTouchReleased: @escaping (UUID) -> Void,
        onDragEnded: @escaping (UUID, Bool) -> Void,
        @ViewBuilder preview: @escaping () -> Preview
    ) {
        self.identifier = identifier
        self.onTouchBegan = onTouchBegan
        self.onDragBegan = onDragBegan
        self.onDragMoved = onDragMoved
        self.onDragEdgeChanged = onDragEdgeChanged
        self.onTouchReleased = onTouchReleased
        self.onDragEnded = onDragEnded
        self.preview = preview
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            identifier: identifier,
            onTouchBegan: onTouchBegan,
            onDragBegan: onDragBegan,
            onDragMoved: onDragMoved,
            onDragEdgeChanged: onDragEdgeChanged,
            onTouchReleased: onTouchReleased,
            onDragEnded: onDragEnded,
            preview: preview
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false

        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        recognizer.minimumPressDuration = 0.5
        recognizer.allowableMovement = 12
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        context.coordinator.sourceView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(
            identifier: identifier,
            onTouchBegan: onTouchBegan,
            onDragBegan: onDragBegan,
            onDragMoved: onDragMoved,
            onDragEdgeChanged: onDragEdgeChanged,
            onTouchReleased: onTouchReleased,
            onDragEnded: onDragEnded,
            preview: preview
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.cancelActiveGesture()
        coordinator.sourceView = nil
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var sourceView: UIView?

        private var identifier: UUID
        private var onTouchBegan: (CategoryReorderSession) -> Void
        private var onDragBegan: (CategoryReorderSession) -> Void
        private var onDragMoved: (UUID, CGPoint) -> Void
        private var onDragEdgeChanged: (UUID, CategoryDragAutoScrollDirection?) -> Void
        private var onTouchReleased: (UUID) -> Void
        private var onDragEnded: (UUID, Bool) -> Void
        private var makePreview: () -> AnyView

        private var activeSession: CategoryReorderSession?
        private var previewSnapshotView: UIImageView?
        private var initialPreviewCenter: CGPoint = .zero
        private var initialTouchLocation: CGPoint = .zero
        private var reportedEdge: CategoryDragAutoScrollDirection?
        private var didReleaseVisuals = false

        init(
            identifier: UUID,
            onTouchBegan: @escaping (CategoryReorderSession) -> Void,
            onDragBegan: @escaping (CategoryReorderSession) -> Void,
            onDragMoved: @escaping (UUID, CGPoint) -> Void,
            onDragEdgeChanged: @escaping (UUID, CategoryDragAutoScrollDirection?) -> Void,
            onTouchReleased: @escaping (UUID) -> Void,
            onDragEnded: @escaping (UUID, Bool) -> Void,
            preview: @escaping () -> Preview
        ) {
            self.identifier = identifier
            self.onTouchBegan = onTouchBegan
            self.onDragBegan = onDragBegan
            self.onDragMoved = onDragMoved
            self.onDragEdgeChanged = onDragEdgeChanged
            self.onTouchReleased = onTouchReleased
            self.onDragEnded = onDragEnded
            self.makePreview = { AnyView(preview()) }
        }

        func update(
            identifier: UUID,
            onTouchBegan: @escaping (CategoryReorderSession) -> Void,
            onDragBegan: @escaping (CategoryReorderSession) -> Void,
            onDragMoved: @escaping (UUID, CGPoint) -> Void,
            onDragEdgeChanged: @escaping (UUID, CategoryDragAutoScrollDirection?) -> Void,
            onTouchReleased: @escaping (UUID) -> Void,
            onDragEnded: @escaping (UUID, Bool) -> Void,
            preview: @escaping () -> Preview
        ) {
            self.identifier = identifier
            self.onTouchBegan = onTouchBegan
            self.onDragBegan = onDragBegan
            self.onDragMoved = onDragMoved
            self.onDragEdgeChanged = onDragEdgeChanged
            self.onTouchReleased = onTouchReleased
            self.onDragEnded = onDragEnded
            self.makePreview = { AnyView(preview()) }
        }

        @objc
        func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                beginGesture(recognizer)
            case .changed:
                moveGesture(recognizer)
            case .ended:
                endGesture(recognizer, shouldCommit: true)
            case .cancelled, .failed:
                endGesture(recognizer, shouldCommit: false)
            case .possible:
                break
            @unknown default:
                endGesture(recognizer, shouldCommit: false)
            }
        }

        func cancelActiveGesture() {
            guard let session = activeSession else {
                removePreview()
                return
            }
            releaseVisualState(sessionID: session.id)
            onDragEnded(session.id, false)
            activeSession = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        private func beginGesture(_ recognizer: UILongPressGestureRecognizer) {
            guard activeSession == nil,
                  let sourceView,
                  let window = sourceView.window,
                  let image = CategoryDragSnapshotRenderer.image(
                    for: makePreview(),
                    displayScale: sourceView.traitCollection.displayScale
                  ),
                  image.size.width > 0,
                  image.size.height > 0 else {
                return
            }

            let session = CategoryReorderSession(categoryID: identifier)
            let location = recognizer.location(in: window)
            let sourceOrigin = sourceView.convert(sourceView.bounds.origin, to: window)
            let imageView = UIImageView(image: image)
            imageView.frame = CGRect(origin: sourceOrigin, size: image.size)
            imageView.backgroundColor = .clear
            imageView.isOpaque = false
            imageView.isUserInteractionEnabled = false
            imageView.contentMode = .scaleToFill
            imageView.transform = CGAffineTransform(scaleX: 1.008, y: 1.008)
            window.addSubview(imageView)

            activeSession = session
            previewSnapshotView = imageView
            initialPreviewCenter = imageView.center
            initialTouchLocation = location
            reportedEdge = nil
            didReleaseVisuals = false

            onTouchBegan(session)
            onDragBegan(session)
            reportLocation(location, in: window, sessionID: session.id)
        }

        private func moveGesture(_ recognizer: UILongPressGestureRecognizer) {
            guard let session = activeSession,
                  let sourceView,
                  let window = sourceView.window else { return }
            let location = recognizer.location(in: window)
            let translation = CGPoint(
                x: location.x - initialTouchLocation.x,
                y: location.y - initialTouchLocation.y
            )
            previewSnapshotView?.center = CGPoint(
                x: initialPreviewCenter.x + translation.x,
                y: initialPreviewCenter.y + translation.y
            )
            reportLocation(location, in: window, sessionID: session.id)
        }

        private func endGesture(
            _ recognizer: UILongPressGestureRecognizer,
            shouldCommit: Bool
        ) {
            guard let session = activeSession else { return }
            if let window = sourceView?.window {
                reportLocation(
                    recognizer.location(in: window),
                    in: window,
                    sessionID: session.id
                )
            }

            // Clear visuals before reordering so a library refresh cannot delay the
            // response to the real finger-up event.
            releaseVisualState(sessionID: session.id)
            onDragEnded(session.id, shouldCommit)
            activeSession = nil
        }

        private func reportLocation(
            _ location: CGPoint,
            in window: UIWindow,
            sessionID: UUID
        ) {
            onDragMoved(sessionID, location)

            let edgeZoneHeight: CGFloat = 110
            let topThreshold = window.bounds.minY
                + window.safeAreaInsets.top
                + edgeZoneHeight
            let bottomThreshold = window.bounds.maxY
                - window.safeAreaInsets.bottom
                - edgeZoneHeight
            let direction: CategoryDragAutoScrollDirection? = if location.y < topThreshold {
                .up
            } else if location.y > bottomThreshold {
                .down
            } else {
                nil
            }
            guard reportedEdge != direction else { return }
            reportedEdge = direction
            onDragEdgeChanged(sessionID, direction)
        }

        private func releaseVisualState(sessionID: UUID) {
            guard !didReleaseVisuals else { return }
            didReleaseVisuals = true
            if reportedEdge != nil {
                reportedEdge = nil
                onDragEdgeChanged(sessionID, nil)
            }
            removePreview()
            onTouchReleased(sessionID)
        }

        private func removePreview() {
            previewSnapshotView?.layer.removeAllAnimations()
            previewSnapshotView?.removeFromSuperview()
            previewSnapshotView = nil
        }
    }
}
