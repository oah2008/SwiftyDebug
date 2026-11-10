//
//  SwiftyDebugWindow.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit


/// Forced left-to-right layout — including the `layoutDirection` trait the nav
/// bar's back chevron is resolved from — is inherited from
/// `SwiftyDebugHostingWindow`. See UIView+ForceLTR.swift; do not re-implement it
/// here.
///
/// ## Size
///
/// The window always covers the scene it is attached to, one ulp short in height
/// (see `overlayFrame(forSceneBounds:)`), and it re-fits itself every time that
/// scene's geometry changes.
///
/// It used to be created as `SwiftyDebugWindow(frame: UIScreen.main.bounds)` and
/// never resized. On iPhone Duo `UIScreen.main` is always the outer panel, so the
/// window was born 466 x 678 pt; and because it is deliberately *not* exactly
/// scene-sized, UIKit does not resize it when the scene moves to the 951 x 669
/// inner display. The debug UI therefore opened at the outer display's size in a
/// corner of the unfolded screen and stayed that way, and the bubble docked
/// against an edge that was really the middle of the screen. Measured on the
/// iPhone Duo simulator: the scene's `effectiveGeometry` is key-value observable
/// and fires on every rotation, which is what drives the re-fit below.
class SwiftyDebugWindow: SwiftyDebugHostingWindow {

    weak var delegate: WindowDelegate?

    /// Live while the window is attached to a scene; replaced on every attach.
    private var sceneGeometryObservation: NSKeyValueObservation?

    /// The scene `sceneGeometryObservation` watches.
    private weak var observedScene: UIWindowScene?

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.backgroundColor = .clear
        self.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)

        // In an app without a scene manifest UIKit attaches a new window to the
        // app's scene by itself, inside `init`, without going through the
        // `windowScene` setter — so `didSet` below never runs for it. Measured in
        // the test host: a `SwiftyDebugWindow(frame: .zero)` comes back with a
        // scene and, until this, kept its zero size.
        fitToScene()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Never claim a point outside the window itself. While the debug UI is
        // up the delegate answers yes to every point, and if the window were ever
        // smaller than its scene that would swallow touches beyond its edges.
        guard bounds.contains(point) else { return false }
        return self.delegate?.isPointEvent(point: point) ?? false
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Backstop for the resizes the geometry observation cannot see (it needs
        // iOS 16): a size-class change means the scene was resized. Here on the
        // window, not on a view controller — the window stays in the trait
        // hierarchy whatever is presented in it, while the root controller's view
        // is taken out of it by every full-screen presentation.
        fitToScene()
    }

    // MARK: - Tracking the scene

    override var windowScene: UIWindowScene? {
        didSet {
            observeSceneGeometry()
            fitToScene()
        }
    }

    /// Re-fits the window whenever its scene's geometry changes: the device
    /// folding or unfolding (the scene moves to the other display), rotating,
    /// entering Split View, or any other resize.
    ///
    /// `effectiveGeometry` is iOS 16+. Before that there is no fold to follow and
    /// rotation already resizes the window; `traitCollectionDidChange` above
    /// re-fits on size-class changes as the backstop for the remaining resizes.
    private func observeSceneGeometry() {
        sceneGeometryObservation = nil
        observedScene = windowScene
        guard let scene = windowScene else { return }
        if #available(iOS 16.0, *) {
            sceneGeometryObservation = scene.observe(\.effectiveGeometry, options: []) { [weak self] _, _ in
                // UIKit changes the geometry on the main thread and KVO calls back
                // synchronously on it. Re-fitting right here, rather than one
                // runloop later, lets the window resize in the same transaction as
                // the host app's own windows.
                if Thread.isMainThread {
                    self?.fitToScene()
                } else {
                    DispatchQueue.main.async { self?.fitToScene() }
                }
            }
        }
    }

    /// Sizes the window to the scene it is attached to. A no-op without a scene,
    /// and when the window already fits — so it never fights a resize UIKit is
    /// animating itself, such as a rotation.
    func fitToScene() {
        guard let scene = windowScene else { return }
        // A scene UIKit attached on its own never went through the setter, so
        // it may not be observed yet. Start watching it here.
        if observedScene !== scene {
            observeSceneGeometry()
        }
        let target = Self.overlayFrame(forSceneBounds: SceneGeometry.bounds(of: scene))
        guard target.width > 0, target.height > 0,
              !Self.isApproximatelyEqual(frame, target) else { return }
        frame = target
    }

    /// The frame the overlay window takes in a scene with `sceneBounds`.
    ///
    /// The full scene, one ulp short of its height. A window that exactly covers
    /// its scene counts as full-screen to UIKit, and the topmost full-screen
    /// window is the one whose root view controller decides the status bar style,
    /// the supported interface orientations and — from iOS 27.1 — whether the
    /// vertical bar is used. At `UIWindow.Level.alert - 1` that would be this
    /// window, taking all three away from the host app. One ulp is invisible and
    /// keeps them with the app.
    static func overlayFrame(forSceneBounds sceneBounds: CGRect) -> CGRect {
        CGRect(x: sceneBounds.minX,
               y: sceneBounds.minY,
               width: sceneBounds.width,
               height: sceneBounds.height.nextDown)
    }

    /// Frames within half a point are the same frame: the deliberate one-ulp
    /// height and any rounding UIKit applies must not trigger a re-fit.
    static func isApproximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}

extension DebugWindowPresenter: WindowDelegate {
    func isPointEvent(point: CGPoint) -> Bool {
        return self.vc.shouldReceive(point: point)
    }
}
