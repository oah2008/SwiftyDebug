//
//  PokemonViewController.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

class PokemonViewController: BaseVC<PokemonVM, PokemonUI> {

    override func viewDidLoad() {
        super.viewDidLoad()
        viewModel.delegate = self
        ui.delegate = self
        viewModel.loadPokemon()
    }
}

extension PokemonViewController: PokemonUIDelegate {

    func doActions(_ actions: PokemonUIActions) {
        switch actions {
        case .selectPokemon(let item):
            let vc = PokemonDetailViewController(item: item)
            navigationController?.pushViewController(vc, animated: true)
        case .refresh:
            viewModel.loadPokemon()
        }
    }
}

extension PokemonViewController: PokemonVMDelegate {

    func doActions(_ actions: PokemonVMActions) {
        switch actions {
        case .didFetchList(let list):
            ui.setupList(list)
        case .onError:
            ui.endRefreshing()
        }
    }
}
