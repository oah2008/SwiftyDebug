//
//  BaseUI.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit
import SwiftyConstraint

class BaseUI: UIView {

    var uiHolderView:UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        Logger.deinits(String(describing: type(of: self)))
    }

    func setupUIElements() {
        addSubview(uiHolderView)
    }

    func setupConstraints() {
        uiHolderView.anchor([.fill(self)])
    }
}
