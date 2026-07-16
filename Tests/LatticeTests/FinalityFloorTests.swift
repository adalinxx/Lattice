import XCTest
@testable import Lattice
import UInt256

// SEC-101 /: the per-node depth-based finality floor has been removed
// ENTIRELY. Fork choice is pure heaviest-subtree work, so consensus must NOT
// reject a strictly-heavier valid chain for being too deep, and must still
// reject a lighter chain. These tests drive the same projection entry point as
// the other consensus tests.

@MainActor
final class FinalityFloorTests: XCTestCase {

    /// Main chain G→A1→A2→A3→A4 (tip height 4); a heavier fork B2→B3→B4→B5
    /// branches off A1 (so its earliest orphan B2 is at height 2, buried 2 deep).
    private func forkedChain() -> ChainState {
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

        return makeChain(
            blocks: [g, a1, a2, a3, a4, b2, b3, b4, b5],
            mainChainHashes: Set(["G", "A1", "A2", "A3", "A4"])
        )
    }

    /// A strictly-heavier fork always reorgs — no depth floor can refuse it.
    func testHeavierForkAlwaysReorgs() async {
        let chain = forkedChain()
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg, "heavier fork reorgs — there is no finality floor")
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "B5", "tip moves to the heavier fork")
    }

    /// The load-bearing invariant: a DEEP but strictly-heavier reorg is
    /// ACCEPTED. The deepest removed block (A2) is buried 2 deep below the tip,
    /// and a third block makes the fork strictly heavier; the old floor would
    /// have refused this. Pure heaviest-chain must follow it.
    func testDeepStrictlyHeavierForkIsAccepted() async {
        let chain = forkedChain()
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg, "deep but strictly-heavier fork must NOT be refused for being too deep")
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "B5")
        // The whole old suffix is gone; the heavier fork is now canonical.
        for (idx, hash) in [(0, "G"), (1, "A1"), (2, "B2"), (3, "B3"), (4, "B4"), (5, "B5")] {
            let onMain = await chain.getMainChainBlockHash(atIndex: UInt64(idx))
            XCTAssertEqual(onMain, hash, "main chain index \(idx) follows the heavier fork")
        }
    }

    /// A lighter fork is still rejected by the first fork-choice comparator.
    func testLighterForkIsRejected() async {
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
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNil(reorg, "lighter fork must be rejected (heaviest-chain only)")
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "A3", "tip stays on the heavier original chain")
    }

}
