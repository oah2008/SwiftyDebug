//
//  Logger.swift
//  SwiftyDebugDemo
//
//  Created by Omar Hariri on 09/03/2026.
//

import Foundation

class Logger {

    private static let tag = "[SwiftyDebugDemo]"

    static func debug (_ log: String,file: String = #file,
                       function: String = #function,
                       line: Int = #line) {
        printLog("\(Thread.isMainThread ? "⬜️⬜️⬜️" : "⬜️‼️‼️") \(log)",file: file,function: function,line: line)
    }

    static func info (_ log: String,file: String = #file,
                      function: String = #function,
                      line: Int = #line) {
        printLog("\(Thread.isMainThread ? "⚠️⚠️⚠️" : "⚠️‼️‼️") \(log)",file: file,function: function,line: line)
    }

    static func error (_ log: String,file: String = #file,
                       function: String = #function,
                       line: Int = #line) {
        printLog("\(Thread.isMainThread ? "🟥🟥🟥" : "🟥‼️‼️") \(log)",file: file,function: function,line: line)
    }

    static func deinits (_ log: String,file: String = #file,
                         function: String = #function,
                         line: Int = #line) {
        printLog("\(Thread.isMainThread ? "🏳️🏳️🏳️" : "🏳️‼️‼️") \(log) was deallocated",file: file,function: function,line: line)
    }

    static private func printLog(_ log: String,file: String = #file,
                                 function: String = #function,
                                 line: Int = #line){
        let filename = (file as NSString).lastPathComponent
        print("\(tag) [\(filename):\(line) \(function)]: \(log)")
    }
}
