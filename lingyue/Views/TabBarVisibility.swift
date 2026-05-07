import SwiftUI
import UIKit

/// Toggles the host UITabBarController's tab bar visibility synchronously via UIKit, bypassing
/// SwiftUI's `.toolbar(.hidden, for: .tabBar)` which on iOS 17 fades the tab bar back in only
/// after the navigation pop animation completes — visibly delayed for the user.
///
/// `viewDidAppear` hides the tab bar; `viewWillDisappear` shows it again, which fires before
/// the pop animation has finished, so the tab bar is already in place when Library is revealed.
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        tabBarController?.tabBar.isHidden = targetHidden
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        tabBarController?.tabBar.isHidden = false
    }

    func applyIfVisible() {
        guard isViewLoaded, view.window != nil else { return }
        tabBarController?.tabBar.isHidden = targetHidden
    }
}
