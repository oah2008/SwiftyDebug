//
//  UIColor+HexParsing.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import UIKit

@objc extension UIColor {

    @objc static func colorFromHexString(_ hexString: String?) -> UIColor? {
        guard let hexString = hexString else { return nil }
        var hex = hexString
        if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }
        var rgbValue: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgbValue)
        return UIColor(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0xFF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
