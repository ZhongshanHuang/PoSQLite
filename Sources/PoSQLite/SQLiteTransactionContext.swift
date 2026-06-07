import Foundation

public struct SQLiteTransactionContext: ~Copyable {
    private let database: SQLiteDatabase

    init(database: SQLiteDatabase) {
        self.database = database
    }

    public var path: String {
        database.path
    }

    @discardableResult
    public func run(_ sql: SQL) throws -> SQLiteRunResult {
        try database.run(sql)
    }

    public func fetch<T>(_ sql: SQL, map: (SQLiteRow) throws -> T) throws -> [T] {
        try database.fetch(sql, map: map)
    }

    public func fetch(_ sql: SQL) throws -> [SQLiteRow] {
        try database.fetch(sql)
    }

    public func fetch(_ sql: SQL, handleRow: (SQLiteRow) throws -> Void) throws {
        try database.fetch(sql, handleRow: handleRow)
    }

    public func fetchOne(_ sql: SQL) throws -> SQLiteRow? {
        try database.fetchOne(sql)
    }

    public func scalar(_ sql: SQL) throws -> SQLiteValue? {
        try database.scalar(sql)
    }
}
