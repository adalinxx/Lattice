import Foundation
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
/// observations together; later work or a stronger observation appends another
/// immutable fact.
public struct ChainAdmissionBatch: Codable, Sendable, Equatable {
    public let facts: [ChainAdmissionFact]

    init(facts: [ChainAdmissionFact]) {
        self.facts = facts
    }
}

/// The verified, node-owned facts that must become durable with one admission
/// batch. They are deliberately separate from ``ChainAdmissionBatch``: chain
/// replay needs only consensus facts, while the node also needs these facts to
/// relay hierarchy evidence after a restart.
public struct ChainAdmissionStagingContext: Sendable {
    public let batch: ChainAdmissionBatch
    /// Present only when this chain has verified a complete ancestry for the
    /// carrier and may issue a parent-process fact for it.
    public let issuedCarrierLink: ParentCarrierLink?
    /// Child-genesis actions carried by this admission. They become issuer
    /// facts only when `issuedCarrierLink` is present; retaining them lets a
    /// commit atomically observe a predecessor that connected after preflight.
    public let parentGenesisLinks: [ParentGenesisLink]

    init(
        batch: ChainAdmissionBatch,
        issuedCarrierLink: ParentCarrierLink?,
        parentGenesisLinks: [ParentGenesisLink]
    ) {
        self.batch = batch
        self.issuedCarrierLink = issuedCarrierLink
        self.parentGenesisLinks = parentGenesisLinks
    }
}

public struct ChainAcceptance: Sendable {
    public let facts: ChainAdmissionBatch
    public let materializedPostState: LatticeState?
    public let commit: ChainCommit
    public let sameChainPredecessor: SameChainPredecessorRequirement?
    public let parentCarrierLink: ParentCarrierLink?

    public var stateDiff: StateDiff? {
        for case .block(let fact) in facts.facts { return fact.stateDiff }
        return nil
    }
}

public enum ChainLocalBlockResult: Sendable {
    case accepted(ChainAcceptance)
    case carrier(
        ParentCarrierLink?,
        sameChainPredecessor: SameChainPredecessorRequirement? = nil
    )
    case duplicate(
        ParentCarrierLink?,
        sameChainPredecessor: SameChainPredecessorRequirement? = nil
    )
    case rejected(
        ChainAdmissionFailure,
        parentCarrierLink: ParentCarrierLink? = nil,
        sameChainPredecessor: SameChainPredecessorRequirement? = nil
    )

    public var materializedPostState: LatticeState? {
        switch self {
        case .accepted(let acceptance): acceptance.materializedPostState
        case .carrier, .duplicate, .rejected: nil
        }
    }

    public var sameChainPredecessor: SameChainPredecessorRequirement? {
        switch self {
        case .accepted(let acceptance): acceptance.sameChainPredecessor
        case .carrier(_, let requirement),
             .duplicate(_, let requirement),
             .rejected(_, _, let requirement): requirement
        }
    }

    public var crossChainEvidenceRequirement: CrossChainEvidenceRequirement? {
        guard case .rejected(
            .crossChainEvidenceRequired(let requirement), _, _
        ) = self else {
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
        if case .rejected(let failure, _, _) = self { return failure }
        return nil
    }

    public var parentCarrierLink: ParentCarrierLink? {
        switch self {
        case .accepted(let acceptance): acceptance.parentCarrierLink
        case .carrier(let link, _), .duplicate(let link, _): link
        case .rejected(_, let link, _): link
        }
    }

}

public struct ChildChainBootstrapAcceptance: Sendable {
    public let level: ChainLevel
    public let stateDiff: StateDiff
    public let materializedPostState: LatticeState?
    public let commit: ChainCommit
    public let parentCarrierLink: ParentCarrierLink
}

public enum ChildChainBootstrapResult: Sendable {
    case accepted(ChildChainBootstrapAcceptance)
    case carrier(ParentCarrierLink)
    case rejected(
        ChainAdmissionFailure,
        parentCarrierLink: ParentCarrierLink
    )

    public var parentCarrierLink: ParentCarrierLink {
        switch self {
        case .accepted(let acceptance): acceptance.parentCarrierLink
        case .carrier(let link), .rejected(_, let link): link
        }
    }

