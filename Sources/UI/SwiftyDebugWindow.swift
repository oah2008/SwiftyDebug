//
//  SwiftyDebugWindow.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit


class SwiftyDebugWindow: UIWindow {
    
    weak var delegate: WindowDelegate?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        self.backgroundColor = .clear
        self.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        self.semanticContentAttribute = .forceLeftToRight
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override var traitCollection: UITraitCollection {
        UITraitCollection(traitsFrom: [super.traitCollection, UITraitCollection(layoutDirection: .leftToRight)])
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
