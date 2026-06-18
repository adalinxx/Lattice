import XCTest
@testable import Lattice
import UInt256
import cashew

/// Acceptance coverage for the Hierarchical-GHOST property that a child chain
/// retargets its own target independently of its parent and can therefore
/// run at a lower target / higher block rate than the parent.
///
/// Convention reminder: the `target` field IS the PoW *target* threshold —
/// `ChainSpec.validateBlockHash` accepts `hash < target`, so a LARGER value
/// is EASIER (more nonces qualify) and the LWMA retarget raises it when blocks
/// arrive slower than `targetBlockTime`. "Lower target" in the colloquial
/// sense (easier to mine) therefore corresponds to a larger `target` value.
///
/// These tests drive the real retarget + consensus entry points
/// (`BlockBuilder.buildBlock` + `Block.validateNextTarget`); they do not
/// exercise the node-side merged-mining `effectiveTarget` or the
/// PoW-inheritance acceptance of an easy child under a hard parent, which is
/// covered by `lattice-node`'s `PerProcessChainTests.testChildBlockValidPoWWithPartialParent`.
@MainActor
final class ChildChainDifficultyIndependenceTests: XCTestCase {

    private func spec(target: UInt64, window: UInt64 = 120) -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 1_000_000,
            premine: 0,
            targetBlockTime: target,
            initialReward: 1024,
            halvingInterval: 10_000,
            retargetWindow: window
        )
    }

    private func genesis(spec: ChainSpec, timestamp: Int64, target: UInt256, fetcher: StorableFetcher) async throws -> Block {
        try await BlockBuilder.buildGenesis(spec: spec, timestamp: timestamp, target: target, fetcher: fetcher)
    }

    /// Extend a chain by one block at `timestamp`, letting the builder retarget
    /// `nextTarget` via the chain's OWN spec, and assert the block passes the
    /// real `validateNextTarget` consensus gate. `newestFirstAncestors` is the
    /// chain's timestamp history (newest first, INCLUDING the parent), as the gate
    /// requires.
    @discardableResult
    private func extend(
        _ previous: Block,
        spec: ChainSpec,
        timestamp: Int64,
        newestFirstAncestors: [Int64],
        fetcher: StorableFetcher
    ) async throws -> Block {
        let block = try await BlockBuilder.buildBlock(previous: previous, timestamp: timestamp, fetcher: fetcher)
        XCTAssertTrue(
            block.validateNextTarget(spec: spec, parent: previous, ancestorTimestamps: newestFirstAncestors),
            "builder-produced retarget at height \(block.height) must satisfy the consensus gate"
        )
        return block
    }

    // MARK: - A. Independent retarget keyed to each chain's own targetBlockTime

    /// Fed the IDENTICAL solve interval, a fast child (small `targetBlockTime`)
    /// and a slow parent (large `targetBlockTime`) retarget to DIFFERENT next
    /// difficulties — proving the LWMA is a pure function of each chain's own
    /// spec + own timestamps, not a shared/parent value. The interval equals the
    /// parent's target, so the parent holds steady while the child — for which
    /// those same blocks are far too slow — eases to a strictly larger target.
    func testFasterChildRetargetsIndependentlyOfParent() async throws {
        let interval: Int64 = 10_000
        let parentSpec = spec(target: 10_000)   // interval == target → steady
        let childSpec = spec(target: 1_000)     // interval == 10× target → eases
        let d0 = UInt256(1_000_000)
        let fetcher = StorableFetcher()

        let parentGenesis = try await genesis(spec: parentSpec, timestamp: 1_000, target: d0, fetcher: fetcher)
        let childGenesis = try await genesis(spec: childSpec, timestamp: 1_000, target: d0, fetcher: fetcher)

        let parentBlock = try await extend(parentGenesis, spec: parentSpec, timestamp: 1_000 + interval,
                                            newestFirstAncestors: [parentGenesis.timestamp], fetcher: fetcher)
        let childBlock = try await extend(childGenesis, spec: childSpec, timestamp: 1_000 + interval,
                                          newestFirstAncestors: [childGenesis.timestamp], fetcher: fetcher)

        // Same genesis target, same solve interval, different targetBlockTime
        // ⇒ different retarget. Parent steady; child strictly easier (larger target).
        XCTAssertEqual(parentBlock.nextTarget, d0, "parent at exact target cadence holds target steady")
        XCTAssertGreaterThan(childBlock.nextTarget, parentBlock.nextTarget,
                             "the faster child must retarget to a strictly easier target for the same solve cadence")
    }

    // MARK: - B. A child cannot import its parent chain's retarget

    /// The child enforces ITS OWN retarget: a child block carrying the parent
    /// chain's (slower-target) next target fails the consensus gate even
    /// though that value is itself a valid retarget on the parent chain.
    func testChildRejectsParentChainRetarget() async throws {
        let interval: Int64 = 10_000
        let parentSpec = spec(target: 10_000)
        let childSpec = spec(target: 1_000)
        let d0 = UInt256(1_000_000)
        let fetcher = StorableFetcher()

        let parentGenesis = try await genesis(spec: parentSpec, timestamp: 1_000, target: d0, fetcher: fetcher)
        let childGenesis = try await genesis(spec: childSpec, timestamp: 1_000, target: d0, fetcher: fetcher)
        let parentBlock = try await extend(parentGenesis, spec: parentSpec, timestamp: 1_000 + interval,
                                           newestFirstAncestors: [parentGenesis.timestamp], fetcher: fetcher)

        // The child's OWN honest retarget (builder uses the child spec), captured
        // so we can confirm the rejection below is meaningful (values differ).
        let childHonest = try await BlockBuilder.buildBlock(previous: childGenesis, timestamp: 1_000 + interval, fetcher: fetcher)
        XCTAssertNotEqual(childHonest.nextTarget, parentBlock.nextTarget,
                          "precondition: the two chains' retargets genuinely differ")

        // Forge a child block that copies the parent chain's next target.
        let imported = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            timestamp: 1_000 + interval,
            target: childGenesis.nextTarget,
            nextTarget: parentBlock.nextTarget,
            fetcher: fetcher
        )
        XCTAssertFalse(
            imported.validateNextTarget(spec: childSpec, parent: childGenesis, ancestorTimestamps: [childGenesis.timestamp]),
            "child must reject a next target retargeted under the parent chain's targetBlockTime"
        )
    }

    // MARK: - C. A faster child sustains a strictly higher block rate

    /// Over the SAME wall-clock window, a child running at its own faster target
    /// cadence produces strictly more blocks than the parent, and each chain's
    /// target stays steady at its equilibrium (cadence == target ⇒ stable) —
    /// so the higher rate is the sustained equilibrium, not a transient the
    /// retarget corrects away. Every block clears the real consensus gate.
    func testFasterChildSustainsHigherBlockRateOverSameWindow() async throws {
        let window: Int64 = 20_000
        let parentTarget: Int64 = 5_000   // 4 blocks across the window
        let childTarget: Int64 = 1_000    // 20 blocks across the window
        let parentSpec = spec(target: UInt64(parentTarget))
        let childSpec = spec(target: UInt64(childTarget))
        let d0 = UInt256(1_000_000)
        let start: Int64 = 1_000

        func run(spec: ChainSpec, target: Int64) async throws -> [Block] {
            let fetcher = StorableFetcher()
            var tip = try await genesis(spec: spec, timestamp: start, target: d0, fetcher: fetcher)
            var history: [Int64] = [tip.timestamp]   // newest-first
            var chain = [tip]
            var t = start + target
            while t <= start + window {
                tip = try await extend(tip, spec: spec, timestamp: t, newestFirstAncestors: history, fetcher: fetcher)
                history.insert(tip.timestamp, at: 0)
                chain.append(tip)
                t += target
            }
            return chain
        }

        let parentChain = try await run(spec: parentSpec, target: parentTarget)
        let childChain = try await run(spec: childSpec, target: childTarget)

        // Higher rate: strictly more blocks in the same wall-clock window.
        XCTAssertEqual(parentChain.count, 5, "genesis + 4 blocks over the window at 5s cadence")
        XCTAssertEqual(childChain.count, 21, "genesis + 20 blocks over the window at 1s cadence")
        XCTAssertGreaterThan(childChain.count, parentChain.count)

        // Sustained equilibrium: at exact target cadence each chain's target
        // is stable (no runaway), so the faster rate persists indefinitely.
        XCTAssertEqual(parentChain.last!.nextTarget, d0, "parent target steady at target cadence")
        XCTAssertEqual(childChain.last!.nextTarget, d0, "child target steady at its own faster target cadence")
    }
}
