//
//  PokemonEndPoint.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 10/03/2026.
//

import SwiftyNetworkIOS

enum PokemonEndPoint {
    case list(limit:Int)
    case detail(name:String)
}

extension PokemonEndPoint: NetworkEndpoints {

    private static let baseUrl = "https://pokeapi.co/api/v2/"

    var info: EndpointInfo {
        switch self {
        case .list(let limit):
            return .init("pokemon?limit=\(limit)", .get, customBaseUrl: PokemonEndPoint.baseUrl)
        case .detail(let name):
            return .init("pokemon/\(name)", .get, customBaseUrl: PokemonEndPoint.baseUrl)
        }
    }
}
