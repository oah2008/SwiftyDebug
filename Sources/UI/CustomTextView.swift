//
//  CustomTextView.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import UIKit

class CustomTextView: UITextView {

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        self.inputView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    required init(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)!
        self.inputView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(selectAll) {
            if let range = selectedTextRange, range.start == beginningOfDocument, range.end == endOfDocument {
                return false
            }
            return !text.isEmpty
        }
        else if action == #selector(paste(_:)) {
            return false
        }
        else if action == #selector(cut(_:)) {
            return false
        }

        return super.canPerformAction(action, withSender: sender)
    }
}
