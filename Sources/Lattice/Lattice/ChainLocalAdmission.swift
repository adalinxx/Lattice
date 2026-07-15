import cashew

/// A non-successful chain-local admission outcome.
public enum ChainAdmissionFailure: Error, Sendable, Equatable {
    case unavailableEvidence
    case providerMalformedEvidence
    case missingChildProof
    case protocolInvalid
    case localVerificationFailure
    case notYetAdmissible
    case durablePreparationUnavailable
    case durablePreparationFailed
}

/// Bodies needed to complete a known heavier branch. The admission boundary
/// reports this requirement but never initiates transport itself.
public struct MissingBodyRequest: Sendable, Equatable {
    public let tipHash: String
    public let missingBodies: [String]

    init(tipHash: String, missingBodies: [String]) {
        self.tipHash = tipHash
        self.missingBodies = missingBodies
    }
}

/// Immutable admission identity for one runtime chain level.
///
/// The path is configured when the level is created, not supplied by a gossip
/// caller. Child levels require a proof witness for every candidate.
struct ChainAdmissionContext: Sendable, Equatable {
    let chainPath: [String]
    let requiresChildProof: Bool

    init(rootDirectory: String = DEFAULT_ROOT_DIRECTORY) {
        precondition(!rootDirectory.isEmpty)
        chainPath = [rootDirectory]
        requiresChildProof = false
    }

    init(parent: ChainAdmissionContext, directory: String) {
        precondition(!directory.isEmpty)
        chainPath = parent.chainPath + [directory]
        requiresChildProof = true
    }

    static let root = ChainAdmissionContext()

    fileprivate var childProofPath: [String] {
        Array(chainPath.dropFirst())
    }
}

/// Result of the node's durable preparation step for one fully verified block.
/// Retention policy remains entirely node-owned.
public enum ChainCommitPreparation: Sendable, Equatable {
    case ready
    case unavailable
    case storageFailed
}

public typealias ChainCommitPreparer = @Sendable (Block, StateDiff, LatticeState?) async -> ChainCommitPreparation

/// Chain-local admission result. This vocabulary preserves the architectural
/// distinction between unavailable evidence, invalid protocol data, local
/// failures, temporal deferral, and durable preparation failures.
public enum ChainLocalBlockResult: Sendable {
    case canonicalized(
        StateDiff,
        materializedPostState: LatticeState?,
        followUps: [MissingBodyRequest]
    )
    case acceptedSide(
        StateDiff,
        materializedPostState: LatticeState?,
        followUps: [MissingBodyRequest]
    )
    case duplicate
    case rejected(ChainAdmissionFailure)

    public var materializedPostState: LatticeState? {
        switch self {
        case .canonicalized(_, let state, _), .acceptedSide(_, let state, _):
            state
        case .duplicate, .rejected:
            nil
        }
    }

    public var followUps: [MissingBodyRequest] {
        switch self {
        case .canonicalized(_, _, let followUps), .acceptedSide(_, _, let followUps):
            followUps
        case .duplicate, .rejected:
            []
        }
    }

    public var failure: ChainAdmissionFailure? {
        if case .rejected(let failure) = self { return failure }
        return nil
    }
}

enum ChainLocalAdmission {
    static func admit(
        level: ChainLevel,
        blockHeader: BlockHeader,
        fetcher: Fetcher,
        childProof: ChildBlockProof?,
        prepare: @escaping ChainCommitPreparer
    ) async -> ChainLocalBlockResult {
        let context = level.admissionContext
        let chain = level.chain
        if await chain.contains(blockHash: blockHeader.rawCID) {
            return .duplicate
        }

        let block: Block
        switch await resolveBlock(blockHeader, fetcher: fetcher) {
        case .success(let resolved):
            block = resolved
        case .failure(let failure):
            return .rejected(failure)
        }

        switch await validate(
            blockHeader: blockHeader,
            block: block,
            fetcher: fetcher,
            chain: chain,
            context: context,
            childProof: childProof
        ) {
        case .failure(let failure):
            return .rejected(failure)
        case .success(let transition):
            return await commit(
                blockHeader: blockHeader,
                block: block,
                stateDiff: transition.stateDiff,
                materializedPostState: transition.materializedPostState,
                chain: chain,
                prepare: prepare
            )
        }
    }

    /// Resolve a header through one typed boundary so first-root bootstrap and
    /// ordinary admission cannot disagree about unavailable, malformed, and
    /// local verification failures.
    static func resolveBlock(
        _ blockHeader: BlockHeader,
        fetcher: Fetcher
    ) async -> Result<Block, ChainAdmissionFailure> {
        do {
            guard let block = try await blockHeader.resolveBlockContent(fetcher: fetcher).node else {
                return .failure(.unavailableEvidence)
            }
            return .success(block)
        } catch {
            return .failure(classifyResolutionFailure(error))
        }
    }

