import XCTest
import UInt256
@testable import Lattice

@MainActor
final class SegmentBaseGhostDifferentialTests: XCTestCase {
    func testHistoricalSegmentSplitsStayIncrementalAndExact() async throws {
        let depth = 128
        var blocks: [PlannedDifferentialBlock] = []
        blocks.reserveCapacity(depth)
        for index in 0..<depth {
            blocks.append(PlannedDifferentialBlock(
                index: index,
                hash: testCID("incremental-split-main-\(index)"),
                parentHash: index == 0 ? nil : blocks[index - 1].hash,
                height: UInt64(index)
            ))
        }
        let chain = try await ChainState.restore(replaying: [
            admission(for: blocks[0]),
        ])
        for block in blocks.dropFirst() {
            _ = try await chain.applyStaged(admission(for: block))
        }

        let rebuilds = await chain.segmentCacheRebuildCount
        let projections = await chain.fullCanonicalProjectionCount
        let firstSibling = PlannedDifferentialBlock(
            index: depth,
            hash: testCID("incremental-split-first-sibling"),
            parentHash: blocks[0].hash,
            height: 1
        )
        _ = try await chain.applyStaged(admission(for: firstSibling))
        var rebuildsAfter = await chain.segmentCacheRebuildCount
        XCTAssertEqual(rebuildsAfter, rebuilds)
        var projectionsAfter = await chain.fullCanonicalProjectionCount
        XCTAssertEqual(projectionsAfter, projections)
        await assertMatchesReference(
            chain,
            seed: 0,
            event: "deep historical split"
        )

        for index in 1...32 {
            let sibling = PlannedDifferentialBlock(
                index: depth + index,
                hash: testCID("incremental-split-sibling-\(index)"),
                parentHash: blocks[0].hash,
                height: 1
            )
            _ = try await chain.applyStaged(admission(for: sibling))
            rebuildsAfter = await chain.segmentCacheRebuildCount
            projectionsAfter = await chain.fullCanonicalProjectionCount
            XCTAssertEqual(
                rebuildsAfter,
                rebuilds,
                "sibling \(index)"
            )
            XCTAssertEqual(
                projectionsAfter,
                projections,
                "same-parent sibling \(index)"
            )
            await assertMatchesReference(
                chain,
                seed: 0,
                event: "repeated sibling \(index)"
            )
        }

        for parentIndex in 1...32 {
            let sibling = PlannedDifferentialBlock(
                index: depth + 100 + parentIndex,
                hash: testCID("incremental-historical-sibling-\(parentIndex)"),
                parentHash: blocks[parentIndex].hash,
                height: UInt64(parentIndex + 1)
            )
            _ = try await chain.applyStaged(admission(for: sibling))
            rebuildsAfter = await chain.segmentCacheRebuildCount
            projectionsAfter = await chain.fullCanonicalProjectionCount
            XCTAssertEqual(rebuildsAfter, rebuilds, "history \(parentIndex)")
            XCTAssertEqual(
                projectionsAfter,
                projections,
                "losing historical split \(parentIndex)"
            )
            await assertMatchesReference(
                chain,
                seed: 0,
                event: "losing historical split \(parentIndex)"
            )
        }
    }

