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

    /// Whether this device uses the Dynamic Island pill instead of the floating bubble
    let usesDynamicIsland = DynamicIslandBubble.deviceHasDynamicIsland

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        if !usesDynamicIsland {
            bubble.updateOrientation(newSize: size)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .clear

        if usesDynamicIsland {
            // Use Dynamic Island pill — hide regular bubble
            let island = DynamicIslandBubble(frame: .zero)
            island.delegate = self
            view.addSubview(island)
            island.pinToTop(of: view)
            dynamicIslandBubble = island
        } else {
            // Use regular floating bubble
            bubble.center = Bubble.originalPosition
            bubble.delegate = self
            view.addSubview(bubble)
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
