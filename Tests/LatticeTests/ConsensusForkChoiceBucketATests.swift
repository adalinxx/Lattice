import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

// Bucket-A mainnet-readiness consensus tests test phase).
//
//   CFC-A1: ghostDescent no-downgrade obligation — a pruned heavier-branch
//                     interior must NOT let fork choice pick the lighter sibling and
//                     regress the tip.
//   CFC-A2:           getCumulativeWork(limit:) saturation — the windowed prefix sum
//                     must not wrap modulo 2^256 and report a spuriously-lower work.
//   CFC-A3: corrupted persisted target fails closed on restore/resetFrom —
//                     a present-but-undecodable target must be flagged, not silently
//                     mapped to UInt256.zero work.
//
// Entry points are the REAL fork-choice / accumulation / restore paths
// (checkForReorg via the GHOST descent, submitBlock, ChainState.restore/resetFrom),
// not private helpers.

private func f() -> StorableFetcher { StorableFetcher() }
private func spec(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: 0, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
}
private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

final class ConsensusForkChoiceBucketATests: XCTestCase {

    // MARK: - CFC-A1: no-downgrade obligation under a pruned heavier branch

    // Two ChainState over the SAME DAG. The "oracle" never prunes; the "pruned"
    // copy has the heavier fork's interior block missing from hashToBlock (as
    // retention would leave it after a restart that dropped an ancestor). Fork
    // choice on the pruned copy must NOT descend the visible-but-lighter sibling
    // and regress its tip below the incumbent main chain.
    // DAG:
    //   main:  G -> M1 -> M2                  (main own-work = 2 each; tip M2)
    //   fork:  G -> F1 -> { F2a -> F3a -> F4a -> F5a ,  F2b }  (fork own-work = 1)
    // Subtree weights (own-work sums): M1's subtree = M1+M2 = 4;
    // F1's subtree = F1+F2a+F2b+F3a+F4a+F5a = 6 > 4 — the fork legitimately wins
    // fork choice with the heavy branch present, and descent rides to F5a.
    // Cumulative (genesis-relative) work: M2 = G+M1+M2 = 1+2+2 = 5;
    // the fork's truncated-reachable leaf F2a = G+F1+F2a = 1+1+1 = 3 < 5.
    // When retention drops the interior F3a (heights 3..5 are fork-only, so the
    // main tip M2 survives), F1 keeps its already-accumulated subtree weight (6),
    // so the fork still "wins" the subtree comparison — but descent can no longer
    // reach F5a and lands on F2a, a tip of LOWER cumulative work than M2. The
    // no-downgrade obligation must refuse that regression.
    private func buildForkDag() -> [BlockMeta] {
        let m = UInt256(2)
        let w = UInt256(1)
        // Genesis-relative cumulativeWork prefix sums (parent.cum + own work) are
        // seeded explicitly so the no-downgrade guard exercises its REAL durable
        // comparison `forkTip.cumulativeWork <= highestBlock.cumulativeWork`
        // (not a 0<=0 tautology over a .zero default). Main tip M2 = 5; the
        // truncated fork's reachable leaf F2a = 3 (< 5, a downgrade); the heavy
        // branch's true leaf F5a = 6 (> 5, the legitimate win when present).
        return [
            makeBlockMeta(hash: "G",   height: 0, childHashes: ["M1", "F1"], work: w, cumulativeWork: UInt256(1)),
            makeBlockMeta(hash: "M1",  previousHash: "G",   height: 1, childHashes: ["M2"], work: m, cumulativeWork: UInt256(3)),
            makeBlockMeta(hash: "M2",  previousHash: "M1",  height: 2, work: m, cumulativeWork: UInt256(5)),
            makeBlockMeta(hash: "F1",  previousHash: "G",   height: 1, childHashes: ["F2a", "F2b"], work: w, cumulativeWork: UInt256(2)),
            makeBlockMeta(hash: "F2a", previousHash: "F1",  height: 2, childHashes: ["F3a"], work: w, cumulativeWork: UInt256(3)),
            makeBlockMeta(hash: "F2b", previousHash: "F1",  height: 2, work: w, cumulativeWork: UInt256(3)),
            makeBlockMeta(hash: "F3a", previousHash: "F2a", height: 3, childHashes: ["F4a"], work: w, cumulativeWork: UInt256(4)),
            makeBlockMeta(hash: "F4a", previousHash: "F3a", height: 4, childHashes: ["F5a"], work: w, cumulativeWork: UInt256(5)),
            makeBlockMeta(hash: "F5a", previousHash: "F4a", height: 5, work: w, cumulativeWork: UInt256(6)),
        ]
    }
    private var forkMainSet: Set<String> { Set(["G", "M1", "M2"]) }

