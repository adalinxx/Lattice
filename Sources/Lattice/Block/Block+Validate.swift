import Foundation
import Crypto
import cashew
import UInt256
import CollectionConcurrencyKit

// MARK: - State-trie key grammar (consensus)
//
// The grammar for every semantic atom used as a state-trie key, enforced on the
// block-validation path (`TransactionBody.stateAtomsAreValid` /
// `genesisActionsAreValid`, chain-path construction, account-state reads).
//
// There is intentionally NO length/count limit here — key size is a node
// storage concern, not a protocol rule. Two structural constraints remain, and
// neither is a "limit":
//   * Visible ASCII (0x21…0x7e): the state trie keys by Swift `String`, whose
//     Unicode canonical equivalence would otherwise let byte-distinct keys
//     collide and serialize nondeterministically across nodes. This dissolves
//     once cashew keys tries by raw bytes.
//   * No `DIRECTORY_KEY_SEPARATOR` ("/") in account/directory atoms: preserves
//     receipt-key injectivity across chains (a `/` would let a withdrawal settle
//     against the wrong chain's receipt).

func isDeterministicKeyAtom(_ value: String) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.allSatisfy { (0x21...0x7e).contains($0) }
}

func isValidAccountAtom(_ value: String) -> Bool {
    isDeterministicKeyAtom(value) && !value.contains(DIRECTORY_KEY_SEPARATOR)
}

func isValidDirectoryAtom(_ value: String) -> Bool {
    isDeterministicKeyAtom(value) && !value.contains(DIRECTORY_KEY_SEPARATOR)
}

func isValidGeneralAtom(_ value: String) -> Bool {
    isDeterministicKeyAtom(value)
}

/// A validation result whose truth may change only as the supplied wall-clock
/// context advances. It is deliberately separate from a permanent protocol
/// violation and from unavailable evidence.
public enum BlockValidationError: Error, Sendable, Equatable {
    case notYetAdmissible
}

public struct ValidationContext: Sendable, Equatable {
    public let nowMilliseconds: Int64

    public init(nowMilliseconds: Int64) {
        self.nowMilliseconds = nowMilliseconds
    }

    public static var current: ValidationContext {
        ValidationContext(nowMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000))
    }

    func admits(timestamp: Int64) -> Bool {
        let (latest, overflow) = nowMilliseconds.addingReportingOverflow(
            Block.maxFutureDriftMilliseconds
        )
        return overflow || timestamp <= latest
    }
}

public extension Block {
    private static let fieldSeparator: [UInt8] = [0x00]
    /// Shared consensus timestamp limits.
    /// Bounded future drift: a block timestamp may lead wall-clock by at most 2h.
    internal static let maxFutureDriftMilliseconds: Int64 = 2 * 60 * 60 * 1000
    /// MedianTimePast window depth (Bitcoin's MTP-11).
    internal static let mtpDepth: UInt64 = 11

