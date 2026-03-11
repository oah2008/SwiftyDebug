//
//  SectionHeaderView.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

class SectionHeaderView: UICollectionReusableView {

    static let reuseId = String(describing: SectionHeaderView.self)

    private let titleLabel:UILabel = {
        let lbl = UILabel()
        lbl.font = .systemFont(ofSize: 13, weight: .semibold)
        lbl.textColor = .secondaryLabel
        return lbl
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(titleLabel)
        titleLabel.anchor([.fillX(self, 4), .fillY(self)])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setup(title:String) {
        titleLabel.text = title
    }
}
