import XCTest
@testable import Lattice
import UInt256

final class ConsensusSegmentedWorkTests: XCTestCase {
    func testSegmentContributionCanInstallOneCheckedRun() {
        let store = InheritedWeightStore()
        store.recordVerifiedWorkSegment(
            ConsensusWorkSegment(
                baseHash: "P10",
                tipHash: "P20",
                startWork: UInt256(10),
                endWork: UInt256(110)
            ),
            committingChild: "C"
        )
        store.recordVerifiedWorkSegment(
            ConsensusWorkSegment(
                baseHash: "P10",
                tipHash: "P20",
                startWork: UInt256(10),
                endWork: UInt256(110)
            ),
            committingChild: "C"
        )

        XCTAssertEqual(store.inheritedWeight(forChild: "C"), UInt256(100))
    }

    // MARK: - Hierarchical-GHOST faithfulness: each grinding block counted ONCE

    /// T3 (load-bearing). A child C committed by TWO parent-fork carriers that
    /// share a prefix cone {s1,s2} and diverge into disjoint fork blocks {x},{y}.
    /// Faithful Hierarchical GHOST = union, each grinding block once =
    /// ws1+ws2+wx+wy. It must be NEITHER the sum of the carriers' trueCumWorks
    /// (double-counts the shared prefix) NOR the max (the prefix-interval-merge
    /// reduction, which drops the lighter fork — the longest-chain reduction).
    func testCrossForkCommittersUnionEachBlockOnce() {
        let store = InheritedWeightStore()
        let ws1 = UInt256(2), ws2 = UInt256(3), wx = UInt256(5), wy = UInt256(7)

        // Carrier on fork X commits C: shared prefix {s1,s2} + disjoint {x}.
        store.recordVerifiedWorkContributions(
            [(id: "s1", work: ws1), (id: "s2", work: ws2), (id: "x", work: wx)],
            committingChild: "C"
        )
        // Carrier on fork Y commits the SAME C: shared prefix {s1,s2} + disjoint {y}.
        store.recordVerifiedWorkContributions(
            [(id: "s1", work: ws1), (id: "s2", work: ws2), (id: "y", work: wy)],
            committingChild: "C"
        )

        let faithfulUnion = ws1 &+ ws2 &+ wx &+ wy            // 17 — each block once
        let sumOfTrueCumWorks = (ws1 &+ ws2 &+ wx) &+ (ws1 &+ ws2 &+ wy) // 22 — double-counts {s1,s2}
        let maxReduction = ws1 &+ ws2 &+ (wx > wy ? wx : wy)  // 12 — drops the lighter fork

        XCTAssertEqual(store.inheritedWeight(forChild: "C"), faithfulUnion,
                       "inherited weight must be the union, each grinding block counted once")
        XCTAssertNotEqual(store.inheritedWeight(forChild: "C"), sumOfTrueCumWorks,
                          "must NOT double-count the shared prefix cone")
        XCTAssertNotEqual(store.inheritedWeight(forChild: "C"), maxReduction,
                          "must NOT drop a disjoint fork (that is the longest-chain reduction, not GHOST)")
    }

    /// T5a. A purely-anchored carrier (zero own grind) adds nothing.
    func testPureAnchorCarrierAddsZero() {
        let store = InheritedWeightStore()
        store.recordVerifiedWorkContributions([(id: "g", work: UInt256(9))], committingChild: "C")
        let before = store.inheritedWeight(forChild: "C")
        let changed = store.recordVerifiedWorkContributions(
            [(id: "pureAnchor", work: .zero)], committingChild: "C"
        )
        XCTAssertFalse(changed, "a zero-grind carrier is a no-op")
        XCTAssertEqual(store.inheritedWeight(forChild: "C"), before)
    }

