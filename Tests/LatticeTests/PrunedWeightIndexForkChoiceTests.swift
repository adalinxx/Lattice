import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

// / CFC-A1 LIVENESS half): the fork-choice weight/linkage index
// must be retained INDEPENDENTLY of the prunable block-body store, so most-work
// fork choice always has COMPLETE weight info even after body pruning — the
// Bitcoin Core `-prune` model (deletes block bodies/undo files but NEVER the
// `CBlockIndex`/`nChainWork` tree, so `pindexBestHeader` is always correct).
//
// This is DISTINCT from CFC-A1's "hold and don't downgrade" obligation
// (ConsensusForkChoiceBucketATests): there the node fails SAFE behind a hole it
// CANNOT weigh. Here the heavier subtree's BODIES are pruned but its weight +
// linkage SURVIVE in the index, so the node POSITIVELY COMPUTES the heavier
// subtree as heaviest — the weight is known from the index, not body presence.
//
// Entry points are the REAL fork-choice paths (heaviestDescent / checkForReorg
// via the GHOST descent / pruneBlocksAtIndex), never private helpers.

final class PrunedWeightIndexForkChoiceTests: XCTestCase {

    // DAG (own-work in parens), heights:
    //   main:  G(1) ->h1 M1(2) ->h2 M2(2)                  (incumbent tip M2)
    //   fork:  G(1) ->h1 F1(1) ->h2 F2(1) ->h3 F3(1) ->h4 F4(1) ->h5 F5(1)
    // Genesis-relative cumulativeWork: M2 = 1+2+2 = 5; F5 = 1+1+1+1+1+1 = 6 > 5.
    // Subtree weights: F1 = F1+F2+F3+F4+F5 = 5 > M1's subtree (M1+M2 = 4), so the
    // fork legitimately and STRICTLY wins fork choice — its heaviest leaf is F5.
    private func buildHeavyForkDag() -> [BlockMeta] {
        let m = UInt256(2)
        let w = UInt256(1)
        return [
            makeBlockMeta(hash: "G",  height: 0, childHashes: ["M1", "F1"], work: w, cumulativeWork: UInt256(1)),
            makeBlockMeta(hash: "M1", previousHash: "G",  height: 1, childHashes: ["M2"], work: m, cumulativeWork: UInt256(3)),
            makeBlockMeta(hash: "M2", previousHash: "M1", height: 2, work: m, cumulativeWork: UInt256(5)),
            makeBlockMeta(hash: "F1", previousHash: "G",  height: 1, childHashes: ["F2"], work: w, cumulativeWork: UInt256(2)),
            makeBlockMeta(hash: "F2", previousHash: "F1", height: 2, childHashes: ["F3"], work: w, cumulativeWork: UInt256(3)),
            makeBlockMeta(hash: "F3", previousHash: "F2", height: 3, childHashes: ["F4"], work: w, cumulativeWork: UInt256(4)),
            makeBlockMeta(hash: "F4", previousHash: "F3", height: 4, childHashes: ["F5"], work: w, cumulativeWork: UInt256(5)),
            makeBlockMeta(hash: "F5", previousHash: "F4", height: 5, work: w, cumulativeWork: UInt256(6)),
        ]
    }
    private var mainSet: Set<String> { Set(["G", "M1", "M2"]) }