    public var failure: ChainAdmissionFailure? {
        guard case .rejected(let failure, _) = self else { return nil }
        return failure
    }
}

fileprivate struct PreparedAdmission: Sendable {
    enum Kind: Sendable {
        case block(StateDiff, LatticeState?)
        case evidence
    }

    let resolvedHeader: BlockHeader
    let block: Block
    let fetcher: any Fetcher
    let contribution: VerifiedWorkContribution
    let carrierLink: ParentCarrierLink
    let verifiedCarrierLink: ParentCarrierLink?
    let sameChainPredecessor: SameChainPredecessorRequirement?
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

    /// Store the immutable validation Volumes before the node takes its
    /// durability lease. They remain unretained until the admission batch
    /// becomes visible.
    func cacheValidationContent(
        to validationContentStorer: any VolumeStorer
    ) async throws {
        switch kind {
        case .evidence:
            return
        case .block:
            try await resolvedHeader.storeBlock(
                fetcher: fetcher,
                storer: validationContentStorer
            )
        }
    }

    /// Materialized state is a complete Volume and can be evicted until it is
    /// retained with the staged batch. The node must therefore invoke this
    /// immediately before its retention-and-stage boundary.
    func storeMaterializedPostState(
        to materializedVolumeStorer: any VolumeStorer
    ) async throws {
        guard case .block(let stateDiff, let materializedPostState) = kind,
              let materializedPostState else {
            return
        }
        try await LatticeStateHeader(node: materializedPostState)
            .storeMaterialized(
                createdBy: stateDiff,
                storer: materializedVolumeStorer
            )
    }

    /// The stage callback runs before `ChainState` applies `facts`, so this is
    /// the only point where Lattice can pass the already-verified hierarchy
    /// facts across the node durability boundary without reconstructing them.
    func stagingContext() async throws -> ChainAdmissionStagingContext {
        let batch = facts
        return ChainAdmissionStagingContext(
            batch: batch,
            issuedCarrierLink: verifiedCarrierLink,
            parentGenesisLinks: try await parentGenesisLinks(
                in: resolvedHeader,
                parentPath: carrierLink.parentPath,
                parentStateCID: block.prevState.rawCID,
                fetcher: fetcher
            )
        )
    }
}

fileprivate enum Preparation {
    case ready(PreparedAdmission)
    case result(
        ChainLocalBlockResult,
        parentGenesisLinks: [ParentGenesisLink] = []
    )
    case duplicate(PreparedDuplicateAdmissionState)
}

public enum ChainAdmissionPreflightError: Error, Sendable, Equatable {
    case invalidToken
}

/// A one-use, level-bound result of remote validation and validation-Volume
/// storage.
public actor PreparedChainAdmission {
    /// Commit may add an issuable carrier link if the already-validated
    /// predecessor connected before the durability boundary.
    fileprivate nonisolated let stagingContext: ChainAdmissionStagingContext

    private let levelIdentity: UUID
    private var prepared: PreparedAdmission?

    fileprivate init(
        levelIdentity: UUID,
        prepared: PreparedAdmission,
        stagingContext: ChainAdmissionStagingContext
    ) {
        self.levelIdentity = levelIdentity
        self.prepared = prepared
        self.stagingContext = stagingContext
    }

    fileprivate func take(for levelIdentity: UUID) -> PreparedAdmission? {
        guard self.levelIdentity == levelIdentity else { return nil }
        defer { prepared = nil }
        return prepared
    }
}

fileprivate struct PreparedDuplicateAdmissionState: Sendable {
    let carrierLink: ParentCarrierLink
    let parentGenesisLinks: [ParentGenesisLink]
}

/// A one-use, level-bound duplicate whose immutable validation completed before
/// the node acquired its mutation lease. Resolving it under that lease can add
/// a carrier link when a predecessor connected in the meantime; it never
/// stages consensus facts or reacquires remote content.
public actor PreparedDuplicateAdmission {
    private let levelIdentity: UUID
    private var state: PreparedDuplicateAdmissionState?

    fileprivate init(
        levelIdentity: UUID,
        state: PreparedDuplicateAdmissionState
    ) {
        self.levelIdentity = levelIdentity
        self.state = state
    }

    fileprivate func take(
        for levelIdentity: UUID
    ) -> PreparedDuplicateAdmissionState? {
        guard self.levelIdentity == levelIdentity else { return nil }
        defer { state = nil }
        return state
    }
}

public enum ChainAdmissionPreflightResult: Sendable {
    case terminal(
        ChainLocalBlockResult,
        parentGenesisLinks: [ParentGenesisLink] = []
    )
    case duplicate(PreparedDuplicateAdmission)
    case ready(PreparedChainAdmission)
}

private func parentGenesisLinks(
    in header: BlockHeader,
    parentPath: [String],
    parentStateCID: String,
    fetcher: any Fetcher
) async throws -> [ParentGenesisLink] {
    let content = try await header.resolveBlockContent(fetcher: fetcher)
    guard let transactions = content.node?.transactions.node else {
        throw DataErrors.nodeNotAvailable
    }
    var links = Set<ParentGenesisLink>()
    for transaction in try transactions.allKeysAndValues().values {
        guard let body = transaction.node?.body.node else {
            throw DataErrors.nodeNotAvailable
        }
        for action in body.genesisActions {
            links.insert(ParentGenesisLink(
                parentPath: parentPath,
                directory: action.directory,
                childGenesisCID: action.blockCID,
                parentStateCID: parentStateCID
            ))
        }
    }
    return links.sorted {
        ($0.directory, $0.childGenesisCID, $0.parentStateCID)
            < ($1.directory, $1.childGenesisCID, $1.parentStateCID)
    }
}

private enum ChainLocalAdmission {
    static func verifyChildProof(
        _ package: ChildValidationPackage,
        child: Block,
        context: ChainRuntimeContext
    ) async -> Result<VerifiedChildEvidence, ChainAdmissionFailure> {
        await package.proof.verifySecuringWork(
            child: child,
            chainPath: context.path
        ).mapError { failure -> ChainAdmissionFailure in
            switch failure {
            case .crossChainEvidenceRequired(let requirement):
                .crossChainEvidenceRequired(requirement)
            case .malformedEvidence: .providerMalformedEvidence
            case .protocolInvalid: .protocolInvalid
            }
        }
    }

