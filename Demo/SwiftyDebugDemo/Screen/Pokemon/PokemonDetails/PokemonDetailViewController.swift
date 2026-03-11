//
//  PokemonDetailViewController.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

class PokemonDetailViewController: BaseVC<PokemonDetailVM, PokemonDetailUI> {

    private let item:PokemonListItem

    init(item:PokemonListItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
        title = (item.name ?? "").capitalized
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        viewModel.delegate = self
        viewModel.load(item: item)
    }
}

extension PokemonDetailViewController: PokemonDetailVMDelegate {

    func doActions(_ actions: PokemonDetailVMActions) {
        switch actions {
        case .didFetchDetail(let detail):
            ui.applyDetail(detail, spriteURL: item.spriteURL)
        }
    }
}
