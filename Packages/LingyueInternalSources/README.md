# LingyueInternalSources

Internal-only fast-path adapters and seeded rule bundles for sources whose
names cannot appear in the App Store binary. The `LingyueAppStore` target
does **not** depend on this package — the boundary is compile-time, not a
naming convention.

## What lives here

- Hand-written `BookSource` conformers for sources that need bespoke
  parsing the rule engine can't yet express (header-stitched cookies,
  multi-step search forms, custom decoders).
- Seeded `SourceRule` bundles shipped pre-installed in the Internal /
  TestFlight builds.
- `FixtureManifest.json` — neutral fixture IDs (`source-a`, `source-b`)
  mapped back to real hostnames, kept out of `LingyueCore` and out of the
  test fixture filenames so the App Store target's compile output cannot
  reference real source names.
- An `InternalSourceRegistry` that merges these internal sources with the
  user's rule-driven sources from `EditableSourceStore` and presents the
  union to the rest of the app via `BookSourceRegistry`.

## Why a separate package

The App Store posture is "user-supplied rules are data, the app is a
generic interpreter." That story breaks immediately if grep over the App
Store binary turns up specific Chinese-novel host strings or seeded URL
templates. Moving those into a separate SPM target that the App Store app
doesn't link guarantees they can't be in that binary — no review-time
arguments about what `#if INTERNAL` actually compiled.
