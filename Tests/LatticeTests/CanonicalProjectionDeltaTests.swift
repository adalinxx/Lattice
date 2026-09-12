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
        truncations: UInt64,
        tip: String,
        chain: ChainState
    ) {
        let root = node("root", parent: nil, height: 0, work: 4)
        let chain = try await ChainState.restore(replaying: [admission(root)])
        let blocksBefore = await chain.canonicalProjectionBlockVisitCount
        let segmentsBefore = await chain.canonicalProjectionSegmentVisitCount
        let cellsBefore = await chain.segmentWorkUpdateCellCount
        let truncationsBefore = await chain.truncatedCanonicalProjectionCount
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
        let truncationsAfter = await chain.truncatedCanonicalProjectionCount
        return (
            blocksAfter - blocksBefore,
            segmentsAfter - segmentsBefore,
            cellsAfter - cellsBefore,
            truncationsAfter - truncationsBefore,
            previous.hash,
            chain
        )
    }

    func testLiveSyncProjectsTheChangedSuffixNotTheWholeChain() async throws {
        var blockVisits: [Int: UInt64] = [:]
        var segmentVisits: [Int: UInt64] = [:]
        var workCells: [Int: UInt64] = [:]
        var truncations: [Int: UInt64] = [:]
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
            truncations[length] = run.truncations
        }

        // Assert the per-admission bound the projection actually guarantees,
        // not a growth ratio: a "must not quadruple for a doubled chain" bound
        // is vacuous here, since the whole-chain projection satisfies it too
        // (20,300 x 4 >= 80,600). Materializing the changed suffix is one block
        // per admission on this shape; the x2 leaves room for the first
        // projection, which is necessarily full.
        let measured = "blocks \(blockVisits), segments \(segmentVisits), workCells \(workCells), truncations \(truncations)"
        for length in [200, 400, 800] {
            XCTAssertLessThanOrEqual(
                blockVisits[length]!,
                UInt64(2 * length),
                "projection work must scale with the change, not the chain length: \(measured)"
            )
        }

        // The spine walk is no longer quadratic. The descent starts at the
        // divergence point — the deepest canonical ancestor of the block that
        // just changed — so it walks the segments that CHANGED rather than the
        // path from the root. The previous assertion on this column was an
        // XCTAssertGreaterThan pinning it as still quadratic; inverting it is
        // the entire point of this change, not a broken test.
        //
        // Measured, not guessed: one segment per admission, so 2 per height on
        // this shape (400/800/1600 at 200/400/800), against 20,300/80,600/
        // 321,200 before. The x3 is headroom over the measured 2, and still
        // leaves the bound two orders of magnitude below the quadratic value it
        // replaces — a planted bug that disables truncation turns it red.
        for length in [200, 400, 800] {
            XCTAssertLessThanOrEqual(
                segmentVisits[length]!,
                UInt64(3 * length),
                "the spine walk must scale with the change, not the chain: \(measured)"
            )
        }
        // The truncation must also be shown to FIRE. One that silently never
        // fired would still be correct, and every parity test would still pass,
        // so the cost claim needs a witness of its own.
        for length in [200, 400, 800] {
            XCTAssertGreaterThanOrEqual(
                truncations[length]!,
                UInt64(2 * length),
                "every admission truncates, both per height: \(measured)"
            )
        }

        // What this change does NOT fix, pinned so it cannot be mistaken for
        // solved: `SegmentWorkIndex.add` still walks every ancestor base on
        // every admission. It is the larger of the two residual terms and it is
        // paid before any projection runs, so no change to the descent can
        // reach it — that needs a different weight structure. A fix to it is
        // EXPECTED to break this assertion; update it deliberately when it
        // lands.
        XCTAssertGreaterThan(
            workCells[800]!,
            workCells[200]! * 8,
            "subtree-weight walk is still quadratic: \(measured)"
        )
    }

    /// A LOSING sibling deep in the chain is the most common admission shape on
    /// a merged-mining child, and it changes no canonical decision at all, so it
    /// must cost nothing. The shape matters: the sibling-at-every-height case
    /// hangs its sibling off the current TIP, where a descent to the tip is one
    /// block and a regression here would be invisible. These siblings hang off
    /// blocks spread across the whole history, including just above genesis,
    /// where descending to the tip would materialize hundreds of blocks to
    /// conclude nothing moved.
    func testDeepLosingSiblingMaterializesNothing() async throws {
        let length = 400
        let root = node("deep-root", parent: nil, height: 0, work: 4)
        let chain = try await ChainState.restore(replaying: [admission(root)])
        var canonical = [root]
        var previous = root
        for height in 1...length {
            let block = node(
                "deep-main-\(height)",
                parent: previous.hash,
                height: UInt64(height),
                work: 4
            )
            _ = try await chain.applyStaged(admission(block))
            canonical.append(block)
            previous = block
        }

        let blocksBefore = await chain.canonicalProjectionBlockVisitCount
        let segmentsBefore = await chain.canonicalProjectionSegmentVisitCount
        var siblings = 0
        for height in stride(from: 1, through: length - 1, by: 8) {
            let sibling = node(
                "deep-side-\(height)",
                parent: canonical[height - 1].hash,
                height: UInt64(height),
                work: 1
            )
            _ = try await chain.applyStaged(admission(sibling))
            siblings += 1
        }
        let blocks = await chain.canonicalProjectionBlockVisitCount - blocksBefore
        let segments = await chain.canonicalProjectionSegmentVisitCount
            - segmentsBefore
        let tip = await chain.getMainChainTip()

        XCTAssertGreaterThan(siblings, 40, "the shape must cover real depth")
        XCTAssertEqual(tip, previous.hash, "a losing sibling must not move the tip")
        XCTAssertEqual(
            blocks,
            0,
            "a losing sibling changes no decision, so nothing may be materialized"
        )
        XCTAssertEqual(
            segments,
            0,
            "and the winner at the fork point settles it without walking to the tip"
        )
    }

    /// Divergence deeper than any fixed walk budget.
    ///
    /// An earlier version of this change capped the ancestor walk at 64 steps
    /// and fell through to the whole-chain projection past it. That cap did not
    /// bound the cost of a deep divergence, it RELOCATED it: the fallback pays a
    /// spine walk and a descent from the root before it can discover that
    /// nothing moved, so a divergence past the cap cost O(n) per admission — the
    /// quadratic this change removes, on the shape it exists to make cheap.
    ///
    /// Every other shape in this file keeps the mutation one step off the
    /// canonical path, so not one of them can see that. The shape is the test
    /// here, not the bound.
    func testDivergenceDeeperThanAnyWalkBudgetMaterializesNothing() async throws {
        let length = 400
        let forkHeight = 10
        let branchLength = 160
        XCTAssertGreaterThan(
            branchLength,
            64,
            "the divergence must exceed any fixed step budget to be meaningful"
        )

        let root = node("budget-root", parent: nil, height: 0, work: 4)
        let chain = try await ChainState.restore(replaying: [admission(root)])
        var canonical = [root]
        var previous = root
        for height in 1...length {
            let block = node(
                "budget-main-\(height)",
                parent: previous.hash,
                height: UInt64(height),
                work: 4
            )
            _ = try await chain.applyStaged(admission(block))
            canonical.append(block)
            previous = block
        }

        // A long LOSING branch off an early canonical block. Its total work
        // stays far under the canonical subtree above the fork, so the canonical
        // path never moves and everything admitted on it is a losing block.
        var branchTip = canonical[forkHeight]
        for step in 1...branchLength {
            let block = node(
                "budget-branch-\(step)",
                parent: branchTip.hash,
                height: UInt64(forkHeight + step),
                work: 1
            )
            _ = try await chain.applyStaged(admission(block))
            branchTip = block
        }
        let tipAfterBranch = await chain.getMainChainTip()
        XCTAssertEqual(
            tipAfterBranch,
            previous.hash,
            "the losing branch must not take the canonical path"
        )

        let blocksBefore = await chain.canonicalProjectionBlockVisitCount
        let segmentsBefore = await chain.canonicalProjectionSegmentVisitCount
        // One more block at the END of that branch: its ancestor line meets the
        // canonical path branchLength + 1 steps down, far past any budget.
        let deep = node(
            "budget-deep",
            parent: branchTip.hash,
            height: UInt64(forkHeight + branchLength + 1),
            work: 1
        )
        _ = try await chain.applyStaged(admission(deep))
        let blocks = await chain.canonicalProjectionBlockVisitCount - blocksBefore
        let segments = await chain.canonicalProjectionSegmentVisitCount
            - segmentsBefore

        let finalTip = await chain.getMainChainTip()
        XCTAssertEqual(
            finalTip,
            previous.hash,
            "a losing block on a deep branch must not move the tip"
        )
        XCTAssertEqual(
            blocks,
            0,
            "a deep divergence that changes nothing must materialize nothing"
        )
        XCTAssertEqual(
            segments,
            0,
            "and must not fall back to walking the path from the root"
        )
    }

    /// Subtree work is SUMMED by the live index but deduplicated by grind
    /// identity in the reference oracle, so the two agree only while each grind
    /// identity occupies exactly one block. That is what `acceptsLocation`
    /// enforces, and it is what makes summing — and every range-sum technique
    /// built on it — valid over this graph. Tested rather than assumed.
    func testAGrindIdentityCannotOccupyTwoBlocks() async throws {
        let root = node("dup-root", parent: nil, height: 0, work: 4)
        let a = node("dup-a", parent: root.hash, height: 1, work: 4)
        let b = node("dup-b", parent: root.hash, height: 1, work: 1)
        let chain = try await ChainState.restore(replaying: [admission(root)])
        _ = try await chain.applyStaged(admission(a))
        _ = try await chain.applyStaged(admission(b))

        let shared = testCID("projection-delta:shared-grind")
        let first = try await chain.applyStaged(ChainAdmissionBatch(facts: [
            .work(ChainWorkFact(
                blockHash: a.hash,
                contribution: VerifiedWorkContribution(id: shared, work: UInt256(9))
            )),
        ]))
        XCTAssertEqual(first?.addedContribution, true)

        // The same identity, stronger, at a different block: if this were
        // admitted the same work would be counted in two subtrees at once.
        do {
            _ = try await chain.applyStaged(ChainAdmissionBatch(facts: [
                .work(ChainWorkFact(
                    blockHash: b.hash,
                    contribution: VerifiedWorkContribution(
                        id: shared,
                        work: UInt256(99)
                    )
                )),
            ]))
            XCTFail("a grind identity already located at another block was admitted")
        } catch {
            // Refused, as it must be.
        }

        let blocks = await chain.hashToBlock
        let reference = try XCTUnwrap(
            ChainState.referenceCanonicalProjection(in: blocks)
        )
        let tip = await chain.getMainChainTip()
        let path = await chain.mainChainHashes
        XCTAssertEqual(tip, reference.chainTip)
        XCTAssertEqual(path, reference.mainChainHashes)
        XCTAssertEqual(tip, a.hash, "the relocated work must not have moved the tip")
    }
}
