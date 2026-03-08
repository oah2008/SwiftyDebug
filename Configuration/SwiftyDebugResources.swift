//
//  SwiftyDebugResources.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 08/03/2026.
//

import Foundation

enum SwiftyDebugResources {
    static let bundle: Bundle = {
        #if SWIFT_PACKAGE
        return .module
        #else
        return Bundle(for: Settings.self)
        #endif
    }()
}
