import XCTest
@testable import Lattice
import UInt256
import cashew

// MARK: - Block Construction Helpers

func emptyTransactions() -> HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>> {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    try! HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>())
}

func emptyChildBlocks() -> HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>> {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    try! HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>>(node: MerkleDictionaryImpl<VolumeImpl<Block>>())
}

func emptyLatticeState() -> LatticeStateHeader {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    try! LatticeStateHeader(node: LatticeState.emptyState())
}

func testChainSpec() -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1024,
        halvingInterval: 10_000
    )
}

func makeGenesisBlock(
    spec: ChainSpec? = nil,
    timestamp: Int64 = 1_000_000,
    target: UInt256 = UInt256(1000),
    nonce: UInt64 = 0
) -> Block {
    let s = spec ?? testChainSpec()
    let emptyState = emptyLatticeState()
    return Block(
        parent: nil,
        transactions: emptyTransactions(),
        target: target,
        nextTarget: target,
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        spec: try! VolumeImpl<ChainSpec>(node: s),
        parentState: Reference(emptyState),
        prevState: Reference(emptyState),
        postState: emptyState,
        children: emptyChildBlocks(),
        height: 0,
        timestamp: timestamp,
        nonce: nonce
    )
}

func makeBlock(
    previous: Block,
    height: UInt64,
    timestamp: Int64,
    target: UInt256 = UInt256(1000),
    nonce: UInt64 = 0,
    children: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>>? = nil
) -> Block {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    let prevHeader = try! VolumeImpl<Block>(node: previous)
    let emptyState = emptyLatticeState()
    return Block(
        parent: Reference(prevHeader),
        transactions: emptyTransactions(),
        target: target,
        nextTarget: target,
        spec: previous.spec,
        parentState: Reference(emptyState),
        prevState: Reference(previous.postState),
        postState: emptyState,
        children: children ?? emptyChildBlocks(),
        height: height,
        timestamp: timestamp,
        nonce: nonce
    )
}

func blockHeader(_ block: Block) -> BlockHeader {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    try! VolumeImpl<Block>(node: block)
}

// MARK: - End-to-End: Block Construction and CID

@MainActor
final class BlockConstructionTests: XCTestCase {

    func testGenesisBlockHasDeterministicCID() {
        let g1 = makeGenesisBlock(timestamp: 1000, nonce: 42)
        let g2 = makeGenesisBlock(timestamp: 1000, nonce: 42)
        let h1 = blockHeader(g1)
        let h2 = blockHeader(g2)
        XCTAssertEqual(h1.rawCID, h2.rawCID, "Same genesis params should produce same CID")
    }

    func testDifferentNonceProducesDifferentCID() {
        let g1 = makeGenesisBlock(nonce: 1)
        let g2 = makeGenesisBlock(nonce: 2)
        let h1 = blockHeader(g1)
        let h2 = blockHeader(g2)
        XCTAssertNotEqual(h1.rawCID, h2.rawCID)
    }

    func testDifferentTimestampProducesDifferentCID() {
        let g1 = makeGenesisBlock(timestamp: 1000)
        let g2 = makeGenesisBlock(timestamp: 2000)
        XCTAssertNotEqual(blockHeader(g1).rawCID, blockHeader(g2).rawCID)
    }

    func testBlockReferencesParentCID() {
        let genesis = makeGenesisBlock()
        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        XCTAssertEqual(block1.parent?.rawCID, blockHeader(genesis).rawCID)
    }

    func testDifficultyHashCommitsToAllFields() {
        let genesis = makeGenesisBlock()
        let block1a = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 1)
        let block1b = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 2)
        XCTAssertNotEqual(block1a.proofOfWorkHash(), block1b.proofOfWorkHash())
    }

    func testDifficultyHashIncludesChildBlocks() {
        let genesis = makeGenesisBlock()
        let childGenesis = makeGenesisBlock(timestamp: 500, nonce: 99)
        let childBlockHeader = blockHeader(childGenesis)

        let emptyChildren = emptyChildBlocks()
        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, children: emptyChildren)

        let block1WithChild = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 0)

        let hash1 = block1.proofOfWorkHash()
        let hash2 = block1WithChild.proofOfWorkHash()
        XCTAssertEqual(hash1, hash2, "Same nonce and empty children should produce same hash")
    }
}

