import Foundation
import cashew
import LatticePrimitives
import LatticePoW
import LatticeValidation
import LatticeProofs
import LatticeBlockTree

// MARK: - Parent-chain facts

/// What a child chain's execution asks of its parent chain. Both answers are
/// about the parent's EXECUTED SET — every block executed from genesis on any
/// branch, minus excluded subtrees — never about its tip, and both are for
/// the parent chain the link names.
public protocol ParentChainFacts: Sendable {
    /// Whether some block of the parent's executed set, on any branch,
    /// produced `link.toStateCID` (continuity from the parent's genesis).
    func hasContinuity(_ link: ParentStateContinuityLink) -> Bool
    /// Whether a `GenesisAction` in a block of the parent's executed set
    /// authorized exactly `link`.
    func recordsGenesis(_ link: ParentGenesisLink) -> Bool
}

/// A parent level's facts as values: its tree, whose executed set and path
/// answer continuity, and every genesis link its executions reported, keyed
/// by the issuing block. A link is honoured only while an issuer is in the
/// executed set — checked when read, so a block executed ahead of its
/// ancestry authorizes once that ancestry executes, and never once an
/// ancestor is excluded.
public struct ParentLevelFacts: ParentChainFacts {
    public var tree: ChainTree
    /// The parent chain's path: facts answer only for links naming it.
    public let path: [String]?
    public private(set) var genesisIssuers: [ParentGenesisLink: Set<String>]

    /// `path` defaults to the tree's own context.
    public init(
        tree: ChainTree,
        path: [String]? = nil,
        genesisIssuers: [ParentGenesisLink: Set<String>] = [:]
    ) {
        self.tree = tree
        self.path = path ?? tree.context?.path
        self.genesisIssuers = genesisIssuers
    }

    /// Record the genesis links one of the parent's executions reported.
    public mutating func record(_ update: ChainTreeUpdate) {
        for link in update.parentGenesisLinks {
            genesisIssuers[link, default: []].insert(update.blockHash)
        }
    }

    public func hasContinuity(_ link: ParentStateContinuityLink) -> Bool {
        link.parentPath == path
            && link.fromStateCID == LatticeState.emptyHeader.rawCID
            && tree.executedSetProduced(stateCID: link.toStateCID)
    }

    public func recordsGenesis(_ link: ParentGenesisLink) -> Bool {
        guard link.parentPath == path, let issuers = genesisIssuers[link] else {
            return false
        }
        return issuers.contains { tree.hasExecutedAncestry(blockHash: $0) }
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
    /// The block the batches are about.
    public let blockHash: String
    /// The batches the tree applied, in order. The caller MUST persist all of
    /// them in one transaction — a restart must see both or neither;
    /// `ChainTree.restore` rebuilds the tree from them in any order. One
    /// batch, except a header that lands excluded: its block and work, then
    /// its exclusion (a batch carries at most one exclusion and nothing
    /// beside it).
    public let batches: [BlockImportBatch]
    /// Whether this operation excluded the block: a header admitted with its
    /// work but failing a validity rule (§9.9), or an execution that proved
    /// it invalid. Its work still weighs; it is never selected.
    public let excluded: Bool
    /// The canonical change, when the projection moved.
    public let commit: ChainCommit?
    /// The executed post-state (`applyConnect` of a valid block only).
    public let materializedPostState: LatticeState?
    /// The child-genesis links this block's `GenesisAction`s authorize. Only
    /// an executed block issues any: a weighed-only block issues no facts.
    /// A link authorizes a child only while this block is in the executed
    /// set (`ParentLevelFacts.record`).
    public let parentGenesisLinks: [ParentGenesisLink]
}

public enum ChainTreeAdmission: Sendable {
    case applied(ChainTreeUpdate)
    /// Nothing new: no fact was emitted. A re-projection that promoted a
    /// candidate is carried. (Re-connecting an executed block is not this: it
    /// re-emits its validation batch, as the actor path re-stages it, and
    /// replaying that batch is a no-op.)
    case duplicate(promotedCommit: ChainCommit?)
    /// Refused: no fact was emitted and the tree is unchanged. For a header,
    /// only `.proofOfWorkInvalid` blames its sender; `.notYetValid` and
    /// `.unavailableEvidence` are held and retried; anything else is dropped.
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
    /// Nil only for a genesis no grind has been credited to.
    let contribution: VerifiedWorkContribution?
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

/// A chain bootstrapped from its genesis: the tree, and the batches that
/// seeded it — the genesis inserted (`insertGenesis`), then executed
/// (`applyConnect`). The caller MUST persist both in one transaction.
public struct GenesisBootstrap: Sendable {
    public let tree: ChainTree
    public let batches: [BlockImportBatch]
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

