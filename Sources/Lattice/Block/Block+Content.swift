import ArrayTrie
import cashew

private func cachePolicyModules(
    _ policies: [WasmPolicyRef],
    fetcher: any Fetcher,
    storer: any Storer
) async throws {
    var moduleCIDs = Set<String>()
    for policy in policies where moduleCIDs.insert(policy.moduleCID).inserted {
        _ = try await WasmPolicyModuleHeader(rawCID: policy.moduleCID)
            .resolve(fetcher: fetcher, cache: storer)
    }
}

public extension Block {
    /// Cashew resolution policy for the content carried by this block.
    ///
    /// This intentionally resolves the block's own content package, not its
    /// transitive execution inputs. State roots, parent blocks, and child block
    /// values remain external Volume roots with independent validation and
    /// retention policies.
    static var contentResolutionPaths: ArrayTrie<ResolutionStrategy> {
        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set([SPEC_PROPERTY], value: .targeted)
        paths.set([TRANSACTIONS_PROPERTY], value: .recursive)
        return paths
    }

    /// The deterministic block-local state package required after the caller
    /// has retained its independent parent-chain roots. Post-state
    /// materialization is a transition output and remains a caller policy.
    static func validationPaths(transactionBodies: [TransactionBody]) -> ArrayTrie<ResolutionStrategy> {
        var paths = contentResolutionPaths
        paths.set([PREV_STATE_PROPERTY], value: .targeted)

        func setPrevStatePath(_ path: [String]) {
            paths.set([PREV_STATE_PROPERTY] + path, value: .targeted)
        }

        for body in transactionBodies {
            for action in body.accountActions {
                setPrevStatePath([ACCOUNT_STATE_PROPERTY, action.owner])
            }
            for signer in Set(body.signers) {
                setPrevStatePath([ACCOUNT_STATE_PROPERTY, AccountStateHeader.nonceTrackingKey(signer)])
            }
            for action in body.actions {
                setPrevStatePath([GENERAL_STATE_PROPERTY, action.key])
            }
            for action in body.depositActions {
                setPrevStatePath([DEPOSIT_STATE_PROPERTY, DepositKey(depositAction: action).description])
            }
            for action in body.withdrawalActions {
                setPrevStatePath([DEPOSIT_STATE_PROPERTY, DepositKey(withdrawalAction: action).description])
                if let directory = body.chainPath.last {
                    let receiptKey = ReceiptKey(withdrawalAction: action, directory: directory).description
                    paths.set([PARENT_STATE_PROPERTY, RECEIPT_STATE_PROPERTY, receiptKey], value: .targeted)
                }
            }
            for action in body.genesisActions {
                setPrevStatePath([GENESIS_STATE_PROPERTY, action.directory])
            }
            for action in body.receiptActions {
                setPrevStatePath([RECEIPT_STATE_PROPERTY, ReceiptKey(receiptAction: action).description])
                setPrevStatePath([ACCOUNT_STATE_PROPERTY, action.withdrawer])
                setPrevStatePath([ACCOUNT_STATE_PROPERTY, action.demander])
            }
        }

        return paths
    }
}

public extension VolumeImpl where NodeType == Block {
    /// Resolve the block content package:
    /// block internals, chain spec, and transaction trie + transaction bodies.
    /// This does not resolve state Volumes, parent/ancestor block Volumes, or
    /// the independently retained child-link trie and child block Volumes.
    func resolveBlockContent(fetcher: Fetcher) async throws -> Self {
        try await resolve(paths: Block.contentResolutionPaths, fetcher: fetcher)
    }

    /// `source:` overload of ``resolveBlockContent(fetcher:)``: resolve the same
    /// content package, but drive resolution from a batched cashew
    /// ``ContentSource`` instead of a per-CID ``Fetcher``. cashew wraps the
    /// source in a single ``CoalescingFetcher`` for the whole walk, so this is
    /// byte-identical to the `fetcher:` path — it runs the same resolution walk
    /// over the same `contentResolutionPaths` — while collapsing each concurrent
    /// wave of child fetches into one batched request.
    func resolveBlockContent(source: any ContentSource) async throws -> Self {
        try await resolve(paths: Block.contentResolutionPaths, source: source)
    }

    func storeBlockContent(storer: any Storer) async throws {
        try await store(paths: Block.contentResolutionPaths, storer: storer)
    }

    /// Store the block content, policy modules, and exactly the external state
    /// paths needed to validate it. Parent blocks remain independent roots that
    /// callers retain according to their own history policy. The resulting
    /// post-state is computed during validation; callers decide whether and how
    /// to persist that transition output. The block itself may be an unresolved
    /// CID; its content is loaded from `fetcher` before the validation plan is
    /// derived.
    func storeBlock(fetcher: any Fetcher, storer: any Storer) async throws {
        let content = try await resolveBlockContent(fetcher: fetcher)
        guard let block = content.node,
              let spec = block.spec.node,
              let transactionNode = block.transactions.node else {
            throw DataErrors.nodeNotAvailable
        }
        let transactions = try transactionNode.allKeysAndValues().values
        let transactionBodies = try transactions.map { transaction -> TransactionBody in
            guard let body = transaction.node?.body.node else {
                throw DataErrors.nodeNotAvailable
            }
            return body
        }
        try await cachePolicyModules(spec.wasmPolicies, fetcher: fetcher, storer: storer)
        if block.height == 0 {
            try await LatticeState.emptyHeader.storeRecursively(storer: storer)
        }
        let paths = Block.validationPaths(transactionBodies: transactionBodies)
        let resolved = try await content.resolve(paths: paths, fetcher: fetcher, cache: storer)
        try await resolved.store(paths: paths, storer: storer)
    }

    /// Convenience for a combined fetcher/storer such as a local CAS.
    func storeBlock(storer: any Storer) async throws {
        guard let fetcher = storer as? any Fetcher else {
            throw DataErrors.nodeNotAvailable
        }
        try await storeBlock(fetcher: fetcher, storer: storer)
    }
}
