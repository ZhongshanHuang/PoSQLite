import Foundation
import SQLite3

typealias RecyclableHandle = Recyclable<SQLiteHandlePool.HandleWrap>
typealias RecyclableHandlePool = Recyclable<SQLiteHandlePool>

final class SQLiteHandlePool: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let path: String
        let configuration: SQLiteConfiguration
    }
    
    private final class Wrap: @unchecked Sendable {
        let handlePool: SQLiteHandlePool
        var reference: Int = 0
        init(_ handlePool: SQLiteHandlePool) {
            self.handlePool = handlePool
        }
    }
    
    private static let spin = Spin()
    nonisolated(unsafe) private static var pools: [Key: Wrap] = [:]
    private static var maxHardwareConcurrency: Int { ProcessInfo.processInfo.processorCount }
    
    static func getHandlePool(with path: String, configuration: SQLiteConfiguration) -> RecyclableHandlePool {
        let key = Key(path: path, configuration: configuration)

        spin.lock()
        defer { spin.unlock() }
        
        let wrap: Wrap
        if let existing = unsafe pools[key], !existing.handlePool.isClosed {
            wrap = existing
        } else {
            let handlePool = SQLiteHandlePool(key: key)
            wrap = Wrap(handlePool)
            unsafe pools[key] = wrap
        }
        
        wrap.reference += 1
        return RecyclableHandlePool(wrap.handlePool) {
            spin.lock()
            defer { spin.unlock() }
            wrap.reference -= 1
            if wrap.reference == 0, let current = unsafe pools[key], current === wrap {
                unsafe pools.removeValue(forKey: key)
            }
        }
    }
    
    
    typealias HandleWrap = SQLiteHandle
    private let handles: ConcurrentList<HandleWrap>
    let key: Key
    var path: String { key.path }
    var configuration: SQLiteConfiguration { key.configuration }
    private let wwlock = UnfairLock()
    
    func wLock() {
        wwlock.lock()
    }
    
    func wUnlock() {
        wwlock.unlock()
    }
    
    private let rwlock = RWLock()
    private let stateLock = UnfairLock()
    private var aliveHandleCount = 0
    private var closed = false
    
    private init(key: Key) {
        self.key = key
        self.handles = ConcurrentList<HandleWrap>(capacity: Self.maximumIdleConnectionCount(for: key))
    }
    
    var isDrained: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return aliveHandleCount == 0
    }

    var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }
    
    func fillOne() throws {
        rwlock.lockRead()
        defer { rwlock.unlockRead() }
        try reserveAliveHandleSlot()

        let handle: HandleWrap
        do {
            handle = try generate()
        } catch {
            releaseAliveHandleSlots(1)
            throw error
        }

        if !handles.pushBack(handle) {
            releaseAliveHandleSlots(1)
        }
    }
    
    func flowOut() throws -> RecyclableHandle {
        var unlock = true
        rwlock.lockRead()
        defer { if unlock { rwlock.unlockRead() } }
        try throwIfClosed()

        var handleWrap = handles.popBack()
        if handleWrap == nil {
            try reserveAliveHandleSlot()
            do {
                handleWrap = try generate()
            } catch {
                releaseAliveHandleSlots(1)
                throw error
            }
        }
        unlock = false

        let handle = handleWrap!
        return RecyclableHandle(handle, onRecycled: { self.flowBack(handle) })
    }
    
    private func flowBack(_ handleWrap: HandleWrap) {
        let inserted = handles.pushBack(handleWrap)
        rwlock.unlockRead()
        if !inserted {
            releaseAliveHandleSlots(1)
        }
    }
    
    private func generate() throws -> HandleWrap {
        let handle = SQLiteHandle(withPath: path, configuration: configuration)
        try handle.open()
        return handle
    }
    
    func blockade() {
        rwlock.lockWrite()
    }

    func unblockade() {
        rwlock.unlockWrite()
    }

    var isBlockaded: Bool {
        return rwlock.isWriting
    }

    typealias OnDrained = () throws -> Void

    func close(onClosed: OnDrained) rethrows {
        blockade()
        defer { unblockade() }
        markClosed()
        let size = handles.clear()
        releaseAliveHandleSlots(size)
        try onClosed()
    }

    func close() {
        blockade()
        defer { unblockade() }
        markClosed()
        let size = handles.clear()
        releaseAliveHandleSlots(size)
    }

    func purgeFreeHandles() {
        rwlock.lockRead()
        defer { rwlock.unlockRead() }
        let size = handles.clear()
        releaseAliveHandleSlots(size)
    }
    
    static func purgeFreeHandlesInAllPools() {
        let handlePools: [SQLiteHandlePool]!
        do {
            spin.lock()
            defer { spin.unlock() }
            handlePools = unsafe pools.values.reduce(into: []) { $0.append($1.handlePool) }
        }
        handlePools.forEach { $0.purgeFreeHandles() }
    }

}

private extension SQLiteHandlePool {
    func throwIfClosed() throws {
        stateLock.lock()
        let isClosed = closed
        stateLock.unlock()

        if isClosed {
            throw SQLiteError(
                code: SQLITE_MISUSE,
                description: "Database is closed.",
                operation: "open_handle"
            )
        }
    }

    func reserveAliveHandleSlot() throws {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            throw SQLiteError(
                code: SQLITE_MISUSE,
                description: "Database is closed.",
                operation: "open_handle"
            )
        }

        guard aliveHandleCount < maximumConnectionCount else {
            stateLock.unlock()
            throw SQLiteError(
                code: SQLITE_BUSY,
                description: "The database reached its configured maximum connection count: \(maximumConnectionCount).",
                operation: "open_handle"
            )
        }

        aliveHandleCount += 1
        let count = aliveHandleCount
        stateLock.unlock()

        if count > SQLiteHandlePool.maxHardwareConcurrency {
            var warning = "The concurrency of database: \(path) with \(count)"
            warning.append(" exceeds the concurrency of hardware: \(SQLiteHandlePool.maxHardwareConcurrency)")
            SQLiteError.warning(warning)
        }
    }

    func releaseAliveHandleSlots(_ count: Int) {
        guard count > 0 else { return }

        stateLock.lock()
        aliveHandleCount = max(0, aliveHandleCount - count)
        stateLock.unlock()
    }

    func markClosed() {
        stateLock.lock()
        closed = true
        stateLock.unlock()
    }

    var maximumConnectionCount: Int {
        path == ":memory:" ? 1 : configuration.maximumConnectionCount
    }

    static func maximumIdleConnectionCount(for key: Key) -> Int {
        key.path == ":memory:" ? 1 : key.configuration.maximumIdleConnectionCount
    }
}
