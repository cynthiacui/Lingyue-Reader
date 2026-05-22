import SwiftUI
import UIKit

/// Toggles the host UITabBarController's tab bar visibility synchronously via UIKit, bypassing
/// SwiftUI's `.toolbar(.hidden, for: .tabBar)` which on iOS 17 fades the tab bar back in only
/// after the navigation pop animation completes — visibly delayed for the user.
///
/// `viewWillAppear` hides the tab bar (fires *before* the push animation starts, so the bar is
/// gone as the reader slides in); `viewWillDisappear` shows it again, which fires before
/// the pop animation has finished, so the tab bar is already in place when Library is revealed.
///
/// iPad iOS 18+ renders the tabs as a floating tab bar / sidebar that the legacy
/// `tabBar.isHidden` toggle no longer reaches. Use the iOS 18 `setTabBarHidden(_:animated:)`
/// API when available so the reader hides both presentations.
struct TabBarVisibility: UIViewControllerRepresentable {
    let isHidden: Bool

    func makeUIViewController(context: Context) -> TabBarVisibilityController {
        let vc = TabBarVisibilityController()
        vc.targetHidden = isHidden
        return vc
    }

    func updateUIViewController(_ vc: TabBarVisibilityController, context: Context) {
        vc.targetHidden = isHidden
        vc.applyIfVisible()
    }
}

final class TabBarVisibilityController: UIViewController {
    var targetHidden = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        apply(targetHidden)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        apply(false)
    }

    func applyIfVisible() {
        guard isViewLoaded, view.window != nil, tabBarController != nil else { return }
        apply(targetHidden)
    }

    private func apply(_ hidden: Bool) {
        guard let tabBarController else { return }
        if #available(iOS 18.0, *) {
            tabBarController.setTabBarHidden(hidden, animated: false)
        } else {
            tabBarController.tabBar.isHidden = hidden
        }
    }
}
