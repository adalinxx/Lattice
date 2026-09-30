import Foundation
import cashew
import LatticePrimitives
import LatticePoW
import LatticeValidation
import LatticeProofs
import LatticeBlockTree

// MARK: - Parent-chain facts

/// What a child chain's execution asks of its parent chain. Both answers are
/// about the parent's EXECUTED SET — every state it executed from genesis on
/// any branch, minus excluded subtrees — never about its tip.
public protocol ParentChainFacts: Sendable {
    /// Whether some block of the parent's executed set, on any branch,
    /// produced `stateCID`.
    func executedSetProduced(stateCID: String) -> Bool
    /// Whether a `GenesisAction` in an executed parent block authorized
    /// exactly `link`.
    func recordsGenesis(_ link: ParentGenesisLink) -> Bool
}

/// A parent level's facts as values: its tree, whose executed set answers
/// continuity, and the genesis links its executed blocks issued
/// (`ChainTreeUpdate.parentGenesisLinks` of each `applyConnect`).
public struct ParentLevelFacts: ParentChainFacts {
    public let tree: ChainTree
    public let genesisLinks: Set<ParentGenesisLink>

    public init(tree: ChainTree, genesisLinks: Set<ParentGenesisLink> = []) {
        self.tree = tree
        self.genesisLinks = genesisLinks
    }

    public func executedSetProduced(stateCID: String) -> Bool {
        tree.executedSetProduced(stateCID: stateCID)
    }

    public func recordsGenesis(_ link: ParentGenesisLink) -> Bool {
        genesisLinks.contains(link)
    }
}

/// One parent fact a child's execution needs, and how a source answers it.
enum ParentFactQuery: Sendable {
    case genesis(ParentGenesisLink)
    case continuity(ParentStateContinuityLink)
    /// The block commits no parent state: no fact may be offered for it.
    case none
}

enum ParentFactAnswer: Sendable, Equatable {
    case present
    case absent
    case malformed
}

typealias ParentFactLookup = @Sendable (ParentFactQuery) -> ParentFactAnswer

// MARK: - Results

/// What one admission operation applied to a `ChainTree`.
public struct ChainTreeUpdate: Sendable {
    /// The batch the tree applied: the same fact bytes the actor admission
    /// path stages for the same block. Durable storage of it is the caller's;
    /// `ChainTree.replay` rebuilds the tree from it.
    public let facts: BlockImportBatch
    /// The canonical change, when the projection moved.
    public let commit: ChainCommit?
    /// The executed post-state (`applyConnect` of a valid block only).
    public let materializedPostState: LatticeState?
    /// The child-genesis links this block's `GenesisAction`s authorize. Only
    /// an executed block issues any: a weighed-only block issues no facts.
    public let parentGenesisLinks: [ParentGenesisLink]
}

public enum ChainTreeAdmission: Sendable {
    case applied(ChainTreeUpdate)
    /// Nothing new: no fact was emitted. A re-projection that promoted a
    /// candidate is carried.
    case duplicate(promotedCommit: ChainCommit?)
    /// Refused: no fact was emitted and the tree is unchanged.
    case rejected(BlockImportError)

    public var update: ChainTreeUpdate? {
        if case .applied(let update) = self { return update }
        return nil
    }

    public var failure: BlockImportError? {
        if case .rejected(let failure) = self { return failure }
        return nil
    }
}

/// The inputs of one execution, captured from the tree so the execution can
/// run off it: the block, the chain it is on, the grind its batch re-states,
/// the commitments already recorded, and the parent's difficulty anchor.
public struct ConnectJob: Sendable {
    public let blockHash: String
    public let context: ChainRuntimeContext
    let contribution: VerifiedWorkContribution
    let recordedChildCommitments: [String: String]?
    let anchors: AnchorSnapshot
}

/// The difficulty anchors a job captured. Asked for anything else it has
/// none, which validation reports as `AnchorUnavailable`.
struct AnchorSnapshot: DifficultyAnchorSource {
    let anchors: [String: DifficultyAnchor]

    func difficultyAnchor(forBlockHash hash: String) async -> DifficultyAnchor? {
        anchors[hash]
    }
}

