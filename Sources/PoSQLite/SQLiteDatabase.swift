#if canImport(UIKit)
import UIKit
#endif
import Foundation
import SQLite3

public final class SQLiteDatabase: @unchecked Sendable {
    private let recyclableHandlePool: RecyclableHandlePool
    
    private var handlePool: SQLiteHandlePool {
        recyclableHandlePool.rawValue
    }
    
    public var path: String {
        handlePool.path
    }

    public var configuration: SQLiteConfiguration {
        handlePool.configuration
    }
    
    private var identity: SQLiteHandlePool.Key {
        handlePool.key
    }
    
    public convenience init(path: String, configuration: SQLiteConfiguration = .mobile) {
        self.init(resolvedPath: Self.resolvePath(path, configuration: configuration), configuration: configuration)
    }
    
    public convenience init(fileURL: URL, configuration: SQLiteConfiguration = .mobile) {
        self.init(resolvedPath: fileURL.standardizedFileURL.path, configuration: configuration)
    }

    private init(resolvedPath path: String, configuration: SQLiteConfiguration) {
        self.recyclableHandlePool = SQLiteHandlePool.getHandlePool(with: path, configuration: configuration)

#if canImport(UIKit)
        DispatchQueue.once(name: "com.potato.sqlite.swift.purge", {
            let purgeFreeHandleQueue: DispatchQueue = DispatchQueue(label: "com.potato.sqlite.swift.purge")
            _ = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: nil,
                using: { (_) in
                    purgeFreeHandleQueue.async {
                        SQLiteDatabase.purge()
                    }
                })
        })
#endif
    }
    
    private static let threadedHandles = ThreadLocal<[SQLiteHandlePool.Key: RecyclableHandle]>(defaultValue: [:])
    private static let threadedTransactionDepths = ThreadLocal<[SQLiteHandlePool.Key: Int]>(defaultValue: [:])
    
    func flowOut() throws -> RecyclableHandle {
        if let handle = Self.threadedHandles.value[identity] {
            return handle
        }
        let handle = try handlePool.flowOut()
        return handle
    }

    /// Since It is using lazy initialization,
    /// `init(withPath:)`, `init(withFileURL:)` never failed even the database can't open.
    /// So you can call this to check whether the database can be opened.
    /// Return false if an error occurs during sqlite handle initialization.
    public var canOpen: Bool {
        return !handlePool.isClosed && (!handlePool.isDrained || ((try? handlePool.fillOne()) != nil))
    }

    /// Check database is already opened.
    public var isOpened: Bool {
        return !handlePool.isClosed && !handlePool.isDrained
    }

    /// Check whether database is blockaded.
    public var isBlockaded: Bool {
        return handlePool.isBlockaded
    }
    
    public typealias OnClosed = () throws -> Void
    
    public func close(onClosed: OnClosed) throws {
        if Self.threadedHandles.value[identity] != nil {
            throw SQLiteError(
                code: SQLITE_BUSY,
                description: "Cannot close database while the current thread holds active statements or a transaction.",
                operation: "close"
            )
        }
        try handlePool.close(onClosed: onClosed)
    }

    /// Close the database.
    public func close() throws {
        try close(onClosed: {})
    }

    /// Blockade the database.
    public func blockade() {
        handlePool.blockade()
    }

    /// Unblockade the database.
    public func unblockade() {
        handlePool.unblockade()
    }

    /// Purge all unused memory of this database.
    /// It will cache and reuse some sqlite handles to improve performance.
    /// The max count of free sqlite handles is controlled by
    /// `SQLiteConfiguration.maximumIdleConnectionCount`.
    /// You can call it to save some memory.
    public func purge() {
        handlePool.purgeFreeHandles()
    }

    /// Purge all unused memory of all databases.
    /// Note that It will call this interface automatically while it receives memory warning on iOS.
    public static func purge() {
        SQLiteHandlePool.purgeFreeHandlesInAllPools()
    }
    
}

private extension SQLiteDatabase {
    var isInTransactionOnCurrentThread: Bool {
        (Self.threadedTransactionDepths.value[identity] ?? 0) > 0
    }

    func withWriteLock<T>(_ body: () throws -> T) throws -> T {
        if isInTransactionOnCurrentThread {
            return try body()
        }

        handlePool.wLock()
        defer { handlePool.wUnlock() }
        return try body()
    }

    func incrementTransactionDepth() {
        var depths = Self.threadedTransactionDepths.value
        depths[identity, default: 0] += 1
        Self.threadedTransactionDepths.value = depths
    }

    func decrementTransactionDepth() {
        var depths = Self.threadedTransactionDepths.value
        let nextDepth = (depths[identity] ?? 0) - 1
        if nextDepth > 0 {
            depths[identity] = nextDepth
        } else {
            depths.removeValue(forKey: identity)
        }
        Self.threadedTransactionDepths.value = depths
    }

