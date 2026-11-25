import Foundation
import SQLite3

/// Thin wrapper over the system SQLite3 C API. Not thread safe by itself: `HistoryStore` serialises access.
enum SQLBind {
    case int(Int64), double(Double), text(String), null
    static func opt(_ d: Double?) -> SQLBind { d.map { .double($0) } ?? .null }
}

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class SQLRow {
    fileprivate let stmt: OpaquePointer
    fileprivate init(_ s: OpaquePointer) { stmt = s }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
    func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
}

final class SQLiteDB {
    private var db: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(message: "Cannot open \(path): \(m)")
        }
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { sqlite3_close(db) }

    var lastError: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database" }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw SQLiteError(message: m)
        }
    }

    private func prepare(_ sql: String, _ params: [SQLBind]) throws -> OpaquePointer {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw SQLiteError(message: "\(lastError) in: \(sql.prefix(80))")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .double(let v): sqlite3_bind_double(st, idx, v)
            case .text(let v): sqlite3_bind_text(st, idx, v, -1, transient)
            case .null: sqlite3_bind_null(st, idx)
            }
        }
        return st
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ params: [SQLBind] = []) throws {
        let st = try prepare(sql, params)
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(message: lastError) }
    }

    func query(_ sql: String, _ params: [SQLBind] = [], _ each: (SQLRow) -> Void) throws {
        let st = try prepare(sql, params)
        defer { sqlite3_finalize(st) }
        let row = SQLRow(st)
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { each(row) } else if rc == SQLITE_DONE { break } else { throw SQLiteError(message: lastError) }
        }
    }

    func scalarInt(_ sql: String, _ params: [SQLBind] = []) -> Int64 {
        var v: Int64 = 0
        try? query(sql, params) { v = $0.int(0) }
        return v
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
}