// MARK: - End-to-End: Real Block Submission through ChainState

@MainActor
final class BlockSubmissionE2ETests: XCTestCase {

    func testSubmitGenesisAndExtendChain() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let genesisHash = blockHeader(genesis).rawCID
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, genesisHash)

        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        let header1 = blockHeader(block1)
        let result1 = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: header1,
            block: block1
        )
        XCTAssertTrue(result1.addedBlock)
        XCTAssertTrue(result1.extendsMainChain)
        XCTAssertNil(result1.reorganization)

        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, header1.rawCID)
        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 1)
    }

    func testSubmitLinearChainOfFiveBlocks() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        var prev = genesis
        for i in 1...5 {
            let block = makeBlock(previous: prev, height: UInt64(i), timestamp: Int64(1000 + i * 1000))
            let header = blockHeader(block)
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: header,
                block: block
            )
            XCTAssertTrue(result.addedBlock, "Block \(i) should be added")
            XCTAssertTrue(result.extendsMainChain, "Block \(i) should extend main chain")
            prev = block
        }

        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 5)

        let tipHash = await chain.getMainChainTip()
        XCTAssertEqual(tipHash, blockHeader(prev).rawCID)
    }

    func testSubmitDuplicateBlockIsDiscarded() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        let header1 = blockHeader(block1)

        let result1 = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: header1,
            block: block1
        )
        XCTAssertTrue(result1.addedBlock)

        let result2 = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: header1,
            block: block1
        )
        XCTAssertFalse(result2.addedBlock, "Duplicate block should be discarded")
    }

    func testBlockWithoutParentOrParentChainInfoIsDiscarded() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let orphan = makeGenesisBlock(timestamp: 9999, nonce: 77)
        let header = blockHeader(orphan)

        let result = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: header,
            block: orphan
        )
        XCTAssertFalse(result.addedBlock, "Genesis-like block without parent chain info should be discarded")
    }
}

// MARK: - End-to-End: Fork and Reorg with Real Blocks

@MainActor
final class ForkReorgE2ETests: XCTestCase {

    func testLongerForkReorgsWithRealBlocks() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let a1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 1)
        let a2 = makeBlock(previous: a1, height: 2, timestamp: 3000, nonce: 1)

        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(a1), block: a1)
        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(a2), block: a2)

        let tipAfterA = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterA, blockHeader(a2).rawCID)

        let b1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 2)
        let b2 = makeBlock(previous: b1, height: 2, timestamp: 3000, nonce: 2)
        let b3 = makeBlock(previous: b2, height: 3, timestamp: 4000, nonce: 2)

        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b1), block: b1)
        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b2), block: b2)
        let resultB3 = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b3), block: b3)

        XCTAssertNotNil(resultB3.reorganization, "Longer B fork should trigger reorg")

        let tipAfterB = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterB, blockHeader(b3).rawCID)

        let a2OnMain = await chain.isOnMainChain(hash: blockHeader(a2).rawCID)
        XCTAssertFalse(a2OnMain, "A2 should be off main chain after reorg")

        let b3OnMain = await chain.isOnMainChain(hash: blockHeader(b3).rawCID)
        XCTAssertTrue(b3OnMain, "B3 should be on main chain after reorg")

        let genesisOnMain = await chain.isOnMainChain(hash: blockHeader(genesis).rawCID)
        XCTAssertTrue(genesisOnMain, "Genesis should survive reorg")
    }

    func testEqualLengthForkDoesNotReorgWithRealBlocks() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let a1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 1)
        let a2 = makeBlock(previous: a1, height: 2, timestamp: 3000, nonce: 1)

        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(a1), block: a1)
        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(a2), block: a2)

        let b1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 2)
        let b2 = makeBlock(previous: b1, height: 2, timestamp: 3000, nonce: 2)

        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b1), block: b1)
        let resultB2 = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b2), block: b2)

        XCTAssertNil(resultB2.reorganization, "Equal length fork should not reorg")

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, blockHeader(a2).rawCID, "Incumbent chain should hold")
    }
}

