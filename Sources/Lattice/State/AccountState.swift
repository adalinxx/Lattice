import cashew

public typealias AccountState = VolumeMerkleDictionaryImpl<UInt64>
public typealias AccountStateHeader = VolumeImpl<AccountState>

public extension AccountStateHeader {
    /// Aggregate deltas per owner, resolve current balances, apply net changes.
    /// Also advances per-signer nonce tracking via `_nonce_<prefix>` keys in
    /// the same trie (Ethereum-style per-account nonce).
    func proveAndUpdateState(
        allAccountActions: [AccountAction],
        transactionBodies: [TransactionBody] = [],
        fetcher: Fetcher
    ) async throws -> (AccountStateHeader, StateDiff) {
        // Aggregate deltas per owner (preserve insertion order)
        var ownerOrder: [String] = []
        var netDeltas: [String: Int64] = [:]
        for action in allAccountActions {
            if netDeltas[action.owner] == nil {
                ownerOrder.append(action.owner)
            }
            let (sum, overflow) = netDeltas[action.owner, default: 0].addingReportingOverflow(action.delta)
            guard !overflow else { throw StateErrors.balanceOverflow }
            netDeltas[action.owner] = sum
        }
        ownerOrder.removeAll { netDeltas[$0] == 0 }
        for key in netDeltas.keys where netDeltas[key] == 0 {
            netDeltas.removeValue(forKey: key)
        }

        // Group transactions by signer account, validate each signer's contiguous
        // nonce sequence independently. Multi-signer transactions advance every
        // signer, not a synthetic signer-set namespace.
        var signerOrder: [String] = []
        var groups: [String: [TransactionBody]] = [:]
        for tx in transactionBodies {
            for signer in Set(tx.signers).sorted() {
                guard !Self.isReservedAccountKey(signer) else { throw StateErrors.conflictingActions }
                if groups[signer] == nil { signerOrder.append(signer) }
                groups[signer, default: []].append(tx)
            }
        }
        for signer in signerOrder {
            groups[signer]!.sort { $0.nonce < $1.nonce }
            let sorted = groups[signer]!
            for i in 1..<sorted.count {
                if sorted[i].nonce != sorted[i - 1].nonce + 1 {
                    throw StateErrors.nonceGap
                }
            }
        }

        if netDeltas.isEmpty && signerOrder.isEmpty { return (self, .empty) }

        // Resolve targeted paths to read current balances + current nonces
        var resolvePaths = [[String]: ResolutionStrategy]()
        for owner in ownerOrder {
            guard !Self.isReservedAccountKey(owner) else { throw StateErrors.conflictingActions }
            resolvePaths[[owner]] = .targeted
        }
        for signer in signerOrder {
            resolvePaths[[Self.nonceTrackingKey(signer)]] = .targeted
        }
        let resolved = try await resolve(paths: resolvePaths, fetcher: fetcher)

        var proofs = [[String]: SparseMerkleProof]()
        var transforms = [[String]: Transform]()

        for owner in ownerOrder {
            let delta = netDeltas[owner]!
            let current: UInt64 = resolved.node.flatMap({ try? $0.get(key: owner) }) ?? 0

            let newBalance: UInt64
            if delta < 0 {
                // SEC-601 (belt-and-suspenders): -Int64.min overflows; throw rather than trap.
                guard delta > Int64.min else { throw StateErrors.balanceOverflow }
                let debit = UInt64(-delta)
                guard current >= debit else { throw StateErrors.insufficientBalance }
                newBalance = current - debit
            } else {
                let (result, overflow) = current.addingReportingOverflow(UInt64(delta))
                guard !overflow else { throw StateErrors.balanceOverflow }
                newBalance = result
            }

            if current == 0 && newBalance > 0 {
                proofs[[owner]] = .insertion
                transforms[[owner]] = .insert(String(newBalance))
            } else if current > 0 && newBalance == 0 {
                proofs[[owner]] = .deletion
                transforms[[owner]] = .delete
            } else if current > 0 && newBalance > 0 {
                proofs[[owner]] = .mutation
                transforms[[owner]] = .update(String(newBalance))
            }
            // current == 0 && newBalance == 0 → no-op
        }

        for signer in signerOrder {
            // groups[signer]! and sorted.first!/.last! are safe: signerOrder only
            // gains a signer when `groups[signer] == nil` and at least one tx is
            // appended in the same loop above, so every entry is present and non-empty.
            let sorted = groups[signer]!
            let nonceKey = Self.nonceTrackingKey(signer)
            let currentNonce: UInt64? = resolved.node.flatMap { try? $0.get(key: nonceKey) }
            let expectedFirst: UInt64 = Self.nextExpectedNonce(afterStored: currentNonce)
            guard sorted.first!.nonce == expectedFirst else {
                throw StateErrors.nonceGap
            }
            let newNonce = sorted.last!.nonce
            if currentNonce != nil {
                proofs[[nonceKey]] = .mutation
                transforms[[nonceKey]] = .update(String(newNonce))
            } else {
                proofs[[nonceKey]] = .insertion
                transforms[[nonceKey]] = .insert(String(newNonce))
            }
        }

        if proofs.isEmpty { return (resolved, .empty) }

        let proven = try await resolved.proof(paths: proofs, fetcher: fetcher)
        guard let result = try proven.transform(transforms: transforms) else {
            throw TransformErrors.transformFailed("account state transform returned nil")
        }
        return (result, diffCIDs(old: proven, new: result))
    }

    /// THE consensus nonce floor rule: the nonce a signer's next transaction
    /// must carry, given the trie's stored nonce (`nil` — the account has never
    /// transacted — floors at 0; otherwise stored + 1). Consumed by the state
    /// transition's contiguity check in `proveAndUpdateState` and by node-side
    /// admission — one definition so the two cannot drift.
    static func nextExpectedNonce(afterStored currentNonce: UInt64?) -> UInt64 {
        (currentNonce ?? 0) + (currentNonce != nil ? 1 : 0)
    }

    /// Public read API over the floor rule: resolve `account`'s stored nonce
    /// from this account-state trie and return the next expected nonce.
    func nextExpectedNonce(for account: String, fetcher: Fetcher) async throws -> UInt64 {
        let nonceKey = Self.nonceTrackingKey(account)
        let resolved = try await resolve(paths: [[nonceKey]: ResolutionStrategy.targeted], fetcher: fetcher)
        let currentNonce: UInt64? = resolved.node.flatMap { try? $0.get(key: nonceKey) }
        return Self.nextExpectedNonce(afterStored: currentNonce)
    }

    static let nonceKeyPrefix = "_nonce_"

    static func nonceTrackingKey(_ account: String) -> String {
        nonceKeyPrefix + account
    }

    static func isReservedAccountKey(_ key: String) -> Bool {
        key.hasPrefix(nonceKeyPrefix)
    }
}
