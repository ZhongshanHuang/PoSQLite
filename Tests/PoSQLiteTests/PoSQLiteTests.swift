import XCTest
import Foundation
import SQLite3
@testable import PoSQLite

final class PoSQLiteTests: XCTestCase {
    private struct Person: Equatable {
        let id: Int
        let name: String
        let age: Int?
        let score: Double?
        let isActive: Bool?
        let payload: [UInt8]?
        let note: String?
    }

    func testModernUpdateAndQueryAPIs() throws {
        let (database, url) = makeDatabase()
        defer { cleanup(database: database, url: url) }

        try database.execute("""
        CREATE TABLE people (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            age INTEGER,
            score REAL,
            is_active INTEGER,
            payload BLOB,
            note TEXT
        );
        """)

        let changes = try database.update(
            "INSERT INTO people (name, age, score, is_active, payload, note) VALUES (?, ?, ?, ?, ?, ?)",
            parameters: ["Blob", 37, 9.5, true, .blob([0, 1, 2, 255]), nil]
        )
        XCTAssertEqual(changes, 1)

        let people = try database.query(
            "SELECT id, name, age, score, is_active, payload, note FROM people WHERE name = ?",
            parameters: ["Blob"]
        ) { row in
            Person(
                id: try XCTUnwrap(row.int(named: "id")),
                name: try XCTUnwrap(row.string(named: "name")),
                age: try row.int(named: "age"),
                score: try row.double(named: "score"),
                isActive: try row.bool(named: "is_active"),
                payload: try row.blob(named: "payload"),
                note: try row.string(named: "note")
            )
        }

        XCTAssertEqual(
            people,
            [
                Person(
                    id: 1,
                    name: "Blob",
                    age: 37,
                    score: 9.5,
                    isActive: true,
                    payload: [0, 1, 2, 255],
                    note: nil
                )
            ]
        )
        XCTAssertEqual(try database.scalar("SELECT COUNT(*) FROM people"), .integer(1))
    }

    func testTransactionRollsBackAndRethrows() throws {
        let (database, url) = makeDatabase()
        defer { cleanup(database: database, url: url) }

        enum TestFailure: Error {
            case expected
        }

        try database.execute("CREATE TABLE items (name TEXT NOT NULL UNIQUE);")
        try database.update("INSERT INTO items (name) VALUES (?)", parameters: ["existing"])

        XCTAssertThrowsError(
            try database.transaction {
                try database.update("INSERT INTO items (name) VALUES (?)", parameters: ["pending"])
                throw TestFailure.expected
            }
        )

        let names = try database.query("SELECT name FROM items ORDER BY name") { row in
            try XCTUnwrap(row.string(named: "name"))
        }
        XCTAssertEqual(names, ["existing"])
    }

    func testLegacyTransactionAPIRollsBackAndRethrows() throws {
        let (database, url) = makeDatabase()
        defer { cleanup(database: database, url: url) }

        enum TestFailure: Error {
            case expected
        }

        try database.execute("CREATE TABLE items (name TEXT NOT NULL);")

        XCTAssertThrowsError(
            try database.executeUpdatesInTransaction(statement: "INSERT INTO items (name) VALUES (?)") { statement in
                try statement.bind(position: 1, "pending")
                try statement.step()
                throw TestFailure.expected
            }
        )

        XCTAssertEqual(try database.scalar("SELECT COUNT(*) FROM items"), .integer(0))
    }

    func testNestedTransactionThrowsInsteadOfDeadlocking() throws {
        let (database, url) = makeDatabase()
        defer { cleanup(database: database, url: url) }

        try database.execute("CREATE TABLE items (name TEXT NOT NULL);")

        XCTAssertThrowsError(
            try database.transaction {
                try database.executeUpdatesInTransaction(statement: "INSERT INTO items (name) VALUES (?)") { statement in
                    try statement.bind(position: 1, "pending")
                    try statement.step()
                }
            }
        )

        XCTAssertEqual(try database.scalar("SELECT COUNT(*) FROM items"), .integer(0))
    }

