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
class SwiftyDebugWindow: SwiftyDebugHostingWindow {

    weak var delegate: WindowDelegate?

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.backgroundColor = .clear
        self.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return self.delegate?.isPointEvent(point: point) ?? false
    }
}

extension DebugWindowPresenter: WindowDelegate {
    func isPointEvent(point: CGPoint) -> Bool {
        return self.vc.shouldReceive(point: point)
    }
}