// MARK: - End-to-End: Parent Chain Anchoring with Real Blocks

@MainActor
final class AnchoringE2ETests: XCTestCase {

    // F5-4 (Hierarchical GHOST): a short fork that inherits heavy parent work beats
    // a longer unanchored chain. The node installs a provider returning the securing
    // parent's trueCumWork (10w) for B1; fork choice reads it live. 10w ≫ A's subtree.
    func testInheritedHeavyForkReorgsLongerChain() async {
        let w = workForTarget(UInt256(1000))
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let a1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 1)
        let a2 = makeBlock(previous: a1, height: 2, timestamp: 3000, nonce: 1)
        let a3 = makeBlock(previous: a2, height: 3, timestamp: 4000, nonce: 1)

        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(a1), block: a1)
        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(a2), block: a2)
        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(a3), block: a3)

        let tipBeforeB = await chain.getMainChainTip()
        XCTAssertEqual(tipBeforeB, blockHeader(a3).rawCID)

        let b1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 2)
        let b1hash = blockHeader(b1).rawCID
        let heavy = w &* UInt256(10)
        await chain.setInheritedWeightProvider { $0 == b1hash ? heavy : .zero }
        let resultB1 = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: blockHeader(b1),
            block: b1
        )

        XCTAssertTrue(resultB1.addedBlock)
        XCTAssertNotNil(resultB1.reorganization, "heavy-inherited B1 should beat the unanchored A chain")

        let tipAfterB = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterB, blockHeader(b1).rawCID)
    }

    // F5-4: when the parent chain extends a fork B1 rides, B1's inherited weight rises
    // live (the provider returns the larger value) and re-evaluation triggers a reorg
    // — replaces the old "duplicate-block anchoring triggers reorg" path.
    func testInheritedWeightRefreshTriggersReorg() async {
        let w = workForTarget(UInt256(1000))
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let a1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 1)
        let b1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 2)
        let b1hash = blockHeader(b1).rawCID

        let box = E2EWeightBox()
        await chain.setInheritedWeightProvider { $0 == b1hash ? box.value : .zero }

        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(a1), block: a1)
        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: blockHeader(b1), block: b1)

        let tipBefore = await chain.getMainChainTip()
        XCTAssertEqual(tipBefore, blockHeader(a1).rawCID, "A1 is incumbent (equal weight, holds)")

        box.value = w &* UInt256(10)   // parent chain extended B1's fork
        let reorg = await chain.reevaluateForkChoice(blockHash: b1hash)
        XCTAssertNotNil(reorg, "B1's risen inherited weight should trigger reorg")
        let tipAfter = await chain.getMainChainTip()
        XCTAssertEqual(tipAfter, blockHeader(b1).rawCID)
    }
}

final class E2EWeightBox: @unchecked Sendable {
    var value: UInt256 = .zero
}

// MARK: - End-to-End: ChainState.fromGenesis Validation

@MainActor
final class FromGenesisE2ETests: XCTestCase {

    func testFromGenesisInitializesCorrectly() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)
        let genesisHash = blockHeader(genesis).rawCID

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, genesisHash)

        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 0)

        let contains = await chain.contains(blockHash: genesisHash)
        XCTAssertTrue(contains)

        let onMain = await chain.isOnMainChain(hash: genesisHash)
        XCTAssertTrue(onMain)

        let block = await chain.getConsensusBlock(hash: genesisHash)
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.blockHeight, 0)
        XCTAssertNil(block?.parentBlockHash)
    }

    func testFromGenesisProducesDeterministicChain() async {
        let genesis = makeGenesisBlock(timestamp: 42, nonce: 7)
        let chain1 = ChainState.fromGenesis(block: genesis)
        let chain2 = ChainState.fromGenesis(block: genesis)

        let tip1 = await chain1.getMainChainTip()
        let tip2 = await chain2.getMainChainTip()
        XCTAssertEqual(tip1, tip2, "Same genesis should produce same chain tip")
    }
}

