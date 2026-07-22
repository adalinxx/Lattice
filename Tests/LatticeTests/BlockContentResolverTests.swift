import XCTest
@testable import Lattice
import ArrayTrie
import cashew
#if canImport(os)
import os
#endif
import UInt256

final class BlockContentResolverTests: XCTestCase {
    func testBuilderReturnsTransitionWithoutWritingToFetcher() async throws {
        let fetcher = TestVolumeFetcher()
        let body = TransactionBody(
            accountActions: [AccountAction(owner: "alice", delta: 10)],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: ["alice"],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let transaction = Transaction(
            signatures: ["alice": "sig"],
            body: try HeaderImpl(node: body)
        )

        let result = try await BlockBuilder.buildGenesisWithTransition(
            spec: testSpec(directory: "Nexus"),
            transactions: [transaction],
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )

        XCTAssertFalse(result.stateDiff.isEmpty)
        XCTAssertEqual(
            try result.materializedPostState.map { try LatticeStateHeader(node: $0).rawCID },
            result.block.postState.rawCID
        )

        _ = try await BlockBuilder.buildBlockWithTransition(
            previous: result.block,
            timestamp: 2,
            target: UInt256.max,
            fetcher: fetcher
        )
        XCTAssertTrue(fetcher.entries.isEmpty)
    }

    func testValidationPathsUseExactReceiptKeys() {
        let receipt = ReceiptAction(
            withdrawer: "withdrawer",
            nonce: 7,
            demander: "demander",
            amountDemanded: 9,
            directory: "Child"
        )
        let withdrawal = WithdrawalAction(
            withdrawer: "withdrawer",
            nonce: 7,
            demander: "demander",
            amountDemanded: 9,
            amountWithdrawn: 9
        )
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [receipt],
            withdrawalActions: [withdrawal],
            signers: [],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus", "Child"]
        )

        let paths = Block.validationPaths(transactionBodies: [body])
        XCTAssertEqual(
            paths.get([PREV_STATE_PROPERTY, RECEIPT_STATE_PROPERTY, ReceiptKey(receiptAction: receipt).description]),
            .targeted
        )
        XCTAssertEqual(
            paths.get([PARENT_STATE_PROPERTY, RECEIPT_STATE_PROPERTY, ReceiptKey(withdrawalAction: withdrawal, directory: "Child").description]),
            .targeted
        )
        XCTAssertNil(paths.get([PREV_STATE_PROPERTY, RECEIPT_STATE_PROPERTY, ""]))
        XCTAssertNil(paths.get([PARENT_STATE_PROPERTY, RECEIPT_STATE_PROPERTY, ""]))
    }

    func testResolveBlockContentIncludesTransactionsAndSpecButLeavesChildrenIndependent() async throws {
        let fetcher = TestVolumeFetcher()
        let parent = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Nexus"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        try await VolumeImpl<Block>(node: parent).storeBlockContent(storer: fetcher)

        let txBody = TransactionBody(
            accountActions: [AccountAction(owner: "alice", delta: 10)],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: ["alice"],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let tx = Transaction(signatures: ["alice": "sig"], body: try! HeaderImpl(node: txBody))
        let child = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Child"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let block = try await buildAndStoreBlock(
            previous: parent,
            transactions: [tx],
            children: ["Child": child],
            timestamp: 2,
            target: UInt256.max,
            nonce: 0,
            fetcher: fetcher
        )
        let contentOnly = TestVolumeFetcher()
        try await VolumeImpl<Block>(node: block).storeBlockContent(storer: contentOnly)

        let header = VolumeImpl<Block>(rawCID: try! VolumeImpl<Block>(node: block).rawCID)
        let resolved = try await header.resolveBlockContent(fetcher: contentOnly)
        let resolvedBlock = try XCTUnwrap(resolved.node)

        XCTAssertNotNil(resolvedBlock.spec.node)
        XCTAssertNotNil(resolvedBlock.transactions.node)
        XCTAssertNil(resolvedBlock.children.node)
        // postState is owned but excluded from the content package — left unresolved.
        XCTAssertNil(resolvedBlock.postState.node)
        // Independent roots are omitted by the content policy; their CID
        // commitments survive intact.
        XCTAssertEqual(resolvedBlock.parent?.rawCID, block.parent?.rawCID)
        XCTAssertEqual(resolvedBlock.prevState.rawCID, block.prevState.rawCID)
        XCTAssertEqual(resolvedBlock.parentState.rawCID, block.parentState.rawCID)

        let transactions = try XCTUnwrap(resolvedBlock.transactions.node?.allKeysAndValues())
        XCTAssertEqual(transactions.count, 1)
        let resolvedTx = try XCTUnwrap(transactions.values.first)
        XCTAssertNotNil(resolvedTx.node)
        XCTAssertNotNil(resolvedTx.node?.body.node)

        XCTAssertEqual(resolvedBlock.children.rawCID, block.children.rawCID)
        XCTAssertNil(contentOnly.entries[block.children.rawCID])
    }