    /// T5b. The same physical grind (same block CID) referenced by two different
    /// carriers is counted exactly once, never doubled.
    func testSameGrindAcrossTwoCarriersCountedOnce() {
        let store = InheritedWeightStore()
        let wg = UInt256(11)
        store.recordVerifiedWorkContributions([(id: "g", work: wg)], committingChild: "C")
        store.recordVerifiedWorkContributions([(id: "g", work: wg)], committingChild: "C")
        XCTAssertEqual(store.inheritedWeight(forChild: "C"), wg,
                       "the same grinding block must be counted once across carriers")
    }

    func testOverlappingLinearSegmentsDedupeByRepeatedBlockHash() {
        let store = InheritedWeightStore()
        store.recordVerifiedWorkSegments(
            [
                ConsensusWorkSegment(
                    headHash: "P1",
                    baseHash: nil,
                    tipHash: "P2",
                    blocks: ["P1", "P2"],
                    cumulativeWorkByBlock: [
                        "P1": UInt256(50),
                        "P2": UInt256(100),
                    ],
                    startWork: UInt256(0),
                    endWork: UInt256(100)
                ),
                ConsensusWorkSegment(
                    headHash: "P2",
                    baseHash: "P50",
                    tipHash: "P3",
                    blocks: ["P2", "P3"],
                    cumulativeWorkByBlock: [
                        "P2": UInt256(100),
                        "P3": UInt256(150),
                    ],
                    startWork: UInt256(50),
                    endWork: UInt256(150)
                ),
            ],
            committingChild: "C"
        )

        XCTAssertEqual(store.inheritedWeight(forChild: "C"), UInt256(150))
    }

    func testForkSiblingSegmentsWithOverlappingPrefixCoordinatesBothCount() {
        let store = InheritedWeightStore()
        store.recordVerifiedWorkSegments(
            [
                ConsensusWorkSegment(
                    headHash: "P",
                    baseHash: nil,
                    tipHash: "P",
                    blocks: ["P"],
                    cumulativeWorkByBlock: [
                        "P": UInt256(2)
                    ],
                    startWork: UInt256(0),
                    endWork: UInt256(2),
                    children: [
                        ConsensusWorkSegment(
                            headHash: "A",
                            baseHash: "P",
                            tipHash: "A",
                            blocks: ["A"],
                            cumulativeWorkByBlock: [
                                "A": UInt256(5)
                            ],
                            startWork: UInt256(2),
                            endWork: UInt256(5)
                        ),
                        ConsensusWorkSegment(
                            headHash: "B",
                            baseHash: "P",
                            tipHash: "B",
                            blocks: ["B"],
                            cumulativeWorkByBlock: [
                                "B": UInt256(7)
                            ],
                            startWork: UInt256(2),
                            endWork: UInt256(7)
                        ),
                    ]
                ),
            ],
            committingChild: "C"
        )

        XCTAssertEqual(
            store.inheritedWeight(forChild: "C"),
            UInt256(10),
            "sibling forks share numeric prefix coordinates but represent distinct block work"
        )
    }

    func testSameSegmentTreeRecordedTwiceIsDedupedByBlockHash() {
        let store = InheritedWeightStore()
        let segment = ConsensusWorkSegment(
            headHash: "P",
            baseHash: nil,
            tipHash: "P",
            blocks: ["P"],
            cumulativeWorkByBlock: ["P": UInt256(2)],
            startWork: UInt256(0),
            endWork: UInt256(2),
            children: [
                ConsensusWorkSegment(
                    headHash: "A",
                    baseHash: "P",
                    tipHash: "A",
                    blocks: ["A"],
                    cumulativeWorkByBlock: ["A": UInt256(5)],
                    startWork: UInt256(2),
                    endWork: UInt256(5)
                ),
            ]
        )

        XCTAssertTrue(store.recordVerifiedWorkSegments([segment], committingChild: "C"))
        XCTAssertFalse(store.recordVerifiedWorkSegments([segment], committingChild: "C"))
        XCTAssertEqual(store.inheritedWeight(forChild: "C"), UInt256(5))
    }