/// The result of `ChainTree.connect`: a verdict to apply with
/// `applyConnect`, or a non-verdict to retry.
public struct ConnectVerdict: Sendable {
    enum Outcome: Sendable {
        case valid(BlockImportBatch, LatticeState?, [ParentGenesisLink])
        /// Execution completed and proved the block invalid.
        case invalid(isGenesis: Bool)
        /// No verdict (availability, ordering, missing parent facts).
        case retry(BlockImportError)
    }

    public let blockHash: String
    let outcome: Outcome

    /// Whether execution completed and proved the block invalid.
    public var provesInvalid: Bool {
        if case .invalid = outcome { return true }
        return false
    }

    /// The non-verdict failure, when execution could not decide.
    public var retryFailure: BlockImportError? {
        if case .retry(let failure) = outcome { return failure }
        return nil
    }
}

/// A chain bootstrapped from its genesis, with the one batch that seeds it.
public struct GenesisBootstrap: Sendable {
    public let tree: ChainTree
    public let facts: BlockImportBatch
    public let stateDiff: StateDiff
    public let materializedPostState: LatticeState?
}

// MARK: - Operations

extension ChainTree {
    /// A root block's own grind — its proof-of-work against its own target —
    /// or nil when the hash misses it. A child block's grind comes from
    /// `ChildBlockProof.verifySecuringWork` instead.
    public static func rootWork(of block: Block) -> VerifiedWorkContribution? {
        guard let blockHash = try? BlockHeader(node: block).rawCID else { return nil }
        return BlockImport.rootWork(of: block, blockHash: blockHash)
    }

    /// Weigh one block from its header: the `.header` admission tier as a
    /// synchronous mutation. `spec` and `childIndex` are the block's own
    /// (bound by CID); `work` is its verified grind. Linkage reads the parent
    /// from this tree, so the parent must be held. A block already held takes
    /// `addWork`. Emits the block fact (declared post-state, empty diff, child
    /// commitments) and its work fact — no validation, and no cross-chain
    /// fact: a weighed-only block issues none.
    public mutating func insertHeader(
        _ block: Block,
        spec: ChainSpec,
        childIndex: ChildIndex,
        work contribution: VerifiedWorkContribution,
        validationContext: ValidationContext = .current
    ) -> ChainTreeAdmission {
        guard let blockHash = try? BlockHeader(node: block).rawCID else {
            return .rejected(.localVerificationFailure)
        }
        guard block.hasWellFormedRewardRecipient else {
            return .rejected(.protocolInvalid)
        }
        if contains(blockHash: blockHash) {
            return addWork(contribution, to: blockHash)
        }
        guard contribution.work > .zero else {
            return .rejected(.notAcceptedAtCurrentChain)
        }
        guard acceptsWorkLocation(of: contribution.id, at: blockHash) else {
            return .rejected(.providerMalformedEvidence)
        }
        // A genesis is never weighed: only bootstrap admits one.
        guard let parentHash = block.parent?.rawCID,
              block.version == Block.currentVersion else {
            return .rejected(.protocolInvalid)
        }
        guard let parent = headerSnapshot(of: parentHash) else {
            return .rejected(.unavailableEvidence)
        }
        guard (try? VolumeImpl<ChainSpec>(node: spec).rawCID) == block.spec.rawCID,
              (try? HeaderImpl<ChildIndex>(node: childIndex).rawCID)
                  == block.children.rawCID else {
            return .rejected(.providerMalformedEvidence)
        }
        do {
            let linked = try block.validateHeaderLinkage(
                parent: HeaderLinkageParent(
                    height: parent.tipHeight,
                    timestamp: parent.timestamp,
                    target: parent.target,
                    nextTarget: parent.nextTarget,
                    postStateCID: parent.postStateCID,
                    specCID: parent.specCID
                ),
                spec: spec,
                inheritedAnchor: { difficultyAnchor(forBlockHash: parentHash) },
                reportTemporalFailure: true,
                validationContext: validationContext
            )
            guard linked else { return .rejected(.protocolInvalid) }
        } catch {
            return .rejected(classifyValidationFailure(error))
        }
        return applyAdmission(BlockImport.admissionFacts(
            blockHash: blockHash,
            block: block,
            contribution: contribution,
            kind: .block(.empty, nil, validated: false),
            childCommitments: childIndex.entries.mapValues(\.rawCID)
        ))
    }

