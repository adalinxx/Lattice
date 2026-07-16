import cashew

public enum ChainAdmissionFailure: Error, Sendable, Equatable {
    case unavailableEvidence
    case providerMalformedEvidence
    case crossChainEvidenceRequired(CrossChainEvidenceRequirement)
    case protocolInvalid
    case localVerificationFailure
    case notYetAdmissible
    case notAcceptedAtCurrentChain
    case revisionExhausted
}

public struct SameChainPredecessorRequirement: Sendable, Equatable {
    public let descendantCID: String
    public let predecessorCID: String

    public init(descendantCID: String, predecessorCID: String) {
        self.descendantCID = descendantCID
        self.predecessorCID = predecessorCID
    }
}

public struct ChainBlockFact: Codable, Sendable, Equatable {
    public let blockHash: String
    public let parentBlockHash: String?
    public let blockHeight: UInt64
    public let postStateCID: String
    public let prevStateCID: String
    public let specCID: String
    public let target: String
    public let nextTarget: String
    public let timestamp: Int64
    public let stateDiff: StateDiff
}

public struct ChainWorkFact: Codable, Sendable, Equatable {
    public let blockHash: String
    public let contribution: VerifiedWorkContribution
}

public enum ChainFactID: Codable, Hashable, Sendable {
    case block(String)
    case work(blockHash: String, grindID: String, work: String)
}

public enum ChainAdmissionFact: Codable, Sendable, Equatable {
    case block(ChainBlockFact)
    case work(ChainWorkFact)

    public var id: ChainFactID {
        switch self {
        case .block(let fact): .block(fact.blockHash)
        case .work(let fact): .work(
            blockHash: fact.blockHash,
            grindID: fact.contribution.id,
            work: fact.contribution.work.toHexString()
        )
        }
    }
}

/// One node-atomic durability unit. New blocks stage their block and first work
/// observations together; later coverage or stronger work appends another
/// immutable fact.
public struct ChainAdmissionBatch: Codable, Sendable, Equatable {
    public let facts: [ChainAdmissionFact]

    init(facts: [ChainAdmissionFact]) {
        self.facts = facts
    }
}

public struct ChainAcceptance: Sendable {
    public let facts: ChainAdmissionBatch
    public let materializedPostState: LatticeState?
    public let commit: ChainCommit
    public let sameChainPredecessor: SameChainPredecessorRequirement?

    public var stateDiff: StateDiff? {
        for case .block(let fact) in facts.facts { return fact.stateDiff }
        return nil
    }
}

public enum ChainLocalBlockResult: Sendable {
    case accepted(ChainAcceptance)
    case carrier
    case duplicate
    case rejected(ChainAdmissionFailure)

    public var materializedPostState: LatticeState? {
        switch self {
        case .accepted(let acceptance): acceptance.materializedPostState
        case .carrier, .duplicate, .rejected: nil
        }
    }

    public var sameChainPredecessor: SameChainPredecessorRequirement? {
        switch self {
        case .accepted(let acceptance): acceptance.sameChainPredecessor
        case .carrier, .duplicate, .rejected: nil
        }
    }

    public var crossChainEvidenceRequirement: CrossChainEvidenceRequirement? {
        guard case .rejected(.crossChainEvidenceRequired(let requirement)) = self else {
            return nil
        }
        return requirement
    }

    public var commit: ChainCommit? {
        switch self {
        case .accepted(let acceptance): acceptance.commit
        case .carrier, .duplicate, .rejected: nil
        }
    }

    public var failure: ChainAdmissionFailure? {
        if case .rejected(let failure) = self { return failure }
        return nil
    }

}

private struct PreparedAdmission: Sendable {
    enum Kind: Sendable {
        case block(StateDiff, LatticeState?)
        case evidence
    }

    let resolvedHeader: BlockHeader
    let block: Block
    let fetcher: any Fetcher
    let contribution: VerifiedWorkContribution
    let kind: Kind

