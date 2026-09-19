import XCTest
import Foundation
import UInt256
import cashew
@testable import Lattice

/// The difficulty schedule is absolutely scheduled from one anchor: the
/// height-1 ancestor of the block being targeted. These cover the properties
/// that make that choice safe, as opposed to merely compiling.
@MainActor
final class AsertDifficultyTests: XCTestCase {

    private func spec(targetBlockTime: UInt64 = 3_600_000, window: UInt64 = 120) -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 1_000_000,
            premine: 0,
            targetBlockTime: targetBlockTime,
            initialReward: 1024,
            halvingInterval: 10_000,
            retargetWindow: window
        )
    }

    // MARK: - The schedule itself

    /// On schedule means unchanged. A chain producing blocks at exactly
    /// `targetBlockTime` should sit still at its anchor's target no matter how
    /// far it has run — that is what "absolutely scheduled" buys, and it is the
    /// property a windowed average only approximates.
    func testExactlyOnScheduleHoldsTheAnchorTargetAtAnyDepth() {
        let s = spec()
        let anchorTarget = UInt256(1) << 215
        let anchorTime: Int64 = 1_000_000

        for height in [2, 3, 50, 1_000, 100_000] as [UInt64] {
            let onSchedule = anchorTime + Int64(3_600_000 * (height - 1))
            XCTAssertEqual(
                s.calculateAsertTarget(
                    anchorTarget: anchorTarget, anchorTimestamp: anchorTime,
                    anchorHeight: 1, blockTimestamp: onSchedule, blockHeight: height
                ),
                anchorTarget,
                "a chain exactly on schedule at height \(height) must not drift"
            )
        }
    }

    /// Ahead of schedule hardens, behind eases, and one half-life is one
    /// doubling in each direction. The half-life is `retargetWindow` blocks, so
    /// this also pins that the window field is being read as a half-life.
    func testOneHalfLifeIsOneDoublingInEitherDirection() {
        let s = spec(window: 120)
        let anchorTarget = UInt256(1) << 215
        let anchorTime: Int64 = 1_000_000
        let height: UInt64 = 121
        let onSchedule = anchorTime + Int64(3_600_000 * 120)
        let halfLife = Int64(120 * 3_600_000)

        let behind = s.calculateAsertTarget(
            anchorTarget: anchorTarget, anchorTimestamp: anchorTime, anchorHeight: 1,
            blockTimestamp: onSchedule + halfLife, blockHeight: height
        )
        let ahead = s.calculateAsertTarget(
            anchorTarget: anchorTarget, anchorTimestamp: anchorTime, anchorHeight: 1,
            blockTimestamp: onSchedule - halfLife, blockHeight: height
        )
        // Fixed-point, so assert closeness rather than exact powers of two.
        assertWithin(behind, of: anchorTarget * UInt256(2), partsPerThousand: 2,
                     "one half-life behind schedule must ease by one doubling")
        assertWithin(ahead, of: anchorTarget / UInt256(2), partsPerThousand: 2,
                     "one half-life ahead of schedule must harden by one doubling")
    }

    /// No window means no memory: the target depends only on the anchor and the
    /// block, so a stretch of unusual block times stops mattering the moment it
    /// stops happening. Two chains that arrive at the same height at the same
    /// time get the same target however differently they got there.
    func testTargetDependsOnlyOnTheAnchorAndThisBlock() async throws {
        let chainSpec = spec(targetBlockTime: 1_000)
        let anchorTarget = UInt256(1) << 240

        // Two chains that share an anchor and arrive at the SAME height and the
        // SAME timestamp by completely different routes: one steady, one wildly
        // irregular. Under a windowed average these diverge, because the window
        // remembers how the height was reached. Under an absolute schedule they
        // must not -- that independence from intervening history is the whole
        // claim, and comparing a call against itself cannot test it.
        func tipTarget(gaps: [Int64]) async throws -> (UInt256, Int64, UInt64) {
            let fetcher = StorableFetcher()
            let genesis = try await buildAndStoreGenesis(
                spec: chainSpec, timestamp: 1_000, target: anchorTarget, fetcher: fetcher
            )
            var previous = genesis
            for (i, gap) in gaps.enumerated() {
                previous = try await buildAndStoreBlock(
                    previous: previous, timestamp: previous.timestamp + gap,
                    nonce: UInt64(i), fetcher: fetcher
                )
            }
            return (previous.nextTarget, previous.timestamp, previous.height)
        }

        // The FIRST gap is held identical on purpose: it places block 1, which
        // is the anchor, and two chains with different anchors are legitimately
        // on different schedules. What must not matter is everything after it.
        let steady = try await tipTarget(gaps: [1_000, 1_000, 1_000, 1_000, 1_000, 1_000])
        let erratic = try await tipTarget(gaps: [1_000, 50, 4_500, 120, 30, 300])

        XCTAssertEqual(steady.1, erratic.1, "precondition: both tips land on the same timestamp")
        XCTAssertEqual(steady.2, erratic.2, "precondition: both tips land on the same height")
        XCTAssertEqual(
            steady.0, erratic.0,
            "two routes to the same height and time must schedule the same next target"
        )
    }

    /// Moving a block's clock BACKWARDS must not buy an easier target. Elapsed
    /// time clamps at zero, which makes the drift maximally negative and the
    /// target harder, so clock manipulation costs difficulty rather than
    /// granting it.
    func testBackwardsTimestampHardensRatherThanEases() {
        let s = spec()
        let anchorTarget = UInt256(1) << 215
        let anchorTime: Int64 = 1_000_000
        let honest = anchorTime + Int64(3_600_000 * 9)

        let honestTarget = s.calculateAsertTarget(
            anchorTarget: anchorTarget, anchorTimestamp: anchorTime,
            anchorHeight: 1, blockTimestamp: honest, blockHeight: 10
        )
        let backdated = s.calculateAsertTarget(
            anchorTarget: anchorTarget, anchorTimestamp: anchorTime,
            anchorHeight: 1, blockTimestamp: anchorTime - 10_000_000, blockHeight: 10
        )
        XCTAssertLessThan(backdated, honestTarget,
                          "a backwards clock must yield a HARDER target, never an easier one")
    }

    /// Adversarial inputs must not trap or wrap: a content-addressed spec and a
    /// block timestamp both arrive from the network.
    func testExtremeInputsStaySaneAndBounded() {
        let s = spec()
        let anchorTarget = UInt256(1) << 215
        for (timestamp, height) in [
            (Int64.max, UInt64.max), (Int64.min, UInt64(2)),
            (Int64.max, UInt64(2)), (0, UInt64.max)
        ] {
            let result = s.calculateAsertTarget(
                anchorTarget: anchorTarget, anchorTimestamp: 1_000_000,
                anchorHeight: 1, blockTimestamp: timestamp, blockHeight: height
            )
            XCTAssertGreaterThanOrEqual(result, UInt256(1), "a zero target would reject every hash")
            XCTAssertLessThanOrEqual(result, UInt256.max)
        }
    }

    /// A zero-length half-life would divide by zero. A spec is content
    /// addressed and attacker supplied, so the degenerate value has to be inert
    /// rather than fatal.
    func testZeroRetargetWindowIsInertRatherThanFatal() {
        let s = spec(window: 0)
        let anchorTarget = UInt256(1) << 200
        XCTAssertEqual(s.halfLifeMilliseconds(), 0)
        XCTAssertEqual(
            s.calculateAsertTarget(
                anchorTarget: anchorTarget, anchorTimestamp: 0,
                anchorHeight: 1, blockTimestamp: 999_999, blockHeight: 77
            ),
            anchorTarget
        )
    }

    // MARK: - The anchor

    /// The anchor is the height-1 ancestor, reached by walking the block's OWN
    /// parents. This is the fallback both the builder and the validator share,
    /// so it has to agree with itself at every depth.
    func testAnchorResolvesToHeightOneAtEveryDepth() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: spec(targetBlockTime: 1_000), timestamp: 1_000,
            target: UInt256(1_000_000), fetcher: fetcher
        )
        var previous = genesis
        var blockOne: Block?
        for i in 1...6 {
            let block = try await buildAndStoreBlock(
                previous: previous, timestamp: 1_000 + Int64(i) * 1_000, fetcher: fetcher
            )
            if block.height == 1 { blockOne = block }
            let anchor = try await BlockBuilder.resolveDifficultyAnchor(
                from: block, fetcher: fetcher
            )
            XCTAssertEqual(anchor?.blockHeight, 1, "every block anchors at height 1")
            XCTAssertEqual(anchor?.timestamp, blockOne?.timestamp,
                           "and at the SAME height-1 block, not merely some block of height 1")
            XCTAssertEqual(anchor?.target, blockOne?.target,
                           "the anchor's target must be block one's own committed target")
            previous = block
        }
    }

    /// Genesis precedes the schedule and has no anchor: it is not a measurement
    /// of anything, which is the entire reason the anchor is block 1.
    func testGenesisHasNoAnchor() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: spec(), timestamp: 1_000, target: UInt256.max, fetcher: fetcher
        )
        let anchor = try await BlockBuilder.resolveDifficultyAnchor(from: genesis, fetcher: fetcher)
        XCTAssertNil(anchor)
    }

    /// The property that matters most: the builder and the validator must
    /// derive the same target for the same block. Disagreement here is not a
    /// bug in one of them, it is a chain split.
    func testBuilderAndValidatorAgreeOnEveryBlock() async throws {
        let fetcher = StorableFetcher()
        let chainSpec = spec(targetBlockTime: 1_000)
        let genesis = try await buildAndStoreGenesis(
            spec: chainSpec, timestamp: 1_000, target: UInt256(1_000_000), fetcher: fetcher
        )
        var previous = genesis
        // Deliberately irregular spacing: fast, slow, and exactly on schedule,
        // so agreement is asserted across the whole response curve rather than
        // at one convenient point.
        for (i, gap) in [1_000, 200, 9_000, 1_000, 50, 4_000, 1_000].enumerated() {
            let block = try await buildAndStoreBlock(
                previous: previous,
                timestamp: previous.timestamp + Int64(gap),
                nonce: UInt64(i),
                fetcher: fetcher
            )
            let anchor = try await BlockBuilder.resolveDifficultyAnchor(
                from: previous, fetcher: fetcher
            ) ?? DifficultyAnchor(
                blockHeight: 1,
                timestamp: block.timestamp, target: block.target
            )
            XCTAssertTrue(
                block.validateNextTarget(spec: chainSpec, parent: previous, difficultyAnchor: anchor),
                "validator must accept the builder's own retarget at height \(block.height)"
            )
            previous = block
        }
    }

    // MARK: - Reorg safety

    /// Two branches forking at height 1 carry two anchors and two schedules,
    /// each internally consistent. A single chain-wide anchor would instead
    /// change under every block already built on it, retroactively altering
    /// targets that were already validated.
    func testForkAtHeightOneGivesEachBranchItsOwnSchedule() async throws {
        let fetcher = StorableFetcher()
        let chainSpec = spec(targetBlockTime: 1_000)
        let genesis = try await buildAndStoreGenesis(
            spec: chainSpec, timestamp: 1_000, target: UInt256(1_000_000), fetcher: fetcher
        )
        // Two competing height-1 blocks, differing in timestamp and target.
        let leftOne = try await buildAndStoreBlock(
            previous: genesis, timestamp: 2_000, target: UInt256(1_000_000), nonce: 1, fetcher: fetcher
        )
        let rightOne = try await buildAndStoreBlock(
            previous: genesis, timestamp: 5_000, target: UInt256(500_000), nonce: 2, fetcher: fetcher
        )
        let leftAnchor = try await BlockBuilder.resolveDifficultyAnchor(from: leftOne, fetcher: fetcher)
        let rightAnchor = try await BlockBuilder.resolveDifficultyAnchor(from: rightOne, fetcher: fetcher)

        XCTAssertNotEqual(leftAnchor, rightAnchor,
                          "each branch must anchor on its OWN height-1 block")
        XCTAssertEqual(leftAnchor?.timestamp, 2_000)
        XCTAssertEqual(rightAnchor?.timestamp, 5_000)
        XCTAssertEqual(rightAnchor?.target, UInt256(500_000))

        // And a block built on each branch inherits that branch's schedule:
        // same height, same spec, different targets, because the anchors differ.
        let leftTwo = try await buildAndStoreBlock(
            previous: leftOne, timestamp: 3_000, nonce: 3, fetcher: fetcher
        )
        let rightTwo = try await buildAndStoreBlock(
            previous: rightOne, timestamp: 6_000, nonce: 4, fetcher: fetcher
        )
        XCTAssertNotEqual(leftTwo.nextTarget, rightTwo.nextTarget,
                          "branches with different anchors must not share a schedule")
    }

    /// Choosing an easy anchor cannot buy fork-choice weight. A branch anchored
    /// at the maximum target is cheap to extend precisely because each of its
    /// blocks is worth almost nothing, so the incentive is neutral rather than
    /// exploitable.
    func testAnEasierAnchorEarnsProportionallyLessWork() {
        let s = spec()
        let anchorTime: Int64 = 1_000_000
        let height: UInt64 = 200
        let onSchedule = anchorTime + Int64(3_600_000 * 199)

        // Drive the schedule itself rather than asserting a property of
        // `workForTarget`: a branch anchored at the maximum target stays at the
        // maximum target while on schedule, so every block on it is worth one
        // unit of work no matter how long it runs. That is what stops a
        // free-to-mine branch from ever out-weighing an honest one.
        let easyAnchored = s.calculateAsertTarget(
            anchorTarget: UInt256.max, anchorTimestamp: anchorTime,
            anchorHeight: 1, blockTimestamp: onSchedule, blockHeight: height
        )
        let honestAnchored = s.calculateAsertTarget(
            anchorTarget: UInt256(1) << 215, anchorTimestamp: anchorTime,
            anchorHeight: 1, blockTimestamp: onSchedule, blockHeight: height
        )
        XCTAssertEqual(workForTarget(easyAnchored), UInt256(1),
                       "a branch anchored at the maximum target earns one unit of work per block")
        XCTAssertGreaterThan(
            workForTarget(honestAnchored), workForTarget(easyAnchored) * UInt256(1_000_000_000),
            "an honestly anchored branch must out-earn it by orders of magnitude per block"
        )
    }

    /// An anchor at or near the MAXIMUM target must harden by the amount the
    /// schedule says, not by a whole doubling.
    ///
    /// `factor` lies in [1, 2), so scaling first pushes a near-maximum target
    /// past 256 bits; if the halvings are applied after that saturation they
    /// come off the maximum rather than off the true product. One block ahead
    /// of schedule then yields exactly half the maximum instead of 0.994 of it.
    /// That is the ordinary state of a chain just after launch -- genesis
    /// commits the maximum, so block 1 anchors there -- which makes this the
    /// common case, not an edge case.
    func testNearMaximumAnchorHardensByTheScheduleNotAWholeDoubling() {
        let s = spec(targetBlockTime: 3_600_000, window: 120)
        let anchorTime: Int64 = 1_000_000
        // One block, one millisecond after the anchor: 3_599_999 ms ahead of a
        // 3_600_000 ms schedule, which is 1/120 of a half-life -- far less than
        // one doubling.
        let result = s.calculateAsertTarget(
            anchorTarget: UInt256.max, anchorTimestamp: anchorTime,
            anchorHeight: 1, blockTimestamp: anchorTime + 1, blockHeight: 2
        )
        XCTAssertGreaterThan(
            result, UInt256.max / UInt256(2),
            "1/120 of a half-life ahead of schedule must not cost a full doubling"
        )
        // 2^(-1/120) of the maximum, to within a part per thousand.
        assertWithin(
            result, of: UInt256.max / UInt256(1_000) * UInt256(994),
            partsPerThousand: 2,
            "the target must follow the schedule's own exponent"
        )
    }

    /// The same property across the whole near-maximum range: hardening a
    /// maximum anchor must stay proportional, with no cliff where the
    /// intermediate would have overflowed.
    ///
    /// The drift is driven by HEIGHT, not by the timestamp. `elapsed` clamps at
    /// zero, so at a low height the schedule is only a block time long and the
    /// chain cannot be more than that far ahead of it -- a timestamp sweep
    /// there silently pins every case to the same drift and asserts nothing.
    /// Pinning `elapsed` at zero and walking the height makes the drift exactly
    /// `targetBlockTime * (height - 1)`.
    func testHardeningFromTheMaximumIsSmoothAcrossFractionsOfAHalfLife() {
        let blockTime: UInt64 = 1_000
        let window: UInt64 = 120
        let s = spec(targetBlockTime: blockTime, window: window)
        let anchorTime: Int64 = 1_000_000
        var previous = UInt256.max
        // height - 1 = 15k blocks of schedule is k/8 of a 120-block half-life.
        for k in 1...16 {
            let height = UInt64(1 + 15 * k)
            let result = s.calculateAsertTarget(
                anchorTarget: UInt256.max, anchorTimestamp: anchorTime,
                anchorHeight: 1, blockTimestamp: anchorTime, blockHeight: height
            )
            XCTAssertLessThan(
                result, previous,
                "k=\(k): each further eighth of a half-life ahead must harden further"
            )
            XCTAssertGreaterThan(result, .zero)
            previous = result
        }
        // One half-life ahead is one doubling: half the maximum, not a quarter.
        let oneHalfLife = s.calculateAsertTarget(
            anchorTarget: UInt256.max, anchorTimestamp: anchorTime,
            anchorHeight: 1, blockTimestamp: anchorTime, blockHeight: UInt64(1 + window)
        )
        assertWithin(
            oneHalfLife, of: UInt256.max / UInt256(2), partsPerThousand: 2,
            "one half-life ahead of schedule is exactly one doubling"
        )
        // And two half-lives is two doublings: a quarter.
        let twoHalfLives = s.calculateAsertTarget(
            anchorTarget: UInt256.max, anchorTimestamp: anchorTime,
            anchorHeight: 1, blockTimestamp: anchorTime, blockHeight: UInt64(1 + 2 * window)
        )
        assertWithin(
            twoHalfLives, of: UInt256.max / UInt256(4), partsPerThousand: 2,
            "two half-lives ahead of schedule is exactly two doublings"
        )
    }

    /// The anchor walk must stop at the first ancestor the GRAPH already
    /// knows, not descend to height 1.
    ///
    /// The anchor is inherited, so any ancestor's anchor is this block's. The
    /// validator only reached for chain state when the immediate parent was
    /// admitted; while a chain syncs, the parent routinely is not, even though
    /// its own parent is. Abandoning the graph after one miss turned an O(1)
    /// lookup into a walk to height 1 -- per block, resolving every ancestor
    /// through the fetcher. Cost grew with depth and stalled a live network at
    /// ~1,800 blocks, with every node asleep on I/O.
    ///
    /// Counting fetches is the assertion: the depth of the walk IS the defect,
    /// so a test that only checked the returned anchor would have passed
    /// throughout.
    func testAnchorWalkStopsAtTheFirstAncestorTheChainKnows() async throws {
        let fetcher = CountingFetcher()
        let chainSpec = spec(targetBlockTime: 1_000)
        let genesis = try await buildAndStoreGenesis(
            spec: chainSpec, timestamp: 1_000,
            target: UInt256(1) << 240, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        // A chain deep enough that a full descent is unmistakable.
        var previous = genesis
        var blocks: [Block] = []
        for i in 0..<40 {
            let block = try await buildAndStoreBlock(
                previous: previous, timestamp: previous.timestamp + 1_000,
                nonce: UInt64(i), fetcher: fetcher
            )
            blocks.append(block)
            previous = block
        }
        // Admit everything EXCEPT the last block, so the deepest block's own
        // parent is absent from the graph while its grandparent is present --
        // exactly the shape sync produces.
        for block in blocks.dropLast() {
            let header = try VolumeImpl<Block>(node: block)
            _ = await chain.submitTestBlock(blockHeader: header, block: block)
        }

        let tip = blocks[blocks.count - 1]
        fetcher.resetCount()
        let anchor = try await BlockBuilder.resolveDifficultyAnchor(
            from: tip, fetcher: fetcher, chain: chain
        )
        let fetches = fetcher.count()

        XCTAssertEqual(anchor?.blockHeight, 1, "the anchor is still height 1")
        XCTAssertEqual(
            anchor?.timestamp, blocks[0].timestamp,
            "and is still block one's, whichever route found it"
        )
        XCTAssertLessThan(
            fetches, 5,
            "the walk must stop at the first known ancestor, not descend to height 1 "
                + "(took \(fetches) fetches at depth \(tip.height))"
        )
    }

    // MARK: - Bounded cost on attacker-supplied input

    /// A zero anchor target must not spin. Scaling zero yields zero, so a
    /// doubling loop driven by the drift would iterate its full count without
    /// ever leaving zero -- and the walk reads `target` from an ancestor it has
    /// not validated, so a forged height-1 block can supply exactly this.
    /// The bound is wall clock on purpose: the defect is unbounded work, and
    /// only a clock can witness that.
    func testZeroAnchorTargetTerminatesImmediately() {
        // The shortest half-life a valid spec can commit, which is what makes
        // the iteration count enormous: `doublings` is the drift measured in
        // half-lives, so a one-millisecond half-life turns the bounded drift
        // into ~1.4e14 iterations. A nonzero anchor escapes this after ~256
        // steps by crossing the representable ceiling; zero never does, because
        // doubling zero is zero.
        let s = spec(targetBlockTime: 1, window: 1)
        let started = Date()
        // Height 2 on purpose: a huge height makes `scheduled` saturate to the
        // same Int64.max as `elapsed`, which cancels to ZERO drift and would
        // exercise no shift at all. The damage needs a small height and a far
        // future timestamp, so the schedule is enormously behind.
        let result = s.calculateAsertTarget(
            anchorTarget: .zero, anchorTimestamp: 0,
            anchorHeight: 1, blockTimestamp: Int64.max, blockHeight: 2
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result, UInt256(1), "a zero anchor has no schedule; the hardest target is the safe answer")
        XCTAssertLessThan(elapsed, 1.0, "a zero anchor must not drive an unbounded shift")
    }

    /// The same bound on a legitimate saturating path. A chain stalled long
    /// enough, or a deep fork off an old block, produces a drift of many
    /// thousands of half-lives; the shift must saturate rather than iterate
    /// once per doubling.
    func testExtremeDriftSaturatesInBoundedTime() {
        let fast = spec(targetBlockTime: 1, window: 1)
        let started = Date()
        for anchorTarget in [UInt256(1), UInt256(1) << 128, UInt256.max] {
            let eased = fast.calculateAsertTarget(
                anchorTarget: anchorTarget, anchorTimestamp: 0,
                anchorHeight: 1, blockTimestamp: Int64.max, blockHeight: 2
            )
            let hardened = fast.calculateAsertTarget(
                anchorTarget: anchorTarget, anchorTimestamp: Int64.max,
                anchorHeight: 1, blockTimestamp: 0, blockHeight: UInt64.max
            )
            XCTAssertEqual(eased, UInt256.max, "an unbounded easing saturates at the maximum target")
            XCTAssertEqual(hardened, UInt256(1), "an unbounded hardening saturates at the hardest target")
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 1.0, "saturation must not cost one iteration per doubling")
    }

    // MARK: - The two anchor sources must agree

    /// The real split risk in production is not builder-vs-validator (both call
    /// the same walk) but CHAIN STATE vs the walk: a node with the block in
    /// `hashToBlock` answers from the anchor inherited at admission, and a node
    /// without it walks the ancestry. If those two ever disagree the network
    /// forks, and nothing else in the suite puts them side by side.
    ///
    /// Admission is driven out of height order deliberately, so the lazy
    /// backfill in `difficultyAnchor(forBlockHash:)` is what answers rather
    /// than a value written on the way in.
    func testChainStateAndWalkResolveTheSameAnchor() async throws {
        let fetcher = StorableFetcher()
        let chainSpec = spec(targetBlockTime: 1_000)
        let genesis = try await buildAndStoreGenesis(
            spec: chainSpec, timestamp: 1_000, target: UInt256(1) << 240, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        var blocks: [Block] = []
        var previous = genesis
        for (i, gap) in [1_000, 300, 7_000, 1_000, 40].enumerated() {
            let block = try await buildAndStoreBlock(
                previous: previous, timestamp: previous.timestamp + Int64(gap),
                nonce: UInt64(i), fetcher: fetcher
            )
            blocks.append(block)
            previous = block
        }

        for block in blocks {
            let header = try VolumeImpl<Block>(node: block)
            _ = await chain.submitTestBlock(blockHeader: header, block: block)
        }

        for block in blocks {
            let hash = try VolumeImpl<Block>(node: block).rawCID
            let carried = await chain.difficultyAnchor(forBlockHash: hash)
            let walked = try await BlockBuilder.resolveDifficultyAnchor(
                from: block, fetcher: fetcher
            )
            XCTAssertNotNil(carried, "chain state must carry an anchor for an admitted block at height \(block.height)")
            XCTAssertEqual(
                carried, walked,
                "chain-state and walked anchors must agree at height \(block.height); a disagreement forks the network"
            )
        }
    }

    // MARK: - Grindability across the curve

    /// A later timestamp must never yield a HARDER target, at any point on the
    /// curve. A single violation is a grinding edge: a miner would search for
    /// the timestamp that buys the easiest target instead of reporting the
    /// truth. One sample cannot establish this, so the response is swept
    /// across several half-lives in both directions.
    func testTargetIsMonotonicInTimestampAcrossTheCurve() {
        let s = spec(targetBlockTime: 1_000, window: 120)
        let anchorTarget = UInt256(1) << 200
        let anchorTime: Int64 = 1_000_000
        let halfLife: Int64 = 120 * 1_000
        var previous = UInt256.zero
        var sawIncrease = false
        // -3 to +3 half-lives, in steps small enough to land inside the cubic's
        // fractional part rather than only on doubling boundaries.
        for step in stride(from: -3 * halfLife, through: 3 * halfLife, by: Int(halfLife / 97)) {
            let result = s.calculateAsertTarget(
                anchorTarget: anchorTarget, anchorTimestamp: anchorTime,
                anchorHeight: 1, blockTimestamp: anchorTime + 60 * 1_000 + step,
                blockHeight: 61
            )
            XCTAssertGreaterThanOrEqual(
                result, previous,
                "a later timestamp must never harden the target (step \(step))"
            )
            if result > previous { sawIncrease = true }
            previous = result
        }
        XCTAssertTrue(sawIncrease, "the sweep must actually move the target, or it proves nothing")
    }

    // MARK: - helpers

    private func assertWithin(
        _ actual: UInt256, of expected: UInt256, partsPerThousand: UInt64,
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let larger = actual > expected ? actual : expected
        let smaller = actual > expected ? expected : actual
        let slack = expected / UInt256(1_000) * UInt256(partsPerThousand)
        XCTAssertLessThanOrEqual(larger - smaller, slack, message, file: file, line: line)
    }
}

/// Wraps the ordinary test store and counts how many objects the walk pulls.
/// The walk's DEPTH is the property under test, and only a count can see it.
final class CountingFetcher: Fetcher, Storer, VolumeStorer, @unchecked Sendable {
    private let inner = StorableFetcher()
    // NSLock rather than the os-specific lock the neighbouring helper uses:
    // this needs no platform guard, and the counter is not on a hot path.
    private let lock = NSLock()
    private var fetches = 0

    func resetCount() { lock.withLock { fetches = 0 } }
    func count() -> Int { lock.withLock { fetches } }

    func store(rawCid: String, data: Data) { inner.store(rawCid: rawCid, data: data) }
    func store(entries: [String: Data]) async { await inner.store(entries: entries) }
    func store(volume: SerializedVolume) async { await inner.store(volume: volume) }
    func volumeRoots() -> Set<String> { inner.volumeRoots() }
    func contains(rawCid: String) -> Bool { inner.contains(rawCid: rawCid) }

    func fetch(rawCid: String) async throws -> Data {
        // `withLock` is the async-safe scoped form; bare lock()/unlock() is
        // unavailable from an async context.
        lock.withLock { fetches += 1 }
        return try await inner.fetch(rawCid: rawCid)
    }
}
