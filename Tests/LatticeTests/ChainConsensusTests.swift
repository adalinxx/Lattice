import XCTest
@testable import Lattice
import UInt256

// MARK: - Test Helpers

/// A mutable, Sendable box so a test can simulate the node "refreshing" a block's
/// inherited weight (the parent chain extending) without re-storing on the block.
final class MutableWeight: @unchecked Sendable {
    var value: UInt256 = .zero
}

func makeBlockMeta(
    hash: String,
    previousHash: String? = nil,
    height: UInt64,
    parentChainBlocks: [String: UInt64?] = [:],
    childHashes: [String] = [],
    work: UInt256 = UInt256(1),
    cumulativeWork: UInt256 = .zero
) -> BlockMeta {
    BlockMeta(
        blockInfo: BlockInfoImpl(
            blockHash: hash,
            parentBlockHash: previousHash,
            blockHeight: height,
            work: work
        ),
        parentChainBlocks: parentChainBlocks,
        childHashes: childHashes,
        cumulativeWork: cumulativeWork
    )
}

// `inheritedWeights` installs a fork-choice provider mapping block hash → its
// inherited cross-chain weight (the securing parent's trueCumWork), as the node
// would supply it. Blocks absent from the map inherit 0 (root-chain default).
func makeChain(
    blocks: [BlockMeta],
    mainChainHashes: Set<String>? = nil,
    parentChainMap: [String: String] = [:],
    inheritedWeights: [String: UInt256] = [:]
) -> ChainState {
    let tip = blocks.max(by: { a, b in
        if mainChainHashes != nil {
            let aOnMain = mainChainHashes!.contains(a.blockHash)
            let bOnMain = mainChainHashes!.contains(b.blockHash)
            if aOnMain != bOnMain { return !aOnMain }
        }
        return a.blockHeight < b.blockHeight
    })!
    let mainHashes = mainChainHashes ?? Set(blocks.map { $0.blockHash })
    var indexMap: [UInt64: Set<String>] = [:]
    var hashMap: [String: BlockMeta] = [:]
    for block in blocks {
        indexMap[block.blockHeight, default: Set()].insert(block.blockHash)
        hashMap[block.blockHash] = block
    }
    // No pruned weight index here, so the throwing init cannot fail.
    return try! ChainState(
        chainTip: tip.blockHash,
        mainChainHashes: mainHashes,
        indexToBlockHash: indexMap,
        hashToBlock: hashMap,
        parentChainBlockHashToBlockHash: parentChainMap,
        inheritedWeightProvider: inheritedWeightProvider(from: inheritedWeights)
    )
}

/// Build a fork-choice inherited-weight provider from a static map (nil if empty).
func inheritedWeightProvider(from weights: [String: UInt256]) -> (@Sendable (String) -> UInt256)? {
    guard !weights.isEmpty else { return nil }
    return { hash in weights[hash] ?? .zero }
}

func makeLinearChain(length: Int, prefix: String = "block") -> (ChainState, [BlockMeta]) {
    var blocks: [BlockMeta] = []
    for i in 0..<length {
        let hash = "\(prefix)_\(i)"
        let prevHash: String? = i == 0 ? nil : "\(prefix)_\(i - 1)"
        let meta = makeBlockMeta(hash: hash, previousHash: prevHash, height: UInt64(i))
        blocks.append(meta)
    }
    for i in 0..<(blocks.count - 1) {
        blocks[i].childHashes = [blocks[i + 1].blockHash]
    }
    let chain = makeChain(blocks: blocks)
    return (chain, blocks)
}

// MARK: - ChainState Tests (async, run via @MainActor)

@MainActor
final class ChainStateGenesisTests: XCTestCase {

    func testFromGenesisCreatesValidState() async {
        let (chain, _) = makeLinearChain(length: 1)
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "block_0")
        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 0)
        let contains = await chain.contains(blockHash: "block_0")
        XCTAssertTrue(contains)
        let onMain = await chain.isOnMainChain(hash: "block_0")
        XCTAssertTrue(onMain)
    }

    func testFromGenesisDoesNotContainOtherBlocks() async {
        let (chain, _) = makeLinearChain(length: 1)
        let contains = await chain.contains(blockHash: "nonexistent")
        XCTAssertFalse(contains)
    }
}

@MainActor
final class LinearChainTests: XCTestCase {