    /// Weigh one block of a ROOT chain from its header, credited with its
    /// own proof-of-work (`rootWork`): its hash meets its own target. See
    /// `insertHeader`.
    public mutating func insertRootHeader(
        _ block: Block,
        childIndex: ChildIndex,
        validationContext: ValidationContext = .current
    ) -> ChainTreeAdmission {
        guard let context else { return .rejected(.notAcceptedAtCurrentChain) }
        guard let blockHash = try? BlockHeader(node: block).rawCID else {
            return .rejected(.proofOfWorkInvalid)
        }
        guard context.isRoot else {
            return .rejected(.crossChainEvidenceRequired(.childProof(
                chainPath: context.path, childCID: blockHash
            )))
        }
        guard let work = BlockImport.rootWork(of: block, blockHash: blockHash) else {
            return .rejected(.proofOfWorkInvalid)
        }
        return insertHeader(
            block, blockHash: blockHash, childIndex: childIndex,
            work: work, validationContext: validationContext
        )
    }

    /// Weigh one block of a CHILD chain from its header, credited with the
    /// work of a verified child proof of exactly this block
    /// (`ChildBlockProof.verifySecuringWork` for this chain's path). See
    /// `insertHeader`. The proof is verified by the caller, and its failures
    /// classify by `headerFailure`. Evidence whose
    /// grind misses the child's own target yields no contribution: a
    /// proof-of-work failure here.
    public mutating func insertChildHeader(
        _ block: Block,
        childIndex: ChildIndex,
        evidence: VerifiedChildEvidence,
        validationContext: ValidationContext = .current
    ) -> ChainTreeAdmission {
        guard let context else { return .rejected(.notAcceptedAtCurrentChain) }
        guard !context.isRoot else { return .rejected(.protocolInvalid) }
        guard let blockHash = try? BlockHeader(node: block).rawCID,
              CIDIdentity.canonicalString(evidence.childCID) == blockHash,
              let work = evidence.contribution else {
            return .rejected(.proofOfWorkInvalid)
        }
        return insertHeader(
            block, blockHash: blockHash, childIndex: childIndex,
            work: work, validationContext: validationContext
        )
    }

    /// How header admission treats a failed `verifySecuringWork`: a CID or
    /// byte mismatch, or an undecodable path, is a proof-of-work failure
    /// (blame); a child `parentState` that is not its carrier's `prevState`
    /// is structural (drop, no blame).
    public static func headerFailure(
        _ failure: ChildProofVerificationFailure
    ) -> BlockImportError {
        switch failure {
        case .malformedEvidence: .proofOfWorkInvalid
        case .protocolInvalid: .protocolInvalid
        case .crossChainEvidenceRequired(let requirement):
            .crossChainEvidenceRequired(requirement)
        }
    }

