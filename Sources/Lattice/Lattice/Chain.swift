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

    /// Backward cumulative proof-of-work prefix measure from genesis through
    /// this block. A physical grind appearing at several covered blocks counts
    /// once.
    ///
    /// Stored so it remains exact across persistence round-trips.
    ///
    /// Mutable so out-of-order delivery and new grind coverage can rebuild the
    /// exact deduplicated prefix.
    public private(set) var cumulativeWork: WorkSum

    /// The forward same-chain subtree measure, deduplicated by physical grind.
    /// This cache is local; live inherited work is unioned only while making a
    /// fork-choice decision and is never persisted here.
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
        workContributions[contribution.id] = contribution
        work = WorkMeasure(workContributions.values).total
        return true
    }

}

struct WorkContributionRecord: Sendable, Equatable {
    var blockHashes: Set<String>
    var contribution: VerifiedWorkContribution
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

    var inheritedWorkProvider: InheritedWorkProvider?
    var inheritedWorkSnapshot: InheritedWorkSnapshot?

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
        mutationGeneration: UInt64 = 0,
        inheritedWorkProvider: InheritedWorkProvider? = nil,
        inheritedWorkSnapshot: InheritedWorkSnapshot? = nil
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
        self.inheritedWorkProvider = inheritedWorkProvider
        self.inheritedWorkSnapshot = inheritedWorkSnapshot ?? inheritedWorkProvider?()
        self.tipSnapshot = tipSnapshot
        self.tipSnapshotsByHash = tipSnapshotsByHash
        if let tipSnapshot {
            self.tipSnapshotsByHash[chainTip] = tipSnapshot
        }
        self.blockTimestamps = blockTimestamps
        self.mutationGeneration = mutationGeneration
        self.mainChainBlockAtIndex = [:]
        for meta in self.hashToBlock.values {
            let contributions = meta.workContributions.values
            guard !contributions.isEmpty,
                  contributions.allSatisfy({ $0.work > .zero }) else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
        }
        Self.normalizeWorkContributions(in: &self.hashToBlock)
        Self.recomputeWorkCaches(in: &self.hashToBlock)
        for hash in mainChainHashes {
            guard let height = self.hashToBlock[hash]?.blockHeight,
                  self.mainChainBlockAtIndex[height] == nil else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            self.mainChainBlockAtIndex[height] = hash
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
        contribution: VerifiedWorkContribution,
        mutationGeneration: UInt64 = 0
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
            tipSnapshot: input.snapshot,
            mutationGeneration: mutationGeneration
        )
    }

    /// Restore a child process whose staged genesis batch reached durable storage
    /// before the in-memory actor was created.
    public static func restore(
        replaying batches: [ChainAdmissionBatch],
        revisionFloor: UInt64 = 0,
        inheritedWorkProvider: InheritedWorkProvider? = nil
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
            mutationGeneration: revisionFloor
        )
        // The node may enumerate its durable facts in any order. Replay the seed
        // batch too: its existing block/work record makes that a no-op.
        try await replay(batches[...], onto: chain)
        _ = await chain.setInheritedWorkProvider(inheritedWorkProvider)
        return chain
    }

    /// Restore a snapshot and then replay durable admission batches that may have
    /// reached node storage immediately before a crash. Replaying all retained
    /// batches is safe: duplicate facts are idempotent.
    public static func restore(
        from persisted: PersistedChainState,
        replaying batches: [ChainAdmissionBatch],
        inheritedWorkProvider: InheritedWorkProvider? = nil
    ) async throws -> ChainState {
        let chain = try restore(
            from: persisted,
            inheritedWorkProvider: inheritedWorkProvider
        )
        try await replay(batches[...], onto: chain)
        return chain
    }

    private static func replay(
        _ batches: ArraySlice<ChainAdmissionBatch>,
        onto chain: ChainState
    ) async throws {
        var pending = Array(batches)
        while !pending.isEmpty {
            pending.sort(by: replayPrecedes)
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

    private static func replayPrecedes(
        _ left: ChainAdmissionBatch,
        _ right: ChainAdmissionBatch
    ) -> Bool {
        guard let left = TrustedAdmissionBatch(left),
              let right = TrustedAdmissionBatch(right) else { return false }
        if left.contribution.work != right.contribution.work {
            return left.contribution.work < right.contribution.work
        }
        if left.workBlockHash != right.workBlockHash {
            return left.workBlockHash < right.workBlockHash
        }
        return left.contribution.id < right.contribution.id
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

    /// Install the node's coherent immediate-parent view and immediately make
    /// this chain's canonical projection agree with it.
    @discardableResult
    public func setInheritedWorkProvider(
        _ provider: InheritedWorkProvider?
    ) -> ChainCommit? {
        inheritedWorkProvider = provider
        return reevaluateForkChoice()
    }

    /// Re-read a live provider whose cached snapshot changed.
    @discardableResult
    public func reevaluateForkChoice() -> ChainCommit? {
        guard mutationGeneration < .max else { return nil }
        let inheritedChanged = refreshInheritedWork()
        let canonicalChange = projectCanonicalChain(
            inherited: retainedInheritedWork
        )
        guard inheritedChanged || canonicalChange != nil else { return nil }
        mutationGeneration += 1
        return (canonicalChange ?? ChainCommit(tipHash: chainTip))
            .atRevision(mutationGeneration)
    }

    /// Atomically export the parent-side work securing each child block. The node
    /// supplies bindings already verified from content-addressed paths; Lattice
    /// stores no cross-process parent/child relationship index.
    public func inheritedWorkSnapshot(
        forChildCoverage verifiedParentBlocksByChildBlock: [String: Set<String>]
    ) -> InheritedWorkSnapshot? {
        guard verifiedParentBlocksByChildBlock.values
            .joined()
            .allSatisfy(hasAcceptedAncestry) else { return nil }
        let measures = effectiveSubtreeMeasures(inherited: retainedInheritedWork)
        var workByChildBlock: [String: WorkMeasure] = [:]
        for (childBlockHash, parentBlockHashes) in verifiedParentBlocksByChildBlock {
            workByChildBlock[childBlockHash] = parentBlockHashes.reduce(
                into: WorkMeasure.zero
            ) { result, hash in
                if let measure = measures[hash] { result.formUnion(measure) }
            }
        }
        return InheritedWorkSnapshot(
            revision: mutationGeneration,
            workByBlock: workByChildBlock
        )
    }

    private func hasAcceptedAncestry(_ blockHash: String) -> Bool {
        var currentHash = blockHash
        var visited = Set<String>()
        while visited.insert(currentHash).inserted,
              let current = hashToBlock[currentHash] {
            guard let parentHash = current.parentBlockHash else {
                return current.blockHeight == 0
            }
            guard let parent = hashToBlock[parentHash],
                  parent.childHashes.contains(currentHash) else { return false }
            let (expectedHeight, overflow) = parent.blockHeight.addingReportingOverflow(1)
            guard !overflow, current.blockHeight == expectedHeight else { return false }
            currentHash = parentHash
        }
        return false
    }

    private var retainedInheritedWork: InheritedWorkSnapshot {
        inheritedWorkSnapshot ?? .zero
    }

    @discardableResult
    private func refreshInheritedWork() -> Bool {
        guard let candidate = inheritedWorkProvider?() else { return false }
        let current = retainedInheritedWork
        let merged = current.union(candidate)
        inheritedWorkSnapshot = merged
        return merged != current
    }

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
        var measure = WorkMeasure.zero
        var current: String? = chainTip
        var walked: UInt64 = 0
        while let hash = current, walked <= limit {
            guard let meta = hashToBlock[hash] else { break }
            measure.formUnion(WorkMeasure(meta.workContributions.values))
            current = meta.parentBlockHash
            walked += 1
        }
        return measure.total
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

    /// The local-only same-chain subtree measure of `hash`, deduplicated by grind
    /// identity. Live inherited work is joined only during fork-choice projection.
    public func subtreeWeight(forHash hash: String) -> WorkSum? {
        hashToBlock[hash]?.subtreeWeight
    }

    /// Test-facing (via `@testable`): the projected heaviest leaf below `hash`
    /// and its durable local cumulative work.
    func heaviestDescent(fromHash hash: String) -> (tipHash: String, cumulativeWork: WorkSum)? {
        guard let start = hashToBlock[hash] else { return nil }
        let descent = chainWithMostWork(startingBlock: start)
        guard let work = hashToBlock[descent.tipHash]?.cumulativeWork else { return nil }
        return (descent.tipHash, work)
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
        let oldTip = chainTip

        if contribution.work == .zero || (isRoot && input.blockHeight != 0) {
            return .discarded()
        }

        if hashToBlock[blockHash] != nil {
            return addWorkContribution(contribution, to: blockHash)
        }

        guard mutationGeneration < .max else { return .discarded() }

        let result = insertBlock(
            input: input,
            contributions: [contribution],
            addedContribution: true
        )
        if !result.addedBlock { return result }
        mutationGeneration += 1
        _ = refreshInheritedWork()

        let canonicalChange = projectCanonicalChain(
            inherited: retainedInheritedWork
        )
        let extendsMainChain = input.parentBlockHash == oldTip
            && mainChainHashes.contains(blockHash)
        return SubmissionResult(
            addedBlock: true,
            addedContribution: result.addedContribution,
            extendsMainChain: extendsMainChain,
            needsParentBlock: result.needsParentBlock,
            commit: (canonicalChange ?? ChainCommit(tipHash: chainTip))
                .atRevision(mutationGeneration)
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
        addToBlockIndex(hash: blockHash, blockHeight: input.blockHeight)

        let childHashes = findChildren(hash: blockHash, blockHeight: input.blockHeight)
        let meta = BlockMeta(
            blockHash: blockHash,
            parentBlockHash: input.parentBlockHash,
            blockHeight: input.blockHeight,
            childHashes: childHashes,
            workContributions: contributions
        )

        hashToBlock[blockHash] = meta
        Self.normalizeWorkContributions(in: &hashToBlock)
        blockTimestamps[blockHash] = input.timestamp
        tipSnapshotsByHash[blockHash] = input.snapshot
        if let prevHash = input.parentBlockHash,
           hashToBlock[prevHash]?.childHashes.contains(blockHash) == false {
            hashToBlock[prevHash]?.childHashes.append(blockHash)
        }

        Self.recomputeWorkCaches(in: &hashToBlock)

        guard let previousBlockCID = input.parentBlockHash else {
            return SubmissionResult(
                addedBlock: true,
                addedContribution: addedContribution,
                extendsMainChain: false,
                needsParentBlock: false
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

    /// Rebuild exact local prefix and subtree measures after a graph or work-fact
    /// mutation. Distinct grind IDs reduce to scalar addition; shared IDs use the
    /// full identity-bearing union.
    nonisolated static func recomputeWorkCaches(
        in blocks: inout [String: BlockMeta]
    ) {
        let ascending = blocks.values.sorted {
            if $0.blockHeight != $1.blockHeight { return $0.blockHeight < $1.blockHeight }
            return $0.blockHash < $1.blockHash
        }
        var seenGrinds = Set<String>()
        let hasSharedGrind = blocks.values.contains { meta in
            meta.workContributions.keys.contains { !seenGrinds.insert($0).inserted }
        }
        if !hasSharedGrind {
            for meta in ascending {
                let cumulative = meta.work + (meta.parentBlockHash.flatMap {
                    blocks[$0]?.cumulativeWork
                } ?? .zero)
                blocks[meta.blockHash]?.setCumulativeWork(cumulative)
            }

            var subtreeTotals: [String: WorkSum] = [:]
            var visiting = Set<String>()
            func subtreeTotal(_ hash: String) -> WorkSum {
                if let cached = subtreeTotals[hash] { return cached }
                guard visiting.insert(hash).inserted,
                      let meta = blocks[hash] else { return .zero }
                let total = meta.childHashes.reduce(meta.work) {
                    $0 + subtreeTotal($1)
                }
                visiting.remove(hash)
                subtreeTotals[hash] = total
                return total
            }
            let totals = Dictionary(
                uniqueKeysWithValues: blocks.keys.map { ($0, subtreeTotal($0)) }
            )
            for (hash, total) in totals {
                blocks[hash]?.setSubtreeWeight(total)
            }
            return
        }

        let ownMeasures = blocks.mapValues { WorkMeasure($0.workContributions.values) }
        var cumulativeMeasures: [String: WorkMeasure] = [:]
        for meta in ascending {
            var measure = ownMeasures[meta.blockHash] ?? .zero
            if let parentHash = meta.parentBlockHash,
               let parentMeasure = cumulativeMeasures[parentHash] {
                measure.formUnion(parentMeasure)
            }
            cumulativeMeasures[meta.blockHash] = measure
            blocks[meta.blockHash]?.setCumulativeWork(measure.total)
        }

        var subtreeMeasures: [String: WorkMeasure] = [:]
        var visiting = Set<String>()
        func subtreeMeasure(_ hash: String) -> WorkMeasure {
            if let cached = subtreeMeasures[hash] { return cached }
            guard visiting.insert(hash).inserted,
                  let meta = blocks[hash] else { return .zero }
            var measure = ownMeasures[hash] ?? .zero
            for childHash in meta.childHashes {
                measure.formUnion(subtreeMeasure(childHash))
            }
            visiting.remove(hash)
            subtreeMeasures[hash] = measure
            return measure
        }
        let subtreeTotals = Dictionary(
            uniqueKeysWithValues: blocks.keys.map { ($0, subtreeMeasure($0).total) }
        )
        for (hash, total) in subtreeTotals {
            blocks[hash]?.setSubtreeWeight(total)
        }
    }

    nonisolated static func normalizeWorkContributions(
        in blocks: inout [String: BlockMeta]
    ) {
        var strongest: [String: VerifiedWorkContribution] = [:]
        for contribution in blocks.values.flatMap(\.workContributions.values) {
            if contribution.work > (strongest[contribution.id]?.work ?? .zero) {
                strongest[contribution.id] = contribution
            }
        }
        for hash in blocks.keys {
            guard let contributions = blocks[hash]?.workContributions.values else {
                continue
            }
            for contribution in contributions {
                if let strongest = strongest[contribution.id] {
                    _ = blocks[hash]?.setWorkContribution(strongest)
                }
            }
        }
    }

    // MARK: - Additional proof facts

    func addWorkContribution(
        _ contribution: VerifiedWorkContribution,
        to blockHash: String
    ) -> SubmissionResult {
        guard hashToBlock[blockHash] != nil else { return .discarded() }
        let existing = workContribution(id: contribution.id)
        let addsCoverage = existing?.blockHashes.contains(blockHash) != true
        let strengthensGrind = contribution.work > (existing?.contribution.work ?? .zero)
        guard addsCoverage || strengthensGrind else { return .discarded() }
        guard mutationGeneration < .max else { return .discarded() }
        _ = hashToBlock[blockHash]?.setWorkContribution(contribution)
        Self.normalizeWorkContributions(in: &hashToBlock)
        Self.recomputeWorkCaches(in: &hashToBlock)
        mutationGeneration += 1
        _ = refreshInheritedWork()

        let canonicalChange = projectCanonicalChain(
            inherited: retainedInheritedWork
        )
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
        var blockHashes = Set<String>()
        var strongest: VerifiedWorkContribution?
        for (hash, meta) in hashToBlock {
            guard let contribution = meta.workContributions[id] else { continue }
            blockHashes.insert(hash)
            if contribution.work > (strongest?.work ?? .zero) {
                strongest = contribution
            }
        }
        return strongest.map {
            WorkContributionRecord(blockHashes: blockHashes, contribution: $0)
        }
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
        if let input = trusted.block {
            if let existing = hashToBlock[input.blockHash] {
                guard matches(existing, input: input),
                      let existingSnapshot = tipSnapshotsByHash[input.blockHash],
                      existingSnapshot == input.snapshot else {
                    throw ChainStateRestoreError.corruptConsensusGraph
                }
                if let existingRecord = workContribution(id: trusted.contribution.id),
                   existingRecord.blockHashes.contains(input.blockHash),
                   existingRecord.contribution.work >= trusted.contribution.work {
                    return nil
                }
                let submission = addWorkContribution(
                    trusted.contribution,
                    to: input.blockHash
                )
                guard submission.addedContribution else {
                    throw ChainStateRestoreError.corruptConsensusGraph
                }
                return submission.commit
            }
            let submission = submitBlock(input: input, contribution: trusted.contribution)
            guard submission.addedBlock, submission.addedContribution else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            return submission.commit
        }

        let blockHash = trusted.workBlockHash
        guard hashToBlock[blockHash] != nil else {
            throw ChainStateRestoreError.missingBlockFact
        }
        if let existingRecord = workContribution(id: trusted.contribution.id) {
            if existingRecord.blockHashes.contains(blockHash),
               existingRecord.contribution.work >= trusted.contribution.work {
                return nil
            }
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

    private func effectiveSubtreeMeasures(
        inherited: InheritedWorkSnapshot
    ) -> [String: WorkMeasure] {
        Self.effectiveSubtreeMeasures(in: hashToBlock, inherited: inherited)
    }

    nonisolated static func effectiveSubtreeMeasures(
        in blocks: [String: BlockMeta],
        inherited: InheritedWorkSnapshot
    ) -> [String: WorkMeasure] {
        var strongestWork = inherited.strongestWorkByGrind
        for contribution in blocks.values.flatMap(\.workContributions.values)
        where contribution.work > (strongestWork[contribution.id] ?? .zero) {
            strongestWork[contribution.id] = contribution.work
        }
        var memo: [String: WorkMeasure] = [:]
        var visiting = Set<String>()

        func measure(_ hash: String) -> WorkMeasure {
            if let cached = memo[hash] { return cached }
            guard visiting.insert(hash).inserted,
                  let meta = blocks[hash] else { return .zero }
            var result = WorkMeasure(meta.workContributions.values)
                .normalized(using: strongestWork)
            result.formUnion(
                inherited.work(forBlock: hash).normalized(using: strongestWork)
            )
            for childHash in meta.childHashes {
                result.formUnion(measure(childHash))
            }
            visiting.remove(hash)
            memo[hash] = result
            return result
        }

        for hash in blocks.keys { _ = measure(hash) }
        return memo
    }

    private func effectiveSubtreeWeights(
        inherited: InheritedWorkSnapshot
    ) -> [String: WorkSum] {
        if inherited.isEmpty {
            return hashToBlock.mapValues(\.subtreeWeight)
        }
        return effectiveSubtreeMeasures(inherited: inherited).mapValues(\.total)
    }

    nonisolated private static func preferred(
        among hashes: [String],
        weights: [String: WorkSum]
    ) -> String? {
        guard var selected = hashes.first, weights[selected] != nil else { return nil }
        for candidate in hashes.dropFirst() {
            guard let candidateWork = weights[candidate],
                  let selectedWork = weights[selected] else { continue }
            if candidateWork > selectedWork ||
                (candidateWork == selectedWork && forkChoicePrefersSegmentBase(
                    candidate,
                    over: selected
                )) {
                selected = candidate
            }
        }
        return selected
    }

    /// GHOST descent chooses the child with greatest deduplicated local and
    /// inherited work. Equal work prefers the smaller segment-base CID.
    func chainWithMostWork(
        startingBlock: BlockMeta
    ) -> (subtreeWork: WorkSum, tipHash: String, blocks: Set<String>) {
        chainWithMostWork(
            startingBlock: startingBlock,
            inherited: retainedInheritedWork
        )
    }

    private func chainWithMostWork(
        startingBlock: BlockMeta,
        inherited: InheritedWorkSnapshot
    ) -> (subtreeWork: WorkSum, tipHash: String, blocks: Set<String>) {
        let start = hashToBlock[startingBlock.blockHash] ?? startingBlock
        let weights = effectiveSubtreeWeights(inherited: inherited)
        let descent = Self.ghostDescent(
            from: start.blockHash,
            in: hashToBlock,
            weights: weights
        )
        let baseWeight = weights[start.blockHash] ?? .zero
        return (baseWeight, descent.tipHash, descent.blocks)
    }

    nonisolated private static func ghostDescent(
        from startHash: String,
        in blocksByHash: [String: BlockMeta],
        weights: [String: WorkSum]
    ) -> (tipHash: String, blocks: Set<String>) {
        var currentHash = startHash
        var blocks: Set<String> = [currentHash]
        while let children = blocksByHash[currentHash]?.childHashes, !children.isEmpty {
            guard let next = preferred(among: children, weights: weights),
                  blocks.insert(next).inserted else { break }
            currentHash = next
        }
        return (currentHash, blocks)
    }

    nonisolated static func canonicalProjection(
        in blocksByHash: [String: BlockMeta],
        inherited: InheritedWorkSnapshot
    ) -> (chainTip: String, mainChainHashes: Set<String>)? {
        let weights = effectiveSubtreeMeasures(
            in: blocksByHash,
            inherited: inherited
        ).mapValues(\.total)
        return canonicalProjection(in: blocksByHash, weights: weights)
    }

    nonisolated private static func canonicalProjection(
        in blocksByHash: [String: BlockMeta],
        weights: [String: WorkSum]
    ) -> (chainTip: String, mainChainHashes: Set<String>)? {
        let roots = blocksByHash.values
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
        guard let root = preferred(among: roots, weights: weights) else { return nil }
        let descent = ghostDescent(
            from: root,
            in: blocksByHash,
            weights: weights
        )
        return (descent.tipHash, descent.blocks)
    }

    private func projectCanonicalChain(
        inherited: InheritedWorkSnapshot
    ) -> ChainCommit? {
        let weights = effectiveSubtreeWeights(inherited: inherited)
        guard let projection = Self.canonicalProjection(
            in: hashToBlock,
            weights: weights
        ) else { return nil }
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
