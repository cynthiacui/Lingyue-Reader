import SwiftUI
import UIKit

@main
struct LingyueApp: App {
    init() {
        Self.configureNavigationBarTypography()
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
    private static func configureNavigationBarTypography() {
        let titleColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.94, green: 0.92, blue: 0.85, alpha: 1.0)
                : UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1.0)
        }

        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.largeTitleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
            .foregroundColor: titleColor
        ]
        appearance.titleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: titleColor
        ]

        let proxy = UINavigationBar.appearance()
        proxy.standardAppearance = appearance
        proxy.scrollEdgeAppearance = appearance
        proxy.compactAppearance = appearance
        proxy.compactScrollEdgeAppearance = appearance
    }
}
