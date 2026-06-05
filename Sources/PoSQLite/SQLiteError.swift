import Foundation

public extension SQLiteError {
    
    static func warning(_ msg: String) {
#if DEBUG
        print("🔴🔔🔔🔴 \(msg)")
#endif
    }
    
    static func reportSQLiteGlobal(code: Int, msg: String) {
#if DEBUG
        print("🔴🔔🔔🔴 SQLiteGlobal code: \(code) error: \(msg)")
#endif
    }
}

public struct SQLiteError: Error, LocalizedError, CustomStringConvertible {
    public let code: Int32
    public let description: String

    public var errorDescription: String? {
        description
    }

    public var localizedDescription: String {
        return description
    }
    public init(code: Int32, description: String) {
        self.code = code
        self.description = description
    }
    
    public init(code: Int, description: String) {
        self.init(code: Int32(truncatingIfNeeded: code), description: description)
    }
}
