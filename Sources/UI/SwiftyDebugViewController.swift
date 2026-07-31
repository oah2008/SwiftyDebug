//
//  SwiftyDebugViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

class SwiftyDebugViewController: UIViewController {

    var bubble = Bubble(frame: CGRect(origin: .zero, size: Bubble.size))

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        bubble.updateOrientation(newSize: size)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .clear

        bubble.center = Bubble.originalPosition
        bubble.delegate = self
        view.addSubview(bubble)
        view.forceLTR()
    }

    func shouldReceive(point: CGPoint) -> Bool {
        // The flag alone is NOT enough. It was set before `present`, so a
        // presentation that never happened (no window yet) left it stuck true —
        // and this method then claimed every touch on the screen, leaving the
        // host app completely dead except for a 25x25 bubble, with no escape but
        // a relaunch. Require something to actually BE presented.
        if DebugWindowPresenter.shared.displayedList, presentedViewController != nil {
            return true
        }
        return bubble.frame.contains(point)
    }
}

//MARK: - BubbleDelegate
extension SwiftyDebugViewController: BubbleDelegate {

    func didTapBubble() {
        // Only claim the screen for a presentation that can actually succeed, and
        // only once it is under way. Setting the flag first and presenting into
        // nothing is what soft-locked the host app.
        guard view.window != nil, presentedViewController == nil else { return }
        let vc = SwiftyDebugTabBarController()
        vc.view.backgroundColor = .white
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true) {
            DebugWindowPresenter.shared.displayedList = true
        }
    }
}