// MARK: - End-to-End: Merged Mining Simulation

@MainActor
final class MergedMiningE2ETests: XCTestCase {

    func testChildBlockEmbeddedInParentSharesCID() {
        let childGenesis = makeGenesisBlock(timestamp: 100, nonce: 1)
        let parentGenesis = makeGenesisBlock(timestamp: 200, nonce: 2)

        let parentBlock1 = makeBlock(previous: parentGenesis, height: 1, timestamp: 1000)

        XCTAssertEqual(parentBlock1.children.rawCID, emptyChildBlocks().rawCID,
            "Block with no child blocks should have empty children CID")

        let parentBlock1DiffHash = parentBlock1.proofOfWorkHash()
        let parentBlock1Alt = makeBlock(previous: parentGenesis, height: 1, timestamp: 1000, nonce: 1)
        let parentBlock1AltDiffHash = parentBlock1Alt.proofOfWorkHash()
        XCTAssertNotEqual(parentBlock1DiffHash, parentBlock1AltDiffHash,
            "Different nonces should produce different target hashes")
    }

    func testParentAndChildChainsBothAcceptSameBlock() async {
        let parentGenesis = makeGenesisBlock(timestamp: 100, nonce: 1)
        let childGenesis = makeGenesisBlock(timestamp: 200, nonce: 2)

        let parentChain = ChainState.fromGenesis(block: parentGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)

        let parentBlock1 = makeBlock(previous: parentGenesis, height: 1, timestamp: 1000)

        let parentResult = await parentChain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: blockHeader(parentBlock1),
            block: parentBlock1
        )
        XCTAssertTrue(parentResult.extendsMainChain)

        let childBlock1 = makeBlock(previous: childGenesis, height: 1, timestamp: 1000)
        let childResult = await childChain.submitBlock(
            parentBlockHeaderAndIndex: (blockHeader(parentBlock1).rawCID, 1),
            blockHeader: blockHeader(childBlock1),
            block: childBlock1
        )
        XCTAssertTrue(childResult.addedBlock, "Child chain should accept block anchored to parent")
        XCTAssertTrue(childResult.extendsMainChain)

        let parentTip = await parentChain.getHighestBlockHeight()
        let childTip = await childChain.getHighestBlockHeight()
        XCTAssertEqual(parentTip, 1)
        XCTAssertEqual(childTip, 1)
    }
}

// MARK: - End-to-End: ChainLevel Hierarchy

@MainActor
final class ChainLevelE2ETests: XCTestCase {

    func testChainLevelCreation() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)
        let level = ChainLevel(chain: chain, children: [:])

        let tip = await level.chain.getMainChainTip()
        XCTAssertEqual(tip, blockHeader(genesis).rawCID)
    }

    func testNestedChainLevelHierarchy() async {
        let nexusGenesis = makeGenesisBlock(timestamp: 100, nonce: 1)
        let childGenesis = makeGenesisBlock(timestamp: 200, nonce: 2)

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)

        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["child1": childLevel])

        let nexusTip = await nexusLevel.chain.getMainChainTip()
        XCTAssertEqual(nexusTip, blockHeader(nexusGenesis).rawCID)

        let childTip = await childLevel.chain.getMainChainTip()
        XCTAssertEqual(childTip, blockHeader(childGenesis).rawCID)
    }
}

// MARK: - End-to-End: State Continuity

@MainActor
final class StateContinuityE2ETests: XCTestCase {

    func testBlockStateChaining() {
        let genesis = makeGenesisBlock()
        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        XCTAssertEqual(block1.prevState.rawCID, genesis.postState.rawCID,
            "Block 1's homestead should equal genesis frontier")

        let block2 = makeBlock(previous: block1, height: 2, timestamp: 3000)
        XCTAssertEqual(block2.prevState.rawCID, block1.postState.rawCID,
            "Block 2's homestead should equal block 1's frontier")
    }