    var facts: ChainAdmissionBatch {
        var facts: [ChainAdmissionFact] = []
        switch kind {
        case .block(let stateDiff, _):
            facts.append(.block(ChainBlockFact(
                blockHash: resolvedHeader.rawCID,
                parentBlockHash: block.parent?.rawCID,
                blockHeight: block.height,
                postStateCID: block.postState.rawCID,
                prevStateCID: block.prevState.rawCID,
                specCID: block.spec.rawCID,
                target: block.target.toHexString(),
                nextTarget: block.nextTarget.toHexString(),
                timestamp: block.timestamp,
                stateDiff: stateDiff
            )))
        case .evidence:
            break
        }
        facts.append(.work(ChainWorkFact(
            blockHash: resolvedHeader.rawCID,
            contribution: contribution
        )))
        return ChainAdmissionBatch(facts: facts)
    }

    func store(to storer: any Storer & VolumeStorer) async throws {
        switch kind {
        case .evidence:
            return
        case .block(let stateDiff, let materializedPostState):
            try await resolvedHeader.storeBlock(fetcher: fetcher, storer: storer)
            if let materializedPostState {
                try await LatticeStateHeader(node: materializedPostState)
                    .storeMaterialized(createdBy: stateDiff, storer: storer)
            }
        }
    }
}

private enum Preparation {
    case ready(PreparedAdmission)
    case result(ChainLocalBlockResult)
}

private enum ChainLocalAdmission {
    static func verifyChildPackage(
        _ package: ChildValidationPackage,
        child: Block,
        context: ChainRuntimeContext
    ) async -> Result<VerifiedChildEvidence, ChainAdmissionFailure> {
        let proofResult = await package.proof.verify(
            child: child,
            chainPath: context.path,
            minimumRootWork: context.minimumRootWork,
            parentContinuityLinks: package.parentContinuityLinks,
            parentGenesisLinks: package.parentGenesisLinks
        ).mapError { failure -> ChainAdmissionFailure in
            switch failure {
            case .crossChainEvidenceRequired(let requirement):
                .crossChainEvidenceRequired(requirement)
            case .malformedEvidence: .providerMalformedEvidence
            case .protocolInvalid: .protocolInvalid
            }
        }
        return proofResult
    }

    static func prepare(
        level: ChainLevel,
        blockHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage?,
        validationContext: ValidationContext
    ) async -> Preparation {
        let context = level.context
        if !context.isRoot {
            guard let childPackage else {
                return .result(.rejected(.crossChainEvidenceRequired(.childProof(
                    chainPath: context.path,
                    childCID: blockHeader.rawCID
                ))))
            }
            switch childPackage.proof.verifyRootFloor(
                minimumRootWork: context.minimumRootWork
            ) {
            case .success:
                break
            case .failure(let failure):
                return .result(.rejected(mapProofFailure(failure)))
            }
        }

        let resolvedHeader: BlockHeader
        let block: Block
        switch await resolveBlock(blockHeader, fetcher: fetcher) {
        case .success(let resolved):
            resolvedHeader = resolved.header
            block = resolved.block
        case .failure(let failure):
            return .result(.rejected(failure))
        }
        let blockHash = resolvedHeader.rawCID

        let contribution: VerifiedWorkContribution?
        if context.isRoot {
            guard childPackage == nil else {
                return .result(.rejected(.protocolInvalid))
            }
            let rootHash = block.proofOfWorkHash()
            guard workForHash(rootHash) >= context.minimumRootWork else {
                return .result(.rejected(.protocolInvalid))
            }
            contribution = block.validateProofOfWork(nexusHash: rootHash)
                ? VerifiedWorkContribution(
                    id: blockHash,
                    work: workForTarget(block.target)
                )
                : nil
        } else {
            guard let childPackage else {
                return .result(.rejected(.crossChainEvidenceRequired(.childProof(
                    chainPath: context.path,
                    childCID: blockHash
                ))))
            }
            switch await verifyChildPackage(
                childPackage,
                child: block,
                context: context
            ) {
            case .success(let verified):
                contribution = verified.contribution
            case .failure(let failure):
                return .result(.rejected(failure))
            }
        }

        guard let contribution else {
            switch await validateCarrierContinuity(block: block, fetcher: fetcher) {
            case .failure(let failure):
                return .result(.rejected(failure))
            case .success:
                break
            }
            return .result(.carrier)
        }

        let knownBlock = await level.chain.contains(blockHash: blockHash)
        if let existing = await level.chain.workContribution(id: contribution.id),
           existing.blockHashes.contains(blockHash),
           existing.contribution.work >= contribution.work {
            return .result(.duplicate)
        }

        if knownBlock {
            return .ready(PreparedAdmission(
                resolvedHeader: resolvedHeader,
                block: block,
                fetcher: fetcher,
                contribution: contribution,
                kind: .evidence
            ))
        }

        let transition: Result<(StateDiff, LatticeState?), ChainAdmissionFailure>
        if block.parent == nil {
            guard !context.isRoot, block.height == 0 else {
                return .result(.rejected(.protocolInvalid))
            }
            transition = await validateGenesis(
                block: block,
                fetcher: fetcher,
                context: context,
                validationContext: validationContext
            )
        } else {
            transition = await validateBlock(
                block: block,
                fetcher: fetcher,
                chain: level.chain,
                context: context,
                validationContext: validationContext
            )
        }

        switch transition {
        case .failure(let failure):
            return .result(.rejected(failure))
        case .success(let (stateDiff, state)):
            return .ready(PreparedAdmission(
                resolvedHeader: resolvedHeader,
                block: block,
                fetcher: fetcher,
                contribution: contribution,
                kind: .block(stateDiff, state)
            ))
        }
    }

