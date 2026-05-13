# LingyueCore

Shared core for the source / rule / parsing engine. Owns:

- The `BookSource`, `BookSourceRegistry`, `EditableSourceStore`, and
  `SourceHTMLLoading` protocols.
- The `SourceRule` schema and all value types crossing the protocol surface
  (`BookSearchResult`, `BookDetail`, `ChapterLink`, `ChapterContent`, …).
- The rule engine and parsing primitives (Phase 1+).
- A pinned SwiftSoup dependency for CSS-selector-based HTML parsing.

## Dependency rule

This package is the **only** rule-engine module the App Store target depends on.

- `LingyueAppStore` (App Store app target) **depends on LingyueCore only**.
- `LingyueInternal` (internal/TestFlight app target) depends on
  `LingyueCore` **and** `LingyueInternalSources`.

Anything that names a specific external source — host strings, seeded
catalog rules, fast-path adapters — lives in `LingyueInternalSources`,
not here. This is a structural guarantee: code outside `LingyueCore`
cannot accidentally leak into the App Store binary because the App Store
target has no edge to that module.

## Platform purity

`LingyueCore` must remain free of `UIKit` / `WebKit` / `AppKit` imports.
HTML fetching and rendering are abstracted behind the
`SourceHTMLLoading` protocol; concrete adapters that wrap `URLSession`
and `WKWebView` live in the app target. This keeps Core unit-testable
with stub loaders and free of platform-specific main-actor coupling.