    func testGhostDescentDoesNotDowngradeOntoLighterTipWhenHeavierBranchPruned() async {
        let pruned = makeChain(blocks: buildForkDag(), mainChainHashes: forkMainSet)

        // Retention drops the fork interior F3a/F4a/F5a (fork-only heights, so the
        // main tip M2 at height 2 survives). F1's heavy subtree weight was
        // accumulated while they were present and is NOT recomputed by pruning.
        await pruned.pruneBlocksAtIndex(3) // F3a (interior of the heavy branch)
        await pruned.pruneBlocksAtIndex(4) // F4a
        await pruned.pruneBlocksAtIndex(5) // F5a

        let incumbentTip = await pruned.getMainChainTip()
        XCTAssertEqual(incumbentTip, "M2", "main tip survives (fork-only heights pruned)")
        let incumbentWork = (await pruned.getCumulativeWork(forHash: incumbentTip))!

        let f1 = await pruned.getConsensusBlock(hash: "F1")!
        _ = await pruned.checkForReorg(block: f1)
        let tipAfter = await pruned.getMainChainTip()
        let tipAfterWork = (await pruned.getCumulativeWork(forHash: tipAfter))!

        // No-downgrade obligation: an incomplete descent (F3a pruned) must NOT
        // install a tip of lower durable cumulative work than the incumbent.
        XCTAssertGreaterThanOrEqual(tipAfterWork, incumbentWork,
            "fork choice must not regress the tip onto a lighter leaf hidden behind a pruned interior block")
        XCTAssertNotEqual(tipAfter, "F2a",
            "must not descend to the truncated branch's reachable leaf F2a (a downgrade)")
    }

    // Convergence with the never-pruned oracle: with the whole heavy branch
    // present, the same fork-choice entry rides to F5a (the oracle outcome).
    func testConvergesWithOracleWhenHeavyBranchPresent() async {
        let oracle = makeChain(blocks: buildForkDag(), mainChainHashes: forkMainSet)
        let f1 = await oracle.getConsensusBlock(hash: "F1")!
        _ = await oracle.checkForReorg(block: f1)
        let tip = await oracle.getMainChainTip()
        XCTAssertEqual(tip, "F5a",
            "never-pruned oracle rides the heavy branch to its leaf — the outcome the pruned copy must converge to once F3a returns")
    }

    // Liveness twin of the no-downgrade obligation. The guard must refuse ONLY a
    // genuine downgrade — it must NOT deadlock a legitimate, strictly-heavier
    // reorg merely because the descent was incomplete. Here the WINNING branch is
    // fully present and strictly heavier than the incumbent tip, while a *losing*
    // sibling on the winning path is absent (pruned / not-yet-fetched), so GHOST
    // descent reports `complete == false`. The node must still adopt the heavier
    // tip: an incomplete descent whose winning leaf strictly outweighs the
    // incumbent is a real win, not a regression.
    // DAG (own-work in parens):
    //   main:  G -> M1(2) -> M2(2)                          (incumbent tip M2)
    //   fork:  G -> F1(1) -> F2a(1) -> { F3a(1) -> F4a(1) -> F5a(1) ,  F3ghost(absent) }
    // F2a names two children but F3ghost is never indexed (the absent losing
    // sibling), so descending past F2a sets `complete == false`. The visible
    // winner F3a's subtree (F3a+F4a+F5a = 3) dwarfs the missing sibling, so the
    // descent still rides to F5a.
    // Subtree weights: F2a = 1 + 3 = 4; F1 = 1 + 4 = 5 > M1's subtree (M1+M2 = 4),
    // so the fork legitimately wins fork choice.
    // Genesis-relative cumulativeWork: M2 = 1+2+2 = 5; F5a = 1+1+1+1+1 = 5? No —
    // seeded explicitly below so F5a = 6 > M2 = 5 (a STRICT win the guard must honor).
    private func buildLivenessForkDag() -> [BlockMeta] {
        let m = UInt256(2)
        let w = UInt256(1)
        // F3ghost is intentionally absent from this array: F2a references it in
        // childHashes, so the descent past F2a is `complete == false`, yet the
        // present winner branch rides to F5a (cumulativeWork 6 > incumbent M2 = 5).
        return [
            makeBlockMeta(hash: "G",   height: 0, childHashes: ["M1", "F1"], work: w, cumulativeWork: UInt256(1)),
            makeBlockMeta(hash: "M1",  previousHash: "G",   height: 1, childHashes: ["M2"], work: m, cumulativeWork: UInt256(3)),
            makeBlockMeta(hash: "M2",  previousHash: "M1",  height: 2, work: m, cumulativeWork: UInt256(5)),
            makeBlockMeta(hash: "F1",  previousHash: "G",   height: 1, childHashes: ["F2a"], work: w, cumulativeWork: UInt256(2)),
            makeBlockMeta(hash: "F2a", previousHash: "F1",  height: 2, childHashes: ["F3a", "F3ghost"], work: w, cumulativeWork: UInt256(3)),
            makeBlockMeta(hash: "F3a", previousHash: "F2a", height: 3, childHashes: ["F4a"], work: w, cumulativeWork: UInt256(4)),
            makeBlockMeta(hash: "F4a", previousHash: "F3a", height: 4, childHashes: ["F5a"], work: w, cumulativeWork: UInt256(5)),
            makeBlockMeta(hash: "F5a", previousHash: "F4a", height: 5, work: w, cumulativeWork: UInt256(6)),
        ]
    }

