import XCTest
import UInt256
@testable import Lattice

final class InheritedWorkScaleTests: XCTestCase {
    func testLongChainDirectWorkProjectionAndRestoreStayDepthSafe() async throws {
        let count = 2_500
        let hashes = (0..<count).map { testCID("long-direct-block-\($0)") }
        let grinds = (0..<count).map { testCID("long-direct-grind-\($0)") }
        let blocks = (0..<count).map { index in
            BlockMeta(
                blockHash: hashes[index],
                parentBlockHash: index == 0 ? nil : hashes[index - 1],
                blockHeight: UInt64(index),
                childHashes: index + 1 == count ? [] : [hashes[index + 1]],
                workContributions: [
                    VerifiedWorkContribution(id: grinds[index], work: UInt256(1)),
                ]
            )
        }
        let started = ContinuousClock.now

        let chain = makeChain(blocks: blocks)
        let restored = try ChainState.restore(from: await chain.persist())
        let rootWeight = await restored.subtreeWeight(forHash: hashes[0])
        let tip = await restored.getMainChainTip()
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(rootWeight, WorkSum(UInt256(UInt64(count))))
        XCTAssertEqual(tip, hashes.last)
        XCTAssertLessThan(elapsed, .seconds(15))
    }

    func testThousandsOfExactParentChildBindingsRemainOneFactPerGrind() async throws {
        let count = 5_000
        let parentBlocks = (0..<count).map { testCID("bulk-parent-\($0)") }
        let childBlocks = (0..<count).map { testCID("bulk-child-\($0)") }
        let grinds = (0..<count).map { testCID("bulk-grind-\($0)") }
        let facts = try (0..<count).map { index in
            try XCTUnwrap(InheritedWorkFact(
                blockCID: parentBlocks[index],
                grindID: grinds[index],
                work: UInt256(1)
            ))
        }
        let parent = InheritedWorkSnapshot(revision: 1, facts: facts)
        let child = makeChain(blocks: (0..<count).map { index in
            BlockMeta(
                blockHash: childBlocks[index],
                parentBlockHash: index == 0 ? nil : childBlocks[index - 1],
                blockHeight: UInt64(index),
                childHashes: index + 1 == count ? [] : [childBlocks[index + 1]],
                workContributions: [
                    VerifiedWorkContribution(
                        id: testCID("bulk-local-\(index)"),
                        work: UInt256(1)
                    ),
                ]
            )
        })
        let bindings = Dictionary(uniqueKeysWithValues: (0..<count).map {
            (childBlocks[$0], Set([parentBlocks[$0]]))
        })
        let started = ContinuousClock.now

        let projectedValue = await child.inheritedWorkSnapshot(
            from: parent,
            parentCarrierBlocksByChildBlock: bindings
        )
        let projected = try XCTUnwrap(projectedValue)
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(projected.blockCIDs.count, count)
        XCTAssertEqual(projected.blockCIDs.reduce(0) {
            $0 + projected.sourceWork(forBlock: $1).grindIDs.count
        }, count)
        XCTAssertLessThan(elapsed, .seconds(15))
    }

    func testTipWorkUpdatesDoNotRebuildLinearHistory() async {
        let blockCount = 2_500
        let updateCount = 64
        let hashes = (0..<blockCount).map { testCID("incremental-block-\($0)") }
        let blocks = (0..<blockCount).map { index in
            BlockMeta(
                blockHash: hashes[index],
                parentBlockHash: index == 0 ? nil : hashes[index - 1],
                blockHeight: UInt64(index),
                childHashes: index + 1 == blockCount ? [] : [hashes[index + 1]],
                workContributions: [
                    VerifiedWorkContribution(
                        id: testCID("incremental-base-\(index)"),
                        work: UInt256(1)
                    ),
                ]
            )
        }
        let chain = makeChain(blocks: blocks)
        let started = ContinuousClock.now

        for index in 0..<updateCount {
            let result = await chain.addWorkContribution(
                VerifiedWorkContribution(
                    id: testCID("incremental-extra-\(index)"),
                    work: UInt256(1)
                ),
                to: hashes[blockCount - 1]
            )
            XCTAssertTrue(result.addedContribution)
        }
        let elapsed = started.duration(to: .now)
        let rootWeight = await chain.subtreeWeight(forHash: hashes[0])

        XCTAssertEqual(
            rootWeight,
            WorkSum(UInt256(UInt64(blockCount + updateCount)))
        )
        XCTAssertLessThan(elapsed, .seconds(15))
    }

    func testForkLadderTipUpdatesTouchOnlyFenwickCells() async {
        let mainCount = 1_000
        let updateCount = 128
        let main = (0..<mainCount).map { testCID("fork-ladder-main-\($0)") }
        let sides = (0..<(mainCount - 1)).map {
            testCID("fork-ladder-side-\($0)")
        }
        var blocks: [BlockMeta] = []
        for index in 0..<mainCount {
            var children: [String] = []
            if index + 1 < mainCount {
                children = [main[index + 1], sides[index]]
            }
            blocks.append(BlockMeta(
                blockHash: main[index],
                parentBlockHash: index == 0 ? nil : main[index - 1],
                blockHeight: UInt64(index),
                childHashes: children,
                workContributions: [VerifiedWorkContribution(
                    id: testCID("fork-ladder-main-work-\(index)"),
                    work: UInt256(1)
                )]
            ))
            if index + 1 < mainCount {
                blocks.append(BlockMeta(
                    blockHash: sides[index],
                    parentBlockHash: main[index],
                    blockHeight: UInt64(index + 1),
                    childHashes: [],
                    workContributions: [VerifiedWorkContribution(
                        id: testCID("fork-ladder-side-work-\(index)"),
                        work: UInt256(1)
                    )]
                ))
            }
        }
        let chain = makeChain(blocks: blocks)
        let tip = await chain.getMainChainTip()
        let rebuildsBefore = await chain.segmentCacheRebuildCount
        let projectionsBefore = await chain.fullCanonicalProjectionCount
        let cellsBefore = await chain.segmentWorkUpdateCellCount

        for index in 0..<updateCount {
            let result = await chain.addWorkContribution(
                VerifiedWorkContribution(
                    id: testCID("fork-ladder-tip-update-\(index)"),
                    work: UInt256(1)
                ),
                to: tip
            )
            XCTAssertTrue(result.addedContribution)
        }

        let segmentCount = mainCount * 2 - 1
        var maximumCellsPerUpdate = 1
        var power = 1
        while power < segmentCount {
            power <<= 1
            maximumCellsPerUpdate += 1
        }
        let cellsAfter = await chain.segmentWorkUpdateCellCount
        let rebuildsAfter = await chain.segmentCacheRebuildCount
        let projectionsAfter = await chain.fullCanonicalProjectionCount
        let cells = cellsAfter - cellsBefore
        XCTAssertLessThanOrEqual(
            cells,
            UInt64(updateCount * maximumCellsPerUpdate)
        )
        XCTAssertEqual(rebuildsAfter, rebuildsBefore)
        XCTAssertEqual(projectionsAfter, projectionsBefore)
    }
}