    static func resolvePath(_ path: String, configuration: SQLiteConfiguration) -> String {
        if path == ":memory:" || configuration.usesURI {
            return path
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

// MARK: - Base Operations
extension SQLiteDatabase {
    
    public func prepare(statement stat: String) throws -> SQLiteStmt {
        let recyclableHandle = try flowOut()
        var stat = try recyclableHandle.rawValue.prepare(statement: stat)
        let identity = identity
        recyclableHandle.refCount += 1
        if recyclableHandle.refCount == 1 {
            Self.threadedHandles.value[identity] = recyclableHandle
        }
        stat.lease = SQLiteStatementLease {
            recyclableHandle.refCount -= 1
            if recyclableHandle.refCount == 0 {
                Self.threadedHandles.value.removeValue(forKey: identity)
            }
        }
        return stat
    }
    
    // write: CREATE TABLE, DELETE, ALTER; INSERT, UPDATE, REPLACE
    public func execute(sql: String, isWrite: Bool) throws {
        let body = { [self] in
            let recyclableHandle = try self.flowOut()
            try recyclableHandle.rawValue.execute(sql: sql)
        }

        if isWrite {
            try withWriteLock(body)
        } else {
            try body()
        }
    }
    
    public func begin(_ transaction: SQLiteTransaction) throws {
        let recyclableHandle = try flowOut()
        try recyclableHandle.rawValue.begin(transaction)
        recyclableHandle.refCount += 1
        if recyclableHandle.refCount == 1 {
            Self.threadedHandles.value[identity] = recyclableHandle
        }
    }
    
    public func commit() throws {
        let recyclableHandle = try flowOut()
        defer {
            recyclableHandle.refCount -= 1
            if recyclableHandle.refCount == 0 {
                Self.threadedHandles.value.removeValue(forKey: identity)
            }
        }
        try recyclableHandle.rawValue.commit()
    }
    
    public func rollback() throws {
        let recyclableHandle = try flowOut()
        defer {
            recyclableHandle.refCount -= 1
            if recyclableHandle.refCount == 0 {
                Self.threadedHandles.value.removeValue(forKey: identity)
            }
        }
        try recyclableHandle.rawValue.rollback()
    }
    
    public func lastInsertRowID() throws -> Int {
        let recyclableHandle = try flowOut()
        return recyclableHandle.rawValue.lastInsertRowID()
    }
    
    /// 自数据库链接被打开起，通过insert，update，delete语句所影响的数据行数
    public func totalChanges() throws -> Int {
        let recyclableHandle = try flowOut()
        return recyclableHandle.rawValue.totalChanges()
    }
    
    /// 最近一条insert，update，delete语句所影响的数据行数
    public func changes() throws -> Int {
        let recyclableHandle = try flowOut()
        return recyclableHandle.rawValue.changes()
    }
    
    public func errCode() throws -> Int {
        let recyclableHandle = try flowOut()
        return recyclableHandle.rawValue.errCode()
    }
    
    public func errMsg() throws -> String? {
        let recyclableHandle = try flowOut()
        return recyclableHandle.rawValue.errMsg()
    }
    
}

// MARK: - Convenience Operations
extension SQLiteDatabase {
    @discardableResult
    public func execute(_ sql: String) throws -> Int {
        try withWriteLock {
            let recyclableHandle = try flowOut()
            try recyclableHandle.rawValue.execute(sql: sql)
            return recyclableHandle.rawValue.changes()
        }
    }

    @discardableResult
    public func update(_ statement: String, parameters: [SQLiteValue] = []) throws -> Int {
        try withWriteLock {
            var stat = try prepare(statement: statement)
            defer { try? stat.finalize() }

            try stat.bind(parameters)
            let result = try stat.step()
            guard result == SQLITE_DONE else {
                throw SQLiteError(
                    code: SQLITE_MISUSE,
                    description: "Use query APIs for statements that return rows.",
                    operation: "update",
                    sql: statement
                )
            }
            return try changes()
        }
    }

    public func query<T>(_ statement: String, parameters: [SQLiteValue] = [], map: (SQLiteRow) throws -> T) throws -> [T] {
        var rows: [T] = []
        try query(statement, parameters: parameters) { row in
            rows.append(try map(row))
        }
        return rows
    }

    public func query(_ statement: String, parameters: [SQLiteValue] = [], handleRow: (SQLiteRow) throws -> Void) throws {
        var stat = try prepare(statement: statement)
        defer { try? stat.finalize() }

        try stat.bind(parameters)
        var result = try stat.step()
        while result == SQLITE_ROW {
            try handleRow(try SQLiteRow(statement: stat))
            result = try stat.step()
        }
    }

    public func firstRow(_ statement: String, parameters: [SQLiteValue] = []) throws -> SQLiteRow? {
        var stat = try prepare(statement: statement)
        defer { try? stat.finalize() }

        try stat.bind(parameters)
        guard try stat.step() == SQLITE_ROW else {
            return nil
        }
        return try SQLiteRow(statement: stat)
    }

    public func scalar(_ statement: String, parameters: [SQLiteValue] = []) throws -> SQLiteValue? {
        try firstRow(statement, parameters: parameters)?[0]
    }

    @discardableResult
    public func run(_ sql: SQL) throws -> SQLiteRunResult {
        try withWriteLock {
            var statement = try prepare(statement: sql.statement)
            defer { try? statement.finalize() }

            try statement.bind(sql.parameters)
            let result = try statement.step()
            guard result == SQLITE_DONE else {
                throw SQLiteError(
                    code: SQLITE_MISUSE,
                    description: "Use fetch APIs for statements that return rows.",
                    operation: "run",
                    sql: sql.statement
                )
            }

            return SQLiteRunResult(
                changes: try changes(),
                lastInsertRowID: try lastInsertRowID()
            )
        }
    }

    public func fetch<T>(_ sql: SQL, map: (SQLiteRow) throws -> T) throws -> [T] {
        var rows: [T] = []
        try fetch(sql) { row in
            rows.append(try map(row))
        }
        return rows
    }

    public func fetch(_ sql: SQL) throws -> [SQLiteRow] {
        try fetch(sql) { $0 }
    }

    public func fetch(_ sql: SQL, handleRow: (SQLiteRow) throws -> Void) throws {
        var statement = try prepare(statement: sql.statement)
        defer { try? statement.finalize() }

        try statement.bind(sql.parameters)
        var result = try statement.step()
        while result == SQLITE_ROW {
            try handleRow(try SQLiteRow(statement: statement))
            result = try statement.step()
        }
    }

    public func fetchOne(_ sql: SQL) throws -> SQLiteRow? {
        var statement = try prepare(statement: sql.statement)
        defer { try? statement.finalize() }

        try statement.bind(sql.parameters)
        guard try statement.step() == SQLITE_ROW else {
            return nil
        }
        return try SQLiteRow(statement: statement)
    }

    public func scalar(_ sql: SQL) throws -> SQLiteValue? {
        try fetchOne(sql)?[0]
    }

    public func transaction<T>(_ mode: SQLiteTransaction = .immediate, _ body: () throws -> T) throws -> T {
        try _transaction(mode, body)
    }

    public func transaction<T>(_ mode: SQLiteTransaction = .immediate, _ body: (_ transaction: borrowing SQLiteTransactionContext) throws -> T) throws -> T {
        try _transaction(mode) {
            try body(SQLiteTransactionContext(database: self))
        }
    }

    private func _transaction<T>(_ mode: SQLiteTransaction, _ body: () throws -> T) throws -> T {
        guard !isInTransactionOnCurrentThread else {
            throw SQLiteError(code: SQLITE_MISUSE, description: "Nested transactions are not supported.")
        }

        handlePool.wLock()
        defer { handlePool.wUnlock() }

        try begin(mode)
        incrementTransactionDepth()
        do {
            let result = try body()
            try commit()
            decrementTransactionDepth()
            return result
        } catch {
            let rollbackError: (any Error)?
            do {
                try rollback()
                rollbackError = nil
            } catch {
                rollbackError = error
            }
            decrementTransactionDepth()
            if let rollbackError {
                throw SQLiteTransactionError(primaryError: error, rollbackError: rollbackError)
            }
            throw error
        }
    }

    /// write multi
    public func executeUpdatesInTransaction(_ transaction: SQLiteTransaction = .immediate, statement: String, doUpdatings: (_ stmt: borrowing SQLiteStmt) throws -> Void) throws {
        guard !isInTransactionOnCurrentThread else {
            throw SQLiteError(code: SQLITE_MISUSE, description: "Nested transactions are not supported.")
        }

        try withWriteLock {
            let stat = try prepare(statement: statement)
            do {
                try begin(transaction)
                incrementTransactionDepth()
                try doUpdatings(stat)
                try commit()
                decrementTransactionDepth()
            } catch {
                let rollbackError: (any Error)?
                do {
                    try rollback()
                    rollbackError = nil
                } catch {
                    rollbackError = error
                }
                decrementTransactionDepth()
                if let rollbackError {
                    throw SQLiteTransactionError(primaryError: error, rollbackError: rollbackError)
                }
                throw error
            }
        }
    }
    
    /// write single
    public func executeUpdate(statement: String, doUpdating: (borrowing SQLiteStmt) throws -> Void) throws {
        try withWriteLock {
            let stat = try prepare(statement: statement)
            try doUpdating(stat)
            try stat.step()
        }
    }
    
    /// read
    public func executeQuery(statement: String, doBindings: (_ stmt: borrowing SQLiteStmt) throws -> Void, handleRow: (_ stmt: borrowing SQLiteStmt) throws -> Void) throws {
        var stat = try prepare(statement: statement)
        defer { try? stat.finalize() }
        try doBindings(stat)
        var res = try stat.step()
        
        while res == SQLITE_ROW {
            try handleRow(stat)
            res = try stat.step()
        }
    }
}
