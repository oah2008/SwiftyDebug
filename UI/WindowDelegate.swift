//
//  WindowDelegate.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

protocol WindowDelegate: AnyObject {
    func isPointEvent(point: CGPoint) -> Bool
}
