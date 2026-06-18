import XCTest
@testable import Lattice
import UInt256

// SEC-101 /: the per-node depth-based finality floor has been removed
// ENTIRELY. Fork choice is pure heaviest-`trueCumWork`, so consensus must NOT
// reject a strictly-heavier valid chain for being too deep, and must still
// reject an equal/lighter chain. These tests drive the real reorg entry points
// (`checkForReorg` for direct fork submission and `propagateParentReorg` for
// parent-chain reorg propagation) using the same makeBlockMeta/makeChain helpers
// as the other consensus tests (defined in ChainConsensusTests.swift).

@MainActor
final class FinalityFloorTests: XCTestCase {

    /// Main chain G→A1→A2→A3→A4 (tip height 4); a heavier fork B2→B3→B4→B5
    /// branches off A1 (so its earliest orphan B2 is at height 2, buried 2 deep).
    /// Returns the chain plus the fork tip meta to feed `checkForReorg`.
    private func forkedChain() -> (ChainState, BlockMeta) {
        let g  = makeBlockMeta(hash: "G",  height: 0, childHashes: ["A1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G",  height: 1, childHashes: ["A2", "B2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2, childHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", height: 3, childHashes: ["A4"])
        let a4 = makeBlockMeta(hash: "A4", previousHash: "A3", height: 4)
        // Fork: 4 blocks off A1 vs the 3 main blocks A2/A3/A4 → strictly heavier.
        let b2 = makeBlockMeta(hash: "B2", previousHash: "A1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3, childHashes: ["B4"])
        let b4 = makeBlockMeta(hash: "B4", previousHash: "B3", height: 4, childHashes: ["B5"])
        let b5 = makeBlockMeta(hash: "B5", previousHash: "B4", height: 5)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, a4, b2, b3, b4, b5],
            mainChainHashes: Set(["G", "A1", "A2", "A3", "A4"])
        )
        return (chain, b5)
    }

    /// A strictly-heavier fork always reorgs — no depth floor can refuse it.
    func testHeavierForkAlwaysReorgs() async {
        let (chain, forkTip) = forkedChain()
        let reorg = await chain.checkForReorg(block: forkTip)
        XCTAssertNotNil(reorg, "heavier fork reorgs — there is no finality floor")
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "B5", "tip moves to the heavier fork")
    }

    /// The load-bearing invariant: a DEEP but strictly-heavier reorg is
    /// ACCEPTED. The deepest removed block (A2) is buried 2 deep below the tip,
    /// and a third block makes the fork strictly heavier; the old floor would
    /// have refused this. Pure heaviest-chain must follow it.
    func testDeepStrictlyHeavierForkIsAccepted() async {
        let (chain, forkTip) = forkedChain()
        let reorg = await chain.checkForReorg(block: forkTip)
        XCTAssertNotNil(reorg, "deep but strictly-heavier fork must NOT be refused for being too deep")
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "B5")
        // The whole old suffix is gone; the heavier fork is now canonical.
        for (idx, hash) in [(0, "G"), (1, "A1"), (2, "B2"), (3, "B3"), (4, "B4"), (5, "B5")] {
            let onMain = await chain.getMainChainBlockHash(atIndex: UInt64(idx))
            XCTAssertEqual(onMain, hash, "main chain index \(idx) follows the heavier fork")
        }
    }

    /// An equal-or-lighter fork is still rejected (fork choice only follows
    /// strictly-greater work). Here the fork B2→B3 (2 blocks) ties the main
    /// suffix A2/A3 in length but loses the hash tie-break / does not exceed it.
    func testEqualOrLighterForkIsRejected() async {
        let g  = makeBlockMeta(hash: "G",  height: 0, childHashes: ["A1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G",  height: 1, childHashes: ["A2", "B2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2, childHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", height: 3)
        // Lighter fork: only 1 block off A1 vs the 2 main blocks A2/A3.
        let b2 = makeBlockMeta(hash: "B2", previousHash: "A1", height: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, b2],
            mainChainHashes: Set(["G", "A1", "A2", "A3"])
        )
        let b2block = await chain.getConsensusBlock(hash: "B2")!
        let reorg = await chain.checkForReorg(block: b2block)
        XCTAssertNil(reorg, "lighter fork must be rejected (heaviest-chain only)")
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "A3", "tip stays on the heavier original chain")
    }

    // MARK: - Parent-chain reorg propagation path

    /// Main CG→CA1→CA2→CA3 (tip height 3); a fork CB1 branches off CG (height 1,
    /// buried 3-1 = 2 deep) anchored to parent block "P_new". A parent-chain
    /// reorg that promotes P_new makes the heavy anchored fork win — exercising
    /// the `findBestReorg` path, which must also have no depth floor.
    private func parentForkedChain() -> ChainState {
        let g   = makeBlockMeta(hash: "CG",  height: 0, childHashes: ["CA1", "CB1"])
        let ca1 = makeBlockMeta(hash: "CA1", previousHash: "CG",  height: 1, childHashes: ["CA2"])
        let ca2 = makeBlockMeta(hash: "CA2", previousHash: "CA1", height: 2, childHashes: ["CA3"])
        let ca3 = makeBlockMeta(hash: "CA3", previousHash: "CA2", height: 3)
        let cb1 = makeBlockMeta(hash: "CB1", previousHash: "CG",  height: 1, parentChainBlocks: [:])
        // CB1 rides a heavy parent fork (inherited weight 10) — outweighs CA's
        // 3-block subtree, so the parent reorg promotes it (no floor refuses it).
        return makeChain(
            blocks: [g, ca1, ca2, ca3, cb1],
            mainChainHashes: Set(["CG", "CA1", "CA2", "CA3"]),
            parentChainMap: ["P_new": "CB1"],
            inheritedWeights: ["CB1": UInt256(10)]
        )
    }

    /// Parent-propagated reorg that is deep AND strictly heavier is accepted —
    /// `findBestReorg` no longer enforces any finality floor.
    func testDeepParentPropagatedReorgIsAccepted() async {
        let chain = parentForkedChain()
        let reorg = Reorganization(mainChainBlocksAdded: ["P_new": 10], mainChainBlocksRemoved: Set())
        let childReorg = await chain.propagateParentReorg(reorg: reorg)
        XCTAssertNotNil(childReorg, "deep, heavier parent-propagated reorg is accepted — no finality floor")
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "CB1")
    }
}
