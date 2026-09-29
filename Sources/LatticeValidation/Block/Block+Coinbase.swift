import UInt256
import LatticePrimitives
import LatticePoW

/// Why a block's transactions and recipient admit no valid coinbase.
public enum CoinbaseError: Error, Sendable, Equatable {
    /// An account action fails `AccountAction.verify()`.
    case invalidAccountAction
    /// Credits plus deposits exceed debits plus withdrawals (C + P > D + W):
    /// the transactions create value, and the block reward no longer funds that.
    case feeRuleViolated
    /// `rewardRecipient` is not a canonical address.
    case invalidRecipient
    /// The miner amount does not fit an `AccountAction` (M > Int64.max).
    case amountOverflow
}

public extension Block {
    /// THE coinbase amount rule, shared by the validator and `BlockBuilder` so
    /// the two cannot drift. Over a non-genesis block's transaction actions:
    ///
    ///   fee rule:     C + P ≤ D + W
    ///   fees:         F = D + W − C − P
    ///   miner amount: M = R(h) + F
    ///
    /// C = account credits, D = account debits, W = amounts withdrawn,
    /// P = amounts deposited, R(h) = `spec.rewardAtBlock(h)`. Exact arithmetic
    /// (`WorkSum`), so no intermediate sum can wrap.
    static func coinbaseAmount(
        spec: ChainSpec,
        height: UInt64,
        accountActions: [AccountAction],
        depositActions: [DepositAction],
        withdrawalActions: [WithdrawalAction]
    ) -> Result<WorkSum, CoinbaseError> {
        var credits = WorkSum.zero
        var debits = WorkSum.zero
        for action in accountActions {
            guard action.verify() else { return .failure(.invalidAccountAction) }
            if action.isCredit { credits = credits + UInt256(action.absoluteAmount) }
            if action.isDebit { debits = debits + UInt256(action.absoluteAmount) }
        }
        let deposited = depositActions.reduce(WorkSum.zero) {
            $0 + UInt256($1.amountDeposited)
        }
        let withdrawn = withdrawalActions.reduce(WorkSum.zero) {
            $0 + UInt256($1.amountWithdrawn)
        }
        guard let fees = (debits + withdrawn).subtracting(credits + deposited) else {
            return .failure(.feeRuleViolated)
        }
        return .success(fees + UInt256(spec.rewardAtBlock(height)))
    }

    /// The synthetic credit a block with `recipient` must apply to its
    /// post-state: exactly M (see `coinbaseAmount`) to `recipient`. `nil`
    /// recipient burns M, and M == 0 credits nothing; both yield no action.
    /// The fee rule holds either way. A recipient must be a canonical address,
    /// and M must fit an `AccountAction` (≤ Int64.max), or the block is invalid.
    static func coinbaseCredit(
        spec: ChainSpec,
        height: UInt64,
        recipient: String?,
        accountActions: [AccountAction],
        depositActions: [DepositAction],
        withdrawalActions: [WithdrawalAction]
    ) -> Result<AccountAction?, CoinbaseError> {
        coinbaseAmount(
            spec: spec,
            height: height,
            accountActions: accountActions,
            depositActions: depositActions,
            withdrawalActions: withdrawalActions
        ).flatMap { amount in
            guard let recipient else { return .success(nil) }
            guard CryptoUtils.isValidAddress(recipient) else {
                return .failure(.invalidRecipient)
            }
            if amount == .zero { return .success(nil) }
            guard let value = amount.uint64Value, value <= UInt64(Int64.max) else {
                return .failure(.amountOverflow)
            }
            return .success(AccountAction(owner: recipient, delta: Int64(value)))
        }
    }
}
