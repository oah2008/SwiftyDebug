//
//  UIView+ForceLTR.swift
//  SwiftyDebug
//
//  Forces all SwiftyDebug views to LTR layout regardless of host app RTL settings.
//

import UIKit

extension UIView {
    /// Recursively forces Left-to-Right layout on this view and all descendants.
    func forceLTR() {
        semanticContentAttribute = .forceLeftToRight
        for subview in subviews {
            subview.forceLTR()
        }
    }
}
