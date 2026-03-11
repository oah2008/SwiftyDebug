//
//  PokemonInfoCardCell.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 11/03/2026.
//

import UIKit
import SwiftyConstraint

class PokemonInfoCardCell: PokemonDetailBaseCell {

    static let reuseId = String(describing: PokemonInfoCardCell.self)

    private let valueLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 18, weight: .bold)
        lbl.textAlignment = .center
        return lbl
    }()

    private let titleLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 11, weight: .medium)
        lbl.textColor = .secondaryLabel
        lbl.textAlignment = .center
        return lbl
    }()

    private let stack:UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 2
        return stack
    }()

    private let cardView:UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 12
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUIElement()
        setupConstaints()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setupUIElement() {
        super.setupUIElement()
        stack.addArrangedSubview(valueLabel)
        stack.addArrangedSubview(titleLabel)
        cardView.addSubview(stack)
        contentView.addSubview(cardView)
    }

    override func setupConstaints() {
        super.setupConstaints()
        stack.anchor([.fillY(cardView, 12), .fillX(cardView, 8)])
        cardView.anchor([.fill(contentView)])
    }

    override func setupCell(item:PokemonDetailItemType) {
        super.setupCell(item: item)
        guard case .infoCard(let label, let value) = item else{return}
        titleLabel.text = label
        valueLabel.text = value
    }
}
