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
    await chain.submitBlock(
        parentBlockHeaderAndIndex: nil,
        blockHeader: try! BlockHeader(node: block),
        block: block
    )
}

private func makeChildForestRoots() async throws -> (fetcher: StorableFetcher, first: Block, second: Block) {
    let fetcher = StorableFetcher()
    let spec = childForestSpec()
    let first = try await buildAndStoreGenesis(
        spec: spec,
        timestamp: 1_000_000,
        target: UInt256.max,
        nonce: 1,
        fetcher: fetcher
    )
    let second = try await buildAndStoreGenesis(
        spec: spec,
        timestamp: 1_001_000,
        target: UInt256.max,
        nonce: 2,
        fetcher: fetcher
    )
    return (fetcher, first, second)
}

private func withoutRootPolicy(_ persisted: PersistedChainState) -> PersistedChainState {
    PersistedChainState(
        chainTip: persisted.chainTip,
        tipPostStateCID: persisted.tipPostStateCID,
        tipPrevStateCID: persisted.tipPrevStateCID,
        tipSpecCID: persisted.tipSpecCID,
        tipTarget: persisted.tipTarget,
        tipNextTarget: persisted.tipNextTarget,
        tipHeight: persisted.tipHeight,
        tipTimestamp: persisted.tipTimestamp,
        mainChainHashes: persisted.mainChainHashes,
        blocks: persisted.blocks,
        prunedWeightIndex: persisted.prunedWeightIndex,
        parentChainMap: persisted.parentChainMap,
        missingBlockHashes: persisted.missingBlockHashes
    )
}

@MainActor
final class ChildRootForestTests: XCTestCase {

    func testSingleGenesisModeRejectsASecondParentlessRoot() async throws {
        let roots = try await makeChildForestRoots()
        let chain = ChainState.fromGenesis(block: roots.first)

        let result = await submitChildForestBlock(roots.second, to: chain)
        let containsSecond = await chain.contains(blockHash: childForestHash(roots.second))
        let tip = await chain.getMainChainTip()

        XCTAssertFalse(result.addedBlock)
        XCTAssertFalse(containsSecond)
        XCTAssertEqual(tip, childForestHash(roots.first))
    }

    func testChildForestSelectsEqualWeightRootsIndependentlyOfArrivalOrder() async throws {
        let roots = try await makeChildForestRoots()
        let firstHash = childForestHash(roots.first)
        let secondHash = childForestHash(roots.second)
        let expectedRoot = min(firstHash, secondHash)

        let firstArrival = ChainState.fromGenesis(
            block: roots.first,
            rootPolicy: .childRootForest
        )
        let firstResult = await submitChildForestBlock(roots.second, to: firstArrival)

        let secondArrival = ChainState.fromGenesis(
            block: roots.second,
            rootPolicy: .childRootForest
        )
        let secondResult = await submitChildForestBlock(roots.first, to: secondArrival)
        let firstTip = await firstArrival.getMainChainTip()
        let secondTip = await secondArrival.getMainChainTip()
        let firstContainsFirst = await firstArrival.contains(blockHash: firstHash)
        let firstContainsSecond = await firstArrival.contains(blockHash: secondHash)

        XCTAssertTrue(firstResult.addedBlock)
        XCTAssertTrue(secondResult.addedBlock)
        XCTAssertEqual(firstTip, expectedRoot)
        XCTAssertEqual(secondTip, expectedRoot)
        XCTAssertTrue(firstContainsFirst)
        XCTAssertTrue(firstContainsSecond)
    }

