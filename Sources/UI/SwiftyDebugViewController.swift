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
        if DebugWindowPresenter.shared.displayedList {
            return true
        }
        return bubble.frame.contains(point)
    }
}

//MARK: - BubbleDelegate
extension SwiftyDebugViewController: BubbleDelegate {

    func didTapBubble() {
        DebugWindowPresenter.shared.displayedList = true
        let vc = SwiftyDebugTabBarController()
        vc.view.backgroundColor = .white
        vc.modalPresentationStyle = .fullScreen
        self.present(vc, animated: true, completion: nil)
    }
}
