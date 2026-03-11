//
//  PokemonHeroCell.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 11/03/2026.
//

import UIKit
import SwiftyConstraint

class PokemonHeroCell: PokemonDetailBaseCell {

    static let reuseId = String(describing: PokemonHeroCell.self)

    private let heroImageView:BaseImageView = {
        let iv = BaseImageView()
        iv.contentMode = .scaleAspectFit
        iv.layer.cornerRadius = 20
        iv.clipsToBounds = true
        iv.backgroundColor = .secondarySystemBackground
        return iv
    }()

    private let activityIndicator:UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.startAnimating()
        return indicator
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUIElement()
        setupConstaints()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setupUIElement() {
        super.setupUIElement()
        contentView.addSubview(heroImageView)
        heroImageView.addSubview(activityIndicator)
    }

    override func setupConstaints() {
        super.setupConstaints()
        heroImageView.anchor([.fill(contentView), .height(220)])
        activityIndicator.anchor([.center(heroImageView)])
    }

    override func setupCell(item:PokemonDetailItemType) {
        super.setupCell(item: item)
        guard case .heroImage(let url, let color) = item else{return}
        heroImageView.loadImage(url: url)
        heroImageView.backgroundColor = color.withAlphaComponent(0.12)
        activityIndicator.stopAnimating()
    }
}