    func testEmptyStatementThrowsInsteadOfCrashing() throws {
        let (database, url) = makeDatabase()
        defer { cleanup(database: database, url: url) }

        do {
            _ = try database.prepare(statement: "-- comment only")
            XCTFail("Expected an empty SQL statement to throw.")
        } catch let error as SQLiteError {
            XCTAssertEqual(error.code, SQLITE_MISUSE)
        }
    }

    func testBlobHelpersReadByteCountsCorrectly() throws {
        let (database, url) = makeDatabase()
        defer { cleanup(database: database, url: url) }

        try database.execute("CREATE TABLE blobs (payload BLOB NOT NULL);")
        try database.update("INSERT INTO blobs (payload) VALUES (?)", parameters: [.blob([1, 0, 2, 0])])

        try database.executeQuery(
            statement: "SELECT payload FROM blobs",
            doBindings: { _ in },
            handleRow: { statement in
                let bytes = statement.columnBlob(position: 0)
                let words: [UInt16] = statement.columnIntBlob(position: 0)
                XCTAssertEqual(bytes, [1, 0, 2, 0])
                XCTAssertEqual(words, [1, 2])
            }
        )
    }

    @available(macOS 10.14.4, iOS 12.2, tvOS 12.2, watchOS 5.2, *)
    func testSpanBlobAPIsBorrowBytes() throws {
        let (database, url) = makeDatabase()
        defer { cleanup(database: database, url: url) }

        let payload: [UInt8] = [3, 1, 4, 1, 5, 9]
        try database.execute("CREATE TABLE blobs (payload BLOB NOT NULL);")
        try database.executeUpdate(statement: "INSERT INTO blobs (payload) VALUES (?)") { statement in
            try unsafe payload.withUnsafeBufferPointer { buffer in
                try statement.bind(position: 1, unsafe Span(_unsafeElements: buffer))
            }
        }

        try database.executeQuery(
            statement: "SELECT payload FROM blobs",
            doBindings: { _ in },
            handleRow: { statement in
                let borrowed = statement.withColumnBlob(position: 0) { span in
                    unsafe span.withUnsafeBufferPointer { unsafe Array($0) }
                }
                XCTAssertEqual(borrowed, payload)
            }
        )
    }

    func testCloseWaitsForActiveStatementLease() throws {
        let (database, url) = makeDatabase()
        try database.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL);")
        try database.update("INSERT INTO items (name) VALUES (?)", parameters: ["held"])

        var statement = try database.prepare(statement: "SELECT name FROM items")
        XCTAssertEqual(try statement.step(), SQLITE_ROW)

