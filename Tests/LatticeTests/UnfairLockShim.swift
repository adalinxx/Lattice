#if !canImport(os)
import Foundation

/// Linux fallback for `os.OSAllocatedUnfairLock`, which is Darwin-only. The
/// test suite uses it purely as a `Sendable` lock-around-state primitive, so a
/// `Foundation.NSLock`-backed shim with the same `withLock`/`initialState` API
/// keeps the tests compiling (and running) on the Linux determinism lane
/// without touching any call site.
final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) {
        self.state = initialState
    }

    convenience init(uncheckedState initialState: State) {
        self.init(initialState: initialState)
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try withLock(body)
    }
}
#endif
