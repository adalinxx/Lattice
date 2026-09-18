import cashew
import Foundation
import UInt256

/// The conventional name of the single root chain (Nexus). A chain's directory
/// is positional — it is the key it is anchored under in its parent's
/// genesisState (i.e. the last element of its chainPath) — and is therefore NOT
/// stored in the content-addressed `ChainSpec`. This constant is only the
/// fallback used by the validators when no chainPath/directory is supplied,
/// which is the root case; the node always supplies its configured chainPath.
public let DEFAULT_ROOT_DIRECTORY = "Nexus"

public struct ChainSpec: Scalar {
    public let maxNumberOfTransactionsPerBlock: UInt64
    public let maxStateGrowth: Int
    public let maxBlockSize: Int
    public let premine: UInt64
    public let targetBlockTime: UInt64
    public let initialReward: UInt64
    public let halvingInterval: UInt64
    public let retargetWindow: UInt64
    public let wasmPolicies: [WasmPolicyRef]
    /// Per-retarget difficulty clamp: a single retarget may move the target at
    /// most this many × in either direction. This is the chain's own committed
    /// manipulation-resistance vs. adaptation-speed choice (tighter = harder to
    /// grind timestamps, slower to track real hashrate); `nil` — the default —
    /// commits none, and the windowed retarget applies its proportional
    /// correction unclamped. There is no protocol-imposed default: a clamp
    /// exists only when the chain commits one and lives with the consequences.
    public let maxTargetChange: UInt8?
    enum CodingKeys: String, CodingKey {
        case maxNumberOfTransactionsPerBlock
        case maxStateGrowth
        case maxBlockSize
        case premine
        case targetBlockTime
        case initialReward
        case halvingInterval
        case retargetWindow
        case wasmPolicies
        case maxTargetChange
    }

    enum LegacyCodingKeys: String, CodingKey {
        case transactionFilters
        case actionFilters
    }

    public init(
        maxNumberOfTransactionsPerBlock: UInt64,
        maxStateGrowth: Int,
        maxBlockSize: Int = 1_000_000,
        premine: UInt64,
        targetBlockTime: UInt64,
        initialReward: UInt64,
        halvingInterval: UInt64,
        retargetWindow: UInt64 = 10,
        wasmPolicies: [WasmPolicyRef] = [],
        maxTargetChange: UInt8? = nil
    ) {
        self.maxNumberOfTransactionsPerBlock = maxNumberOfTransactionsPerBlock
        self.maxStateGrowth = maxStateGrowth
        self.maxBlockSize = maxBlockSize
        self.premine = premine
        self.targetBlockTime = targetBlockTime
        self.initialReward = initialReward
        self.halvingInterval = halvingInterval
        self.retargetWindow = retargetWindow
        self.wasmPolicies = wasmPolicies
        self.maxTargetChange = maxTargetChange
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        maxNumberOfTransactionsPerBlock = try container.decode(UInt64.self, forKey: .maxNumberOfTransactionsPerBlock)
        maxStateGrowth = try container.decode(Int.self, forKey: .maxStateGrowth)
        maxBlockSize = try container.decodeIfPresent(Int.self, forKey: .maxBlockSize) ?? 1_000_000
        premine = try container.decode(UInt64.self, forKey: .premine)
        targetBlockTime = try container.decode(UInt64.self, forKey: .targetBlockTime)
        initialReward = try container.decode(UInt64.self, forKey: .initialReward)
        halvingInterval = try container.decode(UInt64.self, forKey: .halvingInterval)
        retargetWindow = try container.decodeIfPresent(UInt64.self, forKey: .retargetWindow) ?? 10
        if legacyContainer.contains(.transactionFilters) || legacyContainer.contains(.actionFilters) {
            throw DecodingError.dataCorruptedError(
                forKey: legacyContainer.contains(.transactionFilters) ? .transactionFilters : .actionFilters,
                in: legacyContainer,
                debugDescription: "Legacy JavaScript filters are not supported; migrate to wasmPolicies"
            )
        }
        wasmPolicies = try container.decodeIfPresent([WasmPolicyRef].self, forKey: .wasmPolicies) ?? []
        maxTargetChange = try container.decodeIfPresent(UInt8.self, forKey: .maxTargetChange)
    }
}

// MARK: - Reward Calculations
public extension ChainSpec {

    private func elapsedMilliseconds(later: Int64, earlier: Int64) -> UInt64 {
        guard later > earlier else { return 0 }
        if earlier >= 0 || later < 0 {
            return UInt64(later - earlier)
        }
        return UInt64(later) + UInt64(-(earlier + 1)) + 1
    }

