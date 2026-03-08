//
//  UIWindow+ShakeGesture.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import UIKit

extension UIWindow {

    // Tracks whether motionBegan already handled the shake,
    // so motionEnded doesn't toggle a second time.
    private static var handledByMotionBegan = [String: Bool]()

    private var shakeHandledKey: String {
        String(format: "%p", unsafeBitCast(self, to: Int.self))
    }

    open override var canBecomeFirstResponder: Bool { true }

    open override func motionBegan(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionBegan(motion, with: event)
        Self.handledByMotionBegan[shakeHandledKey] = true
        toggleBubbleIfShake(motion)
    }

    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)

        if Self.handledByMotionBegan[shakeHandledKey] == true {
            Self.handledByMotionBegan[shakeHandledKey] = false
            return
        }

        toggleBubbleIfShake(motion)
    }

    private func toggleBubbleIfShake(_ motion: UIEvent.EventSubtype) {
        guard Settings.shared.shakeGestureEnabled,
              motion == .motionShake,
              !Settings.shared.debugUIVisible else { return }
        Settings.shared.bubbleVisible.toggle()
    }
}