    func testTipExtensionRecordsOnlyNewWorkAfterCoveredPrefix() {
        let store = InheritedWeightStore()
        let prefix = ConsensusWorkSegment(
            headHash: "P1",
            baseHash: nil,
            tipHash: "P2",
            blocks: ["P1", "P2"],
            cumulativeWorkByBlock: [
                "P1": UInt256(50),
                "P2": UInt256(100),
            ],
            startWork: UInt256(0),
            endWork: UInt256(100)
        )
        let extended = ConsensusWorkSegment(
            headHash: "P1",
            baseHash: nil,
            tipHash: "P3",
            blocks: ["P1", "P2", "P3"],
            cumulativeWorkByBlock: [
                "P1": UInt256(50),
                "P2": UInt256(100),
                "P3": UInt256(150),
            ],
            startWork: UInt256(0),
            endWork: UInt256(150)
        )

        XCTAssertTrue(store.recordVerifiedWorkSegment(prefix, committingChild: "C"))
        XCTAssertTrue(store.recordVerifiedWorkSegment(extended, committingChild: "C"))

        XCTAssertEqual(store.inheritedWeight(forChild: "C"), UInt256(150))
    }

    func testSegmentCoverageCanBeLearnedEvenWhenBlocksWereAlreadyContributed() {
        let store = InheritedWeightStore()
        let prefix = ConsensusWorkSegment(
            headHash: "P1",
            baseHash: nil,
            tipHash: "P2",
            blocks: ["P1", "P2"],
            cumulativeWorkByBlock: [
                "P1": UInt256(50),
                "P2": UInt256(100),
            ],
            startWork: UInt256(0),
            endWork: UInt256(100)
        )
        let extended = ConsensusWorkSegment(
            headHash: "P1",
            baseHash: nil,
            tipHash: "P3",
            blocks: ["P1", "P2", "P3"],
            cumulativeWorkByBlock: [
                "P1": UInt256(50),
                "P2": UInt256(100),
                "P3": UInt256(150),
            ],
            startWork: UInt256(0),
            endWork: UInt256(150)
        )

        XCTAssertTrue(store.recordVerifiedParentWork(UInt256(50), parentBlockHash: "P1", committingChild: "C"))
        XCTAssertTrue(store.recordVerifiedParentWork(UInt256(50), parentBlockHash: "P2", committingChild: "C"))
        XCTAssertFalse(store.recordVerifiedWorkSegment(prefix, committingChild: "C"))
        XCTAssertTrue(store.recordVerifiedWorkSegment(extended, committingChild: "C"))

        XCTAssertEqual(store.inheritedWeight(forChild: "C"), UInt256(150))
    }

    func testDuplicateContributorDoesNotInflateWeight() {
        let store = InheritedWeightStore()

        XCTAssertTrue(store.recordVerifiedParentWork(UInt256(50), parentBlockHash: "P1", committingChild: "C"))
        XCTAssertFalse(store.recordVerifiedParentWork(UInt256(50), parentBlockHash: "P1", committingChild: "C"))

        XCTAssertEqual(store.inheritedWeight(forChild: "C"), UInt256(50))
        XCTAssertEqual(store.totalParentWork, UInt256(50))
    }

    func testSameContributorCanCreditDifferentChildrenIndependently() {
        let store = InheritedWeightStore()

        XCTAssertTrue(store.recordVerifiedParentWork(UInt256(10), parentBlockHash: "P1", committingChild: "C1"))
        XCTAssertTrue(store.recordVerifiedParentWork(UInt256(10), parentBlockHash: "P1", committingChild: "C2"))

        XCTAssertEqual(store.inheritedWeight(forChild: "C1"), UInt256(10))
        XCTAssertEqual(store.inheritedWeight(forChild: "C2"), UInt256(10))
        XCTAssertEqual(store.totalParentWork, UInt256(20))
    }

    func testUnknownChildInheritsZero() {
        let store = InheritedWeightStore()
        store.recordVerifiedParentWork(UInt256(5), parentBlockHash: "P1", committingChild: "C")

        XCTAssertEqual(store.inheritedWeight(forChild: "UNKNOWN"), .zero)
    }