    func testNestedHistoricalSplitsReparentQuotientExactly() async throws {
        let main = (0..<6).map { index in
            PlannedDifferentialBlock(
                index: index,
                hash: testCID("nested-split-main-\(index)"),
                parentHash: index == 0
                    ? nil
                    : testCID("nested-split-main-\(index - 1)"),
                height: UInt64(index)
            )
        }
        let chain = try await ChainState.restore(replaying: [
            admission(for: main[0]),
        ])
        for block in main.dropFirst() {
            _ = try await chain.applyStaged(admission(for: block))
        }
        let rebuilds = await chain.segmentCacheRebuildCount

        let lowerFork = PlannedDifferentialBlock(
            index: 100,
            hash: testCID("nested-split-lower-fork"),
            parentHash: main[2].hash,
            height: 3
        )
        _ = try await chain.applyStaged(admission(for: lowerFork))
        var rebuildsAfter = await chain.segmentCacheRebuildCount
        XCTAssertEqual(rebuildsAfter, rebuilds)
        await assertMatchesReference(chain, seed: 0, event: "lower split")

        let upperFork = PlannedDifferentialBlock(
            index: 101,
            hash: testCID("nested-split-upper-fork"),
            parentHash: main[1].hash,
            height: 2
        )
        _ = try await chain.applyStaged(admission(for: upperFork))
        rebuildsAfter = await chain.segmentCacheRebuildCount
        XCTAssertEqual(rebuildsAfter, rebuilds)
        await assertMatchesReference(chain, seed: 0, event: "upper split")

        let sharedGrind = testCID("nested-split-shared-work")
        _ = try await chain.applyStaged(workAdmission(
            blockHash: main[4].hash,
            id: sharedGrind,
            work: 7
        ))
        _ = await chain.mergeInheritedWork(InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                main[4].hash: WorkMeasure(VerifiedWorkContribution(
                    id: sharedGrind,
                    work: UInt256(11)
                )),
            ]
        ))
        rebuildsAfter = await chain.segmentCacheRebuildCount
        XCTAssertEqual(rebuildsAfter, rebuilds)
        await assertMatchesReference(
            chain,
            seed: 0,
            event: "once-only inherited strengthening after nested split"
        )
    }

    func testLateOrphanAttachmentGraftsWithoutGlobalRebuild() async throws {
        let root = PlannedDifferentialBlock(
            index: 0,
            hash: testCID("orphan-fallback-root"),
            parentHash: nil,
            height: 0
        )
        let parent = PlannedDifferentialBlock(
            index: 1,
            hash: testCID("orphan-fallback-parent"),
            parentHash: root.hash,
            height: 1
        )
        let child = PlannedDifferentialBlock(
            index: 2,
            hash: testCID("orphan-fallback-child"),
            parentHash: parent.hash,
            height: 2
        )
        let chain = try await ChainState.restore(replaying: [admission(for: root)])
        _ = try await chain.applyStaged(admission(for: child))
        let rebuilds = await chain.segmentCacheRebuildCount
        let grafts = await chain.segmentGraftCount

        _ = try await chain.applyStaged(admission(for: parent))

        let rebuildsAfter = await chain.segmentCacheRebuildCount
        let graftsAfter = await chain.segmentGraftCount
        let visited = await chain.segmentGraftBlockVisitCount
        XCTAssertEqual(rebuildsAfter, rebuilds)
        XCTAssertEqual(graftsAfter, grafts + 1)
        XCTAssertEqual(visited, 2)
        await assertMatchesReference(chain, seed: 0, event: "late orphan attachment")
    }

    func testDeepReverseOrphanRunBulkGraftsAndRoutesWorkOnce() async throws {
        let depth = 512
        var blocks: [PlannedDifferentialBlock] = []
        blocks.reserveCapacity(depth)
        for index in 0..<depth {
            blocks.append(PlannedDifferentialBlock(
                index: index,
                hash: testCID("reverse-orphan-\(index)"),
                parentHash: index == 0 ? nil : blocks[index - 1].hash,
                height: UInt64(index)
            ))
        }
        let chain = try await ChainState.restore(replaying: [
            admission(for: blocks[0]),
        ])
        let initialRebuilds = await chain.segmentCacheRebuildCount
        let initialProjections = await chain.fullCanonicalProjectionCount

        for index in stride(from: depth - 1, through: 2, by: -1) {
            _ = try await chain.applyStaged(admission(for: blocks[index]))
        }
        let sharedGrind = testCID("reverse-orphan-shared-work")
        _ = try await chain.applyStaged(workAdmission(
            blockHash: blocks.last!.hash,
            id: sharedGrind,
            work: 7
        ))
        _ = await chain.mergeInheritedWork(InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                blocks.last!.hash: WorkMeasure(VerifiedWorkContribution(
                    id: sharedGrind,
                    work: UInt256(11)
                )),
            ]
        ))

        let orphanRebuilds = await chain.segmentCacheRebuildCount
        let orphanProjections = await chain.fullCanonicalProjectionCount
        let orphanGrafts = await chain.segmentGraftCount
        let orphanVisits = await chain.segmentGraftBlockVisitCount
        XCTAssertEqual(orphanRebuilds, initialRebuilds)
        XCTAssertEqual(orphanProjections, initialProjections)
        XCTAssertEqual(orphanGrafts, 0)
        XCTAssertEqual(orphanVisits, 0)
        let baselineValue = await chain.parentSecuringWorkSnapshot()
        let baseline = try XCTUnwrap(baselineValue)
        let cellsBefore = await chain.segmentWorkUpdateCellCount

        _ = try await chain.applyStaged(admission(for: blocks[1]))

        let graftRebuilds = await chain.segmentCacheRebuildCount
        let grafts = await chain.segmentGraftCount
        let visits = await chain.segmentGraftBlockVisitCount
        let cellsAfter = await chain.segmentWorkUpdateCellCount
        XCTAssertEqual(graftRebuilds, initialRebuilds)
        XCTAssertEqual(grafts, 1)
        XCTAssertEqual(
            visits,
            UInt64(depth - 1)
        )
        XCTAssertEqual(
            cellsAfter - cellsBefore,
            1,
            "the whole unary component adds one total to its existing root base"
        )

        let deltaValue = await chain.parentSecuringWorkSnapshot(
            since: baseline.revision
        )
        let delta = try XCTUnwrap(deltaValue)
        XCTAssertEqual(delta.blockCIDs.count, depth - 1)
        XCTAssertEqual(
            delta.sourceWork(forBlock: blocks.last!.hash)
                .work(forGrind: sharedGrind),
            UInt256(11)
        )
        let replayValue = await chain.parentSecuringWorkSnapshot(
            since: delta.revision
        )
        let replay = try XCTUnwrap(replayValue)
        XCTAssertTrue(replay.isEmpty)

        var expected = WorkSum.zero
        for block in blocks {
            expected = expected + UInt256(UInt64(block.index % 3 + 1))
        }
        expected = expected + UInt256(11)
        let rootChoiceValue = await chain.forkChoiceSnapshot(
            startingAt: blocks[0].hash
        )
        let rootChoice = try XCTUnwrap(rootChoiceValue)
        XCTAssertEqual(rootChoice.subtreeWork, expected)
        await assertMatchesReference(chain, seed: 0, event: "deep reverse graft")
    }

    func testManySmallOrphanGraftsDoNotScanMatureHistory() async throws {
        let historyCount = 192
        var history: [PlannedDifferentialBlock] = []
        history.reserveCapacity(historyCount)
        for index in 0..<historyCount {
            history.append(PlannedDifferentialBlock(
                index: index,
                hash: testCID("mature-history-\(index)"),
                parentHash: index == 0 ? nil : history[index - 1].hash,
                height: UInt64(index)
            ))
        }
        let chain = try await ChainState.restore(replaying: [
            admission(for: history[0]),
        ])
        for block in history.dropFirst() {
            _ = try await chain.applyStaged(admission(for: block))
        }

        let attachmentCount = 32
        var connectors: [PlannedDifferentialBlock] = []
        var leaves: [PlannedDifferentialBlock] = []
        for offset in 0..<attachmentCount {
            let parent = history[offset + 1]
            let connector = PlannedDifferentialBlock(
                index: 10_000 + offset * 2,
                hash: testCID("small-graft-connector-\(offset)"),
                parentHash: parent.hash,
                height: parent.height + 1
            )
            connectors.append(connector)
            leaves.append(PlannedDifferentialBlock(
                index: connector.index + 1,
                hash: testCID("small-graft-leaf-\(offset)"),
                parentHash: connector.hash,
                height: connector.height + 1
            ))
        }
        let rebuilds = await chain.segmentCacheRebuildCount
        let projections = await chain.fullCanonicalProjectionCount
        for leaf in leaves {
            _ = try await chain.applyStaged(admission(for: leaf))
        }
        let orphanVisits = await chain.segmentGraftBlockVisitCount
        XCTAssertEqual(orphanVisits, 0)

        for connector in connectors {
            _ = try await chain.applyStaged(admission(for: connector))
        }

        let rebuildsAfter = await chain.segmentCacheRebuildCount
        let projectionsAfter = await chain.fullCanonicalProjectionCount
        let graftsAfter = await chain.segmentGraftCount
        let visitsAfter = await chain.segmentGraftBlockVisitCount
        XCTAssertEqual(rebuildsAfter, rebuilds)
        XCTAssertEqual(projectionsAfter, projections)
        XCTAssertEqual(graftsAfter, UInt64(attachmentCount))
        XCTAssertEqual(
            visitsAfter,
            UInt64(attachmentCount * 2),
            "graft work must scale with new fragments, not mature history"
        )
        await assertMatchesReference(
            chain,
            seed: 0,
            event: "many independent small grafts"
        )
    }

    func testSegmentBaseProjectionMatchesReferenceAcrossRandomizedMutations() async throws {
        for seed: UInt64 in [
            0xC0FFEE, 0xD1FF_EA5E, 0xFACE_FEED, 0xBADC_0DE,
            0x1234_5678, 0x8765_4321, 0x0DDC_0FFE, 0x51DE_CAFE,
        ] {
            var random = DifferentialRandom(seed: seed)
            let blocks = plannedBlocks(seed: seed, random: &random)
            var staged = [admission(for: blocks[0])]
            let chain = try await ChainState.restore(replaying: staged)
            var delivered = [blocks[0].hash]
            var localStrength: [String: UInt64] = [:]
            var inheritedByBlock: [String: WorkMeasure] = [:]
            var inheritedStrength: [String: UInt64] = [:]
            var locationByGrind: [String: String] = [:]
            var inheritedRevision: UInt64 = 0
            let sharedGrinds = (0..<3).map {
                testCID("segment-base-differential-\(seed)-shared-\($0)")
            }

            await assertMatchesReference(chain, seed: seed, event: "genesis")

            // Deliver a descendant before both its parent and grandparent.
            for index in [4, 3] {
                let batch = admission(for: blocks[index])
                let result = try await chain.applyStaged(batch)
                staged.append(batch)
                XCTAssertEqual(result?.addedBlock, true, "seed \(seed), block \(index)")
                delivered.append(blocks[index].hash)
                await assertMatchesReference(chain, seed: seed, event: "block \(index)")
            }

            let localGrind = sharedGrinds[0]
            let localWork: UInt64 = 3
            let initialWork = workAdmission(
                blockHash: blocks[4].hash,
                id: localGrind,
                work: localWork
            )
            let localResult = try await chain.applyStaged(initialWork)
            staged.append(initialWork)
            XCTAssertEqual(localResult?.addedContribution, true, "seed \(seed), initial local work")
            localStrength[localGrind] = localWork
            locationByGrind[localGrind] = blocks[4].hash
            await assertMatchesReference(chain, seed: seed, event: "local orphan work")

            let inheritedWork: UInt64 = 4
            inheritedByBlock[blocks[4].hash] = WorkMeasure(
                VerifiedWorkContribution(id: localGrind, work: UInt256(inheritedWork))
            )
            inheritedStrength[localGrind] = inheritedWork
            inheritedRevision += 1
            let inheritedCommit = await chain.mergeInheritedWork(InheritedWorkSnapshot(
                revision: inheritedRevision,
                workByBlock: inheritedByBlock
            ))
            XCTAssertNotNil(inheritedCommit, "seed \(seed), initial inherited work")
            await assertMatchesReference(chain, seed: seed, event: "inherited orphan work")

            // Retain parent-derived work before its covered child arrives; the
            // later fork admission must incorporate it when it becomes known.
            let futureGrind = sharedGrinds[1]
            inheritedByBlock[blocks[5].hash] = WorkMeasure(
                VerifiedWorkContribution(id: futureGrind, work: UInt256(2))
            )
            inheritedStrength[futureGrind] = 2
            locationByGrind[futureGrind] = blocks[5].hash
            inheritedRevision += 1
            let futureCommit = await chain.mergeInheritedWork(InheritedWorkSnapshot(
                revision: inheritedRevision,
                workByBlock: inheritedByBlock
            ))
            XCTAssertNotNil(futureCommit, "seed \(seed), inherited work before block admission")
            let futureKnown = await chain.contains(blockHash: blocks[5].hash)
            XCTAssertFalse(futureKnown)
            await assertMatchesReference(chain, seed: seed, event: "unknown inherited work")

            // Attach the orphaned path, then turn its old unary suffix into a
            // fork after it has accumulated both local and inherited work.
            for index in [1, 2] {
                let batch = admission(for: blocks[index])
                let result = try await chain.applyStaged(batch)
                staged.append(batch)
                XCTAssertEqual(result?.addedBlock, true, "seed \(seed), block \(index)")
                delivered.append(blocks[index].hash)
                await assertMatchesReference(chain, seed: seed, event: "block \(index)")
            }

            let lateForkBatch = admission(for: blocks[5])
            let lateFork = try await chain.applyStaged(lateForkBatch)
            staged.append(lateForkBatch)
            XCTAssertEqual(lateFork?.addedBlock, true, "seed \(seed), late fork")
            delivered.append(blocks[5].hash)
            await assertMatchesReference(chain, seed: seed, event: "late fork")

            var remaining = Array(6..<blocks.count)
            random.shuffle(&remaining)
            var updateCount = 0
            while !remaining.isEmpty || updateCount < 28 {
                let deliverBlock = !remaining.isEmpty
                    && (updateCount >= 28 || random.nextInt(100) < 45)
                if deliverBlock {
                    let index = remaining.removeFirst()
                    let batch = admission(for: blocks[index])
                    let result = try await chain.applyStaged(batch)
                    staged.append(batch)
                    XCTAssertEqual(result?.addedBlock, true, "seed \(seed), block \(index)")
                    delivered.append(blocks[index].hash)
                    await assertMatchesReference(chain, seed: seed, event: "block \(index)")
                    continue
                }

                updateCount += 1
                let grind = sharedGrinds[random.nextInt(sharedGrinds.count)]
                let blockHash = locationByGrind[grind] ?? {
                    let location = delivered[random.nextInt(delivered.count)]
                    locationByGrind[grind] = location
                    return location
                }()
                if random.nextInt(2) == 0 {
                    let existingStrength = localStrength[grind, default: 0]
                    let work = existingStrength + UInt64(random.nextInt(3) + 1)
                    let batch = workAdmission(
                        blockHash: blockHash,
                        id: grind,
                        work: work
                    )
                    let result = try await chain.applyStaged(batch)
                    staged.append(batch)
                    XCTAssertEqual(result?.addedContribution, true, "seed \(seed), local update")
                    localStrength[grind] = work
                    await assertMatchesReference(chain, seed: seed, event: "local update \(updateCount)")
                } else {
                    let existingStrength = inheritedStrength[grind, default: 0]
                    var measure = inheritedByBlock[blockHash] ?? .zero
                    let work = existingStrength + UInt64(random.nextInt(3) + 1)
                    XCTAssertTrue(measure.insert(
                        VerifiedWorkContribution(id: grind, work: UInt256(work))
                    ), "seed \(seed), inherited update must add a fact")
                    inheritedByBlock[blockHash] = measure
                    inheritedStrength[grind] = work
                    inheritedRevision += 1
                    let commit = await chain.mergeInheritedWork(InheritedWorkSnapshot(
                        revision: inheritedRevision,
                        workByBlock: inheritedByBlock
                    ))
                    XCTAssertNotNil(commit, "seed \(seed), inherited update")
                    await assertMatchesReference(chain, seed: seed, event: "inherited update \(updateCount)")
                }
            }

            let restored = try await ChainState.restore(replaying: staged)
            _ = await restored.mergeInheritedWork(InheritedWorkSnapshot(
                revision: inheritedRevision,
                workByBlock: inheritedByBlock
            ))
            await assertMatchesReference(restored, seed: seed, event: "fact replay")
        }
    }
}

