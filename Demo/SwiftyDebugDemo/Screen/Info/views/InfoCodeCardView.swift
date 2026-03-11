//
//  InfoCodeCardView.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

class InfoCodeCardView: BaseUI {

    private let titleLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 13, weight: .semibold)
        lbl.textColor = UIColor(white: 0.55, alpha: 1)
        return lbl
    }()

    private let codeLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = UIFont(name: "Menlo-Regular", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        lbl.textColor = UIColor(red: 0.56, green: 0.93, blue: 0.56, alpha: 1)
        lbl.numberOfLines = 0
        return lbl
    }()

    private let stack:UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        return stack
    }()

    init(title:String, code:String) {
        super.init(frame: .zero)
        titleLabel.text = title
        codeLabel.text = code
        setupUIElements()
        setupConstraints()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setupUIElements() {
        super.setupUIElements()
        uiHolderView.backgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1)
        uiHolderView.layer.cornerRadius = 16
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(codeLabel)
        uiHolderView.addSubview(stack)
    }

    override func setupConstraints() {
        super.setupConstraints()
        stack.anchor([.fill(uiHolderView, 16)])
    }
}
