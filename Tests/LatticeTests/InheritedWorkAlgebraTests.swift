import XCTest
import UInt256
@testable import Lattice

func assertInheritedWorkMeasure(
    _ actual: WorkMeasure,
    equals expected: [String: UInt64],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.grindIDs, Set(expected.keys), file: file, line: line)
    for (grind, work) in expected {
        XCTAssertEqual(actual.work(forGrind: grind), UInt256(work), file: file, line: line)
    }
    XCTAssertEqual(
        actual.total,
        WorkSum(UInt256(expected.values.reduce(0, +))),
        file: file,
        line: line
    )
}

private func permutations<T>(_ values: [T]) -> [[T]] {
    guard !values.isEmpty else { return [[]] }
    return values.indices.flatMap { index -> [[T]] in
        var remainder = values
        let first = remainder.remove(at: index)
        return permutations(remainder).map { [first] + $0 }
    }
}

final class InheritedWorkAlgebraTests: XCTestCase {
    private func fact(
        block: String,
        grind: String,
        work: UInt64
    ) throws -> InheritedWorkFact {
        try XCTUnwrap(InheritedWorkFact(
            blockCID: block,
            grindID: grind,
            work: UInt256(work)
        ))
    }

    func testWorkMeasureUnionIsAssociativeCommutativeAndIdempotent() {
        let g1 = testCID("measure-g1")
        let g2 = testCID("measure-g2")
        let g3 = testCID("measure-g3")
        let a = WorkMeasure([
            VerifiedWorkContribution(id: g1, work: UInt256(2)),
            VerifiedWorkContribution(id: g2, work: UInt256(5)),
        ])
        let b = WorkMeasure([
            VerifiedWorkContribution(id: g1, work: UInt256(7)),
            VerifiedWorkContribution(id: g3, work: UInt256(1)),
        ])

        XCTAssertEqual(a.union(a), a)
        XCTAssertEqual(a.union(b), b.union(a))
        XCTAssertEqual(a.union(b).union(a), a.union(b.union(a)))
        assertInheritedWorkMeasure(a.union(b), equals: [g1: 7, g2: 5, g3: 1])
    }

    func testWorkMeasureRestrictionPartitionsAndRejoinsExactly() {
        let g1 = testCID("restriction-g1")
        let g2 = testCID("restriction-g2")
        let g3 = testCID("restriction-g3")
        let measure = WorkMeasure([
            VerifiedWorkContribution(id: g1, work: UInt256(2)),
            VerifiedWorkContribution(id: g2, work: UInt256(5)),
            VerifiedWorkContribution(id: g3, work: UInt256(7)),
        ])

        let first = measure.restricted(toGrindIDs: [g1, g3])
        let second = measure.restricted(toGrindIDs: [g2])

        assertInheritedWorkMeasure(first, equals: [g1: 2, g3: 7])
        assertInheritedWorkMeasure(second, equals: [g2: 5])
        XCTAssertEqual(first.union(second), measure)
        XCTAssertTrue(measure.restricted(toGrindIDs: []).isEmpty)
    }

    func testSnapshotRestrictionKeepsExactSourceScope() throws {
        let left = testCID("restriction-left")
        let right = testCID("restriction-right")
        let leftGrind = testCID("restriction-left-grind")
        let rightGrind = testCID("restriction-right-grind")
        XCTAssertNil(InheritedWorkFact(
            blockCID: left,
            grindID: leftGrind,
            work: .zero
        ))
        let snapshot = InheritedWorkSnapshot(revision: 7, facts: [
            try fact(block: left, grind: leftGrind, work: 3),
            try fact(block: right, grind: rightGrind, work: 11),
        ])

        XCTAssertEqual(snapshot.blockCIDs, [left, right].sorted())
        XCTAssertTrue(snapshot.isScoped(to: [left, right]))
        XCTAssertFalse(snapshot.isScoped(to: [left]))

        let restricted = snapshot.restricted(to: [right])
        XCTAssertEqual(restricted.revision, 7)
        XCTAssertTrue(restricted.isScoped(to: [right]))
        XCTAssertTrue(restricted.sourceWork(forBlock: left).isEmpty)
        assertInheritedWorkMeasure(
            restricted.sourceWork(forBlock: right),
            equals: [rightGrind: 11]
        )
        XCTAssertTrue(snapshot.restricted(to: []).isEmpty)
    }

