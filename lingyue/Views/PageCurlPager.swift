import SwiftUI
import UIKit

/// SwiftUI wrapper around `UIPageViewController` for both `.pageCurl` (real-book
/// curl) and `.scroll` (follow-finger horizontal slide). SwiftUI's `TabView(.page)`
/// drives slide on its own but writes its post-bounce selection back to the binding
/// asynchronously, racing with our boundary-swipe handler — `UIPageViewController`'s
/// `dataSource` returns nil at the chapter end, so the user can't scroll past the
/// last page and no spurious binding write can land in the next chapter.
///
/// Index-driven: the parent passes `pageCount` plus a `renderPage` closure
/// (page index → view), and a binding to the current index. The coordinator caches
/// `UIHostingController`s so neighbours stay live during a transition. Backgrounds
/// are forced opaque because `.pageCurl` shows through transparent pages.
struct PageCurlPager: UIViewControllerRepresentable {
    let transitionStyle: UIPageViewController.TransitionStyle
    let pageCount: Int
    @Binding var currentIndex: Int
    let backgroundColor: UIColor
    let renderPage: (Int) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: transitionStyle,
            navigationOrientation: .horizontal,
            options: nil
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = backgroundColor
        if let initial = context.coordinator.hostingController(for: currentIndex) {
            pvc.setViewControllers([initial], direction: .forward, animated: false)
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        pvc.view.backgroundColor = backgroundColor
        context.coordinator.refreshCachedRenders()

        let previousIndex = context.coordinator.shownIndex
        if previousIndex != currentIndex,
           let target = context.coordinator.hostingController(for: currentIndex) {
            // Animate adjacent within-chapter turns (tap zones, auto-scroll) so they
            // slide / curl like a swipe. Multi-page jumps (slider drag) and explicitly
            // instant changes (Transaction.disablesAnimations) skip the animation.
            let isAdjacent = abs(currentIndex - previousIndex) == 1
            let shouldAnimate = isAdjacent && !context.transaction.disablesAnimations
            let direction: UIPageViewController.NavigationDirection =
                currentIndex > previousIndex ? .forward : .reverse
            pvc.setViewControllers([target], direction: direction, animated: shouldAnimate)
            context.coordinator.shownIndex = currentIndex
        }
    }

    static func dismantleUIViewController(_ uiViewController: UIPageViewController,
                                          coordinator: Coordinator) {
        coordinator.isDismantled = true
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlPager
        var shownIndex: Int = 0
        var isDismantled = false
        // ReaderView already discards the pager wholesale on chapter change (via `.id`),
        // so this cache is bounded to one chapter's worth of pages.
        private var hosts: [Int: UIHostingController<AnyView>] = [:]

        init(_ parent: PageCurlPager) {
            self.parent = parent
            self.shownIndex = parent.currentIndex
        }

        func hostingController(for index: Int) -> UIHostingController<AnyView>? {
            guard index >= 0, index < parent.pageCount else { return nil }
            if let cached = hosts[index] { return cached }
            let host = UIHostingController(rootView: parent.renderPage(index))
            host.view.backgroundColor = parent.backgroundColor
            hosts[index] = host
            return host
        }

        /// Push fresh root views into existing cached hosts so font / theme changes
        /// take effect without rebuilding the whole pager.
        func refreshCachedRenders() {
            for (index, host) in hosts {
                guard index < parent.pageCount else {
                    hosts.removeValue(forKey: index)
                    continue
                }
                host.rootView = parent.renderPage(index)
                host.view.backgroundColor = parent.backgroundColor
            }
        }

        private func index(of viewController: UIViewController) -> Int? {
            hosts.first(where: { $0.value === viewController })?.key
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let i = index(of: vc) else { return nil }
            return hostingController(for: i - 1)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let i = index(of: vc) else { return nil }
            return hostingController(for: i + 1)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers prev: [UIViewController],
                                transitionCompleted completed: Bool) {
            // Drop writes after dismantle: the representable was torn down by an .id
            // rebuild (chapter swap) while a swipe animation was still in flight. Without
            // this guard, the old coordinator's binding still points at the same @State,
            // and a late didFinishAnimating callback would clobber the new chapter's
            // freshly-zeroed page index.
            guard !isDismantled, completed,
                  let current = pvc.viewControllers?.first,
                  let i = index(of: current) else { return }
            shownIndex = i
            if parent.currentIndex != i {
                parent.currentIndex = i
            }
        }
    }
}
