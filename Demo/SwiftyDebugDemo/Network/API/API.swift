//
//  API.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 10/03/2026.
//

import SwiftyNetworkIOS
import Factory
import Alamofire

typealias APIResult = BaseAPI<RequestAdapter>

class RequestAdapter: APIRequestAdapter {

    func requestValidator(networkEndpoints:NetworkEndpoints?, _ requsetInfo: EndpointInfo, _ data: Data?, _ httpRespnes: HTTPURLResponse?, _ failuerReson: String?, _ afError: AFError?) -> APIErrors? {
        let statusCode = httpRespnes?.statusCode ?? afError?.responseCode ?? 0

        switch afError {
        case .explicitlyCancelled:
            return .explicitlyCancelled
        default:break
        }

        switch statusCode {
        case 200...299:
            return .decodeError(statusCode, data)
        case 404:
            return .notFound
        case 400...499:
            return .clientError(statusCode)
        case 500...599:
            return .serverError(statusCode)
        default:
            break
        }
        return .unknownError(statusCode)
    }

    func retry(networkEndpoints:NetworkEndpoints?, _ requsetInfo: EndpointInfo, _ AFrequest: Request, _ error: Error, isAfterRefresh: Bool) -> RetryResult {
        return .doNotRetry
    }

    func refreshToken(networkEndpoints:NetworkEndpoints?, requsetInfo: EndpointInfo) async -> APIErrors? {
        return nil
    }

    func adapt(networkEndpoints:NetworkEndpoints?, _ requsetInfo: EndpointInfo, _ urlRequest: URLRequest, completion: @escaping (URLRequest?) -> Void) {
        completion(urlRequest)
    }
}


extension Container {

    static var api = Factory(scope: .singleton) {
        BaseAPI(baseUrl: "https://jsonplaceholder.typicode.com/", headers: [:], logLevel: .debug, requestAdapter: RequestAdapter())
    }
}
