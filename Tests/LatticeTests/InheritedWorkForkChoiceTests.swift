import XCTest
import UInt256
@testable import Lattice

final class InheritedWorkForkChoiceTests: XCTestCase {
    private func cid(_ label: String) -> String { testCID(label) }

    private func contribution(_ id: String, _ work: UInt64) -> VerifiedWorkContribution {
        VerifiedWorkContribution(id: id, work: UInt256(work))
    }

    private func fork() -> ChainState {
        var root = makeBlockMeta(hash: cid("root"), height: 0)
        let left = makeBlockMeta(
            hash: cid("left"), previousHash: cid("root"), height: 1
        )
        let right = makeBlockMeta(
            hash: cid("right"), previousHash: cid("root"), height: 1
        )
        root.childHashes = [cid("left"), cid("right")]
        return makeChain(
            blocks: [root, left, right],
            mainChainHashes: [cid("root"), cid("left")]
        )
    }

    func testInheritedWorkReorganizesOnlyTheReceivingChain() async {
        let chain = fork()
        let rightWins = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [cid("right"): WorkMeasure(
                contribution(cid("parent-right"), 5)
            )]
        )

        let commit = await chain.mergeInheritedWork(rightWins)
        let tip = await chain.getMainChainTip()

        XCTAssertEqual(tip, cid("right"))
        XCTAssertEqual(commit?.mainChainBlocksRemoved, [cid("left")])
        XCTAssertEqual(commit?.mainChainBlocksAdded, [cid("right"): 1])
    }

    func testNoUpdateRetainsLastAuthenticatedWork() async {
        let chain = fork()
        let inherited = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [cid("right"): WorkMeasure(
                contribution(cid("retained-right"), 5)
            )]
        )
        _ = await chain.mergeInheritedWork(inherited)
        _ = await chain.reevaluateForkChoice()
        let tip = await chain.getMainChainTip()
        let rightWeight = await chain.forkChoiceSnapshot(
            startingAt: cid("right")
        )?.subtreeWork

        XCTAssertEqual(tip, cid("right"))
        XCTAssertEqual(rightWeight, WorkSum(UInt256(6)))
    }

    func testDistinctDescendantGrindsSumAlongSameChainAncestry() async {
        var root = makeBlockMeta(hash: cid("root"), height: 0)
        let child = makeBlockMeta(
            hash: cid("child"), previousHash: cid("root"), height: 1
        )
        root.childHashes = [cid("child")]
        let chain = makeChain(blocks: [root, child])
        let inherited = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                cid("child"): WorkMeasure([
                    contribution(cid("parent-one"), 5),
                    contribution(cid("parent-two"), 7),
                ]),
            ]
        )

        _ = await chain.mergeInheritedWork(inherited)
        let rootWeight = await chain.forkChoiceSnapshot(
            startingAt: cid("root")
        )?.subtreeWork
        let childWeight = await chain.forkChoiceSnapshot(
            startingAt: cid("child")
        )?.subtreeWork

        XCTAssertEqual(rootWeight, WorkSum(UInt256(14)))
        XCTAssertEqual(childWeight, WorkSum(UInt256(13)))
    }

    func testConflictingLocationUpdateIsRejectedAtomically() async {
        let chain = fork()
        let grind = testCID("conflicting-inherited-grind")
        let first = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [cid("left"): WorkMeasure(contribution(grind, 3))]
        )
        let conflict = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: [cid("right"): WorkMeasure(contribution(grind, 100))]
        )

        let accepted = await chain.mergeInheritedWork(first)
        let rejected = await chain.mergeInheritedWork(conflict)
        let leftWeight = await chain.forkChoiceSnapshot(
            startingAt: cid("left")
        )?.subtreeWork
        let rightWeight = await chain.forkChoiceSnapshot(
            startingAt: cid("right")
        )?.subtreeWork

        XCTAssertNotNil(accepted)
        XCTAssertNil(rejected)
        XCTAssertEqual(leftWeight, WorkSum(UInt256(4)))
        XCTAssertEqual(rightWeight, WorkSum(UInt256(1)))
    }

    func testUnknownInheritedLocationReservesTheGrind() async {
        let chain = makeChain(blocks: [makeBlockMeta(hash: cid("root"), height: 0)])
        let grind = testCID("future-location-grind")
        let first = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [cid("future-a"): WorkMeasure(contribution(grind, 3))]
        )
        let conflictingInherited = InheritedWorkSnapshot(
            revision: 2,
            workByBlock: [cid("future-b"): WorkMeasure(contribution(grind, 100))]
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
            to: cid("root")
        )
        XCTAssertFalse(conflictingLocal.addedContribution)
        let retained = await chain.inheritedWorkSnapshot
        XCTAssertEqual(
            retained?.sourceWork(forBlock: cid("future-a")).work(forGrind: grind),
            UInt256(3)
        )
        XCTAssertTrue(retained?.sourceWork(forBlock: cid("future-b")).isEmpty ?? false)
    }

    func testOldAndEqualRevisionsMayAddNewMonotonicFacts() async {
        let chain = fork()
        _ = await chain.mergeInheritedWork(InheritedWorkSnapshot(
            revision: 5,
            workByBlock: [cid("right"): WorkMeasure(
                contribution(cid("revision-right"), 5)
            )]
        ))

        let oldAddition = await chain.mergeInheritedWork(InheritedWorkSnapshot(
            revision: 4,
            workByBlock: [cid("left"): WorkMeasure(
                contribution(cid("revision-left"), 7)
            )]
        ))
        let equalAddition = await chain.mergeInheritedWork(InheritedWorkSnapshot(
            revision: 5,
            workByBlock: [cid("left"): WorkMeasure(
                contribution(cid("revision-left-two"), 1)
            )]
        ))
        let tip = await chain.getMainChainTip()

        XCTAssertNotNil(oldAddition)
        XCTAssertNotNil(equalAddition)
        XCTAssertEqual(tip, cid("left"))
    }

    func testNoncanonicalConnectedBlocksRemainInParentWorkView() async throws {
        let chain = fork()

        let snapshotValue = await chain.parentSecuringWorkSnapshot()
        let snapshot = try XCTUnwrap(snapshotValue)

        XCTAssertEqual(
            snapshot.blockCIDs,
            [cid("left"), cid("right"), cid("root")].sorted()
        )
        XCTAssertEqual(
            snapshot.sourceWork(forBlock: cid("right")).grindIDs,
            [testCID("work:\(cid("right"))")]
        )
    }

    func testCanonicalPointerDoesNotChangeWorkViewOrGhostChoice() async throws {
        var root = makeBlockMeta(hash: cid("root"), height: 0)
        let left = BlockMeta(
            blockHash: cid("left"),
            parentBlockHash: cid("root"),
            blockHeight: 1,
            childHashes: [],
            workContributions: [contribution(cid("left-work"), 3)]
        )
        let right = BlockMeta(
            blockHash: cid("right"),
            parentBlockHash: cid("root"),
            blockHeight: 1,
            childHashes: [],
            workContributions: [contribution(cid("right-work"), 5)]
        )
        root.childHashes = [cid("left"), cid("right")]
        let leftPointer = makeChain(
            blocks: [root, left, right],
            mainChainHashes: [cid("root"), cid("left")]
        )
        let rightPointer = makeChain(
            blocks: [root, left, right],
            mainChainHashes: [cid("root"), cid("right")]
        )

        let leftViewValue = await leftPointer.parentSecuringWorkSnapshot()
        let rightViewValue = await rightPointer.parentSecuringWorkSnapshot()
        let leftView = try XCTUnwrap(leftViewValue)
        let rightView = try XCTUnwrap(rightViewValue)
        let leftChoice = await leftPointer.forkChoiceSnapshot(startingAt: cid("root"))
        let rightChoice = await rightPointer.forkChoiceSnapshot(startingAt: cid("root"))

        XCTAssertEqual(leftView, rightView)
        XCTAssertEqual(leftChoice, rightChoice)
        XCTAssertEqual(leftChoice?.tipHash, cid("right"))
    }

    func testDisconnectedWorkBecomesVisibleOnlyAfterSameChainAttachment() async throws {
        var root = makeBlockMeta(hash: cid("root"), height: 0)
        let orphan = makeBlockMeta(
            hash: cid("orphan"), previousHash: cid("missing"), height: 2
        )
        let chain = makeChain(
            blocks: [root, orphan], mainChainHashes: [cid("root")]
        )

        let beforeValue = await chain.parentSecuringWorkSnapshot()
        let before = try XCTUnwrap(beforeValue)
        XCTAssertEqual(before.blockCIDs, [cid("root")])

        let missing = makeBlockMeta(
            hash: cid("missing"),
            previousHash: cid("root"),
            height: 1,
            childHashes: [cid("orphan")]
        )
        root.childHashes = [cid("missing")]
        let attached = makeChain(blocks: [root, missing, orphan])
        let afterValue = await attached.parentSecuringWorkSnapshot()
        let after = try XCTUnwrap(afterValue)

        XCTAssertEqual(
            after.blockCIDs,
            [cid("missing"), cid("orphan"), cid("root")].sorted()
        )
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
