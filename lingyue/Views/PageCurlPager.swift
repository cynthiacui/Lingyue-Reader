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
        guard previousIndex != currentIndex else { return }

        // Animate adjacent within-chapter turns (tap zones, auto-scroll) so they
        // slide / curl like a swipe. Multi-page jumps (slider drag) and explicitly
        // instant changes (Transaction.disablesAnimations) skip the animation.
        let isAdjacent = abs(currentIndex - previousIndex) == 1
        let shouldAnimate = isAdjacent && !context.transaction.disablesAnimations
        ReaderDiagnostics.shared.log(.info, "pager updateUIVC", context: [
            "from": String(previousIndex),
            "to": String(currentIndex),
            "wantAnimated": shouldAnimate ? "1" : "0",
            "isAnimating": context.coordinator.isAnimating ? "1" : "0",
            "gestureInFlight": context.coordinator.gestureInFlight ? "1" : "0",
            "pending": context.coordinator.pendingIndex.map(String.init) ?? "-"
        ])
        context.coordinator.requestTransition(to: currentIndex,
                                              animated: shouldAnimate,
                                              in: pvc)
    }

    static func dismantleUIViewController(_ uiViewController: UIPageViewController,
                                          coordinator: Coordinator) {
        coordinator.isDismantled = true
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlPager
        var shownIndex: Int = 0
        var isDismantled = false
        // UIPageViewController crashes with "Duplicate states in queue" if a second
        // setViewControllers lands while a previous animated transition is still
        // in flight. `isAnimating` gates programmatic animated calls; the latest
        // requested target during an animation is stashed in `pendingIndex` and
        // applied instantly from the completion handler so we never queue two
        // animated transitions back-to-back. `gestureInFlight` tracks gesture-
        // started transitions (UIKit signals these via `willTransitionTo`) since
        // those also count as "queue state" UIKit can choke on.
        var isAnimating = false
        var gestureInFlight = false
        var pendingIndex: Int?
        var animationStartedAt: Date?
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

        func requestTransition(to newIndex: Int, animated: Bool, in pvc: UIPageViewController) {
            // A previous animated transition (programmatic or gesture-driven) is
            // still in UIKit's animation queue; pushing another setViewControllers
            // now would crash with "Duplicate states in queue". Stash the desired
            // index and let the completion / didFinishAnimating handler apply it
            // once the curl resolves.
            if isAnimating || gestureInFlight {
                ReaderDiagnostics.shared.log(.info, "pager deferred (would-crash guard)", context: [
                    "to": String(newIndex),
                    "shown": String(shownIndex),
                    "isAnimating": isAnimating ? "1" : "0",
                    "gestureInFlight": gestureInFlight ? "1" : "0",
                    "prevPending": pendingIndex.map(String.init) ?? "-",
                    "ageMs": animationStartedAt.map { String(Int($0.distance(to: Date()) * 1000)) } ?? "-"
                ])
                pendingIndex = newIndex
                return
            }
            performTransition(to: newIndex, animated: animated, in: pvc)
        }

        private func performTransition(to newIndex: Int, animated: Bool, in pvc: UIPageViewController) {
            guard let target = hostingController(for: newIndex) else { return }
            let previousIndex = shownIndex
            guard previousIndex != newIndex else { return }
            let direction: UIPageViewController.NavigationDirection =
                newIndex > previousIndex ? .forward : .reverse
            ReaderDiagnostics.shared.log(.pageTurnStart, "programmatic", context: [
                "from": String(previousIndex),
                "to": String(newIndex),
                "dir": direction == .forward ? "fwd" : "rev",
                "animated": animated ? "1" : "0",
                "pageCount": String(parent.pageCount)
            ])
            shownIndex = newIndex
            if !animated {
                pvc.setViewControllers([target], direction: direction, animated: false)
                return
            }
            isAnimating = true
            animationStartedAt = Date()
            let startedAt = Date()
            pvc.setViewControllers([target], direction: direction, animated: true) { [weak self, weak pvc] finished in
                guard let self = self else { return }
                let durMs = Int(startedAt.distance(to: Date()) * 1000)
                ReaderDiagnostics.shared.log(.pageTurnEnd, "programmatic complete", context: [
                    "to": String(newIndex),
                    "finished": finished ? "1" : "0",
                    "dismantled": self.isDismantled ? "1" : "0",
                    "durMs": String(durMs),
                    "pending": self.pendingIndex.map(String.init) ?? "-"
                ])
                self.isAnimating = false
                self.animationStartedAt = nil
                // iOS 26 UIPageViewController quirk: an animated setViewControllers can
                // fire the completion with finished=false and leave the displayed VC
                // unchanged from the previous page — but shownIndex/currentIndex were
                // already advanced optimistically before the call. The user sees the
                // stale page while state says we've turned, so the next page looks blank.
                // Recover by snapping the target into place non-animated, but only when
                // shownIndex still matches what we asked for (a later gesture or
                // requestTransition may have moved on, in which case we'd clobber it).
                if !finished, !self.isDismantled, let livePvc = pvc,
                   self.shownIndex == newIndex,
                   livePvc.viewControllers?.first !== target {
                    ReaderDiagnostics.shared.log(.info, "pager force-snap after cancel", context: [
                        "to": String(newIndex)
                    ])
                    // Defer one runloop tick — nesting setViewControllers calls inside
                    // another's completion has historically caused UIPageViewController
                    // to drop or duplicate transitions on iOS.
                    DispatchQueue.main.async { [weak self, weak livePvc] in
                        guard let self = self, !self.isDismantled, let livePvc = livePvc,
                              self.shownIndex == newIndex,
                              livePvc.viewControllers?.first !== target else { return }
                        livePvc.setViewControllers([target], direction: direction, animated: false, completion: nil)
                    }
                }
                guard !self.isDismantled,
                      let pvc = pvc,
                      let pending = self.pendingIndex,
                      pending != self.shownIndex else {
                    self.pendingIndex = nil
                    return
                }
                self.pendingIndex = nil
                ReaderDiagnostics.shared.log(.info, "pager apply pending", context: [
                    "to": String(pending),
                    "shown": String(self.shownIndex)
                ])
                // Apply the queued update instantly — animating again would re-enter
                // the same race we're guarding against.
                self.performTransition(to: pending, animated: false, in: pvc)
            }
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

        /// UIKit signals here when the user starts a swipe-driven curl. Track it so
        /// `requestTransition` can defer programmatic calls landing mid-swipe —
        /// `isAnimating` only tracks our own programmatic calls, so without this we
        /// could still stack a programmatic transition on top of a live gesture and
        /// trip UIKit's "Duplicate states in queue" assertion.
        func pageViewController(_ pvc: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            gestureInFlight = true
            let toIndex = pendingViewControllers.first.flatMap { index(of: $0) }
            ReaderDiagnostics.shared.log(.pageTurnStart, "gesture begin", context: [
                "shown": String(shownIndex),
                "to": toIndex.map(String.init) ?? "?"
            ])
        }

        func pageViewController(_ pvc: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers prev: [UIViewController],
                                transitionCompleted completed: Bool) {
            // `didFinishAnimating` fires for both gesture-driven and programmatic
            // transitions. Programmatic transitions also fire their own completion
            // closure (see `performTransition`); to keep our state machine
            // single-sourced we only flip `gestureInFlight` here and let the
            // completion closure handle `isAnimating`.
            let wasGesture = gestureInFlight
            gestureInFlight = false
            // Drop writes after dismantle: the representable was torn down by an .id
            // rebuild (chapter swap) while a swipe animation was still in flight. Without
            // this guard, the old coordinator's binding still points at the same @State,
            // and a late didFinishAnimating callback would clobber the new chapter's
            // freshly-zeroed page index.
            guard !isDismantled, completed,
                  let current = pvc.viewControllers?.first,
                  let i = index(of: current) else {
                if !completed {
                    ReaderDiagnostics.shared.log(.pageTurnEnd, "transition cancelled", context: [
                        "shown": String(shownIndex),
                        "wasGesture": wasGesture ? "1" : "0",
                        "dismantled": isDismantled ? "1" : "0"
                    ])
                }
                // Apply any pending update that piled up during the gesture/transition.
                if !isDismantled, let pending = pendingIndex, pending != shownIndex {
                    pendingIndex = nil
                    ReaderDiagnostics.shared.log(.info, "pager apply pending (post-gesture)", context: [
                        "to": String(pending),
                        "shown": String(shownIndex)
                    ])
                    performTransition(to: pending, animated: false, in: pvc)
                }
                return
            }
            let from = shownIndex
            shownIndex = i
            if parent.currentIndex != i {
                parent.currentIndex = i
            }
            ReaderDiagnostics.shared.log(.pageTurnEnd, wasGesture ? "gesture" : "didFinishAnimating", context: [
                "from": String(from),
                "to": String(i),
                "pageCount": String(parent.pageCount)
            ])
            // Apply any pending programmatic target stashed during the transition.
            if let pending = pendingIndex, pending != shownIndex {
                pendingIndex = nil
                ReaderDiagnostics.shared.log(.info, "pager apply pending (post-gesture)", context: [
                    "to": String(pending),
                    "shown": String(shownIndex)
                ])
                performTransition(to: pending, animated: false, in: pvc)
            }
        }
    }
}