    // CORE assertion: with the heavier fork's INTERIOR AND TIP bodies pruned
    // (heights 3..5 are fork-only, so the main tip M2 at height 2 survives), the
    // node still IDENTIFIES F5 as the heaviest leaf and KNOWS its weight (6) —
    // computed from the retained index, not from body presence. This is exactly
    // what the never-pruned oracle reports, despite the missing bodies.
    func testHeaviestSubtreeIdentifiedFromIndexDespitePrunedBodies() async {
        let oracle = makeChain(blocks: buildHeavyForkDag(), mainChainHashes: mainSet)
        let oracleHeaviest = (await oracle.heaviestDescent(fromHash: "F1"))!
        XCTAssertEqual(oracleHeaviest.tipHash, "F5", "oracle: heaviest leaf below F1 is F5")
        XCTAssertEqual(oracleHeaviest.cumulativeWork, UInt256(6), "oracle: F5 cumulative work is 6")

        let pruned = makeChain(blocks: buildHeavyForkDag(), mainChainHashes: mainSet)
        await pruned.pruneBlocksAtIndex(3) // F3 body
        await pruned.pruneBlocksAtIndex(4) // F4 body
        await pruned.pruneBlocksAtIndex(5) // F5 body — the heavy TIP's body is gone

        // Bodies are genuinely gone from the prunable store.
        let f5Body = await pruned.getConsensusBlock(hash: "F5")
        let f3Body = await pruned.getConsensusBlock(hash: "F3")
        XCTAssertNil(f5Body, "heavy tip body pruned")
        XCTAssertNil(f3Body, "heavy interior body pruned")

        // THE deliverable: fork choice computes the same heaviest leaf + weight from
        // the retained index, with the bodies gone.
        let prunedHeaviest = (await pruned.heaviestDescent(fromHash: "F1"))!
        XCTAssertEqual(prunedHeaviest.tipHash, "F5",
            "node identifies the heaviest leaf F5 from the retained weight index, despite pruned bodies")
        XCTAssertEqual(prunedHeaviest.cumulativeWork, UInt256(6),
            "node knows F5's durable cumulative work (6) from the index, not from the (pruned) body")
        XCTAssertEqual(prunedHeaviest.tipHash, oracleHeaviest.tipHash,
            "pruned copy converges to the never-pruned oracle's heaviest leaf")
        XCTAssertEqual(prunedHeaviest.cumulativeWork, oracleHeaviest.cumulativeWork,
            "pruned copy converges to the never-pruned oracle's heaviest weight")

        // And the durable weight of a body-pruned block is itself queryable.
        let f5DurableWork = await pruned.getCumulativeWork(forHash: "F5")
        XCTAssertEqual(f5DurableWork, UInt256(6),
            "body-pruned F5's durable cumulative work is retained and queryable")
    }

    // Pruning a body must NEVER hole the weight index: F1's subtree-weight stays
    // exactly as it was with the now-pruned descendants present.
    func testPruningDoesNotHoleTheWeightIndex() async {
        let oracle = makeChain(blocks: buildHeavyForkDag(), mainChainHashes: mainSet)
        let oracleF1Subtree = (await oracle.subtreeWeight(forHash: "F1"))!

        let pruned = makeChain(blocks: buildHeavyForkDag(), mainChainHashes: mainSet)
        await pruned.pruneBlocksAtIndex(3)
        await pruned.pruneBlocksAtIndex(4)
        await pruned.pruneBlocksAtIndex(5)

        let prunedF1Subtree = (await pruned.subtreeWeight(forHash: "F1"))!
        XCTAssertEqual(prunedF1Subtree, oracleF1Subtree,
            "pruning descendant bodies does not change the retained subtree weight")
        XCTAssertEqual(prunedF1Subtree, UInt256(5),
            "F1 subtree = F1+F2+F3+F4+F5 = 5, retained across body pruning")

        // The pruned leaf's own retained subtree weight is still queryable.
        let f5Subtree = await pruned.subtreeWeight(forHash: "F5")
        XCTAssertEqual(f5Subtree, UInt256(1),
            "body-pruned F5's retained subtree weight (its own work) survives")
    }

    // No-downgrade preserved (CFC-A1, not regressed): the node KNOWS F5 is heaviest,
    // but it must NOT install a tip whose body it does not hold and whose durable
    // work is LOWER than the incumbent. The body-present prefix of the heavy path
    // tops out at F2 (cumWork 3 < M2's 5), so the real fork-choice entry must HOLD
    // the incumbent M2 — not downgrade onto a body-present-but-lighter F2. Bodies
    // arrive via the backfill transport follow-up 2/2), after which a
    // re-run advances the tip the rest of the way.
    func testKnowsHeavierBranchYetDoesNotDowngradeOntoBodyPresentLighterTip() async {
        let chain = makeChain(blocks: buildHeavyForkDag(), mainChainHashes: mainSet)
        await chain.pruneBlocksAtIndex(3)
        await chain.pruneBlocksAtIndex(4)
        await chain.pruneBlocksAtIndex(5)

        let incumbentTip = await chain.getMainChainTip()
        XCTAssertEqual(incumbentTip, "M2")
        let incumbentWork = (await chain.getCumulativeWork(forHash: incumbentTip))!

        // REAL fork-choice entry point on the fork base.
        let f1 = await chain.getConsensusBlock(hash: "F1")!
        _ = await chain.checkForReorg(block: f1)

        let tipAfter = await chain.getMainChainTip()
        let tipAfterWork = (await chain.getCumulativeWork(forHash: tipAfter))!
        XCTAssertGreaterThanOrEqual(tipAfterWork, incumbentWork,
            "no-downgrade preserved: must not install a tip of lower durable work than the incumbent")
        XCTAssertNotEqual(tipAfter, "F2",
            "must not downgrade onto the body-present-but-lighter prefix F2 (cumWork 3 < 5)")
    }

