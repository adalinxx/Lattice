import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

//: the fork-choice metric (`subtreeWeight` / `effectiveWeight`) is built
// from each block's own `work`. Historically a LIVE block's work was round-tripped
// through `target` with truncating integer divisions on persist->restore:
//
//   live:    work  = workForTarget(target)            = MAX / target     (one floor-div)
//   persist: target' = MAX / work                                         (second floor-div)
//   restore: work' = workForTarget(target')           = MAX / target'    (third floor-div)
//
// so work' >= work and is NOT guaranteed equal — fork-choice weight then depends on
// a node's RESTART history (a determinism split with no attacker). These tests pin
// that the work used in fork choice is BYTE-IDENTICAL before and after a restart.
// The oracle is the never-persisted in-memory chain. RED on pre-fix code, GREEN after.
final class PersistWorkRoundTripTests: XCTestCase {

    // Work values whose target-derived round-trip is LOSSY:
    // workForTarget(MAX / work) != work. These are the adversarial picks where
    // MAX % work != 0 (the floor-divisions do not cancel). Built to span the valid
    // range: near the minimum, mid-range odd factors, and near UInt256.max.
    private func adversarialWorks() -> [UInt256] {
        return [
            UInt256.max / UInt256(3) + UInt256(1),   // large, MAX % work != 0
            UInt256.max / UInt256(7) + UInt256(5),   // large, different residue
            UInt256(3),                              // near the minimum
            UInt256(5),
            UInt256(0x1_0000_0000) + UInt256(7),     // mid-range odd
            UInt256.max - UInt256(1),                // near UInt256.max
        ]
    }

    // Large works whose target-derived round-trip is provably lossy
    // (workForTarget(MAX / work) != work). Used both as a precondition guard and as
    // the values the near-tie fork test relies on for a nonzero residual.
    private func lossyWorks() -> [UInt256] {
        return [
            UInt256.max / UInt256(3) + UInt256(1),
            UInt256.max / UInt256(7) + UInt256(5),
            UInt256.max - UInt256(1),
        ]
    }

    // Precondition guard: the large chosen works are genuinely lossy under the old
    // target-derived round-trip, so the property/near-tie tests exercise the residual
    // rather than coincidentally-exact values. (Small works divide evenly and are NOT
    // lossy; they are still included in the property test, which must hold for them too.)
    func testChosenWorksAreLossyUnderTargetRoundTrip() {
        for work in lossyWorks() {
            let roundTripped = workForTarget(UInt256.max / work)
            XCTAssertNotEqual(roundTripped, work,
                "precondition: target-derived round-trip of \(work.toHexString()) is lossy")
        }
    }

    // AC #1 — Round-trip identity (property). For each adversarial work, build a
    // tree whose root subtree weight aggregates that work, persist->restore, and
    // assert subtreeWeight AND effectiveWeight are bit-identical to the never-persisted
    // oracle. Pre-fix the restored subtree weight is inflated by the round-trip
    // residual (work' > work), so the assertion fails.
    func testSubtreeAndEffectiveWeightBitIdenticalAcrossRestart() async throws {
        for work in adversarialWorks() {
            // G -> A(work) -> B(work): root subtree weight = G + A + B, so the residual
            // on A and B accumulates into G's subtree weight.
            let blocks: [BlockMeta] = [
                makeBlockMeta(hash: "G", height: 0, childHashes: ["A"], work: UInt256(1),
                              cumulativeWork: UInt256(1)),
                makeBlockMeta(hash: "A", previousHash: "G", height: 1, childHashes: ["B"], work: work,
                              cumulativeWork: saturatingWorkSum(UInt256(1), work)),
                makeBlockMeta(hash: "B", previousHash: "A", height: 2, work: work,
                              cumulativeWork: saturatingWorkSum(saturatingWorkSum(UInt256(1), work), work)),
            ]
            let mainHashes: Set<String> = ["G", "A", "B"]

            let oracle = makeChain(blocks: blocks, mainChainHashes: mainHashes)
            let oracleRootSubtree = (await oracle.subtreeWeight(forHash: "G"))!
            let oracleASubtree = (await oracle.subtreeWeight(forHash: "A"))!
            let oracleBSubtree = (await oracle.subtreeWeight(forHash: "B"))!

            let toPersist = makeChain(blocks: blocks, mainChainHashes: mainHashes)
            let persisted = await toPersist.persist()
            let restored = try ChainState.restore(from: persisted)

            let restoredBSubtree = await restored.subtreeWeight(forHash: "B")
            let restoredASubtree = await restored.subtreeWeight(forHash: "A")
            let restoredRootSubtree = await restored.subtreeWeight(forHash: "G")
            XCTAssertEqual(restoredBSubtree, oracleBSubtree,
                "restored B subtree weight must equal the never-persisted oracle for work \(work.toHexString())")
            XCTAssertEqual(restoredASubtree, oracleASubtree,
                "restored A subtree weight must equal the oracle for work \(work.toHexString())")
            XCTAssertEqual(restoredRootSubtree, oracleRootSubtree,
                "restored G subtree weight (aggregating the residual of A,B) must equal the oracle for work \(work.toHexString())")
        }
    }

