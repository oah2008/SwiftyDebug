//
//  Foundation+Serialization.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation

extension String {
    ///JSON/Form format conversion
    func formStringToDictionary() -> [String: Any]? {
        var dictionary = [String: Any]()
        let array = self.components(separatedBy: "&")

        for str in array {
            let arr = str.components(separatedBy: "=")
            if arr.count == 2 {
                dictionary.updateValue(arr[1], forKey: arr[0])
            } else {
                return nil
            }
        }
        if dictionary.count > 0 {
            return dictionary
        }
        return nil
    }
}

extension Data {
    func dataToDictionary() -> [String: Any]? {
        do {
            return try JSONSerialization.jsonObject(with: self, options: []) as? [String : Any]
        } catch {
        }
        return nil
    }
}

extension Dictionary {
    func dictionaryToData() -> Data? {
        do {
            return try JSONSerialization.data(withJSONObject: self, options: .prettyPrinted)
        } catch {
        }
        return nil
    }
}

extension Data {
    func dataToString() -> String? {
        return String(bytes: self, encoding: .utf8)
    }
}

extension String {
    func stringToData() -> Data? {
        return self.data(using: .utf8)
    }
}

extension String {
    func stringToDictionary() -> [String: Any]? {
        return self.stringToData()?.dataToDictionary()
    }
}

extension Dictionary {
    func dictionaryToString() -> String? {
        return self.dictionaryToData()?.dataToString()
    }
}

extension String {
    func formStringToJsonString() -> String? {
        return self.formStringToDictionary()?.dictionaryToString()
    }
}

extension Data {
    /// Try to parse as any valid JSON (dictionary OR array) and return it.
    func dataToJSONObject() -> Any? {
        do {
            return try JSONSerialization.jsonObject(with: self, options: [])
        } catch {}
        return nil
    }

    func dataToPrettyPrintString() -> String? {
        //1.pretty json (handles both dictionaries and arrays)
        if let jsonObject = self.dataToJSONObject(),
           let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted),
           let str = String(data: prettyData, encoding: .utf8) {
            return str
        }
        //2.utf-8 string
        return String(data: self, encoding: .utf8)
    }
}