    func testHeavierCompetingRootReorganizesWithoutCommonAncestor() async throws {
        let roots = try await makeChildForestRoots()
        let firstHash = childForestHash(roots.first)
        let chain = ChainState.fromGenesis(
            block: roots.first,
            rootPolicy: .childRootForest
        )
        _ = await submitChildForestBlock(roots.second, to: chain)

        let oldRoot = await chain.getMainChainTip()
        let sideRoot = oldRoot == firstHash ? roots.second : roots.first
        let sideRootHash = childForestHash(sideRoot)
        let sideChild = try await buildAndStoreBlock(
            previous: sideRoot,
            timestamp: sideRoot.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 3,
            fetcher: roots.fetcher
        )
        let sideChildHash = childForestHash(sideChild)

        let result = await submitChildForestBlock(sideChild, to: chain)
        let tip = await chain.getMainChainTip()
        let oldRootIsCanonical = await chain.isOnMainChain(hash: oldRoot)
        let sideRootIsCanonical = await chain.isOnMainChain(hash: sideRootHash)
        let sideChildIsCanonical = await chain.isOnMainChain(hash: sideChildHash)

        XCTAssertTrue(result.addedBlock)
        XCTAssertNotNil(result.reorganization)
        XCTAssertEqual(tip, sideChildHash)
        XCTAssertTrue(result.reorganization?.mainChainBlocksRemoved.contains(oldRoot) ?? false)
        XCTAssertEqual(result.reorganization?.mainChainBlocksAdded[sideRootHash], 0)
        XCTAssertEqual(result.reorganization?.mainChainBlocksAdded[sideChildHash], 1)
        XCTAssertFalse(oldRootIsCanonical)
        XCTAssertTrue(sideRootIsCanonical)
        XCTAssertTrue(sideChildIsCanonical)
    }

    func testRootArrivalKeepsTheSelectedDescendantSnapshot() async throws {
        let roots = try await makeChildForestRoots()
        let chain = ChainState.fromGenesis(
            block: roots.first,
            rootPolicy: .childRootForest
        )
        let child = try await buildAndStoreBlock(
            previous: roots.second,
            timestamp: roots.second.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 5,
            fetcher: roots.fetcher
        )
        let childHash = childForestHash(child)

        let childResult = await submitChildForestBlock(child, to: chain)
        let rootResult = await submitChildForestBlock(roots.second, to: chain)
        let tip = await chain.getMainChainTip()
        let snapshot = await chain.tipSnapshot

        XCTAssertTrue(childResult.addedBlock)
        XCTAssertTrue(childResult.needsChildBlock)
        XCTAssertNotNil(rootResult.reorganization)
        XCTAssertEqual(tip, childHash)
        XCTAssertEqual(snapshot?.tipHeight, child.height)
        XCTAssertEqual(snapshot?.postStateCID, child.postState.rawCID)
        XCTAssertEqual(snapshot?.prevStateCID, child.prevState.rawCID)

        let restored = try ChainState.restore(from: await chain.persist())
        let restoredTip = await restored.getMainChainTip()
        let restoredSnapshot = await restored.tipSnapshot
        XCTAssertEqual(restoredTip, childHash)
        XCTAssertEqual(restoredSnapshot?.tipHeight, child.height)
        XCTAssertEqual(restoredSnapshot?.postStateCID, child.postState.rawCID)
    }

    func testForestPersistenceRestoresEveryRootAndCanonicalTip() async throws {
        let roots = try await makeChildForestRoots()
        let firstHash = childForestHash(roots.first)
        let secondHash = childForestHash(roots.second)
        let chain = ChainState.fromGenesis(
            block: roots.first,
            rootPolicy: .childRootForest
        )
        _ = await submitChildForestBlock(roots.second, to: chain)

        let currentRoot = await chain.getMainChainTip()
        let sideRoot = currentRoot == firstHash ? roots.second : roots.first
        let sideChild = try await buildAndStoreBlock(
            previous: sideRoot,
            timestamp: sideRoot.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 4,
            fetcher: roots.fetcher
        )
        _ = await submitChildForestBlock(sideChild, to: chain)
        let canonicalTip = await chain.getMainChainTip()

        let persisted = await chain.persist()
        let restored = try ChainState.restore(from: persisted)
        let restoredTip = await restored.getMainChainTip()
        let restoredContainsFirst = await restored.contains(blockHash: firstHash)
        let restoredContainsSecond = await restored.contains(blockHash: secondHash)
        let restoredContainsChild = await restored.contains(blockHash: childForestHash(sideChild))
        let restoredTipIsCanonical = await restored.isOnMainChain(hash: canonicalTip)
        let restoredRootPolicy = await restored.getRootPolicy()

        XCTAssertEqual(persisted.rootPolicy, ChainRootPolicy.childRootForest)
        XCTAssertEqual(restoredRootPolicy, ChainRootPolicy.childRootForest)
        XCTAssertEqual(restoredTip, canonicalTip)
        XCTAssertTrue(restoredContainsFirst)
        XCTAssertTrue(restoredContainsSecond)
        XCTAssertTrue(restoredContainsChild)
        XCTAssertTrue(restoredTipIsCanonical)
    }

