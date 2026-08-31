import SwiftUI
import UIKit

/// UIPageViewController asks its data source for a neighbour only when a gesture is
/// about to begin. A freshly-created UIHostingController can need another run-loop
/// turn for its first SwiftUI layout, which lets a quick swipe land on a valid but
/// visually empty host. Report settled viewport layouts so the coordinator can
/// eagerly prepare the current page and its immediate neighbours beforehand.
private final class ReaderPageViewController: UIPageViewController {
    var onViewportLayout: (() -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onViewportLayout?()
    }
}

/// Hosting controller that carries its page identity independently of the cache.
/// UIPageViewController may retain a controller after our bounded cache evicts it;
/// keeping the identity on the controller makes late delegate/data-source callbacks
/// O(1) and safe instead of reverse-scanning (or depending on) the cache contents.
private final class ReaderPageHostingController: UIHostingController<AnyView> {
    let pageIdentity: String

    init(pageIdentity: String, rootView: AnyView) {
        self.pageIdentity = pageIdentity
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

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
    /// Render a page by its stable identity. The visible page and its immediate
    /// neighbours are prepared eagerly; all other pages remain lazy.
    let renderPage: (String) -> AnyView
    /// Called when a transition COMPLETES onto a slot (gesture-driven landing). The
    /// parent inspects the landed identity and, if it is a cross-chapter bookend,
    /// commits the chapter change (re-basing the slot window). For body slots this is
    /// a no-op — the binding sync already moved the page index. Defaults to no-op so
    /// the legacy / two-column path can ignore it.
    var onCommit: (String) -> Void = { _ in }
    /// Monotonic marker the parent bumps for every EXPLICIT navigation (chapter
    /// buttons, picker, slider, boundary fallback). A transition that STARTED under
    /// an older epoch must not commit its landing — the explicit jump has already
    /// decided where the reader goes, and a late gesture write-back would drag the
    /// user back across a chapter boundary. This replaces the old approach of
    /// rebuilding the whole pager via `.id` on such jumps: a mid-session identity
    /// swap has been observed (iOS 26) to permanently stop SwiftUI from delivering
    /// `updateUIViewController` to every subsequently created pager, which froze the
    /// slot window and dead-ended page turns at the next chapter boundary.
    var navigationEpoch: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = ReaderPageViewController(
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
        let coordinator = context.coordinator
        pvc.onViewportLayout = { [weak coordinator, weak pvc] in
            guard let coordinator, let pvc else { return }
            coordinator.handleViewportLayout(in: pvc)
        }
        context.coordinator.prepareVisibleNeighborhood(in: pvc)
        ReaderDiagnostics.shared.log(.info, "pager created", context: [
            "co": context.coordinator.debugTag,
            "slots": String(slotIdentities.count),
            "shownID": context.coordinator.shownIdentity
        ])
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.updateCount += 1
        context.coordinator.parent = self
        pvc.view.backgroundColor = backgroundColor
        let slotsChanged = context.coordinator.refreshCachedRenders()
        context.coordinator.prepareVisibleNeighborhood(in: pvc)

        if slotsChanged {
            ReaderDiagnostics.shared.log(.info, "pager slots changed", context: [
                "co": context.coordinator.debugTag,
                "slots": String(slotIdentities.count),
                "first": slotIdentities.first ?? "-",
                "last": slotIdentities.last ?? "-",
                "gestureInFlight": context.coordinator.gestureInFlight ? "1" : "0",
                "isAnimating": context.coordinator.isAnimating ? "1" : "0"
            ])
        }

        guard let desiredID = context.coordinator.identity(at: currentIndex) else {
            ReaderDiagnostics.shared.log(.info, "pager updateUIVC no-desired", context: [
                "co": context.coordinator.debugTag,
                "currentIndex": String(currentIndex),
                "slots": String(slotIdentities.count),
                "needsRefresh": context.coordinator.needsNeighborRefresh ? "1" : "0"
            ])
            return
        }
        let shownID = context.coordinator.shownIdentity
        // IDENTITY-equality skip (not index): after a cross-chapter re-base the shown
        // page keeps the same identity even though its index shifted, so we must not
        // re-animate it. This replaces the old `previousIndex != currentIndex` guard.
        if desiredID == shownID {
            if context.coordinator.needsNeighborRefresh {
                ReaderDiagnostics.shared.log(.info, "pager updateUIVC skip (refresh pending)", context: [
                    "co": context.coordinator.debugTag,
                    "shownID": shownID,
                    "gestureInFlight": context.coordinator.gestureInFlight ? "1" : "0",
                    "isAnimating": context.coordinator.isAnimating ? "1" : "0"
                ])
            }
            // A target deferred during an earlier transition is obsolete once the
            // binding again agrees with the displayed page. Leaving it queued can
            // make a later, unrelated swipe snap back to this old destination.
            context.coordinator.pendingIdentity = nil
            // A cross-chapter re-base can change the shown page's NEIGHBORS while the page
            // itself stays put — e.g. chapter N's trailing bookend "N+1-0" becomes chapter
            // N+1's body page 0, which now HAS a next page where before it had none.
            // UIPageViewController caches its prev/next view controllers and won't re-query
            // the dataSource without a setViewControllers call, so the next swipe would
            // rubber-band against the stale neighbour ("翻不过去"). Force a no-op re-set to
            // refresh the neighbour cache. Guard against the animation/gesture queue so we
            // don't trip "Duplicate states in queue".
            context.coordinator.refreshNeighborsIfNeeded(in: pvc)
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
        coordinator.cancelTransitionWatchdog()
        (uiViewController as? ReaderPageViewController)?.onViewportLayout = nil
        ReaderDiagnostics.shared.log(.info, "pager dismantled", context: [
            "co": coordinator.debugTag,
            "shownID": coordinator.shownIdentity
        ])
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlPager {
            didSet {
                guard oldValue.slotIdentities != parent.slotIdentities else { return }
                rebuildSlotIndex()
            }
        }
        /// Identity of the page UIPageViewController is currently displaying. Source of
        /// truth for transition decisions — survives slot-array re-numbering.
        var shownIdentity: String = ""
        var isDismantled = false
        /// Short per-coordinator tag for diagnostics, so a log stream can tell whether
        /// updates and gestures are reaching the same coordinator instance or a stale,
        /// dismantled one that UIKit kept on screen.
        lazy var debugTag: String = String(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 10_000)
        /// Counts updateUIViewController calls. A frozen count while dataSource
        /// callbacks keep flowing means SwiftUI stopped delivering representable
        /// updates entirely — the difference between a stale-window bug in this
        /// file and a dead update pipeline upstream.
        var updateCount = 0
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
        private var gestureStartedAt: Date?
        /// True only while UIKit is executing one of our transition callbacks. SwiftUI
        /// state writes made by `onCommit` can synchronously trigger representable updates;
        /// this guard prevents a nested setViewControllers call in UIKit's callback stack.
        private var isHandlingTransitionCallback = false
        /// A single coalesced watchdog makes the state machine self-healing if UIKit drops
        /// a completion callback (observed around interruptions/backgrounding). It is
        /// cancelled/replaced for every new transition, so work stays O(1).
        private var transitionWatchdog: DispatchWorkItem?
        private let transitionWatchdogDelay: TimeInterval
        // UIKit can keep a neighbor controller alive while SwiftUI updates the slot
        // window (for example when prefetch adds a chapter bookend mid-drag). Keep
        // that identity in the cache until the gesture resolves so delegate callbacks
        // can still map the landed controller back to its page.
        var gestureTargetIdentity: String?
        /// `parent.navigationEpoch` at the moment the in-flight transition started.
        /// A completed landing whose epoch no longer matches raced an explicit
        /// navigation; its binding write and bookend commit are voided so the jump's
        /// destination wins (see `navigationEpoch` on the representable).
        private var activeTransitionEpoch = 0
        // Hosts cached by stable identity so the live page survives a slot re-base. Keep
        // only a small working set: without an explicit cap, a single extremely long
        // chapter retains one UIHostingController per visited page for the whole session.
        private var hosts: [String: ReaderPageHostingController] = [:]
        private var hostAccessOrder: [String] = []
        private let hostCacheCapacity = 9
        // Records the viewport size at which each host completed its first synchronous
        // layout. A matching entry means the host is ready to animate on screen; a size
        // change (rotation / split view) prepares it again at the new geometry.
        private var preparedHostSizes: [String: CGSize] = [:]
        // Temporary containment can cause the pager itself to lay out again. Prevent
        // that callback from recursively starting another preparation batch.
        private var isPreparingHosts = false
        // Snapshot of the slot identities at the last refresh so we can detect
        // re-pagination / re-base and evict stale, non-visible hosts.
        private var lastSeenSlotIdentities: [String] = []
        /// Identity lookup is on the page-turn hot path. Rebuild once when pagination
        /// changes instead of scanning every page for each data-source/delegate callback.
        private var slotIndexByIdentity: [String: Int] = [:]
        // UIPageViewController caches a nil previous/next answer. When the slot window
        // changes during a gesture or programmatic animation we cannot safely call
        // setViewControllers immediately, but consuming the change at that point loses
        // the only signal that its neighbour cache is stale. Keep the refresh pending
        // until the transition has settled; otherwise a chapter bookend added mid-turn
        // can remain unreachable for the rest of the reader session.
        private(set) var needsNeighborRefresh = false

        var cachedHostCount: Int { hosts.count }

        init(_ parent: PageCurlPager, transitionWatchdogDelay: TimeInterval = 3) {
            self.parent = parent
            self.transitionWatchdogDelay = transitionWatchdogDelay
            let initialIdentity = parent.slotIdentities.indices.contains(parent.currentIndex)
                ? parent.slotIdentities[parent.currentIndex]
                : parent.slotIdentities.first
            self.shownIdentity = initialIdentity ?? ""
            self.lastSeenSlotIdentities = parent.slotIdentities
            super.init()
            rebuildSlotIndex()
        }

        // MARK: identity ↔ index helpers (resolved against the *current* slot array)

        func identity(at index: Int) -> String? {
            parent.slotIdentities.indices.contains(index) ? parent.slotIdentities[index] : nil
        }

        func slotIndex(of identity: String) -> Int? {
            slotIndexByIdentity[identity]
        }

        private func rebuildSlotIndex() {
            var rebuilt: [String: Int] = [:]
            rebuilt.reserveCapacity(parent.slotIdentities.count)
            for (index, identity) in parent.slotIdentities.enumerated() {
                // Page identities are expected to be unique. Keeping the first occurrence
                // is defensive and matches Array.firstIndex(of:) if malformed input arrives.
                if rebuilt[identity] == nil {
                    rebuilt[identity] = index
                }
            }
            slotIndexByIdentity = rebuilt
        }

        /// Cached hosting controller for an identity. Returns nil if the identity is not
        /// part of the current slot array (defensive — a stale neighbour request).
        func host(for identity: String) -> UIHostingController<AnyView>? {
            guard slotIndex(of: identity) != nil else { return nil }
            if let cached = hosts[identity] {
                touchHost(identity)
                return cached
            }
            let host = ReaderPageHostingController(
                pageIdentity: identity,
                rootView: parent.renderPage(identity)
            )
            host.view.backgroundColor = parent.backgroundColor
            // The outer ReaderView already pins layout to a stable safe-area inset and
            // passes it explicitly into `pageView`. UIHostingController otherwise spawns a
            // fresh SwiftUI root that re-reads the window's actual safeAreaInsets — so on
            // non-notched iPhones, toggling `.statusBarHidden` with the controls would
            // auto-pad the hosted page top by ~20pt and visibly shift the body down. Zero
            // out the host's safe-area regions so the hosted tree sees zero insets.
            host.safeAreaRegions = []
            hosts[identity] = host
            touchHost(identity)
            trimHostCache(preserving: retainedHostIdentities(including: identity))
            return host
        }

        private func touchHost(_ identity: String) {
            hostAccessOrder.removeAll { $0 == identity }
            hostAccessOrder.append(identity)
        }

        /// Identities UIKit can still reference, plus a two-slot radius around both the
        /// displayed and desired page. The normal working set is at most seven hosts;
        /// capacity nine leaves room for a gesture target and one deferred destination.
        private func retainedHostIdentities(including requested: String? = nil) -> Set<String> {
            let candidates: [String?] = [shownIdentity, gestureTargetIdentity, pendingIdentity, requested]
            var retained = Set<String>(candidates.compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            })
            let centers = [slotIndex(of: shownIdentity), parent.slotIdentities.indices.contains(parent.currentIndex)
                ? parent.currentIndex
                : nil]
                .compactMap { $0 }
            for center in centers {
                for slot in (center - 2)...(center + 2) {
                    if let identity = identity(at: slot) {
                        retained.insert(identity)
                    }
                }
            }
            return retained
        }

        private func trimHostCache(preserving retained: Set<String>) {
            while hosts.count > hostCacheCapacity {
                guard let staleIndex = hostAccessOrder.firstIndex(where: {
                    hosts[$0] != nil && !retained.contains($0)
                }) else {
                    // Active UIKit references may briefly exceed the nominal capacity.
                    // Keep them; the next settled-page trim brings the cache back down.
                    return
                }
                let staleIdentity = hostAccessOrder.remove(at: staleIndex)
                hosts.removeValue(forKey: staleIdentity)
                preparedHostSizes.removeValue(forKey: staleIdentity)
            }
            hostAccessOrder.removeAll { hosts[$0] == nil }
        }

        private func removeCachedHost(_ identity: String) {
            hosts.removeValue(forKey: identity)
            preparedHostSizes.removeValue(forKey: identity)
            hostAccessOrder.removeAll { $0 == identity }
        }

        /// Returns a cached host after forcing its SwiftUI tree through an initial layout
        /// at the pager's real viewport size. This closes the lazy-host race where UIKit
        /// starts displaying a neighbour before SwiftUI has produced its first frame.
        func preparedHost(
            for identity: String,
            in pvc: UIPageViewController
        ) -> UIHostingController<AnyView>? {
            guard let host = host(for: identity) else { return nil }
            guard !isPreparingHosts else { return host }
            isPreparingHosts = true
            defer { isPreparingHosts = false }
            prepare(host, identity: identity, in: pvc)
            return host
        }

        /// Size of the pager viewport at the last settled layout. A change means the
        /// pager was resized in place (rotation, split view) rather than rebuilt.
        private var lastViewportSize: CGSize = .zero

        /// Layout hook for the live pager. Besides keeping the visible neighbourhood
        /// prepared, this detects an in-place resize: UIPageViewController's private
        /// page structure (notably .pageCurl's) keeps the DISPLAYED child at its old
        /// geometry through a rotation, so the reader showed a landscape page laid out
        /// in portrait bounds — content squeezed into half the screen, footer pushed
        /// off it. Once the new bounds settle, force the same shown-host replacement
        /// used after slot re-bases; the fresh setViewControllers makes UIKit rebuild
        /// its page structure at the new size. Deferred one runloop tick so we never
        /// swap controllers from inside UIKit's own layout pass.
        func handleViewportLayout(in pvc: UIPageViewController) {
            let size = pvc.view.bounds.size
            defer { prepareVisibleNeighborhood(in: pvc) }
            guard size.width > 0, size.height > 0 else { return }
            repinDisplayedChildIfNeeded(in: pvc)
            let previous = lastViewportSize
            lastViewportSize = size
            guard previous != .zero, previous != size, !isDismantled else { return }
            ReaderDiagnostics.shared.log(.info, "pager viewport resized", context: [
                "co": debugTag,
                "from": "\(Int(previous.width))x\(Int(previous.height))",
                "to": "\(Int(size.width))x\(Int(size.height))",
                "tree": Self.describeSubtree(of: pvc.view)
            ])
            // A rotation swallows the completion of any animated setViewControllers
            // that was in flight across it, so `isAnimating` would stay set until the
            // watchdog fires seconds later — and EVERY recovery path (neighbour
            // refresh, the re-install below) is gated on it. Measured on iOS 26: the
            // reader sat on the previous orientation's page for ~3s waiting for that
            // watchdog. The page-turn is void anyway; the reader bumps its navigation
            // epoch on rotation precisely so a landing from the old orientation cannot
            // commit. Clear the state here and let this resize re-install the page.
            if isAnimating || gestureInFlight {
                ReaderDiagnostics.shared.log(.info, "pager transition voided by resize", context: [
                    "co": debugTag,
                    "isAnimating": isAnimating ? "1" : "0",
                    "gestureInFlight": gestureInFlight ? "1" : "0",
                    "ageMs": animationStartedAt.map { String(Int($0.distance(to: Date()) * 1000)) } ?? "-"
                ])
                isAnimating = false
                gestureInFlight = false
                animationStartedAt = nil
                pendingIdentity = nil
                cancelTransitionWatchdog()
            }
            needsNeighborRefresh = true
            DispatchQueue.main.async { [weak self, weak pvc] in
                guard let self, let pvc else { return }
                self.refreshNeighborsIfNeeded(in: pvc)
            }
            startResizeEnforcement(in: pvc)
        }

        /// Identity of the host actually covering the pager's viewport, found by walking
        /// the view hierarchy rather than asking `viewControllers`. On iOS 26 pageCurl
        /// that property keeps reporting a swap as if it landed even when the page on
        /// screen never changed, which is why the earlier install verification had to be
        /// limited to .scroll. The hierarchy does not lie: whichever of our cached hosts
        /// is parented and covers the middle of the viewport is what the user sees.
        private func onScreenHostIdentity(in pvc: UIPageViewController) -> String? {
            let viewport = pvc.view.bounds
            guard viewport.width > 0, viewport.height > 0 else { return nil }
            let core = viewport.insetBy(dx: viewport.width * 0.35, dy: viewport.height * 0.35)
            for (identity, host) in hosts {
                guard let view = host.viewIfLoaded,
                      view.superview != nil,
                      !view.isHidden,
                      view.alpha > 0.01 else { continue }
                let frameInPager = view.convert(view.bounds, to: pvc.view)
                if frameInPager.contains(CGPoint(x: core.midX, y: core.midY)) {
                    return identity
                }
            }
            return nil
        }

        /// Rotation's last mile. Re-pagination for the new geometry gives the current
        /// page a new identity, and the reader installs it the usual way — but iOS 26's
        /// .pageCurl silently drops a `setViewControllers` made anywhere near the
        /// rotation window, leaving the PREVIOUS orientation's host on screen: its text
        /// is laid out for the old bounds, so the body is clipped and the footer sits
        /// entirely off screen. That is the "blank page until I turn once" report.
        ///
        /// Retry the install, verifying against the view hierarchy, until the page the
        /// reader wants is the page the user sees. Attempts are cheap (a no-op once the
        /// right host is on screen) and bounded, so a genuinely stuck pager degrades to
        /// today's behaviour instead of spinning.
        /// Deadline for the post-resize enforcement below. A second resize inside the
        /// window (rotating twice quickly) extends it instead of starting a competing
        /// polling chain. The window is the only bound on the work: the reader needs
        /// however many reinstalls it takes to outlast UIKit's swallowing, and each one
        /// that lands ends the retries immediately.
        private var resizeEnforcementDeadline: Date?

        private func startResizeEnforcement(in pvc: UIPageViewController) {
            let alreadyRunning = resizeEnforcementDeadline.map { $0 > Date() } ?? false
            resizeEnforcementDeadline = Date().addingTimeInterval(2.5)
            guard !alreadyRunning else { return }
            enforceDesiredHostAfterResize(in: pvc)
        }

        private func enforceDesiredHostAfterResize(in pvc: UIPageViewController) {
            guard !isDismantled,
                  let deadline = resizeEnforcementDeadline,
                  Date() < deadline else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak pvc] in
                guard let self, let pvc, !self.isDismantled else { return }
                // Poll for the whole window rather than stopping at the first match: the
                // page the reader wants changes again mid-window (the new orientation's
                // pagination lands, then the page index clamps), and each of those
                // installs can be swallowed in turn.
                defer { self.enforceDesiredHostAfterResize(in: pvc) }
                // A live gesture or animation owns the pager; leave UIKit's queue alone
                // and check again on the next tick.
                guard !self.isAnimating, !self.gestureInFlight,
                      pvc.transitionCoordinator == nil,
                      let desired = self.identity(at: self.parent.currentIndex) else { return }
                let onScreen = self.onScreenHostIdentity(in: pvc)
                guard onScreen != desired else {
                    self.repinDisplayedChildIfNeeded(in: pvc)
                    return
                }
                ReaderDiagnostics.shared.log(.info, "pager reinstalling after resize", context: [
                    "co": self.debugTag,
                    "onScreen": onScreen ?? "-",
                    "desired": desired,
                    "shownID": self.shownIdentity
                ])
                // Drop the cached host so it is rebuilt and laid out at the new viewport
                // size; a host prepared for the old orientation is exactly what we are
                // trying to get off the screen.
                self.removeCachedHost(desired)
                if let host = self.preparedHost(for: desired, in: pvc) {
                    self.shownIdentity = desired
                    pvc.setViewControllers([host], direction: .forward, animated: false)
                    self.repinDisplayedChildAfterInstall(in: pvc)
                    self.prepareVisibleNeighborhood(in: pvc)
                }
            }
        }