    // finding #1 (the FETCH-TRIGGER metric): a branch made strictly heavier
    // PURELY by inherited parent weight — but whose genesis-relative prefix cumulative
    // work only TIES/LOSES the incumbent — must STILL trigger body backfill. The
    // trigger has to compare the same effective fork-choice metric (`trueCumWork =
    // subtreeWeight + inherited`) GHOST/inherited-weight selection uses, NOT the prefix
    // cumulative-work shortcut. A prefix-only comparison returns nil here and the node
    // never refetches the heavier branch.
    //
    // DAG: main G(1) -> M1(1) -> M2(1) -> M3(1)  (incumbent tip M3, prefix cum 4)
    //      fork G(1) -> F1(1) -> F2(1)           (fork tip F2, prefix cum 3 < 4)
    // subtreeWeight: F1 = F1+F2 = 2, M1 = M1+M2+M3 = 3. Without inheritance the fork is
    // LIGHTER. We install inherited weight 5 on F1, so effective(F1) = 2+5 = 7 strictly
    // beats effective(M1) = 3 — the fork wins fork choice by inheritance alone, while
    // its prefix cum work (3) does NOT exceed the incumbent's (4). F2's body is pruned,
    // so the heavier branch is a HOLD that must be backfilled.
    func testInheritedHeavierForkWithLighterPrefixTriggersBackfill() async {
        let w = UInt256(1)
        let blocks: [BlockMeta] = [
            makeBlockMeta(hash: "G",  height: 0, childHashes: ["M1", "F1"], work: w, cumulativeWork: UInt256(1)),
            makeBlockMeta(hash: "M1", previousHash: "G",  height: 1, childHashes: ["M2"], work: w, cumulativeWork: UInt256(2)),
            makeBlockMeta(hash: "M2", previousHash: "M1", height: 2, childHashes: ["M3"], work: w, cumulativeWork: UInt256(3)),
            makeBlockMeta(hash: "M3", previousHash: "M2", height: 3, work: w, cumulativeWork: UInt256(4)),
            makeBlockMeta(hash: "F1", previousHash: "G",  height: 1, childHashes: ["F2"], work: w, cumulativeWork: UInt256(2)),
            makeBlockMeta(hash: "F2", previousHash: "F1", height: 2, work: w, cumulativeWork: UInt256(3)),
        ]
        let mainHashes: Set<String> = ["G", "M1", "M2", "M3"]

        // Sanity (no inheritance): the fork is LIGHTER by prefix cum work AND by
        // effective weight, so there is nothing to backfill.
        let noInherit = makeChain(blocks: blocks, mainChainHashes: mainHashes)
        await noInherit.pruneBlocksAtIndex(2) // F2 body (the only height-2 fork-only block)
        let noTarget = await noInherit.heldHeavierBackfillTarget()
        XCTAssertNil(noTarget, "no inheritance: lighter fork is not a backfill target")

        // With inheritance on F1: the fork is heavier by effective weight ONLY (prefix
        // cum work still loses). The OLD prefix-only trigger returns nil here; the
        // effective-weight trigger correctly reports F2 as the held heavier target.
        let chain = makeChain(
            blocks: blocks, mainChainHashes: mainHashes,
            inheritedWeights: ["F1": UInt256(5)]
        )
        await chain.pruneBlocksAtIndex(2) // prune F2 body → the heavy branch is a HOLD

        let incumbentTip = await chain.getMainChainTip()
        XCTAssertEqual(incumbentTip, "M3", "incumbent tip is M3 (prefix cum 4)")
        // Prefix cum work does NOT favor the fork: F2 (3) <= M3 (4).
        let f2Prefix = (await chain.getCumulativeWork(forHash: "F2"))!
        let incumbentPrefix = (await chain.getCumulativeWork(forHash: "M3"))!
        XCTAssertLessThanOrEqual(f2Prefix, incumbentPrefix,
            "fork tip's genesis-relative prefix work does NOT exceed the incumbent's")

        // THE finding: the effective-weight trigger fires anyway and points at F2.
        let target = await chain.heldHeavierBackfillTarget()
        XCTAssertNotNil(target, "inherited-heavier fork triggers backfill despite lighter prefix work")
        XCTAssertEqual(target?.tipHash, "F2", "the held heavier leaf is F2")
        XCTAssertEqual(target?.missingBodies, ["F2"], "F2's pruned body is the refetch target")
    }

