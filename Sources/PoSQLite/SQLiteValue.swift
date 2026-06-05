import Foundation

public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob([UInt8])

    public init(_ value: Int) {
        self = .integer(Int64(value))
    }

    public init(_ value: Int32) {
        self = .integer(Int64(value))
    }

    public init(_ value: Int64) {
        self = .integer(value)
    }

    public init(_ value: Double) {
        self = .double(value)
    }

    public init(_ value: String) {
        self = .text(value)
    }

    public init(_ value: Bool) {
        self = .integer(value ? 1 : 0)
    }

    public init(_ value: [UInt8]) {
        self = .blob(value)
    }

    public init(_ value: Data) {
        self = .blob(Array(value))
    }
}

extension SQLiteValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension SQLiteValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self.init(value)
    }
}

extension SQLiteValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self.init(value)
    }
}

extension SQLiteValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

extension SQLiteValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self.init(value)
    }
}

public extension SQLiteStmt {
    func bind(position: Int, _ value: SQLiteValue) throws {
        switch value {
        case .null:
            try bindNull(position: position)
        case .integer(let value):
            try bind(position: position, value)
        case .double(let value):
            try bind(position: position, value)
        case .text(let value):
            try bind(position: position, value)
        case .blob(let value):
            try bind(position: position, value)
        }
    }

    func bind(name: String, _ value: SQLiteValue) throws {
        switch value {
        case .null:
            try bindNull(name: name)
        case .integer(let value):
            try bind(name: name, value)
        case .double(let value):
            try bind(name: name, value)
        case .text(let value):
            try bind(name: name, value)
        case .blob(let value):
            try bind(name: name, value)
        }
    }

    func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            try bind(position: offset + 1, value)
        }
    }

    func bind(_ values: [String: SQLiteValue]) throws {
        for (name, value) in values {
            try bind(name: name, value)
        }
    }
}
