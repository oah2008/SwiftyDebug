//
//  LogModelDB.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import UIKit
import SQLite3

final class LogModelDB {

    static let shared = LogModelDB()

    // MARK: - Public state (main thread only)

    /// Cached counts per logSource. Main-thread only.
    private(set) var cachedCount: [Int: Int] = [:]

    /// Called on main thread after insert: (logSourceRawValue, newTotalForThatSource)
    var onCountChanged: ((Int, Int) -> Void)?

    // MARK: - Single connection (FULLMUTEX — thread-safe)

    private var db: OpaquePointer?

    // MARK: - Queue for serializing writes

    private let writeQueue = DispatchQueue(label: "com.swiftydebug.logmodel.write", qos: .utility)

    // MARK: - Prepared statements (write — used on writeQueue only)

    private var insertStmt: OpaquePointer?
    private var deleteAllStmt: OpaquePointer?
    private var deleteBySourceStmt: OpaquePointer?
    private var writeCountBySourceStmt: OpaquePointer?
    private var togglePinStmt: OpaquePointer?

    // MARK: - Prepared statements (read — used on main thread only)

    private var fetchRangeStmt: OpaquePointer?
    private var readCountBySourceStmt: OpaquePointer?
    private var searchCountStmt: OpaquePointer?
    private var searchFetchRangeStmt: OpaquePointer?

    // MARK: - SQLite transient destructor

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Database URL

    private static let databaseURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("com.swiftydebug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("logs.sqlite")
    }()

    // MARK: - Init

    private init() {
        openDatabase()
        // Initialize cached counts for known sources
        for src in [SwiftyDebugLogSource.thirdParty.rawValue, SwiftyDebugLogSource.web.rawValue] {
            cachedCount[src] = readCount(source: src)
        }
    }

    // MARK: - Database setup