        /// Re-pins the displayed child to its container's bounds when UIKit left it at
        /// a stale geometry. iOS 26's .pageCurl does this in two situations, and BOTH
        /// end with most of the page — footer included — clipped off screen, which the
        /// field report describes as "blank page until I turn once":
        ///
        /// 1. The pager itself is resized (rotation / split view): the container
        ///    relayouts to the new bounds while the displayed child keeps its
        ///    old-orientation frame.
        /// 2. A `setViewControllers` lands right after such a resize — re-pagination
        ///    changes the page identity, so the reader always installs a fresh host
        ///    just after rotating — and curl's private page structure frames the
        ///    NEWLY installed child at the previous orientation's size. Nothing
        ///    resizes the pager again afterwards, so the layout hook never fires and
        ///    the mis-framed page stays until the user turns a page by hand.
        ///
        /// Idempotent and cheap: a no-op whenever UIKit framed the child correctly,
        /// which is every .scroll transition and most curl ones.
        @discardableResult
        func repinDisplayedChildIfNeeded(in pvc: UIPageViewController) -> Bool {
            guard !isDismantled, !isAnimating, !gestureInFlight,
                  pvc.transitionCoordinator == nil else { return false }
            // `viewControllers` is unreliable on iOS 26 pageCurl (it can keep returning a
            // stale controller), so fall back to the cached host for the shown identity —
            // the controller this coordinator last installed.
            let displayedController = pvc.viewControllers?.first ?? hosts[shownIdentity]
            guard let displayedView = displayedController?.view,
                  let container = displayedView.superview,
                  displayedView.frame != container.bounds else { return false }
            ReaderDiagnostics.shared.log(.info, "pager re-framed displayed child", context: [
                "co": debugTag,
                "from": "\(Int(displayedView.frame.width))x\(Int(displayedView.frame.height))",
                "to": "\(Int(container.bounds.width))x\(Int(container.bounds.height))"
            ])
            displayedView.frame = container.bounds
            return true
        }

