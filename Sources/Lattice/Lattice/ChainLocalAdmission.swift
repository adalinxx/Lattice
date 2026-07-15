import cashew

public enum ChainAdmissionFailure: Error, Sendable, Equatable {
    case unavailableEvidence
    case providerMalformedEvidence
    case missingChildProof
    case protocolInvalid
    case localVerificationFailure
    case notYetAdmissible
    case notAcceptedAtCurrentChain
}

public struct MissingBodyRequest: Sendable, Equatable {
    public let tipHash: String
    public let missingBodies: [String]

    public init(tipHash: String, missingBodies: [String]) {
        self.tipHash = tipHash
        self.missingBodies = missingBodies
    }
}

public enum ChainAdmissionRecordKind: Sendable {
    case block
    case evidence
    case carrier
}

/// Immutable facts the node must make durable before Lattice changes fork choice.
public struct ChainAdmissionRecord: Sendable {
    public let kind: ChainAdmissionRecordKind
    public let blockHash: String
    public let blockHeight: UInt64
    public let postStateCID: String
    public let stateDiff: StateDiff?
    public let workContribution: VerifiedWorkContribution?
    public let childEvidence: VerifiedChildEvidence?
}

public enum ChainLocalBlockResult: Sendable {
    case canonicalized(
        StateDiff,
        materializedPostState: LatticeState?,
        reorganization: Reorganization?,
        evictedBlocks: [BlockMeta],
        followUps: [MissingBodyRequest]
    )
    case acceptedSide(
        StateDiff,
        materializedPostState: LatticeState?,
        evictedBlocks: [BlockMeta],
        followUps: [MissingBodyRequest]
    )
    case acceptedEvidence(
        VerifiedWorkContribution,
        reorganization: Reorganization?,
        evictedBlocks: [BlockMeta],
        followUps: [MissingBodyRequest]
    )
    case carrier
    case duplicate
    case rejected(ChainAdmissionFailure)

    public var materializedPostState: LatticeState? {
        switch self {
        case .canonicalized(_, let state, _, _, _), .acceptedSide(_, let state, _, _):
            state
        case .acceptedEvidence, .carrier, .duplicate, .rejected:
            nil
        }
    }

    public var followUps: [MissingBodyRequest] {
        switch self {
        case .canonicalized(_, _, _, _, let requests),
             .acceptedSide(_, _, _, let requests),
             .acceptedEvidence(_, _, _, let requests):
            requests
        case .carrier, .duplicate, .rejected:
            []
        }
    }

    public var evictedBlocks: [BlockMeta] {
        switch self {
        case .canonicalized(_, _, _, let blocks, _),
             .acceptedSide(_, _, let blocks, _),
             .acceptedEvidence(_, _, let blocks, _):
            blocks
        case .carrier, .duplicate, .rejected:
            []
        }
    }

    public var failure: ChainAdmissionFailure? {
        if case .rejected(let failure) = self { return failure }
        return nil
    }

    public var reorganization: Reorganization? {
        switch self {
        case .canonicalized(_, _, let reorganization, _, _),
             .acceptedEvidence(_, let reorganization, _, _):
            reorganization
        case .acceptedSide, .carrier, .duplicate, .rejected:
            nil
        }
    }
}

private struct PreparedAdmission: Sendable {
    enum Kind: Sendable {
        case block(StateDiff, LatticeState?)
        case evidence
        case carrier
    }

    let generation: UInt64
    let resolvedHeader: BlockHeader
    let block: Block
    let fetcher: any Fetcher
    let contribution: VerifiedWorkContribution?
    let childEvidence: VerifiedChildEvidence?
    let kind: Kind

