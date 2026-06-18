import cashew
import CollectionConcurrencyKit
import Foundation

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

    public init(accountActions: [AccountAction], actions: [Action], depositActions: [DepositAction], genesisActions: [GenesisAction], receiptActions: [ReceiptAction], withdrawalActions: [WithdrawalAction], signers: [String], fee: UInt64, nonce: UInt64, chainPath: [String] = []) {
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

    public func valueConservation() -> (totalDebits: UInt64, totalCredits: UInt64, overflow: Bool, conserved: Bool) {
        var totalDebits: UInt64 = 0
        var totalCredits: UInt64 = 0
        for action in accountActions {
            if action.delta == Int64.min { return (totalDebits, totalCredits, true, false) }
            if action.delta < 0 {
                let (next, overflow) = totalDebits.addingReportingOverflow(UInt64(-action.delta))
                if overflow { return (totalDebits, totalCredits, true, false) }
                totalDebits = next
            } else if action.delta > 0 {
                let (next, overflow) = totalCredits.addingReportingOverflow(UInt64(action.delta))
                if overflow { return (totalDebits, totalCredits, true, false) }
                totalCredits = next
            }
        }

        var totalDeposited: UInt64 = 0
        for deposit in depositActions {
            let (next, overflow) = totalDeposited.addingReportingOverflow(deposit.amountDeposited)
            if overflow { return (totalDebits, totalCredits, true, false) }
            totalDeposited = next
        }

        var totalWithdrawn: UInt64 = 0
        for withdrawal in withdrawalActions {
            let (next, overflow) = totalWithdrawn.addingReportingOverflow(withdrawal.amountWithdrawn)
            if overflow { return (totalDebits, totalCredits, true, false) }
            totalWithdrawn = next
        }

        let (lhs, lhsOverflow) = totalDebits.addingReportingOverflow(totalWithdrawn)
        let (creditsWithFee, feeOverflow) = totalCredits.addingReportingOverflow(fee)
        let (rhs, rhsOverflow) = creditsWithFee.addingReportingOverflow(totalDeposited)
        let overflow = lhsOverflow || feeOverflow || rhsOverflow
        return (totalDebits, totalCredits, overflow, !overflow && lhs == rhs)
    }

    func withdrawalsAreValid(directory: String, prevState: LatticeState, parentState: LatticeState, fetcher: Fetcher) async throws -> Bool {
        if withdrawalActions.isEmpty { return true }
        // Both proofs THROW (StateErrors.conflictingActions) on a missing or
        // mismatched deposit/receipt, so awaiting without throwing IS the
        // validation — the returned proof headers are intentionally discarded.
        // (The authoritative enforcement of deposit existence + amount is the
        // post-state transition, DepositState.proveAndDeleteForWithdrawals.)
        async let proofOfDeposits = prevState.depositState.proveExistenceOfCorrespondingDeposit(withdrawalActions: withdrawalActions, fetcher: fetcher)
        async let proofOfReceipts = parentState.receiptState.proveExistenceAndVerifyWithdrawers(directory: directory, withdrawalActions: withdrawalActions, fetcher: fetcher)
        let (_, _) = try await (proofOfDeposits, proofOfReceipts)
        return true
    }

    /// THE consensus shape rule for genesis actions: an anchor must name a
    /// non-empty directory and a non-empty genesis block CID. The parent only
    /// RECORDS the anchor (directory → genesis CID); the genesis block's CONTENT
    /// is validated by the child chain it belongs to (on sync), not here.
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
        for genesisAction in genesisActions {
            if genesisAction.directory.isEmpty { return false }
            if genesisAction.directory.contains(DIRECTORY_KEY_SEPARATOR) { return false }
            if genesisAction.blockCID.isEmpty { return false }
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

    /// THE consensus account-delta builder: the merged list of account deltas a
    /// transaction's actions imply, INCLUDING the receipt-implied transfer
    /// (withdrawer is debited `amountDemanded`, demander credited the same).
    /// This is the exact rule the state transition applies — consumed by
    /// `LatticeState.proveAndUpdateState` (block validation/building) and by
    /// node-side admission (mempool balance checks); one definition so the two
    /// cannot drift. Throws `StateErrors.balanceOverflow` for a receipt amount
    /// of 0 or exceeding `Int64.max`.
    public static func netAccountDeltas(accountActions: [AccountAction], receiptActions: [ReceiptAction]) throws -> [AccountAction] {
        var mergedAccountActions = accountActions
        for receipt in receiptActions {
            guard receipt.amountDemanded > 0 && receipt.amountDemanded <= UInt64(Int64.max) else {
                throw StateErrors.balanceOverflow
            }
            mergedAccountActions.append(AccountAction(owner: receipt.withdrawer, delta: -Int64(receipt.amountDemanded)))
            mergedAccountActions.append(AccountAction(owner: receipt.demander, delta: Int64(receipt.amountDemanded)))
        }
        return mergedAccountActions
    }

    /// Per-transaction convenience over the static rule above.
    public func netAccountDeltas(includeReceiptTransfers: Bool = true) throws -> [AccountAction] {
        try Self.netAccountDeltas(
            accountActions: accountActions,
            receiptActions: includeReceiptTransfers ? receiptActions : []
        )
    }

    /// Per-owner NET balance delta for this body: the explicit `accountActions`
    /// plus the receipt-implied transfers (`netAccountDeltas`), aggregated by
    /// owner. Negative = the owner must fund that amount. This is the single
    /// source of net-debit arithmetic, shared by the consensus balance check and
    /// node admission so the two cannot drift. Throws `StateErrors.balanceOverflow`
    /// on the arithmetic-overflow / `Int64.min` cases a caller must reject
    /// (propagating `netAccountDeltas`' own overflow throw).
    public func netBalanceDeltas() throws -> [String: Int64] {
        let merged = try netAccountDeltas()
        // The receipt-implied transfers are appended AFTER the explicit actions.
        let receiptImpliedStart = accountActions.count
        var netDelta: [String: Int64] = [:]
        for (index, action) in merged.enumerated() {
            if action.delta == Int64.min { continue }
            let (sum, overflow) = netDelta[action.owner, default: 0].addingReportingOverflow(action.delta)
            if overflow { throw StateErrors.balanceOverflow }
            // A receipt-debit sum of Int64.min is not an overflow per
            // addingReportingOverflow but -Int64.min would trap downstream. No
            // account can hold 2^63 tokens, so treat it as a reject.
            if index >= receiptImpliedStart, sum == Int64.min { throw StateErrors.balanceOverflow }
            netDelta[action.owner] = sum
        }
        return netDelta
    }

    /// Per-owner net OUTFLOW (non-negative magnitudes of the net-negative
    /// deltas) — `netBalanceDeltas` restricted to owners that must fund. Empty on
    /// the overflow cases `netBalanceDeltas` rejects.
    public func netOutflows() -> [String: UInt64] {
        guard let netDelta = try? netBalanceDeltas() else { return [:] }
        var outflows: [String: UInt64] = [:]
        for (owner, delta) in netDelta where delta < 0 {
            // -Int64.min would trap; its magnitude 2^63 is representable in UInt64.
            outflows[owner] = delta == Int64.min ? UInt64(Int64.max) + 1 : UInt64(-delta)
        }
        return outflows
    }

    /// Funds `owner` must afford for this body alone, as a non-negative outflow.
    /// Returns 0 when the owner's net position is non-negative or on the overflow
    /// cases `netBalanceDeltas` rejects.
    public func netOutflow(of owner: String) -> UInt64 {
        guard !owner.isEmpty else { return 0 }
        return netOutflows()[owner] ?? 0
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
    ) async -> Bool {
        let policies = scopes.map { allowedScopes in
            spec.wasmPolicies.filter { allowedScopes.contains($0.scope) }
        } ?? spec.wasmPolicies
        guard !policies.isEmpty else { return true }

        var moduleBytesByCID: [String: Data] = [:]
        for policy in policies {
            guard policy.abiVersion == WasmPolicyRef.currentABIVersion else { return false }
            if moduleBytesByCID[policy.moduleCID] == nil {
                let moduleHeader = WasmPolicyModuleHeader(rawCID: policy.moduleCID)
                guard let moduleNode = try? await moduleHeader.resolve(fetcher: fetcher).node else {
                    return false
                }
                moduleBytesByCID[policy.moduleCID] = moduleNode.bytes
            }
        }

        func evaluate(_ policy: WasmPolicyRef, _ context: WasmPolicyContext) -> Bool {
            guard let moduleBytes = moduleBytesByCID[policy.moduleCID],
                  let contextData = try? context.canonicalData() else {
                return false
            }
            return (try? WasmPolicyEvaluator.evaluate(policy: policy, contextData: contextData, moduleBytes: moduleBytes)) == true
        }

        for policy in policies {
            switch policy.scope {
            case .transaction:
                for body in bodies {
                    let context = WasmPolicyContext(
                        scope: .transaction, chainSpec: spec, chainPath: chainPath,
                        transaction: body, action: nil, actionIndex: nil
                    )
                    guard evaluate(policy, context) else { return false }
                }
            case .action:
                for body in bodies {
                    for (actionIndex, action) in body.actions.enumerated() {
                        let context = WasmPolicyContext(
                            scope: .action, chainSpec: spec, chainPath: chainPath,
                            transaction: body, action: action, actionIndex: actionIndex
                        )
                        guard evaluate(policy, context) else { return false }
                    }
                }
            }
        }
        return true
    }
}
