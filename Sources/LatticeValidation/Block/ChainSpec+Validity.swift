import LatticePrimitives

public extension ChainSpec {
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
               halfLife > 0
    }

    func validateTransactionCount(_ transactionCount: UInt64) -> Bool {
        return transactionCount <= maxNumberOfTransactionsPerBlock
    }

    func validateStateGrowth(_ stateGrowth: UInt64) -> Bool {
        return stateGrowth <= maxStateGrowth
    }
}