        let closeStarted = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            closeStarted.signal()
            database.close()
            closeFinished.signal()
        }

        XCTAssertEqual(closeStarted.wait(timeout: .now() + .seconds(2)), .success)
        XCTAssertEqual(closeFinished.wait(timeout: .now() + .milliseconds(100)), .timedOut)

        try statement.finalize()
        XCTAssertEqual(closeFinished.wait(timeout: .now() + .seconds(2)), .success)

        cleanup(database: database, url: url)
    }

    func testConcurrentReadsAndWritesUsePoolSafely() throws {
        let (database, url) = makeDatabase()
        defer { cleanup(database: database, url: url) }

        try database.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value INTEGER NOT NULL);")

        let failures = FailureRecorder()
        let queue = DispatchQueue(label: "com.potato.sqlite.tests.concurrent", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0..<80 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    if index.isMultiple(of: 4) {
                        try database.update("INSERT INTO items (value) VALUES (?)", parameters: [.integer(Int64(index))])
                    } else {
                        _ = try database.scalar("SELECT COUNT(*) FROM items")
                    }
                } catch {
                    failures.record(error)
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + .seconds(5)), .success)
        XCTAssertEqual(failures.messages, [])
        XCTAssertEqual(try database.scalar("SELECT COUNT(*) FROM items"), .integer(20))
    }

    func testSQLiteErrorsCarryExecuteSQLContext() throws {
        let (database, url) = makeDatabase()
        defer { cleanup(database: database, url: url) }

        let sql = "SELECT * FROM missing_table"
        do {
            _ = try database.execute(sql)
            XCTFail("Expected invalid SQL to throw.")
        } catch let error as SQLiteError {
            XCTAssertEqual(error.code, SQLITE_ERROR)
            XCTAssertEqual(error.extendedCode, SQLITE_ERROR)
            XCTAssertEqual(error.operation, "execute")
            XCTAssertEqual(error.sql, sql)
            XCTAssertTrue(error.description.contains("sql=\(sql)"))
        }
    }

    func testSQLiteConstraintErrorsCarryExtendedCodeAndSQL() throws {
        let (database, url) = makeDatabase()
        defer { cleanup(database: database, url: url) }

        let sql = "INSERT INTO items (name) VALUES (?)"
        try database.execute("CREATE TABLE items (name TEXT NOT NULL UNIQUE);")
        try database.update(sql, parameters: ["duplicate"])

        do {
            try database.update(sql, parameters: ["duplicate"])
            XCTFail("Expected duplicate unique value to throw.")
        } catch let error as SQLiteError {
            let uniqueConstraint = SQLITE_CONSTRAINT | (8 << 8)
            XCTAssertEqual(error.code, SQLITE_CONSTRAINT)
            XCTAssertEqual(error.extendedCode, uniqueConstraint)
            XCTAssertEqual(error.operation, "step")
            XCTAssertEqual(error.sql, sql)
        }
    }

    func testBindNameErrorsCarryBindContext() throws {
        let (database, url) = makeDatabase()
        defer { cleanup(database: database, url: url) }

        let sql = "SELECT :expected"
        let missingName = ":missing"
        var statement = try database.prepare(statement: sql)
        defer { try? statement.finalize() }

        do {
            try statement.bind(name: missingName, 1)
            XCTFail("Expected missing bind parameter to throw.")
        } catch let error as SQLiteError {
            XCTAssertEqual(error.code, SQLITE_MISUSE)
            XCTAssertEqual(error.operation, "bind_parameter_index")
            XCTAssertEqual(error.sql, sql)
            XCTAssertEqual(error.bind?.name, missingName)
        }
    }

    func testTransactionReportsRollbackFailureWithoutLosingPrimaryError() throws {
        let (database, url) = makeDatabase()
        defer { cleanup(database: database, url: url) }

        enum TestFailure: Error {
            case expected
        }

        try database.execute("CREATE TABLE items (name TEXT NOT NULL);")

        do {
            try database.transaction {
                try database.update("INSERT INTO items (name) VALUES (?)", parameters: ["pending"])
                try database.execute("ROLLBACK TRANSACTION;")
                throw TestFailure.expected
            }
            XCTFail("Expected transaction to throw.")
        } catch let error as SQLiteTransactionError {
            XCTAssertTrue(error.primaryError is TestFailure)
            let rollbackError = try XCTUnwrap(error.rollbackError as? SQLiteError)
            XCTAssertEqual(rollbackError.operation, "execute")
            XCTAssertEqual(rollbackError.sql, "ROLLBACK TRANSACTION;")
        }

        XCTAssertEqual(try database.scalar("SELECT COUNT(*) FROM items"), .integer(0))
    }
}

private extension PoSQLiteTests {
    func makeDatabase() -> (SQLiteDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoSQLiteTests-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        return (SQLiteDatabase(fileURL: url), url)
    }

    func cleanup(database: SQLiteDatabase, url: URL) {
        database.close()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }
}

private final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(String(describing: error))
    }
}
