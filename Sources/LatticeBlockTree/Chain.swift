import cashew
import CID
import UInt256
import LatticePrimitives
import LatticePoW

public enum ChainStateRestoreError: Error, Sendable, Equatable {
    case corruptConsensusGraph
    case missingBlockFact
}

// MARK: - Concrete Types

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
    public let difficultyAnchor: DifficultyAnchor?
    public let work: WorkSum
    public var childHashes: [String]
    public let workContributions: [String: VerifiedWorkContribution]
    /// The contribution IDs here that are a parent's attributed runs (§9.10),
    /// not grinds. A run report subtracts the committer's GRINDS — what the
    /// child already holds — so a run attributed AT the committer stays in the
    /// run it serves and reaches the next level down.
    public let attributedRuns: Set<String>
    /// Directory → child block CID this block commits, read from its PoW-bound
    /// `children` index at admission and carried on the durable block fact, so
    /// live admission and replay see the same commitments (§9.10).
    /// Nil when NOT RECORDED — a fact written before this field existed — which
    /// is not "commits nothing": replay tolerates it, and a later fact for the
    /// same block supplies the real map (`BlockGraph.adoptChildCommitments`).
    public let childCommitments: [String: String]?

    /// Backward cumulative proof-of-work prefix measure from genesis through
    /// this block. Each physical grind has one block location in this chain.
    ///
    /// This is a derived diagnostic, rebuilt on demand from durable block work
    /// facts after recovery. It is never a fork-choice input or persisted
    /// source of truth.
    public let cumulativeWork: WorkSum

    /// The forward same-chain subtree measure, deduplicated by physical grind.
    /// This derived diagnostic is rebuilt on demand from accepted work facts.
    public let subtreeWeight: WorkSum

    package init(
        blockHash: String,
        parentBlockHash: String?,
        blockHeight: UInt64,
        childHashes: [String],
        workContributions: [VerifiedWorkContribution],
        cumulativeWork: WorkSum = .zero,
        subtreeWeight: WorkSum? = nil,
        difficultyAnchor: DifficultyAnchor? = nil,
        childCommitments: [String: String]? = nil
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
        // Attributed runs arrive as work-only facts after the block; a block is
        // built with its grinds alone.
        self.attributedRuns = []
    }

    /// The read view of one block the graph holds, assembled from its tables.
    init(
        record: BlockRecord,
        childHashes: [String],
        work: BlockWork,
        difficultyAnchor: DifficultyAnchor?,
        diagnostics: BlockDiagnostics
    ) {
        self.blockHash = record.blockHash
        self.parentBlockHash = record.parentBlockHash
        self.blockHeight = record.blockHeight
        self.childCommitments = record.childCommitments
        self.childHashes = childHashes
        self.workContributions = work.contributions
        self.attributedRuns = work.attributedRuns
        self.work = work.work
        self.difficultyAnchor = difficultyAnchor
        self.cumulativeWork = diagnostics.cumulativeWork
        self.subtreeWeight = diagnostics.subtreeWeight
    }
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
    /// Nil = not recorded on the fact (pre-field), never "commits nothing".
    let childCommitments: [String: String]?

    /// Requires an EXECUTED block.
    init(blockHeader: BlockHeader, block: Block) {
        blockHash = blockHeader.rawCID
        parentBlockHash = block.parent?.rawCID
        blockHeight = block.height
        timestamp = block.timestamp
        // Not enumerated on this test-only path: "not recorded", never a
        // silent "commits nothing".
        childCommitments = nil
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
        childCommitments = fact.childCommitments
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
    /// Set when the work fact is a parent's attributed run, not a grind.
    let attributedRun: AttributedRunIdentity?

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
        // An attributed run's marker names the identity its contribution ID is
        // the CID of, and only a work-only batch carries one: a block's own
        // work fact is its grind.
        if let attributedRun = work.attributedRun {
            guard blockFacts.isEmpty,
                  attributedRun.contributionID.flatMap(CIDIdentity.canonicalString)
                      == contributionID else {
                return nil
            }
        }
        self.attributedRun = work.attributedRun
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

public actor ChainState {
    var indexToBlockHash: [UInt64: Set<String>]
    /// The block tree: records, child edges, work facts, anchors and the
    /// diagnostic totals (BlockGraph.swift).
    var graph: BlockGraph
    /// GHOST weights, grind locations and excluded roots (ForkChoice.swift).
    var forkChoice: ForkChoice
    /// The canonical projection, the executed-from-genesis frontier and the
    /// state-transition index (ExecutionFrontier.swift).
    var frontier: ExecutionFrontier
    /// Parent-attributed run work (§9.10) for the served child directories
    /// (RunAttribution.swift).
    var runs: RunAttribution
    /// Diagnostic prefix/subtree totals are derived local views. They are not
    /// fork-choice inputs and are rebuilt only when an API exposes them.
    var localWorkCachesDirty: Bool

    /// Restore-replay defers the derived canonical projection: batches are
    /// durable, already-admitted facts, their commits are discarded, and no
    /// replay step reads the projection — so it is computed exactly once at
    /// the end of replay instead of per event.
    private var deferProjectionForReplay = false
    /// Advances for every successful consensus mutation.
    var mutationGeneration: UInt64
    /// Capacity held across the node's asynchronous stage boundary. These
    /// reservations are fungible and disappear on restart; staged facts replay
    /// against the same pre-stage revision floor.
    var reservedAdmissionRevisions: UInt64

    // Restore validates this invariant; optional access keeps query paths fail-closed.
    var highestBlockHeight: UInt64 { graph.height(of: chainTip) ?? 0 }

    /// Every held block's public read view, keyed by hash. Test-facing and
    /// O(N) — assembled on read; production reads `graph`.
    var hashToBlock: [String: BlockMeta] { graph.metas }

    package init(
        chainTip: String,
        mainChainHashes: Set<String>,
        indexToBlockHash: [UInt64: Set<String>],
        hashToBlock: [String: BlockMeta],
        tipSnapshot: TipBlockSnapshot? = nil,
        tipSnapshotsByHash: [String: TipBlockSnapshot] = [:],
        validatedBlocks: Set<String> = [],
        mutationGeneration: UInt64 = 0
    ) throws {
        // Every graph read keys a block by its own hash, so a map entry filed
        // under any other key is a corrupt graph, not a second name.
        guard hashToBlock.allSatisfy({ $0.key == $0.value.blockHash }),
              hashToBlock.values.allSatisfy({ meta in
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
        self.graph = BlockGraph(hashToBlock)
        self.forkChoice = ForkChoice()
        self.localWorkCachesDirty = true
        var allByHeight = indexToBlockHash
        for meta in hashToBlock.values {
            allByHeight[meta.blockHeight, default: []].insert(meta.blockHash)
        }
        self.indexToBlockHash = allByHeight
        self.mutationGeneration = mutationGeneration
        self.reservedAdmissionRevisions = 0
        for meta in hashToBlock.values {
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
        guard Self.hasUniqueWorkLocations(in: self.graph) else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        self.forkChoice = ForkChoice.build(from: self.graph)
        // Seed the executed-from-genesis frontier. Replay hands validations to
        // `markValidated` one at a time, but a graph restored wholesale needs
        // it computed once, downward from every genesis it holds.
        self.frontier = try ExecutionFrontier(
            chainTip: chainTip,
            mainChainHashes: mainChainHashes,
            tipSnapshot: tipSnapshot,
            snapshots: tipSnapshotsByHash,
            validated: validatedBlocks,
            in: self.graph,
            excluded: self.forkChoice.excludedRoots
        )
        // Runs (§9.10) are settled by `serveRuns(for:)`, one directory at a
        // time, through the same per-block step live admission uses — one
        // algorithm, not a rebuild twin. Connectivity IS the weight index:
        // every connected block routes, excluded or not (§9.9).
        self.runs = RunAttribution()
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
        frontier.refreshTipSnapshot()
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

    public func contains(blockHash: String) -> Bool {
        graph.contains(blockHash)
    }

    public func currentRevision() -> UInt64 {
        mutationGeneration
    }

    /// Same-chain acquisition needs are every unresolved immediate edge:
    /// absent predecessors and accepted-but-unconnected predecessors alike.
    /// Height order makes this linear after the deterministic sort, rather
    /// than walking the same orphan suffix once per descendant.
    public func unresolvedSameChainPredecessors() -> [SameChainPredecessorRequirement] {
        let ordered = graph.records.sorted {
            if $0.blockHeight != $1.blockHeight {
                return $0.blockHeight < $1.blockHeight
            }
            return $0.blockHash < $1.blockHash
        }
        var connected = Set<String>()
        connected.reserveCapacity(ordered.count)
        for block in ordered {
            let key = block.blockHash
            guard let predecessor = block.parentBlockHash else {
                if block.blockHeight == 0 {
                    connected.insert(key)
                }
                continue
            }
            guard let parent = graph[predecessor] else { continue }
            let (expectedHeight, overflow) = parent.blockHeight
                .addingReportingOverflow(1)
            if !overflow,
               expectedHeight == block.blockHeight,
               connected.contains(predecessor)
            {
                connected.insert(key)
            }
        }
        return graph.records.compactMap { block in
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

    package func sameChainPredecessorRequirement(
        for descendantCID: String
    ) -> SameChainPredecessorRequirement? {
        graph[descendantCID].flatMap(sameChainPredecessorRequirement(for:))
    }

    private func sameChainPredecessorRequirement(
        for block: BlockRecord
    ) -> SameChainPredecessorRequirement? {
        guard let parent = block.parentBlockHash,
              !hasConnectedAncestry(blockHash: parent) else { return nil }
        return SameChainPredecessorRequirement(
            descendantCID: block.blockHash,
            predecessorCID: parent
        )
    }

    public func getConsensusBlock(hash: String) -> BlockMeta? {
        guard graph.contains(hash) else { return nil }
        materializeLocalWorkCachesIfNeeded()
        return graph.meta(of: hash)
    }

    public func getHighestBlockHeight() -> UInt64 {
        highestBlockHeight
    }

#if DEBUG
    /// Test-only view of the excluded roots so a differential test can drive
    /// the reference oracle with the same unselectable set.
    var excludedRootsForTesting: Set<String> {
        forkChoice.excludedRoots
    }
#endif

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
        while let step = current, let meta = graph[step] {
            if let anchor = graph.difficultyAnchor(of: step) {
                resolved = anchor
                break
            }
            unresolved.append(step)
            guard meta.blockHeight > 1 else { break }
            current = meta.parentBlockHash
        }
        guard let anchor = resolved else { return nil }
        for step in unresolved {
            graph.adoptDifficultyAnchor(anchor, at: step)
        }
        return anchor
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

        guard forkChoice.acceptsLocation(of: contribution.id, at: blockHash) else {
            return .discarded()
        }

        if graph.contains(blockHash) {
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
            anchor = graph.difficultyAnchor(of: parentHash)
        } else {
            anchor = nil
        }
        graph.insert(
            BlockRecord(
                blockHash: blockHash,
                parentBlockHash: input.parentBlockHash,
                blockHeight: input.blockHeight,
                childCommitments: input.childCommitments
            ),
            children: childHashes,
            difficultyAnchor: anchor
        )
        indexStateTransition(input.snapshot, blockHash: blockHash)
        if let prevHash = input.parentBlockHash {
            graph.appendChild(blockHash, to: prevHash)
        }
        for contribution in contributions {
            // A block arrives with its grinds; attributed runs come later, as
            // work-only facts.
            applyLocalContribution(contribution, to: blockHash, attributed: false)
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
        // Runs (§9.10): a block that just routed — alone, or as the root of a
        // grafted orphan component — is connected, and so is every descendant
        // it grafted in. Unfiltered: an excluded descendant routes and is
        // credited like any other. An orphan is not routed and is settled the
        // moment its component grafts.
        // Nothing to settle while no directory is served: skip the walk, which
        // on a graft would otherwise be a third pass over the component.
        if !runs.served.isEmpty, forkChoice.isRouted(blockHash) {
            connectForRunAttribution(rootedAt: blockHash)
        }

        for contribution in contributions {
            forkChoice.applyContribution(contribution, at: blockHash)
        }

        return SubmissionResult(
            addedBlock: true,
            addedContribution: addedContribution,
            extendsMainChain: false
        )
    }

    nonisolated private static func hasUniqueWorkLocations(
        in blocks: BlockGraph
    ) -> Bool {
        var locationByGrind: [String: String] = [:]
        func observe(_ grindID: String, at blockHash: String) -> Bool {
            guard locationByGrind[grindID].map({ $0 == blockHash }) ?? true else {
                return false
            }
            locationByGrind[grindID] = blockHash
            return true
        }
        for block in blocks.records {
            let blockHash = block.blockHash
            for grindID in (blocks.work(of: blockHash)?.contributions ?? [:]).keys
            where !observe(grindID, at: blockHash) {
                return false
            }
        }
        return true
    }

    // MARK: - Additional proof facts

    func addWorkContribution(
        _ contribution: VerifiedWorkContribution,
        to blockHash: String,
        attributedRun: AttributedRunIdentity? = nil
    ) -> SubmissionResult {
        guard graph.contains(blockHash),
              forkChoice.acceptsLocation(of: contribution.id, at: blockHash) else {
            return .discarded()
        }
        if let existing = workContribution(id: contribution.id, at: blockHash),
           existing.work >= contribution.work {
            return .discarded()
        }
        guard hasUnreservedMutationCapacity else { return .discarded() }
        let workBefore = graph.work(of: blockHash)?.work ?? .zero
        applyLocalContribution(contribution, to: blockHash, attributed: attributedRun != nil)
        // A strengthening raises this block's own work, so its run (§9.10)
        // rises by exactly that delta — once the block is connected. An
        // orphan's work is credited in full at the moment it connects.
        if forkChoice.isRouted(blockHash),
           let workAfter = graph.work(of: blockHash)?.work,
           let delta = workAfter.subtracting(workBefore) {
            runs.credit(delta, at: blockHash)
        }
        // A stronger observation on an excluded block weighs like any other: it
        // raises every ancestor, and the descent still never steps into the
        // excluded root, so no invalid block is resurrected by piling on work.
        forkChoice.applyContribution(contribution, at: blockHash)
        mutationGeneration += 1

        // A contribution only reaches here when it is strictly stronger than what
        // this block already held, so fork choice saw a positive increase at
        // exactly one point.
        let canonicalChange = deferProjectionForReplay
            ? nil
            : projectCanonicalChain(monotoneIncreaseAt: blockHash)
        if canonicalChange != nil {
            frontier.refreshTipSnapshot()
        }
        return SubmissionResult(
            addedBlock: false,
            addedContribution: true,
            extendsMainChain: false,
            commit: (canonicalChange ?? ChainCommit(tipHash: chainTip))
                .atRevision(mutationGeneration)
        )
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
            guard graph.contains(validated) else {
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
            if let existing = graph[input.blockHash] {
                guard matchesGraph(existing, input: input),
                      frontier.snapshot(of: input.blockHash).map({
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
                    to: input.blockHash,
                    attributedRun: trusted.attributedRun
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
        guard graph.contains(blockHash) else {
            throw ChainStateRestoreError.missingBlockFact
        }
        if let existing = workContribution(
            id: trusted.contribution.id,
            at: blockHash
        ), existing.work >= trusted.contribution.work {
            return nil
        }
        let submission = addWorkContribution(
            trusted.contribution, to: blockHash, attributedRun: trusted.attributedRun
        )
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

    /// An exclusion batch is exactly one `.exclusion` fact. Any other shape is
    /// handled by the block/work reducer.
    private static func exclusionTarget(of batch: ChainAdmissionBatch) -> String? {
        guard batch.facts.count == 1,
              case .exclusion(let fact) = batch.facts[0] else { return nil }
        return CIDIdentity.canonicalString(fact.blockHash)
    }

    /// Record a proven-invalid subtree root. The block must already be present:
    /// a not-yet-connected exclusion defers exactly like a work fact whose block
    /// has not arrived, so replay retries it once the subtree exists.
    private func applyExclusion(blockHash: String) throws -> SubmissionResult? {
        guard graph.contains(blockHash) else {
            throw ChainStateRestoreError.missingBlockFact
        }
        // Idempotent: a duplicate exclusion adds nothing and cannot reorg.
        if forkChoice.excludedRoots.contains(blockHash) { return nil }
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
        if graph.parent(of: blockHash) == nil,
           !hasExecutedRoot(besides: blockHash) {
            throw deferProjectionForReplay
                ? ChainStateRestoreError.missingBlockFact
                : ChainStateRestoreError.corruptConsensusGraph
        }
        forkChoice.exclude(blockHash)
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
            frontier.refreshTipSnapshot()
        }
        return SubmissionResult(
            addedBlock: false,
            addedContribution: false,
            extendsMainChain: false,
            commit: (canonicalChange ?? ChainCommit(tipHash: chainTip))
                .atRevision(mutationGeneration)
        )
    }

    /// Rebuild one already-durable admission fact during recovery. Callers must
    /// authenticate and persist the fact before invoking this public seam.
    public func replay(_ batch: ChainAdmissionBatch) throws -> ChainCommit? {
        try applyStaged(batch)?.commit
    }

    /// Reserve one distinct U64 commit revision before the node stages a batch.
    /// Other actor mutations must leave this capacity available until the batch
    /// either fails staging or consumes the reservation synchronously.
    package func reserveAdmissionRevision() -> Bool {
        guard hasUnreservedMutationCapacity else { return false }
        reservedAdmissionRevisions += 1
        return true
    }

    package func releaseAdmissionRevision() {
        precondition(reservedAdmissionRevisions > 0)
        reservedAdmissionRevisions -= 1
    }

    package func applyReservedStaged(
        _ batch: ChainAdmissionBatch
    ) throws -> SubmissionResult? {
        guard reservedAdmissionRevisions > 0 else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        reservedAdmissionRevisions -= 1
        return try applyStaged(batch)
    }

    var hasUnreservedMutationCapacity: Bool {
        reservedAdmissionRevisions < UInt64.max - mutationGeneration
    }

    private func matchesGraph(_ meta: BlockRecord, input: ConsensusBlockInput) -> Bool {
        meta.blockHash == input.blockHash
            && meta.parentBlockHash == input.parentBlockHash
            && meta.blockHeight == input.blockHeight
            // Commitments are PoW-bound content, so two honest facts for one
            // block agree; a disagreement is a graph conflict, rejected — never
            // resolved by whichever fact happened to replay first. A fact that
            // recorded none (pre-field) conflicts with nothing.
            && (meta.childCommitments == nil || input.childCommitments == nil
                || meta.childCommitments == input.childCommitments)
    }

    private func hydrateMetadata(from input: ConsensusBlockInput) {
        indexStateTransition(input.snapshot, blockHash: input.blockHash)
        // The index above just recorded `input.snapshot` for this block.
        if chainTip == input.blockHash {
            frontier.refreshTipSnapshot()
        }
        if let commitments = input.childCommitments {
            adoptChildCommitments(commitments, at: input.blockHash)
        }
    }

    /// A later fact supplies commitments a pre-field fact left unrecorded. If
    /// the block was already settled as a non-committer in a served directory
    /// it now commits into, that directory's runs are re-settled from scratch:
    /// O(N), exact, and reachable only at the upgrade boundary.
    private func adoptChildCommitments(_ commitments: [String: String], at hash: String) {
        guard let meta = graph[hash], meta.childCommitments == nil else { return }
        graph.adoptChildCommitments(commitments, at: hash)
        guard forkChoice.isRouted(hash) else { return }
        for directory in runs.served where commitments[directory] != nil {
            runs.forget(directory: directory)
            serveRuns(for: directory)
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
        return forkChoice.isRouted(parentHash)
    }

    func addToBlockIndex(hash: String, blockHeight: UInt64) {
        indexToBlockHash[blockHeight, default: []].insert(hash)
    }

    func findChildren(hash: String, blockHeight: UInt64) -> [String] {
        let (childHeight, overflow) = blockHeight.addingReportingOverflow(1)
        guard !overflow, let hashes = indexToBlockHash[childHeight] else { return [] }
        return hashes.filter { graph.parent(of: $0) == hash }
    }

}

extension ChainState: DifficultyAnchorSource {}