    static func resolveBlock(
        _ blockHeader: BlockHeader,
        fetcher: any Fetcher
    ) async -> Result<(header: BlockHeader, block: Block), ChainAdmissionFailure> {
        do {
            let resolved = try await blockHeader.resolve(fetcher: fetcher)
            guard let block = resolved.node else {
                return .failure(.unavailableEvidence)
            }
            return .success((resolved, block))
        } catch {
            return .failure(classifyResolutionFailure(error))
        }
    }

    static func validateGenesis(
        block: Block,
        fetcher: any Fetcher,
        context: ChainRuntimeContext,
        validationContext: ValidationContext
    ) async -> Result<(StateDiff, LatticeState?), ChainAdmissionFailure> {
        do {
            let validation = try await block.validateGenesisTransition(
                fetcher: fetcher,
                directory: context.path.last,
                chainPath: context.path,
                reportTemporalFailure: true,
                validationContext: validationContext
            )
            guard validation.0 else { return .failure(.protocolInvalid) }
            return .success((validation.1, validation.2))
        } catch {
            return .failure(classifyValidationFailure(error))
        }
    }

    static func validateCarrierContinuity(
        block: Block,
        fetcher: any Fetcher
    ) async -> Result<Void, ChainAdmissionFailure> {
        guard let parentHeader = block.parent else {
            return block.hasCarrierContinuity(parent: nil)
                ? .success(())
                : .failure(.protocolInvalid)
        }
        do {
            guard let parent = try await parentHeader.resolve(fetcher: fetcher).node else {
                return .failure(.unavailableEvidence)
            }
            return block.hasCarrierContinuity(parent: parent)
                ? .success(())
                : .failure(.protocolInvalid)
        } catch {
            return .failure(classifyResolutionFailure(error))
        }
    }

    static func validateBlock(
        block: Block,
        fetcher: any Fetcher,
        chain: ChainState,
        context: ChainRuntimeContext,
        validationContext: ValidationContext
    ) async -> Result<(StateDiff, LatticeState?), ChainAdmissionFailure> {
        do {
            let validation = try await block.validateNexus(
                fetcher: fetcher,
                chain: chain,
                chainPath: context.path,
                reportTemporalFailure: true,
                validationContext: validationContext
            )
            guard validation.0 else { return .failure(.protocolInvalid) }
            return .success((validation.1, validation.2))
        } catch {
            return .failure(classifyValidationFailure(error))
        }
    }