    /// Validate a first root before a child runtime exists. The child context is
    /// already fixed by its parent, so this has the same proof and genesis rules
    /// as ordinary admission without creating an unchecked empty runtime first.
    static func validateGenesis(
        blockHeader: BlockHeader,
        block: Block,
        fetcher: Fetcher,
        context: ChainAdmissionContext,
        childProof: ChildBlockProof
    ) async -> Result<(stateDiff: StateDiff, materializedPostState: LatticeState?), ChainAdmissionFailure> {
        guard block.parent == nil else { return .failure(.protocolInvalid) }
        if let failure = await validateAnchor(
            blockHeader: blockHeader,
            block: block,
            context: context,
            childProof: childProof
        ) {
            return .failure(failure)
        }

        do {
            let validation = try await block.validateGenesisTransition(
                fetcher: fetcher,
                directory: context.chainPath.last,
                chainPath: context.chainPath,
                reportTemporalFailure: true
            )
            guard validation.0 else { return .failure(.protocolInvalid) }
            return .success((validation.1, validation.2))
        } catch {
            return .failure(classifyValidationFailure(error))
        }
    }

    static func prepare(
        block: Block,
        stateDiff: StateDiff,
        materializedPostState: LatticeState?,
        prepare: @escaping ChainCommitPreparer
    ) async -> ChainAdmissionFailure? {
        switch await prepare(block, stateDiff, materializedPostState) {
        case .ready:
            return nil
        case .unavailable:
            return .durablePreparationUnavailable
        case .storageFailed:
            return .durablePreparationFailed
        }
    }

    private static func validate(
        blockHeader: BlockHeader,
        block: Block,
        fetcher: Fetcher,
        chain: ChainState,
        context: ChainAdmissionContext,
        childProof: ChildBlockProof?
    ) async -> Result<(stateDiff: StateDiff, materializedPostState: LatticeState?), ChainAdmissionFailure> {
        if let failure = await validateAnchor(
            blockHeader: blockHeader,
            block: block,
            context: context,
            childProof: childProof
        ) {
            return .failure(failure)
        }

        if block.parent == nil {
            do {
                let validation = try await block.validateGenesisTransition(
                    fetcher: fetcher,
                    directory: context.chainPath.last,
                    chainPath: context.chainPath,
                    reportTemporalFailure: true
                )
                guard validation.0 else { return .failure(.protocolInvalid) }
                return .success((validation.1, validation.2))
            } catch {
                return .failure(classifyValidationFailure(error))
            }
        }

        do {
            let validation = try await block.validateNexus(
                fetcher: fetcher,
                chain: chain,
                chainPath: context.chainPath,
                reportTemporalFailure: true
            )
            guard validation.0 else { return .failure(.protocolInvalid) }
            return .success((validation.1, validation.2))
        } catch {
            return .failure(classifyValidationFailure(error))
        }
    }

    private static func validateAnchor(
        blockHeader: BlockHeader,
        block: Block,
        context: ChainAdmissionContext,
        childProof: ChildBlockProof?
    ) async -> ChainAdmissionFailure? {
        guard context.requiresChildProof else {
            guard childProof == nil else { return .protocolInvalid }
            return block.validateProofOfWork(nexusHash: block.proofOfWorkHash())
                ? nil
                : .protocolInvalid
        }

        guard let childProof else {
            return .missingChildProof
        }
        guard childProof.directoryPath == context.childProofPath else {
            return .protocolInvalid
        }
        guard let root = await childProof.anchorRoot() else {
            return childProof.entries.isEmpty
                ? .missingChildProof
                : .providerMalformedEvidence
        }
        guard await childProof.verify(rootHash: root.hash, childCID: blockHeader.rawCID),
              let parentAnchor = await childProof.committingParentAnchor(),
              parentAnchor.prevStateCID == block.parentState.rawCID
        else {
            return .providerMalformedEvidence
        }
        return block.validateProofOfWork(nexusHash: root.hash)
            ? nil
            : .protocolInvalid
    }

