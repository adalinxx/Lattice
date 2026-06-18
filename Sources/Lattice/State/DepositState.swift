import cashew

public struct DepositKey: LosslessStringConvertible {
    public let nonce: UInt128
    public let demander: String
    public let amountDemanded: UInt64

    public init(depositAction: DepositAction) {
        nonce = depositAction.nonce
        demander = depositAction.demander
        amountDemanded = depositAction.amountDemanded
    }

    public init(withdrawalAction: WithdrawalAction) {
        nonce = withdrawalAction.nonce
        demander = withdrawalAction.demander
        amountDemanded = withdrawalAction.amountDemanded
    }

    public init(nonce: UInt128, demander: String, amountDemanded: UInt64) {
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
    }

    public init?(_ description: String) {
        let split = description.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: true)
        guard split.count >= 3 else { return nil }
        let demander = String(split[0])
        guard let amountDemanded = UInt64(String(split[1])) else { return nil }
        guard let nonce = UInt128(String(split[2])) else { return nil }
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
    }

    public var description: String {
        return "\(demander)/\(amountDemanded.description)/\(nonce.description)"
    }
}

public typealias DepositState = VolumeMerkleDictionaryImpl<UInt64>
public typealias DepositStateHeader = VolumeImpl<DepositState>

public extension DepositStateHeader {
    func proveExistenceOfCorrespondingDeposit(withdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> DepositStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for withdrawalAction in withdrawalActions {
            let depositKey = DepositKey(withdrawalAction: withdrawalAction).description
            proofs[[depositKey]] = .mutation
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }

    func proveAndDeleteForWithdrawals(allWithdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> (DepositStateHeader, StateDiff) {
        if allWithdrawalActions.isEmpty { return (self, .empty) }
        var seenKeys = Set<String>()
        var resolvePaths = [[String]: ResolutionStrategy]()
        for wa in allWithdrawalActions {
            let key = DepositKey(withdrawalAction: wa).description
            if !seenKeys.insert(key).inserted { throw StateErrors.conflictingActions }
            resolvePaths[[key]] = .targeted
        }
        let resolved = try await resolve(paths: resolvePaths, fetcher: fetcher)
        var proofs = [[String]: SparseMerkleProof]()
        var transforms = [[String]: Transform]()
        for wa in allWithdrawalActions {
            let key = DepositKey(withdrawalAction: wa).description
            guard let node = resolved.node, let storedDeposited: UInt64 = try? node.get(key: key) else {
                throw StateErrors.conflictingActions
            }
            if storedDeposited != wa.amountWithdrawn { throw StateErrors.conflictingActions }
            proofs[[key]] = .deletion
            transforms[[key]] = .delete
        }
        if proofs.isEmpty { return (self, .empty) }
        let proven = try await proof(paths: proofs, fetcher: fetcher)
        guard let result = try proven.transform(transforms: transforms) else {
            throw TransformErrors.transformFailed("deposit deletion transform returned nil")
        }
        return (result, diffCIDs(old: proven, new: result))
    }

    func proveAndUpdateState(allDepositActions: [DepositAction], fetcher: Fetcher) async throws -> (DepositStateHeader, StateDiff) {
        if allDepositActions.isEmpty { return (self, .empty) }
        var proofs = [[String]: SparseMerkleProof]()
        for depositAction in allDepositActions {
            if depositAction.amountDeposited == 0 { throw StateErrors.conflictingActions }
            if depositAction.amountDemanded == 0 { throw StateErrors.conflictingActions }
            let depositKey = DepositKey(depositAction: depositAction).description
            if proofs[[depositKey]] != nil { throw StateErrors.conflictingActions }
            proofs[[depositKey]] = .insertion
        }
        let proven = try await proof(paths: proofs, fetcher: fetcher)
        var transforms = [[String]: Transform]()
        for depositAction in allDepositActions {
            let depositKey = DepositKey(depositAction: depositAction).description
            transforms[[depositKey]] = .insert(String(depositAction.amountDeposited))
        }
        guard let transformResult = try proven.transform(transforms: transforms) else { throw TransformErrors.transformFailed("transform returned nil") }
        return (transformResult, diffCIDs(old: proven, new: transformResult))
    }
}
