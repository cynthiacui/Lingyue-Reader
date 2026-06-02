import SwiftUI
import UIKit

/// SwiftUI wrapper around `UIPageViewController` for both `.pageCurl` (real-book
/// curl) and `.scroll` (follow-finger horizontal slide). SwiftUI's `TabView(.page)`
/// drives slide on its own but writes its post-bounce selection back to the binding
/// asynchronously, racing with our boundary-swipe handler — `UIPageViewController`'s
/// `dataSource` returns nil at the chapter end, so the user can't scroll past the
/// last page and no spurious binding write can land in the next chapter.
///
/// IDENTITY-DRIVEN: the parent passes an ordered `slotIdentities: [String]` (one
/// stable id per page/spread) plus a `renderPage` closure (identity → view) and a
/// binding to the current slot index. The coordinator caches `UIHostingController`s
/// keyed by *identity* (not index) so the currently-displayed page survives a
/// re-numbering of the slot array — this is what lets a continuous cross-chapter
/// turn keep showing the same host while the slot window re-bases around the new
/// chapter (see ReaderView's bookend logic). Backgrounds are forced opaque because
/// `.pageCurl` shows through transparent pages.
struct PageCurlPager: UIViewControllerRepresentable {
    let transitionStyle: UIPageViewController.TransitionStyle
    /// Ordered identities of every page the pager can show right now. Stable across
    /// re-renders within a chapter; changes when pagination changes (font/size) or
    /// when the slot window re-bases across a chapter boundary.
    let slotIdentities: [String]
    /// Index into `slotIdentities` of the currently shown page. Two-way bound to the
    /// parent's page-index state; the parent owns the index↔chapter-page translation.
    @Binding var currentIndex: Int
    let backgroundColor: UIColor
    /// Render a page by its stable identity. Called lazily as pages become visible.
    let renderPage: (String) -> AnyView
    /// Called when a transition COMPLETES onto a slot (gesture-driven landing). The
    /// parent inspects the landed identity and, if it is a cross-chapter bookend,
    /// commits the chapter change (re-basing the slot window). For body slots this is
    /// a no-op — the binding sync already moved the page index. Defaults to no-op so
    /// the legacy / two-column path can ignore it.
    var onCommit: (String) -> Void = { _ in }

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
        if let initialID = context.coordinator.identity(at: currentIndex),
           let initial = context.coordinator.host(for: initialID) {
            context.coordinator.shownIdentity = initialID
            pvc.setViewControllers([initial], direction: .forward, animated: false)
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        pvc.view.backgroundColor = backgroundColor
        let slotsChanged = context.coordinator.refreshCachedRenders()

        guard let desiredID = context.coordinator.identity(at: currentIndex) else { return }
        let shownID = context.coordinator.shownIdentity
        // IDENTITY-equality skip (not index): after a cross-chapter re-base the shown
        // page keeps the same identity even though its index shifted, so we must not
        // re-animate it. This replaces the old `previousIndex != currentIndex` guard.
        if desiredID == shownID {
            // A cross-chapter re-base can change the shown page's NEIGHBORS while the page
            // itself stays put — e.g. chapter N's trailing bookend "N+1-0" becomes chapter
            // N+1's body page 0, which now HAS a next page where before it had none.
            // UIPageViewController caches its prev/next view controllers and won't re-query
            // the dataSource without a setViewControllers call, so the next swipe would
            // rubber-band against the stale neighbour ("翻不过去"). Force a no-op re-set to
            // refresh the neighbour cache. Guard against the animation/gesture queue so we
            // don't trip "Duplicate states in queue".
            if slotsChanged,
               !context.coordinator.isAnimating,
               !context.coordinator.gestureInFlight,
               let host = context.coordinator.host(for: shownID) {
                ReaderDiagnostics.shared.log(.info, "pager neighbor refresh", context: ["shownID": shownID])
                pvc.setViewControllers([host], direction: .forward, animated: false)
            }
            return
        }

        // Animate adjacent within-chapter turns (tap zones, auto-scroll) so they
        // slide / curl like a swipe. Multi-page jumps (slider drag) and explicitly
        // instant changes (Transaction.disablesAnimations) skip the animation.
        let previousSlot = context.coordinator.slotIndex(of: shownID)
        let isAdjacent = previousSlot.map { abs(currentIndex - $0) == 1 } ?? false
        let shouldAnimate = isAdjacent && !context.transaction.disablesAnimations
        ReaderDiagnostics.shared.log(.info, "pager updateUIVC", context: [
            "fromID": shownID,
            "toID": desiredID,
            "wantAnimated": shouldAnimate ? "1" : "0",
            "isAnimating": context.coordinator.isAnimating ? "1" : "0",
            "gestureInFlight": context.coordinator.gestureInFlight ? "1" : "0",
            "pending": context.coordinator.pendingIdentity ?? "-"
        ])
        context.coordinator.requestTransition(to: desiredID,
                                              animated: shouldAnimate,
                                              in: pvc)
    }

