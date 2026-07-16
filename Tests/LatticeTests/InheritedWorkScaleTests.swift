import XCTest
import UInt256
@testable import Lattice

final class InheritedWorkScaleTests: XCTestCase {
    func testLongChainProjectionExportAndRestoreStayDepthSafe() async throws {
        let blockCount = 2_500
        let inheritedGrindCount = 128
        let hashes = (0..<blockCount).map { testCID("scale-\($0)") }
        let uniqueGrinds = (0..<blockCount).map { testCID("scale-unique-\($0)") }
        let inheritedGrinds = (0..<inheritedGrindCount).map {
            testCID("scale-inherited-\($0)")
        }
        let sharedGrind = testCID("scale-shared")
        let exportedChild = testCID("scale-child")
        let inherited = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                hashes[blockCount - 1]: WorkMeasure(inheritedGrinds.map {
                    VerifiedWorkContribution(
                        id: $0,
                        work: UInt256(1)
                    )
                }),
            ]
        )

        let clock = ContinuousClock()
        let started = clock.now
        var blocks: [BlockMeta] = []
        blocks.reserveCapacity(blockCount)
        for index in 0..<blockCount {
            blocks.append(BlockMeta(
                blockHash: hashes[index],
                parentBlockHash: index == 0 ? nil : hashes[index - 1],
                blockHeight: UInt64(index),
                childHashes: index + 1 == blockCount ? [] : [hashes[index + 1]],
                workContributions: [
                    VerifiedWorkContribution(id: uniqueGrinds[index], work: UInt256(1)),
                    VerifiedWorkContribution(id: sharedGrind, work: UInt256(1)),
                ]
            ))
        }

        let chain = makeChain(blocks: blocks)
        _ = await chain.setInheritedWorkProvider { inherited }
        let persisted = await chain.persist()
        let restored = try ChainState.restore(from: persisted)
        let exported = await restored.inheritedWorkSnapshot(
            forChildCoverage: [exportedChild: Set(hashes)]
        )
        let elapsed = started.duration(to: clock.now)

        let work = try XCTUnwrap(exported?.work(forBlock: exportedChild))
        let expectedTotal = WorkSum(UInt256(
            UInt64(blockCount + inheritedGrindCount + 1)
        ))
        XCTAssertEqual(persisted.blocks.count, blockCount)
        XCTAssertEqual(work.grindIDs.count, blockCount + inheritedGrindCount + 1)
        XCTAssertEqual(work.total, expectedTotal)
        XCTAssertEqual(work.work(forGrind: uniqueGrinds[0]), UInt256(1))
        XCTAssertEqual(work.work(forGrind: uniqueGrinds[blockCount - 1]), UInt256(1))
        XCTAssertEqual(work.work(forGrind: sharedGrind), UInt256(1))
        XCTAssertEqual(work.work(forGrind: inheritedGrinds[0]), UInt256(1))
        XCTAssertEqual(
            work.work(forGrind: inheritedGrinds[inheritedGrindCount - 1]),
            UInt256(1)
        )
        XCTAssertLessThan(
            elapsed,
            .seconds(15),
            "inherited projection/export should not retain one full grind set per ancestor"
        )

        let restoredTip = await restored.getMainChainTip()
        XCTAssertEqual(restoredTip, hashes.last)
        let forkChoiceValue = await restored.forkChoiceSnapshot(startingAt: hashes[0])
        let forkChoice = try XCTUnwrap(forkChoiceValue)
        XCTAssertEqual(forkChoice.tipHash, hashes.last)
        XCTAssertEqual(forkChoice.mainChainPath.count, blockCount)
        XCTAssertEqual(forkChoice.subtreeWork, expectedTotal)
    }

    func testManyChildMappingsReuseOverlappingSubtreeWork() async throws {
        let blockCount = 2_500
        let hashes = (0..<blockCount).map { testCID("shared-export-block-\($0)") }
        let childHashes = (0..<blockCount).map { testCID("shared-export-child-\($0)") }
        let sharedGrind = testCID("shared-export-grind")
        let blocks = (0..<blockCount).map { index in
            BlockMeta(
                blockHash: hashes[index],
                parentBlockHash: index == 0 ? nil : hashes[index - 1],
                blockHeight: UInt64(index),
                childHashes: index + 1 == blockCount ? [] : [hashes[index + 1]],
                workContributions: [
                    VerifiedWorkContribution(id: sharedGrind, work: UInt256(1)),
                ]
            )
        }
        let coverage = Dictionary(uniqueKeysWithValues: (0..<blockCount).map {
            (childHashes[$0], Set([hashes[$0]]))
        })
        let chain = makeChain(blocks: blocks)
        let clock = ContinuousClock()
        let started = clock.now

        let exported = await chain.inheritedWorkSnapshot(
            forChildCoverage: coverage
        )
        let elapsed = started.duration(to: clock.now)

        let snapshot = try XCTUnwrap(exported)
        for index in [0, blockCount / 2, blockCount - 1] {
            let work = snapshot.work(forBlock: childHashes[index])
            XCTAssertEqual(work.grindIDs, [sharedGrind])
            XCTAssertEqual(work.total, WorkSum(UInt256(1)))
        }
        XCTAssertLessThan(
            elapsed,
            .seconds(15),
            "overlapping child exports should share one subtree aggregation pass"
        )
    }

    func testMonotoneWorkFactsDoNotRebuildTheAcceptedGraph() async throws {
        let blockCount = 2_500
        let contributionCount = 64
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
        let clock = ContinuousClock()
        let started = clock.now

        for index in 0..<contributionCount {
            let result = await chain.addWorkContribution(
                VerifiedWorkContribution(
                    id: testCID("incremental-extra-\(index)"),
                    work: UInt256(1)
                ),
                to: hashes[blockCount - 1]
            )
            XCTAssertTrue(result.addedContribution)
        }
        let elapsed = started.duration(to: clock.now)
        let expected = WorkSum(UInt256(UInt64(blockCount + contributionCount)))

        let rootWeight = await chain.subtreeWeight(forHash: hashes[0])
        let tipWork = await chain.getCumulativeWork(forHash: hashes[blockCount - 1])
        XCTAssertEqual(rootWeight, expected)
        XCTAssertEqual(tipWork, expected)
        XCTAssertLessThan(
            elapsed,
            .seconds(15),
            "monotone work facts should update affected paths, not rebuild the graph"
        )
    }
}
