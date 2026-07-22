import XCTest
import UInt256
@testable import Lattice

final class InheritedWorkHierarchyTests: XCTestCase {
    private func contribution(_ id: String, _ value: UInt64) -> VerifiedWorkContribution {
        VerifiedWorkContribution(id: id, work: UInt256(value))
    }

    private func block(
        _ hash: String,
        parent: String? = nil,
        height: UInt64,
        children: [String] = [],
        contribution: VerifiedWorkContribution
    ) -> BlockMeta {
        BlockMeta(
            blockHash: hash,
            parentBlockHash: parent,
            blockHeight: height,
            childHashes: children,
            workContributions: [contribution]
        )
    }

    func testExactImmediateParentFactsComposeRecursivelyAcrossThreeChains() async throws {
        let r0 = testCID("hierarchy-root-0")
        let r1 = testCID("hierarchy-root-1")
        let p0 = testCID("hierarchy-parent-0")
        let p1 = testCID("hierarchy-parent-1")
        let c0 = testCID("hierarchy-child-0")
        let c1 = testCID("hierarchy-child-1")
        let rootG0 = testCID("hierarchy-root-g0")
        let rootG1 = testCID("hierarchy-root-g1")
        let parentG0 = testCID("hierarchy-parent-g0")
        let parentG1 = testCID("hierarchy-parent-g1")

        let root = makeChain(blocks: [
            block(r0, height: 0, children: [r1], contribution: contribution(rootG0, 2)),
            block(r1, parent: r0, height: 1, contribution: contribution(rootG1, 5)),
        ])
        let parent = makeChain(blocks: [
            block(p0, height: 0, children: [p1], contribution: contribution(parentG0, 3)),
            block(p1, parent: p0, height: 1, contribution: contribution(parentG1, 7)),
        ])
        let child = makeChain(blocks: [
            block(c0, height: 0, children: [c1], contribution: contribution(testCID("hierarchy-child-g0"), 1)),
            block(c1, parent: c0, height: 1, contribution: contribution(testCID("hierarchy-child-g1"), 1)),
        ])

        let rootFactsValue = await root.parentSecuringWorkSnapshot()
        let rootFacts = try XCTUnwrap(rootFactsValue)
        let parentInheritedValue = await parent.inheritedWorkSnapshot(
            from: rootFacts,
            parentCarrierBlocksByChildBlock: [p0: [r0], p1: [r1]]
        )
        let parentInherited = try XCTUnwrap(parentInheritedValue)
        _ = await parent.mergeInheritedWork(parentInherited)

        let parentFactsValue = await parent.parentSecuringWorkSnapshot()
        let parentFacts = try XCTUnwrap(parentFactsValue)
        let childInheritedValue = await child.inheritedWorkSnapshot(
            from: parentFacts,
            parentCarrierBlocksByChildBlock: [c0: [p0], c1: [p1]]
        )
        let childInherited = try XCTUnwrap(childInheritedValue)
        _ = await child.mergeInheritedWork(childInherited)

        assertInheritedWorkMeasure(
            childInherited.sourceWork(forBlock: c0),
            equals: [rootG0: 2, parentG0: 3]
        )
        assertInheritedWorkMeasure(
            childInherited.sourceWork(forBlock: c1),
            equals: [rootG1: 5, parentG1: 7]
        )
        let rootWeight = await child.forkChoiceSnapshot(startingAt: c0)?.subtreeWork
        let tipWeight = await child.forkChoiceSnapshot(startingAt: c1)?.subtreeWork
        XCTAssertEqual(rootWeight, WorkSum(UInt256(19)))
        XCTAssertEqual(tipWeight, WorkSum(UInt256(13)))
    }

    func testParentAncestryDoesNotInventAChildCommitment() async throws {
        let p0 = testCID("no-carry-parent-0")
        let p1 = testCID("no-carry-parent-1")
        let childBlock = testCID("no-carry-child")
        let first = testCID("no-carry-first")
        let later = testCID("no-carry-later")
        let parent = makeChain(blocks: [
            block(p0, height: 0, children: [p1], contribution: contribution(first, 2)),
            block(p1, parent: p0, height: 1, contribution: contribution(later, 50)),
        ])
        let child = makeChain(blocks: [
            block(childBlock, height: 0, contribution: contribution(testCID("no-carry-local"), 1)),
        ])

        let parentFactsValue = await parent.parentSecuringWorkSnapshot()
        let parentFacts = try XCTUnwrap(parentFactsValue)
        let inheritedValue = await child.inheritedWorkSnapshot(
            from: parentFacts,
            parentCarrierBlocksByChildBlock: [childBlock: [p0]]
        )
        let inherited = try XCTUnwrap(inheritedValue)

        XCTAssertEqual(inherited.sourceWork(forBlock: childBlock).grindIDs, [first])
        XCTAssertNil(inherited.sourceWork(forBlock: childBlock).work(forGrind: later))
    }
}