    func testGenesisHasEmptyHomestead() {
        let genesis = makeGenesisBlock()
        let emptyState = emptyLatticeState()
        XCTAssertEqual(genesis.prevState.rawCID, emptyState.rawCID,
            "Genesis homestead should be empty state")
    }

    func testChainSpecPersistsAcrossBlocks() {
        let genesis = makeGenesisBlock()
        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        let block2 = makeBlock(previous: block1, height: 2, timestamp: 3000)
        XCTAssertEqual(genesis.spec.rawCID, block1.spec.rawCID)
        XCTAssertEqual(block1.spec.rawCID, block2.spec.rawCID)
    }

    func testBlockIndexIncrements() {
        let genesis = makeGenesisBlock()
        XCTAssertEqual(genesis.height, 0)
        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        XCTAssertEqual(block1.height, 1)
        let block2 = makeBlock(previous: block1, height: 2, timestamp: 3000)
        XCTAssertEqual(block2.height, 2)
    }

    func testTimestampsIncrease() {
        let genesis = makeGenesisBlock(timestamp: 1000)
        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        let block2 = makeBlock(previous: block1, height: 2, timestamp: 3000)
        XCTAssertTrue(genesis.timestamp < block1.timestamp)
        XCTAssertTrue(block1.timestamp < block2.timestamp)
    }
}

// MARK: - End-to-End: Full Pipeline Smoke Test

@MainActor
final class FullPipelineSmokeTests: XCTestCase {

    func testBuildAndReorgTenBlockChain() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        var mainChainBlocks: [Block] = [genesis]
        for i in 1...10 {
            let block = makeBlock(
                previous: mainChainBlocks.last!,
                height: UInt64(i),
                timestamp: Int64(1000 + i * 1000),
                nonce: 1
            )
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: blockHeader(block),
                block: block
            )
            XCTAssertTrue(result.extendsMainChain, "Block \(i) should extend")
            mainChainBlocks.append(block)
        }

        let tipAt10 = await chain.getHighestBlockHeight()
        XCTAssertEqual(tipAt10, 10)

        var forkBlocks: [Block] = [mainChainBlocks[5]]
        for i in 6...15 {
            let block = makeBlock(
                previous: forkBlocks.last!,
                height: UInt64(i),
                timestamp: Int64(1000 + i * 1000),
                nonce: 2
            )
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: blockHeader(block),
                block: block
            )
            if i <= 10 {
                XCTAssertNil(result.reorganization, "Fork block \(i) should not reorg yet (equal or shorter)")
            }
            forkBlocks.append(block)
        }

        let tipAfterFork = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterFork, blockHeader(forkBlocks.last!).rawCID, "Fork should be new tip")
        let highestAfterFork = await chain.getHighestBlockHeight()
        XCTAssertEqual(highestAfterFork, 15)

        for i in 6...10 {
            let oldHash = blockHeader(mainChainBlocks[i]).rawCID
            let onMain = await chain.isOnMainChain(hash: oldHash)
            XCTAssertFalse(onMain, "Old main chain block \(i) should be off main chain")
        }

        for i in 0...5 {
            let commonHash = blockHeader(mainChainBlocks[i]).rawCID
            let onMain = await chain.isOnMainChain(hash: commonHash)
            XCTAssertTrue(onMain, "Common ancestor block \(i) should remain on main chain")
        }
    }

    func testCIDConsistencyAcrossOperations() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)
        let genesisHash = blockHeader(genesis).rawCID

        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        let block1Hash = blockHeader(block1).rawCID
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: blockHeader(block1),
            block: block1
        )

        let storedGenesis = await chain.getConsensusBlock(hash: genesisHash)
        XCTAssertNotNil(storedGenesis)
        XCTAssertEqual(storedGenesis?.blockHash, genesisHash)

        let storedBlock1 = await chain.getConsensusBlock(hash: block1Hash)
        XCTAssertNotNil(storedBlock1)
        XCTAssertEqual(storedBlock1?.parentBlockHash, genesisHash,
            "Stored block's previous hash should match genesis CID")
    }
}
