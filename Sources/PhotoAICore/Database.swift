import Foundation
import SQLite3

/// 数据库出错。写入失败必须让调用方看到，不能悄悄丢掉（数据模型 §8）。
public struct DatabaseError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String {
        if let sql { return "SQLite \(code)：\(message)（\(sql)）" }
        return "SQLite \(code)：\(message)"
    }
}

/// 绑定到 SQL 参数上的值。
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// 查询结果的一行。只在 `query` 的回调里有效。
public struct Row {
    fileprivate let statement: OpaquePointer

    public func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    public func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    public func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    public func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }

    public func optionalInt(_ index: Int32) -> Int? { isNull(index) ? nil : int(index) }
    public func optionalDouble(_ index: Int32) -> Double? { isNull(index) ? nil : double(index) }

    public func text(_ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    public func date(_ index: Int32) -> Date? {
        isNull(index) ? nil : Date(timeIntervalSince1970: double(index))
    }
}

/// 系统 SQLite3 的一个连接。
///
/// 连接不跨线程共享：每个公开方法整体加锁，事务期间其他调用排队等待，
/// 所以 `BEGIN`…`COMMIT` 之间不会插进别的语句。软件里写和读各用一个连接（WAL 下读不阻塞写）。
public final class Database: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var transactionDepth = 0
    public let url: URL

    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        if !readOnly {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var handle: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE))
            | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(handle)
            throw DatabaseError(code: result, message: message, sql: nil)
        }
        self.handle = handle
        // 软件和命令行可能同时打开；短暂锁定时等待重试，而不是立刻报错。
        sqlite3_busy_timeout(handle, 5_000)
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
        }
        try execute("PRAGMA foreign_keys=ON;")
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    // MARK: - 执行

    /// 执行不带参数的一条或多条语句。
    public func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw DatabaseError(code: result, message: message, sql: sql)
        }
    }

    /// 执行一条写语句，返回受影响的行数。
    @discardableResult
    public func run(_ sql: String, _ arguments: [any SQLBindable] = []) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepared(sql, arguments)
        defer { sqlite3_reset(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DatabaseError(code: result, message: lastErrorMessage, sql: sql)
        }
        return Int(sqlite3_changes(handle))
    }

    /// 插入一行，返回新行的 rowid。
    public func insert(_ sql: String, _ arguments: [any SQLBindable] = []) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        try run(sql, arguments)
        return sqlite3_last_insert_rowid(handle)
    }

    /// 逐行读取结果。
    public func query(_ sql: String, _ arguments: [any SQLBindable] = [], _ body: (Row) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepared(sql, arguments)
        defer { sqlite3_reset(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw DatabaseError(code: result, message: lastErrorMessage, sql: sql)
            }
            try body(Row(statement: statement))
        }
    }

    /// 读取所有行，每行映射成一个值。
    public func all<T>(_ sql: String, _ arguments: [any SQLBindable] = [], _ map: (Row) throws -> T) throws -> [T] {
        var results: [T] = []
        try query(sql, arguments) { results.append(try map($0)) }
        return results
    }

    /// 读取第一行。
    public func first<T>(_ sql: String, _ arguments: [any SQLBindable] = [], _ map: (Row) throws -> T) throws -> T? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepared(sql, arguments)
        defer { sqlite3_reset(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            throw DatabaseError(code: result, message: lastErrorMessage, sql: sql)
        }
        return try map(Row(statement: statement))
    }

    public func scalarInt(_ sql: String, _ arguments: [any SQLBindable] = []) throws -> Int {
        try first(sql, arguments) { $0.int(0) } ?? 0
    }

    // MARK: - 事务

    /// 在一个事务里执行。抛错时整体回滚；可以嵌套，嵌套部分用保存点。
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let depth = transactionDepth
        let savepoint = "sp\(depth)"
        try execute(depth == 0 ? "BEGIN IMMEDIATE;" : "SAVEPOINT \(savepoint);")
        transactionDepth += 1
        do {
            let value = try body()
            transactionDepth -= 1
            try execute(depth == 0 ? "COMMIT;" : "RELEASE \(savepoint);")
            return value
        } catch {
            transactionDepth -= 1
            if depth == 0 {
                try? execute("ROLLBACK;")
            } else {
                try? execute("ROLLBACK TO \(savepoint); RELEASE \(savepoint);")
            }
            throw error
        }
    }

    /// `PRAGMA data_version`：别的连接（比如命令行）提交后会变。
    public func dataVersion() throws -> Int {
        try scalarInt("PRAGMA data_version;")
    }

    // MARK: - 内部

    private var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库已关闭"
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepared(_ sql: String, _ arguments: [any SQLBindable]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var pointer: OpaquePointer?
            let result = sqlite3_prepare_v2(handle, sql, -1, &pointer, nil)
            guard result == SQLITE_OK, let pointer else {
                throw DatabaseError(code: result, message: lastErrorMessage, sql: sql)
            }
            statements[sql] = pointer
            statement = pointer
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch argument.sqlValue {
            case .null: result = sqlite3_bind_null(statement, index)
            case .int(let value): result = sqlite3_bind_int64(statement, index, value)
            case .double(let value): result = sqlite3_bind_double(statement, index, value)
            case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .blob(let value):
                result = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
                }
            }
            guard result == SQLITE_OK else {
                throw DatabaseError(code: result, message: lastErrorMessage, sql: sql)
            }
        }
        return statement
    }
}
