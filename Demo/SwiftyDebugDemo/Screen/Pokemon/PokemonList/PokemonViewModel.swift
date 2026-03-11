//
//  PokemonViewModel.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation
import SwiftyNetworkIOS
import Factory

enum PokemonVMActions {
    case didFetchList(list:[PokemonListItem])
    case onError
}

@MainActor protocol PokemonVMDelegate:AnyObject {
    func doActions(_ actions: PokemonVMActions)
}

class PokemonVM: BaseVM {

    @Injected(RepoContainer.pokemonRepo) private var pokemonRepo:PokemonRepo
    private var pokemonList:[PokemonListItem] = []
    weak var delegate:PokemonVMDelegate?

    required init() {
        super.init()
    }

    func loadPokemon() {
        Task { [weak self] in
            guard let self else{return}
            Logger.debug("Fetching Pokemon list...")
            let result = await makeAwaitRequst({ [weak self] in await self?.pokemonRepo.fetchList() })
            guard case .onSuccess(let response, _) = result, let response else {
                Logger.error("Pokemon fetch failed")
                await delegate?.doActions(.onError)
                return
            }
            self.pokemonList = response.results ?? []
            Logger.debug("Loaded \(self.pokemonList.count) Pokemon")
            await delegate?.doActions(.didFetchList(list: self.pokemonList))
        }
    }
}
