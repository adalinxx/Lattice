import XCTest
import UInt256
@testable import Lattice

@MainActor
final class SegmentBaseGhostDifferentialTests: XCTestCase {
    func testSegmentBaseProjectionMatchesReferenceAcrossRandomizedMutations() async throws {
        for seed: UInt64 in [
            0xC0FFEE, 0xD1FF_EA5E, 0xFACE_FEED, 0xBADC_0DE,
            0x1234_5678, 0x8765_4321, 0x0DDC_0FFE, 0x51DE_CAFE,
        ] {
            var random = DifferentialRandom(seed: seed)
            let blocks = plannedBlocks(seed: seed, random: &random)
            let chain = try await ChainState.restore(replaying: [admission(for: blocks[0])])
            var delivered = [blocks[0].hash]
            var localStrength: [String: UInt64] = [:]
            var localCoverage: [String: Set<String>] = [:]
            var inheritedByBlock: [String: WorkMeasure] = [:]
            var inheritedStrength: [String: UInt64] = [:]
            var inheritedRevision: UInt64 = 0
            let sharedGrinds = (0..<3).map {
                testCID("segment-base-differential-\(seed)-shared-\($0)")
            }

            await assertMatchesReference(chain, seed: seed, event: "genesis")

            // Deliver a descendant before both its parent and grandparent.
            for index in [4, 3] {
                let result = try await chain.applyStaged(admission(for: blocks[index]))
                XCTAssertEqual(result?.addedBlock, true, "seed \(seed), block \(index)")
                delivered.append(blocks[index].hash)
                await assertMatchesReference(chain, seed: seed, event: "block \(index)")
            }

            let localGrind = sharedGrinds[0]
            let localWork: UInt64 = 3
            let localResult = try await chain.applyStaged(workAdmission(
                blockHash: blocks[4].hash,
                id: localGrind,
                work: localWork
            ))
            XCTAssertEqual(localResult?.addedContribution, true, "seed \(seed), initial local work")
            localStrength[localGrind] = localWork
            localCoverage[localGrind] = [blocks[4].hash]
            await assertMatchesReference(chain, seed: seed, event: "local orphan work")

            let inheritedWork: UInt64 = 4
            inheritedByBlock[blocks[3].hash] = WorkMeasure(
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
                let result = try await chain.applyStaged(admission(for: blocks[index]))
                XCTAssertEqual(result?.addedBlock, true, "seed \(seed), block \(index)")
                delivered.append(blocks[index].hash)
                await assertMatchesReference(chain, seed: seed, event: "block \(index)")
            }

            let lateFork = try await chain.applyStaged(admission(for: blocks[5]))
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
                    let result = try await chain.applyStaged(admission(for: blocks[index]))
                    XCTAssertEqual(result?.addedBlock, true, "seed \(seed), block \(index)")
                    delivered.append(blocks[index].hash)
                    await assertMatchesReference(chain, seed: seed, event: "block \(index)")
                    continue
                }

                updateCount += 1
                let blockHash = delivered[random.nextInt(delivered.count)]
                let grind = sharedGrinds[random.nextInt(sharedGrinds.count)]
                if random.nextInt(2) == 0 {
                    let existingStrength = localStrength[grind, default: 0]
                    let alreadyCovered = localCoverage[grind, default: []].contains(blockHash)
                    let work = alreadyCovered || random.nextInt(2) == 0
                        ? max(existingStrength, 1) + UInt64(random.nextInt(3) + 1)
                        : max(existingStrength, 1)
                    let result = try await chain.applyStaged(workAdmission(
                        blockHash: blockHash,
                        id: grind,
                        work: work
                    ))
                    XCTAssertEqual(result?.addedContribution, true, "seed \(seed), local update")
                    localStrength[grind] = max(existingStrength, work)
                    localCoverage[grind, default: []].insert(blockHash)
                    await assertMatchesReference(chain, seed: seed, event: "local update \(updateCount)")
                } else {
                    let existingStrength = inheritedStrength[grind, default: 0]
                    var measure = inheritedByBlock[blockHash] ?? .zero
                    let alreadyCovered = measure.work(forGrind: grind) != nil
                    let work = alreadyCovered || random.nextInt(2) == 0
                        ? max(existingStrength, 1) + UInt64(random.nextInt(3) + 1)
                        : max(existingStrength, 1)
                    XCTAssertTrue(measure.insert(
                        VerifiedWorkContribution(id: grind, work: UInt256(work))
                    ), "seed \(seed), inherited update must add a fact")
                    inheritedByBlock[blockHash] = measure
                    inheritedStrength[grind] = max(existingStrength, work)
                    inheritedRevision += 1
                    let commit = await chain.mergeInheritedWork(InheritedWorkSnapshot(
                        revision: inheritedRevision,
                        workByBlock: inheritedByBlock
                    ))
                    XCTAssertNotNil(commit, "seed \(seed), inherited update")
                    await assertMatchesReference(chain, seed: seed, event: "inherited update \(updateCount)")
                }
            }

            let restored = try ChainState.restore(from: await chain.persist())
            await assertMatchesReference(restored, seed: seed, event: "persist/restore")
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
