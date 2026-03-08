//
//  ConsoleLogDB.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import SQLite3

final class ConsoleLogDB {

    static let shared = ConsoleLogDB()

    // MARK: - Public state (main thread only)

    /// Cached total count, updated after each insert batch. Main-thread only.
    private(set) var cachedTotalCount: Int = 0

    /// Called on main thread after insert with (newTotalCount, insertedCount)
    var onCountChanged: ((Int, Int) -> Void)?

    // MARK: - Single connection (FULLMUTEX — thread-safe)

    private var db: OpaquePointer?

    // MARK: - Queue for serializing writes

    private let writeQueue = DispatchQueue(label: "com.swiftydebug.db.write", qos: .utility)

    // MARK: - Prepared statements (write — used on writeQueue only)

    private var insertStmt: OpaquePointer?
    private var deleteAllStmt: OpaquePointer?
    private var writeCountStmt: OpaquePointer?

    // MARK: - Prepared statements (read — used on main thread only)

    private var fetchRangeStmt: OpaquePointer?
    private var readCountStmt: OpaquePointer?
    private var searchCountStmt: OpaquePointer?
    private var searchRangeStmt: OpaquePointer?
    private var matchRowidStmt: OpaquePointer?
    private var displayRowStmt: OpaquePointer?

    // MARK: - SQLite transient destructor

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Database URL

    private static let databaseURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("com.swiftydebug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("console.sqlite")
    }()

    // MARK: - Init

    private init() {
        openDatabase()
        cachedTotalCount = readCount()
    }

    // MARK: - Database setup

    private func openDatabase() {
        let dbPath = Self.databaseURL.path

        // Single connection with FULLMUTEX for thread safety
        // (allows safe concurrent use from writeQueue + main thread)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var rc = sqlite3_open_v2(dbPath, &db, flags, nil)

        if rc != SQLITE_OK {
            // Attempt recovery: delete and retry
            try? FileManager.default.removeItem(atPath: dbPath)
            rc = sqlite3_open_v2(dbPath, &db, flags, nil)
        }

        if rc != SQLITE_OK {
            // Final fallback: in-memory database
            sqlite3_open_v2(":memory:", &db, flags, nil)
        }

        // WAL mode for better concurrent read/write performance
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        // 2 MB page cache
        sqlite3_exec(db, "PRAGMA cache_size=-2000", nil, nil, nil)
        // Faster writes
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)

        // Create table
        sqlite3_exec(db,
            "CREATE TABLE IF NOT EXISTS entries (text TEXT NOT NULL, color INTEGER NOT NULL DEFAULT 0)",
            nil, nil, nil)

        // Prepare all statements on the same connection
        prepareStatements()