    func testLinearChainTipIsHighest() async {
        let (chain, _) = makeLinearChain(length: 5)
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "block_4")
        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 4)
    }

    func testAllBlocksOnMainChain() async {
        let (chain, blocks) = makeLinearChain(length: 5)
        for block in blocks {
            let onMain = await chain.isOnMainChain(hash: block.blockHash)
            XCTAssertTrue(onMain, "\(block.blockHash) should be on main chain")
        }
    }

    func testGetConsensusBlock() async {
        let (chain, _) = makeLinearChain(length: 3)
        let block = await chain.getConsensusBlock(hash: "block_1")
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.blockHeight, 1)
        XCTAssertEqual(block?.parentBlockHash, "block_0")
    }

    func testGetConsensusBlockNotFound() async {
        let (chain, _) = makeLinearChain(length: 3)
        let block = await chain.getConsensusBlock(hash: "nonexistent")
        XCTAssertNil(block)
    }
}

@MainActor
final class ForkChoiceTests: XCTestCase {

    func testLongerForkTriggersReorg() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2, childHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", height: 3)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3, childHashes: ["B4"])
        let b4 = makeBlockMeta(hash: "B4", previousHash: "B3", height: 4)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, b1, b2, b3, b4],
            mainChainHashes: Set(["G", "A1", "A2", "A3"])
        )

        let block = await chain.getConsensusBlock(hash: "B4")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        XCTAssertTrue(reorg!.mainChainBlocksAdded.keys.contains("B4"))
        XCTAssertTrue(reorg!.mainChainBlocksRemoved.contains("A3"))

        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, "B4")
    }

    func testShorterForkDoesNotReorg() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2, childHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", height: 3)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, b1, b2],
            mainChainHashes: Set(["G", "A1", "A2", "A3"])
        )

        let block = await chain.getConsensusBlock(hash: "B2")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNil(reorg)
    }

    func testEqualLengthForkDoesNotReorg() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, b1, b2],
            mainChainHashes: Set(["G", "A1", "A2"])
        )

        let block = await chain.getConsensusBlock(hash: "B2")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNil(reorg)
    }

    // F5-4 (Hierarchical GHOST): a shorter fork that *inherits* heavier parent
    // work beats a longer self-mined fork. The own-chain subtree of B (2 blocks) is
    // lighter than A (4 blocks), but B1's inherited parent weight makes its
    // trueCumWork larger — the §4 rule that replaced the old positional parentIndex.
    func testInheritedHeavyForkBeatsLongerChain() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2, childHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", height: 3, childHashes: ["A4"])
        let a4 = makeBlockMeta(hash: "A4", previousHash: "A3", height: 4)
        // B1 inherits 10 from its securing parent — trueCumWork(B1)=subtree(2)+10=12 > A's 4.
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, a4, b1, b2],
            mainChainHashes: Set(["G", "A1", "A2", "A3", "A4"]),
            inheritedWeights: ["B1": UInt256(10)]
        )

        let block = await chain.getConsensusBlock(hash: "B2")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, "B2")
    }

    // F5-4: between two equal-length forks, the one with heavier inherited parent
    // weight wins (replaces "lower parentIndex wins").
    func testHeavierInheritedWinsForkChoice() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, b1, b2],
            mainChainHashes: Set(["G", "A1", "A2"]),
            inheritedWeights: ["A1": UInt256(3), "B1": UInt256(20)]
        )

        let block = await chain.getConsensusBlock(hash: "B2")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, "B2")
    }
}

@MainActor
final class OrphanDetectionTests: XCTestCase {

    func testOrphanConnectedToMainChain() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)

        let chain = makeChain(
            blocks: [g, a1, b1, b2, b3],
            mainChainHashes: Set(["G", "A1"])
        )

        let earliest = await chain.findEarliestOrphanConnectedToMainChain(blockHeader: "B3")
        XCTAssertEqual(earliest, "B1")
    }

    func testOrphanWithMissingAncestorReturnsNil() async {
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)

        let chain = makeChain(blocks: [b2, b3], mainChainHashes: Set())
        let earliest = await chain.findEarliestOrphanConnectedToMainChain(blockHeader: "B3")
        XCTAssertNil(earliest)
    }

    func testGenesisBlockIsValidOrphanRoot() async {
        let g = makeBlockMeta(hash: "alt_g", height: 0, childHashes: ["B1"])
        let b1 = makeBlockMeta(hash: "B1", previousHash: "alt_g", height: 1)

        let chain = makeChain(blocks: [g, b1], mainChainHashes: Set())
        let earliest = await chain.findEarliestOrphanConnectedToMainChain(blockHeader: "B1")
        XCTAssertEqual(earliest, "alt_g")
    }
}