    /// Weigh one block from its header, synchronously (§9.9 header
    /// admission). `childIndex` is the block's own (bound by CID): run
    /// attribution reads what it does NOT commit. `work` is its verified
    /// grind. Linkage reads the parent from this tree — excluded or not — and
    /// the target schedule from its root's spec. A block already held takes
    /// `addWork`.
    ///
    /// - Weighed: the block fact (declared post-state, empty diff, child
    ///   commitments) and its work fact.
    /// - Weighed and excluded: the same, then its exclusion — for
    ///   `spec != parent.spec` or `prevState != parent.postState`. Its work
    ///   weighs; it is never selected.
    /// - `.proofOfWorkInvalid` (blame): no work, or off the schedule
    ///   (`timestamp <= parent.timestamp`, or the target).
    /// - `.notYetValid` / `.unavailableEvidence` (hold): a timestamp in this
    ///   node's future, an unknown parent, or a difficulty anchor not in hand.
    /// - Anything else (drop, no blame): version, height, the child-index
    ///   binding, a malformed reward recipient, a genesis.
    ///
    /// No validation and no cross-chain fact: a weighed-only block issues
    /// none.
    private mutating func insertHeader(
        _ block: Block,
        blockHash: String,
        childIndex: ChildIndex,
        work contribution: VerifiedWorkContribution,
        validationContext: ValidationContext
    ) -> ChainTreeAdmission {
        guard contribution.work > .zero else {
            return .rejected(.proofOfWorkInvalid)
        }
        guard block.hasWellFormedRewardRecipient else {
            return .rejected(.protocolInvalid)
        }
        if contains(blockHash: blockHash) {
            return addWork(contribution, to: blockHash)
        }
        guard acceptsWorkLocation(of: contribution.id, at: blockHash) else {
            return .rejected(.providerMalformedEvidence)
        }
        // A genesis is never weighed from a header: only `insertGenesis`
        // admits a root.
        guard let parentHash = block.parent?.rawCID else {
            return .rejected(.protocolInvalid)
        }
        guard let parent = headerSnapshot(of: parentHash) else {
            return .rejected(.unavailableEvidence)
        }
        // The schedule is the root's spec's, whatever the parent declares.
        guard let spec = scheduleSpec(underParent: parentHash) else {
            return .rejected(.notAcceptedAtCurrentChain)
        }
        guard (try? HeaderImpl<ChildIndex>(node: childIndex).rawCID)
                == block.children.rawCID else {
            return .rejected(.protocolInvalid)
        }
        let admission: HeaderAdmission
        do {
            admission = try block.headerAdmission(
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
                validationContext: validationContext
            )
        } catch {
            return .rejected(classifyValidationFailure(error))
        }
        let weighed = BlockImport.admissionFacts(
            blockHash: blockHash,
            block: block,
            contribution: contribution,
            kind: .block(.empty, nil, validated: false),
            childCommitments: childIndex.entries.mapValues(\.rawCID)
        )
        switch admission {
        case .malformed: return .rejected(.protocolInvalid)
        case .offSchedule: return .rejected(.proofOfWorkInvalid)
        case .linked: return applyAdmission([weighed], of: blockHash)
        case .excluded:
            return applyAdmission(
                [weighed, BlockImport.exclusionFacts(blockHash: blockHash)],
                of: blockHash,
                excluded: true
            )
        }
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
        return applyAdmission([BlockImportBatch.staged([
            .work(ChainWorkFact(blockHash: hash, contribution: contribution)),
        ])], of: hash)
    }

