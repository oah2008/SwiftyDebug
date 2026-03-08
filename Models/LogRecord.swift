//
//  LogRecord.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import UIKit


class LogRecord: NSObject {

    var contentData: Data?
    var fileInfo: String?
    var content: String?
    var date: Date?
    var color: UIColor?
    var isTag: Bool = false
    var isSelected: Bool = false
    var logSource: SwiftyDebugLogSource = .app
    var sourceName: String = ""
    var logTypeTag: LogTypeTag = .unknown
    var subsystem: String = ""
    var category: String = ""
    var isViewed: Bool = false
    var isPinned: Bool = false
    var dbRowid: Int64 = 0

    /// Bridge for DB storage and @objc contexts that need the raw string.
    var logTypeName: String {
        get { logTypeTag.rawValue }
        set { logTypeTag = LogTypeTag(rawValue: newValue) ?? .unknown }
    }

    init(content: String?, color: UIColor?, fileInfo: String?, isTag: Bool, type: SwiftyDebugToolType) {
        super.init()

        var fileInfo = fileInfo

        if fileInfo == "XXX|XXX|1" {
            if type == .protobuf {
                fileInfo = "Protobuf\n"
            } else {
                fileInfo = "\n"
            }
        }

        self.fileInfo = fileInfo
        self.date = Date()
        self.color = color
        self.isTag = isTag

        // Derive sourceName and logTypeTag from normalized fileInfo
        let trimmedInfo = (fileInfo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInfo == "NSLog" {
            self.sourceName = "NSLog"
            self.logTypeTag = .nslog
        } else if trimmedInfo == "Print" {
            self.sourceName = "Print"
            self.logTypeTag = .printLog
        } else if trimmedInfo == "Protobuf" {
            self.sourceName = "Protobuf"
            self.logTypeTag = .sdk
        } else if trimmedInfo.isEmpty {
            self.sourceName = "SwiftyDebugTool"
            self.logTypeTag = .sdk
        } else if trimmedInfo.contains("[") && trimmedInfo.contains("]") {
            // Format: "File.swift[42]func()" — extract filename
            self.sourceName = String(trimmedInfo.prefix(while: { $0 != "[" }))
            self.logTypeTag = .code
        } else {
            self.sourceName = trimmedInfo
            // OSLogStore entries and others — logTypeTag set externally
        }

        if let content = content {
            self.contentData = content.data(using: .utf8)
        }

        // Avoid too many logs causing lag (use NSString.length to match ObjC UTF-16 counting)
        var truncatedContent = content ?? ""
        if (truncatedContent as NSString).length > 1000 {
            truncatedContent = (truncatedContent as NSString).substring(to: 1000)
        }
        self.content = truncatedContent
    }

    override init() {
        super.init()
    }
}