    static func dismantleUIViewController(_ uiViewController: UIPageViewController,
                                          coordinator: Coordinator) {
        coordinator.isDismantled = true
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlPager
        /// Identity of the page UIPageViewController is currently displaying. Source of
        /// truth for transition decisions — survives slot-array re-numbering.
        var shownIdentity: String = ""
        var isDismantled = false
        // UIPageViewController crashes with "Duplicate states in queue" if a second
        // setViewControllers lands while a previous animated transition is still
        // in flight. `isAnimating` gates programmatic animated calls; the latest
        // requested target during an animation is stashed in `pendingIdentity` and
        // applied instantly from the completion handler so we never queue two
        // animated transitions back-to-back. `gestureInFlight` tracks gesture-
        // started transitions (UIKit signals these via `willTransitionTo`) since
        // those also count as "queue state" UIKit can choke on.
        var isAnimating = false
        var gestureInFlight = false
        // Stashed as an IDENTITY (not index): a transition deferred mid-animation may
        // resolve, by the time it's applied, against a slot array that has re-based to
        // a different chapter. We re-validate the identity is still present before
        // applying and bail otherwise.
        var pendingIdentity: String?
        var animationStartedAt: Date?
        // Hosts cached by stable identity so the live page survives a slot re-base.
        private var hosts: [String: UIHostingController<AnyView>] = [:]
        // Snapshot of the slot identities at the last refresh so we can detect
        // re-pagination / re-base and evict stale, non-visible hosts.
        private var lastSeenSlotIdentities: [String] = []

        init(_ parent: PageCurlPager) {
            self.parent = parent
            let initialIdentity = parent.slotIdentities.indices.contains(parent.currentIndex)
                ? parent.slotIdentities[parent.currentIndex]
                : parent.slotIdentities.first
            self.shownIdentity = initialIdentity ?? ""
            self.lastSeenSlotIdentities = parent.slotIdentities
        }

        // MARK: identity ↔ index helpers (resolved against the *current* slot array)

        func identity(at index: Int) -> String? {
            parent.slotIdentities.indices.contains(index) ? parent.slotIdentities[index] : nil
        }

        func slotIndex(of identity: String) -> Int? {
            parent.slotIdentities.firstIndex(of: identity)
        }

        /// Cached hosting controller for an identity. Returns nil if the identity is not
        /// part of the current slot array (defensive — a stale neighbour request).
        func host(for identity: String) -> UIHostingController<AnyView>? {
            guard slotIndex(of: identity) != nil else { return nil }
            if let cached = hosts[identity] { return cached }
            let host = UIHostingController(rootView: parent.renderPage(identity))
            host.view.backgroundColor = parent.backgroundColor
            // The outer ReaderView already pins layout to a stable safe-area inset and
            // passes it explicitly into `pageView`. UIHostingController otherwise spawns a
            // fresh SwiftUI root that re-reads the window's actual safeAreaInsets — so on
            // non-notched iPhones, toggling `.statusBarHidden` with the controls would
            // auto-pad the hosted page top by ~20pt and visibly shift the body down. Zero
            // out the host's safe-area regions so the hosted tree sees zero insets.
            host.safeAreaRegions = []
            hosts[identity] = host
            return host
        }

        private func identity(of viewController: UIViewController) -> String? {
            hosts.first(where: { $0.value === viewController })?.key
        }

        func requestTransition(to identity: String, animated: Bool, in pvc: UIPageViewController) {
            // A previous animated transition (programmatic or gesture-driven) is
            // still in UIKit's animation queue; pushing another setViewControllers
            // now would crash with "Duplicate states in queue". Stash the desired
            // identity and let the completion / didFinishAnimating handler apply it
            // once the curl resolves.
            if isAnimating || gestureInFlight {
                ReaderDiagnostics.shared.log(.info, "pager deferred (would-crash guard)", context: [
                    "toID": identity,
                    "shownID": shownIdentity,
                    "isAnimating": isAnimating ? "1" : "0",
                    "gestureInFlight": gestureInFlight ? "1" : "0",
                    "prevPending": pendingIdentity ?? "-",
                    "ageMs": animationStartedAt.map { String(Int($0.distance(to: Date()) * 1000)) } ?? "-"
                ])
                pendingIdentity = identity
                return
            }
            performTransition(to: identity, animated: animated, in: pvc)
        }

        private func performTransition(to identity: String, animated: Bool, in pvc: UIPageViewController) {
            guard let target = host(for: identity) else { return }
            let previousID = shownIdentity
            guard previousID != identity else { return }
            let newSlot = slotIndex(of: identity) ?? 0
            let prevSlot = slotIndex(of: previousID) ?? 0
            let direction: UIPageViewController.NavigationDirection =
                newSlot >= prevSlot ? .forward : .reverse
            ReaderDiagnostics.shared.log(.pageTurnStart, "programmatic", context: [
                "fromID": previousID,
                "toID": identity,
                "dir": direction == .forward ? "fwd" : "rev",
                "animated": animated ? "1" : "0",
                "slots": String(parent.slotIdentities.count)
            ])
            shownIdentity = identity
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
                    "toID": identity,
                    "finished": finished ? "1" : "0",
                    "dismantled": self.isDismantled ? "1" : "0",
                    "durMs": String(durMs),
                    "pending": self.pendingIdentity ?? "-"
                ])
                self.isAnimating = false
                self.animationStartedAt = nil
                // iOS 26 UIPageViewController quirk: an animated setViewControllers can
                // fire the completion with finished=false and leave the displayed VC
                // unchanged from the previous page — but shownIdentity/currentIndex were
                // already advanced optimistically before the call. The user sees the
                // stale page while state says we've turned, so the next page looks blank.
                // Recover by snapping the target into place non-animated, but only when
                // shownIdentity still matches what we asked for (a later gesture or
                // requestTransition may have moved on, in which case we'd clobber it).
                if !finished, !self.isDismantled, let livePvc = pvc,
                   self.shownIdentity == identity,
                   livePvc.viewControllers?.first !== target {
                    ReaderDiagnostics.shared.log(.info, "pager force-snap after cancel", context: [
                        "toID": identity
                    ])
                    // Defer one runloop tick — nesting setViewControllers calls inside
                    // another's completion has historically caused UIPageViewController
                    // to drop or duplicate transitions on iOS.
                    DispatchQueue.main.async { [weak self, weak livePvc] in
                        guard let self = self, !self.isDismantled, let livePvc = livePvc,
                              self.shownIdentity == identity,
                              livePvc.viewControllers?.first !== target else { return }
                        livePvc.setViewControllers([target], direction: direction, animated: false, completion: nil)
                    }
                }
                guard !self.isDismantled,
                      let pvc = pvc,
                      let pending = self.pendingIdentity,
                      pending != self.shownIdentity else {
                    self.pendingIdentity = nil
                    return
                }
                self.pendingIdentity = nil
                ReaderDiagnostics.shared.log(.info, "pager apply pending", context: [
                    "toID": pending,
                    "shownID": self.shownIdentity
                ])
                // Apply the queued update instantly — animating again would re-enter
                // the same race we're guarding against. `performTransition` re-resolves
                // the host for `pending`; if the identity is no longer in the slot array
                // (re-based away) `host(for:)` returns nil and it's a safe no-op.
                self.performTransition(to: pending, animated: false, in: pvc)
            }
        }

        // MARK: data source

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let id = identity(of: vc), let i = slotIndex(of: id),
                  let prevID = identity(at: i - 1) else { return nil }
            return host(for: prevID)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let id = identity(of: vc), let i = slotIndex(of: id),
                  let nextID = identity(at: i + 1) else { return nil }
            return host(for: nextID)
        }

        /// Push fresh root views into existing cached hosts so font / theme changes
        /// take effect without rebuilding the whole pager. When the slot array changes
        /// (in-chapter re-pagination, or a cross-chapter re-base), drop every cached
        /// host EXCEPT the currently shown identity — refreshing `rootView` on a cached
        /// UIHostingController queues a SwiftUI render but doesn't guarantee the new tree
        /// is laid out before UIPageViewController shows the host on the next swipe; the
        /// host can flash blank until navigated-away-and-back. Building fresh hosts on
        /// demand sidesteps that race. Never evicting `shownIdentity` is load-bearing for
        /// the seamless cross-chapter re-base.
        /// Returns whether the slot array changed since the last refresh (caller uses this to
        /// know it must refresh UIPageViewController's cached neighbours after a re-base).
        @discardableResult
        func refreshCachedRenders() -> Bool {
            let validIDs = Set(parent.slotIdentities)
            for key in hosts.keys where !validIDs.contains(key) {
                hosts.removeValue(forKey: key)
            }
            let slotsChanged = lastSeenSlotIdentities != parent.slotIdentities
            if slotsChanged {
                for key in hosts.keys where key != shownIdentity {
                    hosts.removeValue(forKey: key)
                }
                lastSeenSlotIdentities = parent.slotIdentities
            }
            for (identity, host) in hosts {
                host.rootView = parent.renderPage(identity)
                host.view.backgroundColor = parent.backgroundColor
            }
            return slotsChanged
        }

        // MARK: delegate

        /// UIKit signals here when the user starts a swipe-driven curl. Track it so
        /// `requestTransition` can defer programmatic calls landing mid-swipe —
        /// `isAnimating` only tracks our own programmatic calls, so without this we
        /// could still stack a programmatic transition on top of a live gesture and
        /// trip UIKit's "Duplicate states in queue" assertion.
        func pageViewController(_ pvc: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            gestureInFlight = true
            let toID = pendingViewControllers.first.flatMap { identity(of: $0) }
            ReaderDiagnostics.shared.log(.pageTurnStart, "gesture begin", context: [
                "shownID": shownIdentity,
                "toID": toID ?? "?"
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
            // rebuild (rotation, or — on the legacy path — a chapter swap) while a swipe
            // animation was still in flight. Without this guard, the old coordinator's
            // binding still points at the same @State and a late didFinishAnimating
            // callback would clobber freshly-reset state.
            guard !isDismantled, completed,
                  let current = pvc.viewControllers?.first,
                  let landedID = identity(of: current) else {
                if !completed {
                    ReaderDiagnostics.shared.log(.pageTurnEnd, "transition cancelled", context: [
                        "shownID": shownIdentity,
                        "wasGesture": wasGesture ? "1" : "0",
                        "dismantled": isDismantled ? "1" : "0"
                    ])
                }
                // Apply any pending update that piled up during the gesture/transition.
                // Defer one runloop tick — calling setViewControllers synchronously inside
                // UIKit's didFinishAnimating(completed=false) leaves the displayed VC
                // unchanged even with animated:false, so the next page renders blank.
                if !isDismantled, let pending = pendingIdentity, pending != shownIdentity {
                    pendingIdentity = nil
                    ReaderDiagnostics.shared.log(.info, "pager apply pending (post-gesture)", context: [
                        "toID": pending,
                        "shownID": shownIdentity
                    ])
                    DispatchQueue.main.async { [weak self, weak pvc] in
                        guard let self = self, !self.isDismantled, let pvc = pvc,
                              self.shownIdentity != pending else { return }
                        self.requestTransition(to: pending, animated: false, in: pvc)
                    }
                }
                return
            }
            let fromID = shownIdentity
            shownIdentity = landedID
            if let slot = slotIndex(of: landedID), parent.currentIndex != slot {
                // Binding sync for body slots; the custom binding on the continuous path
                // ignores bookend indices, so this never writes an out-of-range page.
                parent.currentIndex = slot
            }
            ReaderDiagnostics.shared.log(.pageTurnEnd, wasGesture ? "gesture" : "didFinishAnimating", context: [
                "fromID": fromID,
                "toID": landedID,
                "slots": String(parent.slotIdentities.count)
            ])
            // Commit a cross-chapter bookend landing (re-bases the slot window). For body
            // landings this is a no-op. Called AFTER the binding sync so the page index is
            // already settled for the body case.
            parent.onCommit(landedID)
            // Apply any pending programmatic target stashed during the transition.
            if let pending = pendingIdentity, pending != shownIdentity {
                pendingIdentity = nil
                ReaderDiagnostics.shared.log(.info, "pager apply pending (post-gesture)", context: [
                    "toID": pending,
                    "shownID": shownIdentity
                ])
                performTransition(to: pending, animated: false, in: pvc)
            }
        }
    }
}
