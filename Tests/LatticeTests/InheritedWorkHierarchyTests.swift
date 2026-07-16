import XCTest
import UInt256
@testable import Lattice

private func hierarchyContribution(
    _ grind: String,
    _ work: UInt64
) -> VerifiedWorkContribution {
    VerifiedWorkContribution(id: grind, work: UInt256(work))
}

private func hierarchyBlock(
    hash: String,
    parent: String? = nil,
    height: UInt64,
    children: [String] = [],
    contributions: [VerifiedWorkContribution]
) -> BlockMeta {
    BlockMeta(
        blockHash: hash,
        parentBlockHash: parent,
        blockHeight: height,
        childHashes: children,
        workContributions: contributions
    )
}

final class InheritedWorkHierarchyTests: XCTestCase {
    func testImmediateParentSnapshotsRollUpThreeLevelsWithoutDoubleCounting() async throws {
        let root0 = testCID("hierarchy:root:0")
        let rootWinning = testCID("hierarchy:root:winning")
        let rootLosing = testCID("hierarchy:root:losing")
        let parent0 = testCID("hierarchy:parent:0")
        let parentWinning = testCID("hierarchy:parent:winning")
        let parentLosing = testCID("hierarchy:parent:losing")
        let child0 = testCID("hierarchy:child:0")
        let childWinning = testCID("hierarchy:child:winning")
        let childLosing = testCID("hierarchy:child:losing")
        let nextLevel = testCID("hierarchy:next-level")

        let shared = testCID("hierarchy:grind:shared")
        let rootBase = testCID("hierarchy:grind:root-base")
        let rootWin = testCID("hierarchy:grind:root-win")
        let rootLose = testCID("hierarchy:grind:root-lose")
        let parentBase = testCID("hierarchy:grind:parent-base")
        let parentWin = testCID("hierarchy:grind:parent-win")
        let parentLose = testCID("hierarchy:grind:parent-lose")
        let childBase = testCID("hierarchy:grind:child-base")
        let childWin = testCID("hierarchy:grind:child-win")
        let childLose = testCID("hierarchy:grind:child-lose")

        let root = makeChain(
            blocks: [
                hierarchyBlock(
                    hash: root0,
                    height: 0,
                    children: [rootWinning, rootLosing],
                    contributions: [
                        hierarchyContribution(shared, 6),
                        hierarchyContribution(rootBase, 2),
                    ]
                ),
                hierarchyBlock(
                    hash: rootWinning,
                    parent: root0,
                    height: 1,
                    contributions: [hierarchyContribution(rootWin, 10)]
                ),
                hierarchyBlock(
                    hash: rootLosing,
                    parent: root0,
                    height: 1,
                    contributions: [hierarchyContribution(rootLose, 1)]
                ),
            ],
            mainChainHashes: [root0, rootWinning]
        )
        _ = await root.reevaluateForkChoice()
        let rootTip = await root.getMainChainTip()
        XCTAssertEqual(rootTip, rootWinning)

        let rootExportValue = await root.inheritedWorkSnapshot(
            forChildCoverage: [
                parent0: [root0],
                parentWinning: [rootWinning],
                parentLosing: [rootLosing],
            ]
        )
        let rootExport = try XCTUnwrap(rootExportValue)
        assertInheritedWorkMeasure(
            rootExport.work(forBlock: parent0),
            equals: [shared: 6, rootBase: 2, rootWin: 10, rootLose: 1]
        )

        let parent = makeChain(
            blocks: [
                hierarchyBlock(
                    hash: parent0,
                    height: 0,
                    children: [parentWinning, parentLosing],
                    contributions: [
                        hierarchyContribution(shared, 4),
                        hierarchyContribution(parentBase, 11),
                    ]
                ),
                hierarchyBlock(
                    hash: parentWinning,
                    parent: parent0,
                    height: 1,
                    contributions: [hierarchyContribution(parentWin, 1)]
                ),
                hierarchyBlock(
                    hash: parentLosing,
                    parent: parent0,
                    height: 1,
                    contributions: [hierarchyContribution(parentLose, 5)]
                ),
            ],
            mainChainHashes: [parent0, parentWinning]
        )
        _ = await parent.reevaluateForkChoice()
        let localParentTip = await parent.getMainChainTip()
        XCTAssertEqual(localParentTip, parentLosing)

        _ = await parent.setInheritedWorkProvider { rootExport }
        let parentTip = await parent.getMainChainTip()
        let losingParentIsCanonical = await parent.isOnMainChain(hash: parentLosing)
        XCTAssertEqual(parentTip, parentWinning)
        XCTAssertFalse(losingParentIsCanonical)

        let parentExportValue = await parent.inheritedWorkSnapshot(
            forChildCoverage: [
                child0: [parent0],
                childWinning: [parentWinning],
                childLosing: [parentLosing],
            ]
        )
        let parentExport = try XCTUnwrap(parentExportValue)
        let inheritedAtChildRoot = parentExport.work(forBlock: child0)
        assertInheritedWorkMeasure(
            inheritedAtChildRoot,
            equals: [
                shared: 6,
                rootBase: 2,
                rootWin: 10,
                rootLose: 1,
                parentBase: 11,
                parentWin: 1,
                parentLose: 5,
            ]
        )
        XCTAssertEqual(inheritedAtChildRoot.work(forGrind: parentLose), UInt256(5))

        let child = makeChain(
            blocks: [
                hierarchyBlock(
                    hash: child0,
                    height: 0,
                    children: [childWinning, childLosing],
                    contributions: [
                        hierarchyContribution(shared, 6),
                        hierarchyContribution(childBase, 17),
                    ]
                ),
                hierarchyBlock(
                    hash: childWinning,
                    parent: child0,
                    height: 1,
                    contributions: [hierarchyContribution(childWin, 1)]
                ),
                hierarchyBlock(
                    hash: childLosing,
                    parent: child0,
                    height: 1,
                    contributions: [hierarchyContribution(childLose, 5)]
                ),
            ],
            mainChainHashes: [child0, childWinning]
        )
        _ = await child.reevaluateForkChoice()
        let localChildTip = await child.getMainChainTip()
        XCTAssertEqual(localChildTip, childLosing)

        _ = await child.setInheritedWorkProvider { parentExport }
        let childTip = await child.getMainChainTip()
        XCTAssertEqual(childTip, childWinning)

        let finalExportValue = await child.inheritedWorkSnapshot(
            forChildCoverage: [nextLevel: [child0]]
        )
        let finalMeasure = try XCTUnwrap(finalExportValue).work(forBlock: nextLevel)
        let expected = InheritedWorkOracle([
            InheritedWorkOracleInput(
                revision: 0,
                facts: [
                    .init(block: nextLevel, grind: shared, work: 6),
                    .init(block: nextLevel, grind: rootBase, work: 2),
                    .init(block: nextLevel, grind: rootWin, work: 10),
                    .init(block: nextLevel, grind: rootLose, work: 1),
                    .init(block: nextLevel, grind: shared, work: 4),
                    .init(block: nextLevel, grind: parentBase, work: 11),
                    .init(block: nextLevel, grind: parentWin, work: 1),
                    .init(block: nextLevel, grind: parentLose, work: 5),
                    .init(block: nextLevel, grind: shared, work: 6),
                    .init(block: nextLevel, grind: childBase, work: 17),
                    .init(block: nextLevel, grind: childWin, work: 1),
                    .init(block: nextLevel, grind: childLose, work: 5),
                ]
            ),
        ]).measure(for: nextLevel)

        assertInheritedWorkMeasure(finalMeasure, equals: expected)
        XCTAssertEqual(finalMeasure.work(forGrind: shared), UInt256(6))
        XCTAssertEqual(finalMeasure.grindIDs.count, 10)
        XCTAssertEqual(finalMeasure.total, WorkSum(UInt256(59)))
    }
}
