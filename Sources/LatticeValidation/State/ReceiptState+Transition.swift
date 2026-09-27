import cashew

public extension ReceiptStateHeader {
    func proveExistenceAndVerifyWithdrawers(directory: String, withdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> ReceiptStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for withdrawalAction in withdrawalActions {
            let receiptKey = ReceiptKey(
                withdrawalAction: withdrawalAction,
                directory: directory
            )
            proofs[[receiptKey.storageKey]] = .mutation
        }
        let proven = try await proof(paths: proofs, fetcher: fetcher)
        guard let node = proven.node else { throw StateErrors.conflictingActions }
        for wa in withdrawalActions {
            let key = ReceiptKey(
                withdrawalAction: wa,
                directory: directory
            )
            guard let stored: String = try? node.get(key: key.storageKey) else {
                throw StateErrors.conflictingActions
            }
            if stored != wa.withdrawer { throw StateErrors.conflictingActions }
        }
        return proven
    }

    func proveAndUpdateState(allReceiptActions: [ReceiptAction], fetcher: Fetcher) async throws -> (ReceiptStateHeader, StateDiff) {
        if allReceiptActions.isEmpty { return (self, .empty) }
        var proofs = [[String]: SparseMerkleProof]()
        for receiptAction in allReceiptActions {
            let receiptKey = ReceiptKey(receiptAction: receiptAction)
            if proofs[[receiptKey.storageKey]] != nil {
                throw StateErrors.conflictingActions
            }
            proofs[[receiptKey.storageKey]] = .insertion
        }
        let proven = try await proof(paths: proofs, fetcher: fetcher)
        var transforms = [[String]: Transform]()
        for receiptAction in allReceiptActions {
            let receiptKey = ReceiptKey(receiptAction: receiptAction)
            transforms[[receiptKey.storageKey]] = .insert(receiptAction.withdrawer)
        }
        guard let transformResult = try proven.transform(transforms: transforms) else { throw TransformErrors.transformFailed("transform returned nil") }
        return (transformResult, diffCIDs(old: proven, new: transformResult))
    }
}
