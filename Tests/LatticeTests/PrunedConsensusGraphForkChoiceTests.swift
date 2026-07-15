import Foundation
import XCTest
@testable import Lattice
import cashew
import UInt256

final class PrunedConsensusGraphForkChoiceTests: XCTestCase {
    private var mainHashes: Set<String> { ["G", "M1", "M2"] }

    private func heavyFork() -> [BlockMeta] {
        let mainWork = UInt256(2)
        let forkWork = UInt256(1)
        return [
            makeBlockMeta(hash: "G", height: 0, childHashes: ["M1", "F1"], work: forkWork, cumulativeWork: UInt256(1)),
            makeBlockMeta(hash: "M1", previousHash: "G", height: 1, childHashes: ["M2"], work: mainWork, cumulativeWork: UInt256(3)),
            makeBlockMeta(hash: "M2", previousHash: "M1", height: 2, work: mainWork, cumulativeWork: UInt256(5)),
            makeBlockMeta(hash: "F1", previousHash: "G", height: 1, childHashes: ["F2"], work: forkWork, cumulativeWork: UInt256(2)),
            makeBlockMeta(hash: "F2", previousHash: "F1", height: 2, childHashes: ["F3"], work: forkWork, cumulativeWork: UInt256(3)),
            makeBlockMeta(hash: "F3", previousHash: "F2", height: 3, childHashes: ["F4"], work: forkWork, cumulativeWork: UInt256(4)),
            makeBlockMeta(hash: "F4", previousHash: "F3", height: 4, childHashes: ["F5"], work: forkWork, cumulativeWork: UInt256(5)),
            makeBlockMeta(hash: "F5", previousHash: "F4", height: 5, work: forkWork, cumulativeWork: UInt256(6)),
        ]
    }

    private func pruneHeavyTail(_ chain: ChainState) async {
        await chain.pruneBlocksAtIndex(3)
        await chain.pruneBlocksAtIndex(4)
        await chain.pruneBlocksAtIndex(5)
    }

    func testPruningRetainsWeightAndLinkage() async {
        let oracle = makeChain(blocks: heavyFork(), mainChainHashes: mainHashes)
        let expected = await oracle.heaviestDescent(fromHash: "F1")
        let expectedSubtree = await oracle.subtreeWeight(forHash: "F1")
        let chain = makeChain(blocks: heavyFork(), mainChainHashes: mainHashes)

        await pruneHeavyTail(chain)

        let retainedF3 = await chain.getConsensusBlock(hash: "F3")
        let retainedF5 = await chain.getConsensusBlock(hash: "F5")
        let f3LifecycleAvailable = retainedF3?.stateDiff != nil
        let f5LifecycleAvailable = retainedF5?.stateDiff != nil
        let actual = await chain.heaviestDescent(fromHash: "F1")
        let actualSubtree = await chain.subtreeWeight(forHash: "F1")
        let retainedWork = await chain.getCumulativeWork(forHash: "F5")
        XCTAssertNotNil(retainedF3)
        XCTAssertNotNil(retainedF5)
        XCTAssertFalse(f3LifecycleAvailable)
        XCTAssertFalse(f5LifecycleAvailable)
        XCTAssertEqual(actual?.tipHash, expected?.tipHash)
        XCTAssertEqual(actual?.cumulativeWork, expected?.cumulativeWork)
        XCTAssertEqual(actualSubtree, expectedSubtree)
        XCTAssertEqual(retainedWork, UInt256(6))
    }

    func testPrunedConsensusGraphSurvivesPersistRestore() async throws {
        let chain = makeChain(blocks: heavyFork(), mainChainHashes: mainHashes)
        await pruneHeavyTail(chain)
        let fork = await chain.getConsensusBlock(hash: "F1")!
        _ = await chain.checkForReorg(block: fork)

        let restored = try ChainState.restore(from: await chain.persist())

        let retainedMeta = await restored.getConsensusBlock(hash: "F5")
        let lifecycleAvailable = retainedMeta?.stateDiff != nil
        let heaviest = await restored.heaviestDescent(fromHash: "F1")
        let subtree = await restored.subtreeWeight(forHash: "F1")
        XCTAssertNotNil(retainedMeta)
        XCTAssertFalse(lifecycleAvailable)
        XCTAssertEqual(heaviest?.tipHash, "F5")
        XCTAssertEqual(heaviest?.cumulativeWork, UInt256(6))
        XCTAssertEqual(subtree, UInt256(5))
    }

    func testRestoreRejectsMissingOrUndecodableConsensusWeight() {
        let rootContribution = VerifiedWorkContribution(id: "grind:G", work: UInt256(1))
        let forkContribution = VerifiedWorkContribution(id: "grind:F", work: UInt256(1))
        let root = PersistedBlockMeta(
            blockHash: "G",
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: ["F"],
            workContributions: [rootContribution],
            cumulativeWork: UInt256(1).toHexString()
        )

        func state(subtreeWeight: String?, cumulativeWork: String = UInt256(2).toHexString()) -> PersistedChainState {
            let fork = PersistedBlockMeta(
                blockHash: "F",
                parentBlockHash: "G",
                blockHeight: 1,
                childHashes: [],
                workContributions: [forkContribution],
                cumulativeWork: cumulativeWork,
                subtreeWeight: subtreeWeight
            )
            return PersistedChainState(
                chainTip: "G",
                mainChainHashes: ["G"],
                blocks: [root],
                prunedBlocks: [fork]
            )
        }

        for snapshot in [
            state(subtreeWeight: nil),
            state(subtreeWeight: "not-hex"),
            state(subtreeWeight: UInt256(1).toHexString(), cumulativeWork: "not-hex"),
        ] {
            XCTAssertThrowsError(try ChainState.restore(from: snapshot)) { error in
                XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
            }
        }
    }