    static func validateParentFacts(
        _ package: ChildValidationPackage,
        child: Block,
        childCID: String,
        context: ChainRuntimeContext,
        fetcher: any Fetcher
    ) async -> ChainAdmissionFailure? {
        let parentPath = Array(context.path.dropLast())
        if child.parent == nil {
            guard child.hasGenesisAdmissionShape() else {
                return .protocolInvalid
            }
            guard package.parentStateContinuityLink == nil,
                  let directory = context.path.last else {
                return .providerMalformedEvidence
            }
            guard let genesis = package.parentGenesisLink else {
                return .crossChainEvidenceRequired(.parentGenesis(
                    parentPath: parentPath,
                    directory: directory,
                    childGenesisCID: childCID,
                    parentStateCID: child.parentState.rawCID
                ))
            }
            guard genesis == ParentGenesisLink(
                parentPath: parentPath,
                directory: directory,
                childGenesisCID: childCID,
                parentStateCID: child.parentState.rawCID
            ) else {
                return .providerMalformedEvidence
            }
            return nil
        }

        guard package.parentGenesisLink == nil,
              let predecessorHeader = child.parent else {
            return .providerMalformedEvidence
        }
        let predecessor: Block
        switch await resolveBlock(predecessorHeader, fetcher: fetcher) {
        case .success(let resolved):
            predecessor = resolved.block
        case .failure(let failure):
            return failure
        }
        let fromStateCID = predecessor.parentState.rawCID
        let toStateCID = child.parentState.rawCID
        if fromStateCID == toStateCID {
            guard package.parentStateContinuityLink == nil else {
                return .providerMalformedEvidence
            }
            return nil
        }

        let expected = ParentStateContinuityLink(
            parentPath: parentPath,
            fromStateCID: fromStateCID,
            toStateCID: toStateCID
        )
        guard let link = package.parentStateContinuityLink else {
            return .crossChainEvidenceRequired(.parentStateContinuity(
                parentPath: parentPath,
                fromStateCID: fromStateCID,
                toStateCID: toStateCID
            ))
        }
        guard link == expected else {
            return .providerMalformedEvidence
        }
        return nil
    }

