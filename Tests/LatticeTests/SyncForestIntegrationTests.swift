import Foundation
import XCTest
@testable import Lattice
import cashew
import UInt256

private let syncIntegrationNoopStore: @Sendable (String, Data) async -> Void = { _, _ in }

private func syncIntegrationSpec() -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1_024,
        halvingInterval: 10_000,
        retargetWindow: 5
    )
}

private func syncIntegrationCID(_ block: Block) -> String {
    try! BlockHeader(node: block).rawCID
}

private func syncIntegrationNow() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
}

final class SyncForestIntegrationTests: XCTestCase {
    private let easy = UInt256.max

    private func genesis(
        timestamp: Int64,
        fetcher: StorableFetcher,
        nonce: UInt64 = 0
    ) async throws -> Block {
        try await buildAndStoreGenesis(
            spec: syncIntegrationSpec(),
            timestamp: timestamp,
            target: easy,
            nonce: nonce,
            fetcher: fetcher
        )
    }

    func testLevelConfiguresForestSyncer() async throws {
        let fetcher = StorableFetcher()
        let parentRoot = try await genesis(
            timestamp: syncIntegrationNow() - 30_000,
            fetcher: fetcher
        )
        let childRoot = try await genesis(
            timestamp: syncIntegrationNow() - 20_000,
            fetcher: fetcher,
            nonce: 1
        )
        let parent = ChainLevel(chain: ChainState.fromGenesis(block: parentRoot))
        let level = try await parent.attachRestoredChildForTesting(to: "child", genesisBlock: childRoot)
        let syncer = try await level.makeSyncer(
            fetcher: fetcher,
            store: syncIntegrationNoopStore
        )

        do {
            _ = try await syncer.syncFull(peerTipCID: syncIntegrationCID(childRoot))
            XCTFail("a linear sync result must not stand in for a child-root forest")
        } catch SyncError.forestRequiresIncrementalAdmission {
            // expected
        }
    }

    func testForestApplyAndResetRefuseToDiscardCompetingRoots() async throws {
        let fetcher = StorableFetcher()
        let first = try await genesis(
            timestamp: syncIntegrationNow() - 30_000,
            fetcher: fetcher,
            nonce: 1
        )
        let second = try await genesis(
            timestamp: syncIntegrationNow() - 20_000,
            fetcher: fetcher,
            nonce: 2
        )
        let firstHash = syncIntegrationCID(first)
        let secondHash = syncIntegrationCID(second)
        let parentRoot = try await genesis(
            timestamp: syncIntegrationNow() - 40_000,
            fetcher: fetcher,
            nonce: 3
        )
        let parent = ChainLevel(chain: ChainState.fromGenesis(block: parentRoot))
        let level = try await parent.attachRestoredChildForTesting(to: "child", genesisBlock: first)
        let chain = await level.chain
        let secondSubmission = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try BlockHeader(node: second),
            block: second
        )
        XCTAssertTrue(secondSubmission.addedBlock)

        let syncer = ChainSyncer(
            fetcher: fetcher,
            store: syncIntegrationNoopStore,
            genesisBlockHash: firstHash
        )
        let result = try await syncer.syncFull(peerTipCID: firstHash)

        do {
            try await level.applySync(
                result: result,
                retentionDepth: RECENT_BLOCK_DISTANCE,
                prepare: { _ in .ready }
            )
            XCTFail("linear sync must not replace a forest")
        } catch SyncError.forestRequiresIncrementalAdmission {
            // expected
        }

        do {
            try await level.resetAllToGenesis(
                retentionDepth: RECENT_BLOCK_DISTANCE,
                prepare: { _ in .ready }
            )
            XCTFail("canonical-root reset must not discard a forest")
        } catch SyncError.forestRequiresIncrementalAdmission {
            // expected
        }

