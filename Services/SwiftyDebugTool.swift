//
//  SwiftyDebugTool.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation
import UIKit

class SwiftyDebugTool: NSObject {

    // MARK: - logWithString

    static func log(string: String) {
        log(string: string, color: UIColor(red: 1, green: 1, blue: 1, alpha: 1))
    }

    static func log(string: String, color: UIColor) {
        finalLog(string: string, type: .none, color: color)
    }

    // MARK: - logWithJsonData

    static func log(jsonData data: Data) -> String {
        return log(jsonData: data, color: UIColor(red: 1, green: 1, blue: 1, alpha: 1))
    }

    static func log(jsonData data: Data, color: UIColor) -> String {
        let string = getPrettyJsonString(data: data) ?? "NULL"
        return finalLog(string: string, type: .json, color: color)
    }

    // MARK: - tool

    private static func getPrettyJsonString(jsonString: String) -> String? {
        return getPrettyJsonString(data: jsonString.data(using: .utf8))
    }

    private static func getPrettyJsonString(data: Data?) -> String? {
        guard let data = data else { return nil }

        // 1. pretty json
        guard let dict = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }

        guard let prettyData = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else { return nil }

        if let prettyJsonString = String(data: prettyData, encoding: .utf8) {
            return prettyJsonString
        }

        // 2. utf-8 string
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func finalLog(string: String, type: SwiftyDebugToolType, color: UIColor) -> String {
        LogEntryBuilder.handleLog(file: "XXX", function: "XXX", line: 1, message: string, color: color, type: type)
        return string
    }
}
