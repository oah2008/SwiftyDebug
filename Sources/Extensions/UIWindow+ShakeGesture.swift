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

        // `willBeVisible` reflects the state *after* this shake.
        let willBeVisible = !Settings.shared.bubbleVisible

        if Settings.shared.fullStopOnDisable {
            // Full-stop mode: shaking off performs a complete teardown so the
            // SDK has ~zero cost; shaking on resumes all capture.
            if willBeVisible {
                SwiftyDebug.resumeFromFullStop()
            } else {
                SwiftyDebug.fullStop()
            }
        }

        // In both modes the overlay visibility follows the shake.
        Settings.shared.bubbleVisible = willBeVisible
    }
}
