import cashew
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

/// Saturating addition for cumulative-work prefix sums. Cumulative work feeds
/// fork choice, so silent modulo wrap (which would let a heavier chain compare
/// *lower*) is unacceptable; on the astronomically unlikely overflow we clamp to
/// `UInt256.max`, preserving monotonicity. (Total work over any real chain is
/// vanishingly small relative to 2^256, so this clamp is defensive, not a path
/// any honest chain reaches.)
public func saturatingWorkSum(_ a: UInt256, _ b: UInt256) -> UInt256 {
    let sum = a &+ b
    return sum < a ? UInt256.max : sum
}

public typealias BlockHeader = VolumeImpl<Block>

// MARK: - Concrete Types

public struct BlockMeta: Sendable {
    public let blockHash: String
    public let parentBlockHash: String?
    public let blockHeight: UInt64
    public private(set) var work: UInt256
    /// Local transition delta retained for node lifecycle accounting. It is never
    /// consulted for validity or fork choice; the node owns bytes, pins, and
    /// retention policy.
    public private(set) var stateDiff: StateDiff?
    public var childHashes: [String]
    public private(set) var workContributions: [String: VerifiedWorkContribution]

    /// Backward cumulative proof-of-work prefix sum: the total work of this
    /// block's own chain from genesis up to and including this block,
    /// `cumulativeWork(B) = cumulativeWork(B.parent) + work(B)`.
    ///
    /// Stored so it remains exact when local lifecycle metadata is pruned and
    /// across persistence round-trips.
    ///
    /// Mutable only so a block inserted before its own-chain parent (out-of-order
    /// delivery) can be repaired once the parent — and thus its true prefix —
    /// becomes known; see `ChainState.propagateCumulativeWork(from:)`.
    public private(set) var cumulativeWork: UInt256

    /// The **forward** same-chain subtree weight:
    /// `subtreeWeight(B) = work(B) + Σ_{c ∈ children(B)} subtreeWeight(c)`, the
    /// total work of `B`'s descendant subtree on this chain, counting each block
    /// once (docs/consensus-fork-choice.md §3, §6). This is the GHOST quantity
    /// the fork-choice weight is built from — the *descendant* dual of the
    /// *ancestor* `cumulativeWork` prefix sum. Forks do not enter its definition:
    /// a block either descends from `B` or not. Maintained bottom-up and repaired
    /// up the ancestor chain on insert (`propagateSubtreeWeight(from:)`), so it is
    /// correct under out-of-order delivery and lifecycle pruning because the
    /// consensus graph itself is retained.
    ///
    /// `subtreeWeight` is local to this chain. Cross-chain proofs add immutable
    /// work contributions to blocks; fork choice never reads another live chain.
    public private(set) var subtreeWeight: UInt256

    public var createdDiffs: [String: Int] { stateDiff?.created ?? [:] }
    public var removedDiffs: [String: Int] { stateDiff?.replaced ?? [:] }

