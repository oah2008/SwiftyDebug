//
//  SwiftyDebugBackButton.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 19/09/2026.
//

import UIKit

/// The SDK's own back button, used instead of UIKit's.
///
/// ## Why the system back indicator could not be fixed
///
/// Setting `backIndicatorImage` to a geometric glyph (`chevron.left`, whose asset
/// has no right-to-left variant and whose `flipsForRightToLeftLayoutDirection` is
/// false) was supposed to make mirroring impossible. Measured on a pushed bar
/// inside an SDK window, it does not: UIKit does not install the image it is
/// given. It installs a copy produced by `imageFlippedForRightToLeftLayoutDirection()`,
/// and the image view in the bar reports `flipsForRightToLeftLayoutDirection == true`
/// however the image arrived. Whether the arrow points the right way therefore
/// comes back down to the direction resolved by a **private** image view that
/// UIKit creates on push — after `viewDidLoad`, with no override of its own,
/// inheriting through a chain whose only trait pin (`traitOverrides`) does not
/// exist before iOS 17.
///
/// ## What this does instead
///
/// Owns the control outright. The arrow is **rasterised once** into a plain
/// bitmap with `.alwaysOriginal` rendering: a bitmap has no direction-aware
/// variant to resolve and no flipping flag for UIKit to turn back on, so there is
/// nothing left that can mirror it on any iOS version. The button also re-pins
/// itself and its image view on every layout pass, so a rebuild after a push or a
/// pop cannot reintroduce the host's direction.
final class SwiftyDebugBackButton: UIButton {

    /// Rasterised from `chevron.left` once per process. Rendering it through
    /// `UIGraphicsImageRenderer` discards the symbol's direction-aware asset set;
    /// `.alwaysOriginal` stops UIKit re-templating it.
    private static let arrowImage: UIImage? = {
        let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        guard let symbol = UIImage(systemName: "chevron.left", withConfiguration: configuration) else {
            return nil
        }
        // Resolve the glyph in an explicitly left-to-right trait collection so the
        // bitmap is drawn from the LTR asset even when the process is RTL.
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(layoutDirection: .leftToRight),
            UITraitCollection(userInterfaceStyle: .dark),
        ])
        let resolved = symbol.withConfiguration(configuration).imageAsset?
            .image(with: traits) ?? symbol

        // Drawn in the accent colour, and stamped `.alwaysOriginal` so UIKit does
        // not re-tint it. `.alwaysOriginal` also means `tintColor` cannot reach
        // it, so the colour has to be baked in here — painting it white left a
        // white chevron next to a teal "Back", the only mismatched control in the
        // bar.
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 0                       // 0 = the device's natural scale
        let renderer = UIGraphicsImageRenderer(size: resolved.size, format: format)
        let flat = renderer.image { _ in
            resolved.withTintColor(DebugTheme.accentColor, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(origin: .zero, size: resolved.size))
        }
        return flat.withRenderingMode(.alwaysOriginal)
    }()

    /// Apple's minimum comfortable touch target. A bar button item built from a
    /// custom view takes that view's own bounds as its hit area, and `sizeToFit`
    /// on an image-plus-17pt-title yields barely 22pt of height — so taps just
    /// above or below the word "Back" fell through to the bar and did nothing.
    private static let minimumTouchTarget = CGSize(width: 44, height: 44)

    /// Deliberately built with the plain target-action API and NOT
    /// `UIButton.Configuration`.
    ///
    /// Measured: a configuration-based button does not dispatch through
    /// `sendActions(for:)` even with the target-action pair registered
    /// (`actions(forTarget:forControlEvent:)` reports it, and nothing runs). A
    /// back button that might not fire is not a trade worth making for the newer
    /// layout API, and it also means the behaviour can be asserted by a test
    /// rather than only by tapping.
    init(title: String?, target: Any?, action: Selector) {
        super.init(frame: .zero)
        setImage(Self.arrowImage, for: .normal)
        setTitle(title, for: .normal)
        setTitleColor(DebugTheme.accentColor, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 17)
        tintColor = DebugTheme.accentColor
        contentHorizontalAlignment = .left
        imageView?.contentMode = .scaleAspectFit
        addTarget(target, action: action, for: .touchUpInside)

        accessibilityLabel = "Back"
        sizeToFit()
        frame.size = CGSize(width: max(frame.width, Self.minimumTouchTarget.width),
                            height: max(frame.height, Self.minimumTouchTarget.height))
        pinLeftToRight()
    }

    /// The bar sizes a custom view from this, so the touch target survives layout.
    override var intrinsicContentSize: CGSize {
        let natural = super.intrinsicContentSize
        return CGSize(width: max(natural.width, Self.minimumTouchTarget.width),
                      height: max(natural.height, Self.minimumTouchTarget.height))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// UIKit rebuilds a bar button's internals on push, pop and rotation, so the
    /// pin has to be re-asserted rather than applied once at construction.
    override func layoutSubviews() {
        super.layoutSubviews()
        pinLeftToRight()
        imageView?.pinLeftToRight()
    }
}