        /// Post-install counterpart to `repinDisplayedChildIfNeeded`. UIKit frames a
        /// freshly installed child on its next layout pass, so an inline check would
        /// always read the not-yet-updated frame; hop one runloop turn first.
        func repinDisplayedChildAfterInstall(in pvc: UIPageViewController) {
            DispatchQueue.main.async { [weak self, weak pvc] in
                guard let self, let pvc else { return }
                self.repinDisplayedChildIfNeeded(in: pvc)
            }
        }

        /// Compact class+frame dump of the pager's view subtree for the rotation
        /// diagnostics — cheap enough to leave in, invaluable when UIKit's private
        /// page structure (snapshots, curl containers) misbehaves in the field.
        private static func describeSubtree(of view: UIView, depth: Int = 0) -> String {
            guard depth < 4 else { return "…" }
            let f = view.frame
            var line = "\(String(describing: type(of: view)))(\(Int(f.width))x\(Int(f.height))@\(Int(f.origin.x)),\(Int(f.origin.y)))\(view.isHidden ? "H" : "")"
            if depth < 3, !view.subviews.isEmpty {
                let children = view.subviews.prefix(4).map { describeSubtree(of: $0, depth: depth + 1) }
                line += "[" + children.joined(separator: " ") + (view.subviews.count > 4 ? " +\(view.subviews.count - 4)" : "") + "]"
            }
            return String(line.prefix(depth == 0 ? 900 : 400))
        }

