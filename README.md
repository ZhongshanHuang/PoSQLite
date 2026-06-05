# PoSQLite

PoSQLite is a small Swift wrapper around SQLite. It keeps the low-level statement API available, while providing safer Swift-friendly helpers for parameter binding, row mapping, and transactions.

## Usage

```swift
import PoSQLite

let database = SQLiteDatabase(path: "/tmp/app.sqlite")

try database.execute("""
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    age INTEGER
);
""")

try database.update(
    "INSERT INTO users (name, age) VALUES (?, ?)",
    parameters: ["Ada", 37]
)

let users = try database.query("SELECT id, name, age FROM users ORDER BY id") { row in
    (
        id: try row.int(named: "id"),
        name: try row.string(named: "name"),
        age: try row.int(named: "age")
    )
}
```

Use bound `SQLiteValue` parameters instead of string interpolation for user input:

```swift
try database.update(
    "UPDATE users SET age = ? WHERE name = ?",
    parameters: [38, "Ada"]
)
```

Transactions keep all writes on the same SQLite handle and roll back on any thrown error:

```swift
try database.transaction {
    try database.update("INSERT INTO users (name, age) VALUES (?, ?)", parameters: ["Grace", 40])
    try database.update("INSERT INTO users (name, age) VALUES (?, ?)", parameters: ["Linus", nil])
}
```

The original `prepare`, `executeUpdate`, `executeQuery`, and statement binding APIs are still available for lower-level control.
