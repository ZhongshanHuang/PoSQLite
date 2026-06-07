import Foundation

public struct SQL: Equatable, Sendable, CustomStringConvertible {
    public let statement: String
    public let parameters: [SQLiteValue]

    public var description: String {
        statement
    }

    public init(_ statement: String, parameters: [SQLiteValue] = []) {
        self.statement = statement
        self.parameters = parameters
    }

    public static func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

extension SQL: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

extension SQL: ExpressibleByStringInterpolation {
    public init(stringInterpolation: StringInterpolation) {
        self.init(stringInterpolation.statement, parameters: stringInterpolation.parameters)
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var statement: String
        var parameters: [SQLiteValue]

        public init(literalCapacity: Int, interpolationCount: Int) {
            self.statement = ""
            self.statement.reserveCapacity(literalCapacity + interpolationCount)
            self.parameters = []
            self.parameters.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) {
            statement += literal
        }

        public mutating func appendInterpolation(_ value: SQLiteValue) {
            appendValue(value)
        }

        public mutating func appendInterpolation(_ value: SQLiteValue?) {
            appendValue(value ?? .null)
        }

        public mutating func appendInterpolation(_ value: Int) {
            appendValue(SQLiteValue(value))
        }

        public mutating func appendInterpolation(_ value: Int?) {
            appendValue(value.map { SQLiteValue($0) } ?? .null)
        }

        public mutating func appendInterpolation(_ value: Int32) {
            appendValue(SQLiteValue(value))
        }

        public mutating func appendInterpolation(_ value: Int32?) {
            appendValue(value.map { SQLiteValue($0) } ?? .null)
        }

        public mutating func appendInterpolation(_ value: Int64) {
            appendValue(SQLiteValue(value))
        }

        public mutating func appendInterpolation(_ value: Int64?) {
            appendValue(value.map { SQLiteValue($0) } ?? .null)
        }

        public mutating func appendInterpolation(_ value: Double) {
            appendValue(SQLiteValue(value))
        }

        public mutating func appendInterpolation(_ value: Double?) {
            appendValue(value.map { SQLiteValue($0) } ?? .null)
        }

        public mutating func appendInterpolation(_ value: Bool) {
            appendValue(SQLiteValue(value))
        }

        public mutating func appendInterpolation(_ value: Bool?) {
            appendValue(value.map { SQLiteValue($0) } ?? .null)
        }

        public mutating func appendInterpolation(_ value: String) {
            appendValue(SQLiteValue(value))
        }

        public mutating func appendInterpolation(_ value: String?) {
            appendValue(value.map { SQLiteValue($0) } ?? .null)
        }

        public mutating func appendInterpolation(_ value: [UInt8]) {
            appendValue(SQLiteValue(value))
        }

        public mutating func appendInterpolation(_ value: [UInt8]?) {
            appendValue(value.map { SQLiteValue($0) } ?? .null)
        }

        public mutating func appendInterpolation(_ value: Data) {
            appendValue(SQLiteValue(value))
        }

        public mutating func appendInterpolation(_ value: Data?) {
            appendValue(value.map { SQLiteValue($0) } ?? .null)
        }

        public mutating func appendInterpolation(raw sql: String) {
            statement += sql
        }

        public mutating func appendInterpolation(identifier value: String) {
            statement += SQL.quoteIdentifier(value)
        }

        private mutating func appendValue(_ value: SQLiteValue) {
            statement += "?"
            parameters.append(value)
        }
    }
}

public struct SQLiteRunResult: Equatable, Sendable {
    public let changes: Int
    public let lastInsertRowID: Int
}
