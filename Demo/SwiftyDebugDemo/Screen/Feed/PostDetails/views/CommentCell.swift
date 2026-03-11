//
//  CommentCell.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

class CommentCell: PostDetailBaseCell {

    static let reuseId = String(describing: CommentCell.self)

    private let holderView:UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 12
        return view
    }()

    private let nameLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 13, weight: .semibold)
        return lbl
    }()

    private let emailLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 11)
        lbl.textColor = UIColor(red: 0.30, green: 0.80, blue: 0.72, alpha: 1)
        return lbl
    }()

    private let bodyLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 13)
        lbl.textColor = .secondaryLabel
        lbl.numberOfLines = 0
        return lbl
    }()

    private let contentStack:UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 3
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
        contentStack.addArrangedSubview(nameLabel)
        contentStack.addArrangedSubview(emailLabel)
        contentStack.addArrangedSubview(bodyLabel)
    }

    override func setupConstaints() {
        super.setupConstaints()
        holderView.anchor([.fillX(contentView), .top(contentView.topAnchor, 4), .bottom(contentView.bottomAnchor, -4)])
        contentStack.anchor([.fill(holderView, 12)])
    }

    override func setupCell(comment:Comment) {
        nameLabel.text = (comment.name ?? "").capitalized
        emailLabel.text = comment.email ?? ""
        bodyLabel.text = comment.body ?? ""
    }
}