    func testFullyAvailableHeavierForkIsInstalled() async {
        let chain = makeChain(blocks: heavyFork(), mainChainHashes: mainHashes)
        let fork = await chain.getConsensusBlock(hash: "F1")!

        _ = await chain.checkForReorg(block: fork)

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "F5")
    }

    func testPrunedHeavierForkIsInstalledAndReportsMissingBodies() async {
        let chain = makeChain(blocks: heavyFork(), mainChainHashes: mainHashes)
        await pruneHeavyTail(chain)
        let fork = await chain.getConsensusBlock(hash: "F1")!

        let reorg = await chain.checkForReorg(block: fork)

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "F5")
        XCTAssertEqual(reorg?.missingBodies, ["F3", "F4", "F5"])
    }

    func testInsertUnderLiveAncestorRetainsPrunedSiblingWeight() async throws {
        let fetcher = StorableFetcher()
        let target = UInt256(1_000)
        let work = workForTarget(target)
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 50_000
        let genesis = try await buildAndStoreGenesis(
            spec: pruningSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let a = try await pruningBlock(after: genesis, offset: 1, nonce: 1, base: base, target: target, fetcher: fetcher)
        let b = try await pruningBlock(after: a, offset: 2, nonce: 2, base: base, target: target, fetcher: fetcher)
        let c = try await pruningBlock(after: b, offset: 3, nonce: 3, base: base, target: target, fetcher: fetcher)
        let d = try await pruningBlock(after: c, offset: 4, nonce: 4, base: base, target: target, fetcher: fetcher)
        let e = try await pruningBlock(after: d, offset: 5, nonce: 5, base: base, target: target, fetcher: fetcher)
        let tip = try await pruningBlock(after: e, offset: 6, nonce: 6, base: base, target: target, fetcher: fetcher)
        for block in [a, b, c, d, e, tip] {
            _ = await chain.submitTestBlock(blockHeader: try BlockHeader(node: block), block: block)
        }
        await chain.pruneBlocksAtIndex(3)
        await chain.pruneBlocksAtIndex(4)

        let sibling = try await buildAndStoreBlock(
            previous: b,
            timestamp: base + 3_500,
            target: target,
            nonce: 99,
            fetcher: fetcher
        )
        _ = await chain.submitTestBlock(blockHeader: try BlockHeader(node: sibling), block: sibling)

        let bHash = try BlockHeader(node: b).rawCID
        var expected = UInt256.zero
        for _ in 0..<6 { expected = saturatingWorkSum(expected, work) }
        let subtree = await chain.subtreeWeight(forHash: bHash)
        XCTAssertEqual(subtree, expected)
    }

    func testReplayingPrunedBlockDoesNotRestoreLifecycleMetadata() async throws {
        let fetcher = StorableFetcher()
        let target = UInt256(1_000)
        let work = workForTarget(target)
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 50_000
        let genesis = try await buildAndStoreGenesis(
            spec: pruningSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let a = try await pruningBlock(after: genesis, offset: 1, nonce: 1, base: base, target: target, fetcher: fetcher)
        let b = try await pruningBlock(after: a, offset: 2, nonce: 2, base: base, target: target, fetcher: fetcher)
        let c = try await pruningBlock(after: b, offset: 3, nonce: 3, base: base, target: target, fetcher: fetcher)
        let d = try await pruningBlock(after: c, offset: 4, nonce: 4, base: base, target: target, fetcher: fetcher)
        let e = try await pruningBlock(after: d, offset: 5, nonce: 5, base: base, target: target, fetcher: fetcher)
        for block in [a, b, c, d, e] {
            _ = await chain.submitTestBlock(blockHeader: try BlockHeader(node: block), block: block)
        }
        await chain.pruneBlocksAtIndex(3)
        await chain.pruneBlocksAtIndex(4)
        let cHash = try BlockHeader(node: c).rawCID
        let lifecycleRetainedAfterPrune = (await chain.getConsensusBlock(hash: cHash))?.stateDiff
        XCTAssertNil(lifecycleRetainedAfterPrune)

        let replay = await chain.submitTestBlock(blockHeader: try BlockHeader(node: c), block: c)

        let expected = saturatingWorkSum(saturatingWorkSum(work, work), work)
        let subtree = await chain.subtreeWeight(forHash: cHash)
        let lifecycleAfterReplay = (await chain.getConsensusBlock(hash: cHash))?.stateDiff
        XCTAssertFalse(replay.addedBlock)
        XCTAssertFalse(replay.addedContribution)
        XCTAssertNil(lifecycleAfterReplay)
        XCTAssertEqual(subtree, expected)
    }
}

private func pruningSpec() -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1024,
        halvingInterval: 10_000,
        retargetWindow: 5
    )
}

private func pruningBlock(
    after previous: Block,
    offset: Int64,
    nonce: UInt64,
    base: Int64,
    target: UInt256,
    fetcher: StorableFetcher
) async throws -> Block {
    try await buildAndStoreBlock(
        previous: previous,
        timestamp: base + offset * 1_000,
        target: target,
        nonce: nonce,
        fetcher: fetcher
    )
}