        /// Eagerly prepare only the visible page and its adjacent neighbours. This keeps
        /// memory bounded to the same host cache while ensuring both swipe directions are
        /// ready before UIPageViewController asks for them during a gesture.
        func prepareVisibleNeighborhood(in pvc: UIPageViewController) {
            guard !isDismantled, !isPreparingHosts,
                  let shownSlot = slotIndex(of: shownIdentity) else { return }
            isPreparingHosts = true
            defer {
                isPreparingHosts = false
                trimHostCache(preserving: retainedHostIdentities())
            }
            for slot in (shownSlot - 1)...(shownSlot + 1) {
                guard let identity = identity(at: slot),
                      let host = host(for: identity) else { continue }
                prepare(host, identity: identity, in: pvc)
            }
        }

        /// Replaces the displayed host to make UIPageViewController discard its cached
        /// neighbours and ask the data source again. Re-setting the exact same controller
        /// is not a reliable invalidation: after a chapter bookend becomes page zero of the
        /// new chapter, UIKit can keep the old cached `nil` next page and every forward
        /// gesture rubber-bands on page zero. A freshly prepared, visually identical host
        /// gives UIKit an unambiguous new paging state without animating or changing the
        /// reader's position.
        ///
        /// A slot change may arrive while UIKit has a transition in flight, so this is
        /// deliberately retryable: the pending bit is cleared only after the safe refresh
        /// actually happens.
        @discardableResult
        func refreshNeighborsIfNeeded(in pvc: UIPageViewController) -> Bool {
            guard needsNeighborRefresh,
                  !isDismantled,
                  !isAnimating,
                  !gestureInFlight,
                  !isHandlingTransitionCallback,
                  let desiredID = identity(at: parent.currentIndex),
                  desiredID == shownIdentity else {
                return false
            }

            // Keep the old controller alive through `setViewControllers`; UIKit still owns
            // it as the displayed child. Removing only our cache entry ensures `host(for:)`
            // builds a new controller from the latest render closure and pagination window.
            removeCachedHost(shownIdentity)
            guard let host = preparedHost(for: shownIdentity, in: pvc) else { return false }

            needsNeighborRefresh = false
            ReaderDiagnostics.shared.log(.info, "pager neighbor refresh", context: [
                "co": debugTag,
                "shownID": shownIdentity,
                "slots": String(parent.slotIdentities.count),
                "replacedHost": "1"
            ])
            pvc.setViewControllers([host], direction: .forward, animated: false)
            verifyInstalled(host, in: pvc)
            repinDisplayedChildAfterInstall(in: pvc)
            prepareVisibleNeighborhood(in: pvc)
            return true
        }

