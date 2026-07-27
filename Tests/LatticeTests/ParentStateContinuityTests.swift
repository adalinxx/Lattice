import XCTest
@testable import Lattice
import UInt256

final class ParentStateContinuityTests: XCTestCase {
    private func batch(
        _ block: String,
        parent: String?,
        height: UInt64,
        from: String,
        to: String,
        nonce: Int64
    ) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
            .block(ChainBlockFact(
                blockHash: block,
                parentBlockHash: parent,
                blockHeight: height,
                postStateCID: to,
                prevStateCID: from,
                specCID: testCID("continuity-spec"),
                target: UInt256.max.toHexString(),
                nextTarget: UInt256.max.toHexString(),
                timestamp: nonce,
                stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: block,
                contribution: VerifiedWorkContribution(
                    id: testCID("continuity-grind-\(nonce)"),
                    work: 1
                )
            )),
        ])
    }

    func testContinuityIsReflexiveTransitiveAndCanonicityIndependent()
        async throws {
        let a = testCID("state-a")
        let b = testCID("state-b")
        let c = testCID("state-c")
        let d = testCID("state-d")
        let e = testCID("state-e")
        let z = testCID("state-z")
        let root = testCID("parent-root")
        let left = testCID("parent-left")
        let right = testCID("parent-right")
        let leftTip = testCID("parent-left-tip")
        let rightTip = testCID("parent-right-tip")
        let orphan = testCID("parent-orphan")
        let chain = try await ChainState.restore(replaying: [
            batch(root, parent: nil, height: 0, from: a, to: b, nonce: 1),
            batch(left, parent: root, height: 1, from: b, to: c, nonce: 2),
            batch(right, parent: root, height: 1, from: b, to: d, nonce: 3),
            batch(leftTip, parent: left, height: 2, from: c, to: e, nonce: 4),
            batch(rightTip, parent: right, height: 2, from: d, to: e, nonce: 5),
            batch(
                orphan,
                parent: testCID("missing-parent"),
                height: 2,
                from: d,
                to: z,
                nonce: 6
            ),
        ])

        let reflexive = await chain.hasStateContinuity(from: b, to: b)
        let transitive = await chain.hasStateContinuity(from: a, to: c)
        let leftBranch = await chain.hasStateContinuity(from: b, to: c)
        let rightBranch = await chain.hasStateContinuity(from: b, to: d)
        let backward = await chain.hasStateContinuity(from: c, to: a)
        let sideways = await chain.hasStateContinuity(from: c, to: d)
        XCTAssertTrue(reflexive)
        XCTAssertTrue(transitive)
        XCTAssertTrue(leftBranch)
        XCTAssertTrue(rightBranch)
        XCTAssertFalse(backward)
        XCTAssertFalse(sideways)
        let transitivePath = await chain.stateContinuityPath(from: a, to: c)
        let reflexivePath = await chain.stateContinuityPath(from: b, to: b)
        let sidewaysPath = await chain.stateContinuityPath(from: c, to: d)
        XCTAssertEqual(transitivePath, [root, left])
        XCTAssertEqual(reflexivePath, [])
        XCTAssertNil(sidewaysPath)
        let repeatedLeft = await chain.stateContinuityPath(from: c, to: e)
        let repeatedRight = await chain.stateContinuityPath(from: d, to: e)
        let disconnected = await chain.hasStateContinuity(from: d, to: z)
        XCTAssertEqual(repeatedLeft, [leftTip])
        XCTAssertEqual(repeatedRight, [rightTip])
        XCTAssertFalse(disconnected)
#if DEBUG
        let visits = await chain.stateContinuityBlockVisitCount
        let absent = await chain.hasStateContinuity(
            from: a,
            to: testCID("absent-target")
        )
        let visitsAfterAbsent = await chain.stateContinuityBlockVisitCount
        XCTAssertFalse(absent)
        XCTAssertEqual(visitsAfterAbsent, visits)
#endif
    }
}
