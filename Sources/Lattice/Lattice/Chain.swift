import cashew
import CID
import UInt256

/// Compute proof-of-work for a given target threshold.
/// Higher target value = easier proof; work is inversely proportional.
///
/// Proof validity is INCLUSIVE (`hash <= target`), so `target + 1` hashes satisfy
/// it (`0...target`) and the expected number of tries to find one is
/// `2^256 / (target + 1)`. This is Bitcoin's chainwork, `(~target / (target+1)) + 1`,
/// in 256-bit arithmetic. The exclusive `2^256 / target` form over-credits by up
/// to ~2x at tiny targets (e.g. target 1 has two valid hashes but would be scored
/// ~2^256 instead of 2^255) — exploitable now that a miner may select any
/// `target <= parent.nextTarget`. For realistic (huge) targets the two agree to
/// within one unit.
public func workForTarget(_ target: UInt256) -> UInt256 {
    guard target > UInt256.zero else { return UInt256.zero }
    guard target < UInt256.max else { return UInt256(1) }
    return (UInt256.max - target) / (target + UInt256(1)) + UInt256(1)
}

/// Work demonstrated by one observed hash. This is used for the setup-wide
/// traversal floor, which is deliberately independent of any chain target.
///
/// The root-work test is inclusive (`observedHash <= threshold`), so a hash `h`
/// demonstrates the same work as a target of `h`: `2^256 / (h + 1)`, the
/// inclusive form used by `workForTarget`. The old exclusive `2^256 / h`
/// over-credited by up to ~2x at tiny hashes (hash 1 scored ~2^256 rather than
/// its true ~2^255). Saturating edges: hash 0 is the single smallest output
/// (maximal work, clamped to `.max`); hash `.max` is trivially met (one unit).
public func workForHash(_ hash: UInt256) -> UInt256 {
    guard hash > UInt256.zero else { return UInt256.max }
    guard hash < UInt256.max else { return UInt256(1) }
    return (UInt256.max - hash) / (hash + UInt256(1)) + UInt256(1)
}

/// Stable tie-break for equal-work same-chain child blocks. Compare the CID
/// bytes rather than an encoded presentation string; malformed values remain
/// deterministic so persistence validation can reject them without
/// order-dependent behavior.
public func forkChoicePrefersBlock(
    _ candidateHash: String,
    over currentHash: String
) -> Bool {
    let candidateBytes = (try? CID(candidateHash))?.rawBuffer
    let currentBytes = (try? CID(currentHash))?.rawBuffer
    switch (candidateBytes, currentBytes) {
    case let (candidate?, current?):
        return candidate.lexicographicallyPrecedes(current)
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    case (nil, nil):
        return candidateHash < currentHash
    }
}

public typealias BlockHeader = VolumeImpl<Block>

public enum ChainStateRestoreError: Error, Sendable, Equatable {
    case corruptConsensusGraph
    case missingBlockFact
}

// MARK: - Concrete Types

/// The block the difficulty schedule is measured from: height 1 of this block's
/// OWN ancestry, carried forward so it costs nothing to reach.
///
/// Not genesis, because a genesis timestamp measures nothing — no one mined
/// before block 1 — and a chain that stamps genesis far before its first block
/// would read that gap as one enormous solve time.
///
/// Not a single chain-wide value either. Block 1 can be reorged like any other
/// block, and a chain-wide anchor would then change under every block already
/// built on it, retroactively altering targets that were already validated. An
/// anchor that belongs to the block's own ancestry cannot: two branches forking
/// at height 1 simply carry two anchors, each branch internally consistent,
/// which is exactly what such a reorg means.
public struct DifficultyAnchor: Sendable, Equatable {
    public let blockHeight: UInt64
    public let timestamp: Int64
    public let target: UInt256

    public init(blockHeight: UInt64, timestamp: Int64, target: UInt256) {
        self.blockHeight = blockHeight
        self.timestamp = timestamp
        self.target = target
    }
}

public struct BlockMeta: Sendable {
    public let blockHash: String
    public let parentBlockHash: String?
    public let blockHeight: UInt64
    /// Inherited from the parent, or self at height 1. Absent on genesis, which
    /// precedes the anchor and has no schedule to be measured against.
    ///
    /// Derived, like `cumulativeWork` and `subtreeWeight` beside it: a pure
    /// function of this block's ancestry, rebuildable by walking to height 1.
    /// Carried rather than walked only so reaching it is O(1) instead of O(chain).
    public private(set) var difficultyAnchor: DifficultyAnchor?
    public private(set) var work: WorkSum
    public var childHashes: [String]
    public private(set) var workContributions: [String: VerifiedWorkContribution]
    /// Directory → child block CID this block commits, read from its PoW-bound
    /// `children` trie at admission and carried on the durable block fact, so
    /// live admission and replay see the same commitments (§9.10).
    public private(set) var childCommitments: [String: String]
    /// Directory → the nearest block at or above this one, by parent pointer,
    /// that commits into that directory — this block itself where it commits.
    /// Held only for the directories this node SERVES runs for (the child
    /// chains it hosts — an operator choice), so it costs O(#served) per
    /// block, never O(#directories ever committed); inherited from the parent
    /// like `difficultyAnchor`, and empty until the block is connected.
    public private(set) var nearestCommitter: [String: String]

    /// Backward cumulative proof-of-work prefix measure from genesis through
    /// this block. Each physical grind has one block location in this chain.
    ///
    /// This is a derived diagnostic, rebuilt on demand from durable block work
    /// facts after recovery. It is never a fork-choice input or persisted
    /// source of truth.
    public private(set) var cumulativeWork: WorkSum

    /// The forward same-chain subtree measure, deduplicated by physical grind.
    /// This derived diagnostic is rebuilt on demand from accepted work facts.
    public private(set) var subtreeWeight: WorkSum

    package init(
        blockHash: String,
        parentBlockHash: String?,
        blockHeight: UInt64,
        childHashes: [String],
        workContributions: [VerifiedWorkContribution],
        cumulativeWork: WorkSum = .zero,
        subtreeWeight: WorkSum? = nil,
        difficultyAnchor: DifficultyAnchor? = nil,
        childCommitments: [String: String] = [:],
        nearestCommitter: [String: String] = [:]
    ) {
        let contributions = Dictionary(
            workContributions.map { ($0.id, $0) },
            uniquingKeysWith: { first, second in
                first.work >= second.work ? first : second
            }
        )
        let work = WorkMeasure(contributions.values).total
        self.blockHash = blockHash
        self.parentBlockHash = parentBlockHash
        self.blockHeight = blockHeight
        self.work = work
        self.childHashes = childHashes
        self.workContributions = contributions
        self.cumulativeWork = cumulativeWork
        self.subtreeWeight = subtreeWeight ?? work
        self.difficultyAnchor = difficultyAnchor
        self.childCommitments = childCommitments
        self.nearestCommitter = nearestCommitter
    }

    /// Settle the nearest committers once the block is connected.
    mutating func adoptNearestCommitter(_ nearest: [String: String]) {
        nearestCommitter = nearest
    }

    /// Fill an anchor left absent by out-of-order admission. Write-once: the
    /// anchor is a function of ancestry, which never changes for a given block,
    /// so a second value would mean the ancestry was misread.
    mutating func adoptDifficultyAnchor(_ anchor: DifficultyAnchor) {
        guard difficultyAnchor == nil else { return }
        difficultyAnchor = anchor
    }

    /// Internal-only: `ChainState` rebuilds this derived cache.
    mutating func setCumulativeWork(_ value: WorkSum) {
        cumulativeWork = value
    }

    /// Internal-only: `ChainState` rebuilds this derived cache.
    mutating func setSubtreeWeight(_ value: WorkSum) {
        subtreeWeight = value
    }

    mutating func setWorkContribution(_ contribution: VerifiedWorkContribution) -> Bool {
        if let existing = workContributions[contribution.id],
           existing.work >= contribution.work {
            return false
        }
        if let existing = workContributions[contribution.id] {
            work = work.subtracting(WorkSum(existing.work))!
        }
        workContributions[contribution.id] = contribution
        work = work + contribution.work
        return true
    }

}

/// What a parent serves a child about one of its blocks that commits into a
/// child directory (§9.10): the RUN work at that block, the block's own
/// credited work, and the revision the pair was read at, for provenance.
///
/// The run is the sum of own credited work over every connected parent block
/// whose nearest committer into `directory` — by parent pointer, never by
/// canonical chain — is `blockHash`. Runs partition the graph, so each parent
/// grind is in exactly one run and a fork below the committer puts each branch
/// in its own branch's run: nothing missed, nothing counted twice. Insert-only
/// and never revoked. Served in O(1).
public struct ParentRunReport: Sendable, Equatable {
    /// The committing parent block.
    public let blockHash: String
    public let directory: String
    /// The child block `blockHash` commits into `directory` — what the child
    /// binds the report to before reading any number.
    public let childBlock: String
    /// Every grind credited at the committer; the child requires one of them
    /// at `childBlock`, which is what makes the committer a committer of it.
    public let grinds: Set<String>
    public let runWork: WorkSum
    public let ownWork: WorkSum
    public let revision: UInt64
}

/// The identity under which a parent's attributed run work is credited at a
/// child block: keyed by the committing parent block and the directory — one
/// run, one identity — so a committer mined under several grinds is credited
/// once, not once per grind. A SEPARATE identity from any grind, deliberately:
/// crediting the run by strengthening the grind itself is not idempotent (the
/// second identical report would count the first attribution as the child's
/// own price and add it again), whereas a separate contribution ratchets on
/// its own value.
public struct AttributedRunIdentity: Hashable, Scalar {
    public let committerBlockHash: String
    public let directory: String

    public init(committerBlockHash: String, directory: String) {
        self.committerBlockHash = committerBlockHash
        self.directory = directory
    }

    public var contributionID: String? {
        try? HeaderImpl<AttributedRunIdentity>(node: self).rawCID
    }
}

/// The outcome of applying a parent's run report to a child block. Refusals
/// are typed so the node can make them VISIBLE: a parent whose reports keep
/// being refused is the likeliest symptom of a parent-side accounting bug, and
/// a silent refusal is exactly what would hide it.
public enum ParentReportStrengthening: Sendable, Equatable {
    /// Stage this work-only batch durably, then apply it.
    case strengthened(ChainAdmissionBatch)
    /// The report does not name this child block, or none of the committer's
    /// grinds is credited here — so the reported block is not a committer of
    /// this child block as far as this chain knows.
    case notCommitterOfChild
    /// The report is for another directory: a parent committing into several
    /// directories serves one run per directory, and only this chain's own
    /// may be applied here.
    case wrongDirectory
    /// `ownWork` exceeds `runWork`, which no honest run can do.
    case malformedReport
    /// The derived quantity exceeds what one contribution can carry. Refused
    /// rather than saturated: a saturated value ties with every other and
    /// erases the ordering fork choice needs (§9.2).
    case unrepresentable(derived: WorkSum)
    /// Not a strict increase over what the child already holds. Monotonic
    /// refusal: a report may only ever raise.
    case notStronger(existing: WorkSum, derived: WorkSum)
}

struct WorkContributionRecord: Sendable, Equatable {
    let blockHash: String
    var contribution: VerifiedWorkContribution
    var isRouted: Bool

    init(
        blockHash: String,
        contribution: VerifiedWorkContribution,
        isRouted: Bool = false
    ) {
        self.blockHash = blockHash
        self.contribution = contribution
        self.isRouted = isRouted
    }
}

private struct StateTransition: Hashable {
    let from: String
    let to: String
}

public struct SubmissionResult: Sendable {
    public let addedBlock: Bool
    public let addedContribution: Bool
    public let extendsMainChain: Bool
    public let commit: ChainCommit?

    init(
        addedBlock: Bool,
        addedContribution: Bool = false,
        extendsMainChain: Bool,
        commit: ChainCommit? = nil
    ) {
        self.addedBlock = addedBlock
        self.addedContribution = addedContribution
        self.extendsMainChain = extendsMainChain
        self.commit = commit
    }

    public static func discarded() -> Self {
        SubmissionResult(
            addedBlock: false,
            addedContribution: false,
            extendsMainChain: false
        )
    }
}

public struct ChainCommit: Sendable, Equatable {
    public let revision: UInt64
    public let tipHash: String
    public let mainChainBlocksAdded: [String: UInt64]
    public let mainChainBlocksRemoved: Set<String>

    public init(
        revision: UInt64 = 0,
        tipHash: String,
        mainChainBlocksAdded: [String: UInt64] = [:],
        mainChainBlocksRemoved: Set<String> = []
    ) {
        self.revision = revision
        self.tipHash = tipHash
        self.mainChainBlocksAdded = mainChainBlocksAdded
        self.mainChainBlocksRemoved = mainChainBlocksRemoved
    }

    public var canonicalChanged: Bool {
        !mainChainBlocksAdded.isEmpty || !mainChainBlocksRemoved.isEmpty
    }

    func atRevision(_ revision: UInt64) -> ChainCommit {
        ChainCommit(
            revision: revision,
            tipHash: tipHash,
            mainChainBlocksAdded: mainChainBlocksAdded,
            mainChainBlocksRemoved: mainChainBlocksRemoved
        )
    }
}

// MARK: - ChainState

public struct TipBlockSnapshot: Sendable, Equatable {
    public let postStateCID: String
    public let prevStateCID: String
    public let specCID: String
    public let target: UInt256
    public let nextTarget: UInt256
    public let tipHeight: UInt64
    public let timestamp: Int64

    public init(postStateCID: String, prevStateCID: String, specCID: String, target: UInt256, nextTarget: UInt256, tipHeight: UInt64, timestamp: Int64) {
        self.postStateCID = postStateCID
        self.prevStateCID = prevStateCID
        self.specCID = specCID
        self.target = target
        self.nextTarget = nextTarget
        self.tipHeight = tipHeight
        self.timestamp = timestamp
    }
}

/// The graph fields Lattice needs after admission has already authenticated a
/// block. This deliberately excludes the block body and node-owned state data.
private struct ConsensusBlockInput: Sendable {
    let blockHash: String
    let parentBlockHash: String?
    let blockHeight: UInt64
    let timestamp: Int64
    let snapshot: TipBlockSnapshot
    let childCommitments: [String: String]

    /// Requires an EXECUTED block.
    init(blockHeader: BlockHeader, block: Block) {
        blockHash = blockHeader.rawCID
        parentBlockHash = block.parent?.rawCID
        blockHeight = block.height
        timestamp = block.timestamp
        childCommitments = [:]
        snapshot = TipBlockSnapshot(
            postStateCID: block.postState.rawCID,
            prevStateCID: block.prevState.rawCID,
            specCID: block.spec.rawCID,
            target: block.target,
            nextTarget: block.nextTarget,
            tipHeight: block.height,
            timestamp: block.timestamp
        )
    }

