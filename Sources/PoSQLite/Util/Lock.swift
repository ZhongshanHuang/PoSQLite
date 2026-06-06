import Foundation

protocol Lockable: AnyObject, Sendable {
    func lock()
    func unlock()
}

@available(iOS 10.0, OSX 10.12, watchOS 3.0, tvOS 10.0, *)
final class UnfairLock: Lockable, @unchecked Sendable {
    @unsafe private var unfairLock = os_unfair_lock_s()

    func lock() {
        unsafe os_unfair_lock_lock(&unfairLock)
    }

    func unlock() {
        unsafe os_unfair_lock_unlock(&unfairLock)
    }
}

final class Mutex: Lockable, @unchecked Sendable {
    @unsafe private var mutex = pthread_mutex_t()

    init() {
        unsafe pthread_mutex_init(&mutex, nil)
    }

    deinit {
        unsafe pthread_mutex_destroy(&mutex)
    }

    func lock() {
        unsafe pthread_mutex_lock(&mutex)
    }

    func unlock() {
        unsafe pthread_mutex_unlock(&mutex)
    }
}

final class RecursiveMutex: Lockable, @unchecked Sendable {
    @unsafe private var mutex = pthread_mutex_t()

    init() {
        var attr = pthread_mutexattr_t()
        unsafe pthread_mutexattr_init(&attr)
        unsafe pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE)
        unsafe pthread_mutex_init(&mutex, &attr)
    }

    deinit {
        unsafe pthread_mutex_destroy(&mutex)
    }

    func lock() {
        unsafe pthread_mutex_lock(&mutex)
    }

    func unlock() {
        unsafe pthread_mutex_unlock(&mutex)
    }
}

final class Spin: Lockable, @unchecked Sendable {
    private let locker: Lockable

    init() {
        if #available(iOS 10.0, macOS 10.12, watchOS 3.0, tvOS 10.0, *) {
            locker = UnfairLock()
        } else {
            locker = Mutex()
        }
    }

    func lock() {
        locker.lock()
    }

    func unlock() {
        locker.unlock()
    }
}

final class ConditionLock: Lockable, @unchecked Sendable {
    @unsafe private var mutex = pthread_mutex_t()
    @unsafe private var cond = pthread_cond_t()

    init() {
        unsafe pthread_mutex_init(&mutex, nil)
        unsafe pthread_cond_init(&cond, nil)
    }

    deinit {
        unsafe pthread_cond_destroy(&cond)
        unsafe pthread_mutex_destroy(&mutex)
    }

    func lock() {
        unsafe pthread_mutex_lock(&mutex)
    }

    func unlock() {
        unsafe pthread_mutex_unlock(&mutex)
    }

    func wait() {
        unsafe pthread_cond_wait(&cond, &mutex)
    }

    func wait(timeout: TimeInterval) {
        let integerPart = Int(timeout.nextDown)
        let fractionalPart = timeout - Double(integerPart)
        var ts = timespec(tv_sec: integerPart, tv_nsec: Int(fractionalPart * 1000000000))

        unsafe pthread_cond_timedwait_relative_np(&cond, &mutex, &ts)
    }

    func signal() {
        unsafe pthread_cond_signal(&cond)
    }
}

extension DispatchQueue {
    static private let spin = Spin()
    nonisolated(unsafe) static private var tracker: Set<String> = []

    static func once(name: String, _ block: () -> Void) {
        spin.lock(); defer { spin.unlock() }
        guard unsafe !tracker.contains(name) else { return }
        block()
        unsafe tracker.insert(name)
    }
}

final class RWLock: @unchecked Sendable {
    @unsafe var mutex = pthread_mutex_t()
    @unsafe var cond = pthread_cond_t()
    var reader = 0
    var writer = 0
    var pending = 0

    init() {
        unsafe pthread_mutex_init(&mutex, nil)
        unsafe pthread_cond_init(&cond, nil)
    }

    deinit {
        unsafe pthread_cond_destroy(&cond)
        unsafe pthread_mutex_destroy(&mutex)
    }

    func lockRead() {
        unsafe pthread_mutex_lock(&mutex); defer { unsafe pthread_mutex_unlock(&mutex) }
        while writer>0 || pending>0 {
            unsafe pthread_cond_wait(&cond, &mutex)
        }
        reader += 1
    }

    func unlockRead() {
        unsafe pthread_mutex_lock(&mutex); defer { unsafe pthread_mutex_unlock(&mutex) }
        reader -= 1
        if reader == 0 {
            unsafe pthread_cond_broadcast(&cond)
        }
    }

    func lockWrite() {
        unsafe pthread_mutex_lock(&mutex); defer { unsafe pthread_mutex_unlock(&mutex) }
        pending += 1
        while writer>0||reader>0 {
            unsafe pthread_cond_wait(&cond, &mutex)
        }
        pending -= 1
        writer += 1
    }

    func unlockWrite() {
        unsafe pthread_mutex_lock(&mutex); defer { unsafe pthread_mutex_unlock(&mutex) }
        writer -= 1
        unsafe pthread_cond_broadcast(&cond)
    }

    var isWriting: Bool {
        unsafe pthread_mutex_lock(&mutex); defer { unsafe pthread_mutex_unlock(&mutex) }
        return writer>0
    }

//    var isReading: Bool {
//        pthread_mutex_lock(&mutex); defer { pthread_mutex_unlock(&mutex) }
//        return reader>0
//    }
}

//final class WWLock {
//    var mutex = pthread_mutex_t()
//    var cond = pthread_cond_t()
//    var writer = 0
//
//    init() {
//        pthread_mutex_init(&mutex, nil)
//        pthread_cond_init(&cond, nil)
//    }
//
//    deinit {
//        pthread_cond_destroy(&cond)
//        pthread_mutex_destroy(&mutex)
//    }
//
//    func lockWrite() {
//        pthread_mutex_lock(&mutex); defer { pthread_mutex_unlock(&mutex) }
//        while writer > 0 {
//            pthread_cond_wait(&cond, &mutex)
//        }
//        writer += 1
//    }
//
//    func unlockWrite() {
//        pthread_mutex_lock(&mutex); defer { pthread_mutex_unlock(&mutex) }
//        writer -= 1
//        pthread_cond_broadcast(&cond)
//    }
//
//    var isWriting: Bool {
//        pthread_mutex_lock(&mutex); defer { pthread_mutex_unlock(&mutex) }
//        return writer > 0
//    }
//}
