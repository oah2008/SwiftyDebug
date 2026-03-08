//
//  NSDictionary+SafeAccess.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

@objc extension NSDictionary {

    @objc func _stringForKey(_ key: NSCopying?) -> String? {
        guard let key = key else { return nil }
        let obj = object(forKey: key)
        if let str = obj as? String {
            return str
        }
        return nil
    }

    @objc func _arrayForKey(_ key: NSCopying?) -> NSArray? {
        guard let key = key else { return nil }
        let obj = object(forKey: key)
        if let arr = obj as? NSArray {
            return arr
        }
        return nil
    }

    @objc func _dictionaryForKey(_ key: NSCopying?) -> NSDictionary? {
        guard let key = key else { return nil }
        let obj = object(forKey: key)
        if let dict = obj as? NSDictionary {
            return dict
        }
        return nil
    }

    @objc func _integerForKey(_ key: NSCopying?) -> Int {
        guard let key = key else { return 0 }
        let obj = object(forKey: key)
        if let num = obj as? NSNumber {
            return num.intValue
        }
        if let str = obj as? NSString {
            return str.integerValue
        }
        return 0
    }

    @objc func _int64ForKey(_ key: NSCopying?) -> Int64 {
        guard let key = key else { return 0 }
        let obj = object(forKey: key)
        if let num = obj as? NSNumber {
            return num.int64Value
        }
        if let str = obj as? NSString {
            return str.longLongValue
        }
        return 0
    }

    @objc func _int32ForKey(_ key: NSCopying?) -> Int32 {
        guard let key = key else { return 0 }
        let obj = object(forKey: key)
        if let num = obj as? NSNumber {
            return num.int32Value
        }
        if let str = obj as? NSString {
            return str.intValue
        }
        return 0
    }

    @objc func _floatForKey(_ key: NSCopying?) -> Float {
        guard let key = key else { return 0 }
        let obj = object(forKey: key)
        if let num = obj as? NSNumber {
            return num.floatValue
        }
        if let str = obj as? NSString {
            return str.floatValue
        }
        return 0
    }

    @objc func _doubleForKey(_ key: NSCopying?) -> Double {
        guard let key = key else { return 0 }
        let obj = object(forKey: key)
        if let num = obj as? NSNumber {
            return num.doubleValue
        }
        if let str = obj as? NSString {
            return str.doubleValue
        }
        return 0
    }

    @objc func _boolForKey(_ key: NSCopying?) -> Bool {
        guard let key = key else { return false }
        let obj = object(forKey: key)
        if let num = obj as? NSNumber {
            return num.boolValue
        }
        if let str = obj as? NSString {
            return str.boolValue
        }
        return false
    }

    @objc(cd_stringForKey:default:)
    func _stringForKey(_ key: NSCopying?, default defaultValue: String?) -> String? {
        guard let key = key else { return defaultValue }
        let obj = object(forKey: key)
        if let str = obj as? String {
            return str
        }
        return defaultValue
    }

    @objc(cd_boolForKey:default:)
    func _boolForKey(_ key: NSCopying?, default defaultValue: Bool) -> Bool {
        guard let key = key else { return defaultValue }
        let obj = object(forKey: key)
        if obj is NSNumber || obj is NSString {
            return (obj as AnyObject).boolValue
        }
        return defaultValue
    }

    @objc(cd_integerForKey:default:)
    func _integerForKey(_ key: NSCopying?, default defaultValue: Int) -> Int {
        guard let key = key else { return defaultValue }
        let obj = object(forKey: key)
        if obj is NSNumber || obj is NSString {
            return (obj as AnyObject).integerValue
        }
        return defaultValue
    }

    @objc(cd_floatForKey:default:)
    func _floatForKey(_ key: NSCopying?, default defaultValue: Float) -> Float {
        guard let key = key else { return defaultValue }
        let obj = object(forKey: key)
        if obj is NSNumber || obj is NSString {
            return (obj as AnyObject).floatValue
        }
        return defaultValue
    }

    @objc(cd_arrayForKey:default:)
    func _arrayForKey(_ key: NSCopying?, default defaultValue: NSArray?) -> NSArray? {
        guard let key = key else { return defaultValue }
        let obj = object(forKey: key)
        if let arr = obj as? NSArray {
            return arr
        }
        return defaultValue
    }

    @objc(cd_dictionaryForKey:default:)
    func _dictionaryForKey(_ key: NSCopying?, default defaultValue: NSDictionary?) -> NSDictionary? {
        guard let key = key else { return defaultValue }
        let obj = object(forKey: key)
        if let dict = obj as? NSDictionary {
            return dict
        }
        return defaultValue
    }
}
