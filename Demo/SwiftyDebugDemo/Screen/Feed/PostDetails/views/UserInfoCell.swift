//
//  UserInfoCell.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

class UserInfoCell: PostDetailBaseCell {

    static let reuseId = String(describing: UserInfoCell.self)

    private let holderView:UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        return view
    }()

    private let iconView:UIImageView = {
        let iv = UIImageView()
        iv.tintColor = UIColor(red: 0.30, green: 0.80, blue: 0.72, alpha: 1)
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    private let labelText:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 13, weight: .medium)
        lbl.textColor = .secondaryLabel
        return lbl
    }()

    private let valueText:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 14)
        return lbl
    }()

    private let separator:UIView = {
        let view = UIView()
        view.backgroundColor = .separator
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUIElement()
        setupConstaints()
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }

    override func setupUIElement() {
        super.setupUIElement()
        contentView.addSubview(holderView)
        holderView.addSubview(iconView)
        holderView.addSubview(labelText)
        holderView.addSubview(valueText)
        holderView.addSubview(separator)
    }

    override func setupConstaints() {
        super.setupConstaints()
        holderView.anchor([.fillX(contentView, 4), .fillY(contentView)])
        iconView.anchor([.leading(holderView.leadingAnchor, 14), .centerY(holderView), .size(22)])
        labelText.anchor([.leading(iconView.trailingAnchor, 10), .top(holderView.topAnchor, 10)])
        valueText.anchor([.leading(iconView.trailingAnchor, 10), .top(labelText.bottomAnchor, 2), .trailing(holderView.trailingAnchor, -14), .bottom(holderView.bottomAnchor, -10)])
        separator.anchor([.fillX(holderView, 14), .bottom(holderView.bottomAnchor), .height(0.5)])
    }

    override func setupCell(user:UserItemType, cellPosstion:CellPosstion) {
        iconView.image = UIImage(systemName: user.icon)
        labelText.text = user.label
        valueText.text = user.value

        switch cellPosstion {
        case .top:
            holderView.layer.cornerRadius = 12
            holderView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            separator.isHidden = false
        case .bottom:
            holderView.layer.cornerRadius = 12
            holderView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            separator.isHidden = true
        case .all:
            holderView.layer.cornerRadius = 12
            holderView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            separator.isHidden = true
        case .middle:
            holderView.layer.cornerRadius = 0
            separator.isHidden = false
        }
    }
}
