import SwiftUI
import UIKit

@main
struct LingyueApp: App {
    init() {
        Self.configureNavigationBarAppearance()
        Self.configureTabBarAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    /// Softens the iOS-default navigation-title typography app-wide. UIKit ships large
    /// titles at a near-`.black` weight and pure-black/white tint, which reads as too
    /// aggressive over our soft paper / blush / ink backgrounds. We keep the SF system
    /// face (no custom font) but drop the weight to `.semibold` and swap the tint for
    /// a warm near-black in light mode and warm off-white in dark mode, matching the
    /// chrome's `primaryText` palette. The color is a dynamic `UIColor` so it follows
    /// the trait collection — including the per-window `preferredColorScheme` overrides
    /// each `AppTheme` applies.
    ///
    /// On iOS < 26 we use two appearances so the bar reads differently depending on
    /// scroll position:
    ///   • `scrollEdgeAppearance` (at the top): fully transparent — themed background
    ///     bleeds up to the status bar, matching iOS 26's Liquid Glass at-rest look.
    ///   • `standardAppearance` (scrolled): no blur, just a tinted overlay (~55%
    ///     white / 50% black depending on appearance). UIKit's `.systemUltraThinMaterial`
    ///     is the lightest *blurred* material it ships, and even that frosts more than
    ///     we want here — a plain alpha tint lets the themed background bleed through
    ///     more aggressively than any system material while keeping the title legible
    ///     over arbitrary scrolling content underneath.
    /// iOS 26 keeps `configureWithDefaultBackground()` for both so native Liquid Glass
    /// applies.
    private static func configureNavigationBarAppearance() {
        let titleColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.94, green: 0.92, blue: 0.85, alpha: 1.0)
                : UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1.0)
        }
        let largeTitleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
            .foregroundColor: titleColor
        ]
        let inlineTitleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: titleColor
        ]

        let standardAppearance = UINavigationBarAppearance()
        standardAppearance.configureWithDefaultBackground()
        if #unavailable(iOS 26) {
            standardAppearance.configureWithTransparentBackground()
            standardAppearance.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.black.withAlphaComponent(0.50)
                    : UIColor.white.withAlphaComponent(0.55)
            }
            standardAppearance.shadowColor = .clear
        }
        standardAppearance.largeTitleTextAttributes = largeTitleAttributes
        standardAppearance.titleTextAttributes = inlineTitleAttributes

        let scrollEdgeAppearance = UINavigationBarAppearance()
        if #available(iOS 26, *) {
            scrollEdgeAppearance.configureWithDefaultBackground()
        } else {
            scrollEdgeAppearance.configureWithTransparentBackground()
            scrollEdgeAppearance.backgroundColor = .clear
            scrollEdgeAppearance.shadowColor = .clear
        }
        scrollEdgeAppearance.largeTitleTextAttributes = largeTitleAttributes
        scrollEdgeAppearance.titleTextAttributes = inlineTitleAttributes

        let proxy = UINavigationBar.appearance()
        proxy.standardAppearance = standardAppearance
        proxy.scrollEdgeAppearance = scrollEdgeAppearance
        proxy.compactAppearance = standardAppearance
        proxy.compactScrollEdgeAppearance = scrollEdgeAppearance
    }

    /// Matches the nav-bar treatment for the tab bar: keep the default background's
    /// internal layout (icons + labels stay centered in the standard content area
    /// above the home-indicator safe area, same as every other iOS 18 app) but
    /// override just the visual fill with an `.systemThinMaterial` blur so the
    /// themed background shows through. We deliberately use a heavier material than
    /// the nav-bar scrolled appearance (`.systemUltraThinMaterial`) so the bottom
    /// reads as a slightly more grounded surface than the top — the tab icons need
    /// a bit more frosting to stay legible over arbitrary scrolling content, while
    /// the nav bar mostly sits over the large title. iOS 26 uses its native Liquid
    /// Glass instead.
    private static func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        if #unavailable(iOS 26) {
            appearance.backgroundEffect = UIBlurEffect(style: .systemThinMaterial)
            appearance.backgroundColor = .clear
            appearance.shadowColor = .clear
        }

        let proxy = UITabBar.appearance()
        proxy.standardAppearance = appearance
        proxy.scrollEdgeAppearance = appearance
    }
}
