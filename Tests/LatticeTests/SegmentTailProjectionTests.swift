import XCTest
import UInt256
@testable import Lattice

@MainActor
final class SegmentTailProjectionTests: XCTestCase {
    func testCanonicalUnaryTailAppendAvoidsFullProjectionAndEmitsLeafDelta() async throws {
        let root = segmentTailBlock(name: "append-root", parent: nil, height: 0)
        let alternate = segmentTailBlock(
            name: "append-alternate", parent: root.hash, height: 1
        )
        let canonicalTail = (0..<64).map { index in
            segmentTailBlock(
                name: "append-canonical-\(index)",
                parent: index == 0 ? root.hash : testCID("segment-tail:append-canonical-\(index - 1)"),
                height: UInt64(index + 1)
            )
        }
        let appended = segmentTailBlock(
            name: "append-canonical-64",
            parent: canonicalTail.last!.hash,
            height: 65
        )

        let chain = try await ChainState.restore(replaying: [segmentTailAdmission(root)])
        _ = try await chain.applyStaged(segmentTailAdmission(alternate))
        for block in canonicalTail {
            _ = try await chain.applyStaged(segmentTailAdmission(block))
        }

        let initialTip = await chain.getMainChainTip()
        let initialMainChain = await chain.mainChainHashes
        XCTAssertEqual(initialTip, canonicalTail.last!.hash)
        XCTAssertEqual(initialMainChain, Set([root.hash] + canonicalTail.map(\.hash)))

        await chain.resetFullCanonicalProjectionCount()
        let submission = try await chain.applyStaged(segmentTailAdmission(appended))
        let result = try XCTUnwrap(submission)
        let commit = try XCTUnwrap(result.commit)
        let projectionCount = await chain.fullCanonicalProjectionCount
        let finalMainChain = await chain.mainChainHashes

        XCTAssertEqual(
            projectionCount,
            0,
            "a canonical unary-tail append must update the cached tail, not rebuild the path"
        )
        XCTAssertTrue(result.extendsMainChain)
        XCTAssertEqual(commit.tipHash, appended.hash)
        XCTAssertEqual(commit.mainChainBlocksAdded, [appended.hash: appended.height])
        XCTAssertEqual(commit.mainChainBlocksRemoved, Set<String>())
        XCTAssertEqual(
            finalMainChain,
            Set([root.hash] + canonicalTail.map(\.hash) + [appended.hash])
        )
        await assertSegmentTailReferenceParity(chain)
    }