    // PERSISTENCE/RESTORE (the lifecycle finding): the retained weight index
    // must survive a node RESTART. We prune the heavier fork's interior+tip bodies,
    // round-trip the chain through `persist()` -> `restore()` (exactly the restart
    // path), and assert the RESTORED ChainState — which never saw the pruned bodies —
    // still identifies F5 as the heaviest leaf and knows its durable cumulative work
    // (6) and retained subtree weight from the index alone. Without persisting the
    // pruned-but-retained index entries, restore would re-derive the index from live
    // bodies only and silently LOSE F5's weight/linkage, holing fork choice.
    func testRetainedWeightIndexSurvivesPersistRestore() async throws {
        let pruned = makeChain(blocks: buildHeavyForkDag(), mainChainHashes: mainSet)
        await pruned.pruneBlocksAtIndex(3) // F3 body
        await pruned.pruneBlocksAtIndex(4) // F4 body
        await pruned.pruneBlocksAtIndex(5) // F5 body — heavy TIP body gone

        // Round-trip through persistence: the durable on-disk projection of restart.
        let persisted = await pruned.persist()
        let restored = try ChainState.restore(from: persisted)

        // The restored node never installed the pruned bodies.
        let f5Body = await restored.getConsensusBlock(hash: "F5")
        let f3Body = await restored.getConsensusBlock(hash: "F3")
        XCTAssertNil(f5Body, "restored: heavy tip body absent (was pruned before persist)")
        XCTAssertNil(f3Body, "restored: heavy interior body absent (was pruned before persist)")

        // THE finding: the restored ChainState still computes the heaviest subtree and
        // its cumulative work from the retained (persisted) index.
        let heaviest = (await restored.heaviestDescent(fromHash: "F1"))!
        XCTAssertEqual(heaviest.tipHash, "F5",
            "restored node identifies the heaviest leaf F5 from the persisted weight index")
        XCTAssertEqual(heaviest.cumulativeWork, UInt256(6),
            "restored node knows F5's durable cumulative work (6) from the persisted index")

        // The retained subtree weight survives the restart unchanged.
        let f1Subtree = (await restored.subtreeWeight(forHash: "F1"))!
        XCTAssertEqual(f1Subtree, UInt256(5),
            "restored F1 subtree weight (F1+F2+F3+F4+F5 = 5) recovered from the persisted index")
        let f5DurableWork = await restored.getCumulativeWork(forHash: "F5")
        XCTAssertEqual(f5DurableWork, UInt256(6),
            "restored body-pruned F5's durable cumulative work is retained and queryable")
    }

    // Same lifecycle assertion through the in-place restart path `resetFrom`, which
    // rebuilds the index over a freshly-installed tree. The pruned entries must be
    // re-seeded from the persisted projection, not derived from live bodies alone.
    func testRetainedWeightIndexSurvivesResetFrom() async throws {
        let pruned = makeChain(blocks: buildHeavyForkDag(), mainChainHashes: mainSet)
        await pruned.pruneBlocksAtIndex(3)
        await pruned.pruneBlocksAtIndex(4)
        await pruned.pruneBlocksAtIndex(5)
        let persisted = await pruned.persist()

        // A distinct chain reset onto the persisted state (the resetFrom restart path).
        let target = makeChain(blocks: buildHeavyForkDag(), mainChainHashes: mainSet)
        try await target.resetFrom(persisted)

        let f5Body = await target.getConsensusBlock(hash: "F5")
        XCTAssertNil(f5Body,
            "resetFrom: heavy tip body absent (pruned in the persisted state)")
        let heaviest = (await target.heaviestDescent(fromHash: "F1"))!
        XCTAssertEqual(heaviest.tipHash, "F5",
            "resetFrom node identifies the heaviest leaf F5 from the persisted weight index")
        XCTAssertEqual(heaviest.cumulativeWork, UInt256(6),
            "resetFrom node knows F5's durable cumulative work (6) from the persisted index")
        let f1Subtree = (await target.subtreeWeight(forHash: "F1"))!
        XCTAssertEqual(f1Subtree, UInt256(5),
            "resetFrom F1 subtree weight (5) recovered from the persisted index")
    }

