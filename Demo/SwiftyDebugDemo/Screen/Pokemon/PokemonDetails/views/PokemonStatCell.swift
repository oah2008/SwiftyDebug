//
//  PokemonStatCell.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 11/03/2026.
//

import UIKit
import SwiftyConstraint

class PokemonStatCell: PokemonDetailBaseCell {

    static let reuseId = String(describing: PokemonStatCell.self)

    private let nameLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 13)
        lbl.textColor = .secondaryLabel
        return lbl
    }()

    private let valueLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 13, weight: .bold)
        lbl.textAlignment = .right
        return lbl
    }()

    private let barBg:UIView = {
        let view = UIView()
        view.backgroundColor = .systemFill
        view.layer.cornerRadius = 4
        return view
    }()

    private let barFill:UIView = {
        let view = UIView()
        view.layer.cornerRadius = 4
        return view
    }()

    private let row:UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        return stack
    }()

    private var barWidthConstraint:NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUIElement()
        setupConstaints()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setupUIElement() {
        super.setupUIElement()
        barBg.addSubview(barFill)
        row.addArrangedSubview(nameLabel)
        row.addArrangedSubview(valueLabel)
        row.addArrangedSubview(barBg)
        contentView.addSubview(row)
    }

    override func setupConstaints() {
        super.setupConstaints()
        barFill.anchor([.top(barBg.topAnchor), .bottom(barBg.bottomAnchor), .leading(barBg.leadingAnchor)])
        barWidthConstraint = barFill.widthAnchor.constraint(equalTo: barBg.widthAnchor, multiplier: 0)
        barWidthConstraint?.isActive = true
        row.anchor([.fill(contentView)])
        nameLabel.anchor([.width(120)])
        valueLabel.anchor([.width(36)])
        barBg.anchor([.height(8)])
    }

    override func setupCell(item:PokemonDetailItemType) {
        super.setupCell(item: item)
        guard case .stat(let name, let value, let color) = item else{return}
        nameLabel.text = name.replacingOccurrences(of: "-", with: " ").capitalized
        valueLabel.text = "\(value)"
        barFill.backgroundColor = color

        barWidthConstraint?.isActive = false
        barWidthConstraint = barFill.widthAnchor.constraint(equalTo: barBg.widthAnchor, multiplier: min(CGFloat(value) / 255.0, 1.0))
        barWidthConstraint?.isActive = true
    }
}
