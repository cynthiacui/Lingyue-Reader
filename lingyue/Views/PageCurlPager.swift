import SwiftUI
import UIKit

/// SwiftUI wrapper around a `UIPageViewController` configured for the real-book
/// `.pageCurl` transition. SwiftUI itself has no native page-curl, so this is the
/// only way to surface that effect.
///
/// The view is index-driven: the parent passes `pageCount` plus a `renderPage`
/// closure (page index → view), and a binding to the current index. The
/// coordinator caches `UIHostingController`s so neighbours stay live during a
/// curl. Backgrounds are forced opaque because `.pageCurl` shows through
/// transparent pages while turning, leaking whatever's behind.
struct PageCurlPager: UIViewControllerRepresentable {
    let pageCount: Int
    @Binding var currentIndex: Int
    let backgroundColor: UIColor
    let renderPage: (Int) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .pageCurl,
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
            // Animate adjacent within-chapter turns (tap zones, auto-scroll) so they curl
            // like a swipe. Multi-page jumps (slider drag) and explicitly-instant changes
            // (Transaction.disablesAnimations) skip the curl.
            let isAdjacent = abs(currentIndex - previousIndex) == 1
            let shouldAnimate = isAdjacent && !context.transaction.disablesAnimations
            let direction: UIPageViewController.NavigationDirection =
                currentIndex > previousIndex ? .forward : .reverse
            pvc.setViewControllers([target], direction: direction, animated: shouldAnimate)
            context.coordinator.shownIndex = currentIndex
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlPager
        var shownIndex: Int = 0
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
            guard completed,
                  let current = pvc.viewControllers?.first,
                  let i = index(of: current) else { return }
            shownIndex = i
            if parent.currentIndex != i {
                parent.currentIndex = i
            }
        }
    }
}