    func rewardAtBlock(_ blockHeight: UInt64) -> UInt64 {
        guard halvingInterval > 0 else { return 0 }
        // premine is uncapped, so blockHeight + premine can overflow UInt64.
        // An overflowing offset is astronomically past every halving → 0 reward.
        // Stay total so a content-addressed spec can never trap a validator.
        let (offsetBlockIndex, overflow) = blockHeight.addingReportingOverflow(premine)
        guard !overflow else { return 0 }
        let halvings = offsetBlockIndex / halvingInterval
        guard halvings < 64 else { return 0 }
        return initialReward >> halvings
    }

    func totalRewards(upToBlock blockCount: UInt64) -> UInt64 {
        guard blockCount > 0, halvingInterval > 0 else { return 0 }

        var total: UInt64 = 0
        var blocksProcessed: UInt64 = 0

        while blocksProcessed < blockCount {
            // Overflow ⇒ offset past every halving ⇒ no further emission.
            let (offsetBlock, offsetOverflow) = blocksProcessed.addingReportingOverflow(premine)
            guard !offsetOverflow else { break }
            let currentHalving = offsetBlock / halvingInterval
            guard currentHalving < 64 else { break }
            let currentReward = initialReward >> currentHalving

            guard currentReward > 0 else { break }

            // How many blocks remain in this halving period?
            let remainingBlocks = blockCount - blocksProcessed
            let (hPlus1, c1) = currentHalving.addingReportingOverflow(1)
            let (absBoundary, c2) = c1 ? (UInt64.max, true) : hPlus1.multipliedReportingOverflow(by: halvingInterval)
            let blocksInThisPeriod: UInt64
            if c1 || c2 {
                blocksInThisPeriod = remainingBlocks
            } else {
                let (nextHalvingAt, sub) = absBoundary.subtractingReportingOverflow(premine)
                if sub {
                    blocksInThisPeriod = remainingBlocks
                } else {
                    let (blocksUntil, sub2) = nextHalvingAt.subtractingReportingOverflow(blocksProcessed)
                    blocksInThisPeriod = sub2 ? remainingBlocks : min(blocksUntil, remainingBlocks)
                }
            }
            guard blocksInThisPeriod > 0 else { break }

            let (periodRewards, overflow) = currentReward.multipliedReportingOverflow(by: blocksInThisPeriod)
            if overflow { return UInt64.max }
            let (newTotal, addOverflow) = total.addingReportingOverflow(periodRewards)
            if addOverflow { return UInt64.max }
            total = newTotal

            let (newBlocksProcessed, processOverflow) = blocksProcessed.addingReportingOverflow(blocksInThisPeriod)
            if processOverflow { break }
            blocksProcessed = newBlocksProcessed
        }

        return total
    }

    func premineAmount() -> UInt64 {
        guard premine > 0, halvingInterval > 0 else { return 0 }

        var total: UInt64 = 0
        var blocksProcessed: UInt64 = 0

        while blocksProcessed < premine {
            let currentHalving = blocksProcessed / halvingInterval
            guard currentHalving < 64 else { break }
            let currentReward = initialReward >> currentHalving
            guard currentReward > 0 else { break }

            let (hPlus1, c1) = currentHalving.addingReportingOverflow(1)
            let (nextHalvingBoundary, c2) = c1 ? (UInt64.max, true) : hPlus1.multipliedReportingOverflow(by: halvingInterval)
            let nextHalvingAt = c2 ? UInt64.max : nextHalvingBoundary
            let blocksInThisPeriod = min(nextHalvingAt - blocksProcessed, premine - blocksProcessed)

            let (periodRewards, overflow) = currentReward.multipliedReportingOverflow(by: blocksInThisPeriod)
            if overflow { return UInt64.max }
            let (newTotal, addOverflow) = total.addingReportingOverflow(periodRewards)
            if addOverflow { return UInt64.max }
            total = newTotal

            let (newBlocksProcessed, processOverflow) = blocksProcessed.addingReportingOverflow(blocksInThisPeriod)
            if processOverflow { break }
            blocksProcessed = newBlocksProcessed
        }

        return total
    }

    var totalHalvings: UInt64 {
        guard initialReward > 0 else { return 0 }
        return UInt64(UInt64.bitWidth - initialReward.leadingZeroBitCount)
    }