        /// Bounded retry budget for silently-dropped non-animated setViewControllers
        /// calls. Reset whenever a swap verifiably lands.
        private var installRetriesRemaining = 8

        /// UIPageViewController can silently ignore a non-animated setViewControllers —
        /// documented here for didFinishAnimating(completed:false), and observed again
        /// around rotation: the call returns, `viewControllers` still holds the OLD
        /// host, and the reader keeps showing the old-geometry page (the "blank half
        /// page after rotating" report) while the state machine believes the swap
        /// landed. Verify the swap and, when it was dropped, re-arm the neighbor
        /// refresh a beat later — by then UIKit's transition has settled and the retry
        /// installs a freshly prepared host at the new geometry.
        ///
        /// .scroll ONLY: on iOS 26, .pageCurl's `viewControllers` does not reliably
        /// reflect a successful non-animated install (every verification read the old
        /// host back even when the swap visibly landed), so verifying there produced
        /// an endless reinstall storm. pageCurl rotation is handled through its
        /// documented contract instead — `spineLocationFor` re-installs the shown host.
        private func verifyInstalled(_ target: UIViewController, in pvc: UIPageViewController) {
            guard pvc.transitionStyle == .scroll else { return }
            if pvc.viewControllers?.first === target {
                installRetriesRemaining = 8
                return
            }
            guard installRetriesRemaining > 0, !isDismantled else { return }
            installRetriesRemaining -= 1
            needsNeighborRefresh = true
            ReaderDiagnostics.shared.log(.info, "pager install dropped — retrying", context: [
                "co": debugTag,
                "shownID": shownIdentity,
                "retriesLeft": String(installRetriesRemaining)
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak pvc] in
                guard let self, let pvc, !self.isDismantled else { return }
                self.refreshNeighborsIfNeeded(in: pvc)
            }
        }

        /// UIKit delegate/completion callbacks are still inside its transition stack.
        /// Hop one run-loop turn before retrying a deferred neighbour refresh to avoid
        /// the same duplicate-queue failure that guards requestTransition.
        private func retryNeighborRefreshAfterTransition(in pvc: UIPageViewController?) {
            guard needsNeighborRefresh, let pvc else { return }
            DispatchQueue.main.async { [weak self, weak pvc] in
                guard let self, let pvc else { return }
                self.refreshNeighborsIfNeeded(in: pvc)
            }
        }

