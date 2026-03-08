//
//  NetworkMonitor.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation
import UIKit

class NetworkMonitor: NSObject {

    var isNetworkEnable: Bool = false

    static let shared = NetworkMonitor()

    private override init() {
        super.init()
        isNetworkEnable = false
    }

    func enable() {
        if isNetworkEnable {
            return
        }
        isNetworkEnable = true
        CustomHTTPProtocol.start()
    }

    func disable() {
        if !isNetworkEnable {
            return
        }
        isNetworkEnable = false
        CustomHTTPProtocol.stop()
    }
}
