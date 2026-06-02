# LingyueCore

Shared core for the source / rule / parsing engine. Owns:

- The `BookSource`, `BookSourceRegistry`, `EditableSourceStore`, and
  `SourceHTMLLoading` protocols.
- The `SourceRule` schema and all value types crossing the protocol surface
  (`BookSearchResult`, `BookDetail`, `ChapterLink`, `ChapterContent`, …).
- The rule engine and parsing primitives (Phase 1+).
- A pinned SwiftSoup dependency for CSS-selector-based HTML parsing.

## Dependency rule

This package is the **only** rule-engine module the app target depends on.

- `LingyueAppStore` (the app target) **depends on LingyueCore only**.

Anything that names a specific external source — host strings, seeded
catalog rules — is data, not code: it lives in the out-of-band
`docs/lingyue-sources.json` bundle the user imports at runtime, never in
the binary. `LingyueCore`'s engine is fully generic, so the App Store
build ships no site-specific URLs.

## Platform purity

`LingyueCore` must remain free of `UIKit` / `WebKit` / `AppKit` imports.
HTML fetching and rendering are abstracted behind the
`SourceHTMLLoading` protocol; concrete adapters that wrap `URLSession`
and `WKWebView` live in the app target. This keeps Core unit-testable
with stub loaders and free of platform-specific main-actor coupling.
