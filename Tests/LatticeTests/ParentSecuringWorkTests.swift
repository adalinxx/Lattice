import XCTest
#if canImport(os)
import os
#endif
import UInt256
@testable import Lattice

final class ParentSecuringWorkTests: XCTestCase {
    private func work(_ id: String, _ value: UInt64 = 1) -> VerifiedWorkContribution {
        VerifiedWorkContribution(id: id, work: UInt256(value))
    }

    private func block(
        _ hash: String,
        parent: String? = nil,
        height: UInt64,
        children: [String] = [],
        work: [VerifiedWorkContribution]
    ) -> BlockMeta {
        BlockMeta(
            blockHash: hash,
            parentBlockHash: parent,
            blockHeight: height,
            childHashes: children,
            workContributions: work
        )
    }

    private func admission(
        hash: String,
        parent: String?,
        height: UInt64,
        grind: String
    ) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
            .block(ChainBlockFact(
                blockHash: hash,
                parentBlockHash: parent,
                blockHeight: height,
                postStateCID: testCID("\(hash)-post"),
                prevStateCID: testCID("\(hash)-prev"),
                specCID: testCID("\(hash)-spec"),
                target: "1",
                nextTarget: "1",
                timestamp: Int64(height),
                stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: hash,
                contribution: work(grind)
            )),
        ])
    }

    func testParentExportsOneConnectedLocationPerGrind() async throws {
        let root = testCID("direct-parent-root")
        let child = testCID("direct-parent-child")
        let rootGrind = testCID("direct-root-grind")
        let childGrind = testCID("direct-child-grind")
        let chain = makeChain(blocks: [
            block(root, height: 0, children: [child], work: [work(rootGrind, 2)]),
            block(child, parent: root, height: 1, work: [work(childGrind, 5)]),
        ])

        let exported = await chain.parentSecuringWorkSnapshot()
        let snapshot = try XCTUnwrap(exported)

        XCTAssertEqual(snapshot.blockCIDs, [root, child].sorted())
        XCTAssertEqual(snapshot.sourceWork(forBlock: root).work(forGrind: rootGrind), UInt256(2))
        XCTAssertEqual(snapshot.sourceWork(forBlock: child).work(forGrind: childGrind), UInt256(5))
    }

    func testProjectionUsesOnlyExactDirectCarrierBindings() async throws {
        let p0 = testCID("exact-parent-zero")
        let p1 = testCID("exact-parent-one")
        let a = testCID("exact-child-a")
        let b = testCID("exact-child-b")
        let g0 = testCID("exact-grind-zero")
        let g1 = testCID("exact-grind-one")
        let parent = makeChain(blocks: [
            block(p0, height: 0, children: [p1], work: [work(g0, 2)]),
            block(p1, parent: p0, height: 1, work: [work(g1, 7)]),
        ])
        let child = makeChain(blocks: [
            block(a, height: 0, work: [work(testCID("exact-local-a"))]),
            block(b, height: 0, work: [work(testCID("exact-local-b"))]),
        ])
        let exported = await parent.parentSecuringWorkSnapshot()
        let parentWork = try XCTUnwrap(exported)

        let onlyAValue = await child.inheritedWorkSnapshot(
            from: parentWork,
            parentCarrierBlocksByChildBlock: [a: [p0]]
        )
        let onlyA = try XCTUnwrap(onlyAValue)
        XCTAssertEqual(onlyA.sourceWork(forBlock: a).grindIDs, [g0])
        XCTAssertNil(onlyA.sourceWork(forBlock: a).work(forGrind: g1))

        let bothValue = await child.inheritedWorkSnapshot(
            from: parentWork,
            parentCarrierBlocksByChildBlock: [a: [p0], b: [p1]]
        )
        let both = try XCTUnwrap(bothValue)
        XCTAssertEqual(both.sourceWork(forBlock: a).grindIDs, [g0])
        XCTAssertEqual(both.sourceWork(forBlock: b).grindIDs, [g1])
    }

    func testProjectionRejectsOneGrindAtDifferentParentBlocks() async throws {
        let parentA = testCID("conflict-parent-a")
        let parentB = testCID("conflict-parent-b")
        let childA = testCID("conflict-child-a")
        let childB = testCID("conflict-child-b")
        let grind = testCID("conflict-grind")
        let child = makeChain(blocks: [
            block(childA, height: 0, work: [work(testCID("conflict-local-a"))]),
            block(childB, height: 0, work: [work(testCID("conflict-local-b"))]),
        ])
        let invalid = InheritedWorkSnapshot(revision: 1, facts: [
            try XCTUnwrap(InheritedWorkFact(blockCID: parentA, grindID: grind, work: UInt256(1))),
            try XCTUnwrap(InheritedWorkFact(blockCID: parentB, grindID: grind, work: UInt256(1))),
        ])

        let projected = await child.inheritedWorkSnapshot(
            from: invalid,
            parentCarrierBlocksByChildBlock: [childA: [parentA], childB: [parentB]]
        )

        XCTAssertNil(projected)
    }

    func testProjectionRejectsCarrierBoundToTwoAcceptedChildren() async throws {
        let carrier = testCID("duplicate-carrier")
        let childA = testCID("duplicate-child-a")
        let childB = testCID("duplicate-child-b")
        let grind = testCID("duplicate-grind")
        let child = makeChain(blocks: [
            block(childA, height: 0, work: [work(testCID("duplicate-local-a"))]),
            block(childB, height: 0, work: [work(testCID("duplicate-local-b"))]),
        ])
        let parent = InheritedWorkSnapshot(revision: 1, facts: [
            try XCTUnwrap(InheritedWorkFact(blockCID: carrier, grindID: grind, work: UInt256(1)))
        ])

        let projected = await child.inheritedWorkSnapshot(
            from: parent,
            parentCarrierBlocksByChildBlock: [childA: [carrier], childB: [carrier]]
        )

        XCTAssertNil(projected)
    }

    func testProjectionRetainsExactBindingForDisconnectedAcceptedChild() async throws {
        let root = testCID("disconnected-root")
        let missing = testCID("disconnected-missing")
        let orphan = testCID("disconnected-orphan")
        let carrier = testCID("disconnected-carrier")
        let grind = testCID("disconnected-grind")
        let child = makeChain(blocks: [
            block(root, height: 0, work: [work(testCID("disconnected-local"))]),
            block(
                orphan,
                parent: missing,
                height: 2,
                work: [work(testCID("disconnected-orphan-local"))]
            ),
        ])
        let parent = InheritedWorkSnapshot(revision: 1, facts: [
            try XCTUnwrap(InheritedWorkFact(
                blockCID: carrier,
                grindID: grind,
                work: UInt256(9)
            )),
        ])

        let projected = await child.inheritedWorkSnapshot(
            from: parent,
            parentCarrierBlocksByChildBlock: [orphan: [carrier]]
        )

        XCTAssertEqual(projected?.sourceWork(forBlock: orphan).work(forGrind: grind), UInt256(9))
    }

    func testCoreRejectsASecondLocationForOneGrind() async {
        let root = testCID("location-root")
        let child = testCID("location-child")
        let grind = testCID("location-grind")
        let chain = makeChain(blocks: [
            block(root, height: 0, children: [child], work: [work(testCID("location-root-work"))]),
            block(child, parent: root, height: 1, work: [work(testCID("location-child-work"))]),
        ])

        let first = await chain.addWorkContribution(work(grind, 3), to: root)
        let conflicting = await chain.addWorkContribution(work(grind, 5), to: child)

        XCTAssertTrue(first.addedContribution)
        XCTAssertFalse(conflicting.addedContribution)
    }

    func testParentExportCursorReturnsOnlyChangedGrinds() async throws {
        let root = testCID("cursor-root")
        let original = testCID("cursor-original")
        let added = testCID("cursor-added")
        let chain = makeChain(blocks: [
            block(root, height: 0, work: [work(original, 1)]),
        ])
        let baselineValue = await chain.parentSecuringWorkSnapshot()
        let baseline = try XCTUnwrap(baselineValue)

        let addition = await chain.addWorkContribution(
            work(added, 3),
            to: root
        )
        XCTAssertTrue(addition.addedContribution)
        let deltaValue = await chain.parentSecuringWorkSnapshot(
            since: baseline.revision
        )
        let delta = try XCTUnwrap(deltaValue)

        XCTAssertEqual(delta.blockCIDs, [root])
        XCTAssertEqual(delta.sourceWork(forBlock: root).grindIDs, [added])
        XCTAssertEqual(
            delta.sourceWork(forBlock: root).work(forGrind: added),
            UInt256(3)
        )
        let currentValue = await chain.parentSecuringWorkSnapshot(
            since: delta.revision
        )
        let current = try XCTUnwrap(currentValue)
        XCTAssertTrue(current.isEmpty)
    }

    func testProviderRefreshFactsShareTheEnclosingMutationRevision() async throws {
        let root = testCID("provider-revision-root")
        let child = testCID("provider-revision-child")
        let inheritedGrind = testCID("provider-revision-inherited")
        let provider = OSAllocatedUnfairLock(
            initialState: InheritedWorkSnapshot.zero
        )
        let chain = makeChain(blocks: [
            block(
                root,
                height: 0,
                work: [work(testCID("provider-revision-root-work"))]
            ),
        ])
        _ = await chain.mergeInheritedWork(provider.withLock { $0 })
        let baselineValue = await chain.parentSecuringWorkSnapshot()
        let baseline = try XCTUnwrap(baselineValue)
        provider.withLock {
            $0 = InheritedWorkSnapshot(
                revision: 1,
                workByBlock: [
                    root: WorkMeasure(VerifiedWorkContribution(
                        id: inheritedGrind,
                        work: UInt256(3)
                    )),
                ]
            )
        }
        _ = await chain.mergeInheritedWork(provider.withLock { $0 })

        let submitted = try await chain.replay(
            admission(
                hash: child,
                parent: root,
                height: 1,
                grind: testCID("provider-revision-child-work")
            )
        )
        XCTAssertNotNil(submitted)
        let deltaValue = await chain.parentSecuringWorkSnapshot(
            since: baseline.revision
        )
        let delta = try XCTUnwrap(deltaValue)
        XCTAssertEqual(
            delta.sourceWork(forBlock: root).work(forGrind: inheritedGrind),
            UInt256(3)
        )
        let afterValue = await chain.parentSecuringWorkSnapshot(
            since: delta.revision
        )
        let after = try XCTUnwrap(afterValue)
        XCTAssertTrue(after.isEmpty)
    }

    func testParentExportJournalCompactsWithoutLosingOldCursors() async throws {
        let root = testCID("journal-root")
        let base = testCID("journal-base")
        let strengthened = testCID("journal-strengthened")
        let chain = makeChain(blocks: [
            block(root, height: 0, work: [work(base)]),
        ])

        for value in 1...1_000 {
            let result = await chain.addWorkContribution(
                work(strengthened, UInt64(value)),
                to: root
            )
            XCTAssertTrue(result.addedContribution)
        }

        let deltaValue = await chain.parentSecuringWorkSnapshot(since: 0)
        let delta = try XCTUnwrap(deltaValue)
        XCTAssertEqual(delta.blockCIDs, [root])
        XCTAssertEqual(delta.sourceWork(forBlock: root).grindIDs, [strengthened])
        XCTAssertEqual(
            delta.sourceWork(forBlock: root).work(forGrind: strengthened),
            UInt256(1_000)
        )
        let retainedRevisionSlots = await chain.parentWorkChangeRevisionSlotCount
        XCTAssertLessThanOrEqual(retainedRevisionSlots, 64)
    }

    func testDisconnectedParentWorkIsNotExportedUntilAttachment() async throws {
        let root = testCID("connected-root")
        let missing = testCID("connected-missing")
        let orphan = testCID("connected-orphan")
        let rootGrind = testCID("connected-root-grind")
        let orphanGrind = testCID("connected-orphan-grind")
        let chain = makeChain(blocks: [
            block(root, height: 0, work: [work(rootGrind)]),
            block(orphan, parent: missing, height: 2, work: [work(orphanGrind)]),
        ])

        let exported = await chain.parentSecuringWorkSnapshot()
        let snapshot = try XCTUnwrap(exported)

        XCTAssertEqual(snapshot.blockCIDs, [root])
        XCTAssertNil(snapshot.sourceWork(forBlock: orphan).work(forGrind: orphanGrind))
    }

    func testCursorExportsNewlyConnectedWorkExactlyOnce() async throws {
        let root = testCID("late-connect-root")
        let missing = testCID("late-connect-missing")
        let orphan = testCID("late-connect-orphan")
        let rootGrind = testCID("late-connect-root-grind")
        let missingGrind = testCID("late-connect-missing-grind")
        let orphanGrind = testCID("late-connect-orphan-grind")
        let chain = makeChain(blocks: [
            block(root, height: 0, work: [work(rootGrind)]),
            block(orphan, parent: missing, height: 2, work: [work(orphanGrind)]),
        ])
        let baselineValue = await chain.parentSecuringWorkSnapshot()
        let baseline = try XCTUnwrap(baselineValue)

        let result = try await chain.applyStaged(admission(
            hash: missing,
            parent: root,
            height: 1,
            grind: missingGrind
        ))
        XCTAssertTrue(result?.addedBlock == true)
        let deltaValue = await chain.parentSecuringWorkSnapshot(
            since: baseline.revision
        )
        let delta = try XCTUnwrap(deltaValue)

        XCTAssertEqual(Set(delta.blockCIDs), Set([missing, orphan]))
        XCTAssertEqual(
            delta.sourceWork(forBlock: missing).work(forGrind: missingGrind),
            UInt256(1)
        )
        XCTAssertEqual(
            delta.sourceWork(forBlock: orphan).work(forGrind: orphanGrind),
            UInt256(1)
        )
        let replayValue = await chain.parentSecuringWorkSnapshot(
            since: delta.revision
        )
        let replay = try XCTUnwrap(replayValue)
        XCTAssertTrue(replay.isEmpty)
    }

    func testLinearProjectionIsOneFactPerGrind() async throws {
        let count = 2_500
        let parentIDs = (0..<count).map { testCID("scale-parent-\($0)") }
        let childIDs = (0..<count).map { testCID("scale-child-\($0)") }
        let grinds = (0..<count).map { testCID("scale-grind-\($0)") }
        let parent = makeChain(blocks: (0..<count).map { index in
            block(
                parentIDs[index],
                parent: index == 0 ? nil : parentIDs[index - 1],
                height: UInt64(index),
                children: index + 1 == count ? [] : [parentIDs[index + 1]],
                work: [work(grinds[index])]
            )
        })
        let child = makeChain(blocks: (0..<count).map { index in
            block(
                childIDs[index],
                parent: index == 0 ? nil : childIDs[index - 1],
                height: UInt64(index),
                children: index + 1 == count ? [] : [childIDs[index + 1]],
                work: [work(testCID("scale-local-\(index)"))]
            )
        })
        let bindings = Dictionary(uniqueKeysWithValues: (0..<count).map {
            (childIDs[$0], Set([parentIDs[$0]]))
        })

        let exported = await parent.parentSecuringWorkSnapshot()
        let parentWork = try XCTUnwrap(exported)
        let projectedValue = await child.inheritedWorkSnapshot(
            from: parentWork,
            parentCarrierBlocksByChildBlock: bindings
        )
        let projected = try XCTUnwrap(projectedValue)

        XCTAssertEqual(parentWork.blockCIDs.count, count)
        XCTAssertEqual(projected.blockCIDs.count, count)
        XCTAssertEqual(projected.blockCIDs.reduce(0) {
            $0 + projected.sourceWork(forBlock: $1).grindIDs.count
        }, count)
    }
}