    func testStoreBlockCopiesTheSameValidationPackageFromNodefulAndDecodedBlocks() async throws {
        let source = TestVolumeFetcher()
        let nodeDestination = TestVolumeFetcher()
        let decodedDestination = TestVolumeFetcher()
        let unresolvedDestination = TestVolumeFetcher()
        let genesisResult = try await BlockBuilder.buildGenesisWithTransition(
            spec: testSpec(directory: "Nexus"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let genesis = try await storeBuiltBlock(genesisResult, in: source)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: "alice", delta: 10)],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: ["alice"],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let transaction = Transaction(
            signatures: ["alice": "sig"],
            body: try HeaderImpl(node: body)
        )
        let child = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Child"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let block = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [transaction],
            children: ["Child": child],
            timestamp: 2,
            target: UInt256.max,
            nonce: 0,
            fetcher: source
        )
        let nodeful = try VolumeImpl<Block>(node: block)
        try await nodeful.storeBlock(fetcher: source, storer: source)

        let cid = nodeful.rawCID
        let decoded = try await VolumeImpl<Block>(rawCID: cid).resolveBlockContent(fetcher: source)
        XCTAssertNil(decoded.node?.postState.node)

        try await nodeful.storeBlock(fetcher: source, storer: nodeDestination)
        try await decoded.storeBlock(fetcher: source, storer: decodedDestination)
        let unresolved = VolumeImpl<Block>(rawCID: cid)
        try await unresolved.storeBlock(fetcher: source, storer: unresolvedDestination)

        XCTAssertEqual(nodeDestination.entries, decodedDestination.entries)
        XCTAssertEqual(nodeDestination.entries, unresolvedDestination.entries)
        XCTAssertTrue(nodeDestination.volumeRoots.contains(cid))
        XCTAssertTrue(nodeDestination.volumeRoots.contains(block.spec.rawCID))
        XCTAssertTrue(nodeDestination.volumeRoots.contains(block.prevState.rawCID))
        XCTAssertTrue(nodeDestination.volumeRoots.contains(try VolumeImpl<Transaction>(node: transaction).rawCID))
        XCTAssertFalse(nodeDestination.contains(rawCid: block.postState.rawCID))
        XCTAssertFalse(nodeDestination.contains(rawCid: try XCTUnwrap(block.parent).rawCID))
        XCTAssertFalse(nodeDestination.volumeRoots.contains(block.postState.rawCID))
        XCTAssertFalse(nodeDestination.volumeRoots.contains(try XCTUnwrap(block.parent).rawCID))
        XCTAssertFalse(nodeDestination.volumeRoots.contains(try VolumeImpl<Block>(node: child).rawCID))

