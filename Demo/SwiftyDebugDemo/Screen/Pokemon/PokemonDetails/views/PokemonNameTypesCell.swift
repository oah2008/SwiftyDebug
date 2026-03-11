//
//  PokemonNameTypesCell.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 11/03/2026.
//

import UIKit
import SwiftyConstraint

class PokemonNameTypesCell: PokemonDetailBaseCell {

    static let reuseId = String(describing: PokemonNameTypesCell.self)

    private let nameLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 30, weight: .bold)
        lbl.textAlignment = .center
        return lbl
    }()

    private let typesStack:UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.distribution = .fillProportionally
        stack.alignment = .center
        return stack
    }()

    private let typesWrapper:UIStackView = {
        let stack = UIStackView()
        stack.distribution = .equalCentering
        return stack
    }()

    private let mainStack:UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUIElement()
        setupConstaints()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setupUIElement() {
        super.setupUIElement()
        typesWrapper.addArrangedSubview(typesStack)
        mainStack.addArrangedSubview(nameLabel)
        mainStack.addArrangedSubview(typesWrapper)
        contentView.addSubview(mainStack)
    }

    override func setupConstaints() {
        super.setupConstaints()
        mainStack.anchor([.fill(contentView)])
    }

    override func setupCell(item:PokemonDetailItemType) {
        super.setupCell(item: item)
        guard case .nameTypes(let name, let types, let color) = item else{return}
        nameLabel.text = name.capitalized
        typesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        types.forEach { typesStack.addArrangedSubview(TypePillView(name: $0, color: color)) }
    }
}
