import Foundation
#if canImport(os)
import os
#endif
@testable import Lattice
import cashew
import UInt256
import WAT

enum FetcherError: Error {
    case notFound(String)
}

final class StorableFetcher: Fetcher, Storer, Sendable {
    private let state = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    func store(rawCid: String, data: Data) {
        state.withLock { $0[rawCid] = data }
    }

    func contains(rawCid: String) -> Bool {
        state.withLock { $0[rawCid] != nil }
    }

    func fetch(rawCid: String) async throws -> Data {
        guard let data = state.withLock({ $0[rawCid] }) else {
            throw FetcherError.notFound(rawCid)
        }
        return data
    }

    /// Synchronous lookup for non-async callers (e.g. a Network.framework receive
    /// callback that serves CAS bytes off a socket).
    func fetchSync(rawCid: String) throws -> Data {
        guard let data = state.withLock({ $0[rawCid] }) else {
            throw FetcherError.notFound(rawCid)
        }
        return data
    }
}

struct ThrowingFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw FetcherError.notFound(rawCid)
    }
}

/// Synchronous storer that collects CAS data in memory, then flushes to a StorableFetcher.
final class CollectingStorer: Storer, @unchecked Sendable {
    private var collected: [(String, Data)] = []

    func store(rawCid: String, data: Data) throws {
        collected.append((rawCid, data))
    }

    func flush(to fetcher: StorableFetcher) async {
        for (cid, data) in collected {
            await fetcher.store(rawCid: cid, data: data)
        }
    }
}

func testAddress(publicKey: String) -> String {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    try! HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
}

func signedTestTransaction(
    _ body: TransactionBody,
    by keyPair: (privateKey: String, publicKey: String)
) -> Transaction {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    let header = try! HeaderImpl<TransactionBody>(node: body)
    let signature = CryptoUtils.sign(message: header.rawCID, privateKeyHex: keyPair.privateKey)!
    return Transaction(signatures: [keyPair.publicKey: signature], body: header)
}

func buildPremineGenesis(
    spec: ChainSpec,
    owner: (privateKey: String, publicKey: String),
    fetcher: StorableFetcher,
    timestamp: Int64,
    target: UInt256 = UInt256(1000)
) async throws -> Block {
    let ownerAddress = testAddress(publicKey: owner.publicKey)
    let body = TransactionBody(
        accountActions: [AccountAction(owner: ownerAddress, delta: Int64(spec.premineAmount()))],
        actions: [],
        depositActions: [],
        genesisActions: [],
        receiptActions: [],
        withdrawalActions: [],
        signers: [ownerAddress],
        fee: 0,
        nonce: 0
    )
    return try await BlockBuilder.buildGenesis(
        spec: spec,
        transactions: [signedTestTransaction(body, by: owner)],
        timestamp: timestamp,
        target: target,
        fetcher: fetcher
    )
}

func wasmPolicyFixture(accepts: Bool) throws -> Data {
    let returnValue = accepts ? 1 : 0
    let wat = """
    (module
      (memory (export "memory") 1)
      (global $heap (mut i32) (i32.const 1024))
      (func (export "lattice_alloc") (param $len i32) (result i32)
        (local $ptr i32)
        global.get $heap
        local.set $ptr
        global.get $heap
        local.get $len
        i32.add
        global.set $heap
        local.get $ptr)
      (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
        i32.const \(returnValue))
      (func (export "lattice_validate_action") (param $ptr i32) (param $len i32) (result i32)
        i32.const \(returnValue))
    )
    """
    return Data(try wat2wasm(wat))
}

func wasmPolicyFixture(requiringSubstring needle: String) throws -> Data {
    let needleBytes = Array(needle.utf8)
    let escapedNeedle = needleBytes.map { String(format: "\\%02x", $0) }.joined()
    let wat = """
    (module
      (memory (export "memory") 1)
      (data (i32.const 16) "\(escapedNeedle)")
      (global $heap (mut i32) (i32.const 1024))
      (func (export "lattice_alloc") (param $len i32) (result i32)
        (local $ptr i32)
        global.get $heap
        local.set $ptr
        global.get $heap
        local.get $len
        i32.add
        global.set $heap
        local.get $ptr)
      (func $contains (param $ptr i32) (param $len i32) (result i32)
        (local $i i32)
        (local $j i32)
        local.get $len
        i32.const \(needleBytes.count)
        i32.lt_u
        if
          i32.const 0
          return
        end
        (block $not_found
          (loop $outer
            local.get $i
            local.get $len
            i32.const \(needleBytes.count)
            i32.sub
            i32.gt_u
            br_if $not_found
            i32.const 0
            local.set $j
            (block $mismatch
              (loop $inner
                local.get $j
                i32.const \(needleBytes.count)
                i32.eq
                if
                  i32.const 1
                  return
                end
                local.get $ptr
                local.get $i
                i32.add
                local.get $j
                i32.add
                i32.load8_u
                i32.const 16
                local.get $j
                i32.add
                i32.load8_u
                i32.ne
                br_if $mismatch
                local.get $j
                i32.const 1
                i32.add
                local.set $j
                br $inner))
            local.get $i
            i32.const 1
            i32.add
            local.set $i
            br $outer))
        i32.const 0)
      (export "lattice_validate_transaction" (func $contains))
      (export "lattice_validate_action" (func $contains))
    )
    """
    return Data(try wat2wasm(wat))
}

@discardableResult
func storeWasmPolicy(
    accepts: Bool,
    scope: WasmPolicyRef.Scope,
    fetcher: StorableFetcher,
    entrypoint: String? = nil
) throws -> WasmPolicyRef {
    let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: try wasmPolicyFixture(accepts: accepts)))
    try module.storeRecursively(storer: fetcher)
    return WasmPolicyRef(moduleCID: module.rawCID, scope: scope, entrypoint: entrypoint)
}

@discardableResult
func storeWasmPolicy(
    requiringSubstring needle: String,
    scope: WasmPolicyRef.Scope,
    fetcher: StorableFetcher,
    entrypoint: String? = nil
) throws -> WasmPolicyRef {
    let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: try wasmPolicyFixture(requiringSubstring: needle)))
    try module.storeRecursively(storer: fetcher)
    return WasmPolicyRef(moduleCID: module.rawCID, scope: scope, entrypoint: entrypoint)
}