    func testProviderReadsStore() {
        let store = InheritedWeightStore()
        let provider = store.makeProvider()

        XCTAssertEqual(provider("C"), .zero)
        store.recordVerifiedParentWork(UInt256(42), parentBlockHash: "P1", committingChild: "C")

        XCTAssertEqual(provider("C"), UInt256(42))
        XCTAssertEqual(provider("missing"), .zero)
    }

    func testEmptyNilAndZeroWorkInputsAreNoOps() {
        let store = InheritedWeightStore()

        XCTAssertFalse(store.recordVerifiedWorkContributions([], committingChild: "C"))
        XCTAssertFalse(store.recordVerifiedParentWork(UInt256(10), parentBlockHash: "P1", committingChild: nil))
        XCTAssertFalse(store.recordVerifiedWorkContributions([(id: "P1", work: .zero)], committingChild: "C"))
        XCTAssertFalse(store.recordVerifiedWorkSegments([], committingChild: "C"))
        XCTAssertFalse(store.recordVerifiedWorkSegment(
            ConsensusWorkSegment(baseHash: nil, tipHash: "P1", startWork: UInt256(7), endWork: UInt256(7)),
            committingChild: "C"
        ))

        XCTAssertEqual(store.inheritedWeight(forChild: "C"), .zero)
        XCTAssertEqual(store.totalParentWork, .zero)
    }

    func testInheritedWeightSaturatesAtUInt256Max() {
        let store = InheritedWeightStore()

        store.recordVerifiedWorkContributions(
            [
                (id: "P1", work: UInt256.max),
                (id: "P2", work: UInt256(1)),
            ],
            committingChild: "C"
        )

        XCTAssertEqual(store.inheritedWeight(forChild: "C"), UInt256.max)
        XCTAssertEqual(store.totalParentWork, UInt256.max)
    }

    func testContributionsAndSegmentsCrossDedupeByBlockHash() {
        let store = InheritedWeightStore()
        let segment = ConsensusWorkSegment(
            headHash: "P1",
            baseHash: nil,
            tipHash: "P1",
            blocks: ["P1"],
            cumulativeWorkByBlock: ["P1": UInt256(50)],
            startWork: UInt256(0),
            endWork: UInt256(50)
        )

        XCTAssertTrue(store.recordVerifiedParentWork(UInt256(50), parentBlockHash: "P1", committingChild: "C"))
        XCTAssertFalse(store.recordVerifiedWorkSegment(segment, committingChild: "C"))

        XCTAssertEqual(store.inheritedWeight(forChild: "C"), UInt256(50))
    }

    func testSegmentRecordingRejectsInconsistentCumulativeWorkMap() {
        let store = InheritedWeightStore()
        let wrongEnd = ConsensusWorkSegment(
            headHash: "P1",
            baseHash: nil,
            tipHash: "P1",
            blocks: ["P1"],
            cumulativeWorkByBlock: ["P1": UInt256(40)],
            startWork: UInt256(0),
            endWork: UInt256(50)
        )
        let wrongBlock = ConsensusWorkSegment(
            headHash: "P1",
            baseHash: nil,
            tipHash: "P1",
            blocks: ["P1"],
            cumulativeWorkByBlock: ["other": UInt256(50)],
            startWork: UInt256(0),
            endWork: UInt256(50)
        )
        let decreasing = ConsensusWorkSegment(
            headHash: "P1",
            baseHash: nil,
            tipHash: "P1",
            blocks: ["P1"],
            cumulativeWorkByBlock: ["P1": UInt256(40)],
            startWork: UInt256(50),
            endWork: UInt256(40)
        )

        XCTAssertFalse(store.recordVerifiedWorkSegment(wrongEnd, committingChild: "C"))
        XCTAssertFalse(store.recordVerifiedWorkSegment(wrongBlock, committingChild: "C"))
        XCTAssertFalse(store.recordVerifiedWorkSegment(decreasing, committingChild: "C"))
        XCTAssertEqual(store.inheritedWeight(forChild: "C"), .zero)
    }