    var isValid: Bool {
        // `premine` is intentionally uncapped: it is a block-count offset into
        // the emission schedule, and `premineAmount`/`rewardAtBlock`/`totalRewards`
        // already loop across halving periods with saturating overflow guards and
        // the `halvings < 64` ceiling. A premine spanning multiple halvings (up to
        // a fully-premined, zero-ongoing-emission chain) is a deliberate, honest
        // tokenomics choice for permissionless child chains — transparency, not a
        // protocol ceiling, governs premine. The real bound is the Int64 genesis
        // credit and the emission math, both of which remain well-defined.
        return maxNumberOfTransactionsPerBlock > 0 &&
               maxStateGrowth > 0 &&
               maxBlockSize > 0 &&
               targetBlockTime > 0 &&
               initialReward > 0 &&
               halvingInterval > 0 &&
               maxTargetChange.map { $0 > 0 } ?? true &&
               retargetWindow > 0
    }
}

// MARK: - Target Calculations
public extension ChainSpec {

    private func multiplyDividingSaturating(_ value: UInt256, by numerator: UInt256, over denominator: UInt256) -> UInt256 {
        guard denominator > .zero else { return UInt256.max }
        guard numerator > .zero else { return .zero }

        let quotient = value / denominator
        let remainder = value % denominator

        let scaledQuotient = quotient > UInt256.max / numerator ? UInt256.max : quotient * numerator
        let scaledRemainderProduct = remainder > UInt256.max / numerator ? UInt256.max : remainder * numerator
        let scaledRemainder = scaledRemainderProduct / denominator

        return scaledQuotient > UInt256.max - scaledRemainder
            ? UInt256.max
            : scaledQuotient + scaledRemainder
    }

    /// The difficulty schedule: an absolutely-scheduled exponential target.
    ///
    /// The target for a block is a function of ONE anchor and this block's own
    /// height and timestamp:
    ///
    ///     target = anchorTarget * 2^((elapsed - targetBlockTime * heights) / halfLife)
    ///
    /// where `elapsed` is the time since the anchor and `heights` is the number
    /// of blocks since it. When the chain is exactly on schedule the exponent is
    /// zero and the target is the anchor's. Running ahead of schedule hardens
    /// it, running behind eases it, smoothly and without bound in either
    /// direction.
    ///
    /// **There is no window, and that is the point.** A windowed average carries
    /// the last `retargetWindow` intervals as state, so a stretch of unusual
    /// block times keeps steering difficulty long after it has passed, and a
    /// window perturbed at one end oscillates as it drains. This reads only the
    /// anchor and the present block, so it has nothing to drain: a disturbance
    /// stops mattering the moment it stops happening.
    ///
    /// It is also why the genesis timestamp cannot poison this schedule. A
    /// window that reaches back to genesis reads the gap before block 1 as one
    /// colossal solve time -- on a chain stamping genesis at epoch 0 that gap is
    /// decades, and the estimator eases every block until it finally ages out.
    /// Anchored at block 1, genesis is simply never read.
    ///
    /// The anchor must be a block whose target is near what the chain can
    /// actually sustain. This moves at most one doubling per half-life, so an
    /// anchor far from the truth is approached slowly -- from a maximum target
    /// that is dozens of half-lives, spent at negligible difficulty.
    ///
    /// Integer-exact by construction. Every node must compute the identical
    /// target from the identical inputs, so the exponential is evaluated in
    /// 16.16 fixed point with a cubic approximation over the fractional part --
    /// the same shape Bitcoin Cash's `aserti3-2d` uses, and for the same reason.
    /// No floating point appears anywhere in this path.
    func calculateAsertTarget(
        anchorTarget: UInt256,
        anchorTimestamp: Int64,
        anchorHeight: UInt64,
        blockTimestamp: Int64,
        blockHeight: UInt64
    ) -> UInt256 {
        guard blockHeight > anchorHeight else { return anchorTarget }
        let halfLifeMilliseconds = halfLifeMilliseconds()
        guard halfLifeMilliseconds > 0 else { return anchorTarget }
        // A zero anchor target expresses no schedule: every scaling of zero is
        // zero, so the doubling below could never climb out of it however long
        // it ran. An anchor read from an unvalidated ancestor can carry one, so
        // this is a reachable input and not merely a defensive check.
        guard anchorTarget != .zero else { return UInt256(1) }

        // How far ahead of (negative) or behind (positive) schedule we are, in
        // milliseconds. Both terms are clamped before use: `blockTimestamp` is
        // attacker-supplied on an unconnected block, and the height difference
        // is bounded by the chain itself.
        let heights = blockHeight - anchorHeight
        let product = heights.multipliedReportingOverflow(by: targetBlockTime)
        let scheduled = Int64(clamping: product.overflow ? UInt64.max : product.partialValue)
        // A timestamp at or before the anchor yields zero elapsed, which makes
        // the drift maximally negative and the target harder. Moving a block's
        // clock backwards therefore costs the miner difficulty rather than
        // buying any, so the clamp needs no separate defence.
        let elapsed = Int64(clamping: elapsedMilliseconds(
            later: blockTimestamp, earlier: anchorTimestamp
        ))
        let deviation = elapsed.subtractingReportingOverflow(scheduled)
        let driftMilliseconds = deviation.overflow
            ? (scheduled > 0 ? Int64.min : Int64.max)
            : deviation.partialValue

        // 16.16 fixed-point exponent. The drift is bounded first so the scaling
        // multiply cannot overflow: past this magnitude the target saturates
        // anyway, so the clamp changes no reachable result.
        let maximumDrift = Int64.max / Self.asertFixedPointOne
        let boundedDrift = min(max(driftMilliseconds, -maximumDrift), maximumDrift)
        let exponent = (boundedDrift * Self.asertFixedPointOne) / halfLifeMilliseconds

        // Arithmetic shift floors toward negative infinity, so `fraction` is
        // always the non-negative remainder and `doublings` carries the sign.
        let doublings = exponent >> Self.asertFixedPointBits
        let fraction = UInt64(exponent & (Self.asertFixedPointOne - 1))

        // Cubic approximation of 2^(fraction/65536) in 16.16, exact in integers.
        // The constants are chosen so the widest intermediate stays inside
        // UInt64; see the overflow note on `asertCubic*`.
        let cubic = Self.asertCubicA * fraction
            + Self.asertCubicB * fraction * fraction
            + Self.asertCubicC * fraction * fraction * fraction
            + Self.asertCubicRounding
        let factor = UInt64(Self.asertFixedPointOne) + (cubic >> 48)

        // target = anchorTarget * factor / 2^16, then shifted by the whole
        // doublings. Saturating at both ends: a target of zero rejects every
        // hash and a target above the maximum is not representable.
        var scaled = multiplyDividingSaturating(
            anchorTarget,
            by: UInt256(factor),
            over: UInt256(UInt64(Self.asertFixedPointOne))
        )
        // The shift is bounded by the width of the type rather than by the
        // drift. No 256-bit value survives 256 halvings, and none stays
        // representable through 256 doublings, so past that the answer is
        // already saturated -- and the drift feeding it is attacker-supplied,
        // so the iteration count must not be.
        if doublings > 0 {
            guard doublings < Self.asertMaximumDoublings else { return UInt256.max }
            let ceiling = UInt256.max / UInt256(2)
            for _ in 0..<doublings {
                guard scaled <= ceiling else { return UInt256.max }
                scaled = scaled * UInt256(2)
            }
        } else if doublings < 0 {
            guard -doublings < Self.asertMaximumDoublings else { return UInt256(1) }
            for _ in 0..<(-doublings) {
                scaled = scaled / UInt256(2)
                if scaled == .zero { return UInt256(1) }
            }
        }
        return scaled == .zero ? UInt256(1) : scaled
    }