    private static func commit(
        blockHeader: BlockHeader,
        block: Block,
        stateDiff: StateDiff,
        materializedPostState: LatticeState?,
        chain: ChainState,
        prepare: @escaping ChainCommitPreparer
    ) async -> ChainLocalBlockResult {
        if let failure = await self.prepare(
            block: block,
            stateDiff: stateDiff,
            materializedPostState: materializedPostState,
            prepare: prepare
        ) {
            return .rejected(failure)
        }

        let submission = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: blockHeader,
            block: block
        )
        var followUps: [MissingBodyRequest] = []
        if submission.addedBlock,
           submission.needsChildBlock,
           let parentHash = block.parent?.rawCID {
            followUps.append(MissingBodyRequest(
                tipHash: blockHeader.rawCID,
                missingBodies: [parentHash]
            ))
        }
        if submission.addedBlock,
           let target = await chain.heldHeavierBackfillTarget() {
            mergeFollowUp(MissingBodyRequest(
                tipHash: target.tipHash,
                missingBodies: target.missingBodies
            ), into: &followUps)
        }

        if submission.extendsMainChain || submission.reorganization != nil {
            return .canonicalized(
                stateDiff,
                materializedPostState: materializedPostState,
                followUps: followUps
            )
        }
        if submission.addedBlock {
            return .acceptedSide(
                stateDiff,
                materializedPostState: materializedPostState,
                followUps: followUps
            )
        }
        return .duplicate
    }

    private static func mergeFollowUp(
        _ request: MissingBodyRequest,
        into requests: inout [MissingBodyRequest]
    ) {
        guard let index = requests.firstIndex(where: { $0.tipHash == request.tipHash }) else {
            requests.append(request)
            return
        }

        let existing = requests[index]
        var missingBodies = existing.missingBodies
        for body in request.missingBodies where !missingBodies.contains(body) {
            missingBodies.append(body)
        }
        requests[index] = MissingBodyRequest(
            tipHash: existing.tipHash,
            missingBodies: missingBodies
        )
    }
}

private func classifyResolutionFailure(_ error: Error) -> ChainAdmissionFailure {
    if error is FetcherError {
        return .unavailableEvidence
    }
    if let dataError = error as? DataErrors {
        return classifyDataError(dataError)
    }
    if error is CashewDecodingError || error is ResolutionErrors {
        return .protocolInvalid
    }
    return .localVerificationFailure
}

private func classifyValidationFailure(_ error: Error) -> ChainAdmissionFailure {
    if error is BlockValidationError {
        return .notYetAdmissible
    }
    if let dataError = error as? DataErrors {
        return classifyDataError(dataError)
    }
    if error is FetcherError {
        return .unavailableEvidence
    }
    if let validationError = error as? ValidationErrors {
        switch validationError {
        case .transactionNotResolved, .prevStateNotResolved, .postStateNotResolved:
            return .unavailableEvidence
        case .serializationError:
            return .localVerificationFailure
        }
    }
    if let transformError = error as? TransformErrors {
        switch transformError {
        case .missingData:
            return .unavailableEvidence
        case .transformFailed, .invalidKey:
            return .protocolInvalid
        }
    }
    if error is StateErrors || error is CashewDecodingError || error is ResolutionErrors {
        return .protocolInvalid
    }
    return .localVerificationFailure
}

private func classifyDataError(_ error: DataErrors) -> ChainAdmissionFailure {
    switch error {
    case .nodeNotAvailable, .keyNotFound:
        return .unavailableEvidence
    case .cidMismatch:
        return .providerMalformedEvidence
    case .missingDeclaredChild:
        return .protocolInvalid
    case .serializationFailed, .cidCreationFailed, .encryptionFailed, .decryptionFailed, .invalidIV:
        return .localVerificationFailure
    }
}

public extension ChainLevel {
    /// Validate and admit one block on this runtime chain only.
    ///
    /// The chain level, rather than the caller, owns its chain path and whether
    /// an anchored child proof is required. `prepare` is mandatory and runs before
    /// any visible in-memory mutation.
    func admitBlockHeaderChainLocal(
        _ blockHeader: BlockHeader,
        fetcher: Fetcher,
        childProof: ChildBlockProof? = nil,
        prepare: @escaping ChainCommitPreparer
    ) async -> ChainLocalBlockResult {
        return await ChainLocalAdmission.admit(
            level: self,
            blockHeader: blockHeader,
            fetcher: fetcher,
            childProof: childProof,
            prepare: prepare
        )
    }

    /// Batched-content overload with the same admission semantics as `fetcher:`.
    func admitBlockHeaderChainLocal(
        _ blockHeader: BlockHeader,
        source: any ContentSource,
        childProof: ChildBlockProof? = nil,
        prepare: @escaping ChainCommitPreparer
    ) async -> ChainLocalBlockResult {
        await admitBlockHeaderChainLocal(
            blockHeader,
            fetcher: CoalescingFetcher(source),
            childProof: childProof,
            prepare: prepare
        )
    }
}
