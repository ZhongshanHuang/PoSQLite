import XCTest
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
