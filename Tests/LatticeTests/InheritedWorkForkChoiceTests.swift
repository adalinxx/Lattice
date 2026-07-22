import XCTest
import UInt256
@testable import Lattice

final class InheritedWorkForkChoiceTests: XCTestCase {
    private func contribution(_ id: String, _ work: UInt64) -> VerifiedWorkContribution {
        VerifiedWorkContribution(id: id, work: UInt256(work))
    }

    private func fork() -> ChainState {
        var root = makeBlockMeta(hash: "root", height: 0)
        let left = makeBlockMeta(hash: "left", previousHash: "root", height: 1)
        let right = makeBlockMeta(hash: "right", previousHash: "root", height: 1)
        root.childHashes = ["left", "right"]
        return makeChain(blocks: [root, left, right], mainChainHashes: ["root", "left"])
    }

    func testInheritedWorkReorganizesOnlyTheReceivingChain() async {
        let chain = fork()
        let rightWins = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: ["right": WorkMeasure(contribution("parent-right", 5))]
        )

        let commit = await chain.setInheritedWorkProvider { rightWins }
        let tip = await chain.getMainChainTip()

        XCTAssertEqual(tip, "right")
        XCTAssertEqual(commit?.mainChainBlocksRemoved, ["left"])
        XCTAssertEqual(commit?.mainChainBlocksAdded, ["right": 1])
    }

    func testProviderOutageRetainsLastAuthenticatedWork() async {
        let chain = fork()
        let inherited = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: ["right": WorkMeasure(contribution("retained-right", 5))]
        )
        _ = await chain.setInheritedWorkProvider { inherited }

        _ = await chain.setInheritedWorkProvider(nil)
        _ = await chain.reevaluateForkChoice()
        let tip = await chain.getMainChainTip()
        let rightWeight = await chain.forkChoiceSnapshot(startingAt: "right")?.subtreeWork

        XCTAssertEqual(tip, "right")
        XCTAssertEqual(rightWeight, WorkSum(UInt256(6)))
    }

    func testDistinctDescendantGrindsSumAlongSameChainAncestry() async {
        var root = makeBlockMeta(hash: "root", height: 0)
        let child = makeBlockMeta(hash: "child", previousHash: "root", height: 1)
        root.childHashes = ["child"]
        let chain = makeChain(blocks: [root, child])
        let inherited = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                "child": WorkMeasure([
                    contribution("parent-one", 5),
                    contribution("parent-two", 7),
                ]),
            ]
        )

        _ = await chain.mergeInheritedWork(inherited)
        let rootWeight = await chain.forkChoiceSnapshot(startingAt: "root")?.subtreeWork
        let childWeight = await chain.forkChoiceSnapshot(startingAt: "child")?.subtreeWork

        XCTAssertEqual(rootWeight, WorkSum(UInt256(14)))
        XCTAssertEqual(childWeight, WorkSum(UInt256(13)))
    }

    func testConflictingLocationUpdateIsRejectedAtomically() async {
        let chain = fork()
        let grind = testCID("conflicting-inherited-grind")
        let first = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: ["left": WorkMeasure(contribution(grind, 3))]
        )
        let conflict = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: ["right": WorkMeasure(contribution(grind, 100))]
        )

        let accepted = await chain.mergeInheritedWork(first)
        let rejected = await chain.mergeInheritedWork(conflict)
        let leftWeight = await chain.forkChoiceSnapshot(startingAt: "left")?.subtreeWork
        let rightWeight = await chain.forkChoiceSnapshot(startingAt: "right")?.subtreeWork

        XCTAssertNotNil(accepted)
        XCTAssertNil(rejected)
        XCTAssertEqual(leftWeight, WorkSum(UInt256(4)))
        XCTAssertEqual(rightWeight, WorkSum(UInt256(1)))
    }

    func testUnknownInheritedLocationReservesTheGrind() async {
        let chain = makeChain(blocks: [makeBlockMeta(hash: "root", height: 0)])
        let grind = testCID("future-location-grind")
        let first = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: ["future-a": WorkMeasure(contribution(grind, 3))]
        )
        let conflictingInherited = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: ["future-b": WorkMeasure(contribution(grind, 100))]
        )

        let accepted = await chain.mergeInheritedWork(first)
        let rejected = await chain.mergeInheritedWork(conflictingInherited)
        let acceptsConflict = await chain.acceptsInheritedWork(
            conflictingInherited
        )
        XCTAssertNotNil(accepted)
        XCTAssertNil(rejected)
        XCTAssertFalse(acceptsConflict)

        let conflictingLocal = await chain.addWorkContribution(
            contribution(grind, 100),
            to: "root"
        )
        XCTAssertFalse(conflictingLocal.addedContribution)
        let retained = await chain.inheritedWorkSnapshot
        XCTAssertEqual(
            retained?.sourceWork(forBlock: "future-a").work(forGrind: grind),
            UInt256(3)
        )
        XCTAssertTrue(retained?.sourceWork(forBlock: "future-b").isEmpty ?? false)
    }

    func testOldAndEqualRevisionsMayAddNewMonotonicFacts() async {
        let chain = fork()
        _ = await chain.mergeInheritedWork(InheritedWorkSnapshot(
            revision: 5,
            workByBlock: ["right": WorkMeasure(contribution("revision-right", 5))]
        ))

        let oldAddition = await chain.mergeInheritedWork(InheritedWorkSnapshot(
            revision: 4,
            workByBlock: ["left": WorkMeasure(contribution("revision-left", 7))]
        ))
        let equalAddition = await chain.mergeInheritedWork(InheritedWorkSnapshot(
            revision: 5,
            workByBlock: ["left": WorkMeasure(contribution("revision-left-two", 1))]
        ))
        let tip = await chain.getMainChainTip()

        XCTAssertNotNil(oldAddition)
        XCTAssertNotNil(equalAddition)
        XCTAssertEqual(tip, "left")
    }

    func testNoncanonicalConnectedBlocksRemainInParentWorkView() async throws {
        let chain = fork()

        let snapshotValue = await chain.parentSecuringWorkSnapshot()
        let snapshot = try XCTUnwrap(snapshotValue)

        XCTAssertEqual(snapshot.blockCIDs, ["left", "right", "root"])
        XCTAssertEqual(
            snapshot.sourceWork(forBlock: "right").grindIDs,
            [testCID("work:right")]
        )
    }

    func testCanonicalPointerDoesNotChangeWorkViewOrGhostChoice() async throws {
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

        let leftViewValue = await leftPointer.parentSecuringWorkSnapshot()
        let rightViewValue = await rightPointer.parentSecuringWorkSnapshot()
        let leftView = try XCTUnwrap(leftViewValue)
        let rightView = try XCTUnwrap(rightViewValue)
        let leftChoice = await leftPointer.forkChoiceSnapshot(startingAt: "root")
        let rightChoice = await rightPointer.forkChoiceSnapshot(startingAt: "root")

        XCTAssertEqual(leftView, rightView)
        XCTAssertEqual(leftChoice, rightChoice)
        XCTAssertEqual(leftChoice?.tipHash, "right")
    }

    func testDisconnectedWorkBecomesVisibleOnlyAfterSameChainAttachment() async throws {
        var root = makeBlockMeta(hash: "root", height: 0)
        let orphan = makeBlockMeta(hash: "orphan", previousHash: "missing", height: 2)
        let chain = makeChain(blocks: [root, orphan], mainChainHashes: ["root"])

        let beforeValue = await chain.parentSecuringWorkSnapshot()
        let before = try XCTUnwrap(beforeValue)
        XCTAssertEqual(before.blockCIDs, ["root"])

        let missing = makeBlockMeta(
            hash: "missing",
            previousHash: "root",
            height: 1,
            childHashes: ["orphan"]
        )
        root.childHashes = ["missing"]
        let attached = makeChain(blocks: [root, missing, orphan])
        let afterValue = await attached.parentSecuringWorkSnapshot()
        let after = try XCTUnwrap(afterValue)

        XCTAssertEqual(after.blockCIDs, ["missing", "orphan", "root"])
    }

    func testRecoveryReportsEveryMissingImmediatePredecessor() async {
        let root = makeBlockMeta(hash: "root", height: 0)
        var parent = makeBlockMeta(hash: "parent", previousHash: "missing", height: 1)
        let descendant = makeBlockMeta(hash: "descendant", previousHash: "parent", height: 2)
        parent.childHashes = ["descendant"]
        let chain = makeChain(
            blocks: [root, parent, descendant],
            mainChainHashes: ["root"]
        )

        let requirements = await chain.unresolvedSameChainPredecessors()

        XCTAssertEqual(requirements, [
            SameChainPredecessorRequirement(
                descendantCID: "descendant",
                predecessorCID: "parent"
            ),
            SameChainPredecessorRequirement(
                descendantCID: "parent",
                predecessorCID: "missing"
            ),
        ])
    }

    func testRestoreRejectsOneLocalGrindAtTwoBlocks() {
        let grind = testCID("restore-duplicate-grind")
        let root = BlockMeta(
            blockHash: "root",
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: ["child"],
            workContributions: [contribution(grind, 1)]
        )
        let child = BlockMeta(
            blockHash: "child",
            parentBlockHash: "root",
            blockHeight: 1,
            childHashes: [],
            workContributions: [contribution(grind, 1)]
        )

        XCTAssertThrowsError(try ChainState(
            chainTip: "child",
            mainChainHashes: ["root", "child"],
            indexToBlockHash: [0: ["root"], 1: ["child"]],
            hashToBlock: ["root": root, "child": child]
        )) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreRejectsNonreciprocalKnownEdges() {
        let root = makeBlockMeta(hash: "root", height: 0, childHashes: ["child"])
        let child = makeBlockMeta(hash: "child", previousHash: "other", height: 1)

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
