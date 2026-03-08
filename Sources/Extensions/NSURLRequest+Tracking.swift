//
//  NSURLRequest+Tracking.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import ObjectiveC

private var requestIdKey: UInt8 = 0
private var startTimeKey: UInt8 = 0

@objc extension NSURLRequest {

    @objc var requestId: String? {
        get {
            return objc_getAssociatedObject(self, &requestIdKey) as? String
        }
        set {
            objc_setAssociatedObject(self, &requestIdKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        }
    }

    @objc var startTime: NSNumber? {
        get {
            return objc_getAssociatedObject(self, &startTimeKey) as? NSNumber
        }
        set {
            objc_setAssociatedObject(self, &startTimeKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