private struct PlannedDifferentialBlock {
    let index: Int
    let hash: String
    let parentHash: String?
    let height: UInt64
}

private func plannedBlocks(
    seed: UInt64,
    random: inout DifferentialRandom
) -> [PlannedDifferentialBlock] {
    var blocks = [PlannedDifferentialBlock(
        index: 0,
        hash: testCID("segment-base-differential-\(seed)-block-0"),
        parentHash: nil,
        height: 0
    )]
    let forcedParents = [1: 0, 2: 0, 3: 1, 4: 3, 5: 1, 7: 6]
    for index in 1..<20 {
        if index == 6 {
            // A second root exercises the same comparison at genesis level.
            blocks.append(PlannedDifferentialBlock(
                index: index,
                hash: testCID("segment-base-differential-\(seed)-block-\(index)"),
                parentHash: nil,
                height: 0
            ))
            continue
        }
        let parentIndex = forcedParents[index] ?? random.nextInt(index)
        let parent = blocks[parentIndex]
        blocks.append(PlannedDifferentialBlock(
            index: index,
            hash: testCID("segment-base-differential-\(seed)-block-\(index)"),
            parentHash: parent.hash,
            height: parent.height + 1
        ))
    }
    return blocks
}

private func admission(for block: PlannedDifferentialBlock) -> ChainAdmissionBatch {
    let contribution = VerifiedWorkContribution(
        id: testCID("segment-base-differential-work-\(block.index)"),
        work: UInt256(UInt64(block.index % 3 + 1))
    )
    return ChainAdmissionBatch(facts: [
        .block(ChainBlockFact(
            blockHash: block.hash,
            parentBlockHash: block.parentHash,
            blockHeight: block.height,
            postStateCID: testCID("segment-base-differential-post-\(block.index)"),
            prevStateCID: testCID("segment-base-differential-prev-\(block.index)"),
            specCID: testCID("segment-base-differential-spec-\(block.index)"),
            target: "1",
            nextTarget: "1",
            timestamp: Int64(block.index),
            stateDiff: .empty
        )),
        .work(ChainWorkFact(blockHash: block.hash, contribution: contribution)),
    ])
}

