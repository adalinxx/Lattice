import XCTest
import UInt256
@testable import Lattice

/// The invalidity-exclusion seam of deferred execution: a proven-invalid
/// subtree is removed from THIS chain's own effective weight and fork choice
/// re-projects onto the heaviest VALID chain — while the excluded facts remain
/// present in `hashToBlock` (served/exported, never pruned) and untouched in the
/// per-block work evidence.
@MainActor
final class DeferredExecutionExclusionTests: XCTestCase {
    // MARK: - Fixtures

    private struct PlannedBlock {
        let hash: String
        let parentHash: String?
        let height: UInt64
        let work: UInt64
    }

    private func block(
        _ name: String,
        parent: PlannedBlock?,
        work: UInt64
    ) -> PlannedBlock {
        PlannedBlock(
            hash: testCID("exclusion-\(name)"),
            parentHash: parent?.hash,
            height: (parent?.height).map { $0 + 1 } ?? 0,
            work: work
        )
    }

    private func admission(for block: PlannedBlock) -> ChainAdmissionBatch {
        let contribution = VerifiedWorkContribution(
            id: testCID("exclusion-work-\(block.hash)"),
            work: UInt256(block.work)
        )
        return ChainAdmissionBatch(facts: [
            .block(ChainBlockFact(
                blockHash: block.hash,
                parentBlockHash: block.parentHash,
                blockHeight: block.height,
                postStateCID: testCID("exclusion-post-\(block.hash)"),
                prevStateCID: testCID("exclusion-prev-\(block.hash)"),
                specCID: testCID("exclusion-spec-\(block.hash)"),
                target: "1",
                nextTarget: "1",
                timestamp: Int64(block.height),
                stateDiff: .empty
            )),
            .work(ChainWorkFact(blockHash: block.hash, contribution: contribution)),
        ])
    }

