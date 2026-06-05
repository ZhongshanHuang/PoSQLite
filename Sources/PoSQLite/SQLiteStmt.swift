import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

public enum SQLiteType: Int32 {
    case integer = 1    // SQLITE_INTEGER
    case float = 2      // SQLITE_FLOAT
    case text = 3       // SQLITE_TEXT
    case blob = 4       // SQLITE_BLOB
    case null = 5       // SQLITE_NULL
}

public struct SQLiteStmt: ~Copyable {
    private var stat: SQLite3Statement!
    var onFinalize: (() -> Void)?
    
    deinit {
        if self.stat != nil {
            sqlite3_finalize(self.stat)
            self.onFinalize?()
        }
    }
    
    internal init(stat: SQLite3Statement) {
        self.stat = stat
    }
    
    public func reset(clearBindings: Bool = false) throws {
        let statement = try _statement()
        try _checkResult(sqlite3_reset(statement))
        if clearBindings {
            try self.clearBindings()
        }
    }

    public func clearBindings() throws {
        try _checkResult(sqlite3_clear_bindings(try _statement()))
    }
    
    public mutating func finalize() throws {
        guard let statement = self.stat else { return }

        let database = sqlite3_db_handle(statement)
        let result = sqlite3_finalize(statement)
        self.stat = nil

        let onFinalize = self.onFinalize
        self.onFinalize = nil
        onFinalize?()

        try Self._checkResult(result, database: database, fallback: "sqlite3_finalize")
    }
    
    /// SQLITE_ROW 有数据，SQLITE_DONE 完成，其余的状态为失败
    @discardableResult
    public func step() throws -> Int32 {
        let res = sqlite3_step(try _statement())
        try _checkResult(res, isStep: true)
        return res
    }
    
    /* bind position */
    public func bind(position: Int, _ d: Double) throws {
        try _checkResult(sqlite3_bind_double(try _statement(), Int32(position), d))
    }
    
    public func bind(position: Int, _ i: Int32) throws {
        try _checkResult(sqlite3_bind_int(try _statement(), Int32(position), i))
    }
    
    public func bind(position: Int, _ i: Int) throws {
        try _checkResult(sqlite3_bind_int64(try _statement(), Int32(position), Int64(i)))
    }
    
    public func bind(position: Int, _ i: Int64) throws {
        try _checkResult(sqlite3_bind_int64(try _statement(), Int32(position), i))
    }
    
    public func bind(position: Int, _ s: String) throws {
        try _checkResult(sqlite3_bind_text(try _statement(), Int32(position), s, Int32(s.utf8.count), sqliteTransient))
    }
    
    public func bind(position: Int, _ b: [Int8]) throws {
        try _checkResult(sqlite3_bind_blob(try _statement(), Int32(position), b, Int32(b.count), sqliteTransient))
    }
    
    public func bind(position: Int, _ b: [UInt8]) throws {
        try _checkResult(sqlite3_bind_blob(try _statement(), Int32(position), b, Int32(b.count), sqliteTransient))
    }