    static func prepare(
        level: ChainLevel,
        blockHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage?,
        validationContext: ValidationContext
    ) async -> Preparation {
        let context = level.context
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
        let knownBlock = await level.chain.contains(blockHash: blockHash)

        let grindID: String
        let contribution: VerifiedWorkContribution?
        if context.isRoot {
            guard childPackage == nil else {
                return .result(.rejected(.protocolInvalid))
            }
            let rootHash = block.proofOfWorkHash()
            grindID = blockHash
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
            switch await verifyChildProof(
                childPackage,
                child: block,
                context: context
            ) {
            case .success(let verified):
                grindID = verified.grindID
                contribution = verified.contribution
            case .failure(let failure):
                return .result(.rejected(failure))
            }
        }
        let carrierLink = ParentCarrierLink(
            parentPath: context.path,
            carrierCID: blockHash,
            rootCID: grindID
        )

        let carrier = await deriveCarrierLink(
            candidate: carrierLink,
            blockHash: blockHash,
            block: block,
            level: level
        )

        guard let contribution else {
            return .result(.carrier(
                carrier.relayLink,
                sameChainPredecessor: nil
            ))
        }

        if let existing = await level.chain.workContribution(
            id: contribution.id,
            at: blockHash
        ), existing.work >= contribution.work {
            if knownBlock {
                // A predecessor can connect after preflight but before the
                // node takes its mutation lease. Keep this duplicate's
                // immutable evidence so the lease can recheck only ancestry.
                let genesisLinks: [ParentGenesisLink]
                do {
                    genesisLinks = try await parentGenesisLinks(
                        in: resolvedHeader,
                        parentPath: carrierLink.parentPath,
                        parentStateCID: block.prevState.rawCID,
                        fetcher: fetcher
                    )
                } catch {
                    return .result(.rejected(
                        classifyValidationFailure(error),
                        sameChainPredecessor: carrier.sameChainPredecessor
                    ))
                }
                return .duplicate(PreparedDuplicateAdmissionState(
                    carrierLink: carrierLink,
                    parentGenesisLinks: genesisLinks
                ))
            }
            return .result(.duplicate(
                carrier.relayLink,
                sameChainPredecessor: carrier.sameChainPredecessor
            ))
        }

        if knownBlock {
            return .ready(PreparedAdmission(
                resolvedHeader: resolvedHeader,
                block: block,
                fetcher: fetcher,
                contribution: contribution,
                carrierLink: carrierLink,
                verifiedCarrierLink: carrier.issuableLink,
                sameChainPredecessor: carrier.sameChainPredecessor,
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
            return .result(.rejected(
                failure,
                parentCarrierLink: carrier.relayLink,
                sameChainPredecessor: carrier.sameChainPredecessor
            ))
        case .success(let (stateDiff, state)):
            if !context.isRoot, let childPackage,
               let failure = await validateParentFacts(
                   childPackage,
                   child: block,
                   childCID: blockHash,
                   context: context,
                   fetcher: fetcher
               ) {
                return .result(.rejected(
                    failure,
                    parentCarrierLink: carrier.relayLink,
                    sameChainPredecessor: carrier.sameChainPredecessor
                ))
            }
            return .ready(PreparedAdmission(
                resolvedHeader: resolvedHeader,
                block: block,
                fetcher: fetcher,
                contribution: contribution,
                carrierLink: carrierLink,
                verifiedCarrierLink: carrier.issuableLink,
                sameChainPredecessor: carrier.sameChainPredecessor,
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
            guard let canonicalCID = try? BlockHeader(node: block).rawCID,
                  canonicalCID == resolved.rawCID else {
                return .failure(.providerMalformedEvidence)
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

    /// A real grind may carry descendant work even when this block is invalid
    /// or disconnected on its own chain. Connectivity is requested separately
    /// only so this process can still try ordinary block admission.
    static func deriveCarrierLink(
        candidate: ParentCarrierLink,
        blockHash: String,
        block: Block,
        level: ChainLevel
    ) async -> (
        relayLink: ParentCarrierLink,
        issuableLink: ParentCarrierLink?,
        sameChainPredecessor: SameChainPredecessorRequirement?
    ) {
        if await level.chain.hasValidatedAncestry(blockHash: blockHash) {
            return (candidate, candidate, nil)
        }
        guard let predecessorCID = block.parent?.rawCID else {
            return (
                candidate,
                level.context.isRoot ? nil : candidate,
                nil
            )
        }
        let predecessorIsConnected = await level.chain.hasValidatedAncestry(
            blockHash: predecessorCID
        )
        guard !predecessorIsConnected else {
            return (candidate, candidate, nil)
        }
        return (candidate, nil, SameChainPredecessorRequirement(
            descendantCID: blockHash,
            predecessorCID: predecessorCID
        ))
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
        carrierLink: ParentCarrierLink,
        transition: (StateDiff, LatticeState?),
        validationContentStorer: any VolumeStorer,
        materializedVolumeStorer: any VolumeStorer,
        stage: @Sendable (ChainAdmissionStagingContext) async throws -> Void
    ) async throws -> (
        level: ChainLevel,
        stateDiff: StateDiff,
        materializedPostState: LatticeState?,
        commit: ChainCommit,
        parentCarrierLink: ParentCarrierLink
    ) {
        let prepared = PreparedAdmission(
            resolvedHeader: resolved.header,
            block: resolved.block,
            fetcher: fetcher,
            contribution: contribution,
            carrierLink: carrierLink,
            verifiedCarrierLink: carrierLink,
            sameChainPredecessor: nil,
            kind: .block(transition.0, transition.1)
        )
        try await prepared.cacheValidationContent(to: validationContentStorer)
        let stagingContext = try await prepared.stagingContext()
        try await prepared.storeMaterializedPostState(
            to: materializedVolumeStorer
        )
        try await stage(stagingContext)
        let chain = try await ChainState.restore(replaying: [prepared.facts])
        return (
            ChainLevel(chain: chain, context: context),
            transition.0,
            transition.1,
            ChainCommit(
                tipHash: resolved.header.rawCID,
                mainChainBlocksAdded: [resolved.header.rawCID: 0]
            ),
            carrierLink
        )
    }

    static func result(
        for submission: SubmissionResult,
        prepared: PreparedAdmission,
        sameChainPredecessor: SameChainPredecessorRequirement?,
        parentCarrierLink: ParentCarrierLink?
    ) -> ChainLocalBlockResult {
        guard let commit = submission.commit else {
            return .duplicate(
                parentCarrierLink,
                sameChainPredecessor: sameChainPredecessor
            )
        }
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
            sameChainPredecessor: sameChainPredecessor,
            parentCarrierLink: parentCarrierLink
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
    /// Verify one candidate and store its immutable validation Volumes without
    /// mutating the accepted graph. The returned token contains the exact
    /// hierarchy facts the node must make durable with the batch.
    func preflightBlockHeaderChainLocal(
        _ blockHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage? = nil,
        validationContext: ValidationContext = .current,
        validationContentStorer: any VolumeStorer
    ) async throws -> ChainAdmissionPreflightResult {
        switch await ChainLocalAdmission.prepare(
            level: self,
            blockHeader: blockHeader,
            fetcher: fetcher,
            childPackage: childPackage,
            validationContext: validationContext
        ) {
        case .result(let result, let parentGenesisLinks):
            return .terminal(
                result,
                parentGenesisLinks: parentGenesisLinks
            )
        case .duplicate(let duplicate):
            return .duplicate(PreparedDuplicateAdmission(
                levelIdentity: admissionIdentity,
                state: duplicate
            ))
        case .ready(let prepared):
            try await prepared.cacheValidationContent(
                to: validationContentStorer
            )
            let stagingContext = try await prepared.stagingContext()
            return .ready(PreparedChainAdmission(
                levelIdentity: admissionIdentity,
                prepared: prepared,
                stagingContext: stagingContext
            ))
        }
    }

    /// Resolve an already-validated duplicate at the node's mutation boundary.
    /// Accepted ancestry only grows, so this rechecks no remote content and
    /// writes no consensus facts.
    func resolveDuplicatePreflight(
        _ preflight: PreparedDuplicateAdmission
    ) async throws -> (
        result: ChainLocalBlockResult,
        parentGenesisLinks: [ParentGenesisLink]
    ) {
        guard let duplicate = await preflight.take(for: admissionIdentity) else {
            throw ChainAdmissionPreflightError.invalidToken
        }
        let isConnected = await chain.hasValidatedAncestry(
            blockHash: duplicate.carrierLink.carrierCID
        )
        let requirement = await chain.sameChainPredecessorRequirement(
            for: duplicate.carrierLink.carrierCID
        )
        return (
            .duplicate(
                duplicate.carrierLink,
                sameChainPredecessor: requirement
            ),
            isConnected ? duplicate.parentGenesisLinks : []
        )
    }

    /// Consume a preflight token at the node-owned durability boundary. This
    /// method performs no remote resolution: callers can take their mutation
    /// lease immediately before invoking it.
    func commitPreflight(
        _ preflight: PreparedChainAdmission,
        materializedVolumeStorer: any VolumeStorer,
        stage: @Sendable (ChainAdmissionStagingContext) async throws -> Void
    ) async throws -> ChainLocalBlockResult {
        guard let prepared = await preflight.take(for: admissionIdentity) else {
            throw ChainAdmissionPreflightError.invalidToken
        }
        try await prepared.storeMaterializedPostState(
            to: materializedVolumeStorer
        )
        guard await chain.reserveAdmissionRevision() else {
            return .rejected(
                .revisionExhausted,
                parentCarrierLink: prepared.carrierLink,
                sameChainPredecessor: prepared.sameChainPredecessor
            )
        }
        let stagingContext: ChainAdmissionStagingContext
        if preflight.stagingContext.issuedCarrierLink != nil {
            stagingContext = preflight.stagingContext
        } else if let parentCID = prepared.block.parent?.rawCID,
                  await chain.hasValidatedAncestry(blockHash: parentCID) {
            stagingContext = ChainAdmissionStagingContext(
                batch: preflight.stagingContext.batch,
                issuedCarrierLink: prepared.carrierLink,
                parentGenesisLinks: preflight.stagingContext.parentGenesisLinks
            )
        } else {
            stagingContext = preflight.stagingContext
        }
        do {
            try await stage(stagingContext)
        } catch {
            await chain.releaseAdmissionRevision()
            throw error
        }
        let submission = try await chain.applyReservedStaged(prepared.facts)
        let requirement = await chain.sameChainPredecessorRequirement(
            for: prepared.resolvedHeader.rawCID
        )
        guard let submission else {
            return .duplicate(
                prepared.carrierLink,
                sameChainPredecessor: requirement
            )
        }
        return ChainLocalAdmission.result(
            for: submission,
            prepared: prepared,
            sameChainPredecessor: requirement,
            parentCarrierLink: prepared.carrierLink
        )
    }

    /// The node-owned atomic durability boundary. The context contains the
    /// exact hierarchy facts Lattice verified for this admission, so callers do
    /// not need to recreate them after the batch has become durable.
    func admitBlockHeaderChainLocal(
        _ blockHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage? = nil,
        validationContext: ValidationContext = .current,
        validationContentStorer: any VolumeStorer,
        materializedVolumeStorer: any VolumeStorer,
        stage: @Sendable (ChainAdmissionStagingContext) async throws -> Void
    ) async throws -> ChainLocalBlockResult {
        switch try await preflightBlockHeaderChainLocal(
            blockHeader,
            fetcher: fetcher,
            childPackage: childPackage,
            validationContext: validationContext,
            validationContentStorer: validationContentStorer
        ) {
        case .terminal(let result, _):
            return result
        case .duplicate(let preflight):
            return try await resolveDuplicatePreflight(preflight).result
        case .ready(let preflight):
            return try await commitPreflight(
                preflight,
                materializedVolumeStorer: materializedVolumeStorer,
                stage: stage
            )
        }
    }

    func admitBlockHeaderChainLocal(
        _ blockHeader: BlockHeader,
        source: any ContentSource,
        childPackage: ChildValidationPackage? = nil,
        validationContext: ValidationContext = .current,
        validationContentStorer: any VolumeStorer,
        materializedVolumeStorer: any VolumeStorer,
        stage: @Sendable (ChainAdmissionStagingContext) async throws -> Void
    ) async throws -> ChainLocalBlockResult {
        try await admitBlockHeaderChainLocal(
            blockHeader,
            fetcher: CoalescingFetcher(source),
            childPackage: childPackage,
            validationContext: validationContext,
            validationContentStorer: validationContentStorer,
            materializedVolumeStorer: materializedVolumeStorer,
            stage: stage
        )
    }

    /// Root bootstrap variant that stages verified hierarchy facts atomically
    /// with the first admission batch.
    static func bootstrap(
        context: ChainRuntimeContext,
        genesisHeader: BlockHeader,
        fetcher: any Fetcher,
        validationContext: ValidationContext = .current,
        validationContentStorer: any VolumeStorer,
        materializedVolumeStorer: any VolumeStorer,
        stage: @Sendable (ChainAdmissionStagingContext) async throws -> Void
    ) async throws -> (
        level: ChainLevel,
        stateDiff: StateDiff,
        materializedPostState: LatticeState?,
        commit: ChainCommit,
        parentCarrierLink: ParentCarrierLink
    ) {
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
        guard resolved.block.validateProofOfWork(nexusHash: rootHash) else {
            throw ChainAdmissionFailure.notAcceptedAtCurrentChain
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
            carrierLink: ParentCarrierLink(
                parentPath: context.path,
                carrierCID: resolved.header.rawCID,
                rootCID: resolved.header.rawCID
            ),
            transition: transition,
            validationContentStorer: validationContentStorer,
            materializedVolumeStorer: materializedVolumeStorer,
            stage: stage
        )
    }

    /// Child bootstrap variant that stages verified hierarchy facts atomically
    /// with the first admission batch.
    static func bootstrap(
        context: ChainRuntimeContext,
        genesisHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage,
        validationContext: ValidationContext = .current,
        validationContentStorer: any VolumeStorer,
        materializedVolumeStorer: any VolumeStorer,
        stage: @Sendable (ChainAdmissionStagingContext) async throws -> Void
    ) async throws -> ChildChainBootstrapResult {
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
        switch await ChainLocalAdmission.verifyChildProof(
            childPackage,
            child: resolved.block,
            context: context
        ) {
        case .success(let verified): evidence = verified
        case .failure(let failure): throw failure
        }
        let carrierLink = ParentCarrierLink(
            parentPath: context.path,
            carrierCID: resolved.header.rawCID,
            rootCID: evidence.grindID
        )
        if let failure = await ChainLocalAdmission.validateParentFacts(
            childPackage,
            child: resolved.block,
            childCID: evidence.childCID,
            context: context,
            fetcher: fetcher
        ) {
            return .rejected(failure, parentCarrierLink: carrierLink)
        }
        guard let contribution = evidence.contribution else {
            return .carrier(carrierLink)
        }
        let transition: (StateDiff, LatticeState?)
        switch await ChainLocalAdmission.validateGenesis(
            block: resolved.block,
            fetcher: fetcher,
            context: context,
            validationContext: validationContext
        ) {
        case .failure(let failure):
            return .rejected(failure, parentCarrierLink: carrierLink)
        case .success(let value): transition = value
        }
        let accepted = try await ChainLocalAdmission.finishBootstrap(
            context: context,
            resolved: resolved,
            fetcher: fetcher,
            contribution: contribution,
            carrierLink: carrierLink,
            transition: transition,
            validationContentStorer: validationContentStorer,
            materializedVolumeStorer: materializedVolumeStorer,
            stage: stage
        )
        return .accepted(ChildChainBootstrapAcceptance(
            level: accepted.level,
            stateDiff: accepted.stateDiff,
            materializedPostState: accepted.materializedPostState,
            commit: accepted.commit,
            parentCarrierLink: accepted.parentCarrierLink
        ))
    }
}