    func testSnapshotRoundTripUnionAndDeltaPreserveUniqueLocations() throws {
        let left = testCID("snapshot-left")
        let right = testCID("snapshot-right")
        let g1 = testCID("snapshot-g1")
        let g2 = testCID("snapshot-g2")
        let first = InheritedWorkSnapshot(revision: 3, facts: [
            try fact(block: left, grind: g1, work: 2),
        ])
        let second = InheritedWorkSnapshot(revision: 4, facts: [
            try fact(block: left, grind: g1, work: 7),
            try fact(block: right, grind: g2, work: 5),
        ])
        let joined = first.union(second)
        let decoded = try JSONDecoder().decode(
            InheritedWorkSnapshot.self,
            from: JSONEncoder().encode(joined)
        )
        let delta = joined.additions(since: first)

        XCTAssertTrue(joined.hasUniqueGrindLocations)
        XCTAssertEqual(decoded, joined)
        XCTAssertEqual(joined.revision, 4)
        XCTAssertEqual(joined.sourceWork(forBlock: left).work(forGrind: g1), UInt256(7))
        XCTAssertEqual(delta.sourceWork(forBlock: left).work(forGrind: g1), UInt256(7))
        XCTAssertEqual(delta.sourceWork(forBlock: right).work(forGrind: g2), UInt256(5))
    }

    func testSnapshotDetectsOneGrindAtTwoLocations() throws {
        let grind = testCID("invalid-location-grind")
        let snapshot = InheritedWorkSnapshot(revision: 1, facts: [
            try fact(block: testCID("invalid-location-a"), grind: grind, work: 1),
            try fact(block: testCID("invalid-location-b"), grind: grind, work: 2),
        ])

        XCTAssertFalse(snapshot.hasUniqueGrindLocations)
    }

    func testMergePermutationsMatchSlowDirectLocationGhostOracle() async throws {
        let root = testCID("oracle-root")
        let left = testCID("oracle-left")
        let right = testCID("oracle-right")
        let leftTip = testCID("oracle-left-tip")
        let rightTip = testCID("oracle-right-tip")
        let blocks = [
            BlockMeta(
                blockHash: root,
                parentBlockHash: nil,
                blockHeight: 0,
                childHashes: [left, right],
                workContributions: [
                    VerifiedWorkContribution(id: testCID("oracle-local-root"), work: UInt256(2)),
                ]
            ),
            BlockMeta(
                blockHash: left,
                parentBlockHash: root,
                blockHeight: 1,
                childHashes: [leftTip],
                workContributions: [
                    VerifiedWorkContribution(id: testCID("oracle-local-left"), work: UInt256(3)),
                ]
            ),
            BlockMeta(
                blockHash: right,
                parentBlockHash: root,
                blockHeight: 1,
                childHashes: [rightTip],
                workContributions: [
                    VerifiedWorkContribution(id: testCID("oracle-local-right"), work: UInt256(4)),
                ]
            ),
            BlockMeta(
                blockHash: leftTip,
                parentBlockHash: left,
                blockHeight: 2,
                childHashes: [],
                workContributions: [
                    VerifiedWorkContribution(id: testCID("oracle-local-left-tip"), work: UInt256(1)),
                ]
            ),
            BlockMeta(
                blockHash: rightTip,
                parentBlockHash: right,
                blockHeight: 2,
                childHashes: [],
                workContributions: [
                    VerifiedWorkContribution(id: testCID("oracle-local-right-tip"), work: UInt256(1)),
                ]
            ),
        ]
        let updates = [
            InheritedWorkSnapshot(revision: 3, facts: [
                try fact(block: leftTip, grind: testCID("oracle-parent-left"), work: 8),
            ]),
            InheritedWorkSnapshot(revision: 2, facts: [
                try fact(block: rightTip, grind: testCID("oracle-parent-right"), work: 5),
            ]),
            InheritedWorkSnapshot(revision: 3, facts: [
                try fact(block: right, grind: testCID("oracle-parent-right-base"), work: 1),
            ]),
        ]

        // Slow oracle: every unique grind contributes to its location and each
        // same-chain ancestor. Left = 3 + 1 + 8; right = 4 + 1 + 5 + 1.
        for order in permutations(updates) {
            let chain = makeChain(blocks: blocks, mainChainHashes: [root, right, rightTip])
            for update in order {
                _ = await chain.mergeInheritedWork(update)
            }

            let tip = await chain.getMainChainTip()
            let leftWeight = await chain.forkChoiceSnapshot(startingAt: left)?.subtreeWork
            let rightWeight = await chain.forkChoiceSnapshot(startingAt: right)?.subtreeWork
            let rootWeight = await chain.forkChoiceSnapshot(startingAt: root)?.subtreeWork
            XCTAssertEqual(tip, leftTip)
            XCTAssertEqual(leftWeight, WorkSum(UInt256(12)))
            XCTAssertEqual(rightWeight, WorkSum(UInt256(11)))
            XCTAssertEqual(rootWeight, WorkSum(UInt256(25)))
        }
    }
}