@MainActor
final class ParentReorgPropagationTests: XCTestCase {

    func testPropagateParentReorgUpdatesReferences() async {
        let g = makeBlockMeta(hash: "CG", height: 0, childHashes: ["C1"])
        let c1 = makeBlockMeta(hash: "C1", previousHash: "CG", height: 1, parentChainBlocks: ["P_5": 5])

        let chain = makeChain(
            blocks: [g, c1],
            mainChainHashes: Set(["CG", "C1"]),
            parentChainMap: ["P_5": "C1"]
        )

        let reorg = Reorganization(mainChainBlocksAdded: ["P_new": 3], mainChainBlocksRemoved: Set(["P_5"]))
        let childReorg = await chain.propagateParentReorg(reorg: reorg)
        XCTAssertNil(childReorg)

        let c1Block = await chain.getConsensusBlock(hash: "C1")!
        XCTAssertNil(c1Block.parentChainBlocks["P_5"] as Any?)
    }

    // F5-4: a parent reorg that makes CB1's securing parent canonical raises CB1's
    // inherited weight (the provider returns the heavier value); propagating it
    // promotes CB1 emergently. (Here the heavier inherited weight is supplied
    // directly; the node would recompute it from the now-canonical parent fork.)
    func testPropagateParentReorgTriggersChildReorg() async {
        let g = makeBlockMeta(hash: "CG", height: 0, childHashes: ["CA1", "CB1"])
        let ca1 = makeBlockMeta(hash: "CA1", previousHash: "CG", height: 1)
        let cb1 = makeBlockMeta(hash: "CB1", previousHash: "CG", height: 1, parentChainBlocks: [:])

        let chain = makeChain(
            blocks: [g, ca1, cb1],
            mainChainHashes: Set(["CG", "CA1"]),
            parentChainMap: ["P_new": "CB1"],
            inheritedWeights: ["CB1": UInt256(10)]
        )

        let reorg = Reorganization(mainChainBlocksAdded: ["P_new": 10], mainChainBlocksRemoved: Set())
        let childReorg = await chain.propagateParentReorg(reorg: reorg)
        XCTAssertNotNil(childReorg)
        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, "CB1")
    }

    func testPropagateNoAffectedBlocksReturnsNil() async {
        let g = makeBlockMeta(hash: "G", height: 0)
        let chain = makeChain(blocks: [g])

        let reorg = Reorganization(mainChainBlocksAdded: ["unrelated": 5], mainChainBlocksRemoved: Set(["also_unrelated"]))
        let result = await chain.propagateParentReorg(reorg: reorg)
        XCTAssertNil(result)
    }
}

@MainActor
final class DuplicateBlockTests: XCTestCase {

    func testDuplicateWithoutParentInfoDiscarded() async {
        let (chain, _) = makeLinearChain(length: 3)
        let result = await chain.handleDuplicateBlock(parentBlockHeaderAndIndex: nil, blockHash: "block_1")
        XCTAssertFalse(result.addedBlock)
        XCTAssertNil(result.reorganization)
    }

    func testDuplicateAddsParentChainReference() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1)

        // handleDuplicateBlock still records the parent-chain reference; with B1
        // carrying heavier inherited weight, the re-check also promotes it.
        let chain = makeChain(
            blocks: [g, a1, b1],
            mainChainHashes: Set(["G", "A1"]),
            inheritedWeights: ["B1": UInt256(10)]
        )

        let result = await chain.handleDuplicateBlock(parentBlockHeaderAndIndex: ("parent_10", 10), blockHash: "B1")
        let b1Block = await chain.getConsensusBlock(hash: "B1")!
        XCTAssertEqual(b1Block.parentChainBlocks["parent_10"] as? UInt64, 10, "parent-chain reference recorded")
        XCTAssertNotNil(result.reorganization)
        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, "B1")
    }

    func testDuplicateAlreadyOnMainChainDiscarded() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1)

        let chain = makeChain(blocks: [g, a1], mainChainHashes: Set(["G", "A1"]))
        let result = await chain.handleDuplicateBlock(parentBlockHeaderAndIndex: ("parent_10", 10), blockHash: "A1")
        XCTAssertFalse(result.addedBlock)
        XCTAssertNil(result.reorganization)
    }
}