    func testSegmentRecordingRejectsDuplicateBlocksInOrderedPath() {
        let store = InheritedWeightStore()
        let duplicatePath = ConsensusWorkSegment(
            headHash: "P1",
            baseHash: nil,
            tipHash: "P2",
            blocks: ["P1", "P1", "P2"],
            cumulativeWorkByBlock: [
                "P1": UInt256(50),
                "P2": UInt256(100),
            ],
            startWork: UInt256(0),
            endWork: UInt256(100)
        )

        XCTAssertFalse(store.recordVerifiedWorkSegment(duplicatePath, committingChild: "C"))
        XCTAssertEqual(store.inheritedWeight(forChild: "C"), .zero)
    }

    func testInvalidChildSegmentDoesNotPartiallyRecordParentWork() {
        let store = InheritedWeightStore()
        let segment = ConsensusWorkSegment(
            headHash: "P",
            baseHash: nil,
            tipHash: "P",
            blocks: ["P"],
            cumulativeWorkByBlock: ["P": UInt256(2)],
            startWork: UInt256(0),
            endWork: UInt256(2),
            children: [
                ConsensusWorkSegment(
                    headHash: "A",
                    baseHash: "P",
                    tipHash: "A",
                    blocks: ["A"],
                    cumulativeWorkByBlock: ["wrong": UInt256(5)],
                    startWork: UInt256(2),
                    endWork: UInt256(5)
                ),
            ]
        )

        XCTAssertFalse(store.recordVerifiedWorkSegment(segment, committingChild: "C"))
        XCTAssertEqual(store.inheritedWeight(forChild: "C"), .zero)
    }

    func testObservedWorkBuildsRunsBetweenForks() {
        let graph: [String: ConsensusWorkNode] = [
            "G": ConsensusWorkNode(parent: nil, heightLocalWork: 1, cumulativeWork: 1),
            "A": ConsensusWorkNode(parent: "G", heightLocalWork: 2, cumulativeWork: 3),
            "B": ConsensusWorkNode(parent: "A", heightLocalWork: 3, cumulativeWork: 6),
            "C": ConsensusWorkNode(parent: "B", heightLocalWork: 4, cumulativeWork: 10),
            "D": ConsensusWorkNode(parent: "B", heightLocalWork: 5, cumulativeWork: 11),
            "E": ConsensusWorkNode(parent: "D", heightLocalWork: 6, cumulativeWork: 17),
        ]

        let runs = ConsensusSegmentedWork.observedRuns(for: "G", graph: graph)

        XCTAssertEqual(
            runs,
            [
                ConsensusWorkRun(head: "G", tail: "B", blocks: ["G", "A", "B"], work: UInt256(6)),
                ConsensusWorkRun(head: "C", tail: "C", blocks: ["C"], work: UInt256(4)),
                ConsensusWorkRun(head: "D", tail: "E", blocks: ["D", "E"], work: UInt256(11)),
            ]
        )
        XCTAssertEqual(ConsensusSegmentedWork.observedTotalWork(for: "G", graph: graph), UInt256(21))
    }

    func testLinearChainBuildsOneSegmentWithCachedCumulativeWork() {
        let graph: [String: ConsensusWorkNode] = [
            "A": ConsensusWorkNode(parent: nil, heightLocalWork: 2, cumulativeWork: 2),
            "B": ConsensusWorkNode(parent: "A", heightLocalWork: 3, cumulativeWork: 5),
            "C": ConsensusWorkNode(parent: "B", heightLocalWork: 5, cumulativeWork: 10),
            "D": ConsensusWorkNode(parent: "C", heightLocalWork: 7, cumulativeWork: 17),
        ]

        let segment = ConsensusSegmentedWork.segmentTree(for: "A", graph: graph)

        XCTAssertEqual(segment?.blocks, ["A", "B", "C", "D"])
        XCTAssertEqual(segment?.cumulativeWorkByBlock, [
            "A": UInt256(2),
            "B": UInt256(5),
            "C": UInt256(10),
            "D": UInt256(17),
        ])
        XCTAssertEqual(segment?.children, [])
        XCTAssertEqual(segment?.totalWork, UInt256(17))
    }

