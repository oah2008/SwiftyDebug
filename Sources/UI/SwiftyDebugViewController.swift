//
//  SwiftyDebugViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

class SwiftyDebugViewController: UIViewController {

    var bubble = Bubble(frame: CGRect(origin: .zero, size: Bubble.size))
    var dynamicIslandBubble: DynamicIslandBubble?

    /// Whether this device uses the Dynamic Island pill instead of the floating bubble.
    /// Determined after safe area insets are available.
    private(set) var usesDynamicIsland = false
    private var hasConfiguredBubbleType = false

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .clear

        // Always add the regular bubble first as a fallback.
        // It will be removed if we detect Dynamic Island later.
        bubble.center = Bubble.originalPosition
        bubble.delegate = self
        view.addSubview(bubble)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        configureBubbleTypeIfNeeded()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        if !usesDynamicIsland {
            bubble.updateOrientation(newSize: size)
        }
    }

    /// Called once when safe area insets become available.
    /// Swaps the regular bubble for a Dynamic Island pill on supported devices.
    private func configureBubbleTypeIfNeeded() {
        guard !hasConfiguredBubbleType else { return }

        let safeTop = view.safeAreaInsets.top
        // Safe area not available yet — wait for next call
        guard safeTop > 0 else { return }

        hasConfiguredBubbleType = true

        // Dynamic Island devices have safe area top >= 55pt
        // (notch devices have ~47pt, non-notch ~20pt)
        if safeTop >= 55 {
            usesDynamicIsland = true

            // Remove the regular bubble
            bubble.removeFromSuperview()

            // Add the Dynamic Island pill
            let island = DynamicIslandBubble(frame: .zero)
            island.delegate = self
            view.addSubview(island)
            island.pinToTop(of: view)
            dynamicIslandBubble = island
        }
    }

    func shouldReceive(point: CGPoint) -> Bool {
        if DebugWindowPresenter.shared.displayedList {
            return true
        }
        if usesDynamicIsland, let island = dynamicIslandBubble {
            return island.frame.contains(point)
        }
        return bubble.frame.contains(point)
    }
}

//MARK: - BubbleDelegate
extension SwiftyDebugViewController: BubbleDelegate {

    func didTapBubble() {
        presentDebugUI()
    }
}

// MARK: - DynamicIslandBubbleDelegate
extension SwiftyDebugViewController: DynamicIslandBubbleDelegate {

    func didTapDynamicIsland() {
        presentDebugUI()
    }
}

// MARK: - Private
private extension SwiftyDebugViewController {

    func presentDebugUI() {
        DebugWindowPresenter.shared.displayedList = true
        let vc = SwiftyDebugTabBarController()
        vc.view.backgroundColor = .white
        vc.modalPresentationStyle = .fullScreen
        self.present(vc, animated: true, completion: nil)
    }
}