    var record: ChainAdmissionRecord {
        let recordKind: ChainAdmissionRecordKind
        let diff: StateDiff?
        switch kind {
        case .block(let stateDiff, _):
            recordKind = .block
            diff = stateDiff
        case .evidence:
            recordKind = .evidence
            diff = nil
        case .carrier:
            recordKind = .carrier
            diff = nil
        }
        return ChainAdmissionRecord(
            kind: recordKind,
            blockHash: resolvedHeader.rawCID,
            blockHeight: block.height,
            postStateCID: block.postState.rawCID,
            stateDiff: diff,
            workContribution: contribution,
            childEvidence: childEvidence
        )
    }

    func store(to storer: any Storer & VolumeStorer) async throws {
        switch kind {
        case .carrier:
            let paths: [[String]: ResolutionStrategy] = [
                [CHILDREN_PROPERTY, ""]: .list
            ]
            let carrier = try await resolvedHeader.resolve(
                paths: paths,
                fetcher: fetcher
            )
            try await carrier.store(paths: paths, storer: storer)
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
    case stale
}

private enum ChainLocalAdmission {
    static func verifyChildPackage(
        _ package: ChildValidationPackage,
        child: Block,
        childCID: String,
        context: ChainRuntimeContext
    ) async -> Result<VerifiedChildEvidence, ChainAdmissionFailure> {
        let proofResult = await package.proof.verify(
            child: child,
            childCID: childCID,
            chainPath: context.path,
            minimumRootWork: context.minimumRootWork,
            parentContinuityLinks: package.parentContinuityLinks
        ).mapError { failure -> ChainAdmissionFailure in
            switch failure {
            case .unavailableEvidence: .unavailableEvidence
            case .malformedEvidence: .providerMalformedEvidence
            case .protocolInvalid: .protocolInvalid
            }
        }
        guard case .success = proofResult else { return proofResult }

        if child.parent == nil {
            guard let link = package.parentGenesisLink else {
                return .failure(.unavailableEvidence)
            }
            guard let directory = context.path.last,
                  link.parentPath == Array(context.path.dropLast()),
                  link.directory == directory,
                  link.childGenesisCID == childCID else {
                return .failure(.providerMalformedEvidence)
            }
        } else if package.parentGenesisLink != nil {
            return .failure(.providerMalformedEvidence)
        }
        return proofResult
    }

    static func prepare(
        level: ChainLevel,
        blockHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage?
    ) async -> Preparation {
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

        let context = level.context
        let evidence: VerifiedChildEvidence?
        let contribution: VerifiedWorkContribution?
        if context.isRoot {
            guard childPackage == nil else {
                return .result(.rejected(.protocolInvalid))
            }
            let rootHash = block.proofOfWorkHash()
            guard workForHash(rootHash) >= context.minimumRootWork else {
                return .result(.rejected(.protocolInvalid))
            }
            evidence = nil
            contribution = block.validateProofOfWork(nexusHash: rootHash)
                ? VerifiedWorkContribution(
                    id: blockHash,
                    work: workForTarget(block.target)
                )
                : nil
        } else {
            guard let childPackage else {
                return .result(.rejected(.missingChildProof))
            }
            switch await verifyChildPackage(
                childPackage,
                child: block,
                childCID: blockHash,
                context: context
            ) {
            case .success(let verified):
                evidence = verified
                contribution = verified.contribution(for: block)
            case .failure(let failure):
                return .result(.rejected(failure))
            }
        }

        let generation = await level.chain.currentMutationGeneration()
        guard let contribution else {
            switch await validateCarrierContinuity(block: block, fetcher: fetcher) {
            case .failure(let failure):
                return .result(.rejected(failure))
            case .success:
                break
            }
            return .ready(PreparedAdmission(
                generation: generation,
                resolvedHeader: resolvedHeader,
                block: block,
                fetcher: fetcher,
                contribution: nil,
                childEvidence: evidence,
                kind: .carrier
            ))
        }

        let knownBlock = await level.chain.contains(blockHash: blockHash)
        if let existing = await level.chain.workContribution(id: contribution.id) {
            guard existing.blockHash == blockHash,
                  existing.contribution == contribution else {
                return .result(.rejected(.providerMalformedEvidence))
            }
            return .result(.duplicate)
        }

        if knownBlock {
            let currentGeneration = await level.chain.currentMutationGeneration()
            guard generation == currentGeneration else {
                return .stale
            }
            return .ready(PreparedAdmission(
                generation: generation,
                resolvedHeader: resolvedHeader,
                block: block,
                fetcher: fetcher,
                contribution: contribution,
                childEvidence: evidence,
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
                context: context
            )
        } else {
            transition = await validateBlock(
                block: block,
                fetcher: fetcher,
                chain: level.chain,
                context: context
            )
        }

        let currentGeneration = await level.chain.currentMutationGeneration()
        guard generation == currentGeneration else {
            return .stale
        }
        switch transition {
        case .failure(let failure):
            return .result(.rejected(failure))
        case .success(let (stateDiff, state)):
            return .ready(PreparedAdmission(
                generation: generation,
                resolvedHeader: resolvedHeader,
                block: block,
                fetcher: fetcher,
                contribution: contribution,
                childEvidence: evidence,
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
        context: ChainRuntimeContext
    ) async -> Result<(StateDiff, LatticeState?), ChainAdmissionFailure> {
        do {
            let validation = try await block.validateGenesisTransition(
                fetcher: fetcher,
                directory: context.path.last,
                chainPath: context.path,
                reportTemporalFailure: true
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
        context: ChainRuntimeContext
    ) async -> Result<(StateDiff, LatticeState?), ChainAdmissionFailure> {
        do {
            let validation = try await block.validateNexus(
                fetcher: fetcher,
                chain: chain,
                chainPath: context.path,
                reportTemporalFailure: true
            )
            guard validation.0 else { return .failure(.protocolInvalid) }
            return .success((validation.1, validation.2))
        } catch {
            return .failure(classifyValidationFailure(error))
        }
    }

    static func result(
        for submission: SubmissionResult,
        prepared: PreparedAdmission
    ) -> ChainLocalBlockResult {
        var followUps: [MissingBodyRequest] = []
        if submission.needsParentBlock, let parentHash = prepared.block.parent?.rawCID {
            followUps.append(MissingBodyRequest(
                tipHash: prepared.resolvedHeader.rawCID,
                missingBodies: [parentHash]
            ))
        }
        if let reorganization = submission.reorganization,
           !reorganization.missingBodies.isEmpty {
            merge(MissingBodyRequest(
                tipHash: reorganization.newTipHash,
                missingBodies: reorganization.missingBodies
            ), into: &followUps)
        }

        switch prepared.kind {
        case .evidence:
            return .acceptedEvidence(
                prepared.contribution!,
                reorganization: submission.reorganization,
                evictedBlocks: submission.evictedBlocks,
                followUps: followUps
            )
        case .block(let stateDiff, let state):
            if submission.extendsMainChain || submission.reorganization != nil {
                return .canonicalized(
                    stateDiff,
                    materializedPostState: state,
                    reorganization: submission.reorganization,
                    evictedBlocks: submission.evictedBlocks,
                    followUps: followUps
                )
            }
            return .acceptedSide(
                stateDiff,
                materializedPostState: state,
                evictedBlocks: submission.evictedBlocks,
                followUps: followUps
            )
        case .carrier:
            return .carrier
        }
    }

    private static func merge(
        _ request: MissingBodyRequest,
        into requests: inout [MissingBodyRequest]
    ) {
        guard let index = requests.firstIndex(where: { $0.tipHash == request.tipHash }) else {
            requests.append(request)
            return
        }
        var bodies = requests[index].missingBodies
        for body in request.missingBodies where !bodies.contains(body) {
            bodies.append(body)
        }
        requests[index] = MissingBodyRequest(
            tipHash: request.tipHash,
            missingBodies: bodies
        )
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

    /// Admit one candidate. `stage` is the node-owned durability boundary. It may
    /// run more than once after a stale generation and must be idempotent by fact ID.
    func admitBlockHeaderChainLocal(
        _ blockHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage? = nil,
        storer: any Storer & VolumeStorer,
        stage: @Sendable (ChainAdmissionRecord) async throws -> Void
    ) async throws -> ChainLocalBlockResult {
        while true {
            switch await ChainLocalAdmission.prepare(
                level: self,
                blockHeader: blockHeader,
                fetcher: fetcher,
                childPackage: childPackage
            ) {
            case .stale:
                continue
            case .result(let result):
                return result
            case .ready(let prepared):
                try await prepared.store(to: storer)
                try await stage(prepared.record)
                if case .carrier = prepared.kind { return .carrier }
                guard let contribution = prepared.contribution else { return .carrier }
                let stateDiff: StateDiff
                if case .block(let diff, _) = prepared.kind {
                    stateDiff = diff
                } else {
                    stateDiff = .empty
                }
                guard let submission = await chain.submitBlockIfUnchanged(
                    expectedMutationGeneration: prepared.generation,
                    blockHeader: prepared.resolvedHeader,
                    block: prepared.block,
                    stateDiff: stateDiff,
                    contribution: contribution
                ) else {
                    continue
                }
                if !submission.addedBlock && !submission.addedContribution {
                    return .duplicate
                }
                return ChainLocalAdmission.result(
                    for: submission,
                    prepared: prepared
                )
            }
        }
    }

    func admitBlockHeaderChainLocal(
        _ blockHeader: BlockHeader,
        source: any ContentSource,
        childPackage: ChildValidationPackage? = nil,
        storer: any Storer & VolumeStorer,
        stage: @Sendable (ChainAdmissionRecord) async throws -> Void
    ) async throws -> ChainLocalBlockResult {
        try await admitBlockHeaderChainLocal(
            blockHeader,
            fetcher: CoalescingFetcher(source),
            childPackage: childPackage,
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
        storer: any Storer & VolumeStorer,
        retentionDepth: UInt64 = .max,
        stage: @Sendable (ChainAdmissionRecord) async throws -> Void
    ) async throws -> (level: ChainLevel, stateDiff: StateDiff, materializedPostState: LatticeState?) {
        guard !context.isRoot else { throw ChainAdmissionFailure.protocolInvalid }
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
            childCID: genesisHeader.rawCID,
            context: context
        ) {
        case .success(let verified): evidence = verified
        case .failure(let failure): throw failure
        }
        guard let contribution = evidence.contribution(for: resolved.block) else {
            switch await ChainLocalAdmission.validateCarrierContinuity(
                block: resolved.block,
                fetcher: fetcher
            ) {
            case .failure(let failure): throw failure
            case .success: break
            }
            let carrier = PreparedAdmission(
                generation: 0,
                resolvedHeader: resolved.header,
                block: resolved.block,
                fetcher: fetcher,
                contribution: nil,
                childEvidence: evidence,
                kind: .carrier
            )
            try await carrier.store(to: storer)
            try await stage(carrier.record)
            throw ChainAdmissionFailure.notAcceptedAtCurrentChain
        }
        let transition: (StateDiff, LatticeState?)
        switch await ChainLocalAdmission.validateGenesis(
            block: resolved.block,
            fetcher: fetcher,
            context: context
        ) {
        case .failure(let failure): throw failure
        case .success(let value): transition = value
        }
        let prepared = PreparedAdmission(
            generation: 0,
            resolvedHeader: resolved.header,
            block: resolved.block,
            fetcher: fetcher,
            contribution: contribution,
            childEvidence: evidence,
            kind: .block(transition.0, transition.1)
        )
        try await prepared.store(to: storer)
        try await stage(prepared.record)
        let chain = ChainState.fromVerifiedGenesis(
            block: resolved.block,
            stateDiff: transition.0,
            contribution: contribution,
            retentionDepth: retentionDepth
        )
        return (ChainLevel(chain: chain, context: context), transition.0, transition.1)
    }
}