    func testTotalWorkFromInteriorBlockUsesCumulativeWorkSubtraction() {
        let graph: [String: ConsensusWorkNode] = [
            "G": ConsensusWorkNode(parent: nil, heightLocalWork: 1, cumulativeWork: 1),
            "A": ConsensusWorkNode(parent: "G", heightLocalWork: 2, cumulativeWork: 3),
            "B": ConsensusWorkNode(parent: "A", heightLocalWork: 3, cumulativeWork: 6),
            "C": ConsensusWorkNode(parent: "B", heightLocalWork: 4, cumulativeWork: 10),
            "D": ConsensusWorkNode(parent: "B", heightLocalWork: 5, cumulativeWork: 11),
            "E": ConsensusWorkNode(parent: "D", heightLocalWork: 6, cumulativeWork: 17),
        ]

        let segment = ConsensusSegmentedWork.segmentTree(for: "G", graph: graph)

        XCTAssertEqual(segment?.totalWork(startingAt: "G"), UInt256(21))
        XCTAssertEqual(segment?.totalWork(startingAt: "A"), UInt256(20))
        XCTAssertEqual(segment?.totalWork(startingAt: "B"), UInt256(18))
        XCTAssertEqual(segment?.totalWork(startingAt: "C"), UInt256(4))
        XCTAssertEqual(segment?.totalWork(startingAt: "D"), UInt256(11))
        XCTAssertEqual(segment?.totalWork(startingAt: "E"), UInt256(6))
        XCTAssertNil(segment?.totalWork(startingAt: "missing"))
    }

    func testNestedForkSegmentsRecurseOnlyAtForkBoundaries() {
        let graph: [String: ConsensusWorkNode] = [
            "P": ConsensusWorkNode(parent: nil, heightLocalWork: 1, cumulativeWork: 1),
            "A": ConsensusWorkNode(parent: "P", heightLocalWork: 2, cumulativeWork: 3),
            "B": ConsensusWorkNode(parent: "A", heightLocalWork: 3, cumulativeWork: 6),
            "C": ConsensusWorkNode(parent: "B", heightLocalWork: 5, cumulativeWork: 11),
            "C1": ConsensusWorkNode(parent: "C", heightLocalWork: 7, cumulativeWork: 18),
            "D": ConsensusWorkNode(parent: "B", heightLocalWork: 11, cumulativeWork: 17),
            "D1": ConsensusWorkNode(parent: "D", heightLocalWork: 13, cumulativeWork: 30),
            "E": ConsensusWorkNode(parent: "D1", heightLocalWork: 17, cumulativeWork: 47),
            "F": ConsensusWorkNode(parent: "D1", heightLocalWork: 19, cumulativeWork: 49),
        ]

        let segment = ConsensusSegmentedWork.segmentTree(for: "P", graph: graph)

        XCTAssertEqual(segment?.blocks, ["P", "A", "B"])
        XCTAssertEqual(segment?.children.map(\.blocks), [["C", "C1"], ["D", "D1"]])
        XCTAssertEqual(segment?.children.last?.children.map(\.blocks), [["E"], ["F"]])
        XCTAssertEqual(segment?.totalWork, UInt256(78))
        XCTAssertEqual(segment?.totalWork(startingAt: "D"), UInt256(60))
        XCTAssertEqual(segment?.totalWork(startingAt: "D1"), UInt256(49))
        XCTAssertEqual(segment?.totalWork(startingAt: "F"), UInt256(19))
    }