        func cancelTransitionWatchdog() {
            transitionWatchdog?.cancel()
            transitionWatchdog = nil
        }

        /// Schedule one coalesced reconciliation pass. A genuine long-held interactive
        /// curl is detected from UIKit's gesture recognizers and simply reschedules;
        /// a lost callback with no live interaction is recovered automatically. An
        /// interaction that outlives any plausible finger-hold is force-cancelled —
        /// a pan stuck in .began/.changed for that long has lost its touch-up
        /// (interruption, incoming call UI, system gesture conflict), and without a
        /// cancel every later swipe and programmatic turn stays deferred forever.
        private func scheduleTransitionWatchdog(in pvc: UIPageViewController) {
            cancelTransitionWatchdog()
            guard !isDismantled, isAnimating || gestureInFlight else { return }

            let work = DispatchWorkItem { [weak self, weak pvc] in
                guard let self, let pvc, !self.isDismantled else { return }
                self.transitionWatchdog = nil
                if self.pagerHasActiveInteraction(pvc) {
                    let gestureAge = self.gestureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                    if gestureAge >= Self.stuckGestureRecoveryThreshold {
                        ReaderDiagnostics.shared.log(.info, "pager cancelled stuck gesture", context: [
                            "co": self.debugTag,
                            "gestureAgeMs": String(Int(gestureAge * 1_000)),
                            "shownID": self.shownIdentity
                        ])
                        // Toggling isEnabled force-cancels the recognizer; UIKit then
                        // cancels the interactive transition through the normal
                        // didFinishAnimating(completed: false) path, so the state
                        // machine unwinds without a synthetic setViewControllers.
                        for recognizer in Self.interactiveRecognizers(of: pvc)
                        where recognizer.state == .began || recognizer.state == .changed {
                            recognizer.isEnabled = false
                            recognizer.isEnabled = true
                        }
                    }
                    self.scheduleTransitionWatchdog(in: pvc)
                    return
                }
                self.recoverStaleTransitionState(in: pvc)
            }
            transitionWatchdog = work
            DispatchQueue.main.asyncAfter(deadline: .now() + transitionWatchdogDelay, execute: work)
        }

        /// A finger legitimately resting mid-curl reads the next page's peek; beyond
        /// this age the "interaction" is a recognizer that lost its touch-up.
        private static let stuckGestureRecoveryThreshold: TimeInterval = 15

        /// pageCurl exposes its recognizers on the controller; scroll keeps the pan
        /// on the internal scroll view.
        private static func interactiveRecognizers(of pvc: UIPageViewController) -> [UIGestureRecognizer] {
            var recognizers = pvc.gestureRecognizers
            if let scrollView = pvc.view.subviews.compactMap({ $0 as? UIScrollView }).first {
                recognizers.append(scrollView.panGestureRecognizer)
            }
            return recognizers
        }

        private func pagerHasActiveInteraction(_ pvc: UIPageViewController) -> Bool {
            if pvc.transitionCoordinator?.isInteractive == true { return true }
            return Self.interactiveRecognizers(of: pvc).contains {
                $0.state == .began || $0.state == .changed
            }
        }

        /// Last-resort reconciliation for missing UIKit callbacks. This collapses every
        /// queued request to the parent binding's latest desired identity, then performs
        /// one non-animated snap and one neighbour refresh. Cost is constant regardless
        /// of how many SwiftUI updates arrived while the transition was stuck.
        private func recoverStaleTransitionState(in pvc: UIPageViewController) {
            guard !isDismantled, !isHandlingTransitionCallback,
                  isAnimating || gestureInFlight else { return }

            let now = Date()
            ReaderDiagnostics.shared.log(.info, "pager recovered stale transition", context: [
                "shownID": shownIdentity,
                "desiredID": identity(at: parent.currentIndex) ?? "-",
                "animationAgeMs": animationStartedAt.map { String(Int($0.distance(to: now) * 1_000)) } ?? "-",
                "gestureAgeMs": gestureStartedAt.map { String(Int($0.distance(to: now) * 1_000)) } ?? "-",
                "pending": pendingIdentity ?? "-"
            ])

            isAnimating = false
            gestureInFlight = false
            animationStartedAt = nil
            gestureStartedAt = nil
            gestureTargetIdentity = nil
            pendingIdentity = nil

            guard let desiredID = identity(at: parent.currentIndex),
                  let target = preparedHost(for: desiredID, in: pvc) else { return }
            let displayedID = pvc.viewControllers?.first.flatMap(identity(of:))
            shownIdentity = desiredID
            if displayedID != desiredID {
                pvc.setViewControllers([target], direction: .forward, animated: false)
            }
            refreshNeighborsIfNeeded(in: pvc)
            prepareVisibleNeighborhood(in: pvc)
        }

        private func prepare(
            _ host: UIHostingController<AnyView>,
            identity: String,
            in pvc: UIPageViewController
        ) {
            let viewportSize = pvc.view.bounds.size
            guard viewportSize.width > 0, viewportSize.height > 0,
                  preparedHostSizes[identity] != viewportSize else { return }

            // A detached UIHostingController can complete Auto Layout without producing
            // a SwiftUI display frame. Give fresh neighbours a genuine containment and
            // appearance lifecycle so their render tree commits before UIKit requests
            // them. Detach immediately afterward; UIPageViewController must be the one
            // that owns the host when it begins the actual transition.
            let needsTemporaryContainment = host.parent == nil
            if needsTemporaryContainment {
                pvc.addChild(host)
                pvc.view.insertSubview(host.view, at: 0)
                host.didMove(toParent: pvc)
                host.beginAppearanceTransition(true, animated: false)
            }

            host.loadViewIfNeeded()
            host.view.frame = CGRect(origin: .zero, size: viewportSize)
            host.preferredContentSize = viewportSize
            // `sizeThatFits` evaluates the SwiftUI layout synchronously after containment.
            // Follow with UIKit layout so text and backgrounds have a complete first frame.
            _ = host.sizeThatFits(in: viewportSize)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            host.view.setNeedsDisplay()
            host.view.layer.displayIfNeeded()

            if needsTemporaryContainment {
                host.endAppearanceTransition()
                // Snapshotting after screen updates forces SwiftUI to commit the first
                // display frame while the host still has pager/window traits. The result
                // itself is discarded; the live hosting view remains cached and ready.
                _ = host.view.snapshotView(afterScreenUpdates: true)
                host.beginAppearanceTransition(false, animated: false)
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
                host.endAppearanceTransition()
            }
            preparedHostSizes[identity] = viewportSize
        }