    /// Credit another grind to a held block (the `.evidence` tier). A grind
    /// already credited at least as strongly is a duplicate; a grind located
    /// on another block is refused, since a grind has one location. Emits a
    /// work fact alone.
    public mutating func addWork(
        _ contribution: VerifiedWorkContribution,
        to blockHash: String
    ) -> ChainTreeAdmission {
        guard let hash = CIDIdentity.canonicalString(blockHash),
              contains(blockHash: hash) else {
            return .rejected(.unavailableEvidence)
        }
        guard contribution.work > .zero else {
            return .rejected(.notAcceptedAtCurrentChain)
        }
        if let existing = workContribution(id: contribution.id, at: hash),
           existing.work >= contribution.work {
            return .duplicate(promotedCommit: reevaluateForkChoice())
        }
        guard acceptsWorkLocation(of: contribution.id, at: hash) else {
            return .rejected(.providerMalformedEvidence)
        }
        return applyAdmission(BlockImportBatch.staged([
            .work(ChainWorkFact(blockHash: hash, contribution: contribution)),
        ]))
    }

    /// Capture what executing a held block needs, so `connect` can run off
    /// the tree. Nil for a block this tree does not hold.
    public mutating func connectJob(
        for blockHash: String,
        context: ChainRuntimeContext
    ) -> ConnectJob? {
        guard let hash = CIDIdentity.canonicalString(blockHash),
              contains(blockHash: hash),
              let contribution = strongestGrind(of: hash) else { return nil }
        var anchors: [String: DifficultyAnchor] = [:]
        if let parentHash = parentHash(of: hash),
           let anchor = difficultyAnchor(forBlockHash: parentHash) {
            anchors[parentHash] = anchor
        }
        return ConnectJob(
            blockHash: hash,
            context: context,
            contribution: contribution,
            recordedChildCommitments: recordedChildCommitments(of: hash),
            anchors: AnchorSnapshot(anchors: anchors)
        )
    }

    /// Execute a job's block: the `.execution` tier's work, pure and off the
    /// tree. A child's parent facts are read from `parentFacts` (nil knows
    /// nothing, so a child block that needs one gets no verdict). Apply the
    /// result with `applyConnect`.
    public static func connect(
        _ job: ConnectJob,
        fetcher: any Fetcher,
        parentFacts: (any ParentChainFacts)? = nil,
        validationContext: ValidationContext = .current
    ) async -> ConnectVerdict {
        func verdict(_ outcome: ConnectVerdict.Outcome) -> ConnectVerdict {
            ConnectVerdict(blockHash: job.blockHash, outcome: outcome)
        }
        let context = job.context
        let resolvedHeader: BlockHeader
        let block: Block
        switch await BlockImport.resolveBlock(
            BlockHeader(rawCID: job.blockHash),
            fetcher: fetcher
        ) {
        case .success(let resolved):
            resolvedHeader = resolved.header
            block = resolved.block
        case .failure(let failure):
            return verdict(.retry(failure))
        }
        let isGenesis = block.parent == nil
        func rejected(_ failure: BlockImportError) -> ConnectVerdict {
            BlockImport.isDeterministicInvalidity(failure)
                ? verdict(.invalid(isGenesis: isGenesis))
                : verdict(.retry(failure))
        }
        if isGenesis {
            guard !context.isRoot, block.height == 0 else {
                return verdict(.invalid(isGenesis: true))
            }
        }
        let transition: BlockImport.ExecutedTransition
        switch await BlockImport.executeTransition(
            block: block,
            blockHash: job.blockHash,
            fetcher: fetcher,
            chain: job.anchors,
            parentFacts: context.isRoot
                ? nil : BlockImport.parentFactLookup(parentFacts),
            context: context,
            validationContext: validationContext
        ) {
        case .failure(let failure): return rejected(failure)
        case .success(let value): transition = value
        }
        let commitments: [String: String]
        if let recorded = job.recordedChildCommitments {
            commitments = recorded
        } else {
            switch await BlockImport.childCommitments(of: resolvedHeader, fetcher: fetcher) {
            case .success(let enumerated): commitments = enumerated
            case .failure(let failure): return rejected(failure)
            }
        }
        let genesisLinks: [ParentGenesisLink]
        do {
            genesisLinks = try await parentGenesisLinks(
                in: resolvedHeader,
                parentPath: context.path,
                fetcher: fetcher
            )
        } catch {
            // Issuance only, never a verdict on the block.
            return verdict(.retry(.unavailableEvidence))
        }
        return verdict(.valid(
            BlockImport.admissionFacts(
                blockHash: job.blockHash,
                block: block,
                contribution: job.contribution,
                kind: .block(
                    transition.stateDiff,
                    transition.materializedPostState,
                    validated: true
                ),
                childCommitments: commitments
            ),
            transition.materializedPostState,
            genesisLinks
        ))
    }

