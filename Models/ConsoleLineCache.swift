//
//  ConsoleLineCache.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation
import UIKit

class ConsoleLineCache {
    let rowid: Int64
    let text: String
    let color: UIColor
    /// Highlighted text, computed on-demand by LogViewController's highlight queue.
    var attributedText: NSAttributedString?

    init(rowid: Int64, text: String, color: UIColor) {
        self.rowid = rowid
        self.text = text
        self.color = color
    }
}
