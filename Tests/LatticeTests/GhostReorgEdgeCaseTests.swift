import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

// F5-5: extensive edge-case coverage for Hierarchical GHOST fork choice & reorgs
// (design consensus-fork-choice.md §3/§4/§6). Uses the synchronous makeBlockMeta /
// makeChain harness (uniform own-work = 1 per block unless noted) with the
// `inheritedWeights` provider to drive cross-chain inheritance, exercising:
//   - GHOST descent over nested/multi-level forks (heaviest *subtree*, not longest path)
//   - inheritance-dominated fork choice (ride the heaviest parent fork; flip it back)
//   - deterministic tie-breaking
//   - finality floor vs. a heavy GHOST reorg
//   - subtree weight counting ALL branches under reorg

@MainActor
final class GhostReorgEdgeCaseTests: XCTestCase {

    // A shorter main chain loses to a fork whose *subtree* is heavier because the
    // fork branches (GHOST counts both branches), even though no single fork path
    // is longer than main.
    func testForkWithBranchingSubtreeOutweighsLongerSinglePath() async {
        // main: G→M1→M2→M3 (subtree at M1 = 3).
        // fork: G→F1, F1 has two children F2a, F2b (subtree at F1 = 3: F1,F2a,F2b).
        // Tie at 3 vs 3 → incumbent (main) holds. Add F3a under F2a → fork subtree 4 > 3.
        let g  = makeBlockMeta(hash: "G",  height: 0, childHashes: ["M1", "F1"])
        let m1 = makeBlockMeta(hash: "M1", previousHash: "G",  height: 1, childHashes: ["M2"])
        let m2 = makeBlockMeta(hash: "M2", previousHash: "M1", height: 2, childHashes: ["M3"])
        let m3 = makeBlockMeta(hash: "M3", previousHash: "M2", height: 3)
        let f1  = makeBlockMeta(hash: "F1",  previousHash: "G",  height: 1, childHashes: ["F2a", "F2b"])
        let f2a = makeBlockMeta(hash: "F2a", previousHash: "F1", height: 2, childHashes: ["F3a"])
        let f2b = makeBlockMeta(hash: "F2b", previousHash: "F1", height: 2)
        let f3a = makeBlockMeta(hash: "F3a", previousHash: "F2a", height: 3)

        let chain = makeChain(
            blocks: [g, m1, m2, m3, f1, f2a, f2b, f3a],
            mainChainHashes: Set(["G", "M1", "M2", "M3"])
        )
        // subtreeWeight(F1) = {F1,F2a,F2b,F3a} = 4 > subtreeWeight(M1) = {M1,M2,M3} = 3.
        let f1block = await chain.getConsensusBlock(hash: "F1")!
        let reorg = await chain.checkForReorg(block: f1block)
        XCTAssertNotNil(reorg, "fork's branching subtree (4) outweighs main's single path (3)")
        // GHOST descent picks the heaviest leaf under F1 — the F2a→F3a branch.
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "F3a", "descent rides the heavier branch to its leaf")
    }

    // Equal subtree weights ⇒ incumbent main chain holds (strict-greater reorg).
    func testEqualSubtreeIncumbentHolds() async {
        let g  = makeBlockMeta(hash: "G",  height: 0, childHashes: ["M1", "F1"])
        let m1 = makeBlockMeta(hash: "M1", previousHash: "G",  height: 1, childHashes: ["M2"])
        let m2 = makeBlockMeta(hash: "M2", previousHash: "M1", height: 2)
        let f1 = makeBlockMeta(hash: "F1", previousHash: "G",  height: 1, childHashes: ["F2"])
        let f2 = makeBlockMeta(hash: "F2", previousHash: "F1", height: 2)

        let chain = makeChain(blocks: [g, m1, m2, f1, f2], mainChainHashes: Set(["G", "M1", "M2"]))
        let f1block = await chain.getConsensusBlock(hash: "F1")!
        let reorg = await chain.checkForReorg(block: f1block)
        XCTAssertNil(reorg, "equal subtree weight ⇒ incumbent holds")
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "M2")
    }

    // Inheritance-dominated: two equal-size child forks; the canonical one is the
    // one riding the heavier parent fork (larger inherited weight). Then the parent
    // fork flips (provider values swap) and re-evaluation flips the child too.
    func testChildRidesHeaviestParentForkAndFlips() async {
        let g  = makeBlockMeta(hash: "CG", height: 0, childHashes: ["CA", "CB"])
        let ca = makeBlockMeta(hash: "CA", previousHash: "CG", height: 1)
        let cb = makeBlockMeta(hash: "CB", previousHash: "CG", height: 1)
        // CB inherits more than CA ⇒ CB canonical.
        let box = ForkWeights()
        box.weights = ["CA": UInt256(5), "CB": UInt256(20)]
        let chain = try! ChainState(
            chainTip: "CA", mainChainHashes: Set(["CG", "CA"]),
            indexToBlockHash: [0: ["CG"], 1: ["CA", "CB"]],
            hashToBlock: ["CG": g, "CA": ca, "CB": cb],
            parentChainBlockHashToBlockHash: [:],
            inheritedWeightProvider: { box.weights[$0] ?? .zero }
        )
        let cbBlock = await chain.getConsensusBlock(hash: "CB")!
        let reorg1 = await chain.checkForReorg(block: cbBlock)
        XCTAssertNotNil(reorg1, "CB rides the heavier parent fork (20 > 5)")
        let tip1 = await chain.getMainChainTip(); XCTAssertEqual(tip1, "CB")

        // Parent fork flips: now CA's fork is heavier. Re-evaluate CA.
        box.weights = ["CA": UInt256(30), "CB": UInt256(20)]
        let reorg2 = await chain.reevaluateForkChoice(blockHash: "CA")
        XCTAssertNotNil(reorg2, "parent fork flipped ⇒ CA now canonical")
        let tip2 = await chain.getMainChainTip(); XCTAssertEqual(tip2, "CA")
    }

    // Deterministic tie-break: equal-weight sibling leaves ⇒ the lexicographically
    // smaller hash is chosen, so every node agrees on the same tip.
    func testTieBreakByHashIsDeterministic() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["zzz", "aaa"])
        let z = makeBlockMeta(hash: "zzz", previousHash: "G", height: 1)
        let a = makeBlockMeta(hash: "aaa", previousHash: "G", height: 1)
        // Start with main = zzz; aaa ties on weight (both subtree 1). Incumbent holds,
        // but the *descent from genesis* must deterministically prefer "aaa" (smaller).
        let chain = makeChain(blocks: [g, z, a], mainChainHashes: Set(["G", "zzz"]))
        let work = await chain.chainWithMostWork(startingBlock: g)
        XCTAssertEqual(work.tipHash, "aaa", "tie broken toward the smaller hash, deterministically")
        // And on a tie the incumbent main tip is NOT reorged away (strict-greater).
        let aBlock = await chain.getConsensusBlock(hash: "aaa")!
        let reorg = await chain.checkForReorg(block: aBlock)
        XCTAssertNil(reorg, "a weight tie does not reorg the incumbent")
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "zzz", "incumbent held despite the deterministic descent preferring aaa")
    }

    // A fork with strictly LOWER inherited weight than the main chain does not reorg
    // (the inheritance path's negative direction).
    func testLighterInheritedForkDoesNotReorg() async {
        let g  = makeBlockMeta(hash: "G",  height: 0, childHashes: ["M1", "F1"])
        let m1 = makeBlockMeta(hash: "M1", previousHash: "G", height: 1)
        let f1 = makeBlockMeta(hash: "F1", previousHash: "G", height: 1)
        let chain = makeChain(
            blocks: [g, m1, f1],
            mainChainHashes: Set(["G", "M1"]),
            inheritedWeights: ["M1": UInt256(50), "F1": UInt256(10)]
        )
        let f1block = await chain.getConsensusBlock(hash: "F1")!
        let reorg = await chain.checkForReorg(block: f1block)
        XCTAssertNil(reorg, "F1 (own 1 + inherited 10 = 11) < M1 (1 + 50 = 51) ⇒ no reorg")
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "M1")
    }

    // Demotion: a canonical fork whose inherited weight DROPS (its parent fork was
    // orphaned) is demoted when the node re-evaluates the now-heavier competitor.
    // reevaluateForkChoice only ever *promotes*, so the node drives demotion by
    // re-evaluating the rival — exercising that path.
    func testDemotionWhenInheritedWeightDrops() async {
        let g  = makeBlockMeta(hash: "CG", height: 0, childHashes: ["CA", "CB"])
        let ca = makeBlockMeta(hash: "CA", previousHash: "CG", height: 1)
        let cb = makeBlockMeta(hash: "CB", previousHash: "CG", height: 1)
        let box = ForkWeights()
        box.weights = ["CA": UInt256(5), "CB": UInt256(20)]   // CB canonical
        let chain = try! ChainState(
            chainTip: "CB", mainChainHashes: Set(["CG", "CB"]),
            indexToBlockHash: [0: ["CG"], 1: ["CA", "CB"]],
            hashToBlock: ["CG": g, "CA": ca, "CB": cb],
            parentChainBlockHashToBlockHash: [:],
            inheritedWeightProvider: { box.weights[$0] ?? .zero }
        )
        // CB's parent fork is orphaned ⇒ its inherited weight collapses; CA now wins.
        box.weights = ["CA": UInt256(5), "CB": UInt256(1)]
        let reorg = await chain.reevaluateForkChoice(blockHash: "CA")
        XCTAssertNotNil(reorg, "CA (5) now beats the demoted CB (1)")
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "CA")
    }

    // SEC-101 /: there is NO finality floor — a strictly-heavier GHOST
    // reorg is followed regardless of how deep below the tip its fork point sits.
    func testDeepHeavyGhostReorgIsAcceptedNoFinalityFloor() async {
        let g  = makeBlockMeta(hash: "G",  height: 0, childHashes: ["M1", "F1"])
        let m1 = makeBlockMeta(hash: "M1", previousHash: "G",  height: 1, childHashes: ["M2"])
        let m2 = makeBlockMeta(hash: "M2", previousHash: "M1", height: 2, childHashes: ["M3"])
        let m3 = makeBlockMeta(hash: "M3", previousHash: "M2", height: 3)
        let f1 = makeBlockMeta(hash: "F1", previousHash: "G",  height: 1)  // fork at height 1

        let chain = makeChain(
            blocks: [g, m1, m2, m3, f1],
            mainChainHashes: Set(["G", "M1", "M2", "M3"]),
            inheritedWeights: ["F1": UInt256(1000)]   // dominates the main subtree
        )
        // Fork point (height 1) is buried 2 deep below the tip (height 3). The old
        // depth-based floor would have refused this; with the floor removed, the
        // heavier fork wins.
        let f1block = await chain.getConsensusBlock(hash: "F1")!
        let reorg = await chain.checkForReorg(block: f1block)
        XCTAssertNotNil(reorg, "deep but strictly-heavier fork reorgs — no finality floor")
        let tip = await chain.getMainChainTip(); XCTAssertEqual(tip, "F1")
    }

    // A reorg's GHOST descent must rebuild the FULL winning subtree's main-chain
    // path and drop the entire old suffix, including across a multi-block fork.
    func testReorgRemovesFullOldSuffixAndInstallsWinningPath() async {
        let g  = makeBlockMeta(hash: "G",  height: 0, childHashes: ["M1", "F1"])
        let m1 = makeBlockMeta(hash: "M1", previousHash: "G",  height: 1, childHashes: ["M2"])
        let m2 = makeBlockMeta(hash: "M2", previousHash: "M1", height: 2)
        let f1 = makeBlockMeta(hash: "F1", previousHash: "G",  height: 1, childHashes: ["F2"])
        let f2 = makeBlockMeta(hash: "F2", previousHash: "F1", height: 2, childHashes: ["F3"])
        let f3 = makeBlockMeta(hash: "F3", previousHash: "F2", height: 3)

        let chain = makeChain(blocks: [g, m1, m2, f1, f2, f3], mainChainHashes: Set(["G", "M1", "M2"]))
        let f1block = await chain.getConsensusBlock(hash: "F1")!
        let reorg = await chain.checkForReorg(block: f1block)
        XCTAssertNotNil(reorg)
        XCTAssertEqual(reorg?.mainChainBlocksRemoved, Set(["M1", "M2"]), "entire old suffix removed")
        XCTAssertEqual(Set(reorg!.mainChainBlocksAdded.keys), Set(["F1", "F2", "F3"]), "winning path installed")
        let tip = await chain.getMainChainTip(); XCTAssertEqual(tip, "F3")
        // Old main blocks are no longer on the main chain.
        let m1OnMain = await chain.isOnMainChain(hash: "M1")
        XCTAssertFalse(m1OnMain)
    }

    // Out-of-order delivery + reorg: a heavier fork's blocks arrive children-before
    // -parents; once the fork is complete its subtree weight back-propagates and the
    // reorg fires. Uses real blocks (BlockBuilder) since the static makeChain harness
    // can't model arrival order.
    func testOutOfOrderForkTriggersReorgOnceComplete() async throws {
        let fetcher = StorableFetcher()
        let diff = UInt256(1000)
        let base = Int64(Date().timeIntervalSince1970 * 1000) - 50_000
        let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000, premine: 0,
                             targetBlockTime: 1_000, initialReward: 1024, halvingInterval: 10_000,
                             retargetWindow: 5)
        let genesis = try await BlockBuilder.buildGenesis(spec: spec, timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        // Main chain G→A→B (2 blocks).
        let a = try await BlockBuilder.buildBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        let b = try await BlockBuilder.buildBlock(previous: a, timestamp: base + 2000, target: diff, nonce: 2, fetcher: fetcher)
        for blk in [a, b] {
            _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: blk), block: blk)
        }
        let cid = { (blk: Block) in try! VolumeImpl<Block>(node: blk).rawCID }
        let tipBefore = await chain.getMainChainTip()
        XCTAssertEqual(tipBefore, cid(b))

        // Heavier fork G→X→Y→Z (3 blocks), delivered Z, Y, X (children before parents).
        let x = try await BlockBuilder.buildBlock(previous: genesis, timestamp: base + 1500, target: diff, nonce: 91, fetcher: fetcher)
        let y = try await BlockBuilder.buildBlock(previous: x, timestamp: base + 2500, target: diff, nonce: 92, fetcher: fetcher)
        let z = try await BlockBuilder.buildBlock(previous: y, timestamp: base + 3500, target: diff, nonce: 93, fetcher: fetcher)
        for blk in [z, y, x] {
            _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: blk), block: blk)
        }
        // Once X (the fork base) is delivered, the fork subtree (3) > main (2) ⇒ reorg.
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, cid(z), "out-of-order heavier fork reorgs once complete")
    }
}