        private func identity(of viewController: UIViewController) -> String? {
            (viewController as? ReaderPageHostingController)?.pageIdentity
        }

        func requestTransition(to identity: String, animated: Bool, in pvc: UIPageViewController) {
            // A previous animated transition (programmatic or gesture-driven) is
            // still in UIKit's animation queue; pushing another setViewControllers
            // now would crash with "Duplicate states in queue". Stash the desired
            // identity and let the completion / didFinishAnimating handler apply it
            // once the curl resolves.
            if isAnimating || gestureInFlight || isHandlingTransitionCallback {
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
            guard let target = preparedHost(for: identity, in: pvc) else { return }
            let previousID = shownIdentity
            guard previousID != identity else { return }
            activeTransitionEpoch = parent.navigationEpoch
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
                verifyInstalled(target, in: pvc)
                repinDisplayedChildAfterInstall(in: pvc)
                prepareVisibleNeighborhood(in: pvc)
                return
            }
            isAnimating = true
            animationStartedAt = Date()
            scheduleTransitionWatchdog(in: pvc)
            let startedAt = Date()
            pvc.setViewControllers([target], direction: direction, animated: true) { [weak self, weak pvc] finished in
                guard let self = self else { return }
                self.isHandlingTransitionCallback = true
                defer { self.isHandlingTransitionCallback = false }
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
                self.cancelTransitionWatchdog()
                if let pvc {
                    self.prepareVisibleNeighborhood(in: pvc)
                    self.repinDisplayedChildAfterInstall(in: pvc)
                }
                self.retryNeighborRefreshAfterTransition(in: pvc)
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
                let pending = self.pendingIdentity
                self.pendingIdentity = nil
                guard !self.isDismantled,
                      let pvc = pvc,
                      let pending,
                      pending != self.shownIdentity,
                      self.identity(at: self.parent.currentIndex) == pending else { return }
                self.applyPendingTransitionAfterCallback(pending, in: pvc)
            }
        }

        private func applyPendingTransitionAfterCallback(
            _ identity: String,
            in pvc: UIPageViewController
        ) {
            ReaderDiagnostics.shared.log(.info, "pager apply pending", context: [
                "toID": identity,
                "shownID": shownIdentity
            ])
            // Never call setViewControllers from inside a UIKit completion/delegate
            // callback. Coalesce to the latest parent binding on the next run loop.
            DispatchQueue.main.async { [weak self, weak pvc] in
                guard let self, !self.isDismantled, let pvc,
                      self.shownIdentity != identity,
                      self.identity(at: self.parent.currentIndex) == identity else { return }
                self.requestTransition(to: identity, animated: false, in: pvc)
            }
        }

