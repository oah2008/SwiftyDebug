//
//  DebugWindowPresenter.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

public class DebugWindowPresenter: NSObject {
    public static let shared = DebugWindowPresenter()

    var window: SwiftyDebugWindow
    var displayedList = false
    lazy var vc = SwiftyDebugViewController() //must lazy init, otherwise crash

    private override init() {
        window = SwiftyDebugWindow(frame: UIScreen.main.bounds)
        // This is for making the window not to effect the StatusBarStyle
        window.bounds.size.height = UIScreen.main.bounds.height.nextDown
        super.init()
    }


    public func enable() {
        if window.rootViewController == vc {
            return
        }

        window.rootViewController = vc
        window.delegate = self
        window.isHidden = false

        var success: Bool = false

        for i in 0...10 {
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + (0.1 * Double(i))) {[weak self] in
                if success == true {return}

                for scene in UIApplication.shared.connectedScenes {
                    if let windowScene = scene as? UIWindowScene {
                        self?.window.windowScene = windowScene
                        success = true
                    }
                }
            }
        }
    }


    public func disable() {
        if window.rootViewController == nil {
            return
        }
        window.rootViewController = nil
        window.delegate = nil
        window.isHidden = true
    }
}
