//
//  NSString+Layout.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import UIKit

@objc extension NSString {

    @objc func heightWithFont(_ font: UIFont?, constraintToWidth width: CGFloat) -> CGFloat {
        guard let font = font else { return 0 }
        let rect = (self as String).boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return rect.size.height
    }
}