    init?(fact: ChainBlockFact) {
        guard let blockHash = CIDIdentity.canonicalString(fact.blockHash),
              let postStateCID = CIDIdentity.canonicalString(fact.postStateCID),
              let prevStateCID = CIDIdentity.canonicalString(fact.prevStateCID),
              let specCID = CIDIdentity.canonicalString(fact.specCID),
              let target = UInt256(fact.target, radix: 16),
              let nextTarget = UInt256(fact.nextTarget, radix: 16),
              // Every block, genesis included, must commit a positive target and
              // nextTarget: genesis must satisfy its own target (h <= target), so a
              // zero target — which no hash meets — is not admissible.
              target > .zero, nextTarget > .zero,
              (fact.parentBlockHash == nil) == (fact.blockHeight == 0) else {
            return nil
        }
        let normalizedParent = fact.parentBlockHash.flatMap(CIDIdentity.canonicalString)
        guard fact.parentBlockHash == nil || normalizedParent != nil else { return nil }
        self.blockHash = blockHash
        parentBlockHash = normalizedParent
        blockHeight = fact.blockHeight
        timestamp = fact.timestamp
        childCommitments = fact.childCommitments ?? [:]
        snapshot = TipBlockSnapshot(
            postStateCID: postStateCID,
            prevStateCID: prevStateCID,
            specCID: specCID,
            target: target,
            nextTarget: nextTarget,
            tipHeight: fact.blockHeight,
            timestamp: fact.timestamp
        )
    }
}

/// A node-durable admission batch after Lattice has authenticated it. Recovery
/// may replay this value, but must never use it as wire evidence.
private struct TrustedAdmissionBatch {
    let block: ConsensusBlockInput?
    let workBlockHash: String
    let contribution: VerifiedWorkContribution

    init?(_ batch: ChainAdmissionBatch) {
        guard !batch.facts.isEmpty,
              Set(batch.facts.map(\.id)).count == batch.facts.count else {
            return nil
        }
        let blockFacts = batch.facts.compactMap { fact -> ChainBlockFact? in
            guard case .block(let value) = fact else { return nil }
            return value
        }
        let workFacts = batch.facts.compactMap { fact -> ChainWorkFact? in
            guard case .work(let value) = fact else { return nil }
            return value
        }
        // Every block, genesis included, must carry positive work: genesis must
        // satisfy its own committed target, and the canonical max-target genesis
        // already yields one unit of work, so a zero-work contribution is never
        // admissible in either the durable/replay path or in-memory construction.
        guard workFacts.count == 1,
              let work = workFacts.first,
              work.contribution.work > .zero,
              let workBlockHash = CIDIdentity.canonicalString(work.blockHash),
              let contributionID = CIDIdentity.canonicalString(work.contribution.id) else {
            return nil
        }
        let contribution = VerifiedWorkContribution(
            id: contributionID,
            work: work.contribution.work
        )
        // The eager tier weighs and validates in one gate, so its batch may
        // carry one validation fact alongside the block and work. It must name
        // the batch's own block: a batch is one block's durability unit, and
        // admitting a validation for anything else would let one block's
        // admission silently mark another executed.
        let validationFacts = batch.facts.compactMap { fact -> ChainValidationFact? in
            guard case .validation(let value) = fact else { return nil }
            return value
        }
        guard validationFacts.count <= 1,
              validationFacts.allSatisfy({
                  CIDIdentity.canonicalString($0.blockHash) == workBlockHash
              }) else {
            return nil
        }
        let extra = validationFacts.count

        switch blockFacts.count {
        case 0:
            guard batch.facts.count == 1 + extra else { return nil }
            block = nil
        case 1:
            guard batch.facts.count == 2 + extra,
                  let input = ConsensusBlockInput(fact: blockFacts[0]),
                  workBlockHash == input.blockHash else {
                return nil
            }
            block = input
        default:
            return nil
        }
        self.workBlockHash = workBlockHash
        self.contribution = contribution
    }
}

public struct ForkChoiceSnapshot: Sendable, Equatable {
    public let startingHash: String
    public let subtreeWork: WorkSum
    public let tipHash: String
    public let mainChainPath: Set<String>

    public init(startingHash: String, subtreeWork: WorkSum, tipHash: String, mainChainPath: Set<String>) {
        self.startingHash = startingHash
        self.subtreeWork = subtreeWork
        self.tipHash = tipHash
        self.mainChainPath = mainChainPath
    }
}

