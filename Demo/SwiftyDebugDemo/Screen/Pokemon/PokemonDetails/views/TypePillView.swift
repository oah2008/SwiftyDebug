//
//  TypePillView.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 11/03/2026.
//

import UIKit
import SwiftyConstraint

class TypePillView: BaseUI {

    private let label:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 13, weight: .semibold)
        lbl.textColor = .white
        lbl.textAlignment = .center
        return lbl
    }()

    init(name:String, color:UIColor) {
        super.init(frame: .zero)
        setupUIElements()
        setupConstraints()
        label.text = name
        uiHolderView.backgroundColor = color
        uiHolderView.layer.cornerRadius = 12
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setupUIElements() {
        super.setupUIElements()
        uiHolderView.addSubview(label)
    }

    override func setupConstraints() {
        super.setupConstraints()
        label.anchor([.fillY(uiHolderView, 5), .fillX(uiHolderView, 14)])
    }
}
