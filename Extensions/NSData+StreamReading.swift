//
//  NSData+StreamReading.swift
//  SwiftyDebug
//
//  Created by Omar Hariri on 06/03/2026.
//

import Foundation

@objc extension NSData {

    @objc static func dataWithInputStream(_ stream: InputStream?) -> Data? {
        guard let stream = stream else { return nil }

        let data = NSMutableData()
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 1024)

        while true {
            let result = stream.read(&buffer, maxLength: 1024)
            if result > 0 {
                data.append(buffer, length: result)
            } else if result == 0 {
                break
            } else {
                // Stream error
                stream.close()
                return nil
            }
        }
        stream.close()
        return data as Data
    }

    @objc static func dataWithInputStream(_ stream: InputStream?, maxLength: UInt) -> Data? {
        guard let stream = stream else { return nil }

        let data = NSMutableData()
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 1024)

        while true {
            let remaining = Int(maxLength) - data.length
            if remaining <= 0 { break }
            let toRead = Swift.min(1024, remaining)
            let result = stream.read(&buffer, maxLength: toRead)
            if result > 0 {
                data.append(buffer, length: result)
                if data.length >= Int(maxLength) {
                    break
                }
            } else if result == 0 {
                break
            } else {
                stream.close()
                return nil
            }
        }
        stream.close()
        return data as Data
    }
}
