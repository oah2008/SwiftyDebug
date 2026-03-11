//
//  PokemonCell.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

class PokemonCell: BaseCollectionViewCell {

    static let reuseId = String(describing: PokemonCell.self)

    private let card:UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 16
        view.clipsToBounds = true
        return view
    }()

    private let spriteImageView:BaseImageView = {
        let iv = BaseImageView()
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    private let nameLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 13, weight: .semibold)
        lbl.textColor = .label
        lbl.textAlignment = .center
        return lbl
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUIElement()
        setupConstaints()
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        spriteImageView.kf.cancelDownloadTask()
        spriteImageView.image = nil
        nameLabel.text = nil
    }

    override func setupUIElement() {
        super.setupUIElement()
        contentView.addSubview(card)
        card.addSubview(spriteImageView)
        card.addSubview(nameLabel)
    }

    override func setupConstaints() {
        super.setupConstaints()
        card.anchor([.fill(contentView)])
        spriteImageView.anchor([.top(card.topAnchor, 10), .centerX(card), .size(80)])
        nameLabel.anchor([.top(spriteImageView.bottomAnchor, 4), .fillX(card, 4)])
    }

    func setupCell(model:PokemonListItem) {
        nameLabel.text = (model.name ?? "").capitalized
        spriteImageView.loadImage(url: model.spriteURL)
    }
}