    // (fail closed on restore — THE finding): a persisted snapshot whose
    // pruned-but-retained weight-index entry has a MISSING or UNDECODABLE
    // non-recomputable weight field (`cumulativeWork` / `subtreeWeight`) must be
    // REJECTED by the restore choke point, not silently restored with that field
    // defaulted to `.zero`. A zero-weight entry holes the fork-choice index: the
    // heavier pruned branch looks weightless, a silent downgrade. Missing weight ≠
    // "zero", it = "this index is incomplete" → reindex/halt, never silent zero.
    func testRestoreFailsClosedOnMissingOrUndecodablePrunedWeight() async throws {
        // A valid main chain (G -> M1 -> M2) plus ONE pruned-index entry whose
        // durable weight is holed. We vary only the holed field.
        func snapshot(prunedCumWork: String?, prunedSubtreeWeight: String?) -> PersistedChainState {
            let g = PersistedBlockMeta(
                blockHash: "G", parentBlockHash: nil, blockHeight: 0,
                parentChainBlocks: [:], childHashes: ["M1", "F1"],
                target: UInt256(1).toHexString(), timestamp: 1,
                cumulativeWork: UInt256(1).toHexString())
            let m1 = PersistedBlockMeta(
                blockHash: "M1", parentBlockHash: "G", blockHeight: 1,
                parentChainBlocks: [:], childHashes: [],
                target: UInt256(1).toHexString(), timestamp: 2,
                cumulativeWork: UInt256(2).toHexString())
            // A body-pruned heavier-branch entry whose retained weight is holed.
            let prunedF = PersistedBlockMeta(
                blockHash: "F1", parentBlockHash: "G", blockHeight: 1,
                parentChainBlocks: [:], childHashes: [],
                target: UInt256(1).toHexString(),
                cumulativeWork: prunedCumWork, subtreeWeight: prunedSubtreeWeight,
                workHex: UInt256(1).toHexString())
            return PersistedChainState(
                chainTip: "M1", tipPostStateCID: nil, tipPrevStateCID: nil, tipSpecCID: nil,
                tipTarget: nil, tipNextTarget: nil, tipHeight: 1, tipTimestamp: nil,
                mainChainHashes: ["G", "M1"], blocks: [g, m1], prunedWeightIndex: [prunedF],
                parentChainMap: [:], missingBlockHashes: [])
        }

        // Missing (nil) cumulativeWork — the hole the body-pruned entry exists to fill.
        let missingCum = snapshot(prunedCumWork: nil, prunedSubtreeWeight: UInt256(1).toHexString())
        XCTAssertThrowsError(try ChainState.restore(from: missingCum)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptWeightIndex,
                "restore rejects a pruned entry with missing cumulativeWork, not silent-zero")
        }
        // Undecodable cumulativeWork.
        let badCum = snapshot(prunedCumWork: "zzz", prunedSubtreeWeight: UInt256(1).toHexString())
        XCTAssertThrowsError(try ChainState.restore(from: badCum)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptWeightIndex,
                "restore rejects a pruned entry with undecodable cumulativeWork")
        }
        // Missing (nil) subtreeWeight.
        let missingSub = snapshot(prunedCumWork: UInt256(1).toHexString(), prunedSubtreeWeight: nil)
        XCTAssertThrowsError(try ChainState.restore(from: missingSub)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptWeightIndex,
                "restore rejects a pruned entry with missing subtreeWeight, not silent-zero")
        }
        // Undecodable subtreeWeight.
        let badSub = snapshot(prunedCumWork: UInt256(1).toHexString(), prunedSubtreeWeight: "zzz")
        XCTAssertThrowsError(try ChainState.restore(from: badSub)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptWeightIndex,
                "restore rejects a pruned entry with undecodable subtreeWeight")
        }

        // GREEN control: a wholly-valid pruned entry restores successfully (the fix
        // rejects ONLY holes, never legitimate data).
        let good = snapshot(prunedCumWork: UInt256(9).toHexString(),
                            prunedSubtreeWeight: UInt256(9).toHexString())
        let restored = try ChainState.restore(from: good)
        let f1Work = await restored.getCumulativeWork(forHash: "F1")
        XCTAssertEqual(f1Work, UInt256(9),
            "valid pruned entry restores its retained cumulative work, not zero")
    }

    // (fail closed at the CANONICAL choke point — direct init): the public
    // `ChainState.init(...prunedWeightIndex:...)` is itself a construction path. A
    // caller building `ChainState` directly with a corrupt pruned weight index (one
    // that never passes through `restore`/`resetFrom` and so never hits the early
    // `hasUndecodableTarget()` guard) must STILL fail closed — `init` is throwing and
    // its `weightIndexEntries(fromPruned:)` choke point rejects a missing/undecodable
    // required weight rather than seeding it as `.zero` (which would hole fork choice).
    func testDirectInitFailsClosedOnCorruptPrunedWeight() throws {
        // Minimal live tree G -> M1 (no pruned descendants live here); the corruption
        // lives entirely in the pruned-index projection we pass to init.
        let live: [String: BlockMeta] = [
            "G":  makeBlockMeta(hash: "G",  height: 0, childHashes: ["M1"], cumulativeWork: UInt256(1)),
            "M1": makeBlockMeta(hash: "M1", previousHash: "G", height: 1, cumulativeWork: UInt256(2)),
        ]
        let indexMap: [UInt64: Set<String>] = [0: ["G"], 1: ["M1"]]

        func prunedEntry(cumWork: String?, subtreeWeight: String?) -> PersistedBlockMeta {
            PersistedBlockMeta(
                blockHash: "F1", parentBlockHash: "G", blockHeight: 1,
                parentChainBlocks: [:], childHashes: [],
                target: UInt256(1).toHexString(),
                cumulativeWork: cumWork, subtreeWeight: subtreeWeight,
                workHex: UInt256(1).toHexString())
        }

        func makeDirect(_ pruned: PersistedBlockMeta) throws -> ChainState {
            try ChainState(
                chainTip: "M1",
                mainChainHashes: Set(["G", "M1"]),
                indexToBlockHash: indexMap,
                hashToBlock: live,
                parentChainBlockHashToBlockHash: [:],
                prunedWeightIndex: [pruned])
        }

        // Each holed required weight must make the DIRECT init throw — not silent-zero.
        let cases: [(PersistedBlockMeta, String)] = [
            (prunedEntry(cumWork: nil, subtreeWeight: UInt256(1).toHexString()),
                "missing cumulativeWork"),
            (prunedEntry(cumWork: "zzz", subtreeWeight: UInt256(1).toHexString()),
                "undecodable cumulativeWork"),
            (prunedEntry(cumWork: UInt256(1).toHexString(), subtreeWeight: nil),
                "missing subtreeWeight"),
            (prunedEntry(cumWork: UInt256(1).toHexString(), subtreeWeight: "zzz"),
                "undecodable subtreeWeight"),
        ]
        for (entry, label) in cases {
            XCTAssertThrowsError(try makeDirect(entry)) { error in
                XCTAssertEqual(error as? ChainStateRestoreError, .corruptWeightIndex,
                    "direct ChainState.init rejects \(label), not silent-zero")
            }
        }

        // GREEN control: a wholly-valid pruned entry constructs via the direct init and
        // its retained weight is seeded into the index (the fix rejects ONLY holes).
        let good = try makeDirect(prunedEntry(
            cumWork: UInt256(9).toHexString(), subtreeWeight: UInt256(9).toHexString()))
        XCTAssertNotNil(good, "valid pruned entry constructs via direct init")
    }

    //: a pruned entry's own `work` must roundtrip EXACTLY through the
    // persisted projection. Pre-fix the work was serialized only as `target = MAX/work`
    // and restored as `MAX/target`, a lossy double division. `workHex` carries the
    // exact value. The direct `weightIndexEntries` helper still tolerates a nil
    // `workHex` (target-derived fallback) for direct `ChainState.init` callers, but
    // a SNAPSHOT carrying such an entry now fails closed at the restore choke point
    // (wave-4; see PersistWorkRoundTripTests.testRestoreFailsClosedOnMissingPrunedWorkHex).
    func testPrunedEntryWorkRoundtripsExactly() throws {
        // A large work whose target (MAX/work) quantizes: MAX/(MAX/work) != work,
        // exercising the old lossy double-division path.
        let exactWork = UInt256.max / UInt256(3) + UInt256(1)
        let lossyWork = workForTarget(UInt256.max / exactWork)
        XCTAssertNotEqual(lossyWork, exactWork,
            "precondition: target-derived roundtrip of this work is lossy")

        let target = (UInt256.max / exactWork).toHexString()
        let withWorkHex = PersistedBlockMeta(
            blockHash: "P", parentBlockHash: "G", blockHeight: 1,
            parentChainBlocks: [:], childHashes: [],
            target: target, cumulativeWork: UInt256(9).toHexString(),
            subtreeWeight: UInt256(9).toHexString(), workHex: exactWork.toHexString())
        let restored = try weightIndexEntries(fromPruned: [withWorkHex])
        XCTAssertEqual(restored["P"]?.work, exactWork,
            "restored pruned entry recovers exact own work from workHex")

        // Pre-upgrade entry omits workHex: falls back to the target-derived work.
        let preUpgrade = PersistedBlockMeta(
            blockHash: "Q", parentBlockHash: "G", blockHeight: 1,
            parentChainBlocks: [:], childHashes: [],
            target: target, cumulativeWork: UInt256(9).toHexString(),
            subtreeWeight: UInt256(9).toHexString())
        let restoredPre = try weightIndexEntries(fromPruned: [preUpgrade])
        XCTAssertEqual(restoredPre["Q"]?.work, lossyWork,
            "pre-upgrade pruned entry (no workHex) falls back to target-derived work")
    }

    // Liveness twin: when the heaviest branch's bodies ARE present, the node fully
    // installs the heavier tip (no spurious hold). Same DAG, no pruning.
    func testFullyAdoptsHeavierForkWhenBodiesPresent() async {
        let chain = makeChain(blocks: buildHeavyForkDag(), mainChainHashes: mainSet)
        let f1 = await chain.getConsensusBlock(hash: "F1")!
        _ = await chain.checkForReorg(block: f1)
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "F5",
            "with bodies present the node installs the strictly-heavier tip F5")
    }

    // MARK: - Real-insert regressions (BlockBuilder-driven)

    private func bf() -> StorableFetcher { StorableFetcher() }
    private func bspec() -> ChainSpec {
        ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
                  maxBlockSize: 1_000_000, premine: 0, targetBlockTime: 1_000,
                  initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
    }
    private func bnow() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func bcid(_ b: Block) -> String { try! VolumeImpl<Block>(node: b).rawCID }

    // finding 1: incremental subtree recompute (`propagateSubtreeWeight`)
    // must fold in a child's RETAINED weight, not just the live-store view. We prune
    // a descendant tail under a still-live ancestor B, then insert a NEW sibling
    // child under B — which recomputes B from its children. If the recompute summed
    // `hashToBlock` only, the pruned tail would vanish from B's subtree weight and be
    // written back underweight via `syncWeightIndexEntry`. B must still count it.
    func testInsertUnderLiveAncestorRetainsPrunedSiblingWeight() async throws {
        let fetcher = bf()
        let diff = UInt256(1000)
        let w = workForTarget(diff)
        let base = bnow() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(spec: bspec(), timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        // Linear G(h0) -> A(h1) -> B(h2) -> C(h3) -> D(h4) -> E(h5) -> F(h6, tip).
        // C/D are INTERIOR so the main tip F stays live across pruning.
        let a = try await BlockBuilder.buildBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        let b = try await BlockBuilder.buildBlock(previous: a, timestamp: base + 2000, target: diff, nonce: 2, fetcher: fetcher)
        let c = try await BlockBuilder.buildBlock(previous: b, timestamp: base + 3000, target: diff, nonce: 3, fetcher: fetcher)
        let d = try await BlockBuilder.buildBlock(previous: c, timestamp: base + 4000, target: diff, nonce: 4, fetcher: fetcher)
        let e = try await BlockBuilder.buildBlock(previous: d, timestamp: base + 5000, target: diff, nonce: 5, fetcher: fetcher)
        let fb = try await BlockBuilder.buildBlock(previous: e, timestamp: base + 6000, target: diff, nonce: 6, fetcher: fetcher)
        for blk in [a, b, c, d, e, fb] {
            _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: blk), block: blk)
        }
        // B's subtree before pruning = {B,C,D,E,F} = 5w.
        let swBBefore = await chain.subtreeWeight(forHash: bcid(b))
        XCTAssertEqual(swBBefore, w &+ w &+ w &+ w &+ w, "precondition: B subtree = B..F = 5w")

        // Prune the interior C(h3) and D(h4): their weights now live ONLY in the
        // retained index; B stays live with childHashes still listing C.
        await chain.pruneBlocksAtIndex(3) // C body
        await chain.pruneBlocksAtIndex(4) // D body
        let cBody = await chain.getConsensusBlock(hash: bcid(c))
        let dBody = await chain.getConsensusBlock(hash: bcid(d))
        XCTAssertNil(cBody, "C body pruned")
        XCTAssertNil(dBody, "D body pruned")

        // Insert a NEW sibling child C2(h3) under the still-live B. This drives the
        // incremental recompute of B from its children {C (pruned), C2 (live)}.
        let c2 = try await BlockBuilder.buildBlock(previous: b, timestamp: base + 3500, target: diff, nonce: 99, fetcher: fetcher)
        _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: c2), block: c2)

        // B's subtree must still count the pruned tail: {B, C, D, E, F, C2} = 6w.
        // Pre-fix it would drop the pruned C->D->E->F chain and report 2w (B + C2).
        let swBAfter = await chain.subtreeWeight(forHash: bcid(b))
        XCTAssertEqual(swBAfter, w &+ w &+ w &+ w &+ w &+ w,
            "B subtree retains the pruned interior C,D (and live E,F) after inserting sibling C2: 6w")
    }

    // finding 2: re-submitting (rehydrating) a body-pruned block must NOT
    // overwrite its retained linkage/weight with a body-store-only view. `findChildren`
    // only sees live children, so backfilling C would drop its pruned descendant tail
    // D from the retained entry. The rehydrated entry must merge the retained children.
    func testRehydratingPrunedBlockKeepsRetainedChildren() async throws {
        let fetcher = bf()
        let diff = UInt256(1000)
        let w = workForTarget(diff)
        let base = bnow() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(spec: bspec(), timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        // Linear G -> A -> B -> C(h3) -> D(h4) -> E(h5, tip). C/D interior so the
        // main tip E stays live across pruning.
        let a = try await BlockBuilder.buildBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        let b = try await BlockBuilder.buildBlock(previous: a, timestamp: base + 2000, target: diff, nonce: 2, fetcher: fetcher)
        let c = try await BlockBuilder.buildBlock(previous: b, timestamp: base + 3000, target: diff, nonce: 3, fetcher: fetcher)
        let d = try await BlockBuilder.buildBlock(previous: c, timestamp: base + 4000, target: diff, nonce: 4, fetcher: fetcher)
        let e = try await BlockBuilder.buildBlock(previous: d, timestamp: base + 5000, target: diff, nonce: 5, fetcher: fetcher)
        for blk in [a, b, c, d, e] {
            _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: blk), block: blk)
        }
        // Prune C(h3) and D(h4) bodies; C's retained entry lists child D.
        await chain.pruneBlocksAtIndex(3)
        await chain.pruneBlocksAtIndex(4)
        let cBody = await chain.getConsensusBlock(hash: bcid(c))
        XCTAssertNil(cBody, "C body pruned")

        // Re-submit (backfill) C's body. findChildren(C) sees no live children (D is
        // pruned), so a body-store-only rebuild would lose D from C's linkage/weight.
        _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: c), block: c)

        // C's subtree must still include the pruned tail D (and live E): {C,D,E} = 3w.
        // Pre-fix the rehydrated entry would lose D and report 1w (C alone, no live child).
        let swC = await chain.subtreeWeight(forHash: bcid(c))
        XCTAssertEqual(swC, w &+ w &+ w,
            "rehydrated C keeps retained child D: subtree = C,D,E = 3w")
        // And B's subtree is unchanged end-to-end: {B, C, D, E} = 4w.
        let swB = await chain.subtreeWeight(forHash: bcid(b))
        XCTAssertEqual(swB, w &+ w &+ w &+ w,
            "B subtree intact after C rehydration: B,C,D,E = 4w")
    }
}
