import ArrayTrie
import cashew

private func resolvePolicyModules(
    _ policies: [WasmPolicyRef],
    fetcher: any Fetcher
) async throws -> [WasmPolicyModuleHeader] {
    var moduleCIDs = Set<String>()
    var modules: [WasmPolicyModuleHeader] = []
    for policy in policies where moduleCIDs.insert(policy.moduleCID).inserted {
        modules.append(try await WasmPolicyModuleHeader(rawCID: policy.moduleCID)
            .resolve(fetcher: fetcher))
    }
    return modules
}

private func makeValidationPaths<Value>(
    transactionBodies: [TransactionBody],
    targeted: Value,
    recursive: Value,
    blockBoundary: Value?
) -> ArrayTrie<Value> {
    var paths = ArrayTrie<Value>()
    paths.set([SPEC_PROPERTY], value: targeted)
    paths.set([TRANSACTIONS_PROPERTY], value: recursive)
    paths.set([PREV_STATE_PROPERTY], value: targeted)
    if let blockBoundary {
        paths.set([CHILDREN_PROPERTY, ""], value: blockBoundary)
    }

    func setPrevStatePath(_ path: [String]) {
        paths.set([PREV_STATE_PROPERTY] + path, value: targeted)
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
                paths.set([PARENT_STATE_PROPERTY, RECEIPT_STATE_PROPERTY, receiptKey], value: targeted)
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

    /// The deterministic block-local package required after the caller has
    /// retained its independent parent-chain roots. `.list` materializes the
    /// child index that belongs to the block's own Volume boundary without
    /// resolving child block Volumes. Post-state remains caller policy.
    static func validationPaths(transactionBodies: [TransactionBody]) -> ArrayTrie<ResolutionStrategy> {
        makeValidationPaths(
            transactionBodies: transactionBodies,
            targeted: ResolutionStrategy.targeted,
            recursive: ResolutionStrategy.recursive,
            blockBoundary: ResolutionStrategy.list
        )
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

    /// Store the complete block Volume and exactly the nested Volumes needed to
    /// validate it. Policy modules are independent Volumes; parent blocks and
    /// post-state remain independent roots with caller-owned retention policy.
    func storeBlock(fetcher: any Fetcher, storer: any VolumeStorer) async throws {
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
        let policyModules = try await resolvePolicyModules(spec.wasmPolicies, fetcher: fetcher)
        let resolutionPaths = Block.validationPaths(transactionBodies: transactionBodies)
        let resolved = try await content.resolve(paths: resolutionPaths, fetcher: fetcher)
        let storagePaths = makeValidationPaths(
            transactionBodies: transactionBodies,
            targeted: StorageStrategy.targeted,
            recursive: StorageStrategy.recursive,
            blockBoundary: nil
        )
        try await resolved.store(paths: storagePaths, storer: storer)
        for module in policyModules {
            try await module.store(storer: storer)
        }
        if block.height == 0 {
            try await LatticeState.emptyHeader.storeRecursively(storer: storer)
        }
    }

    /// Convenience for a combined fetcher/Volume storer.
    func storeBlock(storer: any VolumeStorer) async throws {
        guard let fetcher = storer as? any Fetcher else {
            throw DataErrors.nodeNotAvailable
        }
        try await storeBlock(fetcher: fetcher, storer: storer)
    }
}