        // Clear previous session data
        sqlite3_reset(deleteAllStmt)
        sqlite3_step(deleteAllStmt)
        sqlite3_exec(db, "VACUUM", nil, nil, nil)
    }

    private func prepareStatements() {
        // Write statements (used on writeQueue)
        sqlite3_prepare_v2(db,
            "INSERT INTO entries (text, color) VALUES (?, ?)", -1, &insertStmt, nil)
        sqlite3_prepare_v2(db,
            "DELETE FROM entries", -1, &deleteAllStmt, nil)
        sqlite3_prepare_v2(db,
            "SELECT COUNT(*) FROM entries", -1, &writeCountStmt, nil)

        // Read statements (used on main thread)
        sqlite3_prepare_v2(db,
            "SELECT rowid, text, color FROM entries ORDER BY rowid LIMIT ? OFFSET ?",
            -1, &fetchRangeStmt, nil)
        sqlite3_prepare_v2(db,
            "SELECT COUNT(*) FROM entries", -1, &readCountStmt, nil)
        sqlite3_prepare_v2(db,
            "SELECT COUNT(*) FROM entries WHERE text LIKE ?",
            -1, &searchCountStmt, nil)
        sqlite3_prepare_v2(db,
            "SELECT rowid, text, color FROM entries WHERE text LIKE ? ORDER BY rowid LIMIT ? OFFSET ?",
            -1, &searchRangeStmt, nil)

        // Match navigation (read — main thread)
        sqlite3_prepare_v2(db,
            "SELECT rowid FROM entries WHERE text LIKE ? ORDER BY rowid LIMIT 1 OFFSET ?",
            -1, &matchRowidStmt, nil)
        sqlite3_prepare_v2(db,
            "SELECT COUNT(*) FROM entries WHERE rowid < ?",
            -1, &displayRowStmt, nil)
    }

    // MARK: - Write methods (dispatched to writeQueue)

    func batchInsert(lines: [(text: String, colorCode: Int)]) {
        guard !lines.isEmpty else { return }
        let count = lines.count

        writeQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }

            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

            for line in lines {
                sqlite3_reset(self.insertStmt)
                sqlite3_clear_bindings(self.insertStmt)
                _ = line.text.withCString { cStr in
                    sqlite3_bind_text(self.insertStmt, 1, cStr, -1, Self.SQLITE_TRANSIENT)
                }
                sqlite3_bind_int(self.insertStmt, 2, Int32(line.colorCode))
                sqlite3_step(self.insertStmt)
            }

            sqlite3_exec(db, "COMMIT", nil, nil, nil)

            // Get new total count
            sqlite3_reset(self.writeCountStmt)
            sqlite3_step(self.writeCountStmt)
            let newCount = Int(sqlite3_column_int64(self.writeCountStmt, 0))

            DispatchQueue.main.async { [weak self] in
                self?.cachedTotalCount = newCount
                self?.onCountChanged?(newCount, count)
            }
        }
    }

    func deleteAll() {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            sqlite3_reset(self.deleteAllStmt)
            sqlite3_step(self.deleteAllStmt)

            // Reclaim disk space
            sqlite3_exec(self.db, "VACUUM", nil, nil, nil)

            DispatchQueue.main.async { [weak self] in
                self?.cachedTotalCount = 0
                self?.onCountChanged?(0, 0)
            }
        }
    }

    // MARK: - Read methods (main thread only)

    func readCount() -> Int {
        sqlite3_reset(readCountStmt)
        sqlite3_step(readCountStmt)
        return Int(sqlite3_column_int64(readCountStmt, 0))
    }

    func fetchRange(offset: Int, limit: Int) -> [(rowid: Int64, text: String, colorCode: Int)] {
        sqlite3_reset(fetchRangeStmt)
        sqlite3_bind_int64(fetchRangeStmt, 1, Int64(limit))
        sqlite3_bind_int64(fetchRangeStmt, 2, Int64(offset))

        var results: [(rowid: Int64, text: String, colorCode: Int)] = []
        results.reserveCapacity(limit)

        while sqlite3_step(fetchRangeStmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(fetchRangeStmt, 0)
            let textPtr = sqlite3_column_text(fetchRangeStmt, 1)
            let text = textPtr.map { String(cString: $0) } ?? ""
            let colorCode = Int(sqlite3_column_int(fetchRangeStmt, 2))
            results.append((rowid: rowid, text: text, colorCode: colorCode))
        }

        return results
    }

    func searchCount(query: String) -> Int {
        sqlite3_reset(searchCountStmt)
        let likePattern = "%\(query)%"
        _ = likePattern.withCString { cStr in
            sqlite3_bind_text(searchCountStmt, 1, cStr, -1, Self.SQLITE_TRANSIENT)
        }
        sqlite3_step(searchCountStmt)
        return Int(sqlite3_column_int64(searchCountStmt, 0))
    }

    func searchRange(query: String, offset: Int, limit: Int) -> [(rowid: Int64, text: String, colorCode: Int)] {
        sqlite3_reset(searchRangeStmt)
        let likePattern = "%\(query)%"
        _ = likePattern.withCString { cStr in
            sqlite3_bind_text(searchRangeStmt, 1, cStr, -1, Self.SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(searchRangeStmt, 2, Int64(limit))
        sqlite3_bind_int64(searchRangeStmt, 3, Int64(offset))

        var results: [(rowid: Int64, text: String, colorCode: Int)] = []
        results.reserveCapacity(limit)

        while sqlite3_step(searchRangeStmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(searchRangeStmt, 0)
            let textPtr = sqlite3_column_text(searchRangeStmt, 1)
            let text = textPtr.map { String(cString: $0) } ?? ""
            let colorCode = Int(sqlite3_column_int(searchRangeStmt, 2))
            results.append((rowid: rowid, text: text, colorCode: colorCode))
        }

        return results
    }

    // MARK: - Match navigation (main thread only)

    /// Returns the rowid of the Nth matching entry (0-based matchIndex).
    func matchRowid(query: String, matchIndex: Int) -> Int64? {
        sqlite3_reset(matchRowidStmt)
        let likePattern = "%\(query)%"
        _ = likePattern.withCString { cStr in
            sqlite3_bind_text(matchRowidStmt, 1, cStr, -1, Self.SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(matchRowidStmt, 2, Int64(matchIndex))
        guard sqlite3_step(matchRowidStmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(matchRowidStmt, 0)
    }

    /// Returns the 0-based display row index for a given rowid.
    func displayRow(forRowid rowid: Int64) -> Int {
        sqlite3_reset(displayRowStmt)
        sqlite3_bind_int64(displayRowStmt, 1, rowid)
        sqlite3_step(displayRowStmt)
        return Int(sqlite3_column_int64(displayRowStmt, 0))
    }

    // MARK: - Cleanup

    deinit {
        sqlite3_finalize(insertStmt)
        sqlite3_finalize(deleteAllStmt)
        sqlite3_finalize(writeCountStmt)
        sqlite3_finalize(fetchRangeStmt)
        sqlite3_finalize(readCountStmt)
        sqlite3_finalize(searchCountStmt)
        sqlite3_finalize(searchRangeStmt)
        sqlite3_finalize(matchRowidStmt)
        sqlite3_finalize(displayRowStmt)
        sqlite3_close(db)
    }
}