    func testRestoredForestReorganizesToKnownSideDescendantWithItsSnapshot() async throws {
        let roots = try await makeChildForestRoots()
        let firstHash = childForestHash(roots.first)
        let secondHash = childForestHash(roots.second)
        let canonicalRoot = firstHash < secondHash ? roots.first : roots.second
        let sideRoot = firstHash < secondHash ? roots.second : roots.first
        let childTarget = UInt256.max &- UInt256(1)
        let canonicalChild = try await buildAndStoreBlock(
            previous: canonicalRoot,
            timestamp: canonicalRoot.timestamp + 1_000,
            target: childTarget,
            nextTarget: childTarget,
            nonce: 6,
            fetcher: roots.fetcher
        )
        let sideChild = try await buildAndStoreBlock(
            previous: sideRoot,
            timestamp: sideRoot.timestamp + 1_000,
            target: childTarget,
            nextTarget: childTarget,
            nonce: 7,
            fetcher: roots.fetcher
        )
        let canonicalChildHash = childForestHash(canonicalChild)
        let sideRootHash = childForestHash(sideRoot)
        let sideChildHash = childForestHash(sideChild)

        let chain = ChainState.fromGenesis(
            block: canonicalRoot,
            rootPolicy: .childRootForest
        )
        _ = await submitChildForestBlock(canonicalChild, to: chain)
        _ = await submitChildForestBlock(sideRoot, to: chain)
        _ = await submitChildForestBlock(sideChild, to: chain)

        let tipBeforeRestart = await chain.getMainChainTip()
        XCTAssertEqual(tipBeforeRestart, canonicalChildHash)

        let persisted = await chain.persist()
        let persistedSideChild = try XCTUnwrap(
            persisted.blocks.first { $0.blockHash == sideChildHash }
        )
        XCTAssertEqual(persistedSideChild.target, childTarget.toHexString())

        let restored = try ChainState.restore(from: persisted)
        let restoredTip = await restored.getMainChainTip()
        XCTAssertEqual(restoredTip, canonicalChildHash)

        await restored.setInheritedWeightProvider { hash in
            hash == sideRootHash ? UInt256(10) : .zero
        }
        let reorganization = await restored.reevaluateForkChoice(blockHash: sideRootHash)
        let tipAfterReorg = await restored.getMainChainTip()
        let snapshotAfterReorg = await restored.tipSnapshot

        XCTAssertNotNil(reorganization)
        XCTAssertEqual(tipAfterReorg, sideChildHash)
        XCTAssertEqual(snapshotAfterReorg?.tipHeight, sideChild.height)
        XCTAssertEqual(snapshotAfterReorg?.timestamp, sideChild.timestamp)
        XCTAssertEqual(snapshotAfterReorg?.postStateCID, sideChild.postState.rawCID)
        XCTAssertEqual(snapshotAfterReorg?.prevStateCID, sideChild.prevState.rawCID)
        XCTAssertEqual(snapshotAfterReorg?.target, sideChild.target)
        XCTAssertEqual(snapshotAfterReorg?.nextTarget, sideChild.nextTarget)
    }