    func testIncompleteDescentStillAdoptsStrictlyHeavierFork() async {
        let chain = makeChain(blocks: buildLivenessForkDag(), mainChainHashes: forkMainSet)

        let incumbentTip = await chain.getMainChainTip()
        XCTAssertEqual(incumbentTip, "M2", "incumbent main tip")
        let incumbentWork = (await chain.getCumulativeWork(forHash: incumbentTip))!

        // Drive the REAL fork-choice entry point on the fork base.
        let f1 = await chain.getConsensusBlock(hash: "F1")!
        _ = await chain.checkForReorg(block: f1)

        let tipAfter = await chain.getMainChainTip()
        let tipAfterWork = (await chain.getCumulativeWork(forHash: tipAfter))!

        // Liveness: an incomplete descent (F3ghost absent) whose winning leaf is
        // STRICTLY heavier than the incumbent MUST be adopted — the no-downgrade
        // guard does not block a legitimate strictly-heavier reorg.
        XCTAssertEqual(tipAfter, "F5a",
            "node must reorg to the strictly-heavier present leaf despite the incomplete descent")
        XCTAssertGreaterThan(tipAfterWork, incumbentWork,
            "adopted tip is strictly heavier than the incumbent (no liveness deadlock)")
    }

    // MARK: - CFC-A2: windowed cumulative-work saturation

    // Drive the windowed prefix sum toward UInt256.max via the REAL submitBlock
    // path (target = 1 ⇒ work = UInt256.max per block), then read it back
    // through getCumulativeWork(limit:). A bare `&+` would wrap to a tiny value
    // (max + max = max-1 ... actually 2*max mod 2^256), reporting a spuriously
    // LOW windowed work that could invert a fork comparison. The saturating add
    // clamps to UInt256.max instead.
    func testWindowedCumulativeWorkSaturatesInsteadOfWrapping() async throws {
        let fetcher = f()
        let base = now() - 50_000
        let maxWorkDiff = UInt256(1) // workForTarget(1) == UInt256.max

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec(), timestamp: base, target: maxWorkDiff, fetcher: fetcher
        )
        XCTAssertEqual(workForTarget(maxWorkDiff), UInt256.max, "target 1 ⇒ max work per block")