    /// Apply a `connect` verdict. A valid block emits its validation batch
    /// and joins the executed set; a proven-invalid one emits its exclusion,
    /// its work still weighing. A root may be excluded only while another
    /// executed root stands; otherwise, like a block this tree no longer
    /// holds, the verdict is refused as `.notYetValid`.
    public mutating func applyConnect(_ verdict: ConnectVerdict) -> ChainTreeAdmission {
        let blockHash = verdict.blockHash
        switch verdict.outcome {
        case .retry(let failure):
            return .rejected(failure)
        case .invalid(let isGenesis):
            guard contains(blockHash: blockHash),
                  !isGenesis || hasExecutedRoot(besides: blockHash) else {
                return .rejected(.notYetValid)
            }
            return applyAdmission(BlockImport.exclusionFacts(blockHash: blockHash))
        case .valid(let facts, let materializedPostState, let genesisLinks):
            guard contains(blockHash: blockHash) else {
                return .rejected(.notYetValid)
            }
            return applyAdmission(
                facts,
                materializedPostState: materializedPostState,
                parentGenesisLinks: genesisLinks
            )
        }
    }

    /// Bootstrap a chain from its genesis: resolve, a child genesis's shape
    /// and parent authorization (a genesis link `parentFacts` records), its
    /// own proof-of-work, execution — then the tree seeded by the one batch.
    public static func bootstrap(
        genesis genesisHeader: BlockHeader,
        fetcher: any Fetcher,
        context: ChainRuntimeContext,
        parentFacts: (any ParentChainFacts)? = nil,
        validationContext: ValidationContext = .current
    ) async -> Result<GenesisBootstrap, BlockImportError> {
        switch await BlockImport.prepareGenesis(
            context: context,
            genesisHeader: genesisHeader,
            fetcher: fetcher,
            authorizes: { parentFacts?.recordsGenesis($0) == true },
            validationContext: validationContext
        ) {
        case .unresolved(let failure), .invalid(let failure):
            return .failure(failure)
        case .notGenesis:
            return .failure(.protocolInvalid)
        case .unauthorized:
            return .failure(.providerMalformedEvidence)
        case .noWork:
            return .failure(.notAcceptedAtCurrentChain)
        case .ready(let resolved, let contribution, let transition):
            let facts = BlockImport.admissionFacts(
                blockHash: resolved.header.rawCID,
                block: resolved.block,
                contribution: contribution,
                kind: .block(
                    transition.stateDiff,
                    transition.materializedPostState,
                    validated: true
                ),
                childCommitments: nil
            )
            guard let tree = try? ChainTree.restore(replaying: [facts]) else {
                return .failure(.localVerificationFailure)
            }
            return .success(GenesisBootstrap(
                tree: tree,
                facts: facts,
                stateDiff: transition.stateDiff,
                materializedPostState: transition.materializedPostState
            ))
        }
    }

    /// Apply a batch this API derived, reporting what it emitted. A batch
    /// that changed no weight (a validation of a held block) still re-projects,
    /// since execution can make a heavier candidate selectable.
    private mutating func applyAdmission(
        _ facts: BlockImportBatch,
        materializedPostState: LatticeState? = nil,
        parentGenesisLinks: [ParentGenesisLink] = []
    ) -> ChainTreeAdmission {
        let submission: SubmissionResult?
        do {
            submission = try apply(facts)
        } catch {
            return .rejected(.localVerificationFailure)
        }
        let commit = submission == nil ? reevaluateForkChoice() : submission?.commit
        return .applied(ChainTreeUpdate(
            facts: facts,
            commit: commit,
            materializedPostState: materializedPostState,
            parentGenesisLinks: parentGenesisLinks
        ))
    }
}