        // MARK: data source

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let id = identity(of: vc), let i = slotIndex(of: id),
                  let prevID = identity(at: i - 1) else {
                logDataSourceNil(direction: "before", queried: vc)
                return nil
            }
            return preparedHost(for: prevID, in: pvc)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let id = identity(of: vc), let i = slotIndex(of: id),
                  let nextID = identity(at: i + 1) else {
                logDataSourceNil(direction: "after", queried: vc)
                return nil
            }
            return preparedHost(for: nextID, in: pvc)
        }

        /// A nil data-source answer is how UIKit decides a swipe should rubber-band.
        /// At a genuine window edge that's correct; for a page UIKit is displaying whose
        /// identity is no longer in the slot window it means the pager and the reader
        /// state have desynced — exactly the field report "翻不过去". Record which case
        /// fired so a diagnostics export can tell them apart.
        private func logDataSourceNil(direction: String, queried vc: UIViewController) {
            let queriedID = identity(of: vc) ?? "?"
            let slot = slotIndex(of: queriedID).map(String.init) ?? "MISSING"
            ReaderDiagnostics.shared.log(.info, "pager dataSource nil", context: [
                "co": debugTag,
                "dir": direction,
                "queriedID": queriedID,
                "slot": slot,
                "shownID": shownIdentity,
                "slots": String(parent.slotIdentities.count),
                "needsRefresh": needsNeighborRefresh ? "1" : "0",
                "dismantled": isDismantled ? "1" : "0",
                "updates": String(updateCount)
            ])
        }

        /// Reconcile the host cache with the current slot window. Slot identities include
        /// the complete render revision (content, typography, geometry, and theme), so an
        /// unchanged identity means its existing root view is already correct.
        ///
        /// Do not assign `host.rootView` during ordinary SwiftUI updates. A completed
        /// gesture writes the new page index back to ReaderView, which immediately calls
        /// this method; replacing the newly-landed host's root at that moment queues an
        /// asynchronous SwiftUI render and can leave UIPageViewController displaying a
        /// blank frame. Changed render inputs arrive as new identities and therefore get
        /// fresh, fully-built hosts on demand.
        /// Returns whether the slot array changed since the last refresh (caller uses this to
        /// know it must refresh UIPageViewController's cached neighbours after a re-base).
        @discardableResult
        func refreshCachedRenders() -> Bool {
            let validIDs = Set(parent.slotIdentities)
            var protectedIDs: Set<String> = shownIdentity.isEmpty ? [] : [shownIdentity]
            if let gestureTargetIdentity, !gestureTargetIdentity.isEmpty {
                protectedIDs.insert(gestureTargetIdentity)
            }
            // Snapshot keys before deletion. Mutating a Dictionary while iterating its
            // live Keys view can trap or skip entries during re-pagination.
            let staleKeys = hosts.keys.filter {
                !protectedIDs.contains($0) && !validIDs.contains($0)
            }
            for key in staleKeys {
                removeCachedHost(key)
            }
            let slotsChanged = lastSeenSlotIdentities != parent.slotIdentities
            if slotsChanged {
                needsNeighborRefresh = true
                let evictedKeys = hosts.keys.filter { !protectedIDs.contains($0) }
                for key in evictedKeys {
                    removeCachedHost(key)
                }
                lastSeenSlotIdentities = parent.slotIdentities
            }
            for host in hosts.values {
                host.view.backgroundColor = parent.backgroundColor
            }
            trimHostCache(preserving: retainedHostIdentities())
            return slotsChanged
        }

        // MARK: delegate

        /// The documented rotation contract for .pageCurl: UIKit asks for the spine
        /// location on every interface-orientation change and expects the delegate to
        /// re-install the visible controllers for the new geometry. Without this, the
        /// curl's private page structure kept the displayed child laid out for the OLD
        /// orientation — the field report's blank/half page after rotating — and
        /// setViewControllers calls made outside this callback were silently ignored
        /// while the rotation transition ran.
        func pageViewController(
            _ pageViewController: UIPageViewController,
            spineLocationFor orientation: UIInterfaceOrientation
        ) -> UIPageViewController.SpineLocation {
            if !isDismantled, let host = preparedHost(for: shownIdentity, in: pageViewController) {
                ReaderDiagnostics.shared.log(.info, "pager spine relayout", context: [
                    "co": debugTag,
                    "shownID": shownIdentity
                ])
                pageViewController.setViewControllers([host], direction: .forward, animated: false)
                repinDisplayedChildAfterInstall(in: pageViewController)
            }
            return .min
        }

        /// UIKit signals here when the user starts a swipe-driven curl. Track it so
        /// `requestTransition` can defer programmatic calls landing mid-swipe —
        /// `isAnimating` only tracks our own programmatic calls, so without this we
        /// could still stack a programmatic transition on top of a live gesture and
        /// trip UIKit's "Duplicate states in queue" assertion.
        func pageViewController(_ pvc: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            gestureInFlight = true
            gestureStartedAt = Date()
            activeTransitionEpoch = parent.navigationEpoch
            let toID = pendingViewControllers.first.flatMap { identity(of: $0) }
            gestureTargetIdentity = toID
            scheduleTransitionWatchdog(in: pvc)
            ReaderDiagnostics.shared.log(.pageTurnStart, "gesture begin", context: [
                "co": debugTag,
                "shownID": shownIdentity,
                "toID": toID ?? "?"
            ])
        }

        func pageViewController(_ pvc: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers prev: [UIViewController],
                                transitionCompleted completed: Bool) {
            isHandlingTransitionCallback = true
            defer {
                isHandlingTransitionCallback = false
                gestureTargetIdentity = nil
                if isAnimating {
                    scheduleTransitionWatchdog(in: pvc)
                } else {
                    cancelTransitionWatchdog()
                }
            }
            // `didFinishAnimating` fires for both gesture-driven and programmatic
            // transitions. Programmatic transitions also fire their own completion
            // closure (see `performTransition`); to keep our state machine
            // single-sourced we only flip `gestureInFlight` here and let the
            // completion closure handle `isAnimating`.
            let wasGesture = gestureInFlight
            gestureInFlight = false
            gestureStartedAt = nil
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
                let pending = pendingIdentity
                pendingIdentity = nil
                if !isDismantled, let pending, pending != shownIdentity {
                    ReaderDiagnostics.shared.log(.info, "pager apply pending (post-gesture)", context: [
                        "toID": pending,
                        "shownID": shownIdentity
                    ])
                    DispatchQueue.main.async { [weak self, weak pvc] in
                        guard let self = self, !self.isDismantled, let pvc = pvc,
                              self.shownIdentity != pending,
                              self.identity(at: self.parent.currentIndex) == pending else { return }
                        self.requestTransition(to: pending, animated: false, in: pvc)
                    }
                }
                retryNeighborRefreshAfterTransition(in: pvc)
                return
            }
            let fromID = shownIdentity
            shownIdentity = landedID
            // A landing whose transition began before an explicit navigation is stale:
            // the jump already chose the destination, and this landing's page may now
            // be a cross-chapter bookend of the NEW window — writing it back or
            // committing it would drag the reader across a boundary they didn't turn.
            // shownIdentity is still updated above (UIKit really is displaying this
            // page); the deferred/desired snap moves the display to the jump target.
            let staleEpoch = activeTransitionEpoch != parent.navigationEpoch
            if !staleEpoch, let slot = slotIndex(of: landedID), parent.currentIndex != slot {
                // Binding sync for body slots; the custom binding on the continuous path
                // ignores bookend indices, so this never writes an out-of-range page.
                parent.currentIndex = slot
            }
            ReaderDiagnostics.shared.log(.pageTurnEnd, wasGesture ? "gesture" : "didFinishAnimating", context: [
                "co": debugTag,
                "fromID": fromID,
                "toID": landedID,
                "slots": String(parent.slotIdentities.count),
                "staleEpoch": staleEpoch ? "1" : "0"
            ])
            // Commit a cross-chapter bookend landing (re-bases the slot window). For body
            // landings this is a no-op. Called AFTER the binding sync so the page index is
            // already settled for the body case.
            if !staleEpoch {
                parent.onCommit(landedID)
            }
            prepareVisibleNeighborhood(in: pvc)
            repinDisplayedChildAfterInstall(in: pvc)
            retryNeighborRefreshAfterTransition(in: pvc)
            // Apply any pending programmatic target stashed during the transition.
            let pending = pendingIdentity
            pendingIdentity = nil
            if let pending,
               pending != shownIdentity,
               identity(at: parent.currentIndex) == pending {
                applyPendingTransitionAfterCallback(pending, in: pvc)
            }
        }
    }
}