        let chain = ChainState.fromGenesis(block: genesis)
        // Add a second max-work block: windowed sum = max + max, which wraps a bare &+.
        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: base + 1000,
            target: maxWorkDiff, nextTarget: maxWorkDiff, nonce: 1, fetcher: fetcher
        )
        _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: b1), block: b1
        )

        let windowed = await chain.getCumulativeWork(limit: 10)
        XCTAssertEqual(windowed, UInt256.max,
            "windowed work over two max-work blocks saturates to max, never wraps to a low value")
        // The wrap a bare &+ would produce: UInt256.max &+ UInt256.max.
        let wouldWrap = UInt256.max &+ UInt256.max
        XCTAssertTrue(wouldWrap < UInt256.max,
            "sanity: a bare &+ of two max values wraps below max (the bug this clamp prevents)")
    }

    // MARK: - CFC-A3: corrupted persisted target fails closed

    // A persisted block whose target string is present-but-undecodable is
    // corruption. The restore choke point itself fails closed (throws) so the node
    // reindexes/halts rather than mapping it to UInt256.zero work — the detector is
    // no longer a caller obligation that can be forgotten.
    func testUndecodableDifficultyFailsClosedOnRestore() async {
        let goodDiff = UInt256(1000)
        let g = PersistedBlockMeta(
            blockHash: "G", parentBlockHash: nil, blockHeight: 0,
            parentChainBlocks: [:], childHashes: ["A"], target: goodDiff.toHexString(),
            timestamp: 1, cumulativeWork: nil
        )
        // Present but NOT valid hex — corruption, distinct from a legitimately-nil target.
        let a = PersistedBlockMeta(
            blockHash: "A", parentBlockHash: "G", blockHeight: 1,
            parentChainBlocks: [:], childHashes: [], target: "zzz-not-hex",
            timestamp: 2, cumulativeWork: nil
        )
        let persisted = PersistedChainState(
            chainTip: "A", tipPostStateCID: nil, tipPrevStateCID: nil, tipSpecCID: nil,
            tipTarget: nil, tipNextTarget: nil, tipHeight: 1, tipTimestamp: nil,
            mainChainHashes: ["G", "A"], blocks: [g, a], parentChainMap: [:], missingBlockHashes: []
        )

        // Fail-closed signal the node guard depends on.
        XCTAssertTrue(persisted.hasUndecodableTarget(),
            "present-but-undecodable target is flagged as corruption")

        // The restore choke point itself fails closed: rather than silently mapping
        // the corrupt block's work to zero (understating accumulated work), restore
        // throws so the node reindexes/halts instead of restoring a downgraded tip.
        XCTAssertThrowsError(try ChainState.restore(from: persisted)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptWeightIndex,
                "restore rejects a corrupt snapshot rather than zeroing its work")
        }
    }

    // A legitimately-absent (nil) target is NOT corruption — pre-upgrade /
    // sync-produced blocks omit it and are recomputed window-relative.
    func testNilDifficultyIsNotCorruption() {
        let g = PersistedBlockMeta(
            blockHash: "G", parentBlockHash: nil, blockHeight: 0,
            parentChainBlocks: [:], childHashes: [], target: nil,
            timestamp: 1, cumulativeWork: nil
        )
        let persisted = PersistedChainState(
            chainTip: "G", tipPostStateCID: nil, tipPrevStateCID: nil, tipSpecCID: nil,
            tipTarget: nil, tipNextTarget: nil, tipHeight: 0, tipTimestamp: nil,
            mainChainHashes: ["G"], blocks: [g], parentChainMap: [:], missingBlockHashes: []
        )
        XCTAssertFalse(persisted.hasUndecodableTarget(),
            "a nil target is legitimately absent, not corruption")
    }

    // resetFrom (the live chain-acceptance entry) over a corrupt snapshot fails
    // closed at the choke point itself: it throws BEFORE mutating the live chain,
    // so the running tip is never overwritten with a silently zeroed-weight
    // projection (the no-downgrade obligation, CFC-A1).
    func testResetFromOverCorruptSnapshotFailsClosed() async {
        let goodDiff = UInt256(500)
        let g = PersistedBlockMeta(
            blockHash: "G", parentBlockHash: nil, blockHeight: 0,
            parentChainBlocks: [:], childHashes: [], target: "not-hex",
            timestamp: 1, cumulativeWork: nil
        )
        let persisted = PersistedChainState(
            chainTip: "G", tipPostStateCID: nil, tipPrevStateCID: nil, tipSpecCID: nil,
            tipTarget: nil, tipNextTarget: nil, tipHeight: 0, tipTimestamp: nil,
            mainChainHashes: ["G"], blocks: [g], parentChainMap: [:], missingBlockHashes: []
        )
        XCTAssertTrue(persisted.hasUndecodableTarget())

        //: the pruned-but-retained weight-index entries carry their OWN hex
        // weight fields. A present-but-undecodable value there would otherwise be
        // mapped to zero / a target-derived fallback by `weightIndexEntries(fromPruned:)`,
        // silently understating a pruned branch's retained weight — the same fail-open
        // hazard. Each field is validated; a nil field is legitimately-absent, not corrupt.
        func prunedEntry(target: String? = "1f", cumulativeWork: String? = "ff",
                         subtreeWeight: String? = "ff", workHex: String? = "1f") -> PersistedBlockMeta {
            PersistedBlockMeta(
                blockHash: "P", parentBlockHash: "G", blockHeight: 9,
                parentChainBlocks: [:], childHashes: [], target: target,
                cumulativeWork: cumulativeWork, subtreeWeight: subtreeWeight, workHex: workHex)
        }
        func snapshotWithPruned(_ entry: PersistedBlockMeta) -> PersistedChainState {
            let g = PersistedBlockMeta(
                blockHash: "G", parentBlockHash: nil, blockHeight: 0,
                parentChainBlocks: [:], childHashes: [], target: goodDiff.toHexString(),
                timestamp: 1, cumulativeWork: nil)
            return PersistedChainState(
                chainTip: "G", tipPostStateCID: nil, tipPrevStateCID: nil, tipSpecCID: nil,
                tipTarget: nil, tipNextTarget: nil, tipHeight: 0, tipTimestamp: nil,
                mainChainHashes: ["G"], blocks: [g], prunedWeightIndex: [entry],
                parentChainMap: [:], missingBlockHashes: [])
        }
        // A wholly-valid pruned entry is NOT corruption.
        XCTAssertFalse(snapshotWithPruned(prunedEntry()).hasUndecodableTarget(),
            "a valid pruned-index entry is not flagged")
        // Each present-but-undecodable weight field is flagged.
        XCTAssertTrue(snapshotWithPruned(prunedEntry(target: "zz")).hasUndecodableTarget(),
            "corrupt pruned-entry target is flagged")
        XCTAssertTrue(snapshotWithPruned(prunedEntry(cumulativeWork: "zz")).hasUndecodableTarget(),
            "corrupt pruned-entry cumulativeWork is flagged")
        XCTAssertTrue(snapshotWithPruned(prunedEntry(subtreeWeight: "zz")).hasUndecodableTarget(),
            "corrupt pruned-entry subtreeWeight is flagged")
        XCTAssertTrue(snapshotWithPruned(prunedEntry(workHex: "zz")).hasUndecodableTarget(),
            "corrupt pruned-entry workHex is flagged")
        // Invariant: `cumulativeWork` / `subtreeWeight` are non-recomputable
        // and ALWAYS persisted for a retained pruned entry, so a MISSING (nil) value is
        // a hole, not a legitimate absence — it must fail closed rather than restore as
        // zero and underweight a heavier pruned branch.
        XCTAssertTrue(snapshotWithPruned(prunedEntry(cumulativeWork: nil)).hasUndecodableTarget(),
            "a nil pruned-entry cumulativeWork is a hole, flagged")
        XCTAssertTrue(snapshotWithPruned(prunedEntry(subtreeWeight: nil)).hasUndecodableTarget(),
            "a nil pruned-entry subtreeWeight is a hole, flagged")
        // Wave-4 (pre-testnet, no legacy snapshots): `workHex` is ALWAYS persisted
        // for a retained pruned entry, so a missing value is a hole — failing open
        // to the target-derived `workForTarget(target)` would re-open the lossy
        // double-division determinism hazard closed. Fail closed.
        XCTAssertTrue(snapshotWithPruned(prunedEntry(workHex: nil)).hasUndecodableTarget(),
            "a nil pruned-entry workHex is a hole, flagged")
        // `target` may legitimately be nil (persist() omits it for zero work).
        XCTAssertFalse(snapshotWithPruned(prunedEntry(target: nil)).hasUndecodableTarget(),
            "a nil pruned-entry target is absent, not corruption")

        // A throwaway genesis chain we then resetFrom the corrupt snapshot.
        let fetcher = f()
        let realGenesis = try? await BlockBuilder.buildGenesis(
            spec: spec(), timestamp: now() - 10_000, target: goodDiff, fetcher: fetcher
        )
        guard let realGenesis else { return XCTFail("genesis build failed") }
        let chain = ChainState.fromGenesis(block: realGenesis)
        let genesisTip = await chain.getMainChainTip()
        // resetFrom over a corrupt snapshot fails closed BEFORE mutating the live
        // chain: it throws rather than overwriting the running tip with a silently
        // zeroed-weight projection (the no-downgrade obligation, CFC-A1).
        do {
            try await chain.resetFrom(persisted)
            XCTFail("resetFrom must reject a corrupt snapshot rather than zeroing the live tip")
        } catch {
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptWeightIndex,
                "resetFrom rejects a corrupt snapshot with the typed corruption error")
        }
        let tipAfter = await chain.getMainChainTip()
        XCTAssertEqual(tipAfter, genesisTip,
            "the live chain tip is unchanged after a rejected resetFrom (fail closed, no downgrade)")
    }
}
