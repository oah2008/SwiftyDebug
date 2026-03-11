//
//  InfoBannerView.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

class InfoBannerView: BaseUI {

    private let iconView:UIImageView = {
        let iv = UIImageView(image: UIImage(systemName: "ladybug.fill"))
        iv.tintColor = .white
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    private let titleLabel:UILabel = {
        let lbl = UILabel()
        lbl.text = "SwiftyDebug"
        lbl.font = .systemFont(ofSize: 24, weight: .bold)
        lbl.textColor = .white
        return lbl
    }()

    private let subtitleLabel:UILabel = {
        let lbl = UILabel()
        lbl.text = "In-app network & log inspector\nfor iOS development"
        lbl.font = .systemFont(ofSize: 14)
        lbl.textColor = UIColor.white.withAlphaComponent(0.85)
        lbl.numberOfLines = 0
        return lbl
    }()

    private let textStack:UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        return stack
    }()

    private let row:UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 14
        stack.alignment = .center
        return stack
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUIElements()
        setupConstraints()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setupUIElements() {
        super.setupUIElements()
        uiHolderView.backgroundColor = UIColor(red: 0.30, green: 0.80, blue: 0.72, alpha: 1)
        uiHolderView.layer.cornerRadius = 18
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(textStack)
        uiHolderView.addSubview(row)
    }

    override func setupConstraints() {
        super.setupConstraints()
        iconView.anchor([.size(44)])
        row.anchor([.fill(uiHolderView, 20)])
    }
}
