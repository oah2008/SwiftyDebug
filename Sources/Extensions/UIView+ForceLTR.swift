//
//  UIView+ForceLTR.swift
//  SwiftyDebug
//
//  Everything that keeps SwiftyDebug laid out left-to-right inside a host app
//  that runs right-to-left. The window base class lives in this file rather than
//  its own because it *is* this concern, and both SDK windows need it.
//

import UIKit

// MARK: - The one place SwiftyDebug's layout direction is decided

/// Base class for every window SwiftyDebug puts on screen.
///
/// ## Why the previous approach leaked
///
/// Two independent UIKit mechanisms decide direction, and the SDK was only
/// addressing one of them, snapshot-style:
///
/// **1. `semanticContentAttribute`** drives leading/trailing layout. A host app
/// forces RTL with `UIView.appearance().semanticContentAttribute = .forceRightToLeft`.
/// UIKit applies that proxy to every view as it moves into a window, and it fills
/// in every view that has not set the property itself. (Measured: a view that set
/// it explicitly before entering the window keeps its value; an untouched view is
/// stamped `.forceRightToLeft`.) `forceLTR()` only stamps the subtree that exists
/// at the instant it is called — in practice `viewDidLoad` — so every cell,
/// header, alert and lazily created subview born after that point came back RTL.
/// Inheritance could not rescue them either: with the host's proxy installed a
/// view is never `.unspecified`, so it never inherits the SDK window's direction.
///
/// **2. The `layoutDirection` trait** decides which *image* UIKit resolves for
/// direction-aware assets. The navigation bar's back chevron is `chevron.backward`,
/// picked from the trait collection and **not** from `semanticContentAttribute` —
/// which is exactly why forcing the bar's semantic attribute moved the button back
/// to the left edge but left the glyph pointing the wrong way. The same applies to
/// any `UIImage.imageFlippedForRightToLeftLayoutDirection` and to the edge the
/// interactive-pop gesture watches.
///
/// ## The fix
///
/// This one class owns both, for everything it hosts:
///
/// * A `UIAppearance` proxy scoped to this window class. Containment beats plain
///   class specificity, so it wins over the host's global `UIView.appearance()`
///   (measured: it wins even against a host `UILabel.appearance()`), and UIKit
///   applies it itself as each view enters the window — so views created long
///   after any sweep are covered with no sweep at all.
/// * A `layoutDirection` trait pinned to `.leftToRight`, propagated to every
///   hosted view controller, view and presented sheet.
///
/// The host app is untouched: the proxy is scoped by containment to SDK windows
/// and the trait override lives on those windows only.
class SwiftyDebugHostingWindow: UIWindow {

    /// Registered once, lazily, the first time any SDK window is created — which
    /// is always before an SDK view exists, so nothing can slip in ahead of it.
    private static let appearanceProxyInstalled: Void = {
        UIView.appearance(whenContainedInInstancesOf: [SwiftyDebugHostingWindow.self])
            .semanticContentAttribute = .forceLeftToRight
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        applyForcedLTR()
    }

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        applyForcedLTR()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyForcedLTR() {
        _ = Self.appearanceProxyInstalled
        semanticContentAttribute = .forceLeftToRight
        if #available(iOS 17.0, *) {
            traitOverrides.layoutDirection = .leftToRight
        }
    }

    /// Pre-iOS-17 there is no supported way to override a trait for a whole
    /// window, so fall back to the old `traitCollection` override — which does
    /// still propagate to descendants. From iOS 17 `traitOverrides` above is the
    /// supported mechanism and this must stay out of its way.
    override var traitCollection: UITraitCollection {
        if #available(iOS 17.0, *) { return super.traitCollection }
        return Self.legacyLayoutDirectionTraits(base: super.traitCollection)
    }

    /// The pre-iOS-17 composition, factored out so it can be exercised by tests on
    /// any OS. The override above is unreachable on a modern simulator, which is
    /// how it stayed untested.
    static func legacyLayoutDirectionTraits(base: UITraitCollection) -> UITraitCollection {
        UITraitCollection(traitsFrom: [base, UITraitCollection(layoutDirection: .leftToRight)])
    }

    // MARK: - Audit

    private var didAuditLayoutDirection = false

    override func layoutSubviews() {
        super.layoutSubviews()
        auditLayoutDirectionOnce()
    }

    /// Forced LTR is invisible when it works and equally invisible when it fails —
    /// the exact shape of silent no-op this codebase keeps shipping. If a host app
    /// still wins, say so once, out loud, instead of quietly rendering mirrored.
    private func auditLayoutDirectionOnce() {
        guard !didAuditLayoutDirection, let root = rootViewController?.view, root.window === self else { return }
        didAuditLayoutDirection = true

        let semanticIsLTR = root.effectiveUserInterfaceLayoutDirection == .leftToRight
        let traitIsLTR = root.traitCollection.layoutDirection != .rightToLeft
        if semanticIsLTR && traitIsLTR { return }

        NSLog("""
              [SwiftyDebug] Forced left-to-right layout did NOT take effect in \
              \(type(of: self)) (semanticContentAttribute=\(root.semanticContentAttribute.rawValue), \
              effective=\(root.effectiveUserInterfaceLayoutDirection.rawValue), \
              layoutDirection trait=\(root.traitCollection.layoutDirection.rawValue)). \
              The debug UI will render mirrored. This usually means the host app \
              installed a UIAppearance rule more specific than SwiftyDebug's.
              """)
    }
}

// MARK: - Manual sweep

extension UIView {

    /// Forces left-to-right on this view and everything currently beneath it.
    ///
    /// This is a **snapshot**: it cannot reach subviews that do not exist yet, so
    /// it is not the guarantee. The guarantee is `SwiftyDebugHostingWindow`, which
    /// covers every view that ever enters an SDK window, whenever it is created.
    /// Keep calling this for views assembled before they are hosted (it settles
    /// their geometry one layout pass earlier) and for anything built outside an
    /// SDK window.
    func forceLTR() {
        // The semantic attribute alone does not move the `layoutDirection` trait,
        // and direction-aware images resolve from the trait — pin both.
        //
        // `traitOverrides.layoutDirection` RAISES NSInternalInconsistencyException
        // ("Can't return value for trait LayoutDirection that has no override")
        // when nothing has been overridden yet, so `contains` has to be checked
        // first and the `||` has to short-circuit. Reading it directly crashes.
        if #available(iOS 17.0, *) {
            if !traitOverrides.contains(UITraitLayoutDirection.self)
                || traitOverrides.layoutDirection != .leftToRight {
                traitOverrides.layoutDirection = .leftToRight
            }
        }
        forceLTRSemantics()
    }

    private func forceLTRSemantics() {
        if semanticContentAttribute != .forceLeftToRight {
            semanticContentAttribute = .forceLeftToRight
        }
        for subview in subviews {
            subview.forceLTRSemantics()
        }
    }
}
