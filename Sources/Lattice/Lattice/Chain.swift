import cashew
import CID
import UInt256

/// Compute proof-of-work for a given target threshold.
/// Higher target value = easier proof; work is inversely proportional.
public func workForTarget(_ target: UInt256) -> UInt256 {
    guard target > UInt256.zero else { return UInt256.zero }
    return UInt256.max / target
}

/// Work demonstrated by one observed hash. This is used for the setup-wide
/// traversal floor, which is deliberately independent of any chain target.
public func workForHash(_ hash: UInt256) -> UInt256 {
    hash == .zero ? .max : .max / hash
}

/// Stable tie-break for equal-work segment bases. Compare the CID bytes rather
/// than an encoded presentation string; malformed values remain deterministic
/// so persistence validation can reject them without order-dependent behavior.
func forkChoicePrefersSegmentBase(
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

// MARK: - Concrete Types

public struct BlockMeta: Sendable {
    public let blockHash: String
    public let parentBlockHash: String?
    public let blockHeight: UInt64
    public private(set) var work: WorkSum
    public var childHashes: [String]
    public private(set) var workContributions: [String: VerifiedWorkContribution]

    /// Backward cumulative proof-of-work prefix sum: the total work of this
    /// block's own chain from genesis up to and including this block,
    /// `cumulativeWork(B) = cumulativeWork(B.parent) + work(B)`.
    ///
    /// Stored so it remains exact across persistence round-trips.
    ///
    /// Mutable only so a block inserted before its own-chain parent (out-of-order
    /// delivery) can be repaired once the parent — and thus its true prefix —
    /// becomes known; see `ChainState.propagateCumulativeWork(from:)`.
    public private(set) var cumulativeWork: WorkSum

    /// The **forward** same-chain subtree weight:
    /// `subtreeWeight(B) = work(B) + Σ_{c ∈ children(B)} subtreeWeight(c)`, the
    /// total work of `B`'s descendant subtree on this chain, counting each block
    /// once (docs/consensus-fork-choice.md §3, §6). This is the GHOST quantity
    /// the fork-choice weight is built from — the *descendant* dual of the
    /// *ancestor* `cumulativeWork` prefix sum. Forks do not enter its definition:
    /// a block either descends from `B` or not. Maintained bottom-up and repaired
    /// up the ancestor chain on insert (`propagateSubtreeWeight(from:)`), so it is
    /// correct under out-of-order delivery because the consensus graph is retained.
    ///
    /// `subtreeWeight` is local to this chain. Cross-chain proofs add immutable
    /// work contributions to blocks; fork choice never reads another live chain.
    public private(set) var subtreeWeight: WorkSum

    package init(
        blockHash: String,
        parentBlockHash: String?,
        blockHeight: UInt64,
        childHashes: [String],
        workContributions: [VerifiedWorkContribution],
        cumulativeWork: WorkSum = .zero,
        subtreeWeight: WorkSum? = nil
    ) {
        let contributions = Dictionary(
            workContributions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let work = contributions.values.reduce(WorkSum.zero) { $0 + $1.work }
        self.blockHash = blockHash
        self.parentBlockHash = parentBlockHash
        self.blockHeight = blockHeight
        self.work = work
        self.childHashes = childHashes
        self.workContributions = contributions
        self.cumulativeWork = cumulativeWork
        // A freshly-inserted leaf's subtree is just itself; the bottom-up repair
        // (`propagateSubtreeWeight`) folds in any out-of-order children. Default to
        // own work so a block always weighs at least itself.
        self.subtreeWeight = subtreeWeight ?? work
    }

    /// Internal-only: the cumulative-work prefix sum is repaired solely by
    /// `ChainState.propagateCumulativeWork(from:)` (same module). External
    /// callers set the initial value via `init`, not by mutating a copy.
    mutating func setCumulativeWork(_ value: WorkSum) {
        cumulativeWork = value
    }

    /// Internal-only: the forward subtree weight is maintained solely by
    /// `ChainState.propagateSubtreeWeight(from:)` (same module).
    mutating func setSubtreeWeight(_ value: WorkSum) {
        subtreeWeight = value
    }

    mutating func addWorkContribution(_ contribution: VerifiedWorkContribution) -> Bool {
        guard workContributions[contribution.id] == nil else { return false }
        workContributions[contribution.id] = contribution
        work = work + contribution.work
        return true
    }

}

struct WorkContributionRecord: Sendable, Equatable {
    let blockHash: String
    let contribution: VerifiedWorkContribution
}

public struct SubmissionResult: Sendable {
    public let addedBlock: Bool
    public let addedContribution: Bool
    public let extendsMainChain: Bool
    public let needsParentBlock: Bool
    public let commit: ChainCommit?

    init(
        addedBlock: Bool,
        addedContribution: Bool = false,
        extendsMainChain: Bool,
        needsParentBlock: Bool,
        commit: ChainCommit? = nil
    ) {
        self.addedBlock = addedBlock
        self.addedContribution = addedContribution
        self.extendsMainChain = extendsMainChain
        self.needsParentBlock = needsParentBlock
        self.commit = commit
    }

    public static func extendsMainChain(
        addedContribution: Bool = true,
        commit: ChainCommit
    ) -> Self {
        SubmissionResult(
            addedBlock: true,
            addedContribution: addedContribution,
            extendsMainChain: true,
            needsParentBlock: false,
            commit: commit
        )
    }

    public static func discarded() -> Self {
        SubmissionResult(addedBlock: false, addedContribution: false, extendsMainChain: false, needsParentBlock: false)
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

    init(blockHeader: BlockHeader, block: Block) {
        blockHash = blockHeader.rawCID
        parentBlockHash = block.parent?.rawCID
        blockHeight = block.height
        timestamp = block.timestamp
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
        guard (try? CID(fact.blockHash)) != nil,
              fact.parentBlockHash.map({ (try? CID($0)) != nil }) ?? true,
              (try? CID(fact.postStateCID)) != nil,
              (try? CID(fact.prevStateCID)) != nil,
              (try? CID(fact.specCID)) != nil,
              let target = UInt256(fact.target, radix: 16), target > .zero,
              let nextTarget = UInt256(fact.nextTarget, radix: 16), nextTarget > .zero,
              (fact.parentBlockHash == nil) == (fact.blockHeight == 0) else {
            return nil
        }
        blockHash = fact.blockHash
        parentBlockHash = fact.parentBlockHash
        blockHeight = fact.blockHeight
        timestamp = fact.timestamp
        snapshot = TipBlockSnapshot(
            postStateCID: fact.postStateCID,
            prevStateCID: fact.prevStateCID,
            specCID: fact.specCID,
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
        guard workFacts.count == 1,
              let work = workFacts.first,
              work.contribution.work > .zero,
              (try? CID(work.blockHash)) != nil,
              (try? CID(work.contribution.id)) != nil else {
            return nil
        }

        switch blockFacts.count {
        case 0:
            guard batch.facts.count == 1 else { return nil }
            block = nil
        case 1:
            guard batch.facts.count == 2,
                  let input = ConsensusBlockInput(fact: blockFacts[0]),
                  work.blockHash == input.blockHash else {
                return nil
            }
            block = input
        default:
            return nil
        }
        workBlockHash = work.blockHash
        contribution = work.contribution
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

    /// One physical grind may contribute to only one block in this chain.
    var workContributionIndex: [String: WorkContributionRecord]

    var mainChainBlockAtIndex: [UInt64: String]
    var blockTimestamps: [String: Int64]
    /// Advances for every visible chain insertion or replacement. Admission
    /// captures it before node persistence and refuses a stale mutation.
    var mutationGeneration: UInt64

    public private(set) var tipSnapshot: TipBlockSnapshot?
    var tipSnapshotsByHash: [String: TipBlockSnapshot]

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
        mutationGeneration: UInt64 = 0
    ) throws {
        self.chainTip = chainTip
        self.mainChainHashes = mainChainHashes
        guard hashToBlock.values.allSatisfy({
            Set($0.childHashes).count == $0.childHashes.count
        }) else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        self.hashToBlock = hashToBlock
        var allByHeight = indexToBlockHash
        for meta in hashToBlock.values {
            allByHeight[meta.blockHeight, default: []].insert(meta.blockHash)
        }
        self.indexToBlockHash = allByHeight
        self.workContributionIndex = [:]
        self.tipSnapshot = tipSnapshot
        self.tipSnapshotsByHash = tipSnapshotsByHash
        if let tipSnapshot {
            self.tipSnapshotsByHash[chainTip] = tipSnapshot
        }
        self.blockTimestamps = blockTimestamps
        self.mutationGeneration = mutationGeneration
        self.mainChainBlockAtIndex = [:]
        Self.recomputeSubtreeWeights(in: &self.hashToBlock)
        for hash in mainChainHashes {
            guard let height = self.hashToBlock[hash]?.blockHeight,
                  self.mainChainBlockAtIndex[height] == nil else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            self.mainChainBlockAtIndex[height] = hash
        }
        for (blockHash, meta) in self.hashToBlock {
            let contributions = meta.workContributions.values
            guard !contributions.isEmpty,
                  contributions.allSatisfy({ $0.work > .zero }),
                  contributions.reduce(WorkSum.zero, { $0 + $1.work }) == meta.work else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            for contribution in contributions {
                let record = WorkContributionRecord(
                    blockHash: blockHash,
                    contribution: contribution
                )
                if let existing = self.workContributionIndex[contribution.id],
                   existing != record {
                    throw ChainStateRestoreError.corruptConsensusGraph
                }
                self.workContributionIndex[contribution.id] = record
            }
        }
    }

    func currentMutationGeneration() -> UInt64 {
        mutationGeneration
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
            tipSnapshot: Self.snapshot(for: block)
        )
    }

    private static func fromTrustedGenesis(
        input: ConsensusBlockInput,
        contribution: VerifiedWorkContribution
    ) throws -> ChainState {
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
            cumulativeWork: WorkSum(contribution.work)
        )
        return try ChainState(
            chainTip: input.blockHash,
            mainChainHashes: [input.blockHash],
            indexToBlockHash: [0: [input.blockHash]],
            hashToBlock: [input.blockHash: meta],
            blockTimestamps: [input.blockHash: input.timestamp],
            tipSnapshot: input.snapshot
        )
    }

    /// Restore a child process whose staged genesis batch reached durable storage
    /// before the in-memory actor was created.
    public static func restore(
        replaying batches: [ChainAdmissionBatch]
    ) async throws -> ChainState {
        guard let trusted = batches.lazy.compactMap(TrustedAdmissionBatch.init).first(where: {
            $0.block?.parentBlockHash == nil && $0.block?.blockHeight == 0
        }), let input = trusted.block else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        let chain = try fromTrustedGenesis(
            input: input,
            contribution: trusted.contribution
        )
        // The node may enumerate its durable facts in any order. Replay the seed
        // batch too: its existing block/work record makes that a no-op.
        try await replay(batches[...], onto: chain)
        return chain
    }

    /// Restore a snapshot and then replay durable admission batches that may have
    /// reached node storage immediately before a crash. Replaying all retained
    /// batches is safe: duplicate facts are idempotent.
    public static func restore(
        from persisted: PersistedChainState,
        replaying batches: [ChainAdmissionBatch]
    ) async throws -> ChainState {
        let chain = try restore(from: persisted)
        try await replay(batches[...], onto: chain)
        return chain
    }

    private static func replay(
        _ batches: ArraySlice<ChainAdmissionBatch>,
        onto chain: ChainState
    ) async throws {
        var pending = Array(batches)
        while !pending.isEmpty {
            var deferred: [ChainAdmissionBatch] = []
            var completed = false
            for batch in pending {
                do {
                    _ = try await chain.replay(batch)
                    completed = true
                } catch ChainStateRestoreError.missingBlockFact {
                    deferred.append(batch)
                }
            }
            guard completed else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            pending = deferred
        }
    }

    static func snapshot(from block: PersistedBlockMeta) -> TipBlockSnapshot? {
        guard let postStateCID = block.postStateCID,
              let prevStateCID = block.prevStateCID,
              let specCID = block.specCID,
              let targetHex = block.target,
              let nextTargetHex = block.nextTarget,
              let timestamp = block.timestamp,
              let target = UInt256(targetHex, radix: 16),
              let nextTarget = UInt256(nextTargetHex, radix: 16)
        else {
            return nil
        }
        return TipBlockSnapshot(
            postStateCID: postStateCID,
            prevStateCID: prevStateCID,
            specCID: specCID,
            target: target,
            nextTarget: nextTarget,
            tipHeight: block.blockHeight,
            timestamp: timestamp
        )
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
        hashToBlock[blockHash] != nil
    }

    /// Whether `blockHash` belongs to a complete accepted path ending at one of
    /// this path-defined chain's admitted genesis roots. Parent processes issue
    /// cross-process facts only for blocks with validated ancestry.
    func hasValidatedAncestry(blockHash: String) -> Bool {
        var visited = Set<String>()
        var current = blockHash
        while true {
            guard visited.insert(current).inserted,
                  let meta = hashToBlock[current] else { return false }
            guard let parentHash = meta.parentBlockHash else {
                return meta.blockHeight == 0
            }
            guard let parent = hashToBlock[parentHash] else { return false }
            let (expectedHeight, overflow) = parent.blockHeight.addingReportingOverflow(1)
            guard !overflow, expectedHeight == meta.blockHeight else { return false }
            current = parentHash
        }
    }

    public func getMainChainTip() -> String {
        chainTip
    }

    public func isOnMainChain(hash: String) -> Bool {
        guard let height = hashToBlock[hash]?.blockHeight else { return false }
        return mainChainBlockAtIndex[height] == hash
    }

    /// Sum work for up to `limit` ancestors from the current tip.
    public func getCumulativeWork(limit: UInt64) -> WorkSum {
        var total = WorkSum.zero
        var current: String? = chainTip
        var walked: UInt64 = 0
        while let hash = current, walked <= limit {
            guard let meta = hashToBlock[hash] else { break }
            total = total + meta.work
            current = meta.parentBlockHash
            walked += 1
        }
        return total
    }

    /// Exact total proof-of-work from genesis to the current chain tip.
    public func getTipCumulativeWork() -> WorkSum {
        highestBlock?.cumulativeWork ?? .zero
    }

    /// Exact genesis-relative cumulative work at a specific block, or nil if the
    /// block is unknown.
    public func getCumulativeWork(forHash hash: String) -> WorkSum? {
        hashToBlock[hash]?.cumulativeWork
    }

    /// The forward same-chain subtree weight of `hash`
    /// — the total work of its descendant subtree on this chain, counting each
    /// block once (design §3/§6). This is the GHOST quantity the fork-choice weight
    /// is built from; for a tip it equals the block's own work, for an interior
    /// block the sum of itself and everything that builds on it across all forks.
    public func subtreeWeight(forHash hash: String) -> WorkSum? {
        hashToBlock[hash]?.subtreeWeight
    }

    /// Test-facing (via `@testable`): the index-computed heaviest leaf below `hash`
    /// and its durable cumulative work. Production fork choice runs through
    /// `checkForReorg`.
    func heaviestDescent(fromHash hash: String) -> (tipHash: String, cumulativeWork: WorkSum)? {
        guard let start = hashToBlock[hash] else { return nil }
        let descent = ghostDescent(from: start)
        guard let work = hashToBlock[descent.tipHash]?.cumulativeWork else { return nil }
        return (descent.tipHash, work)
    }

    /// The fork base of the branch ending at `leaf`: its deepest ancestor that is NOT
    /// on the current main chain (the sibling of the main-chain block at that height),
    /// found by riding parent linkage up until the parent lands on the
    /// main chain. This is the block reorg evaluation starts `chainWithMostWork` from.
    /// A competing parentless height-0 root is its own base.
    /// Returns `nil` when `leaf` is already on the main chain (no divergence — the
    /// incumbent already contains it) or its linkage cannot be traced to the main chain.
    private func forkBaseOffMainChain(ofLeaf leaf: String) -> String? {
        guard let leafHeight = hashToBlock[leaf]?.blockHeight,
              mainChainBlockAtIndex[leafHeight] != leaf else { return nil }
        var cursor = leaf
        while true {
            guard let parent = previousHash(of: cursor) else {
                return hashToBlock[cursor]?.blockHeight == 0 ? cursor : nil
            }
            guard let parentHeight = hashToBlock[parent]?.blockHeight else { return nil }
            if mainChainBlockAtIndex[parentHeight] == parent {
                // `cursor`'s parent is on the main chain ⇒ `cursor` is the fork base.
                return cursor
            }
            cursor = parent
        }
        return nil
    }

    /// Public simulator/test view of the real local fork-choice descent.
    public func forkChoiceSnapshot(startingAt hash: String) -> ForkChoiceSnapshot? {
        guard let meta = hashToBlock[hash] else { return nil }
        let choice = chainWithMostWork(startingBlock: meta)
        return ForkChoiceSnapshot(
            startingHash: hash,
            subtreeWork: choice.subtreeWork,
            tipHash: choice.tipHash,
            mainChainPath: choice.blocks
        )
    }

    public func getConsensusBlock(hash: String) -> BlockMeta? {
        hashToBlock[hash]
    }

    public func getHighestBlock() -> BlockMeta? {
        highestBlock
    }

    public func getHighestBlockHeight() -> UInt64 {
        highestBlockHeight
    }

    public func getMainChainBlockHash(atIndex index: UInt64) -> String? {
        mainChainBlockAtIndex[index]
    }

    /// Return up to `count` ancestor timestamps newest-first, ending at `parentHash`.
    /// Fast path: walks the main-chain side index via `mainChainBlockAtIndex` +
    /// `blockTimestamps`, avoiding fetcher round-trips. Returns nil if `parentHash`
    /// is not on the current main chain, or if any timestamp in the requested
    /// window is missing (e.g. pre-upgrade persisted data) — callers should fall
    /// back to a fetcher walk.
    public func getMainChainTimestamps(forParentHash parentHash: String, count: UInt64) -> [Int64]? {
        guard count > 0 else { return [] }
        guard let parent = hashToBlock[parentHash] else { return nil }
        guard mainChainBlockAtIndex[parent.blockHeight] == parentHash else { return nil }
        var result: [Int64] = []
        result.reserveCapacity(Int(count))
        var idx = parent.blockHeight
        for _ in 0..<count {
            guard let hash = mainChainBlockAtIndex[idx] else { break }
            guard let ts = blockTimestamps[hash] else { return nil }
            result.append(ts)
            if idx == 0 { break }
            idx -= 1
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

        if contribution.work == .zero || (isRoot && input.blockHeight != 0) {
            return .discarded()
        }

        if let existing = workContributionIndex[contribution.id],
           existing != WorkContributionRecord(
            blockHash: blockHash,
            contribution: contribution
           ) {
            return .discarded()
        }

        if hashToBlock[blockHash] != nil {
            return addWorkContribution(contribution, to: blockHash)
        }

        let result = insertBlock(
            input: input,
            contributions: [contribution],
            addedContribution: true
        )
        if !result.addedBlock { return result }
        mutationGeneration &+= 1

        var commit = result.commit ?? ChainCommit(tipHash: chainTip)
        if !result.extendsMainChain,
           !result.needsParentBlock,
           let canonicalChange = checkForReorgWithoutRevision(block: hashToBlock[blockHash]!) {
            commit = canonicalChange
        }
        return SubmissionResult(
            addedBlock: true,
            addedContribution: result.addedContribution,
            extendsMainChain: result.extendsMainChain,
            needsParentBlock: result.needsParentBlock,
            commit: commit.atRevision(mutationGeneration)
        )
    }

    // MARK: - Insert

    private func insertBlock(
        input: ConsensusBlockInput,
        contributions: [VerifiedWorkContribution],
        addedContribution: Bool
    ) -> SubmissionResult {
        let blockHash = input.blockHash
        guard !contributions.isEmpty,
              Set(contributions.map(\.id)).count == contributions.count,
              contributions.allSatisfy({ $0.work > .zero }),
              !(input.parentBlockHash == nil && input.blockHeight != 0)
        else {
            return .discarded()
        }
        for contribution in contributions {
            if let existing = workContributionIndex[contribution.id],
               existing != WorkContributionRecord(
                blockHash: blockHash,
                contribution: contribution
               ) {
                return .discarded()
            }
        }
        addToBlockIndex(hash: blockHash, blockHeight: input.blockHeight)

        let ownWork = contributions.reduce(WorkSum.zero) { $0 + $1.work }
        let parentCumulativeWork: WorkSum
        if let parentHash = input.parentBlockHash {
            parentCumulativeWork = hashToBlock[parentHash]?.cumulativeWork ?? .zero
        } else {
            parentCumulativeWork = .zero
        }
        let blockCumulativeWork = parentCumulativeWork + ownWork
        let childHashes = findChildren(hash: blockHash, blockHeight: input.blockHeight)
        let meta = BlockMeta(
            blockHash: blockHash,
            parentBlockHash: input.parentBlockHash,
            blockHeight: input.blockHeight,
            childHashes: childHashes,
            workContributions: contributions,
            cumulativeWork: blockCumulativeWork
        )

        hashToBlock[blockHash] = meta
        for contribution in contributions {
            workContributionIndex[contribution.id] = WorkContributionRecord(
                blockHash: blockHash,
                contribution: contribution
            )
        }
        blockTimestamps[blockHash] = input.timestamp
        tipSnapshotsByHash[blockHash] = input.snapshot
        if let prevHash = input.parentBlockHash,
           hashToBlock[prevHash]?.childHashes.contains(blockHash) == false {
            hashToBlock[prevHash]?.childHashes.append(blockHash)
        }

        // Out-of-order repair: if children of this block were delivered before it,
        // they were inserted with a provisional prefix sum (own work only, since
        // their parent was missing). Now that this block's prefix is known, fix
        // them and their descendants.
        propagateCumulativeWork(from: blockHash)

        propagateSubtreeWeight(from: blockHash)

        guard let previousBlockCID = input.parentBlockHash else {
            return SubmissionResult(
                addedBlock: true,
                addedContribution: addedContribution,
                extendsMainChain: false,
                needsParentBlock: false
            )
        }

        if previousBlockCID == chainTip {
            let connected = setNewTip(block: meta)
            return .extendsMainChain(
                addedContribution: addedContribution,
                commit: ChainCommit(
                    tipHash: chainTip,
                    mainChainBlocksAdded: connected
                )
            )
        }

        if hashToBlock[previousBlockCID] == nil {
            return SubmissionResult(
                addedBlock: true,
                addedContribution: addedContribution,
                extendsMainChain: false,
                needsParentBlock: true
            )
        }

        return SubmissionResult(
            addedBlock: true,
            addedContribution: addedContribution,
            extendsMainChain: false,
            needsParentBlock: false
        )
    }

    /// Repair the cumulative-work prefix sum of `hash`'s own-chain descendants
    /// after `hash`'s prefix became known (out-of-order delivery). Walks
    /// `childHashes`, setting each child to `parent.cumulativeWork + child.work`
    /// and recursing only where the value actually changes — so it terminates
    /// and does nothing in the common in-order case (where a freshly inserted
    /// block has no children yet).
    private func propagateCumulativeWork(from hash: String) {
        var queue = [hash]
        while let current = queue.popLast() {
            guard let parentMeta = hashToBlock[current] else { continue }
            let parentCum = parentMeta.cumulativeWork
            for childHash in parentMeta.childHashes {
                guard var childMeta = hashToBlock[childHash] else { continue }
                let expected = parentCum + childMeta.work
                if childMeta.cumulativeWork != expected {
                    childMeta.setCumulativeWork(expected)
                    hashToBlock[childHash] = childMeta
                    queue.append(childHash)
                }
            }
        }
    }

    /// Repair the forward subtree weight up the same-chain ancestor
    /// path from `hash`. `subtreeWeight(B) = work(B) + Σ subtreeWeight(children)`,
    /// recomputed bottom-up: set `hash` from its current children, then walk to its
    /// same-chain parent and recompute it from *its* children, and so on, stopping
    /// once a recompute leaves a value unchanged (no ancestor above can change
    /// either). This is the descendant-dual of `propagateCumulativeWork` and is
    /// correct under out-of-order delivery — a block delivered before its parent
    /// already carries its own subtree, and the parent folds it in on arrival.
    /// O(depth) per call; terminates because the walk is strictly toward genesis.
    private func propagateSubtreeWeight(from hash: String) {
        var current: String? = hash
        // The starting block was just linked into its parent's child set, so its
        // parent must be recomputed even if the block's *own* weight is unchanged
        // (a freshly-inserted leaf already weighs its own work). Only *after* the
        // first hop does an unchanged value let us stop: if an ancestor's recompute
        // leaves it unchanged, no ancestor above it can change either (its
        // dependence on the subtree below runs *through* this unchanged value).
        var isStart = true
        while let h = current, let meta = hashToBlock[h] {
            var weight = meta.work
            for childHash in meta.childHashes {
                weight = weight + (hashToBlock[childHash]?.subtreeWeight ?? .zero)
            }
            if !isStart && weight == meta.subtreeWeight { break }
            hashToBlock[h]?.setSubtreeWeight(weight)
            isStart = false
            current = meta.parentBlockHash
        }
    }

    /// Rebuild subtree weights children-before-parents after restore.
    nonisolated static func recomputeSubtreeWeights(
        in blocks: inout [String: BlockMeta]
    ) {
        let ordered = blocks.values.sorted { $0.blockHeight > $1.blockHeight }
        for meta in ordered {
            var weight = meta.work
            for childHash in meta.childHashes {
                let childWeight = blocks[childHash]?.subtreeWeight ?? .zero
                weight = weight + childWeight
            }
            blocks[meta.blockHash]?.setSubtreeWeight(weight)
        }
    }

    // MARK: - Additional proof facts

    func addWorkContribution(
        _ contribution: VerifiedWorkContribution,
        to blockHash: String
    ) -> SubmissionResult {
        guard var meta = hashToBlock[blockHash] else { return .discarded() }
        let record = WorkContributionRecord(
            blockHash: blockHash,
            contribution: contribution
        )
        guard workContributionIndex[contribution.id] == nil,
              meta.workContributions[contribution.id] == nil else {
            return .discarded()
        }
        guard meta.addWorkContribution(contribution) else { return .discarded() }

        let parentWork = meta.parentBlockHash.flatMap { hashToBlock[$0]?.cumulativeWork } ?? .zero
        meta.setCumulativeWork(parentWork + meta.work)
        hashToBlock[blockHash] = meta
        workContributionIndex[contribution.id] = record
        propagateCumulativeWork(from: blockHash)
        propagateSubtreeWeight(from: blockHash)
        mutationGeneration &+= 1

        let canonicalChange = mainChainBlockAtIndex[meta.blockHeight] == blockHash
            ? nil
            : checkForReorgWithoutRevision(block: hashToBlock[blockHash]!)
        if canonicalChange != nil {
            tipSnapshot = tipSnapshotsByHash[chainTip]
        }
        return SubmissionResult(
            addedBlock: false,
            addedContribution: true,
            extendsMainChain: false,
            needsParentBlock: false,
            commit: (canonicalChange ?? ChainCommit(tipHash: chainTip))
                .atRevision(mutationGeneration)
        )
    }

    func workContribution(id: String) -> WorkContributionRecord? {
        workContributionIndex[id]
    }

    func submitBlockIfUnchanged(
        expectedMutationGeneration: UInt64,
        blockHeader: BlockHeader,
        block: Block,
        contribution: VerifiedWorkContribution
    ) -> SubmissionResult? {
        guard mutationGeneration == expectedMutationGeneration else { return nil }
        return submitBlock(
            blockHeader: blockHeader,
            block: block,
            contribution: contribution
        )
    }

    /// Rebuild one already-durable, locally authenticated admission fact. This is
    /// a recovery API: callers must authenticate and persist the fact before
    /// invoking it, just as live admission does before mutating this actor.
    public func replay(_ batch: ChainAdmissionBatch) throws -> ChainCommit? {
        guard let trusted = TrustedAdmissionBatch(batch) else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        let record = WorkContributionRecord(
            blockHash: trusted.workBlockHash,
            contribution: trusted.contribution
        )

        if let input = trusted.block {
            if let existing = hashToBlock[input.blockHash] {
                guard matches(existing, input: input),
                      let existingSnapshot = tipSnapshotsByHash[input.blockHash],
                      existingSnapshot == input.snapshot else {
                    throw ChainStateRestoreError.corruptConsensusGraph
                }
                guard let existingRecord = workContributionIndex[trusted.contribution.id] else {
                    throw ChainStateRestoreError.corruptConsensusGraph
                }
                guard existingRecord == record else {
                    throw ChainStateRestoreError.corruptConsensusGraph
                }
                return nil
            }
            if let existingRecord = workContributionIndex[trusted.contribution.id],
               existingRecord != record {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            let submission = submitBlock(input: input, contribution: trusted.contribution)
            guard submission.addedBlock, submission.addedContribution else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            return submission.commit
        }

        let blockHash = record.blockHash
        guard hashToBlock[blockHash] != nil else {
            throw ChainStateRestoreError.missingBlockFact
        }
        if let existingRecord = workContributionIndex[trusted.contribution.id] {
            guard existingRecord == record else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            return nil
        }
        let submission = addWorkContribution(trusted.contribution, to: blockHash)
        guard submission.addedContribution else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        return submission.commit
    }

    private func matches(_ meta: BlockMeta, input: ConsensusBlockInput) -> Bool {
        meta.blockHash == input.blockHash
            && meta.parentBlockHash == input.parentBlockHash
            && meta.blockHeight == input.blockHeight
            && blockTimestamps[input.blockHash] == input.timestamp
    }

    // MARK: - Index Management

    func addToBlockIndex(hash: String, blockHeight: UInt64) {
        indexToBlockHash[blockHeight, default: []].insert(hash)
    }

    func findChildren(hash: String, blockHeight: UInt64) -> [String] {
        let (childHeight, overflow) = blockHeight.addingReportingOverflow(1)
        guard !overflow, let hashes = indexToBlockHash[childHeight] else { return [] }
        return hashes.filter { hashToBlock[$0]?.parentBlockHash == hash }
    }

    // MARK: - Fork Choice

    /// GHOST descent chooses the child with greatest verified subtree work.
    /// Equal work prefers the lexicographically smaller segment-base CID.
    func chainWithMostWork(
        startingBlock: BlockMeta
    ) -> (subtreeWork: WorkSum, tipHash: String, blocks: Set<String>) {
        // Resolve the live meta: callers may pass a stale copy captured before the
        // block (and its maintained `subtreeWeight`/`childHashes`) was indexed.
        let start = hashToBlock[startingBlock.blockHash] ?? startingBlock
        let descent = ghostDescent(from: start)
        let baseWeight = hashToBlock[start.blockHash]?.subtreeWeight ?? start.subtreeWeight
        return (baseWeight, descent.tipHash, descent.blocks)
    }

    /// Descend to the heaviest verified-work leaf, returning the path taken.
    private func ghostDescent(
        from start: BlockMeta
    ) -> (tipHash: String, blocks: Set<String>) {
        var currentHash = start.blockHash
        var blocks: Set<String> = [currentHash]
        while let children = hashToBlock[currentHash]?.childHashes, !children.isEmpty {
            let weighted = children.compactMap { child -> (hash: String, work: WorkSum)? in
                guard let work = hashToBlock[child]?.subtreeWeight else { return nil }
                return (child, work)
            }
            guard weighted.count == children.count,
                  let bestWork = weighted.map(\.work).max(),
                  var next = weighted.first(where: { $0.work == bestWork })?.hash else { break }
            for candidate in weighted where candidate.work == bestWork {
                if forkChoicePrefersSegmentBase(
                    candidate.hash,
                    over: next
                ) {
                    next = candidate.hash
                }
            }
            currentHash = next
            blocks.insert(currentHash)
        }
        return (currentHash, blocks)
    }

    private func previousHash(of hash: String) -> String? {
        hashToBlock[hash]?.parentBlockHash
    }

    /// The incumbent subtree work and removal set at a fork height.
    func mainChainWork(
        fromIndex blockHeight: UInt64
    ) -> (subtreeWork: WorkSum, blocks: Set<String>) {
        let weight = mainChainBlockAtIndex[blockHeight].flatMap {
            hashToBlock[$0]?.subtreeWeight
        } ?? .zero
        return (weight, mainChainHashesFrom(index: blockHeight))
    }

    // MARK: - Reorganization

    package func checkForReorg(block: BlockMeta) -> ChainCommit? {
        guard let commit = checkForReorgWithoutRevision(block: block) else {
            return nil
        }
        mutationGeneration &+= 1
        return commit.atRevision(mutationGeneration)
    }

    private func checkForReorgWithoutRevision(block: BlockMeta) -> ChainCommit? {
        guard let earliestHash = findEarliestOrphanConnectedToMainChain(
            blockHeader: block.blockHash
        ) else {
            return nil
        }
        guard let earliest = hashToBlock[earliestHash] else { return nil }

        let mainWork = mainChainWork(fromIndex: earliest.blockHeight)
        let forkWork = chainWithMostWork(startingBlock: earliest)

        let mainBaseHash = mainChainBlockAtIndex[earliest.blockHeight]
        if forkWork.subtreeWork > mainWork.subtreeWork ||
            (forkWork.subtreeWork == mainWork.subtreeWork &&
             mainBaseHash.map {
                forkChoicePrefersSegmentBase(
                    earliest.blockHash,
                    over: $0
                )
             } == true) {
            return applyReorg(
                newForkBlocks: forkWork.blocks,
                newForkTipHash: forkWork.tipHash,
                mainChainBlocks: mainWork.blocks
            )
        }
        return nil
    }

    private func applyReorg(
        newForkBlocks: Set<String>,
        newForkTipHash: String?,
        mainChainBlocks: Set<String>
    ) -> ChainCommit {
        var forkHashToIndex: [String: UInt64] = [:]

        for hash in newForkBlocks {
            guard let idx = hashToBlock[hash]?.blockHeight else { continue }
            forkHashToIndex[hash] = idx
        }

        let newTip = newForkTipHash ?? chainTip
        advanceTip(to: newTip)

        for hash in mainChainBlocks {
            mainChainHashes.remove(hash)
            if let block = hashToBlock[hash] {
                mainChainBlockAtIndex.removeValue(forKey: block.blockHeight)
            }
        }
        for (hash, idx) in forkHashToIndex {
            mainChainHashes.insert(hash)
            mainChainBlockAtIndex[idx] = hash
        }

        return ChainCommit(
            tipHash: newTip,
            mainChainBlocksAdded: forkHashToIndex,
            mainChainBlocksRemoved: mainChainBlocks
        )
    }

    /// Advance the main-chain tip onto the heaviest descent from `block` (whose parent
    /// is the current tip). Returns the **connect set**: the blocks that newly joined
    /// the main chain, keyed by height — `chainWithMostWork`'s descent `blocks`. In the
    /// common in-order extend this is just `{block}`; when GHOST descent advances the
    /// tip past already-attached out-of-order descendants it also includes those, so
    /// the caller can emit one exact canonical commit.
    @discardableResult
    func setNewTip(
        block: BlockMeta
    ) -> [String: UInt64] {
        let chain = chainWithMostWork(startingBlock: block)
        chainTip = chain.tipHash
        tipSnapshot = tipSnapshotsByHash[chainTip]
        var connectSet: [String: UInt64] = [:]
        for hash in chain.blocks {
            mainChainHashes.insert(hash)
            if let b = hashToBlock[hash] {
                mainChainBlockAtIndex[b.blockHeight] = hash
                connectSet[hash] = b.blockHeight
            }
        }
        return connectSet
    }

    func advanceTip(to blockHash: String) {
        chainTip = blockHash
        tipSnapshot = tipSnapshotsByHash[chainTip]
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

    // MARK: - Main Chain Queries

    private func mainChainHashesFrom(index blockHeight: UInt64) -> Set<String> {
        var hashes: Set<String> = Set()
        var currentHash = chainTip
        guard var current = highestBlock else { return hashes.union([currentHash]) }
        guard current.blockHeight >= blockHeight else { return hashes }
        hashes.insert(currentHash)

        while current.blockHeight > blockHeight {
            guard let prevHash = current.parentBlockHash else { break }
            guard let prev = hashToBlock[prevHash] else { break }
            currentHash = prevHash
            current = prev
            hashes.insert(currentHash)
        }
        return hashes
    }

}