@MainActor
final class ChainWithMostWorkTests: XCTestCase {

    func testSingleBlockChain() async {
        let g = makeBlockMeta(hash: "G", height: 0)
        let chain = makeChain(blocks: [g])
        let work = await chain.chainWithMostWork(startingBlock: g)
        XCTAssertEqual(work.cumulativeWork, UInt256(1))
        XCTAssertEqual(work.blocks, Set(["G"]))
    }

    func testLinearChainWork() async {
        let (chain, blocks) = makeLinearChain(length: 4)
        let work = await chain.chainWithMostWork(startingBlock: blocks[0])
        XCTAssertEqual(work.cumulativeWork, UInt256(4))
        XCTAssertEqual(work.blocks.count, 4)
    }

    // F5-4: chainWithMostWork now returns the GHOST `trueCumWork` (the starting
    // block's whole subtree weight), and its `blocks` is the heaviest-subtree
    // descent path. G's subtree = all 6 blocks; the descent rides the heavier B fork.
    func testForkedChainPicksMoreWork() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3])
        let work = await chain.chainWithMostWork(startingBlock: g)
        XCTAssertEqual(work.cumulativeWork, UInt256(6), "trueCumWork(G) = whole subtree = 6 blocks")
        XCTAssertTrue(work.blocks.contains("B3"), "descent rides the heavier B fork to its tip")
        XCTAssertFalse(work.blocks.contains("A1"))
    }

    // F5-4: the descent rides the heaviest-trueCumWork child. A's subtree (3) loses
    // to B1 once B1 inherits heavy parent weight (10) — replaces parentIndex.
    func testForkedChainPicksInheritedHeavy() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2, childHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", height: 3)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1)

        let chain = makeChain(blocks: [g, a1, a2, a3, b1], inheritedWeights: ["B1": UInt256(10)])
        let work = await chain.chainWithMostWork(startingBlock: g)
        XCTAssertTrue(work.blocks.contains("B1"), "B1's inherited weight makes it the heaviest child")
        XCTAssertFalse(work.blocks.contains("A1"))
    }
}

// MARK: - Smoke Tests / Invariant Checks

@MainActor
final class ChainInvariantTests: XCTestCase {

    func testTipAlwaysOnMainChain() async {
        let (chain, _) = makeLinearChain(length: 10)
        let tip = await chain.getMainChainTip()
        let onMain = await chain.isOnMainChain(hash: tip)
        XCTAssertTrue(onMain)
    }

    func testTipAlwaysInBlockMap() async {
        let (chain, _) = makeLinearChain(length: 10)
        let tip = await chain.getMainChainTip()
        let block = await chain.getConsensusBlock(hash: tip)
        XCTAssertNotNil(block)
    }

    func testMainChainConnectivity() async {
        let (chain, blocks) = makeLinearChain(length: 10)
        for block in blocks {
            if let prevHash = block.parentBlockHash {
                let prevOnMain = await chain.isOnMainChain(hash: prevHash)
                let currentOnMain = await chain.isOnMainChain(hash: block.blockHash)
                if currentOnMain {
                    XCTAssertTrue(prevOnMain, "\(block.blockHash) on main but parent \(prevHash) not")
                }
            }
        }
    }

    func testReorgTipIsHighestInWinningFork() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)

        let chain = makeChain(blocks: [g, a1, b1, b2, b3], mainChainHashes: Set(["G", "A1"]))
        let block = await chain.getConsensusBlock(hash: "B3")!
        let _ = await chain.checkForReorg(block: block)

        let tip = await chain.getMainChainTip()
        let tipBlock = await chain.getConsensusBlock(hash: tip)!
        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(tipBlock.blockHeight, highest)
    }

    func testReorgRemovesOldMainChainBlocks() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3], mainChainHashes: Set(["G", "A1", "A2"]))
        let block = await chain.getConsensusBlock(hash: "B3")!
        let _ = await chain.checkForReorg(block: block)

        let a1OnMain = await chain.isOnMainChain(hash: "A1")
        XCTAssertFalse(a1OnMain)
        let a2OnMain = await chain.isOnMainChain(hash: "A2")
        XCTAssertFalse(a2OnMain)
        let gOnMain = await chain.isOnMainChain(hash: "G")
        XCTAssertTrue(gOnMain)
    }

    func testReorgStructContents() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2)

        let chain = makeChain(blocks: [g, a1, b1, b2], mainChainHashes: Set(["G", "A1"]))
        let block = await chain.getConsensusBlock(hash: "B2")!
        let reorg = await chain.checkForReorg(block: block)

        XCTAssertNotNil(reorg)
        XCTAssertTrue(reorg!.mainChainBlocksAdded.keys.contains("B1"))
        XCTAssertTrue(reorg!.mainChainBlocksAdded.keys.contains("B2"))
        XCTAssertFalse(reorg!.mainChainBlocksAdded.keys.contains("G"))
        XCTAssertTrue(reorg!.mainChainBlocksRemoved.contains("A1"))
        XCTAssertFalse(reorg!.mainChainBlocksRemoved.contains("G"))
    }
}

