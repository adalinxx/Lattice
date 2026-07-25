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
        let root = testCID("parent-root")
        let left = testCID("parent-left")
        let right = testCID("parent-right")
        let chain = try await ChainState.restore(replaying: [
            batch(root, parent: nil, height: 0, from: a, to: b, nonce: 1),
            batch(left, parent: root, height: 1, from: b, to: c, nonce: 2),
            batch(right, parent: root, height: 1, from: b, to: d, nonce: 3),
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

        let level = ChainLevel(
            chain: chain,
            context: try ChainRuntimeContext(path: [DEFAULT_ROOT_DIRECTORY])
        )
        switch await level.parentStateContinuityLink(from: a, to: c) {
        case .success(let link):
            XCTAssertEqual(link?.parentPath, [DEFAULT_ROOT_DIRECTORY])
            XCTAssertEqual(link?.fromStateCID, a)
            XCTAssertEqual(link?.toStateCID, c)
        case .failure(let failure):
            XCTFail("transitive path should be issued: \(failure)")
        }
        switch await level.parentStateContinuityLink(from: b, to: b) {
        case .success(let link): XCTAssertNil(link)
        case .failure(let failure):
            XCTFail("reflexive continuity should need no link: \(failure)")
        }
        switch await level.parentStateContinuityLink(from: c, to: d) {
        case .success:
            XCTFail("sideways movement must not be issued")
        case .failure(let failure):
            XCTAssertEqual(failure, .notYetAdmissible)
        }
    }
}