    static func finishBootstrap(
        context: ChainRuntimeContext,
        resolved: (header: BlockHeader, block: Block),
        fetcher: any Fetcher,
        contribution: VerifiedWorkContribution,
        transition: (StateDiff, LatticeState?),
        storer: any Storer & VolumeStorer,
        stage: @Sendable (ChainAdmissionBatch) async throws -> Void
    ) async throws -> (
        level: ChainLevel,
        stateDiff: StateDiff,
        materializedPostState: LatticeState?
    ) {
        let prepared = PreparedAdmission(
            resolvedHeader: resolved.header,
            block: resolved.block,
            fetcher: fetcher,
            contribution: contribution,
            kind: .block(transition.0, transition.1)
        )
        try await prepared.store(to: storer)
        try await stage(prepared.facts)
        let chain = try await ChainState.restore(replaying: [prepared.facts])
        return (
            ChainLevel(chain: chain, context: context),
            transition.0,
            transition.1
        )
    }

    static func result(
        for submission: SubmissionResult,
        prepared: PreparedAdmission,
        sameChainPredecessor: SameChainPredecessorRequirement?
    ) -> ChainLocalBlockResult {
        guard let commit = submission.commit else { return .duplicate }
        let materializedPostState: LatticeState?
        if case .block(_, let state) = prepared.kind {
            materializedPostState = state
        } else {
            materializedPostState = nil
        }
        return .accepted(ChainAcceptance(
            facts: prepared.facts,
            materializedPostState: materializedPostState,
            commit: commit,
            sameChainPredecessor: sameChainPredecessor
        ))
    }
}

private func classifyResolutionFailure(_ error: Error) -> ChainAdmissionFailure {
    if error is FetcherError { return .unavailableEvidence }
    if let dataError = error as? DataErrors { return classifyDataError(dataError) }
    if error is CashewDecodingError || error is ResolutionErrors {
        return .protocolInvalid
    }
    return .localVerificationFailure
}

private func mapProofFailure(
    _ failure: ChildProofVerificationFailure
) -> ChainAdmissionFailure {
    switch failure {
    case .crossChainEvidenceRequired(let requirement):
        .crossChainEvidenceRequired(requirement)
    case .malformedEvidence: .providerMalformedEvidence
    case .protocolInvalid: .protocolInvalid
    }
}

private func classifyValidationFailure(_ error: Error) -> ChainAdmissionFailure {
    if error is BlockValidationError { return .notYetAdmissible }
    if let dataError = error as? DataErrors { return classifyDataError(dataError) }
    if error is FetcherError { return .unavailableEvidence }
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
    if let policyError = error as? WasmPolicyError {
        switch policyError {
        case .missingModule:
            return .unavailableEvidence
        case .contextEncodingFailed:
            return .localVerificationFailure
        default:
            return .protocolInvalid
        }
    }
    if error is StateErrors || error is ProofErrors
        || error is CashewDecodingError || error is ResolutionErrors {
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
    case .serializationFailed, .cidCreationFailed, .encryptionFailed,
         .decryptionFailed, .invalidIV:
        return .localVerificationFailure
    }
}

public extension ChainLevel {
    /// Produce the semantic continuity fact a child process needs for one carrier.
    /// The node is responsible for authenticating this process and transporting
    /// and caching the returned immutable value.
    func continuityLink(
        for successorHeader: BlockHeader,
        fetcher: any Fetcher
    ) async -> Result<ParentContinuityLink, ChainAdmissionFailure> {
        do {
            let resolvedSuccessor = try await successorHeader.resolve(fetcher: fetcher)
            guard let successor = resolvedSuccessor.node else {
                return .failure(.unavailableEvidence)
            }
            guard let predecessorHeader = successor.parent else {
                return .failure(.protocolInvalid)
            }
            let predecessorCID = predecessorHeader.rawCID
            guard await chain.hasValidatedAncestry(blockHash: predecessorCID) else {
                return .failure(.unavailableEvidence)
            }
            let resolvedPredecessor = try await predecessorHeader.resolve(fetcher: fetcher)
            guard let predecessor = resolvedPredecessor.node else {
                return .failure(.unavailableEvidence)
            }
            guard successor.hasCarrierContinuity(parent: predecessor) else {
                return .failure(.protocolInvalid)
            }
            return .success(ParentContinuityLink(
                parentPath: context.path,
                successorCID: successorHeader.rawCID
            ))
        } catch {
            return .failure(classifyValidationFailure(error))
        }
    }

