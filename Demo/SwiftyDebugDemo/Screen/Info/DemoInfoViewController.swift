//
//  DemoInfoViewController.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import UIKit

class DemoInfoViewController: BaseVC<DemoInfoVM, DemoInfoUI> {

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        viewModel.delegate = self
        ui.delegate = self
    }
}

extension DemoInfoViewController: DemoInfoUIDelegate {

    func doActions(_ actions: DemoInfoUIActions) {
        switch actions {
        case .fireTestRequests:
            viewModel.fireTestRequests()
        }
    }
}

extension DemoInfoViewController: DemoInfoVMDelegate {

    func doActions(_ actions: DemoInfoVMActions) {
        switch actions {
        case .didFireRequests:
            ui.showToast("Requests fired — check the Network tab!")
        }
    }
}
