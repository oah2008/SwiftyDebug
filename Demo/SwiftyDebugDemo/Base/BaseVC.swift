//
//  BaseVC.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

class BaseVC<VM: BaseVM, UI: BaseUI>: UIViewController {

    var viewModel:VM!
    var ui:UI!

    override func viewDidLoad() {
        super.viewDidLoad()
        ui = UI()
        viewModel = VM()
        view = ui

        let backBarButtonItem = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
        navigationItem.backBarButtonItem = backBarButtonItem
        navigationItem.backButtonTitle = ""
    }

    deinit {
        Logger.deinits(String(describing: type(of: self)))
    }
}