// MARK: - Nakamoto Consensus / Industry Standard Tests

@MainActor
final class NakamotoConsensusTests: XCTestCase {

    func testNakamotoLongestChainRule() async {
        let (chain, _) = makeLinearChain(length: 6, prefix: "main")
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "main_5")
        for i in 0..<6 {
            let onMain = await chain.isOnMainChain(hash: "main_\(i)")
            XCTAssertTrue(onMain)
        }
    }

    func testSelfishMiningReorg() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["P1", "H1"])
        let p1 = makeBlockMeta(hash: "P1", previousHash: "G", height: 1, childHashes: ["P2"])
        let p2 = makeBlockMeta(hash: "P2", previousHash: "P1", height: 2, childHashes: ["P3"])
        let p3 = makeBlockMeta(hash: "P3", previousHash: "P2", height: 3)
        let h1 = makeBlockMeta(hash: "H1", previousHash: "G", height: 1, childHashes: ["H2"])
        let h2 = makeBlockMeta(hash: "H2", previousHash: "H1", height: 2, childHashes: ["H3"])
        let h3 = makeBlockMeta(hash: "H3", previousHash: "H2", height: 3, childHashes: ["H4"])
        let h4 = makeBlockMeta(hash: "H4", previousHash: "H3", height: 4)

        let chain = makeChain(blocks: [g, p1, p2, p3, h1, h2, h3, h4], mainChainHashes: Set(["G", "P1", "P2", "P3"]))
        let block = await chain.getConsensusBlock(hash: "H4")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let selfishTip = await chain.getMainChainTip()
        XCTAssertEqual(selfishTip, "H4")

        for name in ["P1", "P2", "P3"] {
            let onMain = await chain.isOnMainChain(hash: name)
            XCTAssertFalse(onMain, "\(name) should be off main chain")
        }
        for name in ["H1", "H2", "H3", "H4"] {
            let onMain = await chain.isOnMainChain(hash: name)
            XCTAssertTrue(onMain, "\(name) should be on main chain")
        }
        let gOnMainSelfish = await chain.isOnMainChain(hash: "G")
        XCTAssertTrue(gOnMainSelfish)
    }

    func testFirstSeenTieBreaking() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2, childHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", height: 3)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)

        let chain = makeChain(blocks: [g, a1, a2, a3, b1, b2, b3], mainChainHashes: Set(["G", "A1", "A2", "A3"]))
        let block = await chain.getConsensusBlock(hash: "B3")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNil(reorg, "Equal-length fork must not trigger reorg")
        let tieTip = await chain.getMainChainTip()
        XCTAssertEqual(tieTip, "A3")
    }

    func testDeepReorgFromGenesis() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["M1", "F1"])
        let m1 = makeBlockMeta(hash: "M1", previousHash: "G", height: 1, childHashes: ["M2"])
        let m2 = makeBlockMeta(hash: "M2", previousHash: "M1", height: 2)
        let f1 = makeBlockMeta(hash: "F1", previousHash: "G", height: 1, childHashes: ["F2"])
        let f2 = makeBlockMeta(hash: "F2", previousHash: "F1", height: 2, childHashes: ["F3"])
        let f3 = makeBlockMeta(hash: "F3", previousHash: "F2", height: 3, childHashes: ["F4"])
        let f4 = makeBlockMeta(hash: "F4", previousHash: "F3", height: 4, childHashes: ["F5"])
        let f5 = makeBlockMeta(hash: "F5", previousHash: "F4", height: 5)

        let chain = makeChain(blocks: [g, m1, m2, f1, f2, f3, f4, f5], mainChainHashes: Set(["G", "M1", "M2"]))
        let block = await chain.getConsensusBlock(hash: "F5")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let deepTip = await chain.getMainChainTip()
        XCTAssertEqual(deepTip, "F5")
        let deepHighest = await chain.getHighestBlockHeight()
        XCTAssertEqual(deepHighest, 5)
    }

    func testMultipleConcurrentForks() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1", "C1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)
        let c1 = makeBlockMeta(hash: "C1", previousHash: "G", height: 1)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3, c1], mainChainHashes: Set(["G", "A1", "A2"]))
        let block = await chain.getConsensusBlock(hash: "B3")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let concurrentTip = await chain.getMainChainTip()
        XCTAssertEqual(concurrentTip, "B3")
    }

    func testMidChainFork() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["M1"])
        let m1 = makeBlockMeta(hash: "M1", previousHash: "G", height: 1, childHashes: ["M2"])
        let m2 = makeBlockMeta(hash: "M2", previousHash: "M1", height: 2, childHashes: ["M3", "F1"])
        let m3 = makeBlockMeta(hash: "M3", previousHash: "M2", height: 3)
        let f1 = makeBlockMeta(hash: "F1", previousHash: "M2", height: 3, childHashes: ["F2"])
        let f2 = makeBlockMeta(hash: "F2", previousHash: "F1", height: 4, childHashes: ["F3"])
        let f3 = makeBlockMeta(hash: "F3", previousHash: "F2", height: 5)

        let chain = makeChain(blocks: [g, m1, m2, m3, f1, f2, f3], mainChainHashes: Set(["G", "M1", "M2", "M3"]))
        let block = await chain.getConsensusBlock(hash: "F3")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let midTip = await chain.getMainChainTip()
        XCTAssertEqual(midTip, "F3")
        let m1OnMain = await chain.isOnMainChain(hash: "M1")
        XCTAssertTrue(m1OnMain)
        let m2OnMain = await chain.isOnMainChain(hash: "M2")
        XCTAssertTrue(m2OnMain)
        let m3OnMain = await chain.isOnMainChain(hash: "M3")
        XCTAssertFalse(m3OnMain)
    }
}

