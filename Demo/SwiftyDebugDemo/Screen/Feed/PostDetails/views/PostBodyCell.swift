//
//  PostBodyCell.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

class PostBodyCell: PostDetailBaseCell {

    static let reuseId = String(describing: PostBodyCell.self)

    private let holderView:UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 12
        return view
    }()

    private let titleLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 16, weight: .semibold)
        lbl.numberOfLines = 0
        return lbl
    }()

    private let bodyLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 14)
        lbl.textColor = .secondaryLabel
        lbl.numberOfLines = 0
        return lbl
    }()

    private let contentStack:UIStackView = {
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

    required init?(coder aDecoder: NSCoder) { fatalError() }

    override func setupUIElement() {
        super.setupUIElement()
        contentView.addSubview(holderView)
        holderView.addSubview(contentStack)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(bodyLabel)
    }

    override func setupConstaints() {
        super.setupConstaints()
        holderView.anchor([.fill(contentView, 4)])
        contentStack.anchor([.fill(holderView, 14)])
    }

    override func setupCell(post:Post) {
        titleLabel.text = (post.title ?? "").capitalized
        bodyLabel.text = post.body ?? ""
    }
}
