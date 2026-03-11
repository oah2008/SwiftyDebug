//
//  BaseVM.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation
import SwiftyNetworkIOS

class BaseVM {

    required init() {}

    deinit {
        Logger.deinits(String(describing: type(of: self)))
    }

    func makeAwaitRequst<T: NetworkModel>(_ requset: () async -> APIResult.Result<T>?) async -> APIResult.Result<T>? {
        let result = await requset()
        return result
    }
}