    private func openDatabase() {
        let dbPath = Self.databaseURL.path

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var rc = sqlite3_open_v2(dbPath, &db, flags, nil)

        if rc != SQLITE_OK {
            try? FileManager.default.removeItem(atPath: dbPath)
            rc = sqlite3_open_v2(dbPath, &db, flags, nil)
        }

        if rc != SQLITE_OK {
            sqlite3_open_v2(":memory:", &db, flags, nil)
        }

        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size=-2000", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)

        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS logs (
                content TEXT,
                contentData BLOB,
                color INTEGER DEFAULT 0,
                fileInfo TEXT,
                date REAL,
                sourceName TEXT DEFAULT '',
                logTypeName TEXT DEFAULT '',
                subsystem TEXT DEFAULT '',
                category TEXT DEFAULT '',
                logSource INTEGER DEFAULT 0,
                logType INTEGER DEFAULT 0,
                isTag INTEGER DEFAULT 0,
                isPinned INTEGER DEFAULT 0
            )
            """, nil, nil, nil)

        // Migration: add isPinned column if missing (existing databases)
        sqlite3_exec(db, "ALTER TABLE logs ADD COLUMN isPinned INTEGER DEFAULT 0", nil, nil, nil)

        // Index for fast source-based queries
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_logs_source ON logs(logSource)", nil, nil, nil)

        prepareStatements()

        // Clear previous session data (preserve pinned)
        sqlite3_exec(db, "DELETE FROM logs WHERE isPinned = 0", nil, nil, nil)
        sqlite3_exec(db, "VACUUM", nil, nil, nil)
    }

    private func prepareStatements() {
        // Write statements (writeQueue)
        sqlite3_prepare_v2(db,
            "INSERT INTO logs (content, contentData, color, fileInfo, date, sourceName, logTypeName, subsystem, category, logSource, logType, isTag, isPinned) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            -1, &insertStmt, nil)
        sqlite3_prepare_v2(db,
            "DELETE FROM logs WHERE isPinned = 0", -1, &deleteAllStmt, nil)
        sqlite3_prepare_v2(db,
            "DELETE FROM logs WHERE logSource = ? AND isPinned = 0", -1, &deleteBySourceStmt, nil)
        sqlite3_prepare_v2(db,
            "SELECT COUNT(*) FROM logs WHERE logSource = ?", -1, &writeCountBySourceStmt, nil)
        sqlite3_prepare_v2(db,
            "UPDATE logs SET isPinned = ? WHERE rowid = ?", -1, &togglePinStmt, nil)

        // Read statements (main thread)
        sqlite3_prepare_v2(db,
            "SELECT rowid, content, contentData, color, fileInfo, date, sourceName, logTypeName, subsystem, category, logSource, logType, isTag, isPinned FROM logs WHERE logSource = ? ORDER BY rowid LIMIT ? OFFSET ?",
            -1, &fetchRangeStmt, nil)
        sqlite3_prepare_v2(db,
            "SELECT COUNT(*) FROM logs WHERE logSource = ?", -1, &readCountBySourceStmt, nil)
        sqlite3_prepare_v2(db,
            "SELECT COUNT(*) FROM logs WHERE logSource = ? AND content LIKE ?",
            -1, &searchCountStmt, nil)
        sqlite3_prepare_v2(db,
            "SELECT rowid, content, contentData, color, fileInfo, date, sourceName, logTypeName, subsystem, category, logSource, logType, isTag, isPinned FROM logs WHERE logSource = ? AND content LIKE ? ORDER BY rowid LIMIT ? OFFSET ?",
            -1, &searchFetchRangeStmt, nil)
    }

    // MARK: - Helper: bind text (NULL-safe)

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let val = value {
            val.withCString { cStr in
                sqlite3_bind_text(stmt, index, cStr, -1, Self.SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    // MARK: - Write methods (dispatched to writeQueue)

    func insert(model: LogRecord) {
        let source = model.logSource.rawValue
        writeQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            self.insertRow(model)

            sqlite3_reset(self.writeCountBySourceStmt)
            sqlite3_bind_int(self.writeCountBySourceStmt, 1, Int32(source))
            sqlite3_step(self.writeCountBySourceStmt)
            let newCount = Int(sqlite3_column_int64(self.writeCountBySourceStmt, 0))

            DispatchQueue.main.async { [weak self] in
                self?.cachedCount[source] = newCount
                self?.onCountChanged?(source, newCount)
            }
        }
    }

    func batchInsert(models: [LogRecord]) {
        guard !models.isEmpty else { return }

        // Group by source to report per-source counts
        var sourceSet = Set<Int>()
        for m in models { sourceSet.insert(m.logSource.rawValue) }

        writeQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            for model in models {
                self.insertRow(model)
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)

            // Get updated counts for each affected source
            var counts: [Int: Int] = [:]
            for src in sourceSet {
                sqlite3_reset(self.writeCountBySourceStmt)
                sqlite3_bind_int(self.writeCountBySourceStmt, 1, Int32(src))
                sqlite3_step(self.writeCountBySourceStmt)
                counts[src] = Int(sqlite3_column_int64(self.writeCountBySourceStmt, 0))
            }

            DispatchQueue.main.async { [weak self] in
                for (src, count) in counts {
                    self?.cachedCount[src] = count
                    self?.onCountChanged?(src, count)
                }
            }
        }
    }

    /// Must be called on writeQueue
    private func insertRow(_ model: LogRecord) {
        sqlite3_reset(insertStmt)
        sqlite3_clear_bindings(insertStmt)

        bindText(insertStmt, index: 1, value: model.content)

        if let data = model.contentData {
            data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(insertStmt, 2, bytes.baseAddress, Int32(data.count), Self.SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(insertStmt, 2)
        }

        let colorCode: Int32 = (model.color == .systemRed) ? 1 : 0
        sqlite3_bind_int(insertStmt, 3, colorCode)
        bindText(insertStmt, index: 4, value: model.fileInfo)
        sqlite3_bind_double(insertStmt, 5, model.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)
        bindText(insertStmt, index: 6, value: model.sourceName)
        bindText(insertStmt, index: 7, value: model.logTypeName)
        bindText(insertStmt, index: 8, value: model.subsystem)
        bindText(insertStmt, index: 9, value: model.category)
        sqlite3_bind_int(insertStmt, 10, Int32(model.logSource.rawValue))
        sqlite3_bind_int(insertStmt, 11, 0) // legacy logType column, always 0
        sqlite3_bind_int(insertStmt, 12, model.isTag ? 1 : 0)
        sqlite3_bind_int(insertStmt, 13, model.isPinned ? 1 : 0)

        sqlite3_step(insertStmt)
    }

    func deleteAll(source: Int) {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            sqlite3_reset(self.deleteBySourceStmt)
            sqlite3_bind_int(self.deleteBySourceStmt, 1, Int32(source))
            sqlite3_step(self.deleteBySourceStmt)

            // Recount (pinned rows may remain)
            sqlite3_reset(self.writeCountBySourceStmt)
            sqlite3_bind_int(self.writeCountBySourceStmt, 1, Int32(source))
            sqlite3_step(self.writeCountBySourceStmt)
            let remaining = Int(sqlite3_column_int64(self.writeCountBySourceStmt, 0))

            DispatchQueue.main.async { [weak self] in
                self?.cachedCount[source] = remaining
                self?.onCountChanged?(source, remaining)
            }
        }
    }

    func deleteAll() {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            sqlite3_reset(self.deleteAllStmt)
            sqlite3_step(self.deleteAllStmt)

            // Recount pinned rows per source
            var counts: [Int: Int] = [:]
            for src in [SwiftyDebugLogSource.thirdParty.rawValue, SwiftyDebugLogSource.web.rawValue] {
                sqlite3_reset(self.writeCountBySourceStmt)
                sqlite3_bind_int(self.writeCountBySourceStmt, 1, Int32(src))
                sqlite3_step(self.writeCountBySourceStmt)
                counts[src] = Int(sqlite3_column_int64(self.writeCountBySourceStmt, 0))
            }

            DispatchQueue.main.async { [weak self] in
                for (src, count) in counts {
                    self?.cachedCount[src] = count
                    self?.onCountChanged?(src, count)
                }
            }
        }
    }

    func togglePin(rowid: Int64, pinned: Bool) {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            sqlite3_reset(self.togglePinStmt)
            sqlite3_bind_int(self.togglePinStmt, 1, pinned ? 1 : 0)
            sqlite3_bind_int64(self.togglePinStmt, 2, rowid)
            sqlite3_step(self.togglePinStmt)
        }
    }

    // MARK: - Read methods (main thread only)

    func readCount(source: Int) -> Int {
        sqlite3_reset(readCountBySourceStmt)
        sqlite3_bind_int(readCountBySourceStmt, 1, Int32(source))
        sqlite3_step(readCountBySourceStmt)
        return Int(sqlite3_column_int64(readCountBySourceStmt, 0))
    }

    func fetchRange(source: Int, offset: Int, limit: Int) -> [LogRecord] {
        sqlite3_reset(fetchRangeStmt)
        sqlite3_bind_int(fetchRangeStmt, 1, Int32(source))
        sqlite3_bind_int64(fetchRangeStmt, 2, Int64(limit))
        sqlite3_bind_int64(fetchRangeStmt, 3, Int64(offset))
        return readModels(from: fetchRangeStmt)
    }

    func searchCount(source: Int, query: String) -> Int {
        sqlite3_reset(searchCountStmt)
        sqlite3_bind_int(searchCountStmt, 1, Int32(source))
        let pattern = "%\(query)%"
        pattern.withCString { cStr in
            sqlite3_bind_text(searchCountStmt, 2, cStr, -1, Self.SQLITE_TRANSIENT)
        }
        sqlite3_step(searchCountStmt)
        return Int(sqlite3_column_int64(searchCountStmt, 0))
    }

    func searchFetchRange(source: Int, query: String, offset: Int, limit: Int) -> [LogRecord] {
        sqlite3_reset(searchFetchRangeStmt)
        sqlite3_bind_int(searchFetchRangeStmt, 1, Int32(source))
        let pattern = "%\(query)%"
        pattern.withCString { cStr in
            sqlite3_bind_text(searchFetchRangeStmt, 2, cStr, -1, Self.SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(searchFetchRangeStmt, 3, Int64(limit))
        sqlite3_bind_int64(searchFetchRangeStmt, 4, Int64(offset))
        return readModels(from: searchFetchRangeStmt)
    }

    // MARK: - Model reconstruction

    private func readModels(from stmt: OpaquePointer?) -> [LogRecord] {
        var results: [LogRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = LogRecord()
            let rowid = sqlite3_column_int64(stmt, 0)
            model.dbRowid = rowid
            model.content = columnText(stmt, 1)
            model.contentData = columnBlob(stmt, 2)
            model.color = (sqlite3_column_int(stmt, 3) == 1) ? .systemRed : .white
            model.fileInfo = columnText(stmt, 4)
            let timestamp = sqlite3_column_double(stmt, 5)
            model.date = (timestamp > 0) ? Date(timeIntervalSince1970: timestamp) : nil
            model.sourceName = columnText(stmt, 6) ?? ""
            model.logTypeName = columnText(stmt, 7) ?? ""
            model.subsystem = columnText(stmt, 8) ?? ""
            model.category = columnText(stmt, 9) ?? ""
            model.logSource = SwiftyDebugLogSource(rawValue: Int(sqlite3_column_int(stmt, 10))) ?? .app
            // column 11 is legacy logType, ignored
            model.isTag = sqlite3_column_int(stmt, 12) != 0
            model.isPinned = sqlite3_column_int(stmt, 13) != 0
            results.append(model)
        }
        return results
    }

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: ptr)
    }

    private func columnBlob(_ stmt: OpaquePointer?, _ col: Int32) -> Data? {
        guard let ptr = sqlite3_column_blob(stmt, col) else { return nil }
        let len = sqlite3_column_bytes(stmt, col)
        guard len > 0 else { return nil }
        return Data(bytes: ptr, count: Int(len))
    }

    // MARK: - Cleanup

    deinit {
        sqlite3_finalize(insertStmt)
        sqlite3_finalize(deleteAllStmt)
        sqlite3_finalize(deleteBySourceStmt)
        sqlite3_finalize(writeCountBySourceStmt)
        sqlite3_finalize(togglePinStmt)
        sqlite3_finalize(fetchRangeStmt)
        sqlite3_finalize(readCountBySourceStmt)
        sqlite3_finalize(searchCountStmt)
        sqlite3_finalize(searchFetchRangeStmt)
        sqlite3_close(db)
    }
}
