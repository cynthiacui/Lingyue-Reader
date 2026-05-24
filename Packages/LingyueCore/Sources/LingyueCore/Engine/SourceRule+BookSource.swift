import Foundation

/// Routes a rule to the correct engine at registry-build time. The default
/// path is `RuleBasedBookSource` — HTML scraping driven by the rule's
/// `detection` / `detail` / `catalog` / `chapter` steps. When the rule
/// carries a `jsonAPI` block, the route swaps in `JSONAPIBookSource`
/// instead, which reads its endpoint templates, ID extractors, JSON
/// paths, and body transforms from that block alone.
///
/// The App Store target relies on this: the imported JSON carries
/// every site-specific detail, so the binary stays free of hard-coded
/// URLs while still being able to drive the source the moment its rule
/// lands in the editable store.
public extension SourceRule {
    func makeBookSource(loader: any SourceHTMLLoading) -> any BookSource {
        if let config = jsonAPI {
            return JSONAPIBookSource(rule: self, config: config, loader: loader)
        }
        return RuleBasedBookSource(rule: self, loader: loader)
    }
}
