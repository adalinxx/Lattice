import cashew
import CollectionConcurrencyKit
import Foundation
import UInt256

public enum AccountBalanceDelta: Sendable, Equatable {
    case credit(UInt64)
    case debit(UInt64)

    public var outflow: UInt64 {
        if case .debit(let amount) = self { return amount }
        return 0
    }
}

public struct TransactionBody: Scalar {
    public let accountActions: [AccountAction]
    public let actions: [Action]
    public let depositActions: [DepositAction]
    public let genesisActions: [GenesisAction]
    public let receiptActions: [ReceiptAction]
    public let withdrawalActions: [WithdrawalAction]
    public let signers: [String]
    public let fee: UInt64
    public let nonce: UInt64
    public let chainPath: [String]

    public init(accountActions: [AccountAction], actions: [Action], depositActions: [DepositAction], genesisActions: [GenesisAction], receiptActions: [ReceiptAction], withdrawalActions: [WithdrawalAction], signers: [String], fee: UInt64, nonce: UInt64, chainPath: [String]) {
        self.accountActions = accountActions
        self.actions = actions
        self.depositActions = depositActions
        self.genesisActions = genesisActions
        self.receiptActions = receiptActions
        self.withdrawalActions = withdrawalActions
        self.signers = signers
        self.fee = fee
        self.nonce = nonce
        self.chainPath = chainPath
    }