    /// Produce a permanent fact that this parent chain authorized one child
    /// genesis CID at `directory`. Parent canonicity is intentionally irrelevant;
    /// any block in the validated parent forest may authorize a competing root.
    func genesisLink(
        parentBlockHeader: BlockHeader,
        directory: String,
        childGenesisCID: String,
        fetcher: any Fetcher
    ) async -> Result<ParentGenesisLink, ChainAdmissionFailure> {
        guard !directory.isEmpty, !childGenesisCID.isEmpty else {
            return .failure(.protocolInvalid)
        }
        let parentBlockCID = parentBlockHeader.rawCID
        guard await chain.hasValidatedAncestry(blockHash: parentBlockCID) else {
            return .failure(.unavailableEvidence)
        }
        do {
            let resolvedBlock = try await parentBlockHeader.resolve(fetcher: fetcher)
            guard let block = resolvedBlock.node else {
                return .failure(.unavailableEvidence)
            }
            let resolvedState = try await block.postState.resolve(
                paths: [[GENESIS_STATE_PROPERTY, directory]: .targeted],
                fetcher: fetcher
            )
            guard let state = resolvedState.node,
                  let genesisState = state.genesisState.node else {
                return .failure(.unavailableEvidence)
            }
            guard let anchoredCID: String = try? genesisState.get(key: directory),
                  anchoredCID == childGenesisCID else {
                return .failure(.protocolInvalid)
            }
            return .success(ParentGenesisLink(
                parentPath: context.path,
                directory: directory,
                childGenesisCID: childGenesisCID
            ))
        } catch {
            return .failure(classifyValidationFailure(error))
        }
    }

    /// Admit one candidate. `stage` is the node-owned atomic durability
    /// boundary: success means the whole batch is durable, while throwing means
    /// no fact from the batch became visible. Once it succeeds, live execution
    /// applies that exact batch without reacquisition.
    func admitBlockHeaderChainLocal(
        _ blockHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage? = nil,
        validationContext: ValidationContext = .current,
        storer: any Storer & VolumeStorer,
        stage: @Sendable (ChainAdmissionBatch) async throws -> Void
    ) async throws -> ChainLocalBlockResult {
        switch await ChainLocalAdmission.prepare(
            level: self,
            blockHeader: blockHeader,
            fetcher: fetcher,
            childPackage: childPackage,
            validationContext: validationContext
        ) {
        case .result(let result):
            return result
        case .ready(let prepared):
            try await prepared.store(to: storer)
            guard await chain.reserveAdmissionRevision() else {
                return .rejected(.revisionExhausted)
            }
            do {
                try await stage(prepared.facts)
            } catch {
                await chain.releaseAdmissionRevision()
                throw error
            }
            guard let submission = try await chain.applyReservedStaged(
                prepared.facts
            ) else {
                return .duplicate
            }
            let requirement = await chain.sameChainPredecessorRequirement(
                for: prepared.resolvedHeader.rawCID
            )
            return ChainLocalAdmission.result(
                for: submission,
                prepared: prepared,
                sameChainPredecessor: requirement
            )
        }
    }

    func admitBlockHeaderChainLocal(
        _ blockHeader: BlockHeader,
        source: any ContentSource,
        childPackage: ChildValidationPackage? = nil,
        validationContext: ValidationContext = .current,
        storer: any Storer & VolumeStorer,
        stage: @Sendable (ChainAdmissionBatch) async throws -> Void
    ) async throws -> ChainLocalBlockResult {
        try await admitBlockHeaderChainLocal(
            blockHeader,
            fetcher: CoalescingFetcher(source),
            childPackage: childPackage,
            validationContext: validationContext,
            storer: storer,
            stage: stage
        )
    }

