import XCTest
@testable import Lattice
import cashew
import UInt256

private func childForestSpec() -> ChainSpec {
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

private func childForestHash(_ block: Block) -> String {
    try! BlockHeader(node: block).rawCID
}

private func submitChildForestBlock(_ block: Block, to chain: ChainState) async -> SubmissionResult {
    await chain.submitTestBlock(blockHeader: try! BlockHeader(node: block), block: block)
}

private func makeChildForestRoots() async throws -> (StorableFetcher, Block, Block) {
    let fetcher = StorableFetcher()
    let first = try await buildAndStoreGenesis(
        spec: childForestSpec(),
        timestamp: 1_000_000,
        target: UInt256.max,
        nonce: 1,
        fetcher: fetcher
    )
    let second = try await buildAndStoreGenesis(
        spec: childForestSpec(),
        timestamp: 1_001_000,
        target: UInt256.max,
        nonce: 2,
        fetcher: fetcher
    )
    return (fetcher, first, second)
}

@MainActor
final class ChildRootForestTests: XCTestCase {
    func testExactTieKeepsEachIncumbentRoot() async throws {
        let (_, first, second) = try await makeChildForestRoots()
        let firstHash = childForestHash(first)
        let secondHash = childForestHash(second)
        let firstIncumbent = ChainState.fromGenesis(block: first)
        let secondIncumbent = ChainState.fromGenesis(block: second)

        let firstResult = await submitChildForestBlock(second, to: firstIncumbent)
        let secondResult = await submitChildForestBlock(first, to: secondIncumbent)
        let firstTip = await firstIncumbent.getMainChainTip()
        let secondTip = await secondIncumbent.getMainChainTip()
        let firstContainsSecond = await firstIncumbent.contains(blockHash: secondHash)
        let secondContainsFirst = await secondIncumbent.contains(blockHash: firstHash)

        XCTAssertTrue(firstResult.addedBlock)
        XCTAssertTrue(secondResult.addedBlock)
        XCTAssertEqual(firstTip, firstHash)
        XCTAssertEqual(secondTip, secondHash)
        XCTAssertTrue(firstContainsSecond)
        XCTAssertTrue(secondContainsFirst)
    }

    func testStrictlyHeavierRootForestIsIndependentOfInsertionOrder() async throws {
        let (fetcher, incumbentRoot, sideRoot) = try await makeChildForestRoots()
        let sideChild = try await buildAndStoreBlock(
            previous: sideRoot,
            timestamp: sideRoot.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 3,
            fetcher: fetcher
        )
        let expectedTip = childForestHash(sideChild)
        let parentFirst = ChainState.fromGenesis(block: incumbentRoot)
        let childFirst = ChainState.fromGenesis(block: incumbentRoot)

        _ = await submitChildForestBlock(sideRoot, to: parentFirst)
        _ = await submitChildForestBlock(sideChild, to: parentFirst)

        let orphanResult = await submitChildForestBlock(sideChild, to: childFirst)
        XCTAssertTrue(orphanResult.needsParentBlock)
        _ = await submitChildForestBlock(sideRoot, to: childFirst)

        let parentFirstTip = await parentFirst.getMainChainTip()
        let childFirstTip = await childFirst.getMainChainTip()
        XCTAssertEqual(parentFirstTip, expectedTip)
        XCTAssertEqual(childFirstTip, expectedTip)
    }

    func testRootArrivalKeepsSelectedDescendantSnapshot() async throws {
        let (fetcher, incumbentRoot, sideRoot) = try await makeChildForestRoots()
        let child = try await buildAndStoreBlock(
            previous: sideRoot,
            timestamp: sideRoot.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 5,
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: incumbentRoot)

        _ = await submitChildForestBlock(child, to: chain)
        _ = await submitChildForestBlock(sideRoot, to: chain)

        let snapshot = await chain.tipSnapshot
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, childForestHash(child))
        XCTAssertEqual(snapshot?.tipHeight, child.height)
        XCTAssertEqual(snapshot?.postStateCID, child.postState.rawCID)
        XCTAssertEqual(snapshot?.prevStateCID, child.prevState.rawCID)
    }

    func testForestPersistenceRestoresEveryRootAndCanonicalTip() async throws {
        let (fetcher, incumbentRoot, sideRoot) = try await makeChildForestRoots()
        let sideChild = try await buildAndStoreBlock(
            previous: sideRoot,
            timestamp: sideRoot.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 4,
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: incumbentRoot)
        _ = await submitChildForestBlock(sideRoot, to: chain)
        _ = await submitChildForestBlock(sideChild, to: chain)
        let canonicalTip = await chain.getMainChainTip()

        let restored = try ChainState.restore(from: await chain.persist())

        let restoredTip = await restored.getMainChainTip()
        let containsIncumbent = await restored.contains(blockHash: childForestHash(incumbentRoot))
        let containsSideRoot = await restored.contains(blockHash: childForestHash(sideRoot))
        let containsSideChild = await restored.contains(blockHash: childForestHash(sideChild))
        XCTAssertEqual(restoredTip, canonicalTip)
        XCTAssertTrue(containsIncumbent)
        XCTAssertTrue(containsSideRoot)
        XCTAssertTrue(containsSideChild)
    }

    func testRestoreRejectsStrictlyHeavierPrunedSideRoot() {
        let mainContribution = VerifiedWorkContribution(id: "grind:main", work: UInt256(1))
        let sideContribution = VerifiedWorkContribution(id: "grind:side", work: UInt256(2))
        let mainRoot = PersistedBlockMeta(
            blockHash: "main-root",
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            workContributions: [mainContribution],
            cumulativeWork: UInt256(1).toHexString()
        )
        let sideRoot = PersistedBlockMeta(
            blockHash: "side-root",
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            workContributions: [sideContribution],
            cumulativeWork: UInt256(2).toHexString(),
            subtreeWeight: UInt256(2).toHexString()
        )
        let persisted = PersistedChainState(
            chainTip: mainRoot.blockHash,
            mainChainHashes: [mainRoot.blockHash],
            blocks: [mainRoot],
            prunedBlocks: [sideRoot]
        )
        XCTAssertThrowsError(try ChainState.restore(from: persisted)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }
}