    /// Capture what executing a held block needs, so `connect` can run off
    /// the tree, on the tree's own chain. The validation batch re-states one
    /// grind the tree holds for the block: `grind` when named, else the
    /// strongest. Nil for a block this tree does not hold, a grind it does
    /// not hold there, a non-genesis block with no grind, or a tree made
    /// without a context. A genesis needs no grind: it has no work of its own.
    public mutating func connectJob(
        for blockHash: String,
        grind: String? = nil
    ) -> ConnectJob? {
        guard let context,
              let hash = CIDIdentity.canonicalString(blockHash),
              contains(blockHash: hash) else { return nil }
        let held = grind.map { workContribution(id: $0, at: hash) } ?? strongestGrind(of: hash)
        let contribution: VerifiedWorkContribution?
        if let held {
            contribution = held
        } else if grind == nil, parentHash(of: hash) == nil {
            contribution = nil
        } else {
            return nil
        }
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
            guard block.height == 0 else {
                return verdict(.invalid(isGenesis: true))
            }
            // A child genesis is executed only once authorized: a
            // `GenesisAction` for exactly this genesis in a block of the
            // parent's executed set (`parentFacts.recordsGenesis`). Asked
            // before execution, so an unauthorized root costs nothing to hold.
            // A root chain's genesis is authorized by the node's configured
            // genesis CID, outside this tree.
            if !context.isRoot,
               let failure = BlockImport.validateParentFacts(
                   BlockImport.parentFactLookup(parentFacts),
                   child: block,
                   childCID: job.blockHash,
                   context: context
               ),
               !BlockImport.isDeterministicInvalidity(failure) {
                return verdict(.retry(failure))
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
        let commitments: [String: String]?
        if let recorded = job.recordedChildCommitments {
            commitments = recorded
        } else if isGenesis {
            // A genesis's commitments are not recorded, by the bootstrap
            // convention every genesis fact has always followed.
            commitments = nil
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
    /// holds, the verdict is refused as `.notYetValid`. Execution is never
    /// revoked: an invalid verdict for a block already executed contradicts
    /// a recorded fact, so it is refused as `.localVerificationFailure` — a
    /// local fault for the node to surface, never an exclusion.
    public mutating func applyConnect(_ verdict: ConnectVerdict) -> ChainTreeAdmission {
        let blockHash = verdict.blockHash
        switch verdict.outcome {
        case .retry(let failure):
            return .rejected(failure)
        case .invalid(let isGenesis):
            guard !isExecuted(blockHash: blockHash) else {
                return .rejected(.localVerificationFailure)
            }
            guard contains(blockHash: blockHash),
                  !isGenesis || hasExecutedRoot(besides: blockHash) else {
                return .rejected(.notYetValid)
            }
            return applyAdmission(
                [BlockImport.exclusionFacts(blockHash: blockHash)],
                of: blockHash,
                excluded: true
            )
        case .valid(let facts, let materializedPostState, let genesisLinks):
            guard contains(blockHash: blockHash) else {
                return .rejected(.notYetValid)
            }
            // An executed root re-executed adds nothing: the actor path stages
            // nothing for a held genesis either.
            if parentHash(of: blockHash) == nil, isExecuted(blockHash: blockHash) {
                return .duplicate(promotedCommit: nil)
            }
            return applyAdmission(
                [facts],
                of: blockHash,
                materializedPostState: materializedPostState,
                parentGenesisLinks: genesisLinks
            )
        }
    }

    /// Insert a genesis root into the weighed graph (§9.9 genesis
    /// admission). A genesis has no work of its own (§5.1): no proof-of-work
    /// or target is checked, and it weighs through its descendants' work and
    /// any proof later credited to it (`addWork`). Authorization is not
    /// asked here: an unauthorized root weighs like any other and enters the
    /// executed set only through `connect` once its parent authorizes it.
    ///
    /// Proof of content: `block` is the genesis itself — its CID is computed
    /// from it, so the bytes are their own proof — and `spec` must be the
    /// spec its `spec` field names by CID (otherwise
    /// `.providerMalformedEvidence`). The tree holds that spec as this root's
    /// (`specs`), and every header under the root is scheduled by it.
    ///
    /// - Applied: one batch, the genesis's block fact alone (empty diff, child
    ///   commitments not recorded until execution). No work fact, no
    ///   validation, no cross-chain fact: a weighed-only block issues none.
    /// - Duplicate: the root is already held.
    /// - `.protocolInvalid` (drop): not a genesis (a parent, or a height),
    ///   a malformed reward recipient, or header fields that do not decode
    ///   (a zero target).
    public mutating func insertGenesis(
        _ block: Block,
        spec: ChainSpec
    ) -> ChainTreeAdmission {
        guard context != nil else { return .rejected(.notAcceptedAtCurrentChain) }
        guard let blockHash = try? BlockHeader(node: block).rawCID else {
            return .rejected(.providerMalformedEvidence)
        }
        guard block.parent == nil, block.height == 0,
              block.hasWellFormedRewardRecipient else {
            return .rejected(.protocolInvalid)
        }
        guard ChainTree.binds(spec, to: block.spec.rawCID) else {
            return .rejected(.providerMalformedEvidence)
        }
        if contains(blockHash: blockHash) {
            return .duplicate(promotedCommit: reevaluateForkChoice())
        }
        let facts = BlockImport.admissionFacts(
            blockHash: blockHash,
            block: block,
            contribution: nil,
            kind: .block(.empty, nil, validated: false),
            childCommitments: nil
        )
        // The fact must decode as a root before the spec is held, so a
        // refused genesis leaves the tree unchanged.
        guard ChainTree.decodesAsGenesis(facts) else {
            return .rejected(.protocolInvalid)
        }
        _ = holdSpec(spec, for: block.spec.rawCID)
        return applyAdmission([facts], of: blockHash)
    }

    /// Bootstrap a chain from its genesis: an empty tree, `insertGenesis`,
    /// then `connect` and `applyConnect` — the one path every root takes.
    /// A child genesis must be authorized by `parentFacts`
    /// (`.crossChainEvidenceRequired(.parentGenesis)` otherwise); an invalid
    /// one is `.protocolInvalid`.
    public static func bootstrap(
        genesis genesisHeader: BlockHeader,
        fetcher: any Fetcher,
        context: ChainRuntimeContext,
        parentFacts: (any ParentChainFacts)? = nil,
        validationContext: ValidationContext = .current
    ) async -> Result<GenesisBootstrap, BlockImportError> {
        let block: Block
        switch await BlockImport.resolveBlock(genesisHeader, fetcher: fetcher) {
        case .failure(let failure): return .failure(failure)
        case .success(let resolved): block = resolved.block
        }
        guard let spec = try? await block.spec.resolve(fetcher: fetcher).node else {
            return .failure(.unavailableEvidence)
        }
        var tree = ChainTree.empty(context: context)
        guard let inserted = tree.insertGenesis(block, spec: spec).update else {
            return .failure(.protocolInvalid)
        }
        guard let job = tree.connectJob(for: inserted.blockHash) else {
            return .failure(.localVerificationFailure)
        }
        let verdict = await connect(
            job,
            fetcher: fetcher,
            parentFacts: parentFacts,
            validationContext: validationContext
        )
        if let failure = verdict.retryFailure { return .failure(failure) }
        if verdict.provesInvalid { return .failure(.protocolInvalid) }
        guard let executed = tree.applyConnect(verdict).update,
              case .valid(let facts, _, _) = verdict.outcome else {
            return .failure(.localVerificationFailure)
        }
        let stateDiff = facts.facts.lazy.compactMap { fact -> StateDiff? in
            if case .block(let value) = fact { return value.stateDiff }
            return nil
        }.first ?? .empty
        return .success(GenesisBootstrap(
            tree: tree,
            batches: inserted.batches + executed.batches,
            stateDiff: stateDiff,
            materializedPostState: executed.materializedPostState
        ))
    }

    /// Apply the batches this API derived, in order, reporting what they
    /// emitted and the net canonical change. A batch that changed no weight
    /// (a validation of a held block) still re-projects, since execution can
    /// make a heavier candidate selectable.
    private mutating func applyAdmission(
        _ batches: [BlockImportBatch],
        of blockHash: String,
        excluded: Bool = false,
        materializedPostState: LatticeState? = nil,
        parentGenesisLinks: [ParentGenesisLink] = []
    ) -> ChainTreeAdmission {
        // All or nothing: every batch here is one consensus mutation, so the
        // capacity for all of them is checked before the first is applied.
        guard hasMutationCapacity(for: UInt64(batches.count)) else {
            return .rejected(.revisionExhausted)
        }
        var commit: ChainCommit?
        for facts in batches {
            let submission: SubmissionResult?
            do {
                submission = try apply(facts)
            } catch {
                return .rejected(.localVerificationFailure)
            }
            let next = submission == nil ? reevaluateForkChoice() : submission?.commit
            commit = ChainCommit.composing(commit, then: next)
        }
        return .applied(ChainTreeUpdate(
            blockHash: blockHash,
            batches: batches,
            excluded: excluded,
            commit: commit,
            materializedPostState: materializedPostState,
            parentGenesisLinks: parentGenesisLinks
        ))
    }
}

extension ChainCommit {
    /// The net change of `first` then `second` against the projection before
    /// `first`: a block one added and the other removed moved nowhere.
    static func composing(_ first: ChainCommit?, then second: ChainCommit?) -> ChainCommit? {
        guard let first else { return second }
        guard let second else { return first }
        var added = first.canonicalBlocksAdded.filter {
            !second.canonicalBlocksRemoved.contains($0.key)
        }
        for (hash, height) in second.canonicalBlocksAdded
        where !first.canonicalBlocksRemoved.contains(hash) {
            added[hash] = height
        }
        let removed = first.canonicalBlocksRemoved
            .subtracting(second.canonicalBlocksAdded.keys)
            .union(second.canonicalBlocksRemoved.subtracting(first.canonicalBlocksAdded.keys))
        return ChainCommit(
            revision: second.revision,
            tipHash: second.tipHash,
            canonicalBlocksAdded: added,
            canonicalBlocksRemoved: removed
        )
    }
}