    /// Canonical proof-of-work preimage *prefix*: every consensus field hashed
    /// before the nonce, terminated by the field separator that precedes the
    /// nonce. This is the single source of truth for the nonce-independent bytes,
    /// so optimized miners can hash it once into a midstate and append only the
    /// nonce per attempt (see / #135, where a hand-copy drifted by
    /// omitting `version`). Any change here is consensus-breaking.
    static func makeProofOfWorkPreimagePrefix(block: Block) -> Data {
        var data = Data()
        data.reserveCapacity(512)
        data.append(contentsOf: String(block.version).utf8)
        data.append(contentsOf: Block.fieldSeparator)
        if let parentCID = block.parent?.rawCID {
            data.append(contentsOf: parentCID.utf8)
        }
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.transactions.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.target.toHexString().utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.nextTarget.toHexString().utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.spec.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.parentState.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.prevState.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.postState.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.children.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: String(block.height).utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: String(block.timestamp).utf8)
        data.append(contentsOf: Block.fieldSeparator)
        return data
    }

    /// Fixed-width (8-byte, big-endian) encoding of the PoW nonce — the single
    /// source of truth for how the nonce is appended to the preimage. Fixed width
    /// keeps the total preimage length constant across every nonce, so the SHA-256
    /// padding and block count are identical for all attempts. That is what makes
    /// the per-nonce work divergence-free on a GPU and lets miners reuse a single
    /// prefix midstate (a variable-length ASCII-decimal nonce broke both). External
    /// miners MUST encode the nonce with this exact function. Consensus-breaking.
    static func proofOfWorkNonceBytes(_ nonce: UInt64) -> [UInt8] {
        withUnsafeBytes(of: nonce.bigEndian) { Array($0) }
    }

    /// Canonical proof-of-work preimage. This is the single source of truth for the
    /// bytes hashed during mining and PoW validation; downstream nodes/miners must
    /// reuse this rather than re-deriving it (see / #135, where a hand-copy
    /// drifted by omitting `version`). Any change here is consensus-breaking.
    static func makeProofOfWorkPreimage(block: Block, nonce: UInt64) -> Data {
        var data = makeProofOfWorkPreimagePrefix(block: block)
        data.append(contentsOf: proofOfWorkNonceBytes(nonce))
        return data
    }

    func proofOfWorkHash() -> UInt256 {
        let data = Block.makeProofOfWorkPreimage(block: self, nonce: nonce)
        return UInt256.hash(data)
    }

    func validateGenesis(
        fetcher: Fetcher,
        chainPath: [String],
        reportTemporalFailure: Bool = false,
        validationContext: ValidationContext = .current
    ) async throws -> (Bool, StateDiff) {
        let transition = try await validateGenesisTransition(
            fetcher: fetcher,
            chainPath: chainPath,
            reportTemporalFailure: reportTemporalFailure,
            validationContext: validationContext
        )
        return (transition.0, transition.1)
    }

    /// Internal genesis validation result for admission paths that must retain
    /// the verified post-state before exposing a consensus mutation.
    internal func validateGenesisTransition(
        fetcher: Fetcher,
        chainPath: [String],
        reportTemporalFailure: Bool = false,
        validationContext: ValidationContext
    ) async throws -> (Bool, StateDiff, LatticeState?) {
        if !hasGenesisAdmissionShape() { return (false, .empty, nil) }
        if !validationContext.admits(timestamp: timestamp) {
            if reportTemporalFailure { throw BlockValidationError.notYetAdmissible }
            return (false, .empty, nil)
        }
        guard let transactionBodies = try await resolveTransactionBodies(fetcher: fetcher, validator: { tx in
            try await tx.validateTransactionForGenesis(fetcher: fetcher)
        }) else { return (false, .empty, nil) }
        guard let specNode = try await spec.resolve(fetcher: fetcher).node else { return (false, .empty, nil) }
        guard specNode.isValid else { return (false, .empty, nil) }
        guard chainPath.first == DEFAULT_ROOT_DIRECTORY else {
            return (false, .empty, nil)
        }
        if !validateChainPaths(transactionBodies: transactionBodies, expectedPath: chainPath) {
            return (false, .empty, nil)
        }
        if !(try await TransactionBody.validateConfiguredPolicyModules(
            spec: specNode,
            fetcher: fetcher
        )) {
            return (false, .empty, nil)
        }
        if !(try await TransactionBody.batchVerifyPolicies(bodies: transactionBodies, spec: specNode, chainPath: chainPath, fetcher: fetcher)) { return (false, .empty, nil) }
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty, nil) }
        if try !validateStateDeltaSize(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty, nil) }
        if try await !validateBlockSize(spec: specNode, fetcher: fetcher) {
            return (false, .empty, nil)
        }
        let allAccountActions = transactionBodies.flatMap { $0.accountActions }
        // R4: the per-transaction gate above (validateTransactionForGenesis)
        // rejects any genesis transaction carrying deposit, withdrawal, or
        // receipt actions, so those lists are provably empty for every body
        // that reaches this point — pass empty literals instead of collecting.
        assert(transactionBodies.allSatisfy { $0.depositActions.isEmpty && $0.withdrawalActions.isEmpty && $0.receiptActions.isEmpty })
        if try !validateBalanceChangesForGenesis(spec: specNode, allAccountActions: allAccountActions) { return (false, .empty, nil) }
        if !validateGenesisTransactions(transactionBodies: transactionBodies) { return (false, .empty, nil) }
        let (postStateValid, diff, materializedPostState) = try await validatePostState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: transactionBodies.flatMap { $0.actions }, allDepositActions: [], allGenesisActions: transactionBodies.flatMap { $0.genesisActions }, allReceiptActions: [], allWithdrawalActions: [], fetcher: fetcher)
        if !postStateValid { return (false, .empty, nil) }
        return (true, diff, materializedPostState)
    }

    func collectAncestorTimestamps(
        parent: Block,
        count: UInt64,
        fetcher: Fetcher
    ) async throws -> [Int64]? {
        var timestamps: [Int64] = [parent.timestamp]
        var current = parent
        for _ in 1..<count {
            guard let parentRef = current.parent else { break }
            guard let prev = try await parentRef.resolve(fetcher: fetcher).node else { return nil }
            timestamps.append(prev.timestamp)
            current = prev
        }
        return timestamps
    }

    func validateTimestampAndNextTarget(
        spec: ChainSpec,
        parent: Block,
        fetcher: Fetcher,
        chain: ChainState? = nil,
        reportTemporalFailure: Bool = false,
        validationContext: ValidationContext
    ) async throws -> Bool {
        let walkDepth = max(spec.retargetWindow, Block.mtpDepth)
        let (parentDepth, overflow) = parent.height.addingReportingOverflow(1)
        guard !overflow else { return false }
        let requiredWalkDepth = min(walkDepth, parentDepth)
        let ancestorTimestamps: [Int64]
        if let chain,
           let parentHash = self.parent?.rawCID,
           let fast = await chain.getMainChainTimestamps(forParentHash: parentHash, count: walkDepth),
           requiredWalkDepth <= UInt64(fast.count) {
            ancestorTimestamps = fast
        } else {
            guard let walked = try await collectAncestorTimestamps(parent: parent, count: walkDepth, fetcher: fetcher),
                  requiredWalkDepth <= UInt64(walked.count) else {
                return false
            }
            ancestorTimestamps = walked
        }
        if !validationContext.admits(timestamp: timestamp) {
            if reportTemporalFailure { throw BlockValidationError.notYetAdmissible }
            return false
        }
        if !validateTimestamp(
            parent: parent,
            ancestorTimestamps: ancestorTimestamps,
            validationContext: validationContext
        ) { return false }
        if !validateNextTarget(spec: spec, parent: parent, ancestorTimestamps: ancestorTimestamps) { return false }
        return true
    }

    /// `source:` overload of ``validateNexus(fetcher:chain:chainPath:reportTemporalFailure:)``.
    /// Wraps the batched cashew ``ContentSource`` in a single
    /// ``CoalescingFetcher`` and delegates to the `fetcher:` version unchanged,
    /// so validation is byte-identical to the per-CID path. Threading one
    /// coalescer through the whole call collapses each concurrent wave of
    /// content fetches (transaction bodies, ancestor walk, state resolution)
    /// into batched requests without altering the validation logic.
    func validateNexus(
        source: any ContentSource,
        chain: ChainState? = nil,
        chainPath: [String]? = nil,
        reportTemporalFailure: Bool = false,
        validationContext: ValidationContext = .current
    ) async throws -> (Bool, StateDiff, LatticeState?) {
        try await validateNexus(
            fetcher: CoalescingFetcher(source),
            chain: chain,
            chainPath: chainPath,
            reportTemporalFailure: reportTemporalFailure,
            validationContext: validationContext
        )
    }

    /// Validate block structure: parent linkage, spec, height, timestamp,
    /// target, transaction signatures, balance changes, and genesis
    /// transactions, and post-state root. Returns the state diff and the
    /// materialized post-state produced by the validated transition.
    func validateNexus(
        fetcher: Fetcher,
        chain: ChainState? = nil,
        chainPath: [String]? = nil,
        reportTemporalFailure: Bool = false,
        validationContext: ValidationContext = .current
    ) async throws -> (Bool, StateDiff, LatticeState?) {
        let expectedChainPath = chainPath ?? [DEFAULT_ROOT_DIRECTORY]
        guard expectedChainPath.first == DEFAULT_ROOT_DIRECTORY else {
            return (false, .empty, nil)
        }
        if version != Block.currentVersion { return (false, .empty, nil) }
        async let parentFuture = parent?.resolve(fetcher: fetcher)
        async let specFuture = spec.resolve(fetcher: fetcher)
        guard let previousBlockNode = try await parentFuture?.node else { return (false, .empty, nil) }
        if !validateSpec(parent: previousBlockNode) { return (false, .empty, nil) }
        if !validateState(parent: previousBlockNode) { return (false, .empty, nil) }
        if !validateHeight(parent: previousBlockNode) { return (false, .empty, nil) }

        guard let specNode = try await specFuture.node else { return (false, .empty, nil) }

        // Start transaction body resolution concurrently
        // with the ancestor-timestamp walk. The transaction CAS fetches and the
        // ancestor CAS walk are completely independent — overlapping them eliminates
        // one sequential wait from the block validation critical path.
        let txResolveFetcher = fetcher
        async let txBodiesFuture: [TransactionBody]? = {
            let validator: @Sendable (Transaction) async throws -> Bool = { tx in
                try await tx.validateTransactionForNexus(fetcher: txResolveFetcher)
            }
            return try await resolveTransactionBodies(fetcher: txResolveFetcher, validator: validator)
        }()

        if !(try await validateTimestampAndNextTarget(
            spec: specNode,
            parent: previousBlockNode,
            fetcher: fetcher,
            chain: chain,
            reportTemporalFailure: reportTemporalFailure,
            validationContext: validationContext
        )) { return (false, .empty, nil) }

        guard let transactionBodies = try await txBodiesFuture else { return (false, .empty, nil) }

        // Directory is positional (the anchor context / chainPath), not in the
        // spec; nil chainPath ⇒ root.
        if !(try await TransactionBody.batchVerifyPolicies(bodies: transactionBodies, spec: specNode, chainPath: expectedChainPath, fetcher: fetcher)) { return (false, .empty, nil) }
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty, nil) }
        if try !validateStateDeltaSize(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty, nil) }
        if try await !validateBlockSize(spec: specNode, fetcher: fetcher) {
            return (false, .empty, nil)
        }
        if !validateChainPaths(transactionBodies: transactionBodies, expectedPath: expectedChainPath) { return (false, .empty, nil) }
        if !validateNoDepositsOrWithdrawalsOnRoot(transactionBodies: transactionBodies, expectedPath: expectedChainPath) { return (false, .empty, nil) }

        if try await !validateWithdrawals(
            transactionBodies: transactionBodies,
            fetcher: fetcher,
            chainPath: expectedChainPath
        ) { return (false, .empty, nil) }

        let allAccountActions = transactionBodies.flatMap { $0.accountActions }
        let allDepositActions = transactionBodies.flatMap { $0.depositActions }
        let allWithdrawalActions = transactionBodies.flatMap { $0.withdrawalActions }
        let allReceiptActions = transactionBodies.flatMap { $0.receiptActions }
        if try !validateBalanceChanges(
            spec: specNode,
            allDepositActions: allDepositActions,
            allWithdrawalActions: allWithdrawalActions,
            allAccountActions: allAccountActions
        ) { return (false, .empty, nil) }
        if !validateGenesisTransactions(transactionBodies: transactionBodies) { return (false, .empty, nil) }

        let (postStateValid, diff, materializedPostState) = try await validatePostState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: transactionBodies.flatMap { $0.actions }, allDepositActions: allDepositActions, allGenesisActions: transactionBodies.flatMap { $0.genesisActions }, allReceiptActions: allReceiptActions, allWithdrawalActions: allWithdrawalActions, fetcher: fetcher)
        if !postStateValid { return (false, .empty, nil) }
        return (true, diff, materializedPostState)
    }

    /// Preflight the state-dependent withdrawal rule used by full validation.
    /// Mining uses this to omit transactions that cannot settle against the
    /// exact entering parent state without repeating unrelated block checks.
    func validateWithdrawals(
        fetcher: Fetcher,
        chainPath: [String]
    ) async throws -> Bool {
        guard chainPath.first == DEFAULT_ROOT_DIRECTORY,
              let transactionBodies = try await resolveTransactionBodies(
                fetcher: fetcher,
                validator: { transaction in
                    try await transaction.validateTransactionForNexus(fetcher: fetcher)
                }
              ) else { return false }
        return try await validateWithdrawals(
            transactionBodies: transactionBodies,
            fetcher: fetcher,
            chainPath: chainPath
        )
    }

    private func validateWithdrawals(
        transactionBodies: [TransactionBody],
        fetcher: Fetcher,
        chainPath: [String]
    ) async throws -> Bool {
        let withdrawalBodies = transactionBodies.filter {
            !$0.withdrawalActions.isEmpty
        }
        guard !withdrawalBodies.isEmpty else { return true }
        guard chainPath.count > 1 else { return false }
        guard let directory = chainPath.last,
              TransactionBody.withdrawalsHaveUniqueReceiptKeys(
                bodies: withdrawalBodies,
                directory: directory
              ) else { return false }

        async let prevStateFuture = prevState.resolve(fetcher: fetcher)
        async let parentStateFuture = parentState.resolve(fetcher: fetcher)
        let (resolvedPrevState, resolvedParentState) = try await (
            prevStateFuture,
            parentStateFuture
        )
        guard let prevStateNode = resolvedPrevState.node,
              let parentStateNode = resolvedParentState.node else { return false }
        return try await !withdrawalBodies.concurrentMap {
            try await $0.withdrawalsAreValid(
                directory: directory,
                prevState: prevStateNode,
                parentState: parentStateNode,
                fetcher: fetcher
            )
        }.contains(false)
    }

    func validateProofOfWork(nexusHash: UInt256) -> Bool {
        return target >= nexusHash
    }

    func validatePostState(transactionBodies: [TransactionBody], fetcher: Fetcher) async throws -> (Bool, StateDiff, LatticeState?) {
        // Collect each action family in one pass.
        var allAccountActions: [AccountAction] = []
        var allActions: [Action] = []
        var allDepositActions: [DepositAction] = []
        var allGenesisActions: [GenesisAction] = []
        var allReceiptActions: [ReceiptAction] = []
        var allWithdrawalActions: [WithdrawalAction] = []
        for body in transactionBodies {
            allAccountActions.append(contentsOf: body.accountActions)
            allActions.append(contentsOf: body.actions)
            allDepositActions.append(contentsOf: body.depositActions)
            allGenesisActions.append(contentsOf: body.genesisActions)
            allReceiptActions.append(contentsOf: body.receiptActions)
            allWithdrawalActions.append(contentsOf: body.withdrawalActions)
        }
        return try await validatePostState(transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: allActions, allDepositActions: allDepositActions, allGenesisActions: allGenesisActions, allReceiptActions: allReceiptActions, allWithdrawalActions: allWithdrawalActions, fetcher: fetcher)
    }

    func validatePostState(transactionBodies: [TransactionBody], allAccountActions: [AccountAction], allActions: [Action], allDepositActions: [DepositAction], allGenesisActions: [GenesisAction], allReceiptActions: [ReceiptAction], allWithdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> (Bool, StateDiff, LatticeState?) {
        guard let prevStateNode = try await prevState.resolve(fetcher: fetcher).node else {
            return (false, .empty, nil)
        }
        let (updatedState, diff) = try await prevStateNode.proveAndUpdateState(allAccountActions: allAccountActions, allActions: allActions, allDepositActions: allDepositActions, allGenesisActions: allGenesisActions, allReceiptActions: allReceiptActions, allWithdrawalActions: allWithdrawalActions, transactionBodies: transactionBodies, fetcher: fetcher)
        // Compare the expected postState CID (computed from prev state + TXs) against the
        // block's declared postState CID. Avoids a CAS fetch for the new postState — the
        // new state nodes are computed inline and may not yet be stored to DiskBroker.
        let expectedPostStateCID = try LatticeStateHeader(node: updatedState).rawCID
        let postStateValid = expectedPostStateCID == postState.rawCID
        return (postStateValid, diff, postStateValid ? updatedState : nil)
    }

    func validateBalanceChanges(spec: ChainSpec, allDepositActions: [DepositAction], allWithdrawalActions: [WithdrawalAction], allAccountActions: [AccountAction]) throws -> Bool {
        let reward = spec.rewardAtBlock(height)
        let totalDeposited = allDepositActions.reduce(WorkSum.zero) {
            $0 + UInt256($1.amountDeposited)
        }
        let totalWithdrawn = allWithdrawalActions.reduce(WorkSum.zero) {
            $0 + UInt256($1.amountWithdrawn)
        }
        // Fees are not independent income: transaction validation requires
        // sender debits to include the fee, so block validation only gives
        // miners credit for fees when those debits are present in the same
        // action set.
        // totalCredits <= totalDebits + totalWithdrawn + reward - totalDeposited
        var totalCredits = WorkSum.zero
        var totalDebits = WorkSum.zero
        for action in allAccountActions {
            guard action.verify() else { return false }
            if action.isCredit { totalCredits = totalCredits + UInt256(action.absoluteAmount) }
            if action.isDebit { totalDebits = totalDebits + UInt256(action.absoluteAmount) }
        }
        let grossAvailable = totalDebits + UInt256(reward) + totalWithdrawn
        guard let available = grossAvailable.subtracting(totalDeposited) else { return false }
        return totalCredits <= available
    }

    func validateBalanceChangesForGenesis(spec: ChainSpec, allAccountActions: [AccountAction]) throws -> Bool {
        let premineAmount = spec.premineAmount()
        var totalCredits = WorkSum.zero
        for action in allAccountActions {
            guard action.verify() else { return false }
            if action.isCredit { totalCredits = totalCredits + UInt256(action.absoluteAmount) }
        }
        return totalCredits <= WorkSum(UInt256(premineAmount))
    }

    func validateSpec(parent: Block) -> Bool {
        return parent.spec.rawCID == spec.rawCID
    }

    func validateNextTarget(spec: ChainSpec, parent: Block, ancestorTimestamps: [Int64] = []) -> Bool {
        if target != parent.nextTarget &&
            !ChainSpec.isMinimumTargetRecovery(target: target, parentNextTarget: parent.nextTarget) {
            return false
        }
        // Accept the minimum target floor for chains recovering from a
        // zero-target bug (UInt256 division by 1 returned 0).
        if ChainSpec.isMinimumTargetRecovery(target: target, parentNextTarget: parent.nextTarget) {
            return nextTarget == target
        }
        let (parentDepth, overflow) = parent.height.addingReportingOverflow(1)
        guard !overflow else { return false }
        let requiredRetargetDepth = min(spec.retargetWindow, parentDepth)
        guard requiredRetargetDepth <= UInt64(ancestorTimestamps.count) else { return false }
        let windowTimestamps = [timestamp] + Array(ancestorTimestamps.prefix(Int(requiredRetargetDepth)))
        let expected = spec.calculateWindowedTarget(previousTarget: target, ancestorTimestamps: windowTimestamps)
        return nextTarget == expected
    }

    func validateState(parent: Block) -> Bool {
        return parent.postState.rawCID == prevState.rawCID
    }

    func validateHeight(parent: Block) -> Bool {
        let (expected, overflow) = parent.height.addingReportingOverflow(1)
        return !overflow && expected == height
    }

    /// Header-local rules shared by every path that can accept a genesis.
    func hasGenesisAdmissionShape() -> Bool {
        version == Block.currentVersion
            && parent == nil
            && height == 0
            && prevState.rawCID == LatticeState.emptyHeader.rawCID
            && target >= ChainSpec.minimumTarget
            && nextTarget == target
    }

    /// Bitcoin-style consensus rules:
    ///   (1) timestamp strictly greater than previous block
    ///   (2) timestamp ≤ now + 2h (bounded future drift — prevents warp
    ///       attacks that forward-shift timestamps to halve target)
    ///   (3) timestamp > MedianTimePast(11) (prevents grinding by predating)
    /// No lower-bound against wall-clock: old blocks must still validate for
    /// cold sync, so we only gate the future side against clock drift.
    func validateTimestamp(
        parent: Block,
        ancestorTimestamps: [Int64] = [],
        validationContext: ValidationContext = .current
    ) -> Bool {
        if parent.timestamp >= timestamp { return false }
        if !validationContext.admits(timestamp: timestamp) { return false }
        if !ancestorTimestamps.isEmpty {
            let sorted = ancestorTimestamps.prefix(Int(Block.mtpDepth)).sorted()
            let medianIndex = (sorted.count - 1) / 2
            let median = sorted[medianIndex]
            if timestamp <= median { return false }
        }
        return true
    }

    func validateStateDeltaSize(spec: ChainSpec, transactionBodies: [TransactionBody]) throws -> Bool {
        var delta = 0
        for body in transactionBodies {
            guard addStateDelta(try body.getStateDelta(), to: &delta) else {
                return false
            }
        }
        return delta <= spec.maxStateGrowth
    }

    func validateMaxTransactionCount(spec: ChainSpec, transactionBodies: [TransactionBody]) -> Bool {
        return transactionBodies.count <= spec.maxNumberOfTransactionsPerBlock
    }

    func validateBlockSize(
        spec: ChainSpec,
        fetcher: any Fetcher
    ) async throws -> Bool {
        do {
            return try await logicalContentByteSize(fetcher: fetcher)
                <= spec.maxBlockSize
        } catch is BlockContentSizeError {
            return false
        }
    }

    /// Deposits and withdrawals are cross-chain constructs: a deposit
    /// escrows value for withdrawal on the PARENT chain, and a withdrawal
    /// requires a receipt in the parent chain's state. The root chain
    /// (chainPath length 1) has no parent, so a deposit there burns value with
    /// no withdrawal path and a withdrawal there has no receipt to settle
    /// against. Consensus rejects both so a producer cannot place them directly
    /// in a root-chain block.
    func validateNoDepositsOrWithdrawalsOnRoot(transactionBodies: [TransactionBody], expectedPath: [String]) -> Bool {
        guard expectedPath.count == 1 else { return true }
        for body in transactionBodies {
            if !body.depositActions.isEmpty { return false }
            if !body.withdrawalActions.isEmpty { return false }
        }
        return true
    }

    func validateChainPaths(transactionBodies: [TransactionBody], expectedPath: [String]) -> Bool {
        for body in transactionBodies {
            // Empty chainPath is rejected: it would allow a single signed transaction
            // to be included in any chain simultaneously, enabling cross-chain double-spend.
            if body.chainPath.isEmpty { return false }
            if body.chainPath != expectedPath { return false }
        }
        return true
    }

    func resolveTransactionBodies(fetcher: Fetcher, validator: @escaping @Sendable (Transaction) async throws -> Bool) async throws -> [TransactionBody]? {
        guard let transactionsNode = try await transactions.resolveRecursive(fetcher: fetcher).node else { return nil }
        let txHeaders = try transactionsNode.allKeysAndValues().values
        if txHeaders.contains(where: { $0.node == nil }) { throw ValidationErrors.transactionNotResolved }
        let txs = txHeaders.map { $0.node! }
        if try await txs.concurrentMap({ try await validator($0) }).contains(false) { return nil }
        let transactionBodiesMaybe = txs.map { $0.body.node }
        if transactionBodiesMaybe.contains(where: { $0 == nil }) { throw ValidationErrors.transactionNotResolved }
        return transactionBodiesMaybe.map { $0! }
    }

    func validateGenesisTransactions(transactionBodies: [TransactionBody]) -> Bool {
        return !transactionBodies.contains { !$0.genesisActionsAreValid() }
    }

}
