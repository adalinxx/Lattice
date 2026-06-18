import Foundation
import cashew
@_spi(Fuzzing)
import WasmKit

/// LRU cache of parsed/compiled WasmKit `Module` values, keyed by the module's
/// content id (the bytes' CID). Wasm policy modules are content-addressed and
/// immutable, so a parsed module can be reused across evaluations without
/// changing behavior: instantiation (`Module.instantiate`) is non-mutating and
/// allocates a fresh per-evaluation `Store`/`Instance`, so determinism and
/// isolation are preserved.
///
/// Bounded by module COUNT (LRU eviction on overflow). Safe under concurrent
/// evaluation via an `NSLock` guarding the storage. A bespoke primitive is used
/// because neither cashew nor Lattice ships an in-memory LRU (VolumeBroker's
/// LRU lives in a package Lattice does not depend on), and the parsed `Module`
/// is not `Sendable`, so it cannot be held by `OSAllocatedUnfairLock` or crossed
/// over actor boundaries; the lock + `@unchecked Sendable` confines it instead.
final class WasmModuleCache: @unchecked Sendable {
    /// Default bound on the number of distinct compiled modules retained.
    static let defaultMaxModuleCount = 64

    /// Process-wide shared cache used by `WasmPolicyEvaluator`.
    static let shared = WasmModuleCache()

    private let lock = NSLock()
    private var entries: [String: Module] = [:]
    /// Keys in least-recently-used (front) to most-recently-used (back) order.
    private var lru: [String] = []
    private var maxModuleCount: Int

    /// Test seam: invoked exactly once per cache miss (i.e. per real parse).
    /// Records the moduleCID that was parsed so tests can assert parse counts.
    var onParse: ((String) -> Void)?

    init(maxModuleCount: Int = WasmModuleCache.defaultMaxModuleCount) {
        precondition(maxModuleCount >= 1, "WasmModuleCache bound must be >= 1")
        self.maxModuleCount = maxModuleCount
    }

    /// Returns the cached parsed module for `key`, or parses it via `parse` on a
    /// miss and caches the result. The parse closure runs outside the lock so a
    /// slow parse does not block other evaluations; concurrent misses for the
    /// same key may each parse, but the cache still ends in a consistent state
    /// and verdicts are unaffected (parsing the same immutable bytes is
    /// deterministic).
    func module(forKey key: String, parse: () throws -> Module) throws -> Module {
        lock.lock()
        if let cached = entries[key] {
            touch(key)
            lock.unlock()
            return cached
        }
        lock.unlock()

        onParse?(key)
        let module = try parse()

        lock.lock()
        if entries[key] == nil {
            entries[key] = module
            lru.append(key)
        } else {
            touch(key)
        }
        evictIfNeeded()
        lock.unlock()
        return module
    }

    /// Test seam: shrink/grow the count bound (evicting LRU entries as needed).
    func setMaxModuleCount(_ count: Int) {
        precondition(count >= 1, "WasmModuleCache bound must be >= 1")
        lock.lock()
        maxModuleCount = count
        evictIfNeeded()
        lock.unlock()
    }

    /// Test seam: drop all cached modules (cold-start a warm cache).
    func removeAll() {
        lock.lock()
        entries.removeAll()
        lru.removeAll()
        lock.unlock()
    }

    /// Caller must hold `lock`.
    private func touch(_ key: String) {
        guard let index = lru.firstIndex(of: key) else { return }
        lru.remove(at: index)
        lru.append(key)
    }

    /// Caller must hold `lock`.
    private func evictIfNeeded() {
        while lru.count > maxModuleCount {
            let evicted = lru.removeFirst()
            entries[evicted] = nil
        }
    }
}