public actor ChainState {
    var chainTip: String
    var mainChainHashes: Set<String>
    var indexToBlockHash: [UInt64: Set<String>]
    var hashToBlock: [String: BlockMeta]
    var workByGrind: [String: WorkContributionRecord]
    /// Derived GHOST weights, as one Euler range per routed block — every routed
    /// block, not only those where a choice can be made. That was true while
    /// weights were stored per segment base; a range structure answers for any
    /// block at the same cost, and fork choice reads it only at forks.
    /// Per-block facts remain the source of truth because scalar weights cannot
    /// preserve grind identity.
    private var subtreeWorkIndex: EulerWorkIndex
    /// Run work per child directory per committing block (§9.10): the sum of
    /// own credited work over CONNECTED blocks whose nearest committer into
    /// that directory is the key. Insert-only, independent of exclusion, and
    /// maintained by the one reducer live admission and replay both use.
    /// Served to children; never a fork-choice input on THIS chain.
    private var runWork: [String: [String: WorkSum]]
    /// Blocks reachable from a genesis by parent pointers, excluded or not.
    /// Euler routing means connected-AND-not-excluded; runs must not depend on
    /// exclusion (never revoked), so connectivity is tracked on its own.
    private var connectedBlocks: Set<String>
    /// The child directories this node serves run reports for — the child
    /// chains it hosts. Operator choice, so the per-block run cost is bounded
    /// by what this node asked for, not by what any block commits into.
    private var servedDirectories: Set<String>
#if DEBUG
    /// Test-visible diagnostic for a whole-block canonical materialization.
    var fullCanonicalProjectionCount: UInt64
    /// Projections that re-descended from the divergence point instead of the
    /// root. A truncation that silently never fired would still be CORRECT, so
    /// the cost tests assert this rises rather than only that the answers match.
    var truncatedCanonicalProjectionCount: UInt64
    /// Blocks materialized by canonical projections, and segments walked to
    /// select the canonical spine. The projection COUNT cannot show the cost
    /// PER projection, which is what live-sync admission actually pays.
    var canonicalProjectionBlockVisitCount: UInt64
    var canonicalProjectionSegmentVisitCount: UInt64
    var segmentWorkUpdateCellCount: UInt64
    var segmentGraftCount: UInt64
    var segmentGraftBlockVisitCount: UInt64
    var stateContinuityBlockVisitCount: UInt64
    /// Run-bucket updates. Each connected block costs one per directory it
    /// has a nearest committer for, so this is O(#directories) per block —
    /// asserted by ratio, never by stopwatch.
    var runAttributionUpdateCount: UInt64
#endif
    /// Diagnostic prefix/subtree totals are derived local views. They are not
    /// fork-choice inputs and are rebuilt only when an API exposes them.
    private var localWorkCachesDirty: Bool

    /// Roots of proven-invalid subtrees (deferred-execution validated tier: a
    /// block whose execution completed and FAILED). Rebuilt on recovery from the
    /// durable `.exclusion` facts. Insert-only.
    ///
    /// Work weighs; validity selects (§9.9). An excluded block's work — and its
    /// descendants' — stays in every ancestor's weight exactly as any other
    /// work does: proof-of-work is a physical fact and invalidity is a judgment
    /// about state. What exclusion changes is SELECTION: the canonical descent
    /// never steps into an excluded root, so nothing below one is ever the tip
    /// or attested (§5.3). No weight is ever removed, so no index is ever
    /// rebuilt, and a descendant of an excluded root needs no bookkeeping at
    /// all — the descent cannot reach it.
    private var excludedRoots: Set<String> = []

    var mainChainBlockAtIndex: [UInt64: String]
    /// Generation at which the canonical projection was last brought current
    /// BY AN ACTUAL PROJECTION. Every graph/weight mutation flows through
    /// submitBlock or addWorkContribution, both of which advance
    /// `mutationGeneration`, so equality proves the projection is exact and
    /// re-projection is a no-op. `nil` = never verified: the package
    /// initializer can construct a deliberately stale projection (simulation
    /// and tests do), so currency is only ever established by projecting.
    private var projectedGeneration: UInt64?
    /// Restore-replay defers the derived canonical projection: batches are
    /// durable, already-admitted facts, their commits are discarded, and no
    /// replay step reads the projection — so it is computed exactly once at
    /// the end of replay instead of per event.
    private var deferProjectionForReplay = false
    var blockTimestamps: [String: Int64]
    /// Advances for every successful consensus mutation.
    var mutationGeneration: UInt64
    /// Capacity held across the node's asynchronous stage boundary. These
    /// reservations are fungible and disappear on restart; staged facts replay
    /// against the same pre-stage revision floor.
    var reservedAdmissionRevisions: UInt64

    public private(set) var tipSnapshot: TipBlockSnapshot?
    var tipSnapshotsByHash: [String: TipBlockSnapshot]
    private var blocksByStateTransition: [StateTransition: Set<String>]
    private var blocksByPostState: [String: Set<String>]

    /// Blocks whose transition this chain EXECUTED, so their `postState` is a
    /// reproduced result rather than a declared claim. Grows only: execution is
    /// a fact about immutable bytes, so it is never retracted, and a re-
    /// delivered weighed fact must never downgrade an executed block.
    ///
    /// Kept beside `tipSnapshotsByHash` rather than inside it because snapshot
    /// equality is used as a corruption predicate: a block whose committed
    /// fields changed means a corrupt graph, whereas a block that has since
    /// been executed is ordinary progress.
    private var validatedBlocks: Set<String>

    /// Blocks reachable from this chain's genesis through an unbroken run of
    /// EXECUTED blocks — i.e. every state on the path was produced, not merely
    /// declared.
    ///
    /// This is what "the chain produced this state" means, and keeping it as an
    /// index makes answering it O(1) instead of a walk whose length grows with
    /// chain height. Block 1 of a child chain anchors against `emptyHeader`,
    /// which is reachable only at the parent's genesis, so without this the
    /// anchor cost would grow without bound and a deployment would eventually
    /// become unanswerable.
    ///
    /// Monotone, like `validatedBlocks`: execution is a fact about immutable
    /// bytes and an ancestor never stops having been executed.
    private var anchoredBlocks: Set<String>

    // Restore validates this invariant; optional access keeps query paths fail-closed.
    var highestBlock: BlockMeta? { hashToBlock[chainTip] }
    var highestBlockHeight: UInt64 { highestBlock?.blockHeight ?? 0 }

    package init(
        chainTip: String,
        mainChainHashes: Set<String>,
        indexToBlockHash: [UInt64: Set<String>],
        hashToBlock: [String: BlockMeta],
        blockTimestamps: [String: Int64] = [:],
        tipSnapshot: TipBlockSnapshot? = nil,
        tipSnapshotsByHash: [String: TipBlockSnapshot] = [:],
        validatedBlocks: Set<String> = [],
        mutationGeneration: UInt64 = 0
    ) throws {
        self.chainTip = chainTip
        self.mainChainHashes = mainChainHashes
        guard hashToBlock.values.allSatisfy({ meta in
            guard Set(meta.childHashes).count == meta.childHashes.count,
                  (meta.parentBlockHash == nil) == (meta.blockHeight == 0)
            else { return false }

            for childHash in meta.childHashes {
                guard let child = hashToBlock[childHash],
                      child.parentBlockHash == meta.blockHash else { return false }
                let (expectedHeight, overflow) = meta.blockHeight.addingReportingOverflow(1)
                guard !overflow, child.blockHeight == expectedHeight else { return false }
            }

            guard let parentHash = meta.parentBlockHash,
                  let parent = hashToBlock[parentHash] else { return true }
            let (expectedHeight, overflow) = parent.blockHeight.addingReportingOverflow(1)
            return !overflow
                && meta.blockHeight == expectedHeight
                && parent.childHashes.contains(meta.blockHash)
        }) else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        self.hashToBlock = hashToBlock
        self.workByGrind = [:]
        self.subtreeWorkIndex = .empty
#if DEBUG
        self.fullCanonicalProjectionCount = 0
        self.truncatedCanonicalProjectionCount = 0
        self.canonicalProjectionBlockVisitCount = 0
        self.canonicalProjectionSegmentVisitCount = 0
        self.segmentWorkUpdateCellCount = 0
        self.segmentGraftCount = 0
        self.segmentGraftBlockVisitCount = 0
        self.stateContinuityBlockVisitCount = 0
        self.runAttributionUpdateCount = 0
#endif
        self.localWorkCachesDirty = true
        var allByHeight = indexToBlockHash
        for meta in hashToBlock.values {
            allByHeight[meta.blockHeight, default: []].insert(meta.blockHash)
        }
        self.indexToBlockHash = allByHeight
        self.tipSnapshot = tipSnapshot
        self.tipSnapshotsByHash = tipSnapshotsByHash
        if let tipSnapshot {
            self.tipSnapshotsByHash[chainTip] = tipSnapshot
        }
        self.validatedBlocks = validatedBlocks
        self.anchoredBlocks = []
        self.blocksByStateTransition = [:]
        self.blocksByPostState = [:]
        for (blockHash, snapshot) in self.tipSnapshotsByHash
        where hashToBlock[blockHash] != nil {
            self.blocksByStateTransition[
                StateTransition(
                    from: snapshot.prevStateCID,
                    to: snapshot.postStateCID
                ),
                default: []
            ].insert(blockHash)
            if snapshot.prevStateCID != snapshot.postStateCID {
                self.blocksByPostState[
                    snapshot.postStateCID,
                    default: []
                ].insert(blockHash)
            }
        }
        self.blockTimestamps = blockTimestamps
        self.mutationGeneration = mutationGeneration
        self.reservedAdmissionRevisions = 0
        self.mainChainBlockAtIndex = [:]
        for meta in self.hashToBlock.values {
            let contributions = meta.workContributions.values
            guard !contributions.isEmpty else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            // Every block, genesis included, must carry positive work: genesis
            // must satisfy its own committed target (h <= target), and the
            // canonical max-target genesis already yields one unit, so there is no
            // zero-work genesis to exempt.
            guard contributions.allSatisfy({ $0.work > .zero }) else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
        }
        guard Self.hasUniqueWorkLocations(in: self.hashToBlock) else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        self.workByGrind = Self.workIndex(in: self.hashToBlock)
        self.subtreeWorkIndex = Self.buildSubtreeWorkIndex(
            in: self.hashToBlock,
            workByGrind: &self.workByGrind
        )
        for hash in mainChainHashes {
            guard let height = self.hashToBlock[hash]?.blockHeight,
                  self.mainChainBlockAtIndex[height] == nil else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            self.mainChainBlockAtIndex[height] = hash
        }
        // Connectivity (§9.10), settled once downward from every genesis over
        // the UNFILTERED graph — excluded blocks included, since a run is never
        // revoked. Runs themselves are settled by `serveRuns(for:)`, one
        // directory at a time, through the same per-block step live admission
        // uses — one algorithm, not a rebuild twin.
        self.connectedBlocks = Self.connectedBlocks(in: self.hashToBlock)
        self.runWork = [:]
        self.servedDirectories = []
        // Seed the executed-from-genesis frontier. Replay hands validations to
        // `markValidated` one at a time, but a graph restored wholesale needs
        // it computed once, downward from every genesis it holds.
        self.anchoredBlocks = Self.anchoredFrontier(
            in: self.hashToBlock,
            validated: self.validatedBlocks,
            excluded: self.excludedRoots
        )
    }

    /// Blocks reachable from a genesis through an unbroken run of executed
    /// blocks. Computed downward so each block is settled once.
    private static func anchoredFrontier(
        in hashToBlock: [String: BlockMeta],
        validated: Set<String>,
        excluded: Set<String>
    ) -> Set<String> {
        var anchored: Set<String> = []
        // Roots keyed on the parent pointer, matching `propagateAnchored` and
        // the weight-index builder: the graph invariant ties it to height 0, and
        // three spellings of one predicate is how they drift apart.
        var pending = hashToBlock.values
            .filter { $0.parentBlockHash == nil && validated.contains($0.blockHash) }
            .map(\.blockHash)
        while let hash = pending.popLast() {
            guard let meta = hashToBlock[hash],
                  validated.contains(hash),
                  !excluded.contains(hash),
                  anchored.insert(hash).inserted else { continue }
            pending.append(contentsOf: meta.childHashes)
        }
        return anchored
    }

    package static func fromGenesis(
        block: Block
    ) -> ChainState {
        let blockHeader = try! BlockHeader(node: block)
        return fromVerifiedGenesis(
            block: block,
            contribution: VerifiedWorkContribution(
                id: blockHeader.rawCID,
                work: workForTarget(block.target)
            )
        )
    }

    package static func fromVerifiedGenesis(
        block: Block,
        contribution: VerifiedWorkContribution
    ) -> ChainState {
        // Known-valid local node; CID computation cannot fail (no Float/Double fields).
        let blockHash = try! BlockHeader(node: block).rawCID
        let meta = BlockMeta(
            blockHash: blockHash,
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            workContributions: [contribution],
            cumulativeWork: WorkSum(contribution.work)
        )
        return try! ChainState(
            chainTip: blockHash,
            mainChainHashes: Set([blockHash]),
            indexToBlockHash: [0: Set([blockHash])],
            hashToBlock: [blockHash: meta],
            blockTimestamps: [blockHash: block.timestamp],
            tipSnapshot: Self.snapshot(for: block),
            validatedBlocks: [blockHash]
        )
    }

    private static func fromTrustedGenesis(
        input: ConsensusBlockInput,
        contribution: VerifiedWorkContribution,
        mutationGeneration: UInt64 = 0
    ) throws -> ChainState {
        // Genesis, like every block, must carry positive work: it must satisfy its
        // own committed target, so a zero-work genesis is not admissible.
        guard input.parentBlockHash == nil,
              input.blockHeight == 0,
              contribution.work > .zero else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        let meta = BlockMeta(
            blockHash: input.blockHash,
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            workContributions: [contribution],
            cumulativeWork: WorkSum(contribution.work),
            childCommitments: input.childCommitments
        )
        return try ChainState(
            chainTip: input.blockHash,
            mainChainHashes: [input.blockHash],
            indexToBlockHash: [0: [input.blockHash]],
            hashToBlock: [input.blockHash: meta],
            blockTimestamps: [input.blockHash: input.timestamp],
            tipSnapshot: input.snapshot,
            validatedBlocks: [input.blockHash],
            mutationGeneration: mutationGeneration
        )
    }

    /// Restore a child process whose staged genesis batch reached durable storage
    /// before the in-memory actor was created. The durable revision is a final
    /// lower bound, applied after replay so restarts do not create revisions.
    public static func restore(
        replaying batches: [ChainAdmissionBatch],
        revisionFloor: UInt64 = 0
    ) async throws -> ChainState {
        let genesis = batches.compactMap(TrustedAdmissionBatch.init).filter {
            $0.block?.parentBlockHash == nil && $0.block?.blockHeight == 0
        }.sorted {
            ($0.block?.blockHash ?? "") < ($1.block?.blockHash ?? "")
        }.first
        guard let trusted = genesis, let input = trusted.block else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        let chain = try fromTrustedGenesis(
            input: input,
            contribution: trusted.contribution,
            mutationGeneration: 0
        )
        // The node may enumerate its durable facts in any order. Replay the seed
        // batch too: its existing block/work record makes that a no-op.
        // The projection is a derived cache and no replay step reads it, so it
        // is deferred across the whole replay and computed exactly once —
        // replay is O(batches), not O(batches × chain length).
        await chain.beginReplayProjectionDeferral()
        try await replay(batches[...], onto: chain)
        await chain.completeReplayProjectionDeferral()
        await chain.sealRecovery(revisionFloor: revisionFloor)
        return chain
    }

    private func sealRecovery(revisionFloor: UInt64) {
        mutationGeneration = max(mutationGeneration, revisionFloor)
    }

    private func beginReplayProjectionDeferral() {
        deferProjectionForReplay = true
    }

    /// End of restore-replay: compute the deferred canonical projection once.
    /// `forceFull` because replay deliberately maintains no projection to
    /// truncate against — there is no trustworthy canonical path until this
    /// runs.
    private func completeReplayProjectionDeferral() {
        deferProjectionForReplay = false
        _ = projectCanonicalChain(forceFull: true)
        tipSnapshot = tipSnapshotsByHash[chainTip]
    }

    private static func replay(
        _ batches: ArraySlice<ChainAdmissionBatch>,
        onto chain: ChainState
    ) async throws {
        // Sort keys are derived from immutable batch content, so authenticate
        // each batch ONCE and sort ONCE: the old per-comparison
        // `TrustedAdmissionBatch` construction re-decoded both operands' block
        // facts on every comparison, making a cold-start restore
        // O(N log N x decode) per round — hours of CPU on a long chain. A
        // sorted array's deferred subsequence keeps its relative order, so
        // later rounds never need re-sorting either.
        var pending = batches.map { batch in
            (batch: batch, key: TrustedAdmissionBatch(batch))
        }
        pending.sort { replayPrecedes($0, $1) }
        while !pending.isEmpty {
            var deferred: [(batch: ChainAdmissionBatch, key: TrustedAdmissionBatch?)] = []
            var completed = false
            for entry in pending {
                do {
                    _ = try await chain.replay(entry.batch)
                    completed = true
                } catch ChainStateRestoreError.missingBlockFact {
                    deferred.append(entry)
                }
            }
            guard completed else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            pending = deferred
        }
    }

    /// A strict weak ordering over EVERY batch, fact-only ones included: block
    /// batches by height, then work-only batches, then exclusions and
    /// validations by their target. A batch with no key must still compare
    /// consistently — a key that compared "equal" to everything would let the
    /// sort leave it wherever enumeration put it.
    private static func replayPrecedes(
        _ left: (batch: ChainAdmissionBatch, key: TrustedAdmissionBatch?),
        _ right: (batch: ChainAdmissionBatch, key: TrustedAdmissionBatch?)
    ) -> Bool {
        switch (left.key, right.key) {
        case let (leftKey?, rightKey?):
            return replayPrecedes(leftKey, rightKey)
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            // Validations before exclusions: a root exclusion waits on the other
            // root's validation, so this order settles it in the same round.
            let l = exclusionTarget(of: left.batch).map { ("x", $0) }
                ?? validationTarget(of: left.batch).map { ("v", $0) } ?? ("z", "")
            let r = exclusionTarget(of: right.batch).map { ("x", $0) }
                ?? validationTarget(of: right.batch).map { ("v", $0) } ?? ("z", "")
            return l.0 != r.0 ? l.0 < r.0 : l.1 < r.1
        }
    }

    private static func replayPrecedes(
        _ left: TrustedAdmissionBatch,
        _ right: TrustedAdmissionBatch
    ) -> Bool {
        switch (left.block, right.block) {
        case let (leftBlock?, rightBlock?)
        where leftBlock.blockHeight != rightBlock.blockHeight:
            return leftBlock.blockHeight < rightBlock.blockHeight
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        if left.contribution.work != right.contribution.work {
            return left.contribution.work < right.contribution.work
        }
        if left.workBlockHash != right.workBlockHash {
            return left.workBlockHash < right.workBlockHash
        }
        return left.contribution.id < right.contribution.id
    }

    private static func snapshot(for block: Block) -> TipBlockSnapshot {
        TipBlockSnapshot(
            postStateCID: block.postState.rawCID,
            prevStateCID: block.prevState.rawCID,
            specCID: block.spec.rawCID,
            target: block.target,
            nextTarget: block.nextTarget,
            tipHeight: block.height,
            timestamp: block.timestamp
        )
    }

    // MARK: - Queries

    /// Recompute canonical projection after local simulation/test mutation.
    @discardableResult
    public func reevaluateForkChoice() -> ChainCommit? {
        guard hasUnreservedMutationCapacity else { return nil }
        // No graph or weight fact has changed since the projection was last
        // brought current, so re-projection is provably a no-op: a duplicate
        // delivery that added nothing cannot promote anything.
        guard mutationGeneration != projectedGeneration else { return nil }
        let canonicalChange = projectCanonicalChain()
        guard canonicalChange != nil else { return nil }
        // This bump carries no graph mutation, so the projection just computed
        // stays exact for the new generation.
        mutationGeneration += 1
        projectedGeneration = mutationGeneration
        return (canonicalChange ?? ChainCommit(tipHash: chainTip))
            .atRevision(mutationGeneration)
    }

    public func contains(blockHash: String) -> Bool {
        hashToBlock[blockHash] != nil
    }

    public func currentRevision() -> UInt64 {
        mutationGeneration
    }

    /// Same-chain acquisition needs are every unresolved immediate edge:
    /// absent predecessors and accepted-but-unconnected predecessors alike.
    /// Height order makes this linear after the deterministic sort, rather
    /// than walking the same orphan suffix once per descendant.
    public func unresolvedSameChainPredecessors() -> [SameChainPredecessorRequirement] {
        let ordered = hashToBlock.sorted {
            if $0.value.blockHeight != $1.value.blockHeight {
                return $0.value.blockHeight < $1.value.blockHeight
            }
            return $0.key < $1.key
        }
        var connected = Set<String>()
        connected.reserveCapacity(ordered.count)
        for (key, block) in ordered {
            guard let predecessor = block.parentBlockHash else {
                if block.blockHeight == 0 {
                    connected.insert(key)
                }
                continue
            }
            guard let parent = hashToBlock[predecessor] else { continue }
            let (expectedHeight, overflow) = parent.blockHeight
                .addingReportingOverflow(1)
            if !overflow,
               expectedHeight == block.blockHeight,
               connected.contains(predecessor)
            {
                connected.insert(key)
            }
        }
        return hashToBlock.values.compactMap { block in
            guard let predecessor = block.parentBlockHash,
                  !connected.contains(predecessor) else { return nil }
            return SameChainPredecessorRequirement(
                descendantCID: block.blockHash,
                predecessorCID: predecessor
            )
        }.sorted {
            if $0.descendantCID != $1.descendantCID {
                return $0.descendantCID < $1.descendantCID
            }
            return $0.predecessorCID < $1.predecessorCID
        }
    }

    func sameChainPredecessorRequirement(
        for descendantCID: String
    ) -> SameChainPredecessorRequirement? {
        hashToBlock[descendantCID].flatMap(sameChainPredecessorRequirement(for:))
    }

    private func sameChainPredecessorRequirement(
        for block: BlockMeta
    ) -> SameChainPredecessorRequirement? {
        guard let parent = block.parentBlockHash,
              !hasConnectedAncestry(blockHash: parent) else { return nil }
        return SameChainPredecessorRequirement(
            descendantCID: block.blockHash,
            predecessorCID: parent
        )
    }

    /// Whether `blockHash` belongs to a complete accepted path ending at one of
    /// this path-defined chain's admitted genesis roots — i.e. it is CONNECTED,
    /// so its work routes into fork choice (excluded or not: work weighs, §9.9).
    ///
    /// This says nothing about whether any block on that path was EXECUTED. The
    /// weighed tier connects a block from its header alone and records its
    /// declared `postState` as an unverified claim (§9.9). Anything that must
    /// distinguish a produced state from a declared one — parent-state
    /// attestation above all — must also test whether the block was validated;
    /// connectivity is not verification.
    func hasConnectedAncestry(blockHash: String) -> Bool {
        subtreeWorkIndex.contains(blockHash)
    }

    /// Whether `blockHash` is reachable from this chain's genesis through an
    /// unbroken run of EXECUTED blocks — the honest form of the question the
    /// old `hasValidatedAncestry` name promised and did not answer.
    ///
    /// Use this, not `hasConnectedAncestry`, for anything a CHILD chain will
    /// bind to. A weighed block is connected from its header alone; issuing a
    /// cross-chain fact for one hands a child a commitment this chain has not
    /// verified and may yet prove invalid.
    func hasExecutedAncestry(blockHash: String) -> Bool {
        anchoredBlocks.contains(blockHash)
    }

    /// Whether `toStateCID` is reachable from `fromStateCID` through the
    /// connected accepted state-transition graph. Fork choice is irrelevant.
    /// Continuity is a property of the graph, not of how hard a node is willing
    /// to look: a visit budget would make the same question answerable on one
    /// node and unanswerable on another from identical data, splitting honest
    /// nodes by local policy. Serving RATE is a node's choice; the ANSWER is
    /// not. The block-1 shape — the one whose cost grew with chain height — is
    /// answered from the anchored frontier in O(1).
    public func hasStateContinuity(
        from fromStateCID: String,
        to toStateCID: String
    ) -> Bool {
        guard let from = CIDIdentity.canonicalString(fromStateCID),
              let to = CIDIdentity.canonicalString(toStateCID) else {
            return false
        }
        if from == to { return true }
        // A child's block 1 anchors against `emptyHeader`, which is reachable
        // only at this chain's genesis — so the question is exactly "did this
        // chain produce that state", which the executed-from-genesis frontier
        // answers outright. The equivalent walk costs one visit per block of
        // chain height, which is the shape that used to need a budget.
        if from == LatticeState.emptyHeader.rawCID {
            return chainProduced(stateCID: to)
        }
        return stateContinuityPath(from: from, to: to) != nil
    }

    /// One deterministic accepted-block path proving forward state continuity.
    /// The returned CIDs are hints for acquiring ordinary block Volumes; a
    /// receiver must still validate those blocks before trusting the path.
    public func stateContinuityPath(
        from fromStateCID: String,
        to toStateCID: String
    ) -> [String]? {
        guard let from = CIDIdentity.canonicalString(fromStateCID),
              let to = CIDIdentity.canonicalString(toStateCID) else {
            return nil
        }
        if from == to { return [] }
        // Only a transition on the executed-from-genesis frontier may be
        // attested: executed, every ancestor executed, and not under an
        // excluded root. The weighed tier records a block's declared
        // post-state without running it, so an unverified claim would
        // otherwise stay attestable forever; and the weight index says nothing
        // about validity any more (work weighs, §9.9), so it is not a gate. A
        // child chain settles cross-chain withdrawals against an attested
        // parent state, so attesting a state the parent never produced lets a
        // forged `receiptState` settle a withdrawal that was never paid.
        func isAttestable(_ blockHash: String) -> Bool {
            anchoredBlocks.contains(blockHash)
        }
        if let directCandidates = blocksByStateTransition[
            StateTransition(from: from, to: to)
        ] {
            if let direct = directCandidates.lazy.filter({
                isAttestable($0)
            }).min() {
                return [direct]
            }
        }

        let targetCandidates = blocksByPostState[to] ?? []
        var pending = Array(targetCandidates)
            .filter { isAttestable($0) }
            .sorted(by: >)
        var visited = Set<String>()
        var childTowardTarget: [String: String] = [:]
        while let blockHash = pending.popLast() {
            guard visited.insert(blockHash).inserted,
                  let block = hashToBlock[blockHash],
                  let snapshot = tipSnapshotsByHash[blockHash] else {
                continue
            }
#if DEBUG
            stateContinuityBlockVisitCount &+= 1
#endif
            if snapshot.prevStateCID == from {
                var path = [blockHash]
                while let child = childTowardTarget[path.last!] {
                    path.append(child)
                }
                return path
            }
            guard let parentHash = block.parentBlockHash,
                  isAttestable(parentHash),
                  let parent = hashToBlock[parentHash],
                  let parentSnapshot = tipSnapshotsByHash[parentHash],
                  parentSnapshot.postStateCID == snapshot.prevStateCID
            else { continue }
            childTowardTarget[parentHash] = blockHash
            pending.append(parent.blockHash)
        }
        return nil
    }

    public func getMainChainTip() -> String {
        chainTip
    }

    /// One coherent canonical context for transaction preflight. Keeping the
    /// tip and its snapshot in one actor read lets callers reject a result if
    /// the canonical tip changes while content is being resolved.
    func transactionPreflightTip() -> (cid: String, snapshot: TipBlockSnapshot?) {
        (chainTip, tipSnapshot)
    }

    public func isOnMainChain(hash: String) -> Bool {
        guard let height = hashToBlock[hash]?.blockHeight else { return false }
        return mainChainBlockAtIndex[height] == hash
    }

    /// Sum work for up to `limit` ancestors from the current tip.
    public func getCumulativeWork(limit: UInt64) -> WorkSum {
        var measure = WorkMeasure.zero
        let strongestWork = Self.strongestWorkByGrind(in: hashToBlock)
        var current: String? = chainTip
        var walked: UInt64 = 0
        while let hash = current, walked <= limit {
            guard let meta = hashToBlock[hash] else { break }
            measure.formUnion(
                WorkMeasure(meta.workContributions.values)
                    .normalized(using: strongestWork)
            )
            current = meta.parentBlockHash
            walked += 1
        }
        return measure.total
    }

    /// Exact total proof-of-work from genesis to the current chain tip.
    public func getTipCumulativeWork() -> WorkSum {
        materializeLocalWorkCachesIfNeeded()
        return highestBlock?.cumulativeWork ?? .zero
    }

    /// Exact genesis-relative cumulative work at a specific block, or nil if the
    /// block is unknown.
    public func getCumulativeWork(forHash hash: String) -> WorkSum? {
        guard hashToBlock[hash] != nil else { return nil }
        materializeLocalWorkCachesIfNeeded()
        return hashToBlock[hash]?.cumulativeWork
    }

    /// The same-chain subtree measure of `hash`, deduplicated by grind identity.
    public func subtreeWeight(forHash hash: String) -> WorkSum? {
        guard hashToBlock[hash] != nil else { return nil }
        // Pure work, excluded subtrees included: validity never subtracts weight.
        materializeLocalWorkCachesIfNeeded()
        return hashToBlock[hash]?.subtreeWeight
    }

    /// Public simulator/test view of the real local fork-choice descent.
    public func forkChoiceSnapshot(startingAt hash: String) -> ForkChoiceSnapshot? {
        guard let meta = hashToBlock[hash],
              subtreeWorkIndex.contains(hash) else { return nil }
        let choice = chainWithMostWork(startingBlock: meta)
        return ForkChoiceSnapshot(
            startingHash: hash,
            subtreeWork: choice.subtreeWork,
            tipHash: choice.tipHash,
            mainChainPath: choice.blocks
        )
    }

    public func getConsensusBlock(hash: String) -> BlockMeta? {
        guard hashToBlock[hash] != nil else { return nil }
        materializeLocalWorkCachesIfNeeded()
        return hashToBlock[hash]
    }

    public func getHighestBlock() -> BlockMeta? {
        materializeLocalWorkCachesIfNeeded()
        return highestBlock
    }

    public func getHighestBlockHeight() -> UInt64 {
        highestBlockHeight
    }

#if DEBUG
    /// Test-only seam for asserting that a no-reorg update did not materialize
    /// the unchanged unary canonical path.
    func resetFullCanonicalProjectionCount() {
        fullCanonicalProjectionCount = 0
    }

    /// Read-only whole-chain projection over the LIVE index, with no counter and
    /// no state effects. Differential tests use it to separate a wrong
    /// truncation from a wrong index: a truncated projection must agree with
    /// this at every step, and when it does not, this says which half is at
    /// fault — something comparing only against the reference oracle cannot.
    func debugFullCanonicalProjection() -> (
        chainTip: String,
        mainChainHashes: Set<String>
    )? {
        let roots = Array(indexToBlockHash[0] ?? []).filter {
            hashToBlock[$0]?.parentBlockHash == nil
                && !excludedRoots.contains($0)
        }
        guard let root = Self.preferred(among: roots, workIndex: subtreeWorkIndex)
        else { return nil }
        if let descent = Self.blockGhostDescent(
            from: root,
            in: hashToBlock,
            workIndex: subtreeWorkIndex,
            excluding: excludedRoots
        ) {
            return (descent.tipHash, descent.blocks)
        }
        let direct = Self.referenceGhostDescent(
            from: root,
            in: hashToBlock,
            excluding: excludedRoots
        )
        return (direct.tipHash, direct.blocks)
    }

    /// Test-only view of the excluded roots so a differential test can drive
    /// the reference oracle with the same unselectable set.
    var excludedRootsForTesting: Set<String> {
        excludedRoots
    }
#endif

    public func getMainChainBlockHash(atIndex index: UInt64) -> String? {
        mainChainBlockAtIndex[index]
    }

    /// Return up to `count` ancestor timestamps newest-first, starting at
    /// `parentHash`. Fast path: walks the held graph's parent links via
    /// `hashToBlock` + `blockTimestamps` — every accepted block, weighed
    /// included, on or off the main chain — avoiding fetcher round-trips, with
    /// exactly the order and count of `Block.collectAncestorTimestamps`. Returns
    /// nil if `parentHash` is not held, or if any timestamp in the held window
    /// is missing (e.g. pre-upgrade persisted data) — callers should fall back
    /// to a fetcher walk.
    /// The difficulty anchor for a block, filling any gap and caching the
    /// result along the way.
    ///
    /// Admission normally inherits the anchor from the parent, which is O(1).
    /// A block can arrive before its parent though, and it has no anchor to
    /// inherit at that moment — so rather than leave a hole its descendants
    /// would inherit, this walks up to the nearest ancestor that does have one
    /// and writes it back down the path it walked. Height 1 always has an
    /// anchor from its own admission, so the walk always terminates.
    ///
    /// The result is a pure function of the block's ancestry either way; the
    /// cache only decides how much of that ancestry has to be re-read.
    public func difficultyAnchor(forBlockHash hash: String) -> DifficultyAnchor? {
        var unresolved: [String] = []
        var current: String? = hash
        var resolved: DifficultyAnchor?
        while let step = current, let meta = hashToBlock[step] {
            if let anchor = meta.difficultyAnchor {
                resolved = anchor
                break
            }
            unresolved.append(step)
            guard meta.blockHeight > 1 else { break }
            current = meta.parentBlockHash
        }
        guard let anchor = resolved else { return nil }
        for step in unresolved {
            hashToBlock[step]?.adoptDifficultyAnchor(anchor)
        }
        return anchor
    }

    public func getMainChainTimestamps(forParentHash parentHash: String, count: UInt64) -> [Int64]? {
        guard count > 0 else { return [] }
        guard hashToBlock[parentHash] != nil else { return nil }
        var result: [Int64] = []
        var current: String? = parentHash
        for _ in 0..<count {
            guard let hash = current else { break }
            guard let ts = blockTimestamps[hash] else { return nil }
            result.append(ts)
            current = hashToBlock[hash]?.parentBlockHash
        }
        return result
    }

    // MARK: - Block Submission

    func submitBlock(
        blockHeader: BlockHeader,
        block: Block,
        contribution: VerifiedWorkContribution
    ) -> SubmissionResult {
        submitBlock(
            input: ConsensusBlockInput(blockHeader: blockHeader, block: block),
            contribution: contribution
        )
    }

    private func submitBlock(
        input: ConsensusBlockInput,
        contribution: VerifiedWorkContribution
    ) -> SubmissionResult {
        let blockHash = input.blockHash
        let isRoot = input.parentBlockHash == nil
        let oldTip = chainTip

        if contribution.work == .zero || (isRoot && input.blockHeight != 0) {
            return .discarded()
        }

        guard acceptsLocation(of: contribution.id, at: blockHash) else {
            return .discarded()
        }

        if hashToBlock[blockHash] != nil {
            return addWorkContribution(contribution, to: blockHash)
        }

        guard hasUnreservedMutationCapacity else { return .discarded() }
        let graftsExistingComponent = connectsExistingSubtree(input)

        let result = insertBlock(
            input: input,
            contributions: [contribution],
            addedContribution: true,
            graftsExistingComponent: graftsExistingComponent
        )
        if !result.addedBlock { return result }
        mutationGeneration += 1

        let canonicalChange: ChainCommit?
        if deferProjectionForReplay {
            canonicalChange = nil
        } else {
            // A validated insert either adds one leaf or grafts one component
            // rooted at this block, and every block carries strictly positive
            // work: a positive increase confined to one point of the graph.
            // The canonical tip append is not a special case any more — it is
            // the cheapest instance of this one, a descent of a single step.
            canonicalChange = projectCanonicalChain(monotoneIncreaseAt: blockHash)
        }
        let extendsMainChain = input.parentBlockHash == oldTip
            && mainChainHashes.contains(blockHash)
        return SubmissionResult(
            addedBlock: true,
            addedContribution: result.addedContribution,
            extendsMainChain: extendsMainChain,
            commit: (canonicalChange ?? ChainCommit(tipHash: chainTip))
                .atRevision(mutationGeneration)
        )
    }

    // MARK: - Insert

    private func insertBlock(
        input: ConsensusBlockInput,
        contributions: [VerifiedWorkContribution],
        addedContribution: Bool,
        graftsExistingComponent: Bool
    ) -> SubmissionResult {
        let blockHash = input.blockHash
        guard !contributions.isEmpty,
              Set(contributions.map(\.id)).count == contributions.count,
              // Every block, genesis included, must carry positive work — genesis
              // must satisfy its own committed target.
              contributions.allSatisfy({ $0.work > .zero }),
              !(input.parentBlockHash == nil && input.blockHeight != 0)
        else {
            return .discarded()
        }
        addToBlockIndex(hash: blockHash, blockHeight: input.blockHeight)

        let childHashes = findChildren(hash: blockHash, blockHeight: input.blockHeight)
        // Height 1 is its own anchor; everything above inherits its parent's.
        // Following the PARENT rather than the canonical chain is what makes
        // this reorg-safe: a block admitted onto a competing branch takes that
        // branch's anchor, so two branches forking at height 1 never borrow each
        // other's schedule. A block whose parent is not yet known carries none
        // and acquires one when it connects.
        let anchor: DifficultyAnchor?
        if input.blockHeight == 1 {
            anchor = DifficultyAnchor(
                blockHeight: 1,
                timestamp: input.timestamp,
                target: input.snapshot.target
            )
        } else if let parentHash = input.parentBlockHash {
            anchor = hashToBlock[parentHash]?.difficultyAnchor
        } else {
            anchor = nil
        }
        let meta = BlockMeta(
            blockHash: blockHash,
            parentBlockHash: input.parentBlockHash,
            blockHeight: input.blockHeight,
            childHashes: childHashes,
            workContributions: [],
            cumulativeWork: .zero,
            subtreeWeight: .zero,
            difficultyAnchor: anchor,
            childCommitments: input.childCommitments
        )

        hashToBlock[blockHash] = meta
        blockTimestamps[blockHash] = input.timestamp
        indexStateTransition(input.snapshot, blockHash: blockHash)
        if let prevHash = input.parentBlockHash,
           hashToBlock[prevHash]?.childHashes.contains(blockHash) == false {
            hashToBlock[prevHash]?.childHashes.append(blockHash)
        }
        for contribution in contributions {
            applyLocalContribution(contribution, to: blockHash)
        }
        // Runs and connectivity (§9.10), unfiltered: a block that descends
        // from an excluded block is still connected and its work still lands
        // in its run.
        if input.parentBlockHash == nil {
            if input.blockHeight == 0 { connectForRunAttribution(rootedAt: blockHash) }
        } else if let parentHash = input.parentBlockHash,
                  connectedBlocks.contains(parentHash) {
            connectForRunAttribution(rootedAt: blockHash)
        }
        // Every connected block routes, a descendant of an excluded root
        // included: work weighs unconditionally, and validity is applied by the
        // descent, which never steps into an excluded root (§9.9).
        if graftsExistingComponent {
            // These graph and work-location invariants were validated before
            // this private reducer. Never continue with a partial consensus
            // index if an internal invariant is broken.
            precondition(
                graftConnectedComponent(rootedAt: blockHash),
                "validated orphan component could not be routed"
            )
        } else if childHashes.isEmpty {
            precondition(
                routeBlock(for: blockHash),
                "validated leaf could not be routed"
            )
        }

        for contribution in contributions {
            applyForkChoiceContribution(contribution, to: blockHash)
        }

        guard let previousBlockCID = input.parentBlockHash else {
            return SubmissionResult(
                addedBlock: true,
                addedContribution: addedContribution,
                extendsMainChain: false
            )
        }

        if hashToBlock[previousBlockCID] == nil {
            return SubmissionResult(
                addedBlock: true,
                addedContribution: addedContribution,
                extendsMainChain: false
            )
        }

        return SubmissionResult(
            addedBlock: true,
            addedContribution: addedContribution,
            extendsMainChain: false
        )
    }

    /// Rebuild exact local prefix and subtree measures after a graph or work-fact
    /// mutation without retaining an identity map at every block.
    nonisolated static func recomputeWorkCaches(
        in blocks: inout [String: BlockMeta]
    ) {
        // Quantity is a property of the physical grind, not of the segment
        // containing its one location.
        var strongestWork: [String: UInt256] = [:]
        for contribution in blocks.values.flatMap(\.workContributions.values)
        where contribution.work > (strongestWork[contribution.id] ?? .zero) {
            strongestWork[contribution.id] = contribution.work
        }
        func normalized(_ contribution: VerifiedWorkContribution) -> VerifiedWorkContribution {
            VerifiedWorkContribution(
                id: contribution.id,
                work: strongestWork[contribution.id] ?? contribution.work
            )
        }
        let ascending = blocks.values.sorted {
            if $0.blockHeight != $1.blockHeight { return $0.blockHeight < $1.blockHeight }
            return $0.blockHash < $1.blockHash
        }
        let roots = ascending.filter { meta in
            meta.parentBlockHash.flatMap { blocks[$0] } == nil
        }
        for root in roots {
            var activeCounts: [String: [UInt256: Int]] = [:]
            var activeWork = WorkSum.zero
            func adjustActiveWork(
                _ contribution: VerifiedWorkContribution,
                by delta: Int
            ) {
                let id = contribution.id
                let oldWork = activeCounts[id]?.keys.max() ?? .zero
                var counts = activeCounts[id] ?? [:]
                let count = counts[contribution.work, default: 0] + delta
                if count == 0 {
                    counts.removeValue(forKey: contribution.work)
                } else {
                    counts[contribution.work] = count
                }
                if counts.isEmpty {
                    activeCounts.removeValue(forKey: id)
                } else {
                    activeCounts[id] = counts
                }
                let newWork = counts.keys.max() ?? .zero
                guard oldWork != newWork else { return }
                if oldWork > .zero {
                    activeWork = activeWork.subtracting(WorkSum(oldWork))!
                }
                if newWork > .zero {
                    activeWork = activeWork + newWork
                }
            }
            var pending: [(hash: String, exiting: Bool)] = [(root.blockHash, false)]
            while let frame = pending.popLast() {
                guard let meta = blocks[frame.hash] else { continue }
                if frame.exiting {
                    for contribution in meta.workContributions.values {
                        adjustActiveWork(normalized(contribution), by: -1)
                    }
                    continue
                }

                for contribution in meta.workContributions.values {
                    adjustActiveWork(normalized(contribution), by: 1)
                }
                blocks[meta.blockHash]?.setCumulativeWork(activeWork)
                pending.append((meta.blockHash, true))
                for childHash in meta.childHashes.reversed() {
                    pending.append((childHash, false))
                }
            }
        }

        typealias Accumulator = (entries: [String: UInt256], total: WorkSum)
        var subtreeAccumulators: [String: Accumulator] = [:]
        func insert(
            id: String,
            work: UInt256,
            into accumulator: inout Accumulator
        ) {
            guard work > (accumulator.entries[id] ?? .zero) else { return }
            if let oldWork = accumulator.entries[id] {
                accumulator.total = accumulator.total.subtracting(WorkSum(oldWork))!
            }
            accumulator.entries[id] = work
            accumulator.total = accumulator.total + work
        }

        for meta in ascending.reversed() {
            let largestChild = meta.childHashes.max {
                (subtreeAccumulators[$0]?.entries.count ?? 0)
                    < (subtreeAccumulators[$1]?.entries.count ?? 0)
            }
            var accumulator = largestChild.flatMap {
                subtreeAccumulators.removeValue(forKey: $0)
            } ?? Accumulator(entries: [:], total: .zero)
            for childHash in meta.childHashes where childHash != largestChild {
                guard let child = subtreeAccumulators.removeValue(forKey: childHash) else {
                    continue
                }
                for (id, work) in child.entries {
                    insert(id: id, work: work, into: &accumulator)
                }
            }
            for (id, contribution) in meta.workContributions {
                insert(
                    id: id,
                    work: strongestWork[id] ?? contribution.work,
                    into: &accumulator
                )
            }
            blocks[meta.blockHash]?.setSubtreeWeight(accumulator.total)
            subtreeAccumulators[meta.blockHash] = accumulator
        }
    }

    nonisolated private static func hasUniqueWorkLocations(
        in blocks: [String: BlockMeta]
    ) -> Bool {
        var locationByGrind: [String: String] = [:]
        func observe(_ grindID: String, at blockHash: String) -> Bool {
            guard locationByGrind[grindID].map({ $0 == blockHash }) ?? true else {
                return false
            }
            locationByGrind[grindID] = blockHash
            return true
        }
        for (blockHash, block) in blocks {
            for grindID in block.workContributions.keys
            where !observe(grindID, at: blockHash) {
                return false
            }
        }
        return true
    }

    nonisolated static func workIndex(
        in blocks: [String: BlockMeta]
    ) -> [String: WorkContributionRecord] {
        var result: [String: WorkContributionRecord] = [:]
        func observe(_ contribution: VerifiedWorkContribution, at hash: String) {
            var record = result[contribution.id] ?? WorkContributionRecord(
                blockHash: hash,
                contribution: contribution
            )
            if contribution.work > record.contribution.work {
                record.contribution = contribution
            }
            result[contribution.id] = record
        }

        for (hash, meta) in blocks {
            for contribution in meta.workContributions.values {
                observe(contribution, at: hash)
            }
        }
        return result
    }

    @discardableResult
    /// Route one newly admitted block into fork choice.
    ///
    /// The shape of the parent's existing children used to decide this: zero
    /// children extended the parent's run, one forced a split, more meant a new
    /// base. There are no runs any more, so none of that survives — a block is a
    /// leaf inside its parent's range either way, and the range structure needs
    /// nothing above the insertion point told about it.
    private func routeBlock(for blockHash: String) -> Bool {
        guard let block = hashToBlock[blockHash] else { return false }
        guard let parentHash = block.parentBlockHash else {
            guard block.blockHeight == 0 else { return false }
            return subtreeWorkIndex.insertRoot(blockHash)
        }
        // A disconnected component stays unrouted until an admitted ancestor
        // grafts the whole component in.
        guard hashToBlock[parentHash] != nil,
              subtreeWorkIndex.contains(parentHash) else { return true }
        return subtreeWorkIndex.insertLeaf(blockHash, under: parentHash) != nil
    }

    /// Route one newly connected orphan component without touching unrelated
    /// history. Its blocks are toured once and spliced into the parent's range
    /// in one operation, so nothing above the graft point is updated.
    private func graftConnectedComponent(rootedAt rootHash: String) -> Bool {
        var pending = [rootHash]
        var componentHashes = Set<String>()
        while let hash = pending.popLast() {
            // Defensive: a member of a disconnected component cannot already be
            // routed (`routeBlock` refuses to route under an unrouted parent),
            // so this guard never fires; if an invariant ever broke, skipping
            // also strips the block from the spliced events, since the tour
            // below only follows children that are in componentHashes.
            guard !subtreeWorkIndex.contains(hash),
                  componentHashes.insert(hash).inserted,
                  let block = hashToBlock[hash] else { continue }
            pending.append(contentsOf: block.childHashes)
        }
        guard !componentHashes.isEmpty else { return false }

        var componentBlocks: [String: BlockMeta] = [:]
        componentBlocks.reserveCapacity(componentHashes.count)
        for hash in componentHashes {
            guard let block = hashToBlock[hash] else { return false }
            componentBlocks[hash] = block
        }
        var componentWorkByGrind = Self.workIndex(in: componentBlocks)
        // Direct work per block, which is all the Euler tour carries. No subtree
        // total is computed for the component and none is added to any ancestor:
        // splicing its elements inside the parent's range makes every enclosing
        // range correct by construction.
        //
        // `isRouted` is set here because the build call that used to set it as a
        // side effect is gone. Leaving it false would let the contribution path
        // add this same work a second time.
        var componentDirectWork: [String: WorkSum] = [:]
        for grindID in componentWorkByGrind.keys {
            guard var record = componentWorkByGrind[grindID] else { continue }
            record.isRouted = true
            componentWorkByGrind[grindID] = record
            componentDirectWork[record.blockHash, default: .zero] =
                componentDirectWork[record.blockHash, default: .zero]
                + record.contribution.work
        }

        if let parentHash = hashToBlock[rootHash]?.parentBlockHash {
            guard subtreeWorkIndex.contains(parentHash) else {
                return false
            }
        } else if hashToBlock[rootHash]?.blockHeight != 0 {
            return false
        }

        // One splice, and nothing above it. The walk that used to add this
        // component's total to every routed base above the graft point is gone,
        // because there are no stored ancestor totals left to update.
        // Iterative on purpose: a connected component can be a long orphan run,
        // and a recursive tour would put its length on the call stack.
        var events: [EulerWorkIndex.Event] = []
        events.reserveCapacity(componentHashes.count * 2)
        func componentChildren(_ hash: String) -> [String] {
            (componentBlocks[hash]?.childHashes ?? [])
                .filter { componentHashes.contains($0) }
                .sorted()
        }
        var tourStack: [(hash: String, children: [String], next: Int)] = []
        events.append(.open(rootHash, componentDirectWork[rootHash] ?? .zero))
        tourStack.append((rootHash, componentChildren(rootHash), 0))
        while var frame = tourStack.popLast() {
            guard frame.next < frame.children.count else {
                events.append(.close(frame.hash))
                continue
            }
            let child = frame.children[frame.next]
            frame.next += 1
            tourStack.append(frame)
            events.append(.open(child, componentDirectWork[child] ?? .zero))
            tourStack.append((child, componentChildren(child), 0))
        }

        var updatedCells = 0
        if let parentHash = hashToBlock[rootHash]?.parentBlockHash {
            guard let cells = subtreeWorkIndex.splice(events, under: parentHash)
            else { return false }
            updatedCells = cells
        } else {
            // A component rooted at genesis has no parent range to sit inside.
            guard subtreeWorkIndex.insertRoot(rootHash) else { return false }
            if let rootWork = componentDirectWork[rootHash] {
                _ = subtreeWorkIndex.add(rootWork, at: rootHash)
            }
            let inner = Array(events.dropFirst().dropLast())
            if !inner.isEmpty {
                guard let cells = subtreeWorkIndex.splice(inner, under: rootHash)
                else { return false }
                updatedCells = cells
            }
        }

        for (grindID, record) in componentWorkByGrind {
            workByGrind[grindID] = record
        }
#if DEBUG
        segmentGraftCount += 1
        segmentGraftBlockVisitCount += UInt64(componentHashes.count)
        segmentWorkUpdateCellCount += UInt64(updatedCells)
#endif
        return true
    }

    private func applyLocalContribution(
        _ contribution: VerifiedWorkContribution,
        to blockHash: String
    ) {
        guard hashToBlock[blockHash]?.setWorkContribution(contribution) == true else {
            return
        }
        localWorkCachesDirty = true
    }

    private func acceptsLocation(of grindID: String, at blockHash: String) -> Bool {
        return workByGrind[grindID]
            .map { $0.blockHash == blockHash } ?? true
    }

    /// Rebuild non-consensus diagnostic totals lazily. Fork choice always uses
    /// the identity-aware segment cache instead.
    func materializeLocalWorkCachesIfNeeded() {
        guard localWorkCachesDirty else { return }
        Self.recomputeWorkCaches(in: &hashToBlock)
        localWorkCachesDirty = false
    }

    private func applyForkChoiceContribution(
        _ contribution: VerifiedWorkContribution,
        to blockHash: String
    ) {
        let id = contribution.id
        if workByGrind[id] == nil {
            workByGrind[id] = WorkContributionRecord(
                blockHash: blockHash,
                contribution: contribution
            )
        }
        guard let existing = workByGrind[id],
              existing.blockHash == blockHash else { return }
        if contribution.work > existing.contribution.work {
            if existing.isRouted {
                let delta = WorkSum(contribution.work)
                    .subtracting(WorkSum(existing.contribution.work))!
                guard let updatedCells = subtreeWorkIndex.add(
                        delta,
                        at: blockHash
                      ) else { return }
#if DEBUG
                segmentWorkUpdateCellCount += UInt64(updatedCells)
#endif
            }
            workByGrind[id]?.contribution = contribution
        }

        guard hashToBlock[blockHash] != nil,
              workByGrind[id]?.isRouted == false,
              let strongest = workByGrind[id]?.contribution else { return }
        guard let updatedCells = subtreeWorkIndex.add(
                WorkSum(strongest.work),
                at: blockHash
              ) else {
            return
        }
#if DEBUG
        segmentWorkUpdateCellCount += UInt64(updatedCells)
#endif
        workByGrind[id]?.isRouted = true
    }

    // MARK: - Additional proof facts

    func addWorkContribution(
        _ contribution: VerifiedWorkContribution,
        to blockHash: String
    ) -> SubmissionResult {
        guard hashToBlock[blockHash] != nil,
              acceptsLocation(of: contribution.id, at: blockHash) else {
            return .discarded()
        }
        if let existing = workContribution(id: contribution.id, at: blockHash),
           existing.work >= contribution.work {
            return .discarded()
        }
        guard hasUnreservedMutationCapacity else { return .discarded() }
        let workBefore = hashToBlock[blockHash]?.work ?? .zero
        applyLocalContribution(contribution, to: blockHash)
        // A strengthening raises this block's own work, so its run (§9.10)
        // rises by exactly that delta — once the block is connected. An
        // orphan's work is credited in full at the moment it connects.
        if connectedBlocks.contains(blockHash),
           let workAfter = hashToBlock[blockHash]?.work,
           let delta = workAfter.subtracting(workBefore),
           let nearest = hashToBlock[blockHash]?.nearestCommitter {
            creditRun(delta, nearest: nearest)
        }
        // A stronger observation on an excluded block weighs like any other: it
        // raises every ancestor, and the descent still never steps into the
        // excluded root, so no invalid block is resurrected by piling on work.
        applyForkChoiceContribution(contribution, to: blockHash)
        mutationGeneration += 1

        // A contribution only reaches here when it is strictly stronger than what
        // this block already held, so fork choice saw a positive increase at
        // exactly one point.
        let canonicalChange = deferProjectionForReplay
            ? nil
            : projectCanonicalChain(monotoneIncreaseAt: blockHash)
        if canonicalChange != nil {
            tipSnapshot = tipSnapshotsByHash[chainTip]
        }
        return SubmissionResult(
            addedBlock: false,
            addedContribution: true,
            extendsMainChain: false,
            commit: (canonicalChange ?? ChainCommit(tipHash: chainTip))
                .atRevision(mutationGeneration)
        )
    }

    func workContribution(id: String) -> WorkContributionRecord? {
        workByGrind[id]
    }

    func workContribution(
        id: String,
        at blockHash: String
    ) -> VerifiedWorkContribution? {
        hashToBlock[blockHash]?.workContributions[id]
    }

    // MARK: - Parent-attributed run work (§9.10)

    /// Every block reachable from a genesis by parent pointers, over the
    /// UNFILTERED graph.
    nonisolated static func connectedBlocks(in blocks: [String: BlockMeta]) -> Set<String> {
        var connected = Set<String>()
        var stack = blocks.values
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
        while let hash = stack.popLast() {
            guard let meta = blocks[hash], connected.insert(hash).inserted else { continue }
            stack.append(contentsOf: meta.childHashes)
        }
        return connected
    }

    /// Start serving run reports for `directory` — the node hosts a child
    /// chain there. Settles every connected block's nearest committer and run
    /// for that one directory, parent before child, over the UNFILTERED graph:
    /// O(N) once, at the operator's choice, and idempotent. Which directories a
    /// node serves is its own choice, so a stranger's block committing into ten
    /// thousand directories costs this node nothing it did not ask for.
    public func serveRuns(for directory: String) {
        guard servedDirectories.insert(directory).inserted else { return }
        var stack = hashToBlock.values
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
        while let hash = stack.popLast() {
            guard connectedBlocks.contains(hash), let meta = hashToBlock[hash] else { continue }
            settleRuns(of: hash, directories: [directory])
            stack.append(contentsOf: meta.childHashes)
        }
    }

    /// Connect one block whose parent is connected (or which is a genesis):
    /// settle its nearest committers and runs for every served directory, then
    /// do the same for every already-present descendant — an orphan component
    /// connects the moment its root does. Unfiltered on purpose: an excluded
    /// descendant is still connected and still credited.
    private func connectForRunAttribution(rootedAt rootHash: String) {
        var stack = [rootHash]
        while let hash = stack.popLast() {
            guard let meta = hashToBlock[hash],
                  connectedBlocks.insert(hash).inserted else { continue }
            settleRuns(of: hash, directories: servedDirectories)
            stack.append(contentsOf: meta.childHashes)
        }
    }

    /// The one per-block step of run attribution, for a connected block whose
    /// parent is already settled: for each directory, the nearest committer is
    /// this block if it commits there, else the parent's; the block's own work
    /// is credited to that run. Used both by live connection (every served
    /// directory) and by `serveRuns(for:)` (one directory over the whole
    /// graph), so a run has exactly one definition.
    private func settleRuns(of hash: String, directories: Set<String>) {
        guard let meta = hashToBlock[hash] else { return }
        let inherited = meta.parentBlockHash
            .flatMap { hashToBlock[$0]?.nearestCommitter } ?? [:]
        var nearest = meta.nearestCommitter
        var credited: [String: String] = [:]
        for directory in directories {
            let committer = meta.childCommitments[directory] != nil ? hash : inherited[directory]
            guard let committer else { continue }
            nearest[directory] = committer
            credited[directory] = committer
        }
        hashToBlock[hash]?.adoptNearestCommitter(nearest)
        creditRun(meta.work, nearest: credited)
    }

    private func creditRun(_ work: WorkSum, nearest: [String: String]) {
        for (directory, committer) in nearest {
            let current = runWork[directory]?[committer] ?? .zero
            runWork[directory, default: [:]][committer] = current + work
#if DEBUG
            runAttributionUpdateCount &+= 1
#endif
        }
    }

    /// The run report a parent serves for one of its committing blocks. Nil
    /// when `directory` is not served here (`serveRuns(for:)`), or the block is
    /// unknown, not connected, or does not commit into `directory` — a child
    /// must never be handed a number for a block that is not a committer into
    /// its own directory. O(1).
    ///
    /// The connectivity conjunct is redundant by construction (a run entry is
    /// only ever written for a connected block, so the lookup below already
    /// fails for an orphan) and is kept as the stated rule rather than an
    /// accident of the table's maintenance.
    public func parentRunReport(
        at blockHash: String,
        directory: String
    ) -> ParentRunReport? {
        guard let hash = CIDIdentity.canonicalString(blockHash),
              connectedBlocks.contains(hash),
              let meta = hashToBlock[hash],
              let childBlock = meta.childCommitments[directory],
              let run = runWork[directory]?[hash] else { return nil }
        return ParentRunReport(
            blockHash: hash,
            directory: directory,
            childBlock: childBlock,
            grinds: Set(meta.workContributions.keys),
            runWork: run,
            ownWork: meta.work,
            revision: mutationGeneration
        )
    }

    /// Derive the strengthening a parent's run report implies for one of this
    /// chain's blocks, as a work-only batch the node must make durable and
    /// then apply. This is the ONLY route by which a wire number reaches a
    /// `VerifiedWorkContribution`, and it does not take the number as-is: the
    /// quantity is DERIVED here from this chain's own state and refused unless
    /// it is a strict increase.
    ///
    /// The report is BOUND before any number is read: it must name this child
    /// block as the one its committer commits, it must be for `directory` —
    /// this chain's own, which the caller knows and this actor does not — and
    /// one of the committer's grinds must already be credited here (the proof
    /// through that committer is what made this a child block). The attributed
    /// quantity is `runWork − ownWork`: the committer's own grinds stay counted
    /// exactly once, at the child's own price; the run's other blocks are
    /// credited under `AttributedRunIdentity(committer, directory)`, which
    /// ratchets on its own value, so a repeated report is a refusal, not a
    /// second addition.
    ///
    /// The QUANTITY is the parent's word. The child already trusts its
    /// configured parent process for state continuity (§5.3), which gates
    /// minting outright, so this is not a new trust class; a verified path can
    /// replace it later with no consensus change (§9.10).
    ///
    /// Everything downstream is the existing work path: `applyStaged`
    /// re-checks strict increase and returns nil on a stale or duplicate batch
    /// — never a throw — so a report computed before a concurrent stronger one
    /// applied is a harmless no-op, live and on replay alike.
    public func strengthenFromParentReport(
        child childHash: String,
        directory: String,
        report: ParentRunReport
    ) -> ParentReportStrengthening {
        guard report.directory == directory else { return .wrongDirectory }
        guard let hash = CIDIdentity.canonicalString(childHash),
              CIDIdentity.canonicalString(report.childBlock) == hash,
              let committer = CIDIdentity.canonicalString(report.blockHash),
              report.grinds.contains(where: { workContribution(id: $0, at: hash) != nil }),
              let attributedID = AttributedRunIdentity(
                  committerBlockHash: committer, directory: directory
              ).contributionID,
              acceptsLocation(of: attributedID, at: hash) else {
            return .notCommitterOfChild
        }
        guard let derived = report.runWork.subtracting(report.ownWork) else {
            return .malformedReport
        }
        guard let derivedWork = derived.uint256Value else {
            return .unrepresentable(derived: derived)
        }
        let existing = workContribution(id: attributedID, at: hash)?.work ?? .zero
        guard derivedWork > existing else {
            return .notStronger(existing: WorkSum(existing), derived: derived)
        }
        return .strengthened(ChainAdmissionBatch(facts: [
            .work(ChainWorkFact(
                blockHash: hash,
                contribution: VerifiedWorkContribution(id: attributedID, work: derivedWork)
            )),
        ]))
    }

    /// Apply one already-durable, locally authenticated admission batch. Live
    /// admission and recovery share this reducer so staging is the only
    /// linearization point.
    func applyStaged(_ batch: ChainAdmissionBatch) throws -> SubmissionResult? {
        if let excluded = Self.exclusionTarget(of: batch) {
            return try applyExclusion(blockHash: excluded)
        }
        if let validated = Self.validationTarget(of: batch) {
            // A validation for a block this chain does not hold is deferred by
            // the caller's replay loop exactly as a work fact would be, not an
            // error: possession and execution arrive independently.
            guard hashToBlock[validated] != nil else {
                throw ChainStateRestoreError.missingBlockFact
            }
            markValidated(blockHash: validated)
            return nil
        }
        guard let trusted = TrustedAdmissionBatch(batch) else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        // Applied only once the batch has landed: `defer` would also run on the
        // throw paths, marking a block executed out of a batch that was rejected
        // as graph-inconsistent.
        func applyValidations() {
            for fact in batch.facts {
                guard case .validation(let validation) = fact,
                      let hash = CIDIdentity.canonicalString(validation.blockHash)
                else { continue }
                markValidated(blockHash: hash)
            }
        }
        if let input = trusted.block {
            if let existing = hashToBlock[input.blockHash] {
                guard matchesGraph(existing, input: input),
                      blockTimestamps[input.blockHash].map({
                          $0 == input.timestamp
                      }) ?? true,
                      tipSnapshotsByHash[input.blockHash].map({
                          $0 == input.snapshot
                      }) ?? true else {
                    throw ChainStateRestoreError.corruptConsensusGraph
                }
                if let existing = workContribution(
                    id: trusted.contribution.id,
                    at: input.blockHash
                ), existing.work >= trusted.contribution.work {
                    hydrateMetadata(from: input)
                    applyValidations()
                    return nil
                }
                guard hasUnreservedMutationCapacity else {
                    throw ChainStateRestoreError.corruptConsensusGraph
                }
                hydrateMetadata(from: input)
                let submission = addWorkContribution(
                    trusted.contribution,
                    to: input.blockHash
                )
                guard submission.addedContribution else {
                    throw ChainStateRestoreError.corruptConsensusGraph
                }
                applyValidations()
                return submission
            }
            let submission = submitBlock(input: input, contribution: trusted.contribution)
            guard submission.addedBlock, submission.addedContribution else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            applyValidations()
            return submission
        }

        let blockHash = trusted.workBlockHash
        guard hashToBlock[blockHash] != nil else {
            throw ChainStateRestoreError.missingBlockFact
        }
        if let existing = workContribution(
            id: trusted.contribution.id,
            at: blockHash
        ), existing.work >= trusted.contribution.work {
            return nil
        }
        let submission = addWorkContribution(trusted.contribution, to: blockHash)
        guard submission.addedContribution else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        return submission
    }

    /// A validation batch is exactly one `.validation` fact: the deferred
    /// upgrade of an already-possessed block, carrying no new block or work.
    private static func validationTarget(of batch: ChainAdmissionBatch) -> String? {
        guard batch.facts.count == 1,
              case .validation(let fact) = batch.facts[0] else { return nil }
        return CIDIdentity.canonicalString(fact.blockHash)
    }

    /// Record that a possessed block's transition was executed. Monotone: the
    /// marker is a fact about immutable bytes, so it is never retracted, and a
    /// re-delivered weighed fact must never downgrade it.
    private func markValidated(blockHash: String) {
        guard hashToBlock[blockHash] != nil else { return }
        validatedBlocks.insert(blockHash)
        propagateAnchored(from: blockHash)
    }

    /// Extend the executed-from-genesis frontier.
    ///
    /// A block is anchored once it is executed and its parent is anchored (a
    /// genesis anchors itself). Executing one block can therefore also anchor
    /// descendants that were executed earlier out of order, so the frontier is
    /// pushed down until it stops moving. Each block is anchored at most once
    /// for the life of the chain, so the total work is linear overall and the
    /// amortized cost per admission is constant.
    private func propagateAnchored(from blockHash: String) {
        var pending = [blockHash]
        while let hash = pending.popLast() {
            guard let meta = hashToBlock[hash],
                  !anchoredBlocks.contains(hash),
                  validatedBlocks.contains(hash) else { continue }
            let parentAnchored = meta.parentBlockHash.map {
                anchoredBlocks.contains($0)
            } ?? true
            // A proven-invalid block extends nothing: its subtree left fork
            // choice, and the states it declared are not states this chain
            // stands behind.
            guard parentAnchored, !excludedRoots.contains(hash) else { continue }
            anchoredBlocks.insert(hash)
            pending.append(contentsOf: meta.childHashes)
        }
    }

    /// Whether this chain produced `stateCID` — i.e. some block whose declared
    /// post-state is `stateCID` was executed, and so was every block between it
    /// and the genesis.
    ///
    /// O(1): the equivalent walk grows with chain height, and it is the shape a
    /// child's block 1 asks for every time it anchors.
    private func chainProduced(stateCID: String) -> Bool {
        guard let candidates = blocksByPostState[stateCID] else { return false }
        // The frontier is the one authority: executed from genesis and not
        // under an excluded root. The weight index used to be a second defence
        // here, but it no longer says anything about validity (work weighs,
        // §9.9), so it is not consulted — a vacuous conjunct would only read as
        // a defence it is not.
        return candidates.contains { anchoredBlocks.contains($0) }
    }

    /// An exclusion batch is exactly one `.exclusion` fact. Any other shape is
    /// handled by the block/work reducer.
    private static func exclusionTarget(of batch: ChainAdmissionBatch) -> String? {
        guard batch.facts.count == 1,
              case .exclusion(let fact) = batch.facts[0] else { return nil }
        return CIDIdentity.canonicalString(fact.blockHash)
    }

    /// Whether some OTHER genesis root of this chain is on the executed
    /// frontier — "is there a chain to stand on", the test a producer runs
    /// before it may exclude a root (§9.9).
    func hasExecutedRoot(besides blockHash: String) -> Bool {
        (indexToBlockHash[0] ?? []).contains {
            $0 != blockHash
                && hashToBlock[$0]?.parentBlockHash == nil
                && anchoredBlocks.contains($0)
        }
    }

    /// Record a proven-invalid subtree root. The block must already be present:
    /// a not-yet-connected exclusion defers exactly like a work fact whose block
    /// has not arrived, so replay retries it once the subtree exists.
    private func applyExclusion(blockHash: String) throws -> SubmissionResult? {
        guard hashToBlock[blockHash] != nil else {
            throw ChainStateRestoreError.missingBlockFact
        }
        // Idempotent: a duplicate exclusion adds nothing and cannot reorg.
        if excludedRoots.contains(blockHash) { return nil }
        guard hasUnreservedMutationCapacity else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        // A chain whose every root is proven invalid has no history to stand
        // on, so a root may be excluded only while another root this chain has
        // EXECUTED remains. The producer (`prepareValidatedTier`) refuses
        // before any fact is written; this reducer is the fail-closed twin.
        // During replay the other root's validation may simply not have
        // replayed yet, so the exclusion defers like any fact whose
        // prerequisites are missing — order-independent — and only a live
        // exclusion with nothing to stand on is a corrupt graph.
        if hashToBlock[blockHash]?.parentBlockHash == nil,
           !hasExecutedRoot(besides: blockHash) {
            throw deferProjectionForReplay
                ? ChainStateRestoreError.missingBlockFact
                : ChainStateRestoreError.corruptConsensusGraph
        }
        excludedRoots.insert(blockHash)
        // The excluded subtree may have been anchored before it was proven
        // invalid, and a chain does not stand behind states it has proven it
        // never legitimately produced: un-anchor it, and nothing else.
        unanchor(subtreeRootedAt: blockHash)
        // No weight moves — work weighs regardless of validity — so nothing is
        // rebuilt. Selection moves only if the excluded block was on the
        // canonical path; otherwise the descent never reached it and every
        // decision stands.
        let wasCanonical = mainChainHashes.contains(blockHash)
        mutationGeneration += 1
        let canonicalChange = (deferProjectionForReplay || !wasCanonical)
            ? nil
            : projectCanonicalChain(forceFull: true)
        if canonicalChange != nil {
            tipSnapshot = tipSnapshotsByHash[chainTip]
        }
        return SubmissionResult(
            addedBlock: false,
            addedContribution: false,
            extendsMainChain: false,
            commit: (canonicalChange ?? ChainCommit(tipHash: chainTip))
                .atRevision(mutationGeneration)
        )
    }

    /// Remove a proven-invalid root and everything below it from the executed
    /// frontier. Bounded by the excluded subtree; a root that was never
    /// anchored has no anchored descendants, so the walk stops at once.
    private func unanchor(subtreeRootedAt rootHash: String) {
        var pending = [rootHash]
        while let hash = pending.popLast() {
            guard anchoredBlocks.remove(hash) != nil,
                  let meta = hashToBlock[hash] else { continue }
            pending.append(contentsOf: meta.childHashes)
        }
    }

    /// Rebuild one already-durable admission fact during recovery. Callers must
    /// authenticate and persist the fact before invoking this public seam.
    public func replay(_ batch: ChainAdmissionBatch) throws -> ChainCommit? {
        try applyStaged(batch)?.commit
    }

    /// Reserve one distinct U64 commit revision before the node stages a batch.
    /// Other actor mutations must leave this capacity available until the batch
    /// either fails staging or consumes the reservation synchronously.
    func reserveAdmissionRevision() -> Bool {
        guard hasUnreservedMutationCapacity else { return false }
        reservedAdmissionRevisions += 1
        return true
    }

    func releaseAdmissionRevision() {
        precondition(reservedAdmissionRevisions > 0)
        reservedAdmissionRevisions -= 1
    }

    func applyReservedStaged(
        _ batch: ChainAdmissionBatch
    ) throws -> SubmissionResult? {
        guard reservedAdmissionRevisions > 0 else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        reservedAdmissionRevisions -= 1
        return try applyStaged(batch)
    }

    private var hasUnreservedMutationCapacity: Bool {
        reservedAdmissionRevisions < UInt64.max - mutationGeneration
    }

    private func matchesGraph(_ meta: BlockMeta, input: ConsensusBlockInput) -> Bool {
        meta.blockHash == input.blockHash
            && meta.parentBlockHash == input.parentBlockHash
            && meta.blockHeight == input.blockHeight
            // Commitments are PoW-bound content, so two honest facts for one
            // block agree; a disagreement is a graph conflict, rejected — never
            // resolved by whichever fact happened to replay first.
            && meta.childCommitments == input.childCommitments
    }

    private func hydrateMetadata(from input: ConsensusBlockInput) {
        blockTimestamps[input.blockHash] = input.timestamp
        indexStateTransition(input.snapshot, blockHash: input.blockHash)
        if chainTip == input.blockHash {
            tipSnapshot = input.snapshot
        }
    }

    private func indexStateTransition(
        _ snapshot: TipBlockSnapshot,
        blockHash: String
    ) {
        if let previous = tipSnapshotsByHash[blockHash],
           previous != snapshot {
            blocksByStateTransition[
                StateTransition(
                    from: previous.prevStateCID,
                    to: previous.postStateCID
                )
            ]?.remove(blockHash)
            if previous.prevStateCID != previous.postStateCID {
                blocksByPostState[
                    previous.postStateCID
                ]?.remove(blockHash)
            }
        }
        tipSnapshotsByHash[blockHash] = snapshot
        blocksByStateTransition[
            StateTransition(
                from: snapshot.prevStateCID,
                to: snapshot.postStateCID
            ),
            default: []
        ].insert(blockHash)
        if snapshot.prevStateCID != snapshot.postStateCID {
            blocksByPostState[
                snapshot.postStateCID,
                default: []
            ].insert(blockHash)
        }
    }

    // MARK: - Index Management

    private func connectsExistingSubtree(
        _ input: ConsensusBlockInput
    ) -> Bool {
        guard !findChildren(
            hash: input.blockHash,
            blockHeight: input.blockHeight
        ).isEmpty else { return false }
        guard let parentHash = input.parentBlockHash else {
            return input.blockHeight == 0
        }
        return subtreeWorkIndex.contains(parentHash)
    }

    func addToBlockIndex(hash: String, blockHeight: UInt64) {
        indexToBlockHash[blockHeight, default: []].insert(hash)
    }

    func findChildren(hash: String, blockHeight: UInt64) -> [String] {
        let (childHeight, overflow) = blockHeight.addingReportingOverflow(1)
        guard !overflow, let hashes = indexToBlockHash[childHeight] else { return [] }
        return hashes.filter { hashToBlock[$0]?.parentBlockHash == hash }
    }

    // MARK: - Fork Choice

    nonisolated private static func strongestWorkByGrind(
        in blocks: [String: BlockMeta]
    ) -> [String: UInt256] {
        var strongestWork: [String: UInt256] = [:]
        for block in blocks.values {
            for contribution in block.workContributions.values
            where contribution.work > (strongestWork[contribution.id] ?? .zero) {
                strongestWork[contribution.id] = contribution.work
            }
        }
        return strongestWork
    }

    nonisolated private static func effectiveSubtreeMeasures(
        startingAt startHashes: [String],
        retaining retainedHashes: Set<String>,
        in blocks: [String: BlockMeta],
        strongestWork: [String: UInt256]
    ) -> [String: WorkMeasure] {
        var order: [String] = []
        var pending = startHashes
        var visited = Set<String>()
        while let hash = pending.popLast() {
            guard visited.insert(hash).inserted,
                  let meta = blocks[hash] else { continue }
            order.append(hash)
            pending.append(contentsOf: meta.childHashes)
        }

        var accumulators: [String: WorkMeasure] = [:]
        var retained: [String: WorkMeasure] = [:]
        for hash in order.reversed() {
            guard let meta = blocks[hash] else { continue }
            let children = meta.childHashes
            let largestChild = children.max {
                (accumulators[$0]?.entries.count ?? 0)
                    < (accumulators[$1]?.entries.count ?? 0)
            }
            var measure = largestChild.flatMap {
                accumulators.removeValue(forKey: $0)
            } ?? .zero
            for childHash in children where childHash != largestChild {
                if let child = accumulators.removeValue(forKey: childHash) {
                    measure.formUnion(child)
                }
            }
            measure.formUnion(
                WorkMeasure(meta.workContributions.values)
                    .normalized(using: strongestWork)
            )
            if retainedHashes.contains(hash) { retained[hash] = measure }
            accumulators[hash] = measure
        }
        return retained
    }

    /// Build the derived GHOST weight index as one Euler tour of the routed
    /// graph. Recovery uses this linear builder; every live mutation is
    /// incremental.
    ///
    /// The tour visits routed blocks only, children sorted, so a rebuild is
    /// deterministic. Its ORDER differs from the one live insertion produces,
    /// which appends each new child last — but a subtree is a contiguous range
    /// under either order, and the sum over a range does not depend on the order
    /// within it, which is the only thing fork choice reads.
    nonisolated private static func buildSubtreeWorkIndex(
        in blocks: [String: BlockMeta],
        workByGrind: inout [String: WorkContributionRecord]
    ) -> EulerWorkIndex {
        // Routed-ness was a lookup into the quotient; it is now exactly what it
        // always meant — reachable from a genesis root through blocks that are
        // present. The tour below already walks that set, so it is computed once
        // here rather than kept in a second structure that has to be maintained
        // in step with this one.
        var routedBlocks = Set<String>()
        var reachable = blocks.values
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
        while let hash = reachable.popLast() {
            guard routedBlocks.insert(hash).inserted,
                  let block = blocks[hash] else { continue }
            reachable.append(contentsOf: block.childHashes.filter {
                blocks[$0] != nil
            })
        }

        var directWorkByBlock: [String: WorkSum] = [:]
        for grindID in workByGrind.keys {
            guard var record = workByGrind[grindID] else { continue }
            let routed = routedBlocks.contains(record.blockHash)
            record.isRouted = routed
            workByGrind[grindID] = record
            if routed {
                directWorkByBlock[record.blockHash, default: .zero] =
                    directWorkByBlock[record.blockHash, default: .zero]
                    + record.contribution.work
            }
        }

        // Iterative because a chain is as deep as it is long, and recursion
        // here would be bounded by the stack.
        func routedChildren(_ hash: String) -> [String] {
            (blocks[hash]?.childHashes ?? [])
                .filter { routedBlocks.contains($0) }
                .sorted()
        }
        var events: [EulerWorkIndex.Event] = []
        events.reserveCapacity(routedBlocks.count * 2)
        let roots = blocks.values
            .filter {
                $0.parentBlockHash == nil
                    && $0.blockHeight == 0
                    && routedBlocks.contains($0.blockHash)
            }
            .map(\.blockHash)
            .sorted()
        for root in roots {
            var tourStack: [(hash: String, children: [String], next: Int)] = []
            events.append(.open(root, directWorkByBlock[root] ?? .zero))
            tourStack.append((root, routedChildren(root), 0))
            while var frame = tourStack.popLast() {
                guard frame.next < frame.children.count else {
                    events.append(.close(frame.hash))
                    continue
                }
                let child = frame.children[frame.next]
                frame.next += 1
                tourStack.append(frame)
                events.append(.open(child, directWorkByBlock[child] ?? .zero))
                tourStack.append((child, routedChildren(child), 0))
            }
        }
        return EulerWorkIndex.build(events: events)
    }

    nonisolated private static func preferred(
        among hashes: [String],
        weights: [String: WorkSum]
    ) -> String? {
        // Skip candidates with no weight (a block not yet routed) rather than
        // bailing when the FIRST is weightless — selection must not depend on
        // child ordering.
        var selected: String?
        for candidate in hashes {
            guard let candidateWork = weights[candidate] else { continue }
            guard let current = selected, let selectedWork = weights[current] else {
                selected = candidate
                continue
            }
            if candidateWork > selectedWork ||
                (candidateWork == selectedWork && forkChoicePrefersBlock(
                    candidate,
                    over: current
                )) {
                selected = candidate
            }
        }
        return selected
    }

    nonisolated private static func preferred(
        among hashes: [String],
        workIndex: EulerWorkIndex
    ) -> String? {
        var selected: String?
        for candidate in hashes {
            guard let candidateWork = workIndex.subtreeWork(candidate)
            else { continue }
            guard let current = selected,
                  let selectedWork = workIndex.subtreeWork(current) else {
                selected = candidate
                continue
            }
            if candidateWork > selectedWork
                || (candidateWork == selectedWork
                    && forkChoicePrefersBlock(candidate, over: current)) {
                selected = candidate
            }
        }
        return selected
    }

    /// GHOST descent chooses the child with greatest deduplicated verified
    /// work. Equal work prefers the smaller segment-base CID.
    func chainWithMostWork(
        startingBlock: BlockMeta
    ) -> (subtreeWork: WorkSum, tipHash: String, blocks: Set<String>) {
        // An excluded start point weighs what its work weighs and descends
        // nowhere: nothing below a proven-invalid block is selectable.
        if excludedRoots.contains(startingBlock.blockHash) {
            let weight = subtreeWorkIndex.subtreeWork(startingBlock.blockHash)
                ?? effectiveSubtreeWork(for: startingBlock.blockHash)
            return (weight, startingBlock.blockHash, [startingBlock.blockHash])
        }
        // Weights are pure work; `excluding` only steers the descent past
        // excluded roots, which are never stepped into. No-op when nothing is
        // excluded — the steady-state path is unchanged.
        let start = hashToBlock[startingBlock.blockHash] ?? startingBlock
        if let descent = Self.blockGhostDescent(
            from: start.blockHash,
            in: hashToBlock,
            workIndex: subtreeWorkIndex,
            excluding: excludedRoots
        ) {
            let baseWeight = subtreeWorkIndex.subtreeWork(start.blockHash)
                ?? effectiveSubtreeWork(for: start.blockHash)
            return (baseWeight, descent.tipHash, descent.blocks)
        }
        let direct = Self.referenceGhostDescent(
            from: start.blockHash,
            in: hashToBlock,
            excluding: excludedRoots
        )
        return (
            effectiveSubtreeWork(for: start.blockHash),
            direct.tipHash,
            direct.blocks
        )
    }

    private func effectiveSubtreeWork(for blockHash: String) -> WorkSum {
        let measure = Self.effectiveSubtreeMeasures(
            startingAt: [blockHash],
            retaining: [blockHash],
            in: hashToBlock,
            strongestWork: Self.strongestWorkByGrind(in: hashToBlock)
        )
        return measure[blockHash]?.total ?? .zero
    }

    /// GHOST descent over blocks, with no quotient in between.
    ///
    /// The structure this replaces compressed unary runs so a walk could hop
    /// from a base to its tail. That only pays when runs are long, and on a
    /// merged-mining child they never are: a losing sibling is roughly 74% of
    /// admissions, so a split fired at nearly every height and every run
    /// collapsed to length one — segments walked exactly equalled blocks
    /// materialized, at every chain length measured. The accelerator compressed
    /// nothing on the workload it had to serve.
    ///
    /// A lone child is followed without a weight lookup, matching the reference
    /// walk. Nil on a malformed graph — a cycle — so the caller keeps its
    /// independent slow fallback.
    nonisolated private static func blockGhostDescent(
        from startHash: String,
        in blocksByHash: [String: BlockMeta],
        workIndex: EulerWorkIndex,
        excluding: Set<String> = []
    ) -> (tipHash: String, blocks: Set<String>)? {
        var currentHash = startHash
        var blocks = Set<String>()
        while true {
            guard blocks.insert(currentHash).inserted else { return nil }
            let all = blocksByHash[currentHash]?.childHashes ?? []
            let children = excluding.isEmpty
                ? all
                : all.filter { !excluding.contains($0) }
            guard !children.isEmpty else { return (currentHash, blocks) }
            let next = children.count == 1
                ? children[0]
                : preferred(among: children, workIndex: workIndex)
            guard let next else { return nil }
            currentHash = next
        }
    }

    /// Slow direct GHOST walk kept separate from the live implementation
    /// so differential tests can detect a routing-cache bug.
    nonisolated private static func referenceGhostDescent(
        from startHash: String,
        in blocksByHash: [String: BlockMeta],
        weights: [String: WorkSum],
        excluding: Set<String> = []
    ) -> (tipHash: String, blocks: Set<String>) {
        var currentHash = startHash
        var blocks: Set<String> = [currentHash]
        while true {
            let allChildren = blocksByHash[currentHash]?.childHashes ?? []
            let children = excluding.isEmpty
                ? allChildren
                : allChildren.filter { !excluding.contains($0) }
            guard !children.isEmpty else { break }
            let next: String?
            if children.count == 1 {
                next = children[0]
            } else {
                next = preferred(among: children, weights: weights)
            }
            guard let next,
                  blocks.insert(next).inserted else { break }
            currentHash = next
        }
        return (currentHash, blocks)
    }

    /// Expensive cache-independent fallback used only when derived segment
    /// routing is malformed. It recomputes the exact direct comparison weights
    /// from raw work facts rather than trusting a potentially stale cache.
    nonisolated private static func referenceGhostDescent(
        from startHash: String,
        in blocksByHash: [String: BlockMeta],
        excluding: Set<String> = []
    ) -> (tipHash: String, blocks: Set<String>) {
        let measures = effectiveSubtreeMeasures(
            startingAt: [startHash],
            retaining: Set(blocksByHash.keys),
            in: blocksByHash,
            strongestWork: strongestWorkByGrind(in: blocksByHash)
        )
        return referenceGhostDescent(
            from: startHash,
            in: blocksByHash,
            weights: measures.mapValues(\.total),
            excluding: excluding
        )
    }

    nonisolated static func canonicalProjection(
        in blocksByHash: [String: BlockMeta]
    ) -> (chainTip: String, mainChainHashes: Set<String>)? {
        var workByGrind = workIndex(in: blocksByHash)
        let workIndex = buildSubtreeWorkIndex(
            in: blocksByHash,
            workByGrind: &workByGrind
        )
        return canonicalProjection(
            in: blocksByHash,
            workIndex: workIndex
        )
    }

    /// Slow, exact per-block reference used only by differential tests. The
    /// normal restore validator intentionally uses the compact cache builder.
    nonisolated static func referenceCanonicalProjection(
        in blocksByHash: [String: BlockMeta]
    ) -> (chainTip: String, mainChainHashes: Set<String>)? {
        let roots = blocksByHash.values
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
        let measures = effectiveSubtreeMeasures(
            startingAt: roots,
            retaining: Set(blocksByHash.keys),
            in: blocksByHash,
            strongestWork: strongestWorkByGrind(in: blocksByHash)
        )
        return referenceCanonicalProjection(
            in: blocksByHash,
            weights: measures.mapValues(\.total)
        )
    }

    nonisolated private static func canonicalProjection(
        in blocksByHash: [String: BlockMeta],
        workIndex: EulerWorkIndex
    ) -> (chainTip: String, mainChainHashes: Set<String>)? {
        let roots = blocksByHash.values
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
        guard let root = preferred(among: roots, workIndex: workIndex) else {
            return nil
        }
        let descent = blockGhostDescent(
            from: root,
            in: blocksByHash,
            workIndex: workIndex
        )
        if let descent {
            return (descent.tipHash, descent.blocks)
        }
        let direct = referenceGhostDescent(
            from: root,
            in: blocksByHash
        )
        return (direct.tipHash, direct.blocks)
    }

    /// Reference oracle with exclusions, used by differential tests: weights
    /// are pure work over the whole graph, and the descent never steps into an
    /// excluded root — work weighs, validity selects.
    nonisolated static func referenceCanonicalProjection(
        in blocksByHash: [String: BlockMeta],
        excluding excludedRoots: Set<String>
    ) -> (chainTip: String, mainChainHashes: Set<String>)? {
        let roots = blocksByHash.values
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
        let measures = effectiveSubtreeMeasures(
            startingAt: roots,
            retaining: Set(blocksByHash.keys),
            in: blocksByHash,
            strongestWork: strongestWorkByGrind(in: blocksByHash)
        )
        let weights = measures.mapValues(\.total)
        let selectable = roots.filter { !excludedRoots.contains($0) }
        guard let root = preferred(among: selectable, weights: weights) else { return nil }
        let descent = referenceGhostDescent(
            from: root,
            in: blocksByHash,
            weights: weights,
            excluding: excludedRoots
        )
        return (descent.tipHash, descent.blocks)
    }

    nonisolated private static func referenceCanonicalProjection(
        in blocksByHash: [String: BlockMeta],
        weights: [String: WorkSum]
    ) -> (chainTip: String, mainChainHashes: Set<String>)? {
        let roots = blocksByHash.values
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
        guard let root = preferred(among: roots, weights: weights) else { return nil }
        let descent = referenceGhostDescent(
            from: root,
            in: blocksByHash,
            weights: weights
        )
        return (descent.tipHash, descent.blocks)
    }

    /// Project the canonical path after one fork-choice mutation.
    ///
    /// `monotoneIncreaseAt` names the single block a strictly-positive work
    /// increase landed on — a new leaf, a newly grafted component root, or a
    /// stronger observation on a block already held. ONLY a mutation of that
    /// shape may pass it. That is what makes truncation sound: such an increase
    /// raises the subtree work of exactly the blocks on the mutated block's
    /// ancestor line and of nothing else, so at every canonical block below the
    /// point where that line leaves the canonical path, the child that already
    /// wins is the child that gained — it cannot lose, not even a CID tie-break
    /// it previously won, since it now wins strictly. No decision below that
    /// point can flip, so the path below it needs no recomputation.
    ///
    /// Exclusion removes no weight but changes which child is selectable, so a
    /// canonical exclusion forces a whole-chain projection, as do restore-replay
    /// and a never-projected state.
    private func projectCanonicalChain(
        forceFull: Bool = false,
        monotoneIncreaseAt mutatedAt: String? = nil
    ) -> ChainCommit? {
        defer { projectedGeneration = mutationGeneration }
        // A never-projected state has no trustworthy canonical path to truncate
        // against, and `forceFull` means the caller knows it cannot be trusted.
        if !forceFull, projectedGeneration != nil, let mutatedAt,
           let outcome = truncatedProjection(monotoneIncreaseAt: mutatedAt) {
            return outcome.commit
        }

        // Whole-chain fallback. Weights are pure work, so ONE projection path
        // serves the exclusion-free and exclusion-present cases alike;
        // `excluding` is empty in the common case (zero cost) and otherwise
        // only steers the descent past excluded roots — no parallel path.
        let roots = Array(indexToBlockHash[0] ?? []).filter {
            hashToBlock[$0]?.parentBlockHash == nil
                && !excludedRoots.contains($0)
        }
        guard let root = Self.preferred(among: roots, workIndex: subtreeWorkIndex)
        else { return nil }
#if DEBUG
        fullCanonicalProjectionCount += 1
#endif
        let descent = Self.blockGhostDescent(
            from: root,
            in: hashToBlock,
            workIndex: subtreeWorkIndex,
            excluding: excludedRoots
        ) ?? Self.referenceGhostDescent(
            from: root,
            in: hashToBlock,
            excluding: excludedRoots
        )
#if DEBUG
        // Descent steps ARE blocks now: with no quotient there is no hop to
        // take, so this column and the block column converge by construction.
        // The name is kept unchanged so one test measures both sides of the
        // deletion; what it counts is a block step, not a segment step.
        canonicalProjectionSegmentVisitCount += UInt64(descent.blocks.count)
        canonicalProjectionBlockVisitCount += UInt64(descent.blocks.count)
#endif
        let projection = (
            chainTip: descent.tipHash,
            mainChainHashes: descent.blocks
        )
        let newHashes = projection.mainChainHashes
        let newTip = projection.chainTip
        guard newTip != chainTip || newHashes != mainChainHashes else { return nil }

        let removed = mainChainHashes.subtracting(newHashes)
        let added = newHashes.subtracting(mainChainHashes).reduce(
            into: [String: UInt64]()
        ) { result, hash in
            if let height = hashToBlock[hash]?.blockHeight { result[hash] = height }
        }

        chainTip = newTip
        mainChainHashes = newHashes
        mainChainBlockAtIndex = [:]
        for hash in newHashes {
            if let height = hashToBlock[hash]?.blockHeight {
                mainChainBlockAtIndex[height] = hash
            }
        }
        tipSnapshot = tipSnapshotsByHash[newTip]
        return ChainCommit(
            tipHash: newTip,
            mainChainBlocksAdded: added,
            mainChainBlocksRemoved: removed
        )
    }

    /// Outcome of a mutation-point projection. A nil OUTCOME means truncation's
    /// assumptions could not be verified and the caller must re-materialize from
    /// the root; a nil `commit` inside one means the projection ran and nothing
    /// changed.
    private struct TruncatedProjectionOutcome {
        let commit: ChainCommit?
    }

    /// The deepest canonical block on the ancestor line of `mutatedAt`. Nil when
    /// that line reaches a root or a missing parent without meeting the
    /// canonical path — including a mutation under a different root.
    ///
    /// This walk is UNCAPPED deliberately. A step budget here is a cliff, not a
    /// budget: past it the caller falls through to the whole-chain projection,
    /// which pays a spine walk AND a descent from the root before it can
    /// discover that nothing moved. So a cap does not bound the cost of a deep
    /// divergence, it relocates it to O(n) per admission — reintroducing the
    /// quadratic this change exists to remove, on precisely the shape it exists
    /// to make cheap, and skipping the O(1) winner-unchanged check below, which
    /// only runs once a divergence point has been found.
    ///
    /// Uncapped, the walk is bounded by the length of the branch below the
    /// mutated block, which the node has already paid to admit, and every step
    /// is an O(1) set membership test. Termination does not rest on a budget:
    /// each step moves to a strictly lower height, and a parent that does not is
    /// a malformed route that fails closed like every other guard here.
    private func canonicalDivergencePoint(from mutatedAt: String) -> String? {
        var current = mutatedAt
        while !mainChainHashes.contains(current) {
            guard let meta = hashToBlock[current],
                  let parentHash = meta.parentBlockHash,
                  let parent = hashToBlock[parentHash],
                  parent.blockHeight < meta.blockHeight else { return nil }
            current = parentHash
        }
        return current
    }

    /// Re-descend from the divergence point instead of the root. Every guard
    /// here fails closed: the caller re-materializes whole rather than act on a
    /// partial answer.
    private func truncatedProjection(
        monotoneIncreaseAt mutatedAt: String
    ) -> TruncatedProjectionOutcome? {
        // A block that never routed into the quotient contributed no work and no
        // fork-choice edge — a routed parent always routes its child, so an
        // unrouted block's parent is unrouted or absent and no routed block's
        // visible children changed either. Nothing can have moved.
        guard subtreeWorkIndex.contains(mutatedAt) else {
            return TruncatedProjectionOutcome(commit: nil)
        }
        // The increase landed inside the subtree that already wins at every one
        // of its ancestors, so every canonical decision is reinforced and none
        // flips. This is the ordinary "stronger observation on a canonical
        // block" event, and it is now O(1) instead of a walk from the root.
        guard !mainChainHashes.contains(mutatedAt) else {
            return TruncatedProjectionOutcome(commit: nil)
        }
        guard let divergence = canonicalDivergencePoint(from: mutatedAt),
              let divergenceHeight = hashToBlock[divergence]?.blockHeight
        else { return nil }
        let (suffixHeight, overflow) = divergenceHeight.addingReportingOverflow(1)
        guard !overflow else { return nil }
        let children = excludedRoots.isEmpty
            ? (hashToBlock[divergence]?.childHashes ?? [])
            : (hashToBlock[divergence]?.childHashes ?? []).filter {
                !excludedRoots.contains($0)
            }
        // Every child of the divergence point is unselectable: the mutation
        // landed under an excluded root that is the only child of a canonical
        // block. The descent from the root provably ends at that block, so it
        // already is the tip and nothing moved. Decided in O(1) — this is the
        // steady state right after a canonical exclusion, when miners that have
        // not yet executed the block keep extending it, and it must not cost a
        // whole-chain projection per such block.
        guard !children.isEmpty else { return TruncatedProjectionOutcome(commit: nil) }
        // One GHOST step, taken exactly as the descent takes it: a lone child is
        // followed WITHOUT a weight lookup, matching the reference walk, so a
        // single-child step cannot depend on a weight comparison at all.
        let chosen = children.count == 1
            ? children[0]
            : Self.preferred(among: children, workIndex: subtreeWorkIndex)
        guard let chosen else { return nil }
        // The COMMON admission on a merged-mining child is a losing sibling, and
        // it must cost nothing. This point is the deepest canonical ancestor of
        // the mutated block, so the child leading to that block is never the
        // canonical one, and the increase is confined to its subtree. If the
        // winner here is therefore still the block already on the canonical
        // path, no decision changed anywhere — not here, not below it, not above
        // it — and there is nothing to materialize.
        //
        // This is decided in O(1), before reading the path above and before any
        // descent. Without it a losing sibling deep in the chain would
        // re-materialize everything from the fork point to the tip only to
        // conclude nothing moved, which is worse than the whole-chain early-out
        // this change removes.
        if mainChainHashes.contains(chosen) {
#if DEBUG
            truncatedCanonicalProjectionCount += 1
#endif
            return TruncatedProjectionOutcome(commit: nil)
        }
        guard let replaced = canonicalPathAbove(suffixHeight) else { return nil }
        // The suffix begins at a block taken straight from the divergence
        // point's own children, so the boundary below it holds by construction
        // rather than by assumption.
        guard let descent = Self.blockGhostDescent(
                  from: chosen,
                  in: hashToBlock,
                  workIndex: subtreeWorkIndex,
                  excluding: excludedRoots
              )
        else { return nil }
#if DEBUG
        canonicalProjectionSegmentVisitCount += UInt64(descent.blocks.count)
        canonicalProjectionBlockVisitCount += UInt64(descent.blocks.count)
        truncatedCanonicalProjectionCount += 1
#endif
        return TruncatedProjectionOutcome(commit: applyCanonicalDelta(
            tipHash: descent.tipHash,
            blocks: descent.blocks,
            replacing: replaced
        ))
    }

    /// The canonical blocks at and above `height`. Returns nil when the
    /// by-height index is not contiguous to the tip, so the caller
    /// re-materializes instead of trusting a partial removal set.
    private func canonicalPathAbove(_ height: UInt64) -> Set<String>? {
        guard let tipHeight = hashToBlock[chainTip]?.blockHeight else {
            return nil
        }
        var replaced = Set<String>()
        var current = height
        while current <= tipHeight {
            guard let hash = mainChainBlockAtIndex[current] else { return nil }
            replaced.insert(hash)
            current += 1
        }
        return replaced
    }

    /// Swap the canonical path `replaced` for the freshly materialized suffix.
    /// The prefix below it is unchanged, so membership and the by-height index
    /// are updated in place instead of rebuilt over the whole chain.
    private func applyCanonicalDelta(
        tipHash: String,
        blocks: Set<String>,
        replacing replaced: Set<String>
    ) -> ChainCommit? {
        // Both differences are unconditional, so they are correct whether or
        // not the replaced and suffix block sets overlap.
        let removed = replaced.subtracting(blocks)
        let added = blocks.subtracting(replaced).reduce(
            into: [String: UInt64]()
        ) { result, hash in
            if let height = hashToBlock[hash]?.blockHeight { result[hash] = height }
        }
        guard tipHash != chainTip || !removed.isEmpty || !added.isEmpty else {
            return nil
        }

        chainTip = tipHash
        mainChainHashes.subtract(removed)
        mainChainHashes.formUnion(added.keys)
        for hash in removed {
            guard let height = hashToBlock[hash]?.blockHeight,
                  mainChainBlockAtIndex[height] == hash else { continue }
            mainChainBlockAtIndex.removeValue(forKey: height)
        }
        for (hash, height) in added {
            mainChainBlockAtIndex[height] = hash
        }
        tipSnapshot = tipSnapshotsByHash[tipHash]
        return ChainCommit(
            tipHash: tipHash,
            mainChainBlocksAdded: added,
            mainChainBlocksRemoved: removed
        )
    }

    // MARK: - Orphan Detection

    func findEarliestOrphanConnectedToMainChain(blockHeader: String) -> String? {
        guard var current = hashToBlock[blockHeader] else { return nil }
        var currentHash = blockHeader

        while let prevHash = current.parentBlockHash,
              !mainChainHashes.contains(prevHash)
        {
            guard let prev = hashToBlock[prevHash] else { return nil }
            current = prev
            currentHash = prevHash
        }

        if current.parentBlockHash == nil {
            return current.blockHeight == 0 ? currentHash : nil
        }
        return currentHash
    }

}
