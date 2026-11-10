//
//  SwiftyDebugViewController.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

class SwiftyDebugViewController: UIViewController {

    var bubble = Bubble(frame: CGRect(origin: .zero, size: Bubble.size))

    override func loadView() {
        view = BubbleContainerView()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        // Without `super`, nothing this controller presents is told the size is
        // changing — a presented debug UI misses the rotation entirely, which is
        // what left the media pager showing a black screen after a rotate.
        super.viewWillTransition(to: size, with: coordinator)
        // Only while the bubble is on screen. A full-screen debug UI takes this
        // view out of the window, where its bounds go stale and its safe area
        // reads zero — a remap from those would rewrite the dock. When the UI is
        // dismissed the view is laid out again and `redockBubble()` puts the
        // bubble back from its untouched dock.
        if view.window != nil {
            bubble.updateOrientation(newSize: size)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .clear

        // Parked off-screen until the first layout pass docks it. There is no
        // size to dock against yet — the window gets its size from the scene it
        // is attached to — and a bubble left at the origin would claim the
        // top-left corner's touches (`shouldReceive(point:)`) in the meantime.
        bubble.frame.origin = CGPoint(x: -Bubble.size.width * 2, y: -Bubble.size.height * 2)
        bubble.delegate = self
        view.addSubview(bubble)
        view.forceLTR()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        redockBubble()
    }

    /// Puts the bubble back on its edge for the view's current size and safe
    /// area. Runs on every layout, which is what keeps the bubble on the edge of
    /// the inner display after an unfold and clear of iPhone Duo's vertical bar
    /// whichever side it is on.
    ///
    /// Skipped while the view is out of a window: a full-screen presentation
    /// takes this view out of the hierarchy, and with no window its safe area
    /// reads zero, which would dock the bubble underneath the vertical bar. It is
    /// laid out again — with the real safe area — when the presentation ends.
    func redockBubble() {
        guard isViewLoaded, view.window != nil else { return }
        bubble.redock(in: view.bounds,
                      safeArea: view.safeAreaInsets,
                      avoiding: Bubble.reservedRects(in: view))
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
        // The debug UI is presented full-screen inside this window, so it opens at
        // whatever size the window has. Make sure that is the scene's size now.
        (view.window as? SwiftyDebugWindow)?.fitToScene()
        let vc = SwiftyDebugTabBarController()
        vc.view.backgroundColor = .white
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true) {
            DebugWindowPresenter.shared.displayedList = true
        }
    }
}

// MARK: - Root view

/// The overlay window's root view: the bubble's container.
///
/// Exists for one job. On iPhone Duo (iOS 27.1) the fold of a partially folded
/// device is a reserved region, and it can become active without anything else
/// changing — no resize, no rotation, no safe-area change — so no layout pass
/// would ever move the bubble off it. UIKit tracks the reserved regions a view
/// reads in `updateConstraints()` and calls it again when they change; reading
/// them there and invalidating layout on a change is what re-docks the bubble.
final class BubbleContainerView: UIView {

    private var lastReservedRects: [CGRect] = []

    override class var requiresConstraintBasedLayout: Bool { true }

    override func updateConstraints() {
        let rects = Bubble.reservedRects(in: self)
        if rects != lastReservedRects {
            lastReservedRects = rects
            setNeedsLayout()
        }
        super.updateConstraints()
    }
}
