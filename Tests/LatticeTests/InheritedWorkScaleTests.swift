import XCTest
import UInt256
@testable import Lattice

final class InheritedWorkScaleTests: XCTestCase {
    func testLinearChildQuotientExportsOneFrontierFactPerGrind() async throws {
        let blockCount = 2_500
        let parentHashes = (0..<blockCount).map {
            testCID("frontier-parent-\($0)")
        }
        let childHashes = (0..<blockCount).map {
            testCID("frontier-child-\($0)")
        }
        let grindIDs = (0..<blockCount).map {
            testCID("frontier-grind-\($0)")
        }
        let parentBlocks = (0..<blockCount).map { index in
            BlockMeta(
                blockHash: parentHashes[index],
                parentBlockHash: index == 0 ? nil : parentHashes[index - 1],
                blockHeight: UInt64(index),
                childHashes: index + 1 == blockCount
                    ? []
                    : [parentHashes[index + 1]],
                workContributions: [
                    VerifiedWorkContribution(id: grindIDs[index], work: UInt256(1)),
                ]
            )
        }
        let coverage = Dictionary(uniqueKeysWithValues: (0..<blockCount).map {
            (childHashes[$0], Set([parentHashes[$0]]))
        })
        let quotient = Dictionary(uniqueKeysWithValues: (0..<blockCount).map {
            (childHashes[$0], $0 == 0 ? nil : childHashes[$0 - 1])
        })
        let chain = makeChain(blocks: parentBlocks)
        let clock = ContinuousClock()
        let started = clock.now

        let exported = await chain.inheritedWorkSnapshot(
            forChildCoverage: coverage,
            acceptedChildPredecessorByBlock: quotient
        )
        let elapsed = started.duration(to: clock.now)

        let snapshot = try XCTUnwrap(exported)
        let factCount = snapshot.blockCIDs.reduce(0) {
            $0 + snapshot.sourceWork(forBlock: $1).grindIDs.count
        }
        XCTAssertEqual(factCount, blockCount)
        XCTAssertEqual(snapshot.blockCIDs.count, blockCount)
        for index in [0, blockCount / 2, blockCount - 1] {
            let measure = snapshot.sourceWork(forBlock: childHashes[index])
            XCTAssertEqual(measure.grindIDs, [grindIDs[index]])
            XCTAssertEqual(measure.total, WorkSum(UInt256(1)))
        }
        XCTAssertLessThan(
            elapsed,
            .seconds(15),
            "a linear hierarchy should export one maximal child route per grind"
        )
    }

    func testWideChildQuotientExportsSharedGrindInLinearTime() async throws {
        let blockCount = 2_500
        let parentHashes = (0..<blockCount).map {
            testCID("wide-frontier-parent-\($0)")
        }
        let childRoot = testCID("wide-frontier-child-root")
        let childLeaves = (1..<blockCount).map {
            testCID("wide-frontier-child-\($0)")
        }
        let sharedGrind = testCID("wide-frontier-shared-grind")
        let parentBlocks = (0..<blockCount).map { index in
            BlockMeta(
                blockHash: parentHashes[index],
                parentBlockHash: index == 0 ? nil : parentHashes[index - 1],
                blockHeight: UInt64(index),
                childHashes: index + 1 == blockCount
                    ? []
                    : [parentHashes[index + 1]],
                workContributions: [
                    VerifiedWorkContribution(id: sharedGrind, work: UInt256(1)),
                ]
            )
        }
        var coverage = [childRoot: Set([parentHashes[0]])]
        var quotient = [childRoot: Optional<String>.none]
        for index in 1..<blockCount {
            coverage[childLeaves[index - 1]] = [parentHashes[index]]
            quotient[childLeaves[index - 1]] = childRoot
        }
        let chain = makeChain(blocks: parentBlocks)
        let clock = ContinuousClock()
        let started = clock.now

        let exported = await chain.inheritedWorkSnapshot(
            forChildCoverage: coverage,
            acceptedChildPredecessorByBlock: quotient
        )
        let elapsed = started.duration(to: clock.now)

        let snapshot = try XCTUnwrap(exported)
        let exportedBlocks = Set(snapshot.blockCIDs)
        let expectedBlocks = Set<String>(childLeaves)
        XCTAssertEqual(exportedBlocks, expectedBlocks)
        XCTAssertTrue(snapshot.blockCIDs.allSatisfy {
            snapshot.sourceWork(forBlock: $0).grindIDs
                == Set<String>([sharedGrind])
        })
        XCTAssertLessThan(
            elapsed,
            .seconds(15),
            "a wide accepted frontier should cost roughly its required output"
        )
    }

    func testRepeatedParentForkWorkReusesIdenticalWideFrontier() async throws {
        let width = 1_000
        let prefixHashes = (0..<width).map {
            testCID("reused-frontier-prefix-\($0)")
        }
        let forkHashes = (0..<width).map {
            testCID("reused-frontier-fork-\($0)")
        }
        let childRoot = testCID("reused-frontier-child-root")
        let childLeaves = (1..<width).map {
            testCID("reused-frontier-child-\($0)")
        }
        let sharedGrind = testCID("reused-frontier-grind")
        let prefix = (0..<width).map { index in
            BlockMeta(
                blockHash: prefixHashes[index],
                parentBlockHash: index == 0 ? nil : prefixHashes[index - 1],
                blockHeight: UInt64(index),
                childHashes: index + 1 == width
                    ? forkHashes
                    : [prefixHashes[index + 1]],
                workContributions: [
                    VerifiedWorkContribution(id: sharedGrind, work: UInt256(1)),
                ]
            )
        }
        let forks = forkHashes.map {
            BlockMeta(
                blockHash: $0,
                parentBlockHash: prefixHashes[width - 1],
                blockHeight: UInt64(width),
                childHashes: [],
                workContributions: [
                    VerifiedWorkContribution(id: sharedGrind, work: UInt256(1)),
                ]
            )
        }
        var coverage = [childRoot: Set([prefixHashes[0]])]
        var quotient = [childRoot: Optional<String>.none]
        for index in 1..<width {
            coverage[childLeaves[index - 1]] = [prefixHashes[index]]
            quotient[childLeaves[index - 1]] = childRoot
        }
        let chain = makeChain(blocks: prefix + forks)
        let clock = ContinuousClock()
        let started = clock.now

        let exported = await chain.inheritedWorkSnapshot(
            forChildCoverage: coverage,
            acceptedChildPredecessorByBlock: quotient
        )
        let elapsed = started.duration(to: clock.now)

        let snapshot = try XCTUnwrap(exported)
        XCTAssertEqual(Set(snapshot.blockCIDs), Set(childLeaves))
        XCTAssertTrue(snapshot.blockCIDs.allSatisfy {
            snapshot.sourceWork(forBlock: $0).grindIDs
                == Set<String>([sharedGrind])
        })
        XCTAssertLessThan(
            elapsed,
            .seconds(15),
            "identical child-frontier states should be routed once per grind"
        )
    }

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