    /// Create the root-chain process from an externally supplied, fully
    /// validated genesis. The runtime becomes visible only after storage and
    /// atomic staging succeed.
    static func bootstrap(
        context: ChainRuntimeContext,
        genesisHeader: BlockHeader,
        fetcher: any Fetcher,
        validationContext: ValidationContext = .current,
        storer: any Storer & VolumeStorer,
        stage: @Sendable (ChainAdmissionBatch) async throws -> Void
    ) async throws -> (level: ChainLevel, stateDiff: StateDiff, materializedPostState: LatticeState?) {
        guard context.isRoot else { throw ChainAdmissionFailure.protocolInvalid }
        let resolved: (header: BlockHeader, block: Block)
        switch await ChainLocalAdmission.resolveBlock(genesisHeader, fetcher: fetcher) {
        case .failure(let failure): throw failure
        case .success(let value): resolved = value
        }
        guard resolved.block.parent == nil, resolved.block.height == 0 else {
            throw ChainAdmissionFailure.protocolInvalid
        }
        let rootHash = resolved.block.proofOfWorkHash()
        guard workForHash(rootHash) >= context.minimumRootWork else {
            throw ChainAdmissionFailure.protocolInvalid
        }
        guard resolved.block.validateProofOfWork(nexusHash: rootHash) else {
            switch await ChainLocalAdmission.validateCarrierContinuity(
                block: resolved.block,
                fetcher: fetcher
            ) {
            case .failure(let failure): throw failure
            case .success: throw ChainAdmissionFailure.notAcceptedAtCurrentChain
            }
        }
        let transition: (StateDiff, LatticeState?)
        switch await ChainLocalAdmission.validateGenesis(
            block: resolved.block,
            fetcher: fetcher,
            context: context,
            validationContext: validationContext
        ) {
        case .failure(let failure): throw failure
        case .success(let value): transition = value
        }
        return try await ChainLocalAdmission.finishBootstrap(
            context: context,
            resolved: resolved,
            fetcher: fetcher,
            contribution: VerifiedWorkContribution(
                id: resolved.header.rawCID,
                work: workForTarget(resolved.block.target)
            ),
            transition: transition,
            storer: storer,
            stage: stage
        )
    }

    /// Create a standalone child-chain process from its first accepted root.
    static func bootstrap(
        context: ChainRuntimeContext,
        genesisHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage,
        validationContext: ValidationContext = .current,
        storer: any Storer & VolumeStorer,
        stage: @Sendable (ChainAdmissionBatch) async throws -> Void
    ) async throws -> (level: ChainLevel, stateDiff: StateDiff, materializedPostState: LatticeState?) {
        guard !context.isRoot else { throw ChainAdmissionFailure.protocolInvalid }
        switch childPackage.proof.verifyRootFloor(
            minimumRootWork: context.minimumRootWork
        ) {
        case .success:
            break
        case .failure(let failure):
            throw mapProofFailure(failure)
        }
        let resolved: (header: BlockHeader, block: Block)
        switch await ChainLocalAdmission.resolveBlock(genesisHeader, fetcher: fetcher) {
        case .failure(let failure): throw failure
        case .success(let value): resolved = value
        }
        guard resolved.block.parent == nil, resolved.block.height == 0 else {
            throw ChainAdmissionFailure.protocolInvalid
        }
        let evidence: VerifiedChildEvidence
        switch await ChainLocalAdmission.verifyChildPackage(
            childPackage,
            child: resolved.block,
            context: context
        ) {
        case .success(let verified): evidence = verified
        case .failure(let failure): throw failure
        }
        guard let contribution = evidence.contribution else {
            switch await ChainLocalAdmission.validateCarrierContinuity(
                block: resolved.block,
                fetcher: fetcher
            ) {
            case .failure(let failure): throw failure
            case .success: throw ChainAdmissionFailure.notAcceptedAtCurrentChain
            }
        }
        let transition: (StateDiff, LatticeState?)
        switch await ChainLocalAdmission.validateGenesis(
            block: resolved.block,
            fetcher: fetcher,
            context: context,
            validationContext: validationContext
        ) {
        case .failure(let failure): throw failure
        case .success(let value): transition = value
        }
        return try await ChainLocalAdmission.finishBootstrap(
            context: context,
            resolved: resolved,
            fetcher: fetcher,
            contribution: contribution,
            transition: transition,
            storer: storer,
            stage: stage
        )
    }
}
