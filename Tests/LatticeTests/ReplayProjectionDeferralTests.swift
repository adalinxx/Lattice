import XCTest
import UInt256
@testable import Lattice

/// Restore-replay defers the derived canonical projection to a single
/// computation at the end of replay, and a duplicate delivery that changed no
/// graph or weight fact must not pay a re-projection. Both are pure cost
/// changes: the projected consensus state must be identical to the
/// incrementally-built one.
@MainActor
final class ReplayProjectionDeferralTests: XCTestCase {
    private struct Node {
        let hash: String
        let parent: String?
        let height: UInt64
        let work: UInt64
        let name: String
    }

    private func node(
        _ name: String, parent: String?, height: UInt64, work: UInt64 = 1
    ) -> Node {
        Node(
            hash: testCID("replay-defer:\(name)"),
            parent: parent,
            height: height,
            work: work,
            name: name
        )
    }

    private func admission(_ n: Node) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
            .block(ChainBlockFact(
                blockHash: n.hash,
                parentBlockHash: n.parent,
                blockHeight: n.height,
                postStateCID: testCID("replay-defer:post:\(n.name)"),
                prevStateCID: testCID("replay-defer:prev:\(n.name)"),
                specCID: testCID("replay-defer:spec:\(n.name)"),
                target: "1",
                nextTarget: "1",
                timestamp: Int64(n.height),
                stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: n.hash,
                contribution: VerifiedWorkContribution(
                    id: testCID("replay-defer:work:\(n.name)"),
                    work: UInt256(n.work)
                )
            )),
        ])
    }

    private func extraWork(_ n: Node, grind: String, work: UInt64) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
            .work(ChainWorkFact(
                blockHash: n.hash,
                contribution: VerifiedWorkContribution(
                    id: testCID("replay-defer:grind:\(grind)"),
                    work: UInt256(work)
                )
            )),
        ])
    }

    /// A bushy merged-mining-shaped graph: a canonical spine with a sibling
    /// (duplicate-height side block) at every third height plus extra carrier
    /// work batches — the shape that defeats the append fast path.
    private func bushyBatches() -> (batches: [ChainAdmissionBatch], root: Node) {
        let root = node("root", parent: nil, height: 0)
        var batches = [admission(root)]
        var previous = root
        for index in 1...30 {
            let canonical = node("main-\(index)", parent: previous.hash, height: UInt64(index), work: 4)
            batches.append(admission(canonical))
            if index % 3 == 0 {
                let side = node("side-\(index)", parent: previous.hash, height: UInt64(index), work: 1)
                batches.append(admission(side))
            }
            if index % 5 == 0 {
                batches.append(extraWork(canonical, grind: "carrier-\(index)", work: 2))
            }
            previous = canonical
        }
        return (batches, root)
    }

    func testRestoreReplayProjectsOnceAndMatchesIncrementalConsensus() async throws {
        let (batches, root) = bushyBatches()

        // Incremental reference: genesis restore, then every batch applied live
        // with per-event projection (the pre-existing behavior for live sync).
        let incremental = try await ChainState.restore(replaying: [batches[0]])
        for batch in batches.dropFirst() {
            _ = try await incremental.applyStaged(batch)
        }

        // Replayed: the full batch set through restore, projection deferred.
        // Deterministically adversarial order — fully reversed, so every child
        // precedes its parent and every carrier grind precedes its block —
        // exercising replay's own height/work ordering; the incremental
        // reference above covers the natural order. (Deliberately not
        // shuffled(): a random permutation would turn any order-dependence
        // bug into an unreproducible flake.)
        let restored = try await ChainState.restore(
            replaying: Array(batches.reversed())
        )

        // Consensus state must be identical — tip, membership, and the whole
        // by-height index.
        let incrementalTip = await incremental.getMainChainTip()
        let restoredTip = await restored.getMainChainTip()
        XCTAssertEqual(restoredTip, incrementalTip)
        let incrementalMain = await incremental.mainChainHashes
        let restoredMain = await restored.mainChainHashes
        XCTAssertEqual(restoredMain, incrementalMain)
        let height = await restored.getHighestBlockHeight()
        XCTAssertEqual(height, 30)
        XCTAssertNotEqual(root.hash, restoredTip)
        for h in 0...30 {
            let a = await incremental.getMainChainBlockHash(atIndex: UInt64(h))
            let b = await restored.getMainChainBlockHash(atIndex: UInt64(h))
            XCTAssertNotNil(a, "height \(h) must be indexed")
            XCTAssertEqual(a, b, "height \(h) diverged between replay and incremental")
        }

        // The cost contract: replay computed the full projection exactly once,
        // regardless of graph bushiness or batch count.
        let projections = await restored.fullCanonicalProjectionCount
        XCTAssertEqual(projections, 1, "restore-replay must project exactly once")
    }

    func testReevaluationIsFreeWhenNoFactChangedAndStillPromotesAfterMutation() async throws {
        let (batches, _) = bushyBatches()
        let chain = try await ChainState.restore(replaying: batches)

        // A duplicate delivery that added nothing must not pay a projection.
        await chain.resetFullCanonicalProjectionCount()
        let unchanged = await chain.reevaluateForkChoice()
        XCTAssertNil(unchanged, "no mutation since last projection ⇒ no promotion possible")
        let free = await chain.fullCanonicalProjectionCount
        XCTAssertEqual(free, 0, "provably-current re-evaluation must not project")

        // A real weight mutation must still re-evaluate and be able to promote:
        // outweigh the height-30 canonical tip via the height-30 side fork's
        // ancestor at height 27 (side-27 exists; give it decisive work).
        let sideTip = testCID("replay-defer:side-27")
        _ = try await chain.applyStaged(ChainAdmissionBatch(facts: [
            .work(ChainWorkFact(
                blockHash: sideTip,
                contribution: VerifiedWorkContribution(
                    id: testCID("replay-defer:grind:decisive"),
                    work: UInt256(1_000_000)
                )
            )),
        ]))
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, sideTip, "a decisive weight mutation must still promote")
        // And immediately after that projection, re-evaluation is free again.
        await chain.resetFullCanonicalProjectionCount()
        let settled = await chain.reevaluateForkChoice()
        XCTAssertNil(settled)
        let settledCount = await chain.fullCanonicalProjectionCount
        XCTAssertEqual(settledCount, 0)
    }
}