    // AC #2 — Restart-determinism on a near-tie fork (adversarial). Two branches off
    // G whose summed subtree weight is a TIE under the exact (oracle) work, but whose
    // residuals differ under the lossy target round-trip — so a restarted node would
    // pick a different tip than a never-restarted node. Assert both pick the SAME tip.
    func testNearTieForkSelectsSameTipAcrossRestart() async throws {
        // A lossy work whose round-trip inflates it (work' > work). Putting it on only
        // ONE branch makes the lossy restart break a weight tie that the exact path holds.
        let lossy = UInt256.max / UInt256(3) + UInt256(1)
        let exactRoundTrip = workForTarget(UInt256.max / lossy)
        XCTAssertGreaterThan(exactRoundTrip, lossy,
            "precondition: the round-trip residual inflates this work")
        let residual = exactRoundTrip - lossy

        // Branch X uses the lossy work; branch Y uses a work equal to lossy + residual,
        // i.e. exactly the inflated value branch X reaches ONLY after a lossy restart.
        // Oracle (exact): X subtree = lossy, Y subtree = lossy+residual -> Y strictly heavier.
        // Lossy restart: X subtree = lossy+residual = Y -> a tie X would (mis)win/tie.
        let yWork = saturatingWorkSum(lossy, residual)
        let blocks: [BlockMeta] = [
            makeBlockMeta(hash: "G", height: 0, childHashes: ["X", "Y"], work: UInt256(1),
                          cumulativeWork: UInt256(1)),
            makeBlockMeta(hash: "X", previousHash: "G", height: 1, work: lossy,
                          cumulativeWork: saturatingWorkSum(UInt256(1), lossy)),
            makeBlockMeta(hash: "Y", previousHash: "G", height: 1, work: yWork,
                          cumulativeWork: saturatingWorkSum(UInt256(1), yWork)),
        ]
        let mainHashes: Set<String> = ["G", "X"]

        let neverRestarted = makeChain(blocks: blocks, mainChainHashes: mainHashes)
        let toPersist = makeChain(blocks: blocks, mainChainHashes: mainHashes)
        let persisted = await toPersist.persist()
        let restarted = try ChainState.restore(from: persisted)

        let neverTip = (await neverRestarted.heaviestDescent(fromHash: "G"))!.tipHash
        let restartedTip = (await restarted.heaviestDescent(fromHash: "G"))!.tipHash
        XCTAssertEqual(restartedTip, neverTip,
            "a restarted node and a never-restarted node must select the SAME fork-choice tip on a near-tie fork")
        // And both must agree with the exact oracle: Y is strictly heavier.
        XCTAssertEqual(neverTip, "Y", "never-restarted node selects the exact-heavier tip Y")
    }

    // AC #3 — Persisted bytes carry work, not a reconstruction. Read the serialized
    // record (round-tripped through the real JSON encoder/decoder) and assert the
    // live block's stored work field equals the block's OWN work — verifying the
    // property by reading the serialized form, not by re-running the converter.
    func testPersistedRecordCarriesOwnWork() async throws {
        let work = UInt256.max / UInt256(3) + UInt256(1) // lossy under MAX/work round-trip
        let blocks: [BlockMeta] = [
            makeBlockMeta(hash: "G", height: 0, childHashes: ["A"], work: UInt256(1),
                          cumulativeWork: UInt256(1)),
            makeBlockMeta(hash: "A", previousHash: "G", height: 1, work: work,
                          cumulativeWork: saturatingWorkSum(UInt256(1), work)),
        ]
        let chain = makeChain(blocks: blocks, mainChainHashes: ["G", "A"])
        let persisted = await chain.persist()

        // Serialize and decode through the REAL persistence codec (the on-disk form).
        let encoded = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(PersistedChainState.self, from: encoded)

        let a = decoded.blocks.first { $0.blockHash == "A" }!
        XCTAssertEqual(a.workHex.flatMap { UInt256($0, radix: 16) }, work,
            "serialized live block A carries its own work, not a MAX/work reconstruction")
    }

