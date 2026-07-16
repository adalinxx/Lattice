import XCTest
import UInt256
@testable import Lattice

final class WorkMeasureTests: XCTestCase {
    private func contribution(_ id: String, _ work: UInt64) -> VerifiedWorkContribution {
        VerifiedWorkContribution(id: id, work: UInt256(work))
    }

    func testOneGrindCountsOnceAcrossAnyNumberOfCoverages() {
        let grind = contribution("grind", 7)
        let once = WorkMeasure(grind)
        let many = once.union(once).union(once)

        XCTAssertEqual(many.grindIDs, ["grind"])
        XCTAssertEqual(many.total, WorkSum(UInt256(7)))
    }

    func testStrongestVerifiedValueWinsForOneGrind() {
        let weaker = WorkMeasure(contribution("grind", 7))
        let stronger = WorkMeasure(contribution("grind", 11))

        XCTAssertEqual(weaker.union(stronger).total, WorkSum(UInt256(11)))
        XCTAssertEqual(stronger.union(weaker).total, WorkSum(UInt256(11)))
    }

    func testIndependentGrindsSumExactly() {
        let measure = WorkMeasure([
            contribution("first", 7),
            contribution("second", 11),
        ])

        XCTAssertEqual(measure.total, WorkSum(UInt256(18)))
    }

    func testBlockMetadataKeepsStrongestDuplicateRegardlessOfOrder() {
        let weaker = contribution("grind", 7)
        let stronger = contribution("grind", 11)

        for observations in [[weaker, stronger], [stronger, weaker]] {
            let metadata = BlockMeta(
                blockHash: "block",
                parentBlockHash: nil,
                blockHeight: 0,
                childHashes: [],
                workContributions: observations
            )

            XCTAssertEqual(metadata.workContributions["grind"], stronger)
            XCTAssertEqual(metadata.work, WorkSum(UInt256(11)))
        }
    }
}
