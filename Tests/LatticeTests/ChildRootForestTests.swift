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

private func preferredChildForestHash(_ first: String, _ second: String) -> String {
    forkChoicePrefersSegmentBase(first, over: second) ? first : second
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
    func testExactTieChoosesTheSameRootByCID() async throws {
        let (_, first, second) = try await makeChildForestRoots()
        let firstHash = childForestHash(first)
        let secondHash = childForestHash(second)
        let expectedTip = preferredChildForestHash(firstHash, secondHash)
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
        XCTAssertEqual(firstTip, expectedTip)
        XCTAssertEqual(secondTip, expectedTip)
        XCTAssertTrue(firstContainsSecond)
        XCTAssertTrue(secondContainsFirst)
    }

    func testEqualWorkIgnoresNextTargetAndChoosesSegmentBaseCID() async throws {
        let (fetcher, genesis, _) = try await makeChildForestRoots()
        let harder = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max / UInt256(2),
            nonce: 10,
            fetcher: fetcher
        )
        let easier = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 2_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 11,
            fetcher: fetcher
        )
        let expectedTip = preferredChildForestHash(
            childForestHash(harder),
            childForestHash(easier)
        )
        let harderFirst = ChainState.fromGenesis(block: genesis)
        let easierFirst = ChainState.fromGenesis(block: genesis)

        _ = await submitChildForestBlock(harder, to: harderFirst)
        _ = await submitChildForestBlock(easier, to: harderFirst)
        _ = await submitChildForestBlock(easier, to: easierFirst)
        _ = await submitChildForestBlock(harder, to: easierFirst)

        let harderFirstTip = await harderFirst.getMainChainTip()
        let easierFirstTip = await easierFirst.getMainChainTip()
        let restoredHarderFirst = try ChainState.restore(from: await harderFirst.persist())
        let restoredEasierFirst = try ChainState.restore(from: await easierFirst.persist())
        let restoredHarderFirstTip = await restoredHarderFirst.getMainChainTip()
        let restoredEasierFirstTip = await restoredEasierFirst.getMainChainTip()
        XCTAssertEqual(harderFirstTip, expectedTip)
        XCTAssertEqual(easierFirstTip, expectedTip)
        XCTAssertEqual(restoredHarderFirstTip, expectedTip)
        XCTAssertEqual(restoredEasierFirstTip, expectedTip)
    }

    func testEqualWorkChoosesTheSameSegmentBaseByCID() async throws {
        let (fetcher, genesis, _) = try await makeChildForestRoots()
        let first = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 12,
            fetcher: fetcher
        )
        let second = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 2_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 13,
            fetcher: fetcher
        )
        let expectedTip = preferredChildForestHash(
            childForestHash(first),
            childForestHash(second)
        )
        let firstOrder = ChainState.fromGenesis(block: genesis)
        let secondOrder = ChainState.fromGenesis(block: genesis)

        _ = await submitChildForestBlock(first, to: firstOrder)
        _ = await submitChildForestBlock(second, to: firstOrder)
        _ = await submitChildForestBlock(second, to: secondOrder)
        _ = await submitChildForestBlock(first, to: secondOrder)

        let firstTip = await firstOrder.getMainChainTip()
        let secondTip = await secondOrder.getMainChainTip()
        XCTAssertEqual(firstTip, expectedTip)
        XCTAssertEqual(secondTip, expectedTip)
    }

    func testTieBreakComparesSegmentBasesNotTips() async throws {
        let (fetcher, genesis, _) = try await makeChildForestRoots()
        let firstBase = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 14,
            fetcher: fetcher
        )
        let secondBase = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 2_000,
            target: UInt256.max,
            nextTarget: UInt256.max / UInt256(2),
            nonce: 15,
            fetcher: fetcher
        )
        let firstLeaf = try await buildAndStoreBlock(
            previous: firstBase,
            timestamp: genesis.timestamp + 3_000,
            target: UInt256.max,
            nextTarget: UInt256.max / UInt256(4),
            nonce: 16,
            fetcher: fetcher
        )
        let secondLeaf = try await buildAndStoreBlock(
            previous: secondBase,
            timestamp: genesis.timestamp + 4_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 17,
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        for block in [secondBase, secondLeaf, firstBase, firstLeaf] {
            _ = await submitChildForestBlock(block, to: chain)
        }

        let preferredBaseHash = preferredChildForestHash(
            childForestHash(firstBase),
            childForestHash(secondBase)
        )
        let expectedTip = preferredBaseHash == childForestHash(firstBase)
            ? childForestHash(firstLeaf)
            : childForestHash(secondLeaf)
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, expectedTip)
    }

    func testGreaterTrueCumWorkWinsBeforeEasierTarget() async throws {
        let (fetcher, genesis, _) = try await makeChildForestRoots()
        let greaterWork = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 1_000,
            target: UInt256.max / UInt256(2),
            nextTarget: UInt256(1),
            nonce: 18,
            fetcher: fetcher
        )
        let easierNext = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 2_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 19,
            fetcher: fetcher
        )
        let greaterFirst = ChainState.fromGenesis(block: genesis)
        let easierFirst = ChainState.fromGenesis(block: genesis)

        _ = await submitChildForestBlock(greaterWork, to: greaterFirst)
        _ = await submitChildForestBlock(easierNext, to: greaterFirst)
        _ = await submitChildForestBlock(easierNext, to: easierFirst)
        _ = await submitChildForestBlock(greaterWork, to: easierFirst)

        let expectedTip = childForestHash(greaterWork)
        let greaterFirstTip = await greaterFirst.getMainChainTip()
        let easierFirstTip = await easierFirst.getMainChainTip()
        XCTAssertEqual(greaterFirstTip, expectedTip)
        XCTAssertEqual(easierFirstTip, expectedTip)
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
        XCTAssertTrue(orphanResult.needsPredecessorBlock)
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

}