    public func bind(position: Int, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            try _checkResult(sqlite3_bind_blob(try _statement(), Int32(position), buffer.baseAddress, Int32(data.count), sqliteTransient))
        }
    }
    
    public func bindZeroBlob(position: Int, count: Int) throws {
        try _checkResult(sqlite3_bind_zeroblob(try _statement(), Int32(position), Int32(count)))
    }
    
    public func bindNull(position: Int) throws {
        try _checkResult(sqlite3_bind_null(try _statement(), Int32(position)))
    }
    
    /* bind name */
    
    public func bind(name: String, _ d: Double) throws {
        try _checkResult(sqlite3_bind_double(try _statement(), bindParameterIndex(name: name), d))
    }
    
    public func bind(name: String, _ i: Int32) throws {
        try _checkResult(sqlite3_bind_int(try _statement(), bindParameterIndex(name: name), i))
    }
    
    public func bind(name: String, _ i: Int) throws {
        try _checkResult(sqlite3_bind_int64(try _statement(), bindParameterIndex(name: name), Int64(i)))
    }
    
    public func bind(name: String, _ i: Int64) throws {
        try _checkResult(sqlite3_bind_int64(try _statement(), bindParameterIndex(name: name), i))
    }
    
    public func bind(name: String, _ s: String) throws {
        try _checkResult(sqlite3_bind_text(try _statement(), bindParameterIndex(name: name), s, Int32(s.utf8.count), sqliteTransient))
    }
    
    public func bind(name: String, _ b: [Int8]) throws {
        try _checkResult(sqlite3_bind_blob(try _statement(), bindParameterIndex(name: name), b, Int32(b.count), sqliteTransient))
    }
    
    public func bind(name: String, _ b: [UInt8]) throws {
        try _checkResult(sqlite3_bind_blob(try _statement(), bindParameterIndex(name: name), b, Int32(b.count), sqliteTransient))
    }

    public func bind(name: String, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            try _checkResult(sqlite3_bind_blob(try _statement(), bindParameterIndex(name: name), buffer.baseAddress, Int32(data.count), sqliteTransient))
        }
    }
    
    public func bindZeroBlob(name: String, count: Int) throws {
        try _checkResult(sqlite3_bind_zeroblob(try _statement(), bindParameterIndex(name: name), Int32(count)))
    }
    
    public func bindNull(name: String) throws {
        try _checkResult(sqlite3_bind_null(try _statement(), bindParameterIndex(name: name)))
    }
    
    /// :name
    public func bindParameterIndex(name: String) throws -> Int32 {
        let idx = sqlite3_bind_parameter_index(try _statement(), name)
        if idx == 0 {
            throw SQLiteError(code: SQLITE_MISUSE, description: "The indicated bind parameter name was not found.")
        }
        return idx
    }
    
    public func columnName(position: Int) -> String {
        guard let stat, let name = sqlite3_column_name(stat, Int32(position)) else { return "" }
        return String(cString: name)
    }
    
    public func columnDeclaredType(position: Int) -> String {
        guard let stat, let type = sqlite3_column_decltype(stat, Int32(position)) else { return "" }
        return String(cString: type)
    }
    
    public func columnType(position: Int) -> SQLiteType {
        guard let stat else { return .null }
        let res = sqlite3_column_type(stat, Int32(position))
        return SQLiteType(rawValue: res) ?? .null
    }
    
    public func columnCount() -> Int {
        guard let stat else { return 0 }
        let res = sqlite3_column_count(stat)
        return Int(res)
    }
    
    public func columnIntBlob<I: BinaryInteger>(position: Int) -> [I] {
        guard let stat else { return [] }
        let byteCount = Int(sqlite3_column_bytes(stat, Int32(position)))
        guard byteCount > 0, let bytes = sqlite3_column_blob(stat, Int32(position)) else { return [] }

        let elementStride = MemoryLayout<I>.stride
        let elementCount = byteCount / elementStride
        let buffer = UnsafeRawBufferPointer(start: bytes, count: byteCount)

        var ret: [I] = []
        ret.reserveCapacity(elementCount)
        for index in 0..<elementCount {
            ret.append(buffer.loadUnaligned(fromByteOffset: index * elementStride, as: I.self))
        }
        return ret
    }

    public func columnBlob(position: Int) -> [UInt8] {
        guard let stat else { return [] }
        let byteCount = Int(sqlite3_column_bytes(stat, Int32(position)))
        guard byteCount > 0, let bytes = sqlite3_column_blob(stat, Int32(position)) else { return [] }
        let buffer = UnsafeRawBufferPointer(start: bytes, count: byteCount)
        return Array(buffer)
    }
    
    public func columnText(position: Int) -> String {
        guard let stat, let text = sqlite3_column_text(stat, Int32(position)) else { return "" }
        let byteCount = Int(sqlite3_column_bytes(stat, Int32(position)))
        let buffer = UnsafeRawBufferPointer(start: text, count: byteCount)
        return String(decoding: buffer, as: UTF8.self)
    }
    
    public func columnDouble(position: Int) -> Double {
        guard let stat else { return 0 }
        return sqlite3_column_double(stat, Int32(position))
    }
    
    public func columnInt32(position: Int) -> Int32 {
        guard let stat else { return 0 }
        return sqlite3_column_int(stat, Int32(position))
    }

    public func columnInt64(position: Int) -> Int64 {
        guard let stat else { return 0 }
        return sqlite3_column_int64(stat, Int32(position))
    }
    
    public func columnInt(position: Int) -> Int {
        guard let stat else { return 0 }
        return Int(sqlite3_column_int64(stat, Int32(position)))
    }
    
    private func _checkResult(_ res: Int32, isStep: Bool = false, funcName: StaticString = #function) throws {
        var shouldThrow = false
        if isStep {
            shouldThrow = res != SQLITE_ROW && res != SQLITE_DONE
        } else {
            shouldThrow = res != SQLITE_OK
        }
        if shouldThrow {
            let database = self.stat.flatMap { sqlite3_db_handle($0) }
            try Self._checkResult(res, database: database, fallback: funcName.description)
        }
    }

    private func _statement(funcName: StaticString = #function) throws -> SQLite3Statement {
        guard let stat else {
            throw SQLiteError(code: SQLITE_MISUSE, description: "\(funcName): statement has already been finalized.")
        }
        return stat
    }

    private static func _checkResult(_ res: Int32, database: SQLite3?, fallback: String) throws {
        guard res != SQLITE_OK else { return }

        let message: String
        if let database, let cMessage = sqlite3_errmsg(database) {
            message = String(cString: cMessage)
        } else {
            message = fallback
        }
        throw SQLiteError(code: res, description: message.isEmpty ? fallback : message)
    }

}
