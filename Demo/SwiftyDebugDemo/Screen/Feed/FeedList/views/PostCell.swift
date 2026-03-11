//
//  PostCell.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

class PostCell: BaseCollectionViewCell {

    static let reuseId = String(describing: PostCell.self)

    private let card:UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 14
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.06
        view.layer.shadowOffset = CGSize(width: 0, height: 2)
        view.layer.shadowRadius = 6
        return view
    }()

    private let idBadge:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 11, weight: .bold)
        lbl.textColor = .white
        lbl.backgroundColor = UIColor(red: 0.30, green: 0.80, blue: 0.72, alpha: 1)
        lbl.layer.cornerRadius = 8
        lbl.clipsToBounds = true
        lbl.textAlignment = .center
        return lbl
    }()

    private let titleLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 15, weight: .semibold)
        lbl.textColor = .label
        lbl.numberOfLines = 2
        return lbl
    }()

    private let bodyLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 13, weight: .regular)
        lbl.textColor = .secondaryLabel
        lbl.numberOfLines = 2
        return lbl
    }()

    private let chevron:UIImageView = {
        let iv = UIImageView(image: UIImage(systemName: "chevron.right"))
        iv.tintColor = .tertiaryLabel
        return iv
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUIElement()
        setupConstaints()
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }

    override func setupUIElement() {
        super.setupUIElement()
        contentView.addSubview(card)
        card.addSubview(idBadge)
        card.addSubview(titleLabel)
        card.addSubview(bodyLabel)
        card.addSubview(chevron)
    }

    override func setupConstaints() {
        super.setupConstaints()
        card.anchor([.top(contentView.topAnchor, 6), .bottom(contentView.bottomAnchor, -6), .fillX(contentView, 16)])
        idBadge.anchor([.top(card.topAnchor, 12), .leading(card.leadingAnchor, 14), .widthGreaterOrEqual(34), .height(20)])
        titleLabel.anchor([.top(idBadge.bottomAnchor, 8), .leading(card.leadingAnchor, 14), .trailing(chevron.leadingAnchor, -8)])
        bodyLabel.anchor([.top(titleLabel.bottomAnchor, 6), .leading(card.leadingAnchor, 14), .trailing(chevron.leadingAnchor, -8), .bottom(card.bottomAnchor, -14)])
        chevron.anchor([.centerY(card), .trailing(card.trailingAnchor, -14), .width(8)])
    }

    func setupCell(model:Post) {
        idBadge.text = "#\(model.id ?? 0)"
        titleLabel.text = (model.title ?? "").capitalized
        bodyLabel.text = model.body ?? ""
    }
}
