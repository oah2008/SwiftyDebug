//
//  PrintInterceptor.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import UIKit

public class PrintInterceptor: NSObject {
    
    var enable: Bool = true
    
    static let shared = PrintInterceptor()
    private override init() {}
    
    
    fileprivate func parseFileInfo(file: String?, function: String?, line: Int?) -> String? {
        guard let file = file, let function = function, let line = line, let fileName = file.components(separatedBy: "/").last else {return nil}
        return "\(fileName)[\(line)]\(function)\n"
    }
    
    
    public func handleLog(file: String?, function: String?, line: Int?, message: Any..., color: UIColor?) {
        let stringContent = message.reduce("") { result, next -> String in
            return "\(result)\(result.count > 0 ? " " : "")\(next)"
        }
        commonHandleLog(file: file, function: function, line: (line ?? 0), message: stringContent, color: color)
    }
    
    
    private func commonHandleLog(file: String?, function: String?, line: Int, message: String, color: UIColor?) {
        guard enable else {
            return
        }
        
        //1.
        let fileInfo = parseFileInfo(file: file, function: function, line: line)
        
        //2.
        let newLog = LogRecord(content: message, color: color, fileInfo: fileInfo, isTag: false, type: .none)
        newLog.logSource = .app
        newLog.logTypeTag = .code
        if let fileName = file?.components(separatedBy: "/").last, !fileName.isEmpty {
            newLog.sourceName = fileName
        }
        LogStore.shared.addLog(newLog)

        // Also send to Console tab
        let timeStr = LogCell.formatTime(newLog.date ?? Date())
        let consoleText = "[\(timeStr)] \(message)\n"
        LogStore.shared.appendConsoleLineCache(text: consoleText, color: newLog.color ?? .white)

        //3.
        LogStore.shared.scheduleRefreshNotification()
    }
}
