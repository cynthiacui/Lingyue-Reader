import SwiftUI

/// App-wide interface language: when enabled, every piece of UI chrome (tab titles,
/// buttons, section headers, alerts, placeholders…) renders in traditional Chinese.
///
/// The app's source strings are written in simplified Chinese and conversion is fully
/// mechanical, so rather than maintaining a parallel zh-Hant strings table we convert
/// at view-construction time via the initializer shadows below. Reader *content*
/// conversion stays on its own key (`reader.usesTraditionalChinese`) so the in-reader
/// quick toggle keeps working without tearing down the view tree; the 外观主题 master
/// toggle sets both keys together.
///
/// Anything rendered through the shadows is converted when this flag flips, but the
/// text is baked in when a `Text` is created — `ContentView` re-keys the root view
/// tree with `.id(...)` on this flag so every screen rebuilds with the new language.
enum AppUILanguage {
    static let storageKey = "app.usesTraditionalChineseInterface"

    static var usesTraditionalChinese: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }

    /// Pass-through when the interface language is simplified (the source scripts'
    /// native form), so the default path costs nothing per `Text`.
    static func display(_ text: String) -> String {
        usesTraditionalChinese ? ChineseTextConverter.traditional(text) : text
    }
}

// MARK: - Initializer shadows
//
// Swift resolves a string literal to a concrete `String` parameter in preference to
// any other `ExpressibleByStringLiteral` type (and a concrete overload in preference
// to a `StringProtocol` generic), so declaring these `String` overloads makes every
// existing `Text("…")` / `Label("…", systemImage:)` / `Button("…")` call site in this
// module route through `AppUILanguage.display` — without touching the call sites and
// without new strings being able to forget the conversion. Each shadow delegates to a
// differently-shaped SwiftUI initializer (`verbatim:` / builder closures), so none of
// them can recurse into itself.
//
// Deliberately NOT shadowed: `Text(verbatim:)` (explicit opt-out used by the stats
// number formatting) and the `Date`/`AttributedString` initializers.

extension Text {
    init(_ content: String) {
        self.init(verbatim: AppUILanguage.display(content))
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, systemImage name: String) {
        self.init(
            title: { Text(verbatim: AppUILanguage.display(title)) },
            icon: { Image(systemName: name) }
        )
    }
}

extension Button where Label == Text {
    init(_ title: String, action: @escaping @MainActor () -> Void) {
        self.init(action: action) {
            Text(verbatim: AppUILanguage.display(title))
        }
    }

    init(_ title: String, role: ButtonRole?, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) {
            Text(verbatim: AppUILanguage.display(title))
        }
    }
}

extension Toggle where Label == Text {
    init(_ title: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) {
            Text(verbatim: AppUILanguage.display(title))
        }
    }
}

extension Picker where Label == Text {
    init(
        _ title: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> Content
    ) {
        self.init(selection: selection, content: content) {
            Text(verbatim: AppUILanguage.display(title))
        }
    }
}

extension TextField where Label == Text {
    /// Converts the visible placeholder. The unconverted title stays on the label so
    /// the field's accessibility name matches the source string.
    init(_ title: String, text: Binding<String>) {
        self.init(title, text: text, prompt: Text(verbatim: AppUILanguage.display(title)))
    }
}

extension Section where Parent == Text, Content: View, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(verbatim: AppUILanguage.display(title)) })
    }
}

extension LabeledContent where Label == Text, Content: View {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, label: { Text(verbatim: AppUILanguage.display(title)) })
    }
}

extension View {
    func navigationTitle(_ title: String) -> some View {
        navigationTitle(Text(verbatim: AppUILanguage.display(title)))
    }
}
