import XCTest
import UInt256
@testable import Lattice

final class InheritedWorkForkChoiceTests: XCTestCase {
    private func contribution(_ id: String, _ work: UInt64) -> VerifiedWorkContribution {
        VerifiedWorkContribution(id: id, work: UInt256(work))
    }

    private func exportedWork(
        _ chain: ChainState,
        parentBlocks: Set<String>
    ) async throws -> WorkMeasure {
        let snapshot = await chain.inheritedWorkSnapshot(
            forChildCoverage: ["child": parentBlocks]
        )
        return try XCTUnwrap(snapshot).work(forBlock: "child")
    }

    private func stagedHash(_ name: String) -> String {
        testCID("orphan-boundary-live:\(name)")
    }

    private func stagedAdmission(
        _ name: String,
        parent: String?,
        height: UInt64,
        contribution: VerifiedWorkContribution
    ) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
            .block(ChainBlockFact(
                blockHash: stagedHash(name),
                parentBlockHash: parent,
                blockHeight: height,
                postStateCID: testCID("orphan-boundary-live:post:\(name)"),
                prevStateCID: testCID("orphan-boundary-live:prev:\(name)"),
                specCID: testCID("orphan-boundary-live:spec:\(name)"),
                target: "1",
                nextTarget: "1",
                timestamp: Int64(height),
                stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: stagedHash(name),
                contribution: contribution
            )),
        ])
    }

    private func fork() -> ChainState {
        var root = makeBlockMeta(hash: "root", height: 0)
        let left = makeBlockMeta(hash: "left", previousHash: "root", height: 1)
        let right = makeBlockMeta(hash: "right", previousHash: "root", height: 1)
        root.childHashes = ["left", "right"]
        return makeChain(
            blocks: [root, left, right],
            mainChainHashes: ["root", "left"]
        )
    }

    func testLiveInheritedWorkCanChangeOnlyThisChainsForkChoice() async throws {
        let chain = fork()
        let rightWins = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: ["right": WorkMeasure(contribution("parent-right", 5))]
        )

        let firstCommit = await chain.setInheritedWorkProvider { rightWins }
        let firstTip = await chain.getMainChainTip()
        XCTAssertEqual(firstTip, "right")
        XCTAssertEqual(firstCommit?.mainChainBlocksRemoved, ["left"])
        XCTAssertEqual(firstCommit?.mainChainBlocksAdded, ["right": 1])

        let leftWins = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: ["left": WorkMeasure(contribution("parent-left", 7))]
        )
        let secondCommit = await chain.setInheritedWorkProvider { leftWins }
        let secondTip = await chain.getMainChainTip()
        XCTAssertEqual(secondTip, "left")
        XCTAssertTrue(secondCommit?.canonicalChanged ?? false)
        let retainedRightWork = try await exportedWork(chain, parentBlocks: ["right"])
        XCTAssertEqual(retainedRightWork.total, WorkSum(UInt256(6)))

        _ = await chain.setInheritedWorkProvider(nil)
        let workDuringOutage = try await exportedWork(chain, parentBlocks: ["right"])
        XCTAssertEqual(workDuringOutage, retainedRightWork)
    }

    func testDistinctGrindsAlongSecuredPathSumAndOverlapCountsOnce() async throws {
        var root = makeBlockMeta(hash: "root", height: 0)
        let child = BlockMeta(
            blockHash: "child",
            parentBlockHash: "root",
            blockHeight: 1,
            childHashes: [],
            workContributions: [contribution("child-local", 3)]
        )
        root.childHashes = ["child"]
        let chain = makeChain(blocks: [root, child])
        let rootGrind = try XCTUnwrap(root.workContributions.values.first)
        let inherited = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                "child": WorkMeasure([
                    contribution(rootGrind.id, 1),
                    contribution("parent-one", 5),
                    contribution("parent-two", 7),
                ]),
            ]
        )
        _ = await chain.setInheritedWorkProvider { inherited }

        let secured = try await exportedWork(chain, parentBlocks: ["root"])
        XCTAssertEqual(secured.grindIDs.count, 4)
        XCTAssertEqual(secured.total, WorkSum(UInt256(16)))
    }

    func testSharedGrindAcrossSiblingBranchesIsNeutral() async {
        let chain = fork()
        let shared = contribution("shared", 10)
        _ = await chain.addWorkContribution(shared, to: "left")
        _ = await chain.addWorkContribution(shared, to: "right")
        _ = await chain.addWorkContribution(contribution("right-extra", 2), to: "right")

        let tip = await chain.getMainChainTip()
        let rootWork = await chain.subtreeWeight(forHash: "root")
        XCTAssertEqual(tip, "right")
        XCTAssertEqual(rootWork, WorkSum(UInt256(15)))
    }

    func testStrongestGrindQuantityIsGlobalAcrossLocalAndInheritedCoverage() async {
        let chain = fork()
        let shared = contribution("shared-cross-boundary", 1)
        _ = await chain.addWorkContribution(shared, to: "left")

        let first = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: ["right": WorkMeasure(shared)]
        )
        _ = await chain.setInheritedWorkProvider { first }

        let stronger = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: [
                "right": WorkMeasure(contribution(shared.id, 100)),
            ]
        )
        let commit = await chain.setInheritedWorkProvider { stronger }
        let tip = await chain.getMainChainTip()

        XCTAssertEqual(tip, "left")
        XCTAssertFalse(commit?.canonicalChanged ?? true)
    }

    func testUnknownInheritedCoverageStillStrengthensKnownLocalGrind() async {
        let chain = fork()
        let shared = contribution("future-shared-grind", 1)
        _ = await chain.addWorkContribution(shared, to: "left")
        _ = await chain.addWorkContribution(contribution("right-extra", 10), to: "right")
        let before = await chain.getMainChainTip()
        XCTAssertEqual(before, "right")

        let future = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                testCID("future-block"): WorkMeasure(contribution(shared.id, 100)),
            ]
        )
        _ = await chain.setInheritedWorkProvider { future }

        let after = await chain.getMainChainTip()
        XCTAssertEqual(after, "left")
    }

    func testStaleInheritedRevisionCannotWeakenRetainedWork() async throws {
        let chain = fork()
        let current = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: ["right": WorkMeasure(contribution("current", 5))]
        )
        _ = await chain.setInheritedWorkProvider { current }

        let stale = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: ["right": WorkMeasure(contribution("current", 1))]
        )
        let commit = await chain.setInheritedWorkProvider { stale }
        let tip = await chain.getMainChainTip()
        let leftWork = try await exportedWork(chain, parentBlocks: ["left"])

        XCTAssertNil(commit)
        XCTAssertEqual(tip, "right")
        XCTAssertEqual(leftWork.total, WorkSum(UInt256(1)))
    }

    func testEqualInheritedRevisionCanAddNewCoverage() async {
        let chain = fork()
        let first = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: ["right": WorkMeasure(contribution("right-parent", 5))]
        )
        _ = await chain.setInheritedWorkProvider { first }

        let additional = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: ["left": WorkMeasure(contribution("left-parent", 7))]
        )
        let commit = await chain.setInheritedWorkProvider { additional }
        let tip = await chain.getMainChainTip()

        XCTAssertTrue(commit?.canonicalChanged ?? false)
        XCTAssertEqual(tip, "left")
    }

    func testInheritedWorkRefreshAdvancesAtomicExportWithoutReorg() async throws {
        let chain = fork()
        let first = InheritedWorkSnapshot(
            revision: 4,
            workByBlock: ["root": WorkMeasure(contribution("parent-one", 4))]
        )
        let firstCommit = await chain.setInheritedWorkProvider { first }
        let firstExportValue = await chain.inheritedWorkSnapshot(
            forChildCoverage: ["child": ["root"]]
        )
        let firstExport = try XCTUnwrap(firstExportValue)

        XCTAssertEqual(firstCommit?.revision, 1)
        XCTAssertFalse(firstCommit?.canonicalChanged ?? true)
        XCTAssertEqual(firstExport.revision, 1)
        XCTAssertEqual(
            firstExport.work(forBlock: "child").total,
            WorkSum(UInt256(7))
        )

        let second = InheritedWorkSnapshot(
            revision: 5,
            workByBlock: ["root": WorkMeasure(contribution("parent-two", 2))]
        )
        let secondCommit = await chain.setInheritedWorkProvider { second }
        let secondExportValue = await chain.inheritedWorkSnapshot(
            forChildCoverage: ["child": ["root"]]
        )
        let secondExport = try XCTUnwrap(secondExportValue)

        XCTAssertEqual(secondCommit?.revision, 2)
        XCTAssertFalse(secondCommit?.canonicalChanged ?? true)
        XCTAssertEqual(secondExport.revision, 2)
        XCTAssertEqual(
            secondExport.work(forBlock: "child").total,
            WorkSum(UInt256(9))
        )
        let missing = await chain.inheritedWorkSnapshot(
            forChildCoverage: ["child": ["missing"]]
        )
        XCTAssertNil(missing)
    }

    func testNoncanonicalBlocksStillExportSecuringWork() async throws {
        let chain = fork()

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "left")
        let rightWork = try await exportedWork(chain, parentBlocks: ["right"])
        XCTAssertEqual(rightWork.grindIDs, [testCID("work:right")])
        XCTAssertEqual(rightWork.total, WorkSum(UInt256(1)))
    }

    func testCanonicalPointerDoesNotChangeWorkOrChildExport() async throws {
        var root = makeBlockMeta(hash: "root", height: 0)
        let left = BlockMeta(
            blockHash: "left",
            parentBlockHash: "root",
            blockHeight: 1,
            childHashes: [],
            workContributions: [contribution("left-work", 3)]
        )
        let right = BlockMeta(
            blockHash: "right",
            parentBlockHash: "root",
            blockHeight: 1,
            childHashes: [],
            workContributions: [contribution("right-work", 5)]
        )
        root.childHashes = ["left", "right"]
        let leftPointer = makeChain(
            blocks: [root, left, right],
            mainChainHashes: ["root", "left"]
        )
        let rightPointer = makeChain(
            blocks: [root, left, right],
            mainChainHashes: ["root", "right"]
        )

        let coverage: Set<String> = ["left", "right"]
        let leftExport = try await exportedWork(leftPointer, parentBlocks: coverage)
        let rightExport = try await exportedWork(rightPointer, parentBlocks: coverage)
        let leftChoice = await leftPointer.forkChoiceSnapshot(startingAt: "root")
        let rightChoice = await rightPointer.forkChoiceSnapshot(startingAt: "root")

        XCTAssertEqual(leftExport, rightExport)
        XCTAssertEqual(leftChoice, rightChoice)
        XCTAssertEqual(leftChoice?.tipHash, "right")
    }

    func testAcceptedChildQuotientExportsSparseForkEquivalentToExpandedWork()
        async throws {
        let parentRoot = testCID("frontier-fork-parent-root")
        let parentLeft = testCID("frontier-fork-parent-left")
        let parentRight = testCID("frontier-fork-parent-right")
        let childRoot = testCID("frontier-fork-child-root")
        let childLeft = testCID("frontier-fork-child-left")
        let childRight = testCID("frontier-fork-child-right")
        let childInvalid = testCID("frontier-fork-child-invalid")
        let baseGrind = testCID("frontier-fork-base-grind")
        let leftGrind = testCID("frontier-fork-left-grind")
        let rightGrind = testCID("frontier-fork-right-grind")
        let sharedGrind = testCID("frontier-fork-shared-grind")

        var root = BlockMeta(
            blockHash: parentRoot,
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [parentLeft, parentRight],
            workContributions: [contribution(baseGrind, 2)]
        )
        let left = BlockMeta(
            blockHash: parentLeft,
            parentBlockHash: parentRoot,
            blockHeight: 1,
            childHashes: [],
            workContributions: [
                contribution(leftGrind, 5),
                contribution(sharedGrind, 3),
            ]
        )
        let right = BlockMeta(
            blockHash: parentRight,
            parentBlockHash: parentRoot,
            blockHeight: 1,
            childHashes: [],
            workContributions: [
                contribution(rightGrind, 7),
                contribution(sharedGrind, 9),
            ]
        )
        root.childHashes = [left.blockHash, right.blockHash]
        let parent = makeChain(blocks: [root, left, right])
        let sparseValue = await parent.inheritedWorkSnapshot(
            forChildCoverage: [
                childRoot: [parentRoot, parentLeft],
                childLeft: [parentLeft],
                childRight: [parentRight],
                // The parent retained these bytes, but the child process did
                // not accept them and therefore gives them no ancestry hint.
                childInvalid: [parentLeft],
            ],
            acceptedChildPredecessorByBlock: [
                childRoot: nil,
                childLeft: childRoot,
                childRight: childRoot,
            ]
        )
        let sparse = try XCTUnwrap(sparseValue)

        assertInheritedWorkMeasure(
            sparse.sourceWork(forBlock: childRoot),
            equals: [baseGrind: 2]
        )
        assertInheritedWorkMeasure(
            sparse.sourceWork(forBlock: childLeft),
            equals: [leftGrind: 5, sharedGrind: 9]
        )
        assertInheritedWorkMeasure(
            sparse.sourceWork(forBlock: childRight),
            equals: [rightGrind: 7, sharedGrind: 9]
        )
        assertInheritedWorkMeasure(
            sparse.sourceWork(forBlock: childInvalid),
            equals: [leftGrind: 5, sharedGrind: 9]
        )

        let expanded = InheritedWorkSnapshot(
            revision: sparse.revision,
            workByBlock: [
                childRoot: WorkMeasure([
                    contribution(baseGrind, 2),
                    contribution(leftGrind, 5),
                    contribution(rightGrind, 7),
                    contribution(sharedGrind, 9),
                ]),
                childLeft: WorkMeasure([
                    contribution(leftGrind, 5),
                    contribution(sharedGrind, 9),
                ]),
                childRight: WorkMeasure([
                    contribution(rightGrind, 7),
                    contribution(sharedGrind, 9),
                ]),
            ]
        )
        let childBlocks: [BlockMeta] = [
            BlockMeta(
                blockHash: childRoot,
                parentBlockHash: nil,
                blockHeight: 0,
                childHashes: [childLeft, childRight],
                workContributions: [contribution(testCID("frontier-child-local-root"), 1)]
            ),
            BlockMeta(
                blockHash: childLeft,
                parentBlockHash: childRoot,
                blockHeight: 1,
                childHashes: [],
                workContributions: [contribution(testCID("frontier-child-local-left"), 1)]
            ),
            BlockMeta(
                blockHash: childRight,
                parentBlockHash: childRoot,
                blockHeight: 1,
                childHashes: [],
                workContributions: [contribution(testCID("frontier-child-local-right"), 1)]
            ),
        ]
        let sparseChild = makeChain(blocks: childBlocks)
        let expandedChild = makeChain(blocks: childBlocks)
        _ = await sparseChild.setInheritedWorkProvider { sparse }
        _ = await expandedChild.setInheritedWorkProvider { expanded }
        let sparseTip = await sparseChild.getMainChainTip()
        let expandedTip = await expandedChild.getMainChainTip()
        let sparseForkChoice = await sparseChild.forkChoiceSnapshot(
            startingAt: childRoot
        )
        let expandedForkChoice = await expandedChild.forkChoiceSnapshot(
            startingAt: childRoot
        )

        XCTAssertEqual(sparseTip, expandedTip)
        XCTAssertEqual(sparseForkChoice, expandedForkChoice)
    }

    func testAcceptedChildCoverageQuotientIsConservativeAndRejectsCycles() async {
        let chain = fork()
        let child = testCID("frontier-invalid-child")
        let missing = testCID("frontier-invalid-missing")
        let other = testCID("frontier-invalid-other")
        let coverage = [child: Set(["root"])]

        let conservative = await chain.inheritedWorkSnapshot(
            forChildCoverage: coverage,
            acceptedChildPredecessorByBlock: [child: missing]
        )
        let cyclic = await chain.inheritedWorkSnapshot(
            forChildCoverage: [child: ["root"], other: ["root"]],
            acceptedChildPredecessorByBlock: [child: other, other: child]
        )
        XCTAssertNotNil(conservative)
        XCTAssertNil(cyclic)
    }

    func testDisconnectedOrphanCannotExportSecuringWork() async {
        let root = makeBlockMeta(hash: "root", height: 0)
        let orphan = makeBlockMeta(
            hash: "orphan",
            previousHash: "missing",
            height: 2
        )
        let incomplete = makeChain(
            blocks: [root, orphan],
            mainChainHashes: ["root"]
        )
        let incompleteExport = await incomplete.inheritedWorkSnapshot(
            forChildCoverage: ["child": ["orphan"]]
        )
        let incompleteQuotient = await incomplete.connectedAcceptedCoverageQuotient(
            for: ["root", "orphan"]
        )

        XCTAssertNil(incompleteExport)
        XCTAssertEqual(Set(incompleteQuotient.keys), ["root"])
        XCTAssertEqual(incompleteQuotient["root"], .some(nil))

        var connectedRoot = root
        connectedRoot.childHashes = ["missing"]
        let missing = makeBlockMeta(
            hash: "missing",
            previousHash: "root",
            height: 1,
            childHashes: ["orphan"]
        )
        let complete = makeChain(
            blocks: [connectedRoot, missing, orphan],
            mainChainHashes: ["root", "missing", "orphan"]
        )
        let completeExport = await complete.inheritedWorkSnapshot(
            forChildCoverage: ["child": ["orphan"]]
        )
        let completeQuotient = await complete.connectedAcceptedCoverageQuotient(
            for: ["root", "orphan"]
        )

        XCTAssertNotNil(completeExport)
        XCTAssertEqual(Set(completeQuotient.keys), ["root", "orphan"])
        XCTAssertEqual(completeQuotient["root"], .some(nil))
        XCTAssertEqual(completeQuotient["orphan"], .some("root"))
    }

    func testDisconnectedCoverageDoesNotSuppressConnectedExport() async throws {
        var root = makeBlockMeta(hash: "root", height: 0)
        let connected = makeBlockMeta(
            hash: "connected",
            previousHash: "root",
            height: 1
        )
        let disconnected = makeBlockMeta(
            hash: "disconnected",
            previousHash: "missing",
            height: 2
        )
        root.childHashes = ["connected"]
        let chain = makeChain(
            blocks: [root, connected, disconnected],
            mainChainHashes: ["root", "connected"]
        )

        let exported = await chain.inheritedWorkSnapshot(
            forChildCoverage: [
                "connected-child": ["connected"],
                "mixed-child": ["connected", "disconnected"],
                "disconnected-child": ["disconnected"],
            ]
        )
        let snapshot = try XCTUnwrap(exported)

        XCTAssertEqual(
            snapshot.work(forBlock: "mixed-child"),
            snapshot.work(forBlock: "connected-child")
        )
        XCTAssertFalse(snapshot.blockCIDs.contains("disconnected-child"))
        let unknownExport = await chain.inheritedWorkSnapshot(
            forChildCoverage: ["child": ["connected", "unknown"]]
        )
        XCTAssertNil(unknownExport)
    }

    func testRecoveryReportsEveryUnresolvedImmediatePredecessor() async {
        let root = makeBlockMeta(hash: "root", height: 0)
        var parent = makeBlockMeta(
            hash: "parent",
            previousHash: "missing",
            height: 1
        )
        let descendant = makeBlockMeta(
            hash: "descendant",
            previousHash: "parent",
            height: 2
        )
        parent.childHashes = ["descendant"]
        let chain = makeChain(
            blocks: [root, parent, descendant],
            mainChainHashes: ["root"]
        )

        let requirements = await chain.unresolvedSameChainPredecessors()

        XCTAssertEqual(
            requirements,
            [
                SameChainPredecessorRequirement(
                    descendantCID: "descendant",
                    predecessorCID: "parent"
                ),
                SameChainPredecessorRequirement(
                    descendantCID: "parent",
                    predecessorCID: "missing"
                ),
            ]
        )
    }

    func testInheritedSharedGrindDoesNotProjectThroughMissingOrphanParent() async {
        let shared = contribution("orphan-shared", 2)
        let orphanOnly = contribution("orphan-only", 17)
        let root = makeBlockMeta(hash: "root", height: 0)
        let orphan = BlockMeta(
            blockHash: "orphan",
            parentBlockHash: "missing",
            blockHeight: 2,
            childHashes: [],
            workContributions: [shared, orphanOnly]
        )
        let chain = makeChain(
            blocks: [root, orphan],
            mainChainHashes: ["root"]
        )
        let inherited = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: ["root": WorkMeasure(shared)]
        )

        _ = await chain.setInheritedWorkProvider { inherited }

        let tip = await chain.getMainChainTip()
        let rootChoice = await chain.forkChoiceSnapshot(startingAt: "root")
        XCTAssertEqual(tip, "root")
        XCTAssertEqual(rootChoice?.subtreeWork, WorkSum(UInt256(3)))
    }

    func testAcceptedOrphanStrengthensSharedConnectedCoverageWithoutRoutingItself() async throws {
        let rootHash = testCID("orphan-boundary-root")
        let leftHash = testCID("orphan-boundary-left")
        let rightHash = testCID("orphan-boundary-right")
        let missingHash = testCID("orphan-boundary-missing")
        let orphanHash = testCID("orphan-boundary-orphan")
        let shared = contribution(testCID("orphan-boundary-shared"), 2)
        let rightOnly = contribution(testCID("orphan-boundary-right-only"), 10)
        let orphanStrength = contribution(shared.id, 100)
        let root = BlockMeta(
            blockHash: rootHash,
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [leftHash, rightHash],
            workContributions: [
                contribution(testCID("orphan-boundary-root-work"), 1),
            ]
        )
        let left = BlockMeta(
            blockHash: leftHash,
            parentBlockHash: rootHash,
            blockHeight: 1,
            childHashes: [],
            workContributions: [shared]
        )
        let right = BlockMeta(
            blockHash: rightHash,
            parentBlockHash: rootHash,
            blockHeight: 1,
            childHashes: [],
            workContributions: [rightOnly]
        )
        let orphan = BlockMeta(
            blockHash: orphanHash,
            parentBlockHash: missingHash,
            blockHeight: 2,
            childHashes: [],
            workContributions: [orphanStrength]
        )
        let chain = makeChain(
            blocks: [root, left, right, orphan],
            mainChainHashes: [rootHash, rightHash]
        )

        _ = await chain.reevaluateForkChoice()
        let tip = await chain.getMainChainTip()
        let orphanChoice = await chain.forkChoiceSnapshot(startingAt: orphanHash)
        let leftCumulative = await chain.getCumulativeWork(forHash: leftHash)
        let tipCumulative = await chain.getCumulativeWork(limit: 1)
        let rootSubtree = await chain.subtreeWeight(forHash: rootHash)
        XCTAssertEqual(tip, leftHash)
        XCTAssertNil(orphanChoice)
        XCTAssertEqual(leftCumulative, WorkSum(UInt256(101)))
        XCTAssertEqual(tipCumulative, WorkSum(UInt256(101)))
        XCTAssertEqual(rootSubtree, WorkSum(UInt256(111)))

        let exported = try await exportedWork(chain, parentBlocks: [leftHash])
        XCTAssertEqual(exported.work(forGrind: shared.id), orphanStrength.work)

        let persisted = await chain.persist()
        let persistedLeft = try XCTUnwrap(
            persisted.blocks.first { $0.blockHash == leftHash }
        )
        XCTAssertEqual(persistedLeft.workContributions, [shared])

        let restored = try ChainState.restore(from: persisted)
        let restoredTip = await restored.getMainChainTip()
        let restoredOrphanChoice = await restored.forkChoiceSnapshot(
            startingAt: orphanHash
        )
        let restoredLeftCumulative = await restored.getCumulativeWork(
            forHash: leftHash
        )
        XCTAssertEqual(restoredTip, leftHash)
        XCTAssertNil(restoredOrphanChoice)
        XCTAssertEqual(restoredLeftCumulative, WorkSum(UInt256(101)))
        let restoredExport = try await exportedWork(
            restored,
            parentBlocks: [leftHash]
        )
        XCTAssertEqual(restoredExport.work(forGrind: shared.id), orphanStrength.work)
    }

    func testAcceptedOrphanSeparatesQuantityStrengtheningFromCoverageActivation() async throws {
        let rootHash = stagedHash("root")
        let leftHash = stagedHash("left")
        let missingHash = stagedHash("missing")
        let orphanHash = stagedHash("orphan")
        let shared = contribution(testCID("orphan-boundary-live:shared"), 2)
        let rightOnly = contribution(testCID("orphan-boundary-live:right-only"), 10)
        let orphanOnly = contribution(testCID("orphan-boundary-live:orphan-only"), 1)
        let root = stagedAdmission(
            "root",
            parent: nil,
            height: 0,
            contribution: contribution(testCID("orphan-boundary-live:root"), 1)
        )
        let left = stagedAdmission(
            "left",
            parent: rootHash,
            height: 1,
            contribution: shared
        )
        let right = stagedAdmission(
            "right",
            parent: rootHash,
            height: 1,
            contribution: rightOnly
        )
        let orphan = stagedAdmission(
            "orphan",
            parent: missingHash,
            height: 3,
            contribution: orphanOnly
        )

        let chain = try await ChainState.restore(replaying: [root])
        for batch in [left, right, orphan] {
            _ = try await chain.applyStaged(batch)
        }
        let orphanStrength = contribution(shared.id, 100)
        let update = await chain.addWorkContribution(orphanStrength, to: orphanHash)
        XCTAssertTrue(update.addedContribution)

        let tipBeforeAttachment = await chain.getMainChainTip()
        XCTAssertEqual(tipBeforeAttachment, leftHash)
        let exportBeforeAttachment = try await exportedWork(
            chain,
            parentBlocks: [leftHash]
        )
        XCTAssertEqual(exportBeforeAttachment.work(forGrind: shared.id), orphanStrength.work)
        XCTAssertNil(exportBeforeAttachment.work(forGrind: orphanOnly.id))
        let orphanChoice = await chain.forkChoiceSnapshot(startingAt: orphanHash)
        XCTAssertNil(orphanChoice)

        let persisted = await chain.persist()
        let persistedOrphan = try XCTUnwrap(
            persisted.blocks.first { $0.blockHash == orphanHash }
        )
        XCTAssertEqual(
            persistedOrphan.workContributions.sorted { $0.id < $1.id },
            [orphanOnly, orphanStrength].sorted { $0.id < $1.id }
        )

        let restored = try ChainState.restore(from: persisted)
        let restoredTipBeforeAttachment = await restored.getMainChainTip()
        XCTAssertEqual(restoredTipBeforeAttachment, leftHash)
        let restoredExportBeforeAttachment = try await exportedWork(
            restored,
            parentBlocks: [leftHash]
        )
        XCTAssertEqual(
            restoredExportBeforeAttachment.work(forGrind: shared.id),
            orphanStrength.work
        )
        XCTAssertNil(restoredExportBeforeAttachment.work(forGrind: orphanOnly.id))

        let missing = stagedAdmission(
            "missing",
            parent: leftHash,
            height: 2,
            contribution: shared
        )
        _ = try await restored.applyStaged(missing)

        let tipAfterAttachment = await restored.getMainChainTip()
        XCTAssertEqual(tipAfterAttachment, orphanHash)
        let exportAfterAttachment = try await exportedWork(
            restored,
            parentBlocks: [leftHash]
        )
        XCTAssertEqual(
            exportAfterAttachment.work(forGrind: shared.id),
            orphanStrength.work
        )
        XCTAssertEqual(exportAfterAttachment.work(forGrind: orphanOnly.id), orphanOnly.work)
    }

    func testPackageInitializerRejectsNonreciprocalKnownEdges() {
        let root = makeBlockMeta(
            hash: "root",
            height: 0,
            childHashes: ["child"]
        )
        let child = makeBlockMeta(
            hash: "child",
            previousHash: "other",
            height: 1
        )

        XCTAssertThrowsError(try ChainState(
            chainTip: "root",
            mainChainHashes: ["root"],
            indexToBlockHash: [:],
            hashToBlock: ["root": root, "child": child]
        )) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }
}
