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
        _ = await chain.addWorkContribution(
            VerifiedWorkContribution(id: sharedGrind, work: UInt256(11)),
            to: main[4].hash
        )
        rebuildsAfter = await chain.segmentCacheRebuildCount
        XCTAssertEqual(rebuildsAfter, rebuilds)
        await assertMatchesReference(
            chain,
            seed: 0,
            event: "once-only strengthening after nested split"
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
        _ = await chain.addWorkContribution(
            VerifiedWorkContribution(id: sharedGrind, work: UInt256(11)),
            to: blocks.last!.hash
        )

        let orphanRebuilds = await chain.segmentCacheRebuildCount
        let orphanProjections = await chain.fullCanonicalProjectionCount
        let orphanGrafts = await chain.segmentGraftCount
        let orphanVisits = await chain.segmentGraftBlockVisitCount
        XCTAssertEqual(orphanRebuilds, initialRebuilds)
        XCTAssertEqual(orphanProjections, initialProjections)
        XCTAssertEqual(orphanGrafts, 0)
        XCTAssertEqual(orphanVisits, 0)
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
        // The graft adds NO ancestor total, because no ancestor total exists any
        // more: the component's elements are spliced inside the parent's range
        // and every enclosing range is correct by construction. What remains is
        // the cost of placing the component's own elements, which is inherent to
        // routing those blocks and used to be paid untracked inside the index
        // rebuild and the dictionary merges this replaced.
        //
        // So the cost claim is NOT a single number here — it is that the graft
        // does not touch mature history, which only a shape that varies the
        // mature history can witness. See
        // `testOrphanGraftCostDoesNotScaleWithMatureHistory`.
        XCTAssertGreaterThan(
            cellsAfter - cellsBefore,
            0,
            "the component's own elements must be placed"
        )

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
            var strengthByGrind: [String: UInt64] = [:]
            var locationByGrind: [String: String] = [:]
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
            strengthByGrind[localGrind] = localWork
            locationByGrind[localGrind] = blocks[4].hash
            await assertMatchesReference(chain, seed: seed, event: "local orphan work")

            let strongerWork = workAdmission(
                blockHash: blocks[4].hash,
                id: localGrind,
                work: 4
            )
            let strongerResult = try await chain.applyStaged(strongerWork)
            staged.append(strongerWork)
            XCTAssertEqual(strongerResult?.addedContribution, true, "seed \(seed), stronger work")
            strengthByGrind[localGrind] = 4
            await assertMatchesReference(chain, seed: seed, event: "stronger orphan work")

            let futureGrind = sharedGrinds[1]

            // Attach the orphaned path, then turn its old unary suffix into a fork.
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
            let futureWork = workAdmission(
                blockHash: blocks[5].hash,
                id: futureGrind,
                work: 2
            )
            _ = try await chain.applyStaged(futureWork)
            staged.append(futureWork)
            strengthByGrind[futureGrind] = 2
            locationByGrind[futureGrind] = blocks[5].hash
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
                let work = strengthByGrind[grind, default: 0]
                    + UInt64(random.nextInt(3) + 1)
                let batch = workAdmission(
                    blockHash: blockHash,
                    id: grind,
                    work: work
                )
                let result = try await chain.applyStaged(batch)
                staged.append(batch)
                XCTAssertEqual(result?.addedContribution, true, "seed \(seed), work update")
                strengthByGrind[grind] = work
                await assertMatchesReference(chain, seed: seed, event: "work update \(updateCount)")
            }

            let restored = try await ChainState.restore(replaying: staged)
            await assertMatchesReference(restored, seed: seed, event: "fact replay")
        }
    }

    /// The delta projection's own risk surface: a long shared prefix with
    /// reorgs of varying depth above it — including a selected path that
    /// becomes a strict prefix of the projected one — plus a late orphan graft
    /// and an exclusion. Every step is compared against the independent
    /// reference walk, the by-height index included.
    func testDeltaProjectionMatchesReferenceAcrossDeepReorgs() async throws {
        var random = DifferentialRandom(seed: 0x0DE1_7A00)
        let depth = 48
        var main: [PlannedDifferentialBlock] = []
        for index in 0..<depth {
            main.append(PlannedDifferentialBlock(
                index: index,
                hash: testCID("delta-reorg-main-\(index)"),
                parentHash: index == 0 ? nil : main[index - 1].hash,
                height: UInt64(index)
            ))
        }
        let chain = try await ChainState.restore(replaying: [
            admission(for: main[0]),
        ])
        for block in main.dropFirst() {
            _ = try await chain.applyStaged(admission(for: block))
        }
        await assertMatchesReference(chain, seed: 0, event: "spine")

        // A sibling at every fourth height: the merged-mining shape that
        // defeats the O(1) tip append and splits the quotient.
        var siblings: [PlannedDifferentialBlock] = []
        for index in stride(from: 4, to: depth, by: 4) {
            let sibling = PlannedDifferentialBlock(
                index: 1_000 + index,
                hash: testCID("delta-reorg-side-\(index)"),
                parentHash: main[index - 1].hash,
                height: UInt64(index)
            )
            siblings.append(sibling)
            _ = try await chain.applyStaged(admission(for: sibling))
            await assertMatchesReference(chain, seed: 0, event: "sibling \(index)")
        }

        // Decisive work on a random sibling each round, so the shared prefix
        // shrinks and grows across projections instead of only extending. The
        // emitted commit is the node's only view of what moved, so both halves
        // of it are checked against the reference walk's own set difference.
        var previousPath = await referencePath(chain)
        for round in 0..<24 {
            let target = siblings[random.nextInt(siblings.count)]
            let result = try await chain.applyStaged(workAdmission(
                blockHash: target.hash,
                id: testCID("delta-reorg-grind-\(target.index)"),
                work: UInt64(round + 1) * 8
            ))
            await assertMatchesReference(
                chain,
                seed: 0,
                event: "reorg round \(round)"
            )
            await assertTruncationEquivalent(chain, "reorg round \(round)")
            let newPath = await referencePath(chain)
            assertCommitDelta(
                result,
                from: previousPath,
                to: newPath,
                event: "reorg round \(round)"
            )
            previousPath = newPath
        }

        // A late orphan graft: the child arrives first, then its parent
        // connects the whole component into the quotient.
        let graftParent = PlannedDifferentialBlock(
            index: 2_000,
            hash: testCID("delta-reorg-graft-parent"),
            parentHash: main[6].hash,
            height: 7
        )
        let graftChild = PlannedDifferentialBlock(
            index: 2_001,
            hash: testCID("delta-reorg-graft-child"),
            parentHash: graftParent.hash,
            height: 8
        )
        let heldResult = try await chain.applyStaged(admission(for: graftChild))
        await assertMatchesReference(chain, seed: 0, event: "orphan held")
        var graftPath = await referencePath(chain)
        assertCommitDelta(
            heldResult,
            from: previousPath,
            to: graftPath,
            event: "orphan held"
        )
        previousPath = graftPath

        let graftResult = try await chain.applyStaged(admission(for: graftParent))
        await assertMatchesReference(chain, seed: 0, event: "orphan grafted")
        graftPath = await referencePath(chain)
        assertCommitDelta(
            graftResult,
            from: previousPath,
            to: graftPath,
            event: "orphan grafted"
        )

        // An exclusion rebuilds the filtered index and forces a full
        // projection; the delta must not outlive it.
        _ = try? await chain.applyStaged(exclusionBatch(for: siblings[0]))
        await assertMatchesReferenceWithExclusions(
            chain,
            seed: 0,
            event: "exclusion after deltas"
        )
    }

    /// The merged-mining shape itself: a sibling at EVERY height, each arriving
    /// BEFORE the canonical block, so the parent always already has a child and
    /// no admission can take a cheap tip append. The randomized generator makes
    /// siblings, but not systematically at every height — and this is both the
    /// shape that degenerates the segment quotient and the one live sync
    /// actually sees on a merged-mining child.
    func testSiblingAtEveryHeightMatchesReferenceAndTruncates() async throws {
        let depth = 32
        var main: [PlannedDifferentialBlock] = []
        for index in 0..<depth {
            // `admission(for:)` derives work as `index % 3 + 1`, so an index of
            // 3i+2 weighs 3 and an index of 3i weighs 1: the canonical branch
            // wins on work at every height rather than on a CID tie-break.
            main.append(PlannedDifferentialBlock(
                index: 3 * index + 2,
                hash: testCID("every-height-main-\(index)"),
                parentHash: index == 0 ? nil : main[index - 1].hash,
                height: UInt64(index)
            ))
        }
        let chain = try await ChainState.restore(replaying: [
            admission(for: main[0]),
        ])
        await assertMatchesReference(chain, seed: 0, event: "genesis")

        for index in 1..<depth {
            let sibling = PlannedDifferentialBlock(
                index: 3 * index,
                hash: testCID("every-height-side-\(index)"),
                parentHash: main[index - 1].hash,
                height: UInt64(index)
            )
            _ = try await chain.applyStaged(admission(for: sibling))
            await assertMatchesReference(chain, seed: 0, event: "sibling at \(index)")
            await assertTruncationEquivalent(chain, "sibling at \(index)")
            _ = try await chain.applyStaged(admission(for: main[index]))
            await assertMatchesReference(chain, seed: 0, event: "canonical at \(index)")
            await assertTruncationEquivalent(chain, "canonical at \(index)")
        }

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(
            tip,
            main[depth - 1].hash,
            "the heavier branch must win at every height"
        )
        let truncations = await chain.truncatedCanonicalProjectionCount
        XCTAssertGreaterThan(
            truncations,
            0,
            "the truncated descent must fire on the merged-mining shape"
        )
    }

    /// The safety net for the exclusion seam: drive random block insertions AND
    /// random invalidity exclusions in random order, and after every step assert
    /// the live filtered fork choice is byte-identical to the slow reference
    /// oracle over the same excluded closure. This pins the single-index
    /// integration (no parallel path) against the independent oracle across
    /// insert/exclude interleavings — including exclusions of load-bearing
    /// blocks that demote the tip, and later inserts under excluded subtrees.
    func testRandomExclusionsMatchReferenceOracle() async throws {
        for seed in UInt64(0)..<24 {
            var random = DifferentialRandom(seed: seed &* 2_654_435_761 &+ 1)
            let blocks = plannedBlocks(seed: seed, random: &random)
            let chain = try await ChainState.restore(replaying: [
                admission(for: blocks[0]),
            ])

            var present: [PlannedDifferentialBlock] = [blocks[0]]
            var pendingInsert = Array(blocks.dropFirst())
            var excluded = Set<String>()

            while !pendingInsert.isEmpty {
                // Randomly either insert the next block or exclude a present,
                // non-root, not-yet-excluded block.
                let doExclude = random.nextInt(3) == 0
                if doExclude,
                   let target = present.first(where: {
                       $0.parentHash != nil && !excluded.contains($0.hash)
                   }) {
                    _ = try? await chain.applyStaged(exclusionBatch(for: target))
                    excluded.insert(target.hash)
                } else {
                    let next = pendingInsert.removeFirst()
                    _ = try await chain.applyStaged(admission(for: next))
                    present.append(next)
                }
                await assertMatchesReferenceWithExclusions(
                    chain, seed: seed, event: "interleaved op"
                )
            }

            // A final sweep of exclusions over whatever remains.
            for candidate in present where candidate.parentHash != nil {
                if excluded.contains(candidate.hash) { continue }
                if random.nextInt(2) == 0 { continue }
                _ = try? await chain.applyStaged(exclusionBatch(for: candidate))
                excluded.insert(candidate.hash)
                await assertMatchesReferenceWithExclusions(
                    chain, seed: seed, event: "final exclusion"
                )
            }
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

/// The reference walk's own canonical path, used as the oracle for the
/// emitted commit delta.
private func referencePath(_ chain: ChainState) async -> Set<String> {
    let blocks = await chain.hashToBlock
    return ChainState.referenceCanonicalProjection(in: blocks)?.mainChainHashes
        ?? []
}

/// A commit must report exactly the blocks that joined and left the canonical
/// path — the removal half included, which no standing test covered.
private func assertCommitDelta(
    _ result: SubmissionResult?,
    from previousPath: Set<String>,
    to newPath: Set<String>,
    event: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let added = Set((result?.commit?.mainChainBlocksAdded ?? [:]).keys)
    let removed = result?.commit?.mainChainBlocksRemoved ?? []
    XCTAssertEqual(
        added,
        newPath.subtracting(previousPath),
        "\(event): added",
        file: file,
        line: line
    )
    XCTAssertEqual(
        removed,
        previousPath.subtracting(newPath),
        "\(event): removed",
        file: file,
        line: line
    )
}

private func assertMatchesReference(
    _ chain: ChainState,
    seed: UInt64,
    event: String,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let blocks = await chain.hashToBlock
    guard let expected = ChainState.referenceCanonicalProjection(
        in: blocks
    ) else {
        XCTFail("seed \(seed), \(event): reference has no canonical projection", file: file, line: line)
        return
    }
    let liveTip = await chain.getMainChainTip()
    let livePath = await chain.mainChainHashes
    XCTAssertEqual(liveTip, expected.chainTip, "seed \(seed), \(event): tip", file: file, line: line)
    XCTAssertEqual(livePath, expected.mainChainHashes, "seed \(seed), \(event): path", file: file, line: line)
    await assertMainChainIndexMatchesPath(
        chain,
        expectedPath: expected.mainChainHashes,
        "seed \(seed), \(event): by-height index",
        file: file,
        line: line
    )
}

/// A truncated projection must agree with a whole-chain projection over the
/// SAME live index. Comparing only against the reference oracle cannot tell a
/// wrong truncation from a wrong index — both show up as one divergence. This
/// can: it holds the index fixed and varies only where the descent started.
///
/// This is DIAGNOSTIC rather than additional coverage: `assertMatchesReference`
/// already pins the live path to the oracle, and the two can only disagree with
/// each other when the index is wrong, which that assertion already catches. So
/// it is called at the sites where truncation is the thing under test, not from
/// the shared helper — running a whole-chain projection after every step of
/// every differential test cost 5.5x the suite runtime (836s against 151s) to
/// tell us which half of a failure to look at first.
private func assertTruncationEquivalent(
    _ chain: ChainState,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    guard let full = await chain.debugFullCanonicalProjection() else { return }
    let liveTip = await chain.getMainChainTip()
    let livePath = await chain.mainChainHashes
    XCTAssertEqual(
        liveTip, full.chainTip,
        "\(message): truncated tip vs whole-chain tip over the same index",
        file: file, line: line
    )
    XCTAssertEqual(
        livePath, full.mainChainHashes,
        "\(message): truncated path vs whole-chain path over the same index",
        file: file, line: line
    )
}

private func exclusionBatch(
    for block: PlannedDifferentialBlock
) -> ChainAdmissionBatch {
    ChainAdmissionBatch(facts: [
        .exclusion(ChainExclusionFact(blockHash: block.hash)),
    ])
}

private func assertMatchesReferenceWithExclusions(
    _ chain: ChainState,
    seed: UInt64,
    event: String,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let blocks = await chain.hashToBlock
    let closure = await chain.excludedClosureForTesting
    let liveTip = await chain.getMainChainTip()
    let livePath = await chain.mainChainHashes
    guard let expected = ChainState.referenceCanonicalProjection(
        in: blocks, excluding: closure
    ) else {
        // The only projectionless case here is every root excluded; the live
        // tip must then also be unreachable from a non-excluded root.
        return
    }
    XCTAssertEqual(
        liveTip, expected.chainTip,
        "seed \(seed), \(event): tip", file: file, line: line
    )
    XCTAssertEqual(
        livePath, expected.mainChainHashes,
        "seed \(seed), \(event): path", file: file, line: line
    )
    await assertMainChainIndexMatchesPath(
        chain,
        expectedPath: expected.mainChainHashes,
        "seed \(seed), \(event): by-height index",
        file: file,
        line: line
    )
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