    // AC #4 — Fail-closed on decode. A persisted live block whose stored work cannot
    // be decoded must fail recovery (corruptWeightIndex), never silently substitute a
    // default that shifts fork-choice weight.
    func testRestoreFailsClosedOnUndecodableLiveWork() throws {
        let g = PersistedBlockMeta(
            blockHash: "G", parentBlockHash: nil, blockHeight: 0,
            parentChainBlocks: [:], childHashes: ["A"],
            target: UInt256(1).toHexString(), timestamp: 1,
            cumulativeWork: UInt256(1).toHexString(), workHex: UInt256(1).toHexString())
        // Live block A with a present-but-undecodable workHex.
        let a = PersistedBlockMeta(
            blockHash: "A", parentBlockHash: "G", blockHeight: 1,
            parentChainBlocks: [:], childHashes: [],
            target: UInt256(1).toHexString(), timestamp: 2,
            cumulativeWork: UInt256(2).toHexString(), workHex: "zzz")
        let snapshot = PersistedChainState(
            chainTip: "A", tipPostStateCID: nil, tipPrevStateCID: nil, tipSpecCID: nil,
            tipTarget: nil, tipNextTarget: nil, tipHeight: 1, tipTimestamp: nil,
            mainChainHashes: ["G", "A"], blocks: [g, a], prunedWeightIndex: [],
            parentChainMap: [:], missingBlockHashes: [])
        XCTAssertThrowsError(try ChainState.restore(from: snapshot)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptWeightIndex,
                "restore rejects a live block with undecodable workHex, not silent-default")
        }
    }

    // Wave-4 fail-closed: a retained pruned entry that OMITS `workHex` must fail
    // recovery. `persist()` always writes it, so a nil value is a hole; silently
    // falling back to the target-derived `workForTarget(target)` would re-open the
    // lossy double-division determinism hazard for pruned entries.
    // RED-style: construct the snapshot, assert throw — not a silent fallback.
    func testRestoreFailsClosedOnMissingPrunedWorkHex() throws {
        let g = PersistedBlockMeta(
            blockHash: "G", parentBlockHash: nil, blockHeight: 0,
            parentChainBlocks: [:], childHashes: [],
            target: UInt256(1).toHexString(), timestamp: 1,
            cumulativeWork: UInt256(1).toHexString(), workHex: UInt256(1).toHexString())
        // Pruned entry with required weights present but workHex MISSING (nil).
        let pruned = PersistedBlockMeta(
            blockHash: "P", parentBlockHash: "G", blockHeight: 1,
            parentChainBlocks: [:], childHashes: [],
            target: UInt256(1).toHexString(), timestamp: nil,
            cumulativeWork: UInt256(2).toHexString(),
            subtreeWeight: UInt256(1).toHexString(), workHex: nil)
        let snapshot = PersistedChainState(
            chainTip: "G", tipPostStateCID: nil, tipPrevStateCID: nil, tipSpecCID: nil,
            tipTarget: nil, tipNextTarget: nil, tipHeight: 0, tipTimestamp: nil,
            mainChainHashes: ["G"], blocks: [g], prunedWeightIndex: [pruned],
            parentChainMap: [:], missingBlockHashes: [])
        XCTAssertThrowsError(try ChainState.restore(from: snapshot)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptWeightIndex,
                "restore rejects a pruned entry missing workHex, not a lossy target-derived fallback")
        }
    }

    // Wave-4 fail-closed: the on-disk snapshot must CARRY the prunedWeightIndex key
    // (persist()/save() always encode it, empty or not; no legacy snapshots exist
    // pre-testnet). A snapshot missing the key was truncated or hand-edited —
    // decoding it as `[]` would silently drop every body-pruned branch's retained
    // weight, so the decoder now fails closed instead.
    func testDecodeFailsClosedOnMissingPrunedWeightIndexKey() async throws {
        let chain = makeChain(blocks: [
            makeBlockMeta(hash: "G", height: 0, work: UInt256(1), cumulativeWork: UInt256(1))
        ], mainChainHashes: ["G"])
        let persisted = await chain.persist()
        let encoded = try JSONEncoder().encode(persisted)

        // The healthy round-trip decodes (the key is always written).
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(json["prunedWeightIndex"], "persist() always encodes the key")
        XCTAssertNoThrow(try JSONDecoder().decode(PersistedChainState.self, from: encoded))

        // Strip the key: the decode must throw, not default to [].
        json.removeValue(forKey: "prunedWeightIndex")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(PersistedChainState.self, from: stripped),
            "a snapshot missing prunedWeightIndex is corrupt, not an empty index")
    }
}