/// Mutable provider source for the parent-fork-flip test.
final class ForkWeights: @unchecked Sendable {
    var weights: [String: UInt256] = [:]
}

// MARK: -: reorg-bookkeeping + fork-choice correctness (7 sub-fixes)

@MainActor
final class TRE88ReorgBookkeepingTests: XCTestCase {

    // (1) Tip-extend must emit the connect set when GHOST descent advances the tip
    // past already-attached out-of-order descendants — otherwise updateParentsForReorg
    // never re-anchors them. genesis→C0(tip); grandchild G(parent=C1) pre-attached
    // out of order before C1; submit C1(parent==tip). The tip jumps C0→C1→G, so the
    // result must carry a Reorganization listing BOTH C1 and G (not reorganization==nil).
    func test_tipExtendEmitsConnectSetForOutOfOrderDescendants() async throws {
        let fetcher = StorableFetcher()
        let diff = UInt256(1000)
        let base = Int64(Date().timeIntervalSince1970 * 1000) - 50_000
        let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000, premine: 0,
                             targetBlockTime: 1_000, initialReward: 1024, halvingInterval: 10_000,
                             retargetWindow: 5)
        let genesis = try await BlockBuilder.buildGenesis(spec: spec, timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        let cid = { (blk: Block) in try! VolumeImpl<Block>(node: blk).rawCID }

        // C0 extends genesis and becomes the tip.
        let c0 = try await BlockBuilder.buildBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: c0), block: c0)
        let tipAfterC0 = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterC0, cid(c0))

        // C1 extends C0; G extends C1. Deliver G FIRST (out of order, before C1) so it
        // is attached but not on the main chain; then deliver C1 whose parent is the tip.
        let c1 = try await BlockBuilder.buildBlock(previous: c0, timestamp: base + 2000, target: diff, nonce: 2, fetcher: fetcher)
        let gg = try await BlockBuilder.buildBlock(previous: c1, timestamp: base + 3000, target: diff, nonce: 3, fetcher: fetcher)
        _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: gg), block: gg)

        let result = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: c1), block: c1)
        XCTAssertTrue(result.extendsMainChain, "C1's parent is the tip, so this extends the main chain")
        let finalTip = await chain.getMainChainTip()
        XCTAssertEqual(finalTip, cid(gg), "the tip advances past the out-of-order grandchild")
        let added = result.reorganization?.mainChainBlocksAdded
        XCTAssertNotNil(added, "tip-extend that advances past out-of-order descendants must emit a Reorganization")
        XCTAssertTrue(added?.keys.contains(cid(c1)) ?? false, "connect set contains C1")
        XCTAssertTrue(added?.keys.contains(cid(gg)) ?? false, "connect set contains the out-of-order grandchild G")
    }

    // (2) ghostDescent must not silently descend a lighter surviving sibling when the
    // heaviest child was pruned from the body store. With/218 the heavier
    // child's weight/linkage is retained in weightIndex, so descent weighs it from the
    // index and the backfill trigger surfaces it as needed-to-refetch.
    func test_ghostDescentReturnsNeededHashesForPrunedHeavierChild() async {
        // G→A1 (main tip). A1 has two children: H (heavy subtree H→H2, weight 2) and
        // L (light leaf, weight 1). H is pruned from the body store but retained in the
        // weight index. Descent must pick H (heavier), not L, and surface H/H2 as
        // refetch targets — never silently descend L.
        let g  = makeBlockMeta(hash: "G",  height: 0, childHashes: ["A1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["H", "L"])
        let h  = makeBlockMeta(hash: "H",  previousHash: "A1", height: 2, childHashes: ["H2"])
        let h2 = makeBlockMeta(hash: "H2", previousHash: "H", height: 3)
        let l  = makeBlockMeta(hash: "L",  previousHash: "A1", height: 2)
        let chain = makeChain(blocks: [g, a1, h, h2, l], mainChainHashes: Set(["G", "A1"]))

        // Simulate body-pruning of the heavier branch's deepest interior: drop H2 from
        // the body store while retaining its weight/linkage in the durable index (the
        // invariant). H is still present, so the heavier child of A1 is index-
        // weighed (subtree {H, H2} = 2) and must beat the lighter sibling L (= 1).
        await chain.pruneBlocksAtIndex(3)

        let descent = await chain.heaviestDescent(fromHash: "A1")
        XCTAssertEqual(descent?.tipHash, "H2", "descent identifies the heavier (pruned) branch's leaf, not the lighter sibling")

        let target = await chain.heldHeavierBackfillTarget()
        XCTAssertEqual(target?.tipHash, "H2", "the heavier pruned branch is surfaced as the backfill target")
        XCTAssertEqual(Set(target?.missingBodies ?? []), Set(["H2"]), "the pruned interior body is needed-to-refetch")
        XCTAssertFalse(target?.missingBodies.contains("L") ?? true, "the lighter surviving sibling is never chosen")
    }

    // (3) highestBlock must not trap the actor when chainTip is absent from hashToBlock.
    func test_highestBlockDoesNotTrapOnMissingTip() async {
        let g = makeBlockMeta(hash: "G", height: 0)
        let chain = makeChain(blocks: [g], mainChainHashes: Set(["G"]))
        // Force a tip that is not present in the body store.
        await chain.setChainTip("ghost-tip-absent")
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 0, "a missing tip returns gracefully without trapping the actor")
    }

    // (4) applyReorg must not force-unwrap a fork block absent from hashToBlock (the
    // chainWithMostWork "?? startingBlock" detached fallback).
    func test_applyReorgGuardsDetachedFallback() async {
        let g  = makeBlockMeta(hash: "G",  height: 0, childHashes: ["A1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1)
        let chain = makeChain(blocks: [g, a1], mainChainHashes: Set(["G", "A1"]))
        // newForkBlocks includes a hash present in neither hashToBlock nor weightIndex.
        let reorg = await chain.applyReorg(
            newForkBlocks: Set(["G", "phantom-detached"]),
            newForkTipHash: "G",
            mainChainBlocks: Set()
        )
        XCTAssertFalse(reorg.mainChainBlocksAdded.keys.contains("phantom-detached"),
                       "an absent fork block is skipped, not force-unwrapped")
    }

    // (6) getCumulativeWork(limit:) must saturate, not wrap, when per-block work
    // overflows within the window.
    func test_getCumulativeWorkLimitSaturates() async {
        // Two blocks whose work sums overflow UInt256: max + max wraps to max-1 with &+.
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["T"], work: UInt256.max)
        let t = makeBlockMeta(hash: "T", previousHash: "G", height: 1, work: UInt256.max)
        let chain = makeChain(blocks: [g, t], mainChainHashes: Set(["G", "T"]))
        let total = await chain.getCumulativeWork(limit: 10)
        XCTAssertEqual(total, UInt256.max, "overflowing windowed work saturates to .max, not a wrapped value")
    }

    // (7) init and resetFrom must produce identical subtree weights for every hash
    // (the rebuild loop must not drift between the two construction paths).
    func test_initAndResetFromProduceIdenticalSubtreeWeights() async throws {
        // A fixed multi-branch tree: G→A1→{A2, B2}; A2→A3.
        let g  = makeBlockMeta(hash: "G",  height: 0, childHashes: ["A1"], work: UInt256(3))
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2", "B2"], work: UInt256(5))
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2, childHashes: ["A3"], work: UInt256(7))
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", height: 3, work: UInt256(11))
        let b2 = makeBlockMeta(hash: "B2", previousHash: "A1", height: 2, work: UInt256(13))
        let viaInit = makeChain(blocks: [g, a1, a2, a3, b2], mainChainHashes: Set(["G", "A1", "A2", "A3"]))

        // Build an equivalent persisted snapshot and restore it via resetFrom.
        func persistedBlock(_ m: BlockMeta) -> PersistedBlockMeta {
            PersistedBlockMeta(
                blockHash: m.blockHash,
                parentBlockHash: m.parentBlockHash,
                blockHeight: m.blockHeight,
                parentChainBlocks: m.parentChainBlocks,
                childHashes: m.childHashes,
                target: (UInt256.max / m.work).toHexString(),
                timestamp: nil,
                cumulativeWork: nil,
                subtreeWeight: nil,
                workHex: m.work.toHexString()
            )
        }
        let persisted = PersistedChainState(
            chainTip: "A3",
            tipPostStateCID: nil, tipPrevStateCID: nil, tipSpecCID: nil,
            tipTarget: nil, tipNextTarget: nil, tipHeight: nil, tipTimestamp: nil,
            mainChainHashes: ["G", "A1", "A2", "A3"],
            blocks: [g, a1, a2, a3, b2].map(persistedBlock),
            parentChainMap: [:],
            missingBlockHashes: []
        )
        let viaReset = makeChain(blocks: [makeBlockMeta(hash: "X", height: 0)])
        try await viaReset.resetFrom(persisted)

        for hash in ["G", "A1", "A2", "A3", "B2"] {
            let initWeight = await viaInit.subtreeWeight(forHash: hash)
            let resetWeight = await viaReset.subtreeWeight(forHash: hash)
            XCTAssertEqual(initWeight, resetWeight, "subtree weight for \(hash) must match across init and resetFrom")
        }
    }
}
