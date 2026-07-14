import Foundation
#if canImport(os)
import os
#endif
import ArrayTrie
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

    func store(entries: [String: Data]) async {
        state.withLock { $0.merge(entries) { _, new in new } }
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

private func stateStructurePaths() -> ArrayTrie<ResolutionStrategy> {
    // Keep trie topology and values needed for later proof selection, but leave
    // referenced payload Volumes under the owning test/node retention policy.
    var paths = ArrayTrie<ResolutionStrategy>()
    for property in LATTICE_STATE_PROPERTIES {
        paths.set([property, ""], value: .list)
    }
    return paths
}

@discardableResult
func storeBuiltBlock(
    _ result: BlockBuildResult,
    in fetcher: any Fetcher & Storer
) async throws -> Block {
    try await storeBuiltBlock(result.block, in: fetcher)
}

@discardableResult
func storeBuiltBlock(
    _ block: Block,
    in fetcher: any Fetcher & Storer
) async throws -> Block {
    let header = try BlockHeader(node: block)
    try await header.storeBlockContent(storer: fetcher)
    if block.height == 0 {
        try await LatticeState.emptyHeader.storeRecursively(storer: fetcher)
    }
    if let postState = block.postState.node {
        let state = try LatticeStateHeader(node: postState)
        let paths = stateStructurePaths()
        let indexedState = try await state.resolve(paths: paths, fetcher: fetcher)
        try await indexedState.store(paths: paths, storer: fetcher)
    }
    return block
}

/// Test local-CAS policy for fixtures that build a chain locally: retain block
/// content plus state-trie structure only when the supplied fetcher is also a
/// storer. Production `BlockBuilder` remains storage-neutral.
func buildAndStoreGenesis(
    spec: ChainSpec,
    transactions: [Transaction] = [],
    children: [String: Block] = [:],
    timestamp: Int64,
    target: UInt256,
    nonce: UInt64 = 0,
    version: UInt16 = 1,
    fetcher: Fetcher
) async throws -> Block {
    let result = try await BlockBuilder.buildGenesisWithTransition(
        spec: spec,
        transactions: transactions,
        children: children,
        timestamp: timestamp,
        target: target,
        nonce: nonce,
        version: version,
        fetcher: fetcher
    )
    guard let storer = fetcher as? (any Fetcher & Storer) else {
        return result.block
    }
    return try await storeBuiltBlock(result, in: storer)
}

/// Test local-CAS policy counterpart to ``buildAndStoreGenesis``.
func buildAndStoreBlock(
    previous: Block,
    transactions: [Transaction] = [],
    children: [String: Block] = [:],
    parentChainBlock: Block? = nil,
    timestamp: Int64,
    target: UInt256? = nil,
    nextTarget: UInt256? = nil,
    nonce: UInt64 = 0,
    fetcher: Fetcher
) async throws -> Block {
    let result = try await BlockBuilder.buildBlockWithTransition(
        previous: previous,
        transactions: transactions,
        children: children,
        parentChainBlock: parentChainBlock,
        timestamp: timestamp,
        target: target,
        nextTarget: nextTarget,
        nonce: nonce,
        fetcher: fetcher
    )
    guard let storer = fetcher as? (any Fetcher & Storer) else {
        return result.block
    }
    return try await storeBuiltBlock(result, in: storer)
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
    let result = try await BlockBuilder.buildGenesisWithTransition(
        spec: spec,
        transactions: [signedTestTransaction(body, by: owner)],
        timestamp: timestamp,
        target: target,
        fetcher: fetcher
    )
    return try await storeBuiltBlock(result, in: fetcher)
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
) async throws -> WasmPolicyRef {
    let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: try wasmPolicyFixture(accepts: accepts)))
    try await module.storeRecursively(storer: fetcher)
    return WasmPolicyRef(moduleCID: module.rawCID, scope: scope, entrypoint: entrypoint)
}

@discardableResult
func storeWasmPolicy(
    requiringSubstring needle: String,
    scope: WasmPolicyRef.Scope,
    fetcher: StorableFetcher,
    entrypoint: String? = nil
) async throws -> WasmPolicyRef {
    let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: try wasmPolicyFixture(requiringSubstring: needle)))
    try await module.storeRecursively(storer: fetcher)
    return WasmPolicyRef(moduleCID: module.rawCID, scope: scope, entrypoint: entrypoint)
}
