import XCTest
@testable import Lattice
import ArrayTrie
import cashew
#if canImport(os)
import os
#endif
import UInt256

final class BlockContentResolverTests: XCTestCase {
    func testResolveBlockContentIncludesTransactionsAndSpecButExcludesStateAndChildBlocks() async throws {
        let fetcher = TestVolumeFetcher()
        let parent = try await BlockBuilder.buildGenesis(
            spec: testSpec(directory: "Nexus"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        try VolumeImpl<Block>(node: parent).storeRecursively(storer: fetcher)

        let txBody = TransactionBody(
            accountActions: [AccountAction(owner: "alice", delta: 10)],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: ["alice"],
            fee: 0,
            nonce: 0
        )
        let tx = Transaction(signatures: ["alice": "sig"], body: try! HeaderImpl(node: txBody))
        let child = try await BlockBuilder.buildGenesis(
            spec: testSpec(directory: "Child"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let block = try await BlockBuilder.buildBlock(
            previous: parent,
            transactions: [tx],
            children: ["Child": child],
            timestamp: 2,
            target: UInt256.max,
            nonce: 0,
            fetcher: fetcher
        )
        try VolumeImpl<Block>(node: block).storeRecursively(storer: fetcher)

        let header = VolumeImpl<Block>(rawCID: try! VolumeImpl<Block>(node: block).rawCID)
        let resolved = try await header.resolveBlockContent(fetcher: fetcher)
        let resolvedBlock = try XCTUnwrap(resolved.node)

        // Owned children IN the content package are resolved.
        XCTAssertNotNil(resolvedBlock.spec.node)
        XCTAssertNotNil(resolvedBlock.transactions.node)
        XCTAssertNotNil(resolvedBlock.children.node)
        // postState is owned but excluded from the content package — left unresolved.
        XCTAssertNil(resolvedBlock.postState.node)
        // parent/prevState/parentState are References (not children): structurally
        // never pulled by content resolution; their CID commitments survive intact.
        XCTAssertEqual(resolvedBlock.parent?.rawCID, block.parent?.rawCID)
        XCTAssertEqual(resolvedBlock.prevState.rawCID, block.prevState.rawCID)
        XCTAssertEqual(resolvedBlock.parentState.rawCID, block.parentState.rawCID)

        let transactions = try XCTUnwrap(resolvedBlock.transactions.node?.allKeysAndValues())
        XCTAssertEqual(transactions.count, 1)
        let resolvedTx = try XCTUnwrap(transactions.values.first)
        XCTAssertNotNil(resolvedTx.node)
        XCTAssertNotNil(resolvedTx.node?.body.node)

        let children = try XCTUnwrap(resolvedBlock.children.node?.allKeysAndValues())
        XCTAssertEqual(children.count, 1)
        let childHeader = try XCTUnwrap(children["Child"])
        XCTAssertNil(childHeader.node)
    }
}

private func testSpec(directory: String) -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1,
        halvingInterval: 1_000
    )
}

/// A flat in-memory CAS: stores every node by CID and fetches it back. cashew
/// 3.x resolution is per-CID over a plain `Fetcher`; there is no `VolumeAware`
/// enter/exit side-channel, so a content-by-CID dictionary is all that
/// `resolveBlockContent` needs.
private final class TestVolumeFetcher: Fetcher, Storer, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String: Data]())

    func store(rawCid: String, data: Data) throws {
        state.withLock { $0[rawCid] = data }
    }

    func contains(rawCid: String) -> Bool {
        state.withLock { $0[rawCid] != nil }
    }

    func fetch(rawCid: String) async throws -> Data {
        guard let data = state.withLock({ $0[rawCid] }) else { throw FetcherError.notFound(rawCid) }
        return data
    }
}
