//
//  PokemonDetailViewModel.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation
import SwiftyNetworkIOS
import Factory

enum PokemonDetailVMActions {
    case didFetchDetail(detail:PokemonDetail)
}

@MainActor protocol PokemonDetailVMDelegate:AnyObject {
    func doActions(_ actions: PokemonDetailVMActions)
}

class PokemonDetailVM: BaseVM {

    @Injected(RepoContainer.pokemonRepo) private var pokemonRepo:PokemonRepo

    weak var delegate:PokemonDetailVMDelegate?

    required init() {
        super.init()
    }

    func load(item:PokemonListItem) {

        guard let name = item.name else{return}
        Task { [weak self] in
            guard let self else{return}
            Logger.debug("Fetching \(name) details...")
            let result = await makeAwaitRequst({ [weak self] in await self?.pokemonRepo.fetchDetail(name: name) })
            guard case .onSuccess(let detail, _) = result, let detail else{return}
            Logger.debug("\((detail.name ?? "").capitalized) — type: \(detail.typeNames.joined(separator: "/"))")
            await delegate?.doActions(.didFetchDetail(detail: detail))
        }
    }
}