// MARK: - Lattice-Specific Consensus Tests

@MainActor
final class LatticeConsensusTests: XCTestCase {

    // F5-4: inherited parent weight overrides own-chain length. B1 (1 block) inherits
    // 20, beating the 5-block unanchored A chain (subtree 5).
    func testInheritedWeightOverridesLength() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2, childHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", height: 3, childHashes: ["A4"])
        let a4 = makeBlockMeta(hash: "A4", previousHash: "A3", height: 4, childHashes: ["A5"])
        let a5 = makeBlockMeta(hash: "A5", previousHash: "A4", height: 5)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, a4, a5, b1],
            mainChainHashes: Set(["G", "A1", "A2", "A3", "A4", "A5"]),
            inheritedWeights: ["B1": UInt256(20)]
        )

        let block = await chain.getConsensusBlock(hash: "B1")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg, "heavier inherited weight beats the longer unanchored chain")
        let parentOverrideTip = await chain.getMainChainTip()
        XCTAssertEqual(parentOverrideTip, "B1")
    }

    // F5-4: of two equal-length forks, the heavier-inherited one wins (replaces
    // "earlier anchoring wins").
    func testHeavierInheritedReorgsLighter() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1)

        let chain = makeChain(
            blocks: [g, a1, a2, b1],
            mainChainHashes: Set(["G", "A1", "A2"]),
            inheritedWeights: ["A1": UInt256(2), "B1": UInt256(50)]
        )

        let block = await chain.getConsensusBlock(hash: "B1")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let earlierTip = await chain.getMainChainTip()
        XCTAssertEqual(earlierTip, "B1")
    }

    // F5-4: equal trueCumWork ⇒ the incumbent main chain holds (strict `>`).
    func testEqualWeightIncumbentHolds() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1)

        let chain = makeChain(
            blocks: [g, a1, b1],
            mainChainHashes: Set(["G", "A1"]),
            inheritedWeights: ["A1": UInt256(50), "B1": UInt256(50)]
        )

        let block = await chain.getConsensusBlock(hash: "B1")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNil(reorg, "equal weight ⇒ incumbent holds")
    }

    // F5-4: when the node refreshes a block's inherited parent weight (the parent
    // chain extended a fork this block rides), its trueCumWork rises and may
    // trigger a reorg — the refresh path that replaces "late anchoring".
    func testInheritedWeightRefreshTriggersReorg() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1)

        let chain = makeChain(
            blocks: [g, a1, a2, b1],
            mainChainHashes: Set(["G", "A1", "A2"])
        )
        // The node's provider reads a live box; "refreshing" mutates it, exactly as
        // the parent chain extending would, without re-storing anything on the block.
        let box = MutableWeight()
        await chain.setInheritedWeightProvider { hash in hash == "B1" ? box.value : .zero }

        // B1 (subtree 1) loses to A (subtree 2) initially.
        let block = await chain.getConsensusBlock(hash: "B1")!
        let lateReorg = await chain.checkForReorg(block: block)
        XCTAssertNil(lateReorg)

        // Parent chain extends under B1's anchor ⇒ its inherited weight rises live.
        box.value = UInt256(10)
        let reorg = await chain.reevaluateForkChoice(blockHash: "B1")
        XCTAssertNotNil(reorg)
        let lateTip = await chain.getMainChainTip()
        XCTAssertEqual(lateTip, "B1")
    }

    // F5-4: a block riding a very heavy parent fork (large inherited weight) wins
    // even against a longer lightly-inherited chain (replaces "anchoring at index 0").
    func testMaxInheritedWeightBeatsAll() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1)

        let chain = makeChain(
            blocks: [g, a1, a2, b1],
            mainChainHashes: Set(["G", "A1", "A2"]),
            inheritedWeights: ["A1": UInt256(1), "B1": UInt256(1000)]
        )

        let block = await chain.getConsensusBlock(hash: "B1")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let zeroTip = await chain.getMainChainTip()
        XCTAssertEqual(zeroTip, "B1")
    }
}

