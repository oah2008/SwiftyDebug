//
//  BaseRepo.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 10/03/2026.
//

import SwiftyNetworkIOS
import Factory

class BaseRepo {

    @Injected(Container.api) internal var api: APIResult

    func makeModelRequest<T: NetworkModel>(model:T.Type, endPoint:EndpointInfo, parameters:[String: Any] = [String: Any]()) async -> APIResult.Result<T>? {
        Logger.debug("request with endPoint : \(endPoint)")
        let requset = NetworkRequest(endpoint: endPoint, parameters: parameters)
        let result = await api.request(requset, model: T.self)
        return result
    }
}