        let containsFirst = await chain.contains(blockHash: firstHash)
        let containsSecond = await chain.contains(blockHash: secondHash)
        XCTAssertTrue(containsFirst)
        XCTAssertTrue(containsSecond)
    }

    func testForestDescendantPreflightLeavesParentUntouched() async throws {
        let fetcher = StorableFetcher()
        let root = try await genesis(
            timestamp: syncIntegrationNow() - 30_000,
            fetcher: fetcher
        )
        let nextBlock = try await buildAndStoreBlock(
            previous: root,
            timestamp: root.timestamp + 1_000,
            target: easy,
            nextTarget: easy,
            nonce: 1,
            fetcher: fetcher
        )
        let rootHash = syncIntegrationCID(root)
        let level = ChainLevel(chain: ChainState.fromGenesis(block: root))
        let childRoot = try await genesis(
            timestamp: root.timestamp + 2_000,
            fetcher: fetcher,
            nonce: 2
        )
        _ = try await level.attachRestoredChildForTesting(to: "child", genesisBlock: childRoot)

        let syncer = ChainSyncer(
            fetcher: fetcher,
            store: syncIntegrationNoopStore,
            genesisBlockHash: rootHash
        )
        let result = try await syncer.syncFull(peerTipCID: syncIntegrationCID(nextBlock))

        do {
            try await level.applySync(
                result: result,
                retentionDepth: RECENT_BLOCK_DISTANCE,
                prepare: { _ in .ready }
            )
            XCTFail("a forest descendant must reject before parent sync mutation")
        } catch SyncError.forestRequiresIncrementalAdmission {
            // expected
        }
        let tipAfterSync = await level.chain.getMainChainTip()
        XCTAssertEqual(tipAfterSync, rootHash)

        do {
            try await level.resetAllToGenesis(
                retentionDepth: RECENT_BLOCK_DISTANCE,
                prepare: { _ in .ready }
            )
            XCTFail("a forest descendant must reject before parent reset mutation")
        } catch SyncError.forestRequiresIncrementalAdmission {
            // expected
        }
        let tipAfterReset = await level.chain.getMainChainTip()
        XCTAssertEqual(tipAfterReset, rootHash)
    }

    func testParentAdmissionDoesNotMutateChildRuntime() async throws {
        let fetcher = StorableFetcher()
        let parentRoot = try await genesis(
            timestamp: syncIntegrationNow() - 20_000,
            fetcher: fetcher
        )
        let parentBlock = try await buildAndStoreBlock(
            previous: parentRoot,
            timestamp: parentRoot.timestamp + 1_000,
            target: easy,
            nextTarget: easy,
            nonce: 1,
            fetcher: fetcher
        )
        let parent = ChainLevel(chain: ChainState.fromGenesis(block: parentRoot))
        let childRoot = try await genesis(
            timestamp: parentRoot.timestamp + 2_000,
            fetcher: fetcher,
            nonce: 2
        )
        let child = try await parent.attachRestoredChildForTesting(to: "child", genesisBlock: childRoot)
        let childChain = await child.chain
        let childTipBefore = await childChain.getMainChainTip()

        let result = await parent.admitBlockHeaderChainLocal(
            try BlockHeader(node: parentBlock),
            fetcher: fetcher,
            prepare: { _, _, _ in .ready }
        )
        let childTipAfter = await childChain.getMainChainTip()

        guard case .canonicalized = result else {
            return XCTFail("parent block must canonicalize")
        }
        XCTAssertEqual(childTipAfter, childTipBefore)
    }

    func testApplySyncRequiresDurablePreparationAndRejectsAStaleProjection() async throws {
        let fetcher = StorableFetcher()
        let root = try await genesis(
            timestamp: syncIntegrationNow() - 30_000,
            fetcher: fetcher
        )
        let remoteTip = try await buildAndStoreBlock(
            previous: root,
            timestamp: root.timestamp + 1_000,
            target: easy,
            nextTarget: easy,
            nonce: 1,
            fetcher: fetcher
        )
        let localTip = try await buildAndStoreBlock(
            previous: root,
            timestamp: root.timestamp + 2_000,
            target: easy,
            nextTarget: easy,
            nonce: 2,
            fetcher: fetcher
        )
        let rootHash = syncIntegrationCID(root)
        let localHeader = try BlockHeader(node: localTip)
        let level = ChainLevel(chain: ChainState.fromGenesis(block: root))
        let syncer = ChainSyncer(
            fetcher: fetcher,
            store: syncIntegrationNoopStore,
            genesisBlockHash: rootHash
        )
        let result = try await syncer.syncFull(peerTipCID: syncIntegrationCID(remoteTip))

        do {
            try await level.applySync(
                result: result,
                retentionDepth: RECENT_BLOCK_DISTANCE,
                prepare: { _ in .storageFailed }
            )
            XCTFail("sync state must be durable before replacement")
        } catch SyncError.durablePreparationFailed {
            // expected
        }
        let tipAfterDurableFailure = await level.chain.getMainChainTip()
        XCTAssertEqual(tipAfterDurableFailure, rootHash)

        do {
            try await level.applySync(
                result: result,
                retentionDepth: RECENT_BLOCK_DISTANCE,
                prepare: { _ in
                    let admission = await level.admitBlockHeaderChainLocal(
                        localHeader,
                        fetcher: fetcher,
                        prepare: { _, _, _ in .ready }
                    )
                    guard case .canonicalized = admission else { return .storageFailed }
                    return .ready
                }
            )
            XCTFail("a sync projection cannot overwrite intervening admission")
        } catch SyncError.staleChainState {
            // expected
        }
        let tipAfterStaleProjection = await level.chain.getMainChainTip()
        XCTAssertEqual(tipAfterStaleProjection, localHeader.rawCID)
    }

    func testSyncReportsFutureGenesisAsNotYetAdmissible() async throws {
        let fetcher = StorableFetcher()
        let root = try await genesis(
            timestamp: syncIntegrationNow() + Block.maxFutureDriftMilliseconds + 60_000,
            fetcher: fetcher
        )
        let syncer = ChainSyncer(
            fetcher: fetcher,
            store: syncIntegrationNoopStore,
            genesisBlockHash: syncIntegrationCID(root)
        )

        do {
            _ = try await syncer.syncFull(peerTipCID: syncIntegrationCID(root))
            XCTFail("a future block must remain retryable rather than invalid")
        } catch SyncError.notYetAdmissible(let height) {
            XCTAssertEqual(height, 0)
        }
    }

}
