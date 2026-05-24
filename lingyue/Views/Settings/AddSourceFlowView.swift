import SwiftUI

/// Phase 6.1 — wrapper that gates `AddSourceURLView` behind the IP
/// attestation onboarding on the App Store target. Hosted from
/// `SourcesListView`'s "+" sheet; the gate fires once per install,
/// persisted as `@AppStorage("onboarding.ipAttestationAccepted")`.
///
/// On the Internal target the gate is compile-time-disabled — Internal
/// ships with a seeded rule library and the "you are the source of the
/// rules" framing of the attestation copy doesn't apply.
///
/// Implemented as an `if`-branched view tree inside a single
/// `NavigationStack` (provided by the parent sheet): when the user
/// accepts, the parent's `@AppStorage` flag flips and SwiftUI swaps
/// the inner view to `AddSourceURLView`. The nav bar title /
/// toolbar items pick up from whichever view is current. We don't
/// `NavigationPath`-push from attestation to the form because the
/// gate is one-time — once accepted, the attestation screen never
/// renders again, so there's no "back to onboarding" to preserve.
struct AddSourceFlowView: View {
    @AppStorage("onboarding.ipAttestationAccepted") private var ipAttestationAccepted = false

    let onComplete: () -> Void

    private var requiresAttestation: Bool {
        return !ipAttestationAccepted
    }

    var body: some View {
        if requiresAttestation {
            IPAttestationView(onAccept: {
                ipAttestationAccepted = true
            })
        } else {
            AddSourceURLView(onComplete: onComplete)
        }
    }
}