    /// The half-life is not a new committed field on purpose: adding one would
    /// change this spec's CID, and a chain's genesis commits that CID, so the
    /// chain would lose its identity to a difficulty tweak. `retargetWindow`
    /// already states how much history informs difficulty, which is exactly the
    /// quantity a half-life expresses, so it is reused rather than duplicated.
    func halfLifeMilliseconds() -> Int64 {
        let product = retargetWindow.multipliedReportingOverflow(by: targetBlockTime)
        guard !product.overflow else { return Int64.max }
        return Int64(clamping: product.partialValue)
    }

    private static let asertFixedPointBits: Int64 = 16
    private static let asertFixedPointOne: Int64 = 1 << 16
    /// One more than the width of the target, so the shift saturates instead of
    /// iterating on an attacker-supplied count.
    private static let asertMaximumDoublings: Int64 = 256
    // 2^(x/65536) ~= 1 + ax + bx^2 + cx^3 in 16.16, with the sum taken at 2^48
    // and rounded. At the widest fraction (65535) the three terms total just
    // under UInt64.max, which is what fixes these particular constants.
    private static let asertCubicA: UInt64 = 195_766_423_245_049
    private static let asertCubicB: UInt64 = 971_821_376
    private static let asertCubicC: UInt64 = 5_127
    private static let asertCubicRounding: UInt64 = 1 << 47