// MARK: - Edge Case Tests

@MainActor
final class EdgeCaseTests: XCTestCase {

    func testSingleBlockNoForks() async {
        let g = makeBlockMeta(hash: "G", height: 0)
        let chain = makeChain(blocks: [g])
        let singleTip = await chain.getMainChainTip()
        XCTAssertEqual(singleTip, "G")
        let singleHighest = await chain.getHighestBlockHeight()
        XCTAssertEqual(singleHighest, 0)
    }

    func testNonexistentBlockReturnsNil() async {
        let (chain, _) = makeLinearChain(length: 1)
        let nope = await chain.getConsensusBlock(hash: "nope")
        XCTAssertNil(nope)
    }

    func testManyForksFromSameParent() async {
        var allBlocks: [BlockMeta] = []
        var genesisChildren: [String] = []

        for i in 0..<10 {
            let hash = "F\(i)_1"
            genesisChildren.append(hash)
            if i == 5 {
                allBlocks.append(makeBlockMeta(hash: hash, previousHash: "G", height: 1, childHashes: ["F5_2"]))
                allBlocks.append(makeBlockMeta(hash: "F5_2", previousHash: "F5_1", height: 2, childHashes: ["F5_3"]))
                allBlocks.append(makeBlockMeta(hash: "F5_3", previousHash: "F5_2", height: 3))
            } else {
                allBlocks.append(makeBlockMeta(hash: hash, previousHash: "G", height: 1))
            }
        }

        let g = makeBlockMeta(hash: "G", height: 0, childHashes: genesisChildren)
        allBlocks.insert(g, at: 0)

        let chain = makeChain(blocks: allBlocks, mainChainHashes: Set(["G", "F0_1"]))
        let block = await chain.getConsensusBlock(hash: "F5_3")!
        let reorg = await chain.checkForReorg(block: block)
        XCTAssertNotNil(reorg)
        let manyForksTip = await chain.getMainChainTip()
        XCTAssertEqual(manyForksTip, "F5_3")
    }

    func testLongLinearChain() async {
        let length = 500
        let (chain, _) = makeLinearChain(length: length)
        let longTip = await chain.getMainChainTip()
        XCTAssertEqual(longTip, "block_\(length - 1)")
        let longHighest = await chain.getHighestBlockHeight()
        XCTAssertEqual(longHighest, UInt64(length - 1))
        let containsFirst = await chain.contains(blockHash: "block_0")
        XCTAssertTrue(containsFirst)
        let containsLast = await chain.contains(blockHash: "block_\(length - 1)")
        XCTAssertTrue(containsLast)
    }
}
