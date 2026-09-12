import XCTest
import UInt256
@testable import Lattice

/// Live-sync projection cost on a merged-mining child. Two miners racing at the
/// same height make an ordinary canonical block arrive with a sibling already
/// present, so the O(1) tip-append guard (`parent.childHashes.count == 1`)
/// fails and every canonical admission falls through to a canonical
/// projection. What that projection materializes must scale with the CHANGE,
/// not with the chain length — otherwise live sync is Θ(n²) in blocks.
@MainActor
final class CanonicalProjectionDeltaTests: XCTestCase {
    private struct Node {
        let hash: String
        let parent: String?
        let height: UInt64
        let work: UInt64
        let name: String
    }

    private func node(
        _ name: String, parent: String?, height: UInt64, work: UInt64
    ) -> Node {
        Node(
            hash: testCID("projection-delta:\(name)"),
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
                postStateCID: testCID("projection-delta:post:\(n.name)"),
                prevStateCID: testCID("projection-delta:prev:\(n.name)"),
                specCID: testCID("projection-delta:spec:\(n.name)"),
                target: "1",
                nextTarget: "1",
                timestamp: Int64(n.height),
                stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: n.hash,
                contribution: VerifiedWorkContribution(
                    id: testCID("projection-delta:work:\(n.name)"),
                    work: UInt256(n.work)
                )
            )),
        ])
    }

    /// Sibling-before-canonical at every height, one block at a time — the
    /// live-sync path, not restore-replay.
    private func syncMergedMiningChild(
        length: Int
    ) async throws -> (
        blockVisits: UInt64,
        segmentVisits: UInt64,
        workCells: UInt64,
        tip: String,
        chain: ChainState
    ) {
        let root = node("root", parent: nil, height: 0, work: 4)
        let chain = try await ChainState.restore(replaying: [admission(root)])
        let blocksBefore = await chain.canonicalProjectionBlockVisitCount
        let segmentsBefore = await chain.canonicalProjectionSegmentVisitCount
        let cellsBefore = await chain.segmentWorkUpdateCellCount
        var previous = root
        for height in 1...length {
            let side = node(
                "side-\(height)",
                parent: previous.hash,
                height: UInt64(height),
                work: 1
            )
            _ = try await chain.applyStaged(admission(side))
            let canonical = node(
                "main-\(height)",
                parent: previous.hash,
                height: UInt64(height),
                work: 4
            )
            _ = try await chain.applyStaged(admission(canonical))
            previous = canonical
        }
        let blocksAfter = await chain.canonicalProjectionBlockVisitCount
        let segmentsAfter = await chain.canonicalProjectionSegmentVisitCount
        let cellsAfter = await chain.segmentWorkUpdateCellCount
        return (
            blocksAfter - blocksBefore,
            segmentsAfter - segmentsBefore,
            cellsAfter - cellsBefore,
            previous.hash,
            chain
        )
    }

    func testLiveSyncProjectsTheChangedSuffixNotTheWholeChain() async throws {
        var blockVisits: [Int: UInt64] = [:]
        var segmentVisits: [Int: UInt64] = [:]
        var workCells: [Int: UInt64] = [:]
        for length in [200, 400, 800] {
            let run = try await syncMergedMiningChild(length: length)
            // Cost-only: the projected consensus state must still equal the
            // independent slow walk over the same graph.
            let blocks = await run.chain.hashToBlock
            let reference = try XCTUnwrap(
                ChainState.referenceCanonicalProjection(in: blocks),
                "length \(length)"
            )
            let tip = await run.chain.getMainChainTip()
            let mainChain = await run.chain.mainChainHashes
            XCTAssertEqual(tip, run.tip, "length \(length): tip")
            XCTAssertEqual(tip, reference.chainTip, "length \(length): reference tip")
            XCTAssertEqual(
                mainChain,
                reference.mainChainHashes,
                "length \(length): reference path"
            )
            blockVisits[length] = run.blockVisits
            segmentVisits[length] = run.segmentVisits
            workCells[length] = run.workCells
        }

        // Assert the per-admission bound the projection actually guarantees,
        // not a growth ratio: a "must not quadruple for a doubled chain" bound
        // is vacuous here, since the whole-chain projection satisfies it too
        // (20,300 x 4 >= 80,600). Materializing the changed suffix is one block
        // per admission on this shape; the x2 leaves room for the first
        // projection, which is necessarily full.
        let measured = "blocks \(blockVisits), segments \(segmentVisits), workCells \(workCells)"
        for length in [200, 400, 800] {
            XCTAssertLessThanOrEqual(
                blockVisits[length]!,
                UInt64(2 * length),
                "projection work must scale with the change, not the chain length: \(measured)"
            )
        }

        // What the delta projection does NOT fix, pinned so it cannot be
        // mistaken for solved. Both remaining terms are still Θ(n²) on this
        // shape, and the larger one is paid before any projection runs:
        //   - `SegmentWorkIndex.add` walks every ancestor base per admission;
        //   - `segmentGhostSpine` walks the whole spine from the root.
        // A merged-mining graph degenerates the segment quotient to one
        // segment per block, which is the root cause behind all three terms.
        // A future fix to either is EXPECTED to break these two assertions —
        // that is the point; update them deliberately when it lands.
        XCTAssertGreaterThan(
            segmentVisits[800]!,
            segmentVisits[200]! * 8,
            "spine walk is still quadratic: \(measured)"
        )
        XCTAssertGreaterThan(
            workCells[800]!,
            workCells[200]! * 8,
            "subtree-weight walk is still quadratic: \(measured)"
        )
    }
}
