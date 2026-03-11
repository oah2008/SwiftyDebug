//
//  PokemonRepo.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 10/03/2026.
//

import SwiftyNetworkIOS

class PokemonRepo: BaseRepo {

    func fetchList(limit:Int = 40) async -> APIResult.Result<PokemonListResponse>? {
        let endpoint = PokemonEndPoint.list(limit: limit)
        let result = await makeModelRequest(model: PokemonListResponse.self, endPoint: endpoint.info)
        return result
    }

    func fetchDetail(name:String) async -> APIResult.Result<PokemonDetail>? {
        let endpoint = PokemonEndPoint.detail(name: name)
        let result = await makeModelRequest(model: PokemonDetail.self, endPoint: endpoint.info)
        return result
    }
}