    package init(
        blockHash: String,
        parentBlockHash: String?,
        blockHeight: UInt64,
        childHashes: [String],
        stateDiff: StateDiff? = StateDiff.empty,
        workContributions: [VerifiedWorkContribution],
        cumulativeWork: UInt256 = .zero,
        subtreeWeight: UInt256? = nil
    ) {
        let contributions = Dictionary(
            workContributions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let work = contributions.values.reduce(.zero) {
            saturatingWorkSum($0, $1.work)
        }
        self.blockHash = blockHash
        self.parentBlockHash = parentBlockHash
        self.blockHeight = blockHeight
        self.work = work
        self.stateDiff = stateDiff
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
    mutating func setCumulativeWork(_ value: UInt256) {
        cumulativeWork = value
    }

    /// Internal-only: the forward subtree weight is maintained solely by
    /// `ChainState.propagateSubtreeWeight(from:)` (same module).
    mutating func setSubtreeWeight(_ value: UInt256) {
        subtreeWeight = value
    }

    mutating func addWorkContribution(_ contribution: VerifiedWorkContribution) -> Bool {
        guard workContributions[contribution.id] == nil else { return false }
        workContributions[contribution.id] = contribution
        work = saturatingWorkSum(work, contribution.work)
        return true
    }

    mutating func clearLifecycleDiffs() {
        stateDiff = nil
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
    public let reorganization: Reorganization?
    /// Blocks that left this chain's lifecycle-retention window during the mutation.
    /// The node consumes their committed deltas according to its pin policy.
    public let evictedBlocks: [BlockMeta]

    init(
        addedBlock: Bool,
        addedContribution: Bool = false,
        extendsMainChain: Bool,
        needsParentBlock: Bool,
        reorganization: Reorganization?,
        evictedBlocks: [BlockMeta] = []
    ) {
        self.addedBlock = addedBlock
        self.addedContribution = addedContribution
        self.extendsMainChain = extendsMainChain
        self.needsParentBlock = needsParentBlock
        self.reorganization = reorganization
        self.evictedBlocks = evictedBlocks
    }

    public static func extendsMainChain(
        addedContribution: Bool = true,
        evictedBlocks: [BlockMeta] = []
    ) -> Self {
        SubmissionResult(addedBlock: true, addedContribution: addedContribution, extendsMainChain: true, needsParentBlock: false, reorganization: nil, evictedBlocks: evictedBlocks)
    }

    public static func discarded() -> Self {
        SubmissionResult(addedBlock: false, addedContribution: false, extendsMainChain: false, needsParentBlock: false, reorganization: nil)
    }
}

public struct Reorganization: Sendable {
    public let newTipHash: String
    public let mainChainBlocksAdded: [String: UInt64]
    public let mainChainBlocksRemoved: Set<String>
    /// Newly canonical blocks whose transition delta is no longer retained.
    /// Consensus still selects them; the node decides how to reacquire or
    /// materialize their state.
    public let missingBodies: [String]
    public let evictedBlocks: [BlockMeta]

    init(
        newTipHash: String,
        mainChainBlocksAdded: [String: UInt64] = [:],
        mainChainBlocksRemoved: Set<String>,
        missingBodies: [String] = [],
        evictedBlocks: [BlockMeta] = []
    ) {
        self.newTipHash = newTipHash
        self.mainChainBlocksAdded = mainChainBlocksAdded
        self.mainChainBlocksRemoved = mainChainBlocksRemoved
        self.missingBodies = missingBodies
        self.evictedBlocks = evictedBlocks
    }
}

// MARK: - ChainState

public struct TipBlockSnapshot: Sendable {
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

public struct ForkChoiceSnapshot: Sendable, Equatable {
    public let startingHash: String
    public let subtreeWork: UInt256
    public let tipHash: String
    public let mainChainPath: Set<String>

    public init(startingHash: String, subtreeWork: UInt256, tipHash: String, mainChainPath: Set<String>) {
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

    /// Local lifecycle retention; it never affects validity or fork choice.
    var retentionDepth: UInt64
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
        retentionDepth: UInt64 = .max,
        blockTimestamps: [String: Int64] = [:],
        tipSnapshot: TipBlockSnapshot? = nil,
        tipSnapshotsByHash: [String: TipBlockSnapshot] = [:],
        prunedBlocks: [PersistedBlockMeta] = []
    ) throws {
        self.chainTip = chainTip
        self.mainChainHashes = mainChainHashes
        var allBlocks = hashToBlock
        for block in prunedBlocks {
            guard allBlocks[block.blockHash] == nil,
                  let cumulativeWork = UInt256(block.cumulativeWork, radix: 16),
                  let subtreeHex = block.subtreeWeight,
                  let subtreeWeight = UInt256(subtreeHex, radix: 16) else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            allBlocks[block.blockHash] = BlockMeta(
                blockHash: block.blockHash,
                parentBlockHash: block.parentBlockHash,
                blockHeight: block.blockHeight,
                childHashes: block.childHashes,
                stateDiff: nil,
                workContributions: block.workContributions,
                cumulativeWork: cumulativeWork,
                subtreeWeight: subtreeWeight
            )
        }
        guard allBlocks.values.allSatisfy({
            Set($0.childHashes).count == $0.childHashes.count
        }) else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        self.hashToBlock = allBlocks
        var allByHeight = indexToBlockHash
        for meta in allBlocks.values {
            allByHeight[meta.blockHeight, default: []].insert(meta.blockHash)
        }
        self.indexToBlockHash = allByHeight
        self.workContributionIndex = [:]
        self.retentionDepth = retentionDepth
        self.tipSnapshot = tipSnapshot
        self.tipSnapshotsByHash = tipSnapshotsByHash
        if let tipSnapshot {
            self.tipSnapshotsByHash[chainTip] = tipSnapshot
        }
        self.blockTimestamps = blockTimestamps
        self.mutationGeneration = 0
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
                  contributions.reduce(.zero, {
                      saturatingWorkSum($0, $1.work)
                  }) == meta.work else {
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
        block: Block,
        stateDiff: StateDiff = .empty,
        retentionDepth: UInt64 = .max
    ) -> ChainState {
        let blockHeader = try! BlockHeader(node: block)
        return fromVerifiedGenesis(
            block: block,
            stateDiff: stateDiff,
            contribution: VerifiedWorkContribution(
                id: blockHeader.rawCID,
                work: workForTarget(block.target)
            ),
            retentionDepth: retentionDepth
        )
    }

    package static func fromVerifiedGenesis(
        block: Block,
        stateDiff: StateDiff,
        contribution: VerifiedWorkContribution,
        retentionDepth: UInt64 = .max
    ) -> ChainState {
        // Known-valid local node; CID computation cannot fail (no Float/Double fields).
        let blockHash = try! BlockHeader(node: block).rawCID
        let meta = BlockMeta(
            blockHash: blockHash,
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            stateDiff: stateDiff,
            workContributions: [contribution],
            cumulativeWork: contribution.work
        )
        return try! ChainState(
            chainTip: blockHash,
            mainChainHashes: Set([blockHash]),
            indexToBlockHash: [0: Set([blockHash])],
            hashToBlock: [blockHash: meta],
            retentionDepth: retentionDepth,
            blockTimestamps: [blockHash: block.timestamp],
            tipSnapshot: Self.snapshot(for: block)
        )
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

    public func getMainChainTip() -> String {
        chainTip
    }

    public func isOnMainChain(hash: String) -> Bool {
        guard let height = hashToBlock[hash]?.blockHeight else { return false }
        return mainChainBlockAtIndex[height] == hash
    }

    /// Sum work for up to `limit` ancestors from the current tip.
    public func getCumulativeWork(limit: UInt64) -> UInt256 {
        var total = UInt256.zero
        var current: String? = chainTip
        var walked: UInt64 = 0
        while let hash = current, walked <= limit {
            guard let meta = hashToBlock[hash] else { break }
            total = saturatingWorkSum(total, meta.work)
            current = meta.parentBlockHash
            walked += 1
        }
        return total
    }

    /// Exact total proof-of-work from genesis to the current chain tip.
    public func getTipCumulativeWork() -> UInt256 {
        highestBlock?.cumulativeWork ?? .zero
    }

    /// Exact genesis-relative cumulative work at a specific block, or nil if the
    /// block is unknown.
    public func getCumulativeWork(forHash hash: String) -> UInt256? {
        hashToBlock[hash]?.cumulativeWork
    }

    /// The forward same-chain subtree weight of `hash`
    /// — the total work of its descendant subtree on this chain, counting each
    /// block once (design §3/§6). This is the GHOST quantity the fork-choice weight
    /// is built from; for a tip it equals the block's own work, for an interior
    /// block the sum of itself and everything that builds on it across all forks.
    public func subtreeWeight(forHash hash: String) -> UInt256? {
        hashToBlock[hash]?.subtreeWeight
    }

    /// Test-facing (via `@testable`): the index-computed heaviest leaf below `hash`
    /// and its durable cumulative work. Production fork choice runs through
    /// `checkForReorg`.
    func heaviestDescent(fromHash hash: String) -> (tipHash: String, cumulativeWork: UInt256)? {
        guard let start = hashToBlock[hash] else { return nil }
        let descent = ghostDescent(from: start)
        guard let work = hashToBlock[descent.tipHash]?.cumulativeWork else { return nil }
        return (descent.tipHash, work)
    }

    /// The fork base of the branch ending at `leaf`: its deepest ancestor that is NOT
    /// on the current main chain (the sibling of the main-chain block at that height),
    /// found by riding the pruning-durable linkage up until the parent lands on the
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
        stateDiff: StateDiff = .empty,
        contribution: VerifiedWorkContribution
    ) -> SubmissionResult {
        let blockHash = blockHeader.rawCID
        let isRoot = block.parent == nil

        if contribution.work == .zero || (isRoot && block.height != 0) {
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
            return addWorkContribution(
                contribution,
                blockHeader: blockHeader,
                block: block
            )
        }

        let result = insertBlock(
            blockHash: blockHash,
            block: block,
            stateDiff: stateDiff,
            contributions: [contribution],
            addedContribution: true
        )
        if !result.addedBlock { return result }
        mutationGeneration &+= 1

        if result.extendsMainChain {
            // Forward the tip-extend connect set so out-of-order
            // descendants the GHOST re-descent pulled onto the main chain reach the
            // node's reorg consumers; `.extendsMainChain()` carries `nil` otherwise.
            return SubmissionResult(
                addedBlock: true,
                addedContribution: result.addedContribution,
                extendsMainChain: true,
                needsParentBlock: false,
                reorganization: result.reorganization,
                evictedBlocks: result.evictedBlocks
            )
        }
        if result.needsParentBlock { return result }

        let meta = hashToBlock[blockHash]!
        if let reorg = checkForReorg(block: meta) {
            return SubmissionResult(
                addedBlock: true,
                addedContribution: result.addedContribution,
                extendsMainChain: false,
                needsParentBlock: false,
                reorganization: reorg,
                evictedBlocks: reorg.evictedBlocks
            )
        }

        return result
    }

    // MARK: - Insert

    func insertBlock(
        blockHash: String,
        block: Block,
        stateDiff: StateDiff,
        contributions: [VerifiedWorkContribution],
        addedContribution: Bool
    ) -> SubmissionResult {
        guard !contributions.isEmpty,
              Set(contributions.map(\.id)).count == contributions.count,
              contributions.allSatisfy({ $0.work > .zero }),
              !(block.parent == nil && block.height != 0)
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
        addToBlockIndex(hash: blockHash, blockHeight: block.height)

        let ownWork = contributions.reduce(.zero) {
            saturatingWorkSum($0, $1.work)
        }
        let parentCumulativeWork: UInt256
        if let parentHash = block.parent?.rawCID {
            parentCumulativeWork = hashToBlock[parentHash]?.cumulativeWork ?? .zero
        } else {
            parentCumulativeWork = .zero
        }
        let blockCumulativeWork = saturatingWorkSum(parentCumulativeWork, ownWork)
        let childHashes = findChildren(hash: blockHash, blockHeight: block.height)
        let meta = BlockMeta(
            blockHash: blockHash,
            parentBlockHash: block.parent?.rawCID,
            blockHeight: block.height,
            childHashes: childHashes,
            stateDiff: stateDiff,
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
        blockTimestamps[blockHash] = block.timestamp
        tipSnapshotsByHash[blockHash] = Self.snapshot(for: block)
        if let prevHash = block.parent?.rawCID,
           hashToBlock[prevHash]?.childHashes.contains(blockHash) == false {
            hashToBlock[prevHash]?.childHashes.append(blockHash)
        }

        // Out-of-order repair: if children of this block were delivered before it,
        // they were inserted with a provisional prefix sum (own work only, since
        // their parent was missing). Now that this block's prefix is known, fix
        // them and their descendants.
        propagateCumulativeWork(from: blockHash)

        propagateSubtreeWeight(from: blockHash)

        guard let previousBlockCID = block.parent?.rawCID else {
            return SubmissionResult(
                addedBlock: true,
                addedContribution: addedContribution,
                extendsMainChain: false,
                needsParentBlock: false,
                reorganization: nil
            )
        }

        if previousBlockCID == chainTip {
            // A tip extension can connect descendants that arrived first. Report the
            // full connect set when that happens.
            let tipUpdate = setNewTip(block: meta)
            if tipUpdate.connected.count > 1 {
                let reorg = Reorganization(
                    newTipHash: chainTip,
                    mainChainBlocksAdded: tipUpdate.connected,
                    mainChainBlocksRemoved: Set(),
                    missingBodies: tipUpdate.missingBodies,
                    evictedBlocks: tipUpdate.evictedBlocks
                )
                return SubmissionResult(
                    addedBlock: true,
                    addedContribution: addedContribution,
                    extendsMainChain: true,
                    needsParentBlock: false,
                    reorganization: reorg,
                    evictedBlocks: tipUpdate.evictedBlocks
                )
            }
            return .extendsMainChain(
                addedContribution: addedContribution,
                evictedBlocks: tipUpdate.evictedBlocks
            )
        }

        if hashToBlock[previousBlockCID] == nil {
            return SubmissionResult(
                addedBlock: true,
                addedContribution: addedContribution,
                extendsMainChain: false,
                needsParentBlock: true,
                reorganization: nil
            )
        }

        return SubmissionResult(
            addedBlock: true,
            addedContribution: addedContribution,
            extendsMainChain: false,
            needsParentBlock: false,
            reorganization: nil
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
                let expected = saturatingWorkSum(parentCum, childMeta.work)
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
        // dependence on the subtree below runs *through* this unchanged value). The
        // stop stays safe under saturation because `saturatingWorkSum` is monotone —
        // a clamped ancestor only ever stays clamped.
        var isStart = true
        while let h = current, let meta = hashToBlock[h] {
            var weight = meta.work
            for childHash in meta.childHashes {
                weight = saturatingWorkSum(weight, hashToBlock[childHash]?.subtreeWeight ?? .zero)
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
                weight = saturatingWorkSum(weight, childWeight)
            }
            blocks[meta.blockHash]?.setSubtreeWeight(weight)
        }
    }

    // MARK: - Additional proof facts

    func addWorkContribution(
        _ contribution: VerifiedWorkContribution,
        blockHeader: BlockHeader,
        block: Block
    ) -> SubmissionResult {
        let blockHash = blockHeader.rawCID
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
        meta.setCumulativeWork(saturatingWorkSum(parentWork, meta.work))
        hashToBlock[blockHash] = meta
        blockTimestamps[blockHash] = block.timestamp
        tipSnapshotsByHash[blockHash] = Self.snapshot(for: block)
        workContributionIndex[contribution.id] = record
        propagateCumulativeWork(from: blockHash)
        propagateSubtreeWeight(from: blockHash)
        mutationGeneration &+= 1

        let reorg = mainChainBlockAtIndex[meta.blockHeight] == blockHash
            ? nil
            : checkForReorg(block: hashToBlock[blockHash]!)
        if reorg != nil {
            tipSnapshot = tipSnapshotsByHash[chainTip]
        }
        return SubmissionResult(
            addedBlock: false,
            addedContribution: true,
            extendsMainChain: false,
            needsParentBlock: false,
            reorganization: reorg,
            evictedBlocks: reorg?.evictedBlocks ?? []
        )
    }

    func workContribution(id: String) -> WorkContributionRecord? {
        workContributionIndex[id]
    }

    func submitBlockIfUnchanged(
        expectedMutationGeneration: UInt64,
        blockHeader: BlockHeader,
        block: Block,
        stateDiff: StateDiff,
        contribution: VerifiedWorkContribution
    ) -> SubmissionResult? {
        guard mutationGeneration == expectedMutationGeneration else { return nil }
        return submitBlock(
            blockHeader: blockHeader,
            block: block,
            stateDiff: stateDiff,
            contribution: contribution
        )
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
    /// Equal work keeps the incumbent child when one is already canonical.
    func chainWithMostWork(
        startingBlock: BlockMeta
    ) -> (subtreeWork: UInt256, tipHash: String, blocks: Set<String>) {
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
            var weighted: [(hash: String, work: UInt256)] = []
            for childHash in children.sorted() {
                guard let childWeight = hashToBlock[childHash]?.subtreeWeight else { continue }
                weighted.append((childHash, childWeight))
            }
            guard let bestWeight = weighted.map(\.work).max() else { break }
            let tied = weighted.filter { $0.work == bestWeight }.map(\.hash)
            let incumbent = tied.first { hash in
                guard let height = hashToBlock[hash]?.blockHeight else { return false }
                return mainChainBlockAtIndex[height] == hash
            }
            guard let next = incumbent ?? tied.first, next != currentHash else { break }
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
    ) -> (subtreeWork: UInt256, blocks: Set<String>) {
        let weight = mainChainBlockAtIndex[blockHeight].flatMap {
            hashToBlock[$0]?.subtreeWeight
        } ?? .zero
        return (weight, mainChainHashesFrom(index: blockHeight))
    }

    // MARK: - Reorganization

    package func checkForReorg(block: BlockMeta) -> Reorganization? {
        guard let earliestHash = findEarliestOrphanConnectedToMainChain(
            blockHeader: block.blockHash
        ) else {
            return nil
        }
        guard let earliest = hashToBlock[earliestHash] else { return nil }

        let mainWork = mainChainWork(fromIndex: earliest.blockHeight)
        let forkWork = chainWithMostWork(startingBlock: earliest)

        if forkWork.subtreeWork > mainWork.subtreeWork {
            return applyReorg(
                newForkBlocks: forkWork.blocks,
                newForkTipHash: forkWork.tipHash,
                mainChainBlocks: mainWork.blocks
            )
        }
        return nil
    }

    func applyReorg(
        newForkBlocks: Set<String>,
        newForkTipHash: String?,
        mainChainBlocks: Set<String>
    ) -> Reorganization {
        var forkHashToIndex: [String: UInt64] = [:]
        var highestIndex: UInt64 = 0

        for hash in newForkBlocks {
            guard let idx = hashToBlock[hash]?.blockHeight else { continue }
            forkHashToIndex[hash] = idx
            if idx > highestIndex { highestIndex = idx }
        }
        let missingBodies = forkHashToIndex
            .filter { hashToBlock[$0.key]?.stateDiff == nil }
            .sorted { $0.value < $1.value }
            .map(\.key)

        let newTip = newForkTipHash ?? chainTip
        let evictedBlocks = advanceTip(to: newTip, newHighestIndex: highestIndex)

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

        return Reorganization(
            newTipHash: newTip,
            mainChainBlocksAdded: forkHashToIndex,
            mainChainBlocksRemoved: mainChainBlocks,
            missingBodies: missingBodies,
            evictedBlocks: evictedBlocks
        )
    }

    /// Advance the main-chain tip onto the heaviest descent from `block` (whose parent
    /// is the current tip). Returns the **connect set**: the blocks that newly joined
    /// the main chain, keyed by height — `chainWithMostWork`'s descent `blocks`. In the
    /// common in-order extend this is just `{block}`; when GHOST descent advances the
    /// tip past already-attached out-of-order descendants it also includes those, so
    /// the caller can emit a `Reorganization` and re-anchor them (1)).
    @discardableResult
    func setNewTip(
        block: BlockMeta
    ) -> (connected: [String: UInt64], missingBodies: [String], evictedBlocks: [BlockMeta]) {
        let oldHighest = highestBlockHeight
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
        let missingBodies = connectSet
            .filter { hashToBlock[$0.key]?.stateDiff == nil }
            .sorted { $0.value < $1.value }
            .map(\.key)
        let newHighest = highestBlockHeight
        var evictedBlocks: [BlockMeta] = []
        if let prunable = newlyPrunableRange(oldHighest: oldHighest, newHighest: newHighest) {
            for idx in prunable {
                evictedBlocks.append(contentsOf: pruneBlocksAtIndex(idx))
            }
        }
        return (connectSet, missingBodies, evictedBlocks)
    }

    func advanceTip(to blockHash: String, newHighestIndex: UInt64) -> [BlockMeta] {
        let oldHighest = highestBlockHeight
        chainTip = blockHash
        tipSnapshot = tipSnapshotsByHash[chainTip]

        var evictedBlocks: [BlockMeta] = []
        if let prunable = newlyPrunableRange(oldHighest: oldHighest, newHighest: newHighestIndex) {
            for idx in prunable {
                evictedBlocks.append(contentsOf: pruneBlocksAtIndex(idx))
            }
        }
        return evictedBlocks
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

    // MARK: - Pruning

    @discardableResult
    func pruneBlocksAtIndex(_ index: UInt64) -> [BlockMeta] {
        guard let hashes = indexToBlockHash[index] else { return [] }
        var evictedBlocks: [BlockMeta] = []
        for hash in hashes {
            guard var meta = hashToBlock[hash], meta.stateDiff != nil else { continue }
            evictedBlocks.append(meta)
            meta.clearLifecycleDiffs()
            hashToBlock[hash] = meta
        }
        return evictedBlocks
    }

    private func newlyPrunableRange(
        oldHighest: UInt64,
        newHighest: UInt64
    ) -> Range<UInt64>? {
        guard retentionDepth != .max, newHighest > retentionDepth else { return nil }
        let oldCutoff = oldHighest > retentionDepth ? oldHighest - retentionDepth : 0
        let newCutoff = newHighest - retentionDepth
        return newCutoff > oldCutoff ? oldCutoff..<newCutoff : nil
    }
}
