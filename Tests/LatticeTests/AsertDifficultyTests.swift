import XCTest
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
    func testTargetDependsOnlyOnTheAnchorAndThisBlock() {
        let s = spec()
        let anchorTarget = UInt256(1) << 215
        let anchorTime: Int64 = 1_000_000
        let arrival = anchorTime + 500 * 3_600_000

        // The function cannot even see intermediate history — which is the
        // point — so the same inputs must give the same answer, and that is
        // what a caller replaying a wildly irregular chain will pass.
        let first = s.calculateAsertTarget(
            anchorTarget: anchorTarget, anchorTimestamp: anchorTime,
            anchorHeight: 1, blockTimestamp: arrival, blockHeight: 400
        )
        let second = s.calculateAsertTarget(
            anchorTarget: anchorTarget, anchorTimestamp: anchorTime,
            anchorHeight: 1, blockTimestamp: arrival, blockHeight: 400
        )
        XCTAssertEqual(first, second)
        // And it is genuinely off-schedule here, so this is not asserting
        // equality of two unchanged anchors.
        XCTAssertNotEqual(first, anchorTarget)
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
        var blockOneHash: String?
        for i in 1...6 {
            let block = try await buildAndStoreBlock(
                previous: previous, timestamp: 1_000 + Int64(i) * 1_000, fetcher: fetcher
            )
            if block.height == 1 { blockOneHash = try BlockHeader(node: block).rawCID }
            let anchor = try await BlockBuilder.resolveDifficultyAnchor(
                from: block, fetcher: fetcher
            )
            XCTAssertEqual(anchor?.blockHeight, 1, "every block anchors at height 1")
            XCTAssertEqual(anchor?.blockHash, blockOneHash,
                           "and at the SAME height-1 block, not merely some block of height 1")
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
                blockHash: "", blockHeight: 1,
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

        XCTAssertNotEqual(leftAnchor?.blockHash, rightAnchor?.blockHash,
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
        let easyBranch = workForTarget(UInt256.max)
        let honestBranch = workForTarget(UInt256(1) << 215)
        XCTAssertEqual(easyBranch, UInt256(1), "a maximum target is worth one unit of work")
        XCTAssertGreaterThan(honestBranch, easyBranch * UInt256(1_000_000_000),
                             "an honest target must be worth vastly more per block")
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
