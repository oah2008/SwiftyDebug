//
//  DebugWindowPresenter.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

public class DebugWindowPresenter: NSObject {
    public static let shared = DebugWindowPresenter()

    var window: SwiftyDebugWindow
    var displayedList = false
    lazy var vc = SwiftyDebugViewController() //must lazy init, otherwise crash

    private override init() {
        // No size yet, on purpose. The window takes its size from the scene it is
        // attached to (`SwiftyDebugWindow.fitToScene()`), and there is no scene
        // when the host calls `enable()` from `didFinishLaunching`. Sizing it from
        // `UIScreen.main` here is what made it the OUTER display's size on iPhone
        // Duo for the whole session, wherever the app was actually running.
        window = SwiftyDebugWindow(frame: .zero)
        super.init()
    }


    public func enable() {
        // A window whose scene has gone still has `vc` as its root: UIKit nils
        // `windowScene` when that scene disconnects (an iPad window closed) and
        // the overlay stops rendering, so returning on the root alone made every
        // later `enable()` — including `SwiftyDebug.enable()` and every
        // `bubbleVisible = true` — a silent no-op, with the debug UI unreachable
        // until the app was relaunched. Re-entry has to be able to re-attach.
        if window.rootViewController == vc, window.windowScene != nil {
            // Already attached: just make sure it still fits its scene.
            window.fitToScene()
            return
        }

        window.rootViewController = vc
        window.delegate = self
        window.isHidden = false
        // Covers a window UIKit has already attached to a scene by itself (apps
        // without a scene manifest), where the scene search below can come back
        // empty. Otherwise a no-op until the scene is assigned.
        window.fitToScene()

        var success: Bool = false

        for i in 0...10 {
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + (0.1 * Double(i))) {[weak self] in
                if success == true {return}

                // One scene, picked the way BreakpointOverlay.show() picks it.
                // `connectedScenes` is an unordered Set, so assigning every scene
                // it iterates left the window attached to whichever came last —
                // nondeterministically, and possibly a background one, which on
                // a multi-window iPad put the bubble in the window the user was
                // not looking at. `return` here leaves `success` false so the
                // later retries still fire.
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                        ?? scenes.first else { return }
                self?.window.windowScene = scene
                success = true
            }
        }
    }


    public func disable() {
        if window.rootViewController == nil {
            return
        }
        // Dismiss FIRST. `vc` is a `lazy var` on a singleton, so it lives for the
        // whole process — and while it has a `presentedViewController`, so does
        // everything that tree holds: the tab bar, every pushed screen, and
        // whatever those screens reference. Nilling the window's root only drops
        // the WINDOW's reference; the presentation relationship survives it, so
        // the debug UI was stranded on `vc` until the app was killed.
        //
        // Not animated: this runs from `disable()` / `fullStop()`, where the
        // point is that nothing of the SDK is left running.
        if let presented = vc.presentedViewController {
            presented.dismiss(animated: false)
        }
        displayedList = false
        window.rootViewController = nil
        window.delegate = nil
        window.isHidden = true
    }
}
