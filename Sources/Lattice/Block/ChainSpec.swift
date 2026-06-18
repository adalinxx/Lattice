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
    public static let maxTargetChange: UInt8 = 2
    // Zero-recovery fallback. If an adjustment round produces a zero target
    // (UInt256 division bottoming out from target=1 / 2), the chain would
    // be unmineable; we floor at 1 so the adjustment loop can recover.
    public static let minimumTarget: UInt256 = UInt256(1)

    /// R9 (wave-4): the minimum-target-floor recovery predicate — a block may
    /// present `target == minimumTarget` only when its parent's scheduled
    /// `nextTarget` fell below the floor (recovery from the zero-target bug).
    /// Single definition shared by `Block.validateNextTarget` and the
    /// deliberately-separate header-path validator
    /// (`ChainSyncer.validateHeaderConsensus`), so the duplicated clause cannot
    /// drift; semantics byte-identical to the previous two copies.
    static func isMinimumTargetRecovery(target: UInt256, parentNextTarget: UInt256) -> Bool {
        target == minimumTarget && parentNextTarget < minimumTarget
    }
    public let retargetWindow: UInt64
    public let wasmPolicies: [WasmPolicyRef]

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
        wasmPolicies: [WasmPolicyRef] = []
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
    }
}

// MARK: - Reward Calculations
public extension ChainSpec {

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
               ChainSpec.maxTargetChange > 0 &&
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

    func calculatePairTarget(previousTarget: UInt256, actualTime: Int64) -> UInt256 {
        guard actualTime > 0 else { return ChainSpec.minimumTarget }
        let actual = UInt256(UInt64(actualTime))
        let target = UInt256(targetBlockTime)
        let adjusted = multiplyDividingSaturating(previousTarget, by: actual, over: target)
        return max(adjusted, ChainSpec.minimumTarget)
    }

    func calculateMinimumTarget(previousTarget: UInt256, blockTimestamp: Int64, previousTimestamp: Int64) -> UInt256 {
        return calculatePairTarget(previousTarget: previousTarget, actualTime: blockTimestamp - previousTimestamp)
    }

    func calculateWindowedTarget(previousTarget: UInt256, ancestorTimestamps: [Int64]) -> UInt256 {
        let intervalCount = min(ancestorTimestamps.count - 1, Int(retargetWindow))
        guard intervalCount > 0 else {
            // No retarget interval can be computed (0 or 1 timestamp): keep the
            // previous difficulty, but still apply the minimumTarget floor so a
            // zero previousTarget cannot bypass the lower bound.
            return max(previousTarget, ChainSpec.minimumTarget)
        }

        var weightedActual = UInt256.zero
        var weightSum = UInt256.zero
        for index in 0..<intervalCount {
            let solveTime = max(Int64(0), ancestorTimestamps[index] - ancestorTimestamps[index + 1])
            let weight = UInt256(UInt64(intervalCount - index))
            let solve = UInt256(UInt64(solveTime))
            let weightedSolve = solve > UInt256.max / weight ? UInt256.max : solve * weight
            weightedActual = weightedActual > UInt256.max - weightedSolve ? UInt256.max : weightedActual + weightedSolve
            weightSum = weightSum + weight
        }
        // Zero total solve time = maximally-fast window = maximally harder.
        // Route it through the clamp (proposed 0 saturates to the lower bound)
        // rather than collapsing straight to minimumTarget, so a timestamp grind
        // cannot harden difficulty by more than maxTargetChange× in one step.
        let adjusted: UInt256
        if weightedActual > UInt256.zero {
            let weightedTarget = UInt256(targetBlockTime) * weightSum
            adjusted = multiplyDividingSaturating(previousTarget, by: weightedActual, over: weightedTarget)
        } else {
            adjusted = .zero
        }
        return clampTargetChange(previousTarget: previousTarget, proposed: adjusted)
    }

    /// Bound a single retarget step to at most `maxTargetChange`× in either
    /// direction so a miner cannot grind timestamps to swing difficulty by an
    /// unbounded factor in one window. The result is also floored at
    /// `minimumTarget`. Applied at the single retarget choke point so the block
    /// builder, validator, and syncer all agree on the clamped value.
    private func clampTargetChange(previousTarget: UInt256, proposed: UInt256) -> UInt256 {
        let factor = UInt256(UInt64(ChainSpec.maxTargetChange))
        let upperBound = previousTarget > UInt256.max / factor ? UInt256.max : previousTarget * factor
        let lowerBound = max(previousTarget / factor, ChainSpec.minimumTarget)
        let clamped = min(max(proposed, lowerBound), upperBound)
        return max(clamped, ChainSpec.minimumTarget)
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
