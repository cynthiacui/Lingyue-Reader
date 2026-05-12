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
            ReaderDiagnostics.shared.log(.pageTurnStart, "programmatic", context: [
                "from": String(previousIndex),
                "to": String(currentIndex),
                "dir": direction == .forward ? "fwd" : "rev",
                "animated": shouldAnimate ? "1" : "0",
                "pageCount": String(pageCount)
            ])
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
        // Tracks the pageCount at the last refresh so we can detect re-pagination
        // (e.g., async pagination completion that increases/changes page count
        // within the same chapter) and evict non-visible hosts that may still hold
        // stale `renderPage` output.
        private var lastSeenPageCount: Int = -1

        init(_ parent: PageCurlPager) {
            self.parent = parent
            self.shownIndex = parent.currentIndex
            self.lastSeenPageCount = parent.pageCount
        }

        func hostingController(for index: Int) -> UIHostingController<AnyView>? {
            guard index >= 0, index < parent.pageCount else { return nil }
            if let cached = hosts[index] { return cached }
            let host = UIHostingController(rootView: parent.renderPage(index))
            host.view.backgroundColor = parent.backgroundColor
            // The outer ReaderView already pins layout to a stable safe-area inset and
            // passes it explicitly into `pageView`. UIHostingController otherwise spawns a
            // fresh SwiftUI root that re-reads the window's actual safeAreaInsets — so on
            // non-notched iPhones, toggling `.statusBarHidden` with the controls would
            // auto-pad the hosted page top by ~20pt and visibly shift the body down. Zero
            // out the host's safe-area regions so the hosted tree sees zero insets.
            host.safeAreaRegions = []
            hosts[index] = host
            return host
        }

        /// Push fresh root views into existing cached hosts so font / theme changes
        /// take effect without rebuilding the whole pager. Mutating `hosts` during the
        /// dictionary iteration is undefined behavior in Swift and was crashing on
        /// in-chapter re-pagination that shrank the page count (e.g. font size or
        /// line spacing decrease) — collect stale keys first, drop them in a second
        /// pass, then refresh the rest.
        ///
        /// When pageCount changes (in-chapter re-pagination — async pagination
        /// completing, font/spacing change), drop every cached host except the
        /// currently shown one. Refreshing `rootView` on a cached UIHostingController
        /// queues a SwiftUI render but doesn't guarantee the new tree is laid out
        /// before UIPageViewController shows the host on the next swipe; the host
        /// can flash blank until navigated-away-and-back. Building fresh hosts on
        /// demand sidesteps that race because the new host starts its lifecycle
        /// with the current `renderPage` output.
        func refreshCachedRenders() {
            let staleKeys = hosts.keys.filter { $0 >= parent.pageCount }
            for key in staleKeys {
                hosts.removeValue(forKey: key)
            }
            if lastSeenPageCount != parent.pageCount {
                let evictKeys = hosts.keys.filter { $0 != shownIndex }
                for key in evictKeys {
                    hosts.removeValue(forKey: key)
                }
                lastSeenPageCount = parent.pageCount
            }
            for (index, host) in hosts {
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
                  let i = index(of: current) else {
                if !completed {
                    ReaderDiagnostics.shared.log(.pageTurnEnd, "gesture cancelled", context: [
                        "shown": String(shownIndex),
                        "dismantled": isDismantled ? "1" : "0"
                    ])
                }
                return
            }
            let from = shownIndex
            shownIndex = i
            if parent.currentIndex != i {
                parent.currentIndex = i
            }
            ReaderDiagnostics.shared.log(.pageTurnEnd, "gesture", context: [
                "from": String(from),
                "to": String(i),
                "pageCount": String(parent.pageCount)
            ])
        }
    }
}
