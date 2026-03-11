//
//  InfoCardView.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

class InfoCardView: BaseUI {

    private let titleLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 13, weight: .semibold)
        lbl.textColor = .secondaryLabel
        return lbl
    }()

    private let itemsStack:UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        return stack
    }()

    private let outerStack:UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        return stack
    }()

    init(title:String, items:[(icon:String, text:String)]) {
        super.init(frame: .zero)
        titleLabel.text = title
        items.forEach { itemsStack.addArrangedSubview(makeRow(icon: $0.icon, text: $0.text)) }
        setupUIElements()
        setupConstraints()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setupUIElements() {
        super.setupUIElements()
        uiHolderView.backgroundColor = .secondarySystemBackground
        uiHolderView.layer.cornerRadius = 16
        outerStack.addArrangedSubview(titleLabel)
        outerStack.addArrangedSubview(itemsStack)
        uiHolderView.addSubview(outerStack)
    }

    override func setupConstraints() {
        super.setupConstraints()
        outerStack.anchor([.fill(uiHolderView, 16)])
    }

    private func makeRow(icon:String, text:String) -> UIView {
        let img = UIImageView(image: UIImage(systemName: icon))
        img.tintColor = UIColor(red: 0.30, green: 0.80, blue: 0.72, alpha: 1)
        img.contentMode = .scaleAspectFit
        img.anchor([.size(22)])

        let lbl = UILabel()
        lbl.text = text
        lbl.font = .systemFont(ofSize: 14)
        lbl.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [img, lbl])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return row
    }
}