    func testForestReportsHeldHeavierMissingSideRoot() async throws {
        let one = UInt256(1)
        let two = UInt256(2)
        let mainRoot = PersistedBlockMeta(
            blockHash: "main-root",
            parentBlockHash: nil,
            blockHeight: 0,
            parentChainBlocks: [:],
            childHashes: [],
            target: UInt256.max.toHexString(),
            cumulativeWork: one.toHexString(),
            workHex: one.toHexString()
        )
        let sideRoot = PersistedBlockMeta(
            blockHash: "side-root",
            parentBlockHash: nil,
            blockHeight: 0,
            parentChainBlocks: [:],
            childHashes: [],
            target: (UInt256.max / two).toHexString(),
            cumulativeWork: two.toHexString(),
            subtreeWeight: two.toHexString(),
            workHex: two.toHexString()
        )
        let persisted = PersistedChainState(
            chainTip: mainRoot.blockHash,
            tipPostStateCID: nil,
            tipPrevStateCID: nil,
            tipSpecCID: nil,
            tipTarget: nil,
            tipNextTarget: nil,
            tipHeight: nil,
            tipTimestamp: nil,
            mainChainHashes: [mainRoot.blockHash],
            blocks: [mainRoot],
            prunedWeightIndex: [sideRoot],
            parentChainMap: [:],
            missingBlockHashes: [],
            rootPolicy: .childRootForest
        )
        let chain = try ChainState.restore(from: persisted)

        let target = await chain.heldHeavierBackfillTarget()

        XCTAssertEqual(target?.tipHash, sideRoot.blockHash)
        XCTAssertEqual(target?.missingBodies, [sideRoot.blockHash])
    }

    func testRestoreRequiresMatchingRootPolicy() async throws {
        let roots = try await makeChildForestRoots()
        let forest = ChainState.fromGenesis(
            block: roots.first,
            rootPolicy: .childRootForest
        )
        let forestPersisted = await forest.persist()

        XCTAssertThrowsError(
            try ChainState.restore(from: forestPersisted, rootPolicy: .singleGenesis)
        ) { error in
            XCTAssertEqual(
                error as? ChainStateRestoreError,
                .rootPolicyMismatch(expected: .singleGenesis, actual: .childRootForest)
            )
        }

        let single = ChainState.fromGenesis(block: roots.second)
        let singlePersisted = await single.persist()
        XCTAssertThrowsError(
            try ChainState.restore(from: singlePersisted, rootPolicy: .childRootForest)
        ) { error in
            XCTAssertEqual(
                error as? ChainStateRestoreError,
                .rootPolicyMismatch(expected: .childRootForest, actual: .singleGenesis)
            )
        }
    }

    func testLegacySnapshotDefaultsToSingleGenesisAndCannotChangeRuntimePolicy() async throws {
        let roots = try await makeChildForestRoots()
        let single = ChainState.fromGenesis(block: roots.first)
        let legacy = withoutRootPolicy(await single.persist())

        let restored = try ChainState.restore(from: legacy, rootPolicy: .singleGenesis)
        XCTAssertEqual(restored.rootPolicy, .singleGenesis)
        XCTAssertThrowsError(
            try ChainState.restore(from: legacy, rootPolicy: .childRootForest)
        ) { error in
            XCTAssertEqual(
                error as? ChainStateRestoreError,
                .rootPolicyMismatch(expected: .childRootForest, actual: .singleGenesis)
            )
        }

        let forest = ChainState.fromGenesis(
            block: roots.second,
            rootPolicy: .childRootForest
        )
        let forestTip = await forest.getMainChainTip()
        do {
            try await forest.resetFrom(legacy)
            XCTFail("a reset must not replace a forest runtime with a single-root snapshot")
        } catch let error as ChainStateRestoreError {
            XCTAssertEqual(
                error,
                .rootPolicyMismatch(expected: .childRootForest, actual: .singleGenesis)
            )
        }
        XCTAssertEqual(forest.rootPolicy, ChainRootPolicy.childRootForest)
        let tipAfterReset = await forest.getMainChainTip()
        XCTAssertEqual(tipAfterReset, forestTip)
    }
}