    private func exclusion(of block: PlannedBlock) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
            .exclusion(ChainExclusionFact(blockHash: block.hash)),
        ])
    }

    /// Genesis G with a heavier chain H1→H2→H3 (work 5 each = 15) and a lighter
    /// chain L1→L2 (work 4 each = 8). Before exclusion the tip is H3.
    private func buildForkedChain() async throws -> (
        chain: ChainState,
        g: PlannedBlock,
        h: [PlannedBlock],
        l: [PlannedBlock],
        batches: [ChainAdmissionBatch]
    ) {
        let g = block("g", parent: nil, work: 3)
        let h1 = block("h1", parent: g, work: 5)
        let h2 = block("h2", parent: h1, work: 5)
        let h3 = block("h3", parent: h2, work: 5)
        let l1 = block("l1", parent: g, work: 4)
        let l2 = block("l2", parent: l1, work: 4)
        let h = [h1, h2, h3]
        let l = [l1, l2]
        var batches = [admission(for: g)]
        for b in h + l { batches.append(admission(for: b)) }

        let chain = try await ChainState.restore(replaying: [admission(for: g)])
        for b in h + l {
            _ = try await chain.applyStaged(admission(for: b))
        }
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, h3.hash, "precondition: heaviest chain H is the tip")
        return (chain, g, h, l, batches)
    }

    // MARK: - Tests

    /// A heaviest chain whose block is proven invalid is EXCLUDED and the tip
    /// demotes to the heaviest VALID chain. Excluded blocks stay served.
    func testExcludedSubtreeDemotesTipToHeaviestValidChain() async throws {
        let (chain, g, h, l, _) = try await buildForkedChain()

        _ = try await chain.applyStaged(exclusion(of: h[0]))

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, l[1].hash, "tip demotes to heaviest valid chain L2")

        let path = await chain.mainChainHashes
        XCTAssertEqual(path, [g.hash, l[0].hash, l[1].hash])

        // Excluded facts are NOT pruned: still present and served.
        for b in h {
            let present = await chain.contains(blockHash: b.hash)
            XCTAssertTrue(present, "excluded block \(b.hash) remains served")
        }
    }

    /// The live projection under exclusion matches the reference oracle applied
    /// to the same exclusion — both descents skip the excluded subtree.
    func testLiveProjectionMatchesReferenceOracleUnderExclusion() async throws {
        let (chain, _, h, l, _) = try await buildForkedChain()
        _ = try await chain.applyStaged(exclusion(of: h[0]))

        let blocks = await chain.hashToBlock
        let excluded = await chain.excludedClosureForTesting
        guard let expected = ChainState.referenceCanonicalProjection(
            in: blocks,
            excluding: excluded
        ) else {
            return XCTFail("reference oracle produced no projection")
        }
        let liveTip = await chain.getMainChainTip()
        let livePath = await chain.mainChainHashes
        XCTAssertEqual(liveTip, expected.chainTip)
        XCTAssertEqual(livePath, expected.mainChainHashes)
        XCTAssertEqual(expected.chainTip, l[1].hash)
    }

    /// Exclusion survives restore: replaying all durable facts (including the
    /// exclusion) in an adversarial order reproduces the demoted tip.
    func testExclusionIsReplayInvariant() async throws {
        let (chain, _, h, l, batches) = try await buildForkedChain()
        _ = try await chain.applyStaged(exclusion(of: h[0]))
        let expectedTip = await chain.getMainChainTip()
        let expectedPath = await chain.mainChainHashes
        XCTAssertEqual(expectedTip, l[1].hash)

        // Durable facts in an order that presents the exclusion before, between,
        // and after its subtree blocks. Genesis stays first so restore has a root.
        var durable = batches
        durable.insert(exclusion(of: h[0]), at: 2)

        let restored = try await ChainState.restore(replaying: durable)
        let restoredTip = await restored.getMainChainTip()
        let restoredPath = await restored.mainChainHashes
        XCTAssertEqual(restoredTip, expectedTip)
        XCTAssertEqual(restoredPath, expectedPath)
    }

    /// Closure completeness under orphan admission: a descendant admitted BEFORE
    /// its excluded parent connects (child-before-parent via orphan attach) is
    /// still folded into the excluded closure and contributes zero to both fork
    /// choice and its subtree weight.
    func testOrphanDescendantOfExcludedRootIsFoldedAndZeroWeight() async throws {
        // G → R (excluded) → B → C, plus a valid competing chain L1 → L2.
        let g = block("g", parent: nil, work: 3)
        let r = block("r", parent: g, work: 5)
        let b = block("b", parent: r, work: 5)
        let c = block("c", parent: b, work: 5)
        let l1 = block("l1", parent: g, work: 4)
        let l2 = block("l2", parent: l1, work: 4)

        let chain = try await ChainState.restore(replaying: [admission(for: g)])
        // R and the valid chain exist; B and C do not yet.
        _ = try await chain.applyStaged(admission(for: r))
        _ = try await chain.applyStaged(admission(for: l1))
        _ = try await chain.applyStaged(admission(for: l2))

        // Prove R invalid while B, C are still absent.
        _ = try await chain.applyStaged(exclusion(of: r))

        // C arrives before its parent B — an orphan attach (C routes normally,
        // since B is not yet in the closure).
        _ = try await chain.applyStaged(admission(for: c))
        // B connects under the excluded root R, folding B AND the already-present
        // orphan C into the closure.
        _ = try await chain.applyStaged(admission(for: b))

        let closure = await chain.excludedClosureForTesting
        XCTAssertTrue(closure.contains(r.hash))
        XCTAssertTrue(closure.contains(b.hash))
        XCTAssertTrue(
            closure.contains(c.hash),
            "orphan descendant folded into the excluded closure"
        )

        // C weighs zero and is not on the main chain; the tip is the valid chain.
        let cWeight = await chain.subtreeWeight(forHash: c.hash)
        XCTAssertEqual(cWeight, .zero)
        let path = await chain.mainChainHashes
        XCTAssertFalse(path.contains(c.hash))
        XCTAssertFalse(path.contains(b.hash))
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, l2.hash)

        // Matches the reference oracle over the same exclusion.
        let blocks = await chain.hashToBlock
        let expected = ChainState.referenceCanonicalProjection(
            in: blocks, excluding: closure
        )
        XCTAssertEqual(tip, expected?.chainTip)
        XCTAssertEqual(path, expected?.mainChainHashes)
    }

    /// Complexity regression (the DoS the audit confirmed): with an exclusion
    /// active, spamming losing side blocks must NOT trigger a full canonical
    /// projection per insert — the single filtered segment index keeps the fast
    /// spine early-out working, so the full-projection counter stays bounded.
    func testSideBlockSpamUnderExclusionDoesNotFullyProjectPerInsert() async throws {
        let (chain, g, h, _, _) = try await buildForkedChain()
        _ = try await chain.applyStaged(exclusion(of: h[0]))

        let baseline = await chain.fullCanonicalProjectionCount
        // Many losing side blocks hung off genesis (height 1), none of which
        // changes the winning spine.
        for index in 0..<200 {
            let sibling = PlannedBlock(
                hash: testCID("exclusion-spam-\(index)"),
                parentHash: g.hash,
                height: 1,
                work: 1
            )
            _ = try await chain.applyStaged(admission(for: sibling))
        }
        let after = await chain.fullCanonicalProjectionCount
        XCTAssertLessThanOrEqual(
            after - baseline,
            5,
            "200 losing side blocks under an exclusion must not each force a full projection"
        )
    }

    /// Replay presenting an `.exclusion` batch STRICTLY BEFORE its block must
    /// defer-and-retry (not corrupt), then reproject identically to the live
    /// order. Exercises the missing-block defer path in `applyExclusion`.
    func testExclusionStrictlyBeforeBlockDefersAndReprojectsIdentically() async throws {
        let (chain, _, h, l, batches) = try await buildForkedChain()
        _ = try await chain.applyStaged(exclusion(of: h[0]))
        let expectedTip = await chain.getMainChainTip()
        let expectedPath = await chain.mainChainHashes
        XCTAssertEqual(expectedTip, l[1].hash)

        // Durable order: genesis first (restore needs a root), then the exclusion
        // BEFORE any of H1/H2/H3/L1/L2 — so it must defer until H1 arrives.
        var durable = [batches[0]]
        durable.append(exclusion(of: h[0]))
        durable.append(contentsOf: batches.dropFirst())

        let restored = try await ChainState.restore(replaying: durable)
        let restoredTip = await restored.getMainChainTip()
        let restoredPath = await restored.mainChainHashes
        XCTAssertEqual(restoredTip, expectedTip)
        XCTAssertEqual(restoredPath, expectedPath)

        // And the excluded subtree is genuinely excluded after recovery.
        let closure = await restored.excludedClosureForTesting
        for excluded in h {
            XCTAssertTrue(closure.contains(excluded.hash))
        }
    }

    /// A miner cannot resurrect an excluded subtree by piling on more work: a
    /// heavier extension of the excluded chain is still never acted on.
    func testHeavierExtensionOfExcludedChainNeverResurrectsTip() async throws {
        let (chain, _, h, l, _) = try await buildForkedChain()
        _ = try await chain.applyStaged(exclusion(of: h[0]))
        let tipAfterExclusion = await chain.getMainChainTip()
        XCTAssertEqual(tipAfterExclusion, l[1].hash)

        // H4 extends H3 with enormous work — the excluded subtree stays excluded.
        let h4 = block("h4", parent: h[2], work: 1_000_000)
        _ = try await chain.applyStaged(admission(for: h4))

        let tipAfterExtension = await chain.getMainChainTip()
        XCTAssertEqual(
            tipAfterExtension,
            l[1].hash,
            "excluded subtree extension is weighed-but-never-acted-on"
        )
        let extendedPath = await chain.mainChainHashes
        XCTAssertEqual(extendedPath.contains(h4.hash), false)
    }
}
