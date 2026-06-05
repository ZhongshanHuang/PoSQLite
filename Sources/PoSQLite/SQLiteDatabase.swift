#if canImport(UIKit)
import UIKit
#endif
import Foundation
import SQLite3

public final class SQLiteDatabase {
    private let recyclableHandlePool: RecyclableHandlePool
    
    private var handlePool: SQLiteHandlePool {
        recyclableHandlePool.rawValue
    }
    
    public var path: String {
        handlePool.path
    }
    
    public convenience init(path: String) {
        self.init(fileURL: URL(fileURLWithPath: path))
    }
    
    public init(fileURL: URL) {
        self.recyclableHandlePool = SQLiteHandlePool.getHandlePool(with: fileURL.standardizedFileURL.path)

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
    
    private static var threadedHandles = ThreadLocal<[String: RecyclableHandle]>(defaultValue: [:])
    private static var threadedTransactionDepths = ThreadLocal<[String: Int]>(defaultValue: [:])
    
    func flowOut() throws -> RecyclableHandle {
        if let handle = Self.threadedHandles.value[path] {
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
        return !handlePool.isDrained || ((try? handlePool.fillOne()) != nil)
    }

    /// Check database is already opened.
    public var isOpened: Bool {
        return !handlePool.isDrained
    }

    /// Check whether database is blockaded.
    public var isBlockaded: Bool {
        return handlePool.isBlockaded
    }
    
    public typealias OnClosed = () throws -> Void
    
    public func close(onClosed: OnClosed) rethrows {
        try handlePool.drain(onDrained: onClosed)
    }

    /// Close the database.
    public func close() {
        handlePool.drain()
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
    /// The max count of free sqlite handles is same
    /// as the number of concurrent threads supported by the hardware implementation.
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
        (Self.threadedTransactionDepths.value[path] ?? 0) > 0
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
        depths[path, default: 0] += 1
        Self.threadedTransactionDepths.value = depths
    }

    func decrementTransactionDepth() {
        var depths = Self.threadedTransactionDepths.value
        let nextDepth = (depths[path] ?? 0) - 1
        if nextDepth > 0 {
            depths[path] = nextDepth
        } else {
            depths.removeValue(forKey: path)
        }
        Self.threadedTransactionDepths.value = depths
    }
}

// MARK: - Base Operations
extension SQLiteDatabase {
    
    public func prepare(statement stat: String) throws -> SQLiteStmt {
        let recyclableHandle = try flowOut()
        var stat = try recyclableHandle.rawValue.prepare(statement: stat)
        let path = path
        stat.onFinalize = {
            recyclableHandle.refCount -= 1
            if recyclableHandle.refCount == 0 {
                Self.threadedHandles.value.removeValue(forKey: path)
            }
        }
        recyclableHandle.refCount += 1
        if recyclableHandle.refCount == 1 {
            Self.threadedHandles.value[path] = recyclableHandle
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
            Self.threadedHandles.value[path] = recyclableHandle
        }
    }
    
    public func commit() throws {
        let recyclableHandle = try flowOut()
        try recyclableHandle.rawValue.commit()
        recyclableHandle.refCount -= 1
        if recyclableHandle.refCount == 0 {
            Self.threadedHandles.value.removeValue(forKey: path)
        }
    }
    
    public func rollback() throws {
        let recyclableHandle = try flowOut()
        try recyclableHandle.rawValue.rollback()
        recyclableHandle.refCount -= 1
        if recyclableHandle.refCount == 0 {
            Self.threadedHandles.value.removeValue(forKey: path)
        }
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
                throw SQLiteError(code: SQLITE_MISUSE, description: "Use query APIs for statements that return rows.")
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

    public func transaction<T>(_ mode: SQLiteTransaction = .immediate, _ body: () throws -> T) throws -> T {
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
            try? rollback()
            decrementTransactionDepth()
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
                try? rollback()
                decrementTransactionDepth()
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
