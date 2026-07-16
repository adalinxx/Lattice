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

        XCTAssertNil(incompleteExport)

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

        XCTAssertNotNil(completeExport)
    }
}
