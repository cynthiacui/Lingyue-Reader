import Foundation
import SwiftSoup

/// CSS-selector-driven extraction over a parsed SwiftSoup `Document` or
/// `Element`. Glue between `FieldSelector` (data) and the actual DOM
/// (runtime). Returns post-transform strings, ready for downstream value
/// types.
///
/// Two kinds of resolution:
/// - `resolveSingle` returns the first match (or the page-as-a-whole
///   when the selector is nil).
/// - `resolveAll` returns every match — used for tag lists and the
///   chapter-list inner loop.
///
/// `nil` selector means "operate on the scope as-is" — text of the
/// whole document, or the raw HTML for a regex-only extraction.
public enum SelectorEngine {
    /// Parse `html` into a SwiftSoup `Document` with `baseURL` as the
    /// document's base URI. Setting the base URI is what makes
    /// `Element.attr("abs:href")` work, but the engine resolves URLs
    /// explicitly via `.absoluteURL` transform — `baseURL` here is
    /// mainly informational.
    public static func parse(_ html: String, baseURL: URL) throws -> Document {
        do {
            return try SwiftSoup.parse(html, baseURL.absoluteString)
        } catch {
            throw BookSourceError.parseFailed(field: "html document")
        }
    }

    /// Resolve a single field selector against a scope element.
    /// `scope` is typically the whole document for top-level selectors,
    /// or a single element (a search-result row, a chapter row) for
    /// nested selectors.
    ///
    /// Returns `nil` when the selector resolves to no elements and no
    /// transforms can recover a value. Returns an empty string for
    /// transforms that intentionally erase the value.
    public static func resolveSingle(
        _ field: FieldSelector,
        scope: Element,
        baseURL: URL
    ) throws -> String? {
        let raw: String
        if let selector = field.selector {
            guard let element = try firstSelected(selector, in: scope) else {
                return nil
            }
            raw = try extract(from: element, attribute: field.attribute)
        } else {
            raw = try extract(from: scope, attribute: field.attribute)
        }
        let transformed = try TransformApplier.apply(
            field.transforms,
            to: raw,
            baseURL: baseURL
        )
        return transformed
    }

    /// Resolve a field selector that may match multiple elements. Used
    /// for tag lists and any iteration-style extraction.
    public static func resolveAll(
        _ field: FieldSelector,
        scope: Element,
        baseURL: URL
    ) throws -> [String] {
        guard let selector = field.selector else {
            // No selector → single "page-as-a-whole" value.
            if let v = try resolveSingle(field, scope: scope, baseURL: baseURL) {
                return [v]
            }
            return []
        }
        let elements: Elements
        do {
            elements = try scope.select(selector)
        } catch {
            throw BookSourceError.parseFailed(field: "selector \(selector)")
        }
        var result: [String] = []
        result.reserveCapacity(elements.size())
        for element in elements {
            let raw = try extract(from: element, attribute: field.attribute)
            let transformed = try TransformApplier.apply(
                field.transforms,
                to: raw,
                baseURL: baseURL
            )
            if !transformed.isEmpty {
                result.append(transformed)
            }
        }
        return result
    }

    /// Run a top-level selector and return every matching element,
    /// caller-owned. Used by `RuleBasedBookSource` to walk search-result
    /// rows and chapter-row lists before applying nested selectors.
    public static func selectAll(
        _ selector: String,
        in document: Document
    ) throws -> Elements {
        do {
            return try document.select(selector)
        } catch {
            throw BookSourceError.parseFailed(field: "selector \(selector)")
        }
    }

    // MARK: -

    private static func firstSelected(
        _ selector: String,
        in scope: Element
    ) throws -> Element? {
        let elements: Elements
        do {
            elements = try scope.select(selector)
        } catch {
            throw BookSourceError.parseFailed(field: "selector \(selector)")
        }
        return elements.first()
    }

    private static func extract(from element: Element, attribute: String?) throws -> String {
        do {
            if let attribute, !attribute.isEmpty, attribute != "text" {
                if attribute == "html" {
                    return try element.html()
                }
                if attribute == "outerHTML" {
                    return try element.outerHtml()
                }
                return try element.attr(attribute)
            }
            return try element.text()
        } catch {
            throw BookSourceError.parseFailed(field: "extract \(attribute ?? "text")")
        }
    }
}