private func workAdmission(
    blockHash: String,
    id: String,
    work: UInt64
) -> ChainAdmissionBatch {
    ChainAdmissionBatch(facts: [
        .work(ChainWorkFact(
            blockHash: blockHash,
            contribution: VerifiedWorkContribution(id: id, work: UInt256(work))
        )),
    ])
}

private func assertMatchesReference(
    _ chain: ChainState,
    seed: UInt64,
    event: String,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let blocks = await chain.hashToBlock
    let inherited = await chain.inheritedWorkSnapshot ?? .zero
    guard let expected = ChainState.referenceCanonicalProjection(
        in: blocks,
        inherited: inherited
    ) else {
        XCTFail("seed \(seed), \(event): reference has no canonical projection", file: file, line: line)
        return
    }
    let liveTip = await chain.getMainChainTip()
    let livePath = await chain.mainChainHashes
    XCTAssertEqual(liveTip, expected.chainTip, "seed \(seed), \(event): tip", file: file, line: line)
    XCTAssertEqual(livePath, expected.mainChainHashes, "seed \(seed), \(event): path", file: file, line: line)
}

private struct DifferentialRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state % UInt64(upperBound))
    }

    mutating func shuffle<Element>(_ values: inout [Element]) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            values.swapAt(index, nextInt(index + 1))
        }
    }
}
