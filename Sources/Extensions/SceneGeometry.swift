//
//  SceneGeometry.swift
//  SwiftyDebug
//
//  The one place SwiftyDebug asks "how much space does the UI have right now".
//

import UIKit

/// Display geometry for SwiftyDebug, read from a window scene — never from
/// `UIScreen.main`.
///
/// `UIScreen.main` is the device's built-in display, which is a fixed answer to a
/// question whose answer keeps changing. On iPhone Duo it is always the OUTER
/// panel (466 x 678 pt) — measured on the iPhone Duo simulator, whether the app is
/// running on the outer display or on the 951 x 669 inner one. Every size the SDK
/// took from it was therefore the outer display's: the overlay window opened at
/// that size on the inner display and never filled it, and the floating bubble
/// docked against an "edge" that sat in the middle of the unfolded screen.
///
/// A window scene is the space the app has actually been given. It follows the
/// fold, rotation, Split View, Stage Manager and iPad multitasking, which is why
/// every answer here comes from one.
enum SceneGeometry {

    /// The bounds of `scene` in its own (interface-oriented) coordinate space.
    static func bounds(of scene: UIWindowScene) -> CGRect {
        if #available(iOS 26.0, *) {
            return scene.effectiveGeometry.coordinateSpace.bounds
        }
        return scene.coordinateSpace.bounds
    }

    /// The scene SwiftyDebug's UI is on.
    ///
    /// The overlay window's own scene when it has one, otherwise the app's
    /// foreground-active scene, otherwise any scene. Deliberately does not touch
    /// `DebugWindowPresenter.shared`: asking for geometry must never be what
    /// creates the SDK's window.
    static var currentScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let sdkScene = scenes.first(where: { scene in
            scene.windows.contains { $0 is SwiftyDebugWindow }
        }) {
            return sdkScene
        }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }

    /// The bounds of the scene `view` is shown in, else of `currentScene`.
    ///
    /// Prefer this to `currentBounds` whenever a view is at hand: a view knows
    /// exactly which scene — and therefore which display — it is on.
    static func bounds(for view: UIView?) -> CGRect {
        if let scene = view?.window?.windowScene {
            return bounds(of: scene)
        }
        return currentBounds
    }

    /// The bounds of `currentScene`.
    ///
    /// Falls back to `UIScreen.main` only when the app has no window scene at all
    /// — before the first scene connects, or in a test host without one. There is
    /// no UI on screen to size in that state, so the fallback cannot misplace any.
    static var currentBounds: CGRect {
        if let scene = currentScene {
            return bounds(of: scene)
        }
        return UIScreen.main.bounds
    }

    /// The display scale of the screen `view` is on, else of `currentScene`.
    ///
    /// Both iPhone Duo panels are 3x today, but scale is a property of a display,
    /// and the SDK should not depend on the two happening to agree.
    static func scale(for view: UIView? = nil) -> CGFloat {
        if let scale = view?.window?.traitCollection.displayScale, scale > 0 {
            return scale
        }
        if let scale = currentScene?.traitCollection.displayScale, scale > 0 {
            return scale
        }
        return UIScreen.main.scale
    }
}
