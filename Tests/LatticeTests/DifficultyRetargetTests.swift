import XCTest
@testable import Lattice
import UInt256
import cashew

@MainActor
final class DifficultyRetargetTests: XCTestCase {
    private func spec(window: UInt64 = 120, target: UInt64 = 3_600_000) -> ChainSpec {
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

    private func oracleLWMA(previousTarget: UInt256, targetBlockTime: UInt64, window: UInt64, newestFirstTimestamps: [Int64]) -> UInt256 {
        let intervalCount = min(newestFirstTimestamps.count - 1, Int(window))
        guard intervalCount > 0 else { return previousTarget }

        var weightedActual = UInt256.zero
        var weightSum = UInt256.zero
        for index in 0..<intervalCount {
            let solveTime = max(Int64(0), newestFirstTimestamps[index] - newestFirstTimestamps[index + 1])
            let weight = UInt256(UInt64(intervalCount - index))
            let solve = UInt256(UInt64(solveTime))
            let weightedSolve = solve > UInt256.max / weight ? UInt256.max : solve * weight
            weightedActual = weightedActual > UInt256.max - weightedSolve ? UInt256.max : weightedActual + weightedSolve
            weightSum = weightSum + weight
        }
        guard weightedActual > .zero else { return ChainSpec.minimumTarget }

        let weightedTarget = UInt256(targetBlockTime) * weightSum
        return max(oracleMultiplyDividingSaturating(previousTarget, by: weightedActual, over: weightedTarget), ChainSpec.minimumTarget)
    }

    private func oracleMultiplyDividingSaturating(_ value: UInt256, by numerator: UInt256, over denominator: UInt256) -> UInt256 {
        guard denominator > .zero else { return UInt256.max }
        guard numerator > .zero else { return .zero }
        let quotient = value / denominator
        let remainder = value % denominator
        let scaledQuotient = quotient > UInt256.max / numerator ? UInt256.max : quotient * numerator
        let scaledRemainderProduct = remainder > UInt256.max / numerator ? UInt256.max : remainder * numerator
        let scaledRemainder = scaledRemainderProduct / denominator
        return scaledQuotient > UInt256.max - scaledRemainder ? UInt256.max : scaledQuotient + scaledRemainder
    }

    private func makeGenesis(spec: ChainSpec, timestamp: Int64, target: UInt256, fetcher: StorableFetcher) async throws -> Block {
        try await BlockBuilder.buildGenesis(
            spec: spec,
            timestamp: timestamp,
            target: target,
            fetcher: fetcher
        )
    }

    private func makeNext(previous: Block, timestamp: Int64, target: UInt256, nextTarget: UInt256, fetcher: StorableFetcher) async throws -> Block {
        try await BlockBuilder.buildBlock(
            previous: previous,
            timestamp: timestamp,
            target: target,
            nextTarget: nextTarget,
            fetcher: fetcher
        )
    }

    private func storeBlock(_ block: Block, to fetcher: StorableFetcher) async throws {
        let storer = CollectingStorer()
        try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
        await storer.flush(to: fetcher)
    }

    private func cid(_ block: Block) -> String {
        try! VolumeImpl<Block>(node: block).rawCID
    }

    func testLwmaRetargetWeightedAverageUsesRecentWeights() {
        let s = spec(window: 4, target: 1_000)
        let previous = UInt256(10_000)
        let timestamps: [Int64] = [10_000, 9_000, 7_500, 5_000, 1_000]

        let expected = oracleLWMA(
            previousTarget: previous,
            targetBlockTime: s.targetBlockTime,
            window: s.retargetWindow,
            newestFirstTimestamps: timestamps
        )

        XCTAssertEqual(expected, UInt256(17_500))
        XCTAssertEqual(s.calculateWindowedTarget(previousTarget: previous, ancestorTimestamps: timestamps), expected)
    }

    // MARK: - Proportional-retarget window/clamp invariant (E4.6 /

    /// Bound a single retarget step the way the choke point must: at most
    /// `maxTargetChange`× in either direction, never below `minimumTarget`.
    private func clampBounds(previousTarget: UInt256) -> (lower: UInt256, upper: UInt256) {
        let factor = UInt256(UInt64(ChainSpec.maxTargetChange))
        let upper = previousTarget > UInt256.max / factor ? UInt256.max : previousTarget * factor
        let lower = max(previousTarget / factor, ChainSpec.minimumTarget)
        return (lower, upper)
    }

    private func assertRetargetInvariants(
        _ s: ChainSpec,
        previousTarget: UInt256,
        ancestorTimestamps: [Int64],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = s.calculateWindowedTarget(previousTarget: previousTarget, ancestorTimestamps: ancestorTimestamps)
        let (lower, upper) = clampBounds(previousTarget: previousTarget)

        // (1) per-retarget move bounded by maxTargetChange in either direction.
        XCTAssertLessThanOrEqual(result, upper, "target rose by more than maxTargetChange×", file: file, line: line)
        XCTAssertGreaterThanOrEqual(result, lower, "target fell by more than maxTargetChange×", file: file, line: line)

        // (2) never below minimumTarget.
        XCTAssertGreaterThanOrEqual(result, ChainSpec.minimumTarget, "target dropped below minimumTarget", file: file, line: line)
    }

    /// A miner who grinds an enormous solve-time spread must not be able to
    /// swing difficulty by more than maxTargetChange× in a single retarget.
    /// Pre-fix this is RED: the unclamped LWMA returns ~max-factor easier.
    func testGrindedLongSolveTimesClampedToMaxTargetChange() {
        let s = spec(window: 4, target: 1_000)
        let previous = UInt256(10_000)
        // Newest-first timestamps with huge gaps ⇒ LWMA wants a far-easier target.
        let timestamps: [Int64] = [1_000_000, 800_000, 500_000, 100_000, 0]

        let unclampedOracle = oracleLWMA(
            previousTarget: previous,
            targetBlockTime: s.targetBlockTime,
            window: s.retargetWindow,
            newestFirstTimestamps: timestamps
        )
        // Sanity: without a clamp the LWMA blows past the 2× ceiling.
        XCTAssertGreaterThan(unclampedOracle, previous * UInt256(UInt64(ChainSpec.maxTargetChange)))

        let result = s.calculateWindowedTarget(previousTarget: previous, ancestorTimestamps: timestamps)
        XCTAssertEqual(result, previous * UInt256(UInt64(ChainSpec.maxTargetChange)), "easing must saturate at maxTargetChange×")
        assertRetargetInvariants(s, previousTarget: previous, ancestorTimestamps: timestamps)
    }

    /// All-zero solve times (every block "instant") drive the LWMA toward zero;
    /// the clamp must hold the floor at previous / maxTargetChange.
    func testGrindedZeroSolveTimesClampedToMaxTargetChange() {
        let s = spec(window: 4, target: 1_000)
        let previous = UInt256(10_000)
        // Equal timestamps ⇒ zero solve time ⇒ smallest possible target.
        let timestamps: [Int64] = [5_000, 5_000, 5_000, 5_000, 5_000]

        let result = s.calculateWindowedTarget(previousTarget: previous, ancestorTimestamps: timestamps)
        XCTAssertEqual(result, previous / UInt256(UInt64(ChainSpec.maxTargetChange)), "hardening must saturate at previous / maxTargetChange")
        assertRetargetInvariants(s, previousTarget: previous, ancestorTimestamps: timestamps)
    }

    /// The window must consume at most `retargetWindow` intervals: timestamps
    /// beyond the window are ignored, so padding with adversarial far-history
    /// cannot change the result.
    func testWindowUsesAtMostRetargetWindowIntervals() {
        let s = spec(window: 3, target: 1_000)
        let previous = UInt256(10_000)
        // 4 intervals' worth of timestamps but window == 3.
        let windowed: [Int64] = [4_000, 3_000, 2_000, 1_000]
        // Same newest 3 intervals; the first beyond-window timestamp is made
        // adversarial so the (retargetWindow + 1)th interval is NOT a normal
        // 1,000-second interval. Here windowed ends at 1,000 and the first
        // padded element is -10_000_000, so an off-by-one that consumed one
        // extra interval would inject a ~10_000_001s solve time — easing the
        // target hard enough to hit the maxTargetChange× ceiling. A correct
        // window ignores it, so `a == b` only holds when exactly
        // `retargetWindow` intervals are consumed.
        let padded: [Int64] = windowed + [Int64](repeating: -10_000_000, count: 50)

        // Sanity: an off-by-one that consumed `retargetWindow + 1` intervals
        // would read a fundamentally different target. We model both via the
        // oracle (true window vs. window + 1) and confirm the adversarial
        // boundary interval makes them diverge — so this test can actually
        // catch a one-extra-interval bug rather than absorbing it as another
        // normal 1,000-second interval.
        let correctOracle = oracleLWMA(previousTarget: previous, targetBlockTime: s.targetBlockTime, window: s.retargetWindow, newestFirstTimestamps: padded)
        let offByOneOracle = oracleLWMA(previousTarget: previous, targetBlockTime: s.targetBlockTime, window: s.retargetWindow + 1, newestFirstTimestamps: padded)
        XCTAssertNotEqual(correctOracle, offByOneOracle, "adversarial boundary interval must move the result if consumed")
        XCTAssertGreaterThan(offByOneOracle, correctOracle * UInt256(100), "the (retargetWindow + 1)th interval must ease the target by a large factor, not by a normal interval")

        let a = s.calculateWindowedTarget(previousTarget: previous, ancestorTimestamps: windowed)
        let b = s.calculateWindowedTarget(previousTarget: previous, ancestorTimestamps: padded)
        XCTAssertEqual(a, b, "intervals beyond retargetWindow must not affect the result")
        assertRetargetInvariants(s, previousTarget: previous, ancestorTimestamps: padded)
    }

    /// Property sweep: across a range of adversarial timestamp spreads the three
    /// invariants (clamp up, clamp down, minimumTarget floor) always hold.
    func testRetargetInvariantsHoldAcrossAdversarialTimestamps() {
        let s = spec(window: 8, target: 1_000)
        let previousTargets: [UInt256] = [UInt256(1), UInt256(2), UInt256(1_000), UInt256(10_000), UInt256.max]
        let spreads: [Int64] = [0, 1, 500, 1_000, 10_000, 1_000_000, 1_000_000_000]

        for previous in previousTargets {
            for spread in spreads {
                // Decreasing newest-first timestamps with a fixed per-interval spread.
                var ts: [Int64] = []
                var t: Int64 = spread * 16
                for _ in 0...10 {
                    ts.append(t)
                    t -= spread
                }
                assertRetargetInvariants(s, previousTarget: previous, ancestorTimestamps: ts)

                // Also the reversed (increasing) ordering, which yields zero solve times.
                assertRetargetInvariants(s, previousTarget: previous, ancestorTimestamps: ts.reversed())
            }
        }
    }

    /// When the timestamp window has 0 or 1 elements no retarget interval can be
    /// computed, so the early-return must still apply the minimumTarget floor. A
    /// zero previousTarget on this path previously leaked straight through,
    /// bypassing both the floor and the clamp.
    func testRetargetFloorsZeroPreviousTargetOnEmptyOrSingleWindow() {
        let s = spec(window: 8, target: 1_000)

        // Empty window.
        XCTAssertGreaterThanOrEqual(
            s.calculateWindowedTarget(previousTarget: .zero, ancestorTimestamps: []),
            ChainSpec.minimumTarget,
            "zero previousTarget with an empty window must be floored at minimumTarget"
        )

        // Single-element window (still no interval available).
        XCTAssertGreaterThanOrEqual(
            s.calculateWindowedTarget(previousTarget: .zero, ancestorTimestamps: [10_000]),
            ChainSpec.minimumTarget,
            "zero previousTarget with a single timestamp must be floored at minimumTarget"
        )
    }

    func testValidateNextDifficultyRejectsOldBandNearMisses() async throws {
        let s = spec(window: 120, target: 1_000)
        let fetcher = StorableFetcher()
        let parent = try await makeGenesis(spec: s, timestamp: 1_000, target: UInt256(10_000), fetcher: fetcher)
        let blockTimestamp: Int64 = 2_000
        let expected = oracleLWMA(
            previousTarget: parent.nextTarget,
            targetBlockTime: s.targetBlockTime,
            window: s.retargetWindow,
            newestFirstTimestamps: [blockTimestamp, parent.timestamp]
        )

        let valid = try await makeNext(
            previous: parent,
            timestamp: blockTimestamp,
            target: parent.nextTarget,
            nextTarget: expected,
            fetcher: fetcher
        )
        XCTAssertTrue(valid.validateNextTarget(spec: s, parent: parent, ancestorTimestamps: [parent.timestamp]))

        let tooEasy = try await makeNext(
            previous: parent,
            timestamp: blockTimestamp,
            target: parent.nextTarget,
            nextTarget: expected * UInt256(2),
            fetcher: fetcher
        )
        XCTAssertFalse(tooEasy.validateNextTarget(spec: s, parent: parent, ancestorTimestamps: [parent.timestamp]))

        let tooHard = try await makeNext(
            previous: parent,
            timestamp: blockTimestamp,
            target: parent.nextTarget,
            nextTarget: expected / UInt256(2),
            fetcher: fetcher
        )
        XCTAssertFalse(tooHard.validateNextTarget(spec: s, parent: parent, ancestorTimestamps: [parent.timestamp]))
    }

    func testDifficultyMustBindToParentNextDifficulty() async throws {
        let s = spec(window: 120, target: 1_000)
        let fetcher = StorableFetcher()
        let parent = try await makeGenesis(spec: s, timestamp: 1_000, target: UInt256(10_000), fetcher: fetcher)
        let blockTimestamp: Int64 = 2_000
        let expected = oracleLWMA(
            previousTarget: parent.nextTarget,
            targetBlockTime: s.targetBlockTime,
            window: s.retargetWindow,
            newestFirstTimestamps: [blockTimestamp, parent.timestamp]
        )
        let forgedDifficulty = parent.nextTarget + UInt256(1)
        let block = try await makeNext(
            previous: parent,
            timestamp: blockTimestamp,
            target: forgedDifficulty,
            nextTarget: expected,
            fetcher: fetcher
        )

        XCTAssertFalse(block.validateNextTarget(spec: s, parent: parent, ancestorTimestamps: [parent.timestamp]))
    }

    func testMTPMedianIsPinnedToMostRecentElevenTimestamps() async throws {
        let s = spec(window: 20, target: 1_000)
        let fetcher = StorableFetcher()
        let parent = try await makeGenesis(spec: s, timestamp: 1_000, target: UInt256(10_000), fetcher: fetcher)
        let block = try await makeNext(
            previous: parent,
            timestamp: 1_035,
            target: parent.nextTarget,
            nextTarget: UInt256(10_000),
            fetcher: fetcher
        )
        let mostRecentEleven: [Int64] = [1_050, 1_040, 1_030, 1_020, 1_010, 1_000, 990, 980, 970, 960, 950]
        let olderHighOutliers = Array(repeating: Int64(10_000), count: 9)
        let oldAllWindowMedian = (mostRecentEleven + olderHighOutliers).sorted()[9]

        XCTAssertLessThanOrEqual(block.timestamp, oldAllWindowMedian)
        XCTAssertTrue(block.validateTimestamp(parent: parent, ancestorTimestamps: mostRecentEleven + olderHighOutliers))
    }

    func testMissingAncestorRejectsInsteadOfTwoBlockFallback() async throws {
        let s = spec(window: 120, target: 1_000)
        let fullFetcher = StorableFetcher()
        let genesis = try await makeGenesis(spec: s, timestamp: 1_000, target: UInt256(10_000), fetcher: fullFetcher)
        let block1 = try await makeNext(
            previous: genesis,
            timestamp: 2_000,
            target: genesis.nextTarget,
            nextTarget: UInt256(10_000),
            fetcher: fullFetcher
        )
        let fallbackOnlyNext = s.calculateMinimumTarget(
            previousTarget: block1.nextTarget,
            blockTimestamp: 3_000,
            previousTimestamp: block1.timestamp
        )
        let block2 = try await makeNext(
            previous: block1,
            timestamp: 3_000,
            target: block1.nextTarget,
            nextTarget: fallbackOnlyNext,
            fetcher: fullFetcher
        )

        let partialFetcher = StorableFetcher()
        let block1CID = try! VolumeImpl<Block>(node: block1).rawCID
        guard let block1Data = block1.toData() else {
            return XCTFail("block1 serialization failed")
        }
        partialFetcher.store(rawCid: block1CID, data: block1Data)

        let valid = try await block2.validateNexus(fetcher: partialFetcher).0
        XCTAssertFalse(valid, "missing ancestors must reject/defer instead of falling back to a two-block retarget")
    }

    func testGeneratedChainPassesValidateNexusAndSyncWalks() async throws {
        let s = spec(window: 120, target: 1_000)
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(spec: s, timestamp: 1_000, target: UInt256.max, fetcher: fetcher)
        try await storeBlock(genesis, to: fetcher)

        var blocks = [genesis]
        for offset in 1...5 {
            let block = try await BlockBuilder.buildBlock(
                previous: blocks.last!,
                timestamp: 1_000 + Int64(offset * 1_000),
                fetcher: fetcher
            )
            try await storeBlock(block, to: fetcher)
            let valid = try await block.validateNexus(fetcher: fetcher).0
            XCTAssertTrue(valid, "honest generated block \(offset) must validate")
            blocks.append(block)
        }

        let tipCID = cid(blocks.last!)
        let syncer = ChainSyncer(fetcher: fetcher, store: { _, _ in }, genesisBlockHash: cid(genesis))
        let snapshot = try await syncer.syncSnapshot(peerTipCID: tipCID, depth: 10)
        XCTAssertEqual(snapshot.tipBlockHash, tipCID)

        let full = try await ChainSyncer(fetcher: fetcher, store: { _, _ in }, genesisBlockHash: cid(genesis))
            .syncFull(peerTipCID: tipCID)
        XCTAssertEqual(full.tipBlockHash, tipCID)
    }

    func testForgedNextDifficultyRejectedByValidateNexusAndSyncWalks() async throws {
        let s = spec(window: 120, target: 1_000)
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(spec: s, timestamp: 1_000, target: UInt256.max, fetcher: fetcher)
        try await storeBlock(genesis, to: fetcher)

        let blockTimestamp: Int64 = 2_000
        let expected = oracleLWMA(
            previousTarget: genesis.nextTarget,
            targetBlockTime: s.targetBlockTime,
            window: s.retargetWindow,
            newestFirstTimestamps: [blockTimestamp, genesis.timestamp]
        )
        let forged = try await makeNext(
            previous: genesis,
            timestamp: blockTimestamp,
            target: genesis.nextTarget,
            nextTarget: expected - UInt256(1),
            fetcher: fetcher
        )
        try await storeBlock(forged, to: fetcher)
        let forgedCID = cid(forged)
        let genesisCID = cid(genesis)

        let directValid = try await forged.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(directValid)

        do {
            _ = try await ChainSyncer(fetcher: fetcher, store: { _, _ in }, genesisBlockHash: genesisCID)
                .syncSnapshot(peerTipCID: forgedCID, depth: 10)
            XCTFail("syncSnapshot must reject forged retargets during the block walk")
        } catch SyncError.invalidBlock(let height) {
            XCTAssertEqual(height, forged.height)
        }

        do {
            _ = try await ChainSyncer(fetcher: fetcher, store: { _, _ in }, genesisBlockHash: genesisCID)
                .syncFull(peerTipCID: forgedCID)
            XCTFail("syncFull must reject forged retargets during the block walk")
        } catch SyncError.invalidBlock(let height) {
            XCTAssertEqual(height, forged.height)
        }

        let headers = [
            SyncBlockHeader(
                cid: genesisCID,
                height: genesis.height,
                previousBlockCID: nil,
                target: genesis.target,
                nextTarget: genesis.nextTarget,
                timestamp: genesis.timestamp,
                specCID: genesis.spec.rawCID,
                spec: genesis.spec.node
            ),
            SyncBlockHeader(
                cid: forgedCID,
                height: forged.height,
                previousBlockCID: forged.parent?.rawCID,
                target: forged.target,
                nextTarget: forged.nextTarget,
                timestamp: forged.timestamp,
                specCID: forged.spec.rawCID,
                spec: forged.spec.node
            )
        ]
        do {
            _ = try await ChainSyncer(fetcher: fetcher, store: { _, _ in }, genesisBlockHash: genesisCID)
                .syncFromHeaders(headers, cumulativeWork: UInt256(2))
            XCTFail("syncFromHeaders must reject forged retargets from header consensus data")
        } catch SyncError.invalidBlock(let height) {
            XCTAssertEqual(height, forged.height)
        }
    }
}
