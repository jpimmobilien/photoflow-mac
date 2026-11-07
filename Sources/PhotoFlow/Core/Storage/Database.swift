import Foundation
import SQLite3

/// Thin, thread-safe SQLite wrapper (system libsqlite3 – no third-party dependency).
/// All access is serialized on a private queue; statements are prepared per call (cheap for our volumes)
/// and wrapped in transactions for bulk writes.
final class Database: @unchecked Sendable {
    enum DBError: LocalizedError {
        case open(String), prepare(String), step(String)
        var errorDescription: String? {
            switch self {
            case .open(let m): return "Database open failed: \(m)"
            case .prepare(let m): return "Database statement failed: \(m)"
            case .step(let m): return "Database write failed: \(m)"
            }
        }
    }

    enum Value {
        case int(Int64), double(Double), text(String), blob(Data), null

        init(_ v: Int64?) { self = v.map { .int($0) } ?? .null }
        init(_ v: Int?) { self = v.map { .int(Int64($0)) } ?? .null }
        init(_ v: Double?) { self = v.map { .double($0) } ?? .null }
        init(_ v: String?) { self = v.map { .text($0) } ?? .null }
        init(_ v: Data?) { self = v.map { .blob($0) } ?? .null }
        init(_ v: Date?) { self = v.map { .double($0.timeIntervalSince1970) } ?? .null }
        init(_ v: Bool) { self = .int(v ? 1 : 0) }
    }

    /// Read-only view of the current result row.
    struct Row {
        fileprivate let stmt: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func intOrNil(_ i: Int32) -> Int64? { isNull(i) ? nil : sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func doubleOrNil(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(stmt, i) }
        func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func text(_ i: Int32) -> String { textOrNil(i) ?? "" }
        func textOrNil(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: sqlite3_column_double(stmt, i)) }
        func dateOrNil(_ i: Int32) -> Date? { isNull(i) ? nil : date(i) }
        func blob(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            let n = Int(sqlite3_column_bytes(stmt, i))
            return Data(bytes: p, count: n)
        }
    }

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "de.photoflow.database")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &h, flags, nil) == SQLITE_OK, let h else {
            throw DBError.open(String(cString: sqlite3_errmsg(h)))
        }
        handle = h
        sqlite3_busy_timeout(h, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close_v2(handle) }

    // MARK: - Execution

    func execute(_ sql: String, _ args: [Value] = []) throws {
        try queue.sync { try _run(sql, args, rowHandler: nil) }
    }

    @discardableResult
    func insert(_ sql: String, _ args: [Value] = []) throws -> Int64 {
        try queue.sync {
            try _run(sql, args, rowHandler: nil)
            return sqlite3_last_insert_rowid(handle)
        }
    }

    func query<T>(_ sql: String, _ args: [Value] = [], map: @escaping (Row) throws -> T) throws -> [T] {
        try queue.sync {
            var out: [T] = []
            try _run(sql, args) { row in out.append(try map(row)) }
            return out
        }
    }

    func scalarInt(_ sql: String, _ args: [Value] = []) throws -> Int64? {
        try query(sql, args) { $0.intOrNil(0) }.first ?? nil
    }

    /// Runs `body` inside a single transaction (much faster for bulk inserts).
    func transaction<T>(_ body: (TransactionContext) throws -> T) throws -> T {
        try queue.sync {
            try _run("BEGIN IMMEDIATE", [], rowHandler: nil)
            do {
                let ctx = TransactionContext(db: self)
                let result = try body(ctx)
                try _run("COMMIT", [], rowHandler: nil)
                return result
            } catch {
                try? _run("ROLLBACK", [], rowHandler: nil)
                throw error
            }
        }
    }

    /// Statement runner usable from inside `transaction` (already on the queue).
    struct TransactionContext {
        fileprivate let db: Database
        func execute(_ sql: String, _ args: [Value] = []) throws { try db._run(sql, args, rowHandler: nil) }
        @discardableResult
        func insert(_ sql: String, _ args: [Value] = []) throws -> Int64 {
            try db._run(sql, args, rowHandler: nil)
            return sqlite3_last_insert_rowid(db.handle)
        }
        func query<T>(_ sql: String, _ args: [Value] = [], map: @escaping (Row) throws -> T) throws -> [T] {
            var out: [T] = []
            try db._run(sql, args) { out.append(try map($0)) }
            return out
        }
        var changes: Int { Int(sqlite3_changes(db.handle)) }
    }

    private func _run(_ sql: String, _ args: [Value], rowHandler: ((Row) throws -> Void)?) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError.prepare("\(String(cString: sqlite3_errmsg(handle))) – \(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Database.transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { p in
                    sqlite3_bind_blob(stmt, idx, p.baseAddress, Int32(v.count), Database.transient)
                }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                try rowHandler?(Row(stmt: stmt))
            } else if rc == SQLITE_DONE {
                return
            } else {
                throw DBError.step("\(String(cString: sqlite3_errmsg(handle))) – \(sql)")
            }
        }
    }
}