    /// THE consensus shape rule for deposit actions (non-zero amounts, demander
    /// must sign). Consumed by block validation (validateTransaction*) and by
    /// node-side admission (mempool) — one definition so the two cannot drift.
    public func depositActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for depositAction in depositActions {
            if depositAction.amountDeposited == 0 { return false }
            if depositAction.amountDemanded == 0 { return false }
            if !signerSet.contains(depositAction.demander) { return false }
        }
        return true
    }

    /// THE consensus shape rule for receipt actions (non-zero amount, the
    /// debited withdrawer must sign). Consumed by block validation and by
    /// node-side admission — one definition so the two cannot drift.
    public func receiptActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for receipt in receiptActions {
            if receipt.amountDemanded == 0 { return false }
            if !signerSet.contains(receipt.withdrawer) { return false }
        }
        return true
    }

    /// THE consensus shape rule for withdrawal actions (non-zero amounts, the
    /// withdrawer must sign). Consumed by block validation and by node-side
    /// admission — one definition so the two cannot drift.
    public func withdrawalActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for withdrawalAction in withdrawalActions {
            if withdrawalAction.amountWithdrawn == 0 { return false }
            if withdrawalAction.amountDemanded == 0 { return false }
            if !signerSet.contains(withdrawalAction.withdrawer) { return false }
        }
        return true
    }

    public func valueConservation() -> (totalDebits: WorkSum, totalCredits: WorkSum, overflow: Bool, conserved: Bool) {
        var totalDebits = WorkSum.zero
        var totalCredits = WorkSum.zero
        for action in accountActions {
            guard action.verify() else { return (totalDebits, totalCredits, true, false) }
            if action.isDebit { totalDebits = totalDebits + UInt256(action.absoluteAmount) }
            if action.isCredit { totalCredits = totalCredits + UInt256(action.absoluteAmount) }
        }

        let totalDeposited = depositActions.reduce(WorkSum.zero) {
            $0 + UInt256($1.amountDeposited)
        }
        let totalWithdrawn = withdrawalActions.reduce(WorkSum.zero) {
            $0 + UInt256($1.amountWithdrawn)
        }
        let lhs = totalDebits + totalWithdrawn
        let rhs = totalCredits + UInt256(fee) + totalDeposited
        return (totalDebits, totalCredits, false, lhs == rhs)
    }

    func withdrawalsAreValid(directory: String, prevState: LatticeState, parentState: LatticeState, fetcher: Fetcher) async throws -> Bool {
        if withdrawalActions.isEmpty { return true }
        // Both proofs THROW (StateErrors.conflictingActions) on a missing or
        // mismatched deposit/receipt, so awaiting without throwing IS the
        // validation — the returned proof headers are intentionally discarded.
        // (The authoritative enforcement of deposit existence + amount is the
        // post-state transition, DepositState.proveAndSpendForWithdrawals.)
        async let proofOfDeposits = prevState.depositState.proveExistenceOfCorrespondingDeposit(withdrawalActions: withdrawalActions, fetcher: fetcher)
        async let proofOfReceipts = parentState.receiptState.proveExistenceAndVerifyWithdrawers(directory: directory, withdrawalActions: withdrawalActions, fetcher: fetcher)
        let (_, _) = try await (proofOfDeposits, proofOfReceipts)
        return true
    }

    /// THE consensus shape rule for genesis actions: an anchor must fit the
    /// child-proof wire format and name a canonical genesis block CID. The
    /// parent only RECORDS the anchor (directory → genesis CID); the genesis
    /// block's CONTENT is validated by its child chain during admission.
    /// Consumed by block validation and by node-side admission — one definition
    /// so the two cannot drift.
    ///
    /// The directory must not contain DIRECTORY_KEY_SEPARATOR ("/"): a chain's
    /// directory is a free-text field of the `/`-separated `ReceiptKey`, so a
    /// directory containing the separator would break receipt-key injectivity
    /// (distinct (directory, demander) pairs encoding to the same key), letting a
    /// withdrawal settle against the wrong chain's receipt. Rejecting it here —
    /// the single consensus entry point for new directory names — keeps every
    /// directory in any chainPath separator-free.
    public func genesisActionsAreValid() -> Bool {
        if !genesisActions.isEmpty,
           chainPath.count > ChildProofWireLimits.maximumDepth {
            return false
        }
        for genesisAction in genesisActions {
            if genesisAction.directory.isEmpty { return false }
            if genesisAction.directory.contains(DIRECTORY_KEY_SEPARATOR) { return false }
            if genesisAction.directory.utf8.count > ChildProofWireLimits.maximumDirectoryBytes {
                return false
            }
            if !CIDIdentity.isCanonical(genesisAction.blockCID) { return false }
        }
        return true
    }

    /// THE consensus shape rule for account actions (every debited owner must
    /// sign; every action self-verifies). Consumed by block validation and by
    /// node-side admission — one definition so the two cannot drift.
    public func accountActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for action in accountActions where action.isDebit {
            if !signerSet.contains(action.owner) { return false }
        }
        for action in accountActions {
            if !action.verify() { return false }
        }
        return true
    }

    /// Aggregate all balance effects before touching state. Exact unsigned
    /// totals make the result independent of transaction ordering.
    public static func netBalanceDeltas(
        accountActions: [AccountAction],
        receiptActions: [ReceiptAction]
    ) throws -> [String: AccountBalanceDelta] {
        var totals: [String: (credits: WorkSum, debits: WorkSum)] = [:]

        func add(_ amount: UInt64, owner: String, credit: Bool) {
            var total = totals[owner] ?? (.zero, .zero)
            if credit {
                total.credits = total.credits + UInt256(amount)
            } else {
                total.debits = total.debits + UInt256(amount)
            }
            totals[owner] = total
        }

        for action in accountActions {
            guard action.verify() else { throw StateErrors.balanceOverflow }
            add(action.absoluteAmount, owner: action.owner, credit: action.isCredit)
        }
        for receipt in receiptActions {
            guard receipt.amountDemanded > 0 else { throw StateErrors.balanceOverflow }
            add(receipt.amountDemanded, owner: receipt.withdrawer, credit: false)
            add(receipt.amountDemanded, owner: receipt.demander, credit: true)
        }

        var result: [String: AccountBalanceDelta] = [:]
        for (owner, total) in totals where total.credits != total.debits {
            if total.credits > total.debits {
                guard let amount = total.credits.subtracting(total.debits)?.uint64Value else {
                    throw StateErrors.balanceOverflow
                }
                result[owner] = .credit(amount)
            } else {
                guard let amount = total.debits.subtracting(total.credits)?.uint64Value else {
                    throw StateErrors.balanceOverflow
                }
                result[owner] = .debit(amount)
            }
        }
        return result
    }

    public func netBalanceDeltas() throws -> [String: AccountBalanceDelta] {
        try Self.netBalanceDeltas(
            accountActions: accountActions,
            receiptActions: receiptActions
        )
    }

    /// Per-owner net OUTFLOW (non-negative magnitudes of the net-negative
    /// deltas) — `netBalanceDeltas` restricted to owners that must fund.
    public func netOutflows() throws -> [String: UInt64] {
        let netDelta = try netBalanceDeltas()
        var outflows: [String: UInt64] = [:]
        for (owner, delta) in netDelta where delta.outflow > 0 {
            outflows[owner] = delta.outflow
        }
        return outflows
    }

    /// Funds `owner` must afford for this body alone, as a non-negative outflow.
    /// Returns 0 when the owner's net position is non-negative.
    public func netOutflow(of owner: String) throws -> UInt64 {
        guard !owner.isEmpty else { return 0 }
        return try netOutflows()[owner] ?? 0
    }

    func actionsAreValid() -> Bool {
        for action in actions {
            if !action.verify() { return false }
        }
        return true
    }

    func getStateDelta() throws -> Int {
        var delta = 0
        for a in accountActions { delta += a.stateDelta() }
        for a in actions { delta += a.stateDelta() }
        for a in depositActions { delta += a.stateDelta() }
        for a in genesisActions { delta += a.stateDelta() }
        for a in receiptActions { delta += a.stateDelta() }
        for a in withdrawalActions { delta += a.stateDelta() }
        return delta
    }

    public static func batchVerifyPolicies(
        bodies: [TransactionBody],
        spec: ChainSpec,
        chainPath: [String],
        fetcher: Fetcher,
        scopes: Set<WasmPolicyRef.Scope>? = nil
    ) async throws -> Bool {
        guard chainPath.first == DEFAULT_ROOT_DIRECTORY else { return false }
        let policies = scopes.map { allowedScopes in
            spec.wasmPolicies.filter { allowedScopes.contains($0.scope) }
        } ?? spec.wasmPolicies
        guard !policies.isEmpty else { return true }

        var moduleBytesByCID: [String: Data] = [:]
        for policy in policies {
            guard policy.abiVersion == WasmPolicyRef.currentABIVersion else { return false }
            if moduleBytesByCID[policy.moduleCID] == nil {
                let moduleHeader = WasmPolicyModuleHeader(rawCID: policy.moduleCID)
                let moduleNode: WasmPolicyModule
                do {
                    guard let resolved = try await moduleHeader.resolve(fetcher: fetcher).node else {
                        throw WasmPolicyError.missingModule(policy.moduleCID)
                    }
                    moduleNode = resolved
                } catch is FetcherError {
                    throw WasmPolicyError.missingModule(policy.moduleCID)
                }
                moduleBytesByCID[policy.moduleCID] = moduleNode.bytes
            }
        }

        func evaluate(_ policy: WasmPolicyRef, _ context: WasmPolicyContext) throws -> Bool {
            guard let moduleBytes = moduleBytesByCID[policy.moduleCID] else {
                throw WasmPolicyError.missingModule(policy.moduleCID)
            }
            return try WasmPolicyEvaluator.evaluate(
                policy: policy,
                contextData: context.canonicalData(),
                moduleBytes: moduleBytes
            )
        }

        for policy in policies {
            switch policy.scope {
            case .transaction:
                for body in bodies {
                    let context = WasmPolicyContext(
                        scope: .transaction, chainSpec: spec, chainPath: chainPath,
                        transaction: body, action: nil, actionIndex: nil
                    )
                    guard try evaluate(policy, context) else { return false }
                }
            case .action:
                for body in bodies {
                    for (actionIndex, action) in body.actions.enumerated() {
                        let context = WasmPolicyContext(
                            scope: .action, chainSpec: spec, chainPath: chainPath,
                            transaction: body, action: action, actionIndex: actionIndex
                        )
                        guard try evaluate(policy, context) else { return false }
                    }
                }
            }
        }
        return true
    }
}
