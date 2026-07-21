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

    func testBlockMetadataReplacesOnlyTheStrengthenedQuantity() {
        var metadata = BlockMeta(
            blockHash: "block",
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            workContributions: [
                contribution("shared", 7),
                contribution("independent", 11),
            ]
        )

        XCTAssertTrue(metadata.setWorkContribution(contribution("shared", 13)))
        XCTAssertEqual(metadata.workContributions["shared"]?.work, UInt256(13))
        XCTAssertEqual(metadata.work, WorkSum(UInt256(24)))
    }

    func testRawStrengtheningAcrossBlocksUsesThePathMaximum() async {
        let shared = contribution("shared", 2)
        let stronger = contribution("shared", 13)
        var root = BlockMeta(
            blockHash: "root",
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: ["child"],
            workContributions: [shared]
        )
        let child = BlockMeta(
            blockHash: "child",
            parentBlockHash: "root",
            blockHeight: 1,
            childHashes: [],
            workContributions: [stronger]
        )
        root.childHashes = ["child"]
        let chain = makeChain(blocks: [root, child])

        let cumulative = await chain.getCumulativeWork(forHash: "child")
        let subtree = await chain.subtreeWeight(forHash: "root")

        XCTAssertEqual(cumulative, WorkSum(UInt256(13)))
        XCTAssertEqual(subtree, WorkSum(UInt256(13)))
    }
}
