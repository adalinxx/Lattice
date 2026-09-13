import XCTest
import UInt256
@testable import Lattice

/// WHERE work admissions land, measured before any accumulator is built.
///
/// The accumulator design's cost model rests on one empirical claim: work
/// arrives at or near the canonical tip, because that is where mining happens,
/// so a repair proportional to distance-from-tip is cheap. The spec surfaces one
/// mutation that need not obey that — a securing contribution admitted when a
/// terminal child becomes connected, which is a work increase at arbitrary
/// depth. From `ChainState`'s side securing work is indistinguishable from any
/// other work fact, so measuring admission depth measures it too.
///
/// This test asserts nothing about the design. It reports the distribution, so
/// the design is chosen against a measurement rather than an assumption.
@MainActor
final class WorkAdmissionDepthTests: XCTestCase {
    private func block(
        _ name: String,
        parent: String?,
        height: UInt64,
        work: UInt64
    ) -> (hash: String, batch: ChainAdmissionBatch) {
        let hash = testCID("admission-depth:\(name)")
        let batch = ChainAdmissionBatch(facts: [
            .block(ChainBlockFact(
                blockHash: hash,
                parentBlockHash: parent,
                blockHeight: height,
                postStateCID: testCID("admission-depth:post:\(name)"),
                prevStateCID: testCID("admission-depth:prev:\(name)"),
                specCID: testCID("admission-depth:spec:\(name)"),
                target: "1",
                nextTarget: "1",
                timestamp: Int64(height),
                stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: hash,
                contribution: VerifiedWorkContribution(
                    id: testCID("admission-depth:work:\(name)"),
                    work: UInt256(work)
                )
            )),
        ])
        return (hash, batch)
    }

    /// A later, strictly stronger observation of the SAME grind identity at a
    /// block already held — the shape a securing contribution takes once its
    /// terminal child connects.
    private func restrike(
        _ name: String,
        at blockHash: String,
        work: UInt64
    ) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
            .work(ChainWorkFact(
                blockHash: blockHash,
                contribution: VerifiedWorkContribution(
                    id: testCID("admission-depth:work:\(name)"),
                    work: UInt256(work)
                )
            )),
        ])
    }

    func testWhereWorkAdmissionsLand() async throws {
        let length = 400

        // Shape 1: the merged-mining sync — a losing sibling at every height,
        // delivered before the canonical block. Every admission here should be
        // at or adjacent to the tip.
        let root = block("root", parent: nil, height: 0, work: 4)
        let chain = try await ChainState.restore(replaying: [root.batch])
        var canonical = [root.hash]
        var previous = root.hash
        // Reorgs are counted from the emitted commits rather than from new
        // instrumentation: `mainChainBlocksRemoved` is already public, so this
        // needs no counter, no threshold and no change to the admission path.
        //
        // It matters for the accumulator because a block that LEAVES the spine
        // must stop accruing later tip extensions. If displacement is rare,
        // re-basing is an exceptional path; if it happens at nearly every
        // height, re-basing is the hot path and has to be O(1) itself.
        var reorgCount = 0
        var reorgRemovedSum = 0
        var reorgMaxRemoved = 0
        func tally(_ result: SubmissionResult?) {
            let removed = result?.commit?.mainChainBlocksRemoved ?? []
            guard !removed.isEmpty else { return }
            reorgCount += 1
            reorgRemovedSum += removed.count
            reorgMaxRemoved = max(reorgMaxRemoved, removed.count)
        }
        for height in 1...length {
            let side = block(
                "side-\(height)",
                parent: previous,
                height: UInt64(height),
                work: 1
            )
            tally(try await chain.applyStaged(side.batch))
            let next = block(
                "main-\(height)",
                parent: previous,
                height: UInt64(height),
                work: 4
            )
            tally(try await chain.applyStaged(next.batch))
            canonical.append(next.hash)
            previous = next.hash
        }
        let syncCount = await chain.workAdmissionCount
        let syncDepthSum = await chain.workAdmissionDepthSum
        let syncMaxDepth = await chain.workAdmissionMaxDepth

        // Shape 2: securing work arriving late, at arbitrary depth. A stronger
        // observation of a grind already located at an OLD block is exactly the
        // admission the design's cost model treats as rare.
        for height in [1, length / 4, length / 2] {
            _ = try await chain.applyStaged(restrike(
                "main-\(height)",
                at: canonical[height],
                work: 9
            ))
        }
        let deepCount = await chain.workAdmissionCount - syncCount
        let deepDepthSum = await chain.workAdmissionDepthSum - syncDepthSum
        let deepMaxDepth = await chain.workAdmissionMaxDepth

        let measured = "sync: count \(syncCount) depthSum \(syncDepthSum)"
            + " maxDepth \(syncMaxDepth)"
            + " | deep restrikes: count \(deepCount) depthSum \(deepDepthSum)"
            + " maxDepth \(deepMaxDepth)"
            + " | spine displacement: reorgs \(reorgCount)"
            + " removedSum \(reorgRemovedSum) maxRemoved \(reorgMaxRemoved)"
            + " over \(2 * length) admissions"
        // These are the three facts the accumulator's cost model rests on, so
        // they are asserted rather than merely reported. If the workload shape
        // ever stops matching them, the design's justification has gone and
        // this is where that should surface.

        // 1. Ordinary admission is a TIP phenomenon. This is what makes "one
        //    add and one stamp" the common case rather than a special case.
        XCTAssertEqual(
            syncCount,
            UInt64(2 * length),
            "every admission should be counted: \(measured)"
        )
        XCTAssertEqual(
            syncDepthSum,
            0,
            "ordinary admissions must land at the tip: \(measured)"
        )
        XCTAssertEqual(
            syncMaxDepth,
            0,
            "not one ordinary admission may land behind the tip: \(measured)"
        )

        // 2. The deep path is REAL, not hypothetical - a securing contribution
        //    arriving late reaches arbitrary depth. It is rare, which is why
        //    O(distance from tip) is acceptable there, but a design that
        //    assumed it away would be wrong.
        XCTAssertEqual(deepCount, 3, "the restrikes must register: \(measured)")
        XCTAssertGreaterThan(
            deepMaxDepth,
            UInt64(length / 2),
            "the deep path must actually reach depth: \(measured)"
        )

        // 3. Spine displacement is FREQUENT but CONSTANT-SIZED. Frequency is
        //    why re-basing must be O(1) in both directions; the bounded size is
        //    what makes that achievable.
        XCTAssertEqual(
            reorgCount,
            length,
            "a block should be displaced at nearly every height: \(measured)"
        )
        XCTAssertEqual(
            reorgMaxRemoved,
            1,
            "displacement must stay constant-sized: \(measured)"
        )
    }
}
