import cashew

public extension Block {
    /// Cashew resolution policy for the content carried by this block.
    /// State roots, parents, and child blocks remain independent Volumes.
    static var contentResolutionPaths: [[String]: ResolutionStrategy] {
        [
            [SPEC_PROPERTY]: .targeted,
            [TRANSACTIONS_PROPERTY]: .recursive,
        ]
    }

    /// Exact content needed to validate these transactions. The child index is
    /// listed without resolving its independently stored child block Volumes.
    static func validationPaths(
        transactionBodies: [TransactionBody]
    ) -> [[String]: ResolutionStrategy] {
        var paths = contentResolutionPaths
        paths[[PREV_STATE_PROPERTY]] = .targeted
        paths[[CHILDREN_PROPERTY, ""]] = .list

        func setPrevStatePath(_ path: [String]) {
            paths[[PREV_STATE_PROPERTY] + path] = .targeted
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
                    paths[[PARENT_STATE_PROPERTY, RECEIPT_STATE_PROPERTY, receiptKey]] = .targeted
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
        let resolutionPaths = Block.validationPaths(transactionBodies: transactionBodies)
        let resolved = try await content.resolve(paths: resolutionPaths, fetcher: fetcher)
        let storagePaths: [[String]: StorageStrategy] = resolutionPaths.compactMapValues {
            switch $0 {
            case .targeted: .targeted
            case .recursive: .recursive
            case .list, .range: nil
            }
        }
        try await resolved.store(paths: storagePaths, storer: storer)
        for moduleCID in Set(spec.wasmPolicies.map(\.moduleCID)).sorted() {
            try await WasmPolicyModuleHeader(rawCID: moduleCID)
                .resolve(fetcher: fetcher)
                .store(storer: storer)
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