        let copied = try await VolumeImpl<Block>(rawCID: cid).resolveBlockContent(fetcher: decodedDestination)
        XCTAssertNotNil(copied.node?.transactions.node)
        let prevState = try await block.prevState.resolve(
            paths: [[ACCOUNT_STATE_PROPERTY, "alice"]: .targeted],
            fetcher: decodedDestination
        )
        XCTAssertNil(try prevState.node?.accountState.node?.get(key: "alice"))
    }

    func testStoreBlockIncludesPrevStateRootWithoutTransactions() async throws {
        let source = TestVolumeFetcher()
        let destination = TestVolumeFetcher()
        let genesisResult = try await BlockBuilder.buildGenesisWithTransition(
            spec: testSpec(directory: "Nexus"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let genesis = try await storeBuiltBlock(genesisResult, in: source)
        let block = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2,
            target: UInt256.max,
            nonce: 0,
            fetcher: source
        )
        let nodeful = try VolumeImpl<Block>(node: block)
        try await nodeful.storeBlock(fetcher: source, storer: source)
        let cid = nodeful.rawCID
        let decoded = try await VolumeImpl<Block>(rawCID: cid).resolveBlockContent(fetcher: source)

        try await decoded.storeBlock(fetcher: source, storer: destination)

        let prevState = try await block.prevState.resolve(fetcher: destination)
        XCTAssertNotNil(prevState.node)
    }

    func testStoreBlockIncludesPolicyModulesNeededForFreshGenesisValidation() async throws {
        let source = StorableFetcher()
        let policy = try await storeWasmPolicy(
            accepts: true,
            scope: .transaction,
            fetcher: source
        )
        let spec = testSpec(directory: "Nexus", wasmPolicies: [policy])
        let result = try await BlockBuilder.buildGenesisWithTransition(
            spec: spec,
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let genesis = try await storeBuiltBlock(result, in: source)
        let header = try VolumeImpl<Block>(node: genesis)
        let destination = StorableFetcher()

        try await header.storeBlock(fetcher: source, storer: destination)
        XCTAssertTrue(destination.contains(rawCid: policy.moduleCID))
        let roots = destination.volumeRoots()
        XCTAssertTrue(roots.contains(header.rawCID))
        XCTAssertTrue(roots.contains(policy.moduleCID))
        XCTAssertTrue(roots.contains(LatticeState.emptyHeader.rawCID))
        let emptyState = try XCTUnwrap(LatticeState.emptyHeader.node)
        XCTAssertTrue(roots.contains(emptyState.accountState.rawCID))
        XCTAssertTrue(roots.contains(emptyState.generalState.rawCID))
        XCTAssertTrue(roots.contains(emptyState.depositState.rawCID))
        XCTAssertTrue(roots.contains(emptyState.genesisState.rawCID))
        XCTAssertTrue(roots.contains(emptyState.receiptState.rawCID))

        let copied = try await VolumeImpl<Block>(rawCID: header.rawCID)
            .resolveBlockContent(fetcher: destination)
        let block = try XCTUnwrap(copied.node)
        let (valid, _) = try await block.validateGenesis(
            fetcher: destination,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        XCTAssertTrue(valid)
    }
}

private func testSpec(
    directory: String,
    wasmPolicies: [WasmPolicyRef] = []
) -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1,
        halvingInterval: 1_000,
        wasmPolicies: wasmPolicies
    )
}

/// A flat in-memory CAS: stores every node by CID and fetches it back. cashew
/// 3.x resolution is per-CID over a plain `Fetcher`; there is no `VolumeAware`
/// enter/exit side-channel, so a content-by-CID dictionary is all that
/// `resolveBlockContent` needs.
private final class TestVolumeFetcher: Fetcher, Storer, VolumeStorer, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String: Data]())
    private let roots = OSAllocatedUnfairLock(initialState: Set<String>())

    func store(entries: [String: Data]) async {
        state.withLock { $0.merge(entries) { _, new in new } }
    }

    func store(volume: SerializedVolume) async {
        roots.withLock { _ = $0.insert(volume.root) }
        state.withLock { $0.merge(volume.entries) { _, new in new } }
    }

    func contains(rawCid: String) -> Bool {
        state.withLock { $0[rawCid] != nil }
    }

    var entries: [String: Data] {
        state.withLock { $0 }
    }

    var volumeRoots: Set<String> {
        roots.withLock { $0 }
    }

    func fetch(rawCid: String) async throws -> Data {
        guard let data = state.withLock({ $0[rawCid] }) else { throw cashew.FetcherError.notFound(rawCid) }
        return data
    }
}