    func testSegmentTreeRejectsCycles() {
        let graph: [String: ConsensusWorkNode] = [
            "A": ConsensusWorkNode(parent: "B", heightLocalWork: 1, cumulativeWork: 2),
            "B": ConsensusWorkNode(parent: "A", heightLocalWork: 1, cumulativeWork: 3),
        ]

        XCTAssertNil(ConsensusSegmentedWork.segmentTree(for: "A", graph: graph))
        XCTAssertNil(ConsensusSegmentedWork.observedRuns(for: "A", graph: graph))
    }

    func testInteriorWorkFailsClosedWithoutRequiredCumulativeWork() {
        let segment = ConsensusWorkSegment(
            headHash: "A",
            baseHash: nil,
            tipHash: "C",
            blocks: ["A", "B", "C"],
            cumulativeWorkByBlock: ["A": UInt256(1)],
            startWork: UInt256(0),
            endWork: UInt256(6)
        )

        XCTAssertNil(segment.totalWork(startingAt: "A"))
        XCTAssertNil(segment.totalWork(startingAt: "C"))
    }

    func testInteriorWorkFailsClosedWithInconsistentCumulativeWorkMapping() {
        let wrongEnd = ConsensusWorkSegment(
            headHash: "A",
            baseHash: nil,
            tipHash: "A",
            blocks: ["A"],
            cumulativeWorkByBlock: ["A": UInt256(5)],
            startWork: UInt256(0),
            endWork: UInt256(7)
        )
        let wrongBlock = ConsensusWorkSegment(
            headHash: "A",
            baseHash: nil,
            tipHash: "A",
            blocks: ["A"],
            cumulativeWorkByBlock: ["other": UInt256(5)],
            startWork: UInt256(0),
            endWork: UInt256(5)
        )

        XCTAssertNil(wrongEnd.totalWork(startingAt: "A"))
        XCTAssertNil(wrongBlock.totalWork(startingAt: "A"))
    }

    func testInheritedSegmentsUseCumulativeWorkByBlockAcrossForks() {
        let graph: [String: ConsensusWorkNode] = [
            "P": ConsensusWorkNode(parent: nil, heightLocalWork: 2, cumulativeWork: 2),
            "A": ConsensusWorkNode(parent: "P", heightLocalWork: 3, cumulativeWork: 5),
            "B": ConsensusWorkNode(parent: "P", heightLocalWork: 5, cumulativeWork: 7),
            "B1": ConsensusWorkNode(parent: "B", heightLocalWork: 7, cumulativeWork: 14),
        ]

        let segments = ConsensusSegmentedWork.inheritedSegments(
            for: "P",
            graph: graph
        )

        XCTAssertEqual(
            segments,
            [
                ConsensusWorkSegment(
                    headHash: "P",
                    baseHash: nil,
                    tipHash: "P",
                    blocks: ["P"],
                    cumulativeWorkByBlock: [
                        "P": UInt256(2)
                    ],
                    startWork: UInt256(0),
                    endWork: UInt256(2),
                    children: [
                        ConsensusWorkSegment(
                            headHash: "A",
                            baseHash: "P",
                            tipHash: "A",
                            blocks: ["A"],
                            cumulativeWorkByBlock: [
                                "A": UInt256(5)
                            ],
                            startWork: UInt256(2),
                            endWork: UInt256(5)
                        ),
                        ConsensusWorkSegment(
                            headHash: "B",
                            baseHash: "P",
                            tipHash: "B1",
                            blocks: ["B", "B1"],
                            cumulativeWorkByBlock: [
                                "B": UInt256(7),
                                "B1": UInt256(14),
                            ],
                            startWork: UInt256(2),
                            endWork: UInt256(14)
                        ),
                    ]
                ),
            ]
        )
        XCTAssertEqual(segments?.first?.totalWork, UInt256(17))
        XCTAssertEqual(segments?.first?.children.last?.cachedCumulativeWork(for: "B"), UInt256(7))
    }
}

private extension ConsensusWorkNode {
    init(parent: String?, heightLocalWork: UInt64, cumulativeWork: UInt64) {
        self.init(parent: parent, localWork: UInt256(heightLocalWork), cumulativeWork: UInt256(cumulativeWork))
    }
}
