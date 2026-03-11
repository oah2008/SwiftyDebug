//
//  PokemonUI.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

enum PokemonUIActions {
    case selectPokemon(item:PokemonListItem)
    case refresh
}

protocol PokemonUIDelegate:AnyObject {
    func doActions(_ actions: PokemonUIActions)
}

class PokemonUI: BaseUI {

    weak var delegate:PokemonUIDelegate?

    private var pokemonList:[PokemonListItem] = []

    private let refreshControl = UIRefreshControl()

    private lazy var collectionView: UICollectionView = {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: configureLayout())
        cv.backgroundColor = .systemGroupedBackground
        cv.showsVerticalScrollIndicator = false
        cv.alwaysBounceVertical = true
        cv.register(PokemonCell.self, forCellWithReuseIdentifier: PokemonCell.reuseId)
        cv.delegate = self
        cv.dataSource = self
        return cv
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUIElements()
        setupConstraints()
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setupUIElements() {
        super.setupUIElements()
        uiHolderView.addSubview(collectionView)
        collectionView.refreshControl = refreshControl
    }

    override func setupConstraints() {
        super.setupConstraints()
        collectionView.anchor([.fill(uiHolderView)])
    }

    func setupList(_ list:[PokemonListItem]) {
        self.pokemonList = list
        refreshControl.endRefreshing()
        collectionView.reloadData()
    }

    func endRefreshing() {
        refreshControl.endRefreshing()
    }

    @objc private func refresh() {
        delegate?.doActions(.refresh)
    }

    private func configureLayout() -> UICollectionViewLayout {
        let config = UICollectionViewCompositionalLayoutConfiguration()
        config.scrollDirection = .vertical

        let sectionProvider = { (sectionIndex: Int, layoutEnvironment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / 3.0), heightDimension: .estimated(140))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            item.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(140))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 4
            section.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
            return section
        }
        return UICollectionViewCompositionalLayout(sectionProvider: sectionProvider, configuration: config)
    }
}

extension PokemonUI: UICollectionViewDataSource {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        pokemonList.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PokemonCell.reuseId, for: indexPath) as! PokemonCell
        let item = pokemonList[indexPath.item]
        cell.setupCell(model: item)
        return cell
    }
}

extension PokemonUI: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        delegate?.doActions(.selectPokemon(item: pokemonList[indexPath.item]))
    }

}