    func testCanonicalTailInheritedWorkUsesUnchangedSpineWithoutFullProjection() async throws {
        let root = segmentTailBlock(name: "inherited-root", parent: nil, height: 0)
        let alternate = segmentTailBlock(
            name: "inherited-alternate", parent: root.hash, height: 1
        )
        let canonicalTail = (0..<64).map { index in
            segmentTailBlock(
                name: "inherited-canonical-\(index)",
                parent: index == 0 ? root.hash : testCID("segment-tail:inherited-canonical-\(index - 1)"),
                height: UInt64(index + 1)
            )
        }

        let chain = try await ChainState.restore(replaying: [segmentTailAdmission(root)])
        _ = try await chain.applyStaged(segmentTailAdmission(alternate))
        for block in canonicalTail {
            _ = try await chain.applyStaged(segmentTailAdmission(block))
        }

        let tipBefore = await chain.getMainChainTip()
        let mainChainBefore = await chain.mainChainHashes
        XCTAssertEqual(tipBefore, canonicalTail.last!.hash)

        await chain.resetFullCanonicalProjectionCount()
        let commit = await chain.mergeInheritedWork(InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                canonicalTail.last!.hash: WorkMeasure(VerifiedWorkContribution(
                    id: testCID("segment-tail:inherited-canonical-grind"),
                    work: UInt256(7)
                )),
            ]
        ))
        let projectionCount = await chain.fullCanonicalProjectionCount
        let tipAfter = await chain.getMainChainTip()
        let mainChainAfter = await chain.mainChainHashes

        let nonReorgCommit = try XCTUnwrap(commit)
        XCTAssertFalse(nonReorgCommit.canonicalChanged)
        XCTAssertEqual(nonReorgCommit.tipHash, tipBefore)
        XCTAssertEqual(nonReorgCommit.mainChainBlocksAdded, [:])
        XCTAssertEqual(nonReorgCommit.mainChainBlocksRemoved, Set<String>())
        XCTAssertEqual(projectionCount, 0)
        XCTAssertEqual(tipAfter, tipBefore)
        XCTAssertEqual(mainChainAfter, mainChainBefore)
        await assertSegmentTailReferenceParity(chain)
    }

    func testManyInheritedFragmentsKeepCanonicalTailIncremental() async throws {
        let root = segmentTailBlock(name: "many-inherited-root", parent: nil, height: 0)
        let alternate = segmentTailBlock(
            name: "many-inherited-alternate", parent: root.hash, height: 1
        )
        let canonicalTail = (0..<32).map { index in
            segmentTailBlock(
                name: "many-inherited-canonical-\(index)",
                parent: index == 0
                    ? root.hash
                    : testCID("segment-tail:many-inherited-canonical-\(index - 1)"),
                height: UInt64(index + 1)
            )
        }
        let chain = try await ChainState.restore(replaying: [segmentTailAdmission(root)])
        _ = try await chain.applyStaged(segmentTailAdmission(alternate))
        for block in canonicalTail {
            _ = try await chain.applyStaged(segmentTailAdmission(block))
        }

        await chain.resetFullCanonicalProjectionCount()
        let shared = testCID("segment-tail:many-inherited-shared")
        var contributions: [VerifiedWorkContribution] = []
        for index in 0..<512 {
            let contribution = VerifiedWorkContribution(
                id: index.isMultiple(of: 64)
                    ? shared
                    : testCID("segment-tail:many-inherited-\(index)"),
                work: UInt256(index.isMultiple(of: 64) ? UInt64(index + 1) : 1)
            )
            contributions.append(contribution)
            _ = await chain.mergeInheritedWork(InheritedWorkSnapshot(
                revision: UInt64(index + 1),
                workByBlock: [canonicalTail.last!.hash: WorkMeasure(contribution)]
            ))
        }

        let expected = InheritedWorkSnapshot(
            revision: 512,
            workByBlock: [canonicalTail.last!.hash: WorkMeasure(contributions)]
        )
        let retainedSnapshot = await chain.inheritedWorkSnapshot
        let retained = try XCTUnwrap(retainedSnapshot)
        let projectionCount = await chain.fullCanonicalProjectionCount

        XCTAssertEqual(retained, expected)
        XCTAssertEqual(
            projectionCount,
            0,
            "incremental inherited fragments must not rebuild the unchanged canonical path"
        )
        await assertSegmentTailReferenceParity(chain)
    }

    func testLateForkWithAttachedNestedOrphanTailEmitsExactReorgDelta() async throws {
        let root = segmentTailBlock(name: "reorg-root", parent: nil, height: 0)
        let prefix = segmentTailBlock(name: "reorg-prefix", parent: root.hash, height: 1)
        let a0 = segmentTailBlock(name: "reorg-a0", parent: prefix.hash, height: 2, work: 1)
        let a1 = segmentTailBlock(name: "reorg-a1", parent: a0.hash, height: 3, work: 1)
        let a2 = segmentTailBlock(name: "reorg-a2", parent: a1.hash, height: 4, work: 4)

        // B0 arrives last. Its already accepted descendants form a tail ending
        // at F, then a nested fork where C is the GHOST-selected child.
        let b0 = segmentTailBlock(name: "reorg-b0", parent: prefix.hash, height: 2, work: 1)
        let b1 = segmentTailBlock(name: "reorg-b1", parent: b0.hash, height: 3, work: 1)
        let fork = segmentTailBlock(name: "reorg-fork", parent: b1.hash, height: 4, work: 1)
        let c0 = segmentTailBlock(name: "reorg-c0", parent: fork.hash, height: 5, work: 1)
        let c1 = segmentTailBlock(name: "reorg-c1", parent: c0.hash, height: 6, work: 2)
        let d0 = segmentTailBlock(name: "reorg-d0", parent: fork.hash, height: 5, work: 1)

        let chain = try await ChainState.restore(replaying: [segmentTailAdmission(root)])
        for block in [prefix, a0, a1, a2] {
            _ = try await chain.applyStaged(segmentTailAdmission(block))
        }
        let initialMainChain = await chain.mainChainHashes
        XCTAssertEqual(initialMainChain, Set([root.hash, prefix.hash, a0.hash, a1.hash, a2.hash]))

        // These are deliberately connected below an unavailable B0. They must
        // not affect the selected path until B0 joins the existing prefix.
        for block in [b1, fork, c0, d0, c1] {
            _ = try await chain.applyStaged(segmentTailAdmission(block))
        }
        let tipBeforeAttachment = await chain.getMainChainTip()
        XCTAssertEqual(tipBeforeAttachment, a2.hash)

        let submission = try await chain.applyStaged(segmentTailAdmission(b0))
        let result = try XCTUnwrap(submission)
        let commit = try XCTUnwrap(result.commit)
        let finalMainChain = await chain.mainChainHashes
        let d0IsCanonical = await chain.isOnMainChain(hash: d0.hash)

        XCTAssertEqual(commit.tipHash, c1.hash)
        XCTAssertEqual(
            commit.mainChainBlocksAdded,
            [
                b0.hash: b0.height,
                b1.hash: b1.height,
                fork.hash: fork.height,
                c0.hash: c0.height,
                c1.hash: c1.height,
            ]
        )
        XCTAssertEqual(commit.mainChainBlocksRemoved, Set([a0.hash, a1.hash, a2.hash]))
        XCTAssertEqual(
            finalMainChain,
            Set([root.hash, prefix.hash, b0.hash, b1.hash, fork.hash, c0.hash, c1.hash])
        )
        XCTAssertFalse(d0IsCanonical)
        XCTAssertFalse(commit.mainChainBlocksAdded.keys.contains(d0.hash))
        XCTAssertFalse(commit.mainChainBlocksAdded.keys.contains(root.hash))
        XCTAssertFalse(commit.mainChainBlocksAdded.keys.contains(prefix.hash))
        await assertSegmentTailReferenceParity(chain)
    }

    func testHigherRevisionWithIdenticalInheritedWorkRetainsWatermarkWithoutReorg() async throws {
        let root = segmentTailBlock(name: "revision-root", parent: nil, height: 0)
        let chain = try await ChainState.restore(replaying: [segmentTailAdmission(root)])
        let inherited = WorkMeasure(VerifiedWorkContribution(
            id: testCID("segment-tail:revision-grind"),
            work: UInt256(7)
        ))

        let first = await chain.mergeInheritedWork(InheritedWorkSnapshot(
            revision: 41,
            workByBlock: [root.hash: inherited]
        ))
        XCTAssertNotNil(first)
        XCTAssertFalse(first?.canonicalChanged ?? true)

        let tipBeforeRevisionOnlyUpdate = await chain.getMainChainTip()
        let mainChainBeforeRevisionOnlyUpdate = await chain.mainChainHashes
        let revisionOnlyUpdate = await chain.mergeInheritedWork(InheritedWorkSnapshot(
            revision: 42,
            workByBlock: [root.hash: inherited]
        ))
        let retainedRevision = await chain.inheritedWorkSnapshot?.revision
        let persisted = await chain.persist()
        let tipAfterRevisionOnlyUpdate = await chain.getMainChainTip()
        let mainChainAfterRevisionOnlyUpdate = await chain.mainChainHashes

        XCTAssertNil(revisionOnlyUpdate, "a revision watermark alone must not emit a canonical change")
        XCTAssertEqual(retainedRevision, 42)
        XCTAssertEqual(persisted.inheritedWorkRevision, 42)
        XCTAssertEqual(tipAfterRevisionOnlyUpdate, tipBeforeRevisionOnlyUpdate)
        XCTAssertEqual(mainChainAfterRevisionOnlyUpdate, mainChainBeforeRevisionOnlyUpdate)
    }
}

