//
//  APIErrors.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 10/03/2026.
//

import Foundation

enum APIErrors: Equatable {

    static func == (lhs: APIErrors, rhs: APIErrors) -> Bool {
        lhs.statusCode() == rhs.statusCode()
    }

    case notFound
    case clientError(_ status:Int)
    case serverError(_ status:Int)
    case unknownError(_ status:Int)
    case explicitlyCancelled
    case decodeError(_ status:Int, _ data:Data?)

    func errorMessage() -> String? {
        switch self {
        case .explicitlyCancelled:
            return nil
        default:
            return "Something went wrong"
        }
    }

    func statusCode() -> Int? {
        switch self {
        case .notFound:
            return 404
        case .clientError(let status), .serverError(let status), .unknownError(let status):
            return status
        case .explicitlyCancelled:
            return -1
        case .decodeError(let status, _):
            return status
        }
    }
}
