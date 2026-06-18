import XCTest
@testable import Lattice
import UInt256
import cashew

//: `applyParentReorg` computed `block.height + retentionDepth` with an
// unchecked UInt64 add. `retentionDepth` defaults to `RECENT_BLOCK_DISTANCE ==
// UInt64.max`, so a parent reorg carrying any non-genesis block (height >= 1)
// overflowed the add and TRAPPED the actor — a crafted parent reorg crashes the
// node (mainnet-blocker). The fix guards the add with `addingReportingOverflow`
// (matching the existing `insertBlock`/`submit` retention-window guards): an
// overflow saturates the `>= highestBlockHeight` retention predicate to `true`
// instead of trapping.
//
// Entry point is the REAL public reorg path `ChainState.applyParentReorg`, fed an
// overflow-inducing block. RED before the fix: the actor traps (fatalError on the
// overflowing add). GREEN after: the call returns and the actor stays alive.
@MainActor
final class ParentReorgOverflowTests: XCTestCase {

    func testApplyParentReorgDoesNotTrapOnRetentionOverflow() async {
        // Default retentionDepth = RECENT_BLOCK_DISTANCE = UInt64.max, so for any
        // block height >= 1 the unchecked `height + retentionDepth` overflowed.
        let genesis = makeGenesisBlock()
        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2_000)
        let block1Hash = blockHeader(block1).rawCID
        let genesisHash = blockHeader(genesis).rawCID

        let g = makeBlockMeta(hash: genesisHash, height: 0)
        let chain = makeChain(blocks: [g], mainChainHashes: Set([genesisHash]))

        let reorg = Reorganization(
            mainChainBlocksAdded: [block1Hash: 1],
            mainChainBlocksRemoved: Set()
        )

        // Before the fix this overflowing add trapped the actor (crash). After the
        // fix it saturates the retention predicate and the call returns safely.
        let result = await chain.applyParentReorg(
            reorg: reorg,
            parentBlockHeaderAndIndex: nil,
            blockHash: block1Hash,
            block: block1
        )

        // The actor survived (no trap) and processed the input safely: block1
        // extends the incumbent tip, so it is inserted and becomes the new tip
        // with no orphan reorganization required.
        XCTAssertTrue(result.addedBlock)
        XCTAssertNil(result.reorganization)
        // The actor is still responsive after the overflow-inducing input.
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, block1Hash)
    }
}