private struct SegmentTailBlock {
    let hash: String
    let parent: String?
    let height: UInt64
    let work: UInt64
    let name: String
}

private func segmentTailBlock(
    name: String,
    parent: String?,
    height: UInt64,
    work: UInt64 = 1
) -> SegmentTailBlock {
    SegmentTailBlock(
        hash: testCID("segment-tail:\(name)"),
        parent: parent,
        height: height,
        work: work,
        name: name
    )
}

private func segmentTailAdmission(_ block: SegmentTailBlock) -> ChainAdmissionBatch {
    ChainAdmissionBatch(facts: [
        .block(ChainBlockFact(
            blockHash: block.hash,
            parentBlockHash: block.parent,
            blockHeight: block.height,
            postStateCID: testCID("segment-tail:post:\(block.name)"),
            prevStateCID: testCID("segment-tail:prev:\(block.name)"),
            specCID: testCID("segment-tail:spec:\(block.name)"),
            target: "1",
            nextTarget: "1",
            timestamp: Int64(block.height),
            stateDiff: .empty
        )),
        .work(ChainWorkFact(
            blockHash: block.hash,
            contribution: VerifiedWorkContribution(
                id: testCID("segment-tail:work:\(block.name)"),
                work: UInt256(block.work)
            )
        )),
    ])
}

private func assertSegmentTailReferenceParity(
    _ chain: ChainState,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let blocks = await chain.hashToBlock
    let inherited = await chain.inheritedWorkSnapshot ?? .zero
    guard let reference = ChainState.referenceCanonicalProjection(
        in: blocks,
        inherited: inherited
    ) else {
        XCTFail("reference projection missing", file: file, line: line)
        return
    }
    let tip = await chain.getMainChainTip()
    let mainChain = await chain.mainChainHashes
    XCTAssertEqual(
        tip,
        reference.chainTip,
        file: file,
        line: line
    )
    XCTAssertEqual(
        mainChain,
        reference.mainChainHashes,
        file: file,
        line: line
    )
}