    private func calculatePairTarget(previousTarget: UInt256, actualTime: UInt64) -> UInt256 {
        // Zero elapsed time is rejected at block validation (strictly increasing
        // timestamps), so this is unreachable in consensus; keep the target
        // unchanged for the degenerate direct-call case.
        guard actualTime > 0 else { return previousTarget }
        let actual = UInt256(actualTime)
        let target = UInt256(targetBlockTime)
        return multiplyDividingSaturating(previousTarget, by: actual, over: target)
    }

    func calculatePairTarget(previousTarget: UInt256, actualTime: Int64) -> UInt256 {
        guard actualTime > 0 else { return previousTarget }
        return calculatePairTarget(previousTarget: previousTarget, actualTime: UInt64(actualTime))
    }

    func calculateMinimumTarget(previousTarget: UInt256, blockTimestamp: Int64, previousTimestamp: Int64) -> UInt256 {
        calculatePairTarget(
            previousTarget: previousTarget,
            actualTime: elapsedMilliseconds(later: blockTimestamp, earlier: previousTimestamp)
        )
    }

    func calculateWindowedTarget(previousTarget: UInt256, ancestorTimestamps: [Int64]) -> UInt256 {
        let availableIntervals = max(0, ancestorTimestamps.count - 1)
        let intervalCount = retargetWindow < UInt64(availableIntervals)
            ? Int(retargetWindow)
            : availableIntervals
        guard intervalCount > 0 else {
            // No retarget interval can be computed (0 or 1 timestamp): keep the
            // previous difficulty unchanged.
            return previousTarget
        }

        var weightedActual = UInt256.zero
        var weightSum = UInt256.zero
        for index in 0..<intervalCount {
            let solveTime = elapsedMilliseconds(
                later: ancestorTimestamps[index],
                earlier: ancestorTimestamps[index + 1]
            )
            let weight = UInt256(UInt64(intervalCount - index))
            let solve = UInt256(solveTime)
            let weightedSolve = solve > UInt256.max / weight ? UInt256.max : solve * weight
            weightedActual = weightedActual > UInt256.max - weightedSolve ? UInt256.max : weightedActual + weightedSolve
            weightSum = weightSum > UInt256.max - weight ? UInt256.max : weightSum + weight
        }
        // Zero total solve time is unreachable in consensus (strictly
        // increasing timestamps make every interval at least 1 ms); keep the
        // previous difficulty unchanged for the degenerate direct-call case
        // rather than proposing an impossible zero target — mirroring the
        // `calculatePairTarget` guard, and independent of any clamp.
        guard weightedActual > UInt256.zero else { return previousTarget }
        let target = UInt256(targetBlockTime)
        let weightedTarget = target > UInt256.max / weightSum
            ? UInt256.max
            : target * weightSum
        // Integer floor of the representation, not a policy bound: a
        // proportional correction that rounds to zero would propose target 0,
        // which rejects every hash and bricks the chain. The smallest
        // representable difficulty is 1.
        let adjusted = max(
            UInt256(1),
            multiplyDividingSaturating(previousTarget, by: weightedActual, over: weightedTarget)
        )
        return clampTargetChange(previousTarget: previousTarget, proposed: adjusted)
    }

    /// Bound a single retarget step to at most `maxTargetChange`× in either
    /// direction so a miner cannot grind timestamps to swing difficulty by an
    /// unbounded factor in one window. The clamp exists only when the chain
    /// COMMITS a `maxTargetChange` — there is no protocol default; an
    /// uncommitted spec retargets with the unclamped proportional correction.
    /// Applied at the single retarget choke point so the block builder and
    /// admission validator agree on the clamped value. This clamp is the only
    /// bound: there is no absolute target floor.
    private func clampTargetChange(previousTarget: UInt256, proposed: UInt256) -> UInt256 {
        guard let committed = maxTargetChange, committed > 0 else { return proposed }
        let factor = UInt256(UInt64(committed))
        let upperBound = previousTarget > UInt256.max / factor ? UInt256.max : previousTarget * factor
        let lowerBound = previousTarget / factor
        return min(max(proposed, lowerBound), upperBound)
    }

    func validateTransactionCount(_ transactionCount: UInt64) -> Bool {
        return transactionCount <= maxNumberOfTransactionsPerBlock
    }

    func validateStateGrowth(_ stateGrowth: UInt64) -> Bool {
        return stateGrowth <= maxStateGrowth
    }

    func rewardRange(startBlock: UInt64, count: UInt64) -> [UInt64] {
        guard count > 0 else { return [] }

        var rewards: [UInt64] = []
        rewards.reserveCapacity(Int(count))

        for i in 0..<count {
            rewards.append(rewardAtBlock(startBlock + i))
        }

        return rewards
    }
}
