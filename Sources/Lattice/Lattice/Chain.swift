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
public func forkChoicePrefersSegmentBase(
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
    /// This is a derived diagnostic, rebuilt on demand from durable block work
    /// facts after recovery. It is never a fork-choice input or persisted
    /// source of truth.
    public private(set) var cumulativeWork: WorkSum

    /// The forward same-chain subtree measure, deduplicated by physical grind.
    /// This derived local diagnostic is rebuilt on demand; live inherited work
    /// is unioned only while making a fork-choice decision.
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
        if let existing = workContributions[contribution.id] {
            work = work.subtracting(WorkSum(existing.work))!
        }
        workContributions[contribution.id] = contribution
        work = work + contribution.work
        return true
    }

}

struct WorkContributionRecord: Sendable, Equatable {
    var blockHashes: Set<String>
    var contribution: VerifiedWorkContribution
    /// Derived GHOST routing only. Local work indexes intentionally leave this
    /// empty; fork-choice indexes cache the segment bases covered by the grind.
    var coveredSegmentBases: Set<String>

    init(
        blockHashes: Set<String>,
        contribution: VerifiedWorkContribution,
        coveredSegmentBases: Set<String> = []
    ) {
        self.blockHashes = blockHashes
        self.contribution = contribution
        self.coveredSegmentBases = coveredSegmentBases
    }
}

/// Routing metadata for a derived maximal-unary-segment cache. It deliberately
/// stores no work: immutable block facts and grind coverage remain the only
/// consensus source of truth.
private struct SegmentIndex {
    var baseByBlock: [String: String] = [:]
    var parentBaseByBase: [String: String] = [:]
    var tailByBase: [String: String] = [:]

    func bases(covering blockHash: String) -> Set<String> {
        guard var base = baseByBlock[blockHash] else { return [] }
        var result = Set<String>()
        while result.insert(base).inserted,
              let parent = parentBaseByBase[base] {
            base = parent
        }
        return result
    }
}

/// Parent-proven child coverage plus the accepted ancestry relations explicitly
/// reported by that child process. Unreported relations stay incomparable.
/// This is a routing hint, never parent-side evidence of child validity.
private struct ChildCoverageQuotient {
    private let intervals: [String: (entry: Int, exit: Int)]
    private let blockByEntry: [Int: String]
    private let clockSize: Int
    let blocks: Set<String>

    init?(_ predecessorByBlock: [String: String?]) {
        blocks = Set(predecessorByBlock.keys)
        guard blocks.allSatisfy(Self.hasCanonicalIdentity) else { return nil }

        var children: [String: [String]] = [:]
        var roots: [String] = []
        for block in blocks {
            guard let predecessor = predecessorByBlock[block] else { return nil }
            if let predecessor {
                guard predecessor != block,
                      blocks.contains(predecessor),
                      Self.hasCanonicalIdentity(predecessor) else { return nil }
                children[predecessor, default: []].append(block)
            } else {
                roots.append(block)
            }
        }
        guard blocks.isEmpty || !roots.isEmpty else { return nil }

        var discovered = Set<String>()
        var entries: [String: Int] = [:]
        var completed: [String: Int] = [:]
        var next = 0
        var pending = roots.sorted().reversed().map {
            (block: $0, exiting: false)
        }
        while let frame = pending.popLast() {
            if frame.exiting {
                completed[frame.block] = next
                next += 1
                continue
            }
            guard discovered.insert(frame.block).inserted else { return nil }
            entries[frame.block] = next
            next += 1
            pending.append((frame.block, true))
            for child in (children[frame.block] ?? []).sorted().reversed() {
                pending.append((child, false))
            }
        }
        guard discovered == blocks else { return nil }
        let builtIntervals: [String: (entry: Int, exit: Int)] = Dictionary(
            uniqueKeysWithValues: blocks.compactMap { block in
            guard let entry = entries[block], let exit = completed[block] else {
                return nil
            }
            return (block, (entry, exit))
        })
        guard builtIntervals.count == blocks.count else { return nil }
        intervals = builtIntervals
        blockByEntry = Dictionary(uniqueKeysWithValues: builtIntervals.map {
            ($0.value.entry, $0.key)
        })
        clockSize = next
    }

    private static func hasCanonicalIdentity(_ value: String) -> Bool {
        let canonical = CIDIdentity.canonicalString(value)
        return canonical == nil || canonical == value
    }

    func makeFrontier() -> LaminarFrontier {
        LaminarFrontier(
            intervals: intervals,
            blockByEntry: blockByEntry,
            clockSize: clockSize
        )
    }

    func maximalBlocks(in candidates: Set<String>) -> [String] {
        let ordered = candidates.compactMap { block -> (String, Int, Int)? in
            guard let interval = intervals[block] else { return nil }
            return (block, interval.entry, interval.exit)
        }.sorted { $0.1 < $1.1 }
        return ordered.indices.compactMap { index in
            let candidate = ordered[index]
            if index + 1 < ordered.count,
               ordered[index + 1].1 <= candidate.2 {
                return nil
            }
            return candidate.0
        }
    }
}

/// A mutable antichain over one fixed DFS-interval forest. Point counts make
/// descendant and sole-possible-ancestor checks logarithmic; mutations are
/// reversible so one frontier can follow a parent DFS without branch copies.
private struct LaminarFrontier {
    struct Mutation {
        let inserted: Int?
        let removed: Int?
        let previousStateID: Int
    }

    private struct Transition: Hashable {
        let stateID: Int
        let entry: Int
    }

    private let exitByEntry: [Int: Int]
    private let entryByBlock: [String: Int]
    private let blockByEntry: [Int: String]
    private var counts: [Int]
    private var entries = Set<Int>()
    private var transitionIDs: [Transition: Int] = [:]
    private var nextStateID = 1
    private(set) var stateID = 0

    init(
        intervals: [String: (entry: Int, exit: Int)],
        blockByEntry: [Int: String],
        clockSize: Int
    ) {
        exitByEntry = Dictionary(uniqueKeysWithValues: intervals.values.map {
            ($0.entry, $0.exit)
        })
        entryByBlock = intervals.mapValues(\.entry)
        self.blockByEntry = blockByEntry
        counts = Array(repeating: 0, count: clockSize + 1)
    }

    var blocks: [String] {
        entries.compactMap { blockByEntry[$0] }
    }

    mutating func insert(_ block: String) -> Mutation {
        let previousStateID = stateID
        guard let entry = entryByBlock[block],
              let exit = exitByEntry[entry],
              rangeCount(entry...exit) == 0 else {
            return Mutation(
                inserted: nil,
                removed: nil,
                previousStateID: previousStateID
            )
        }
        var removed: Int?
        let earlierCount = prefixCount(through: entry - 1)
        if earlierCount > 0 {
            let predecessor = entryAtRank(earlierCount)
            if let predecessorExit = exitByEntry[predecessor],
               predecessorExit >= exit {
                remove(predecessor)
                removed = predecessor
            }
        }
        add(entry)
        let transition = Transition(stateID: previousStateID, entry: entry)
        if let existing = transitionIDs[transition] {
            stateID = existing
        } else {
            stateID = nextStateID
            transitionIDs[transition] = nextStateID
            nextStateID += 1
        }
        return Mutation(
            inserted: entry,
            removed: removed,
            previousStateID: previousStateID
        )
    }

    mutating func undo(_ mutation: Mutation) {
        if let inserted = mutation.inserted { remove(inserted) }
        if let removed = mutation.removed { add(removed) }
        stateID = mutation.previousStateID
    }

    private func prefixCount(through entry: Int) -> Int {
        guard entry >= 0 else { return 0 }
        var index = min(entry + 1, counts.count - 1)
        var result = 0
        while index > 0 {
            result += counts[index]
            index -= index & -index
        }
        return result
    }

    private func rangeCount(_ range: ClosedRange<Int>) -> Int {
        prefixCount(through: range.upperBound)
            - prefixCount(through: range.lowerBound - 1)
    }

    private func entryAtRank(_ rank: Int) -> Int {
        var remaining = rank
        var index = 0
        var step = 1
        while step << 1 < counts.count { step <<= 1 }
        while step > 0 {
            let next = index + step
            if next < counts.count, counts[next] < remaining {
                index = next
                remaining -= counts[next]
            }
            step >>= 1
        }
        return index
    }

    private mutating func add(_ entry: Int) {
        guard entries.insert(entry).inserted else { return }
        update(entry, by: 1)
    }

    private mutating func remove(_ entry: Int) {
        guard entries.remove(entry) != nil else { return }
        update(entry, by: -1)
    }

    private mutating func update(_ entry: Int, by delta: Int) {
        var index = entry + 1
        while index < counts.count {
            counts[index] += delta
            index += index & -index
        }
    }
}

private struct CanonicalSegment: Equatable {
    var base: String
    var tail: String
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
        guard CIDIdentity.isCanonical(fact.blockHash),
              fact.parentBlockHash.map(CIDIdentity.isCanonical) ?? true,
              CIDIdentity.isCanonical(fact.postStateCID),
              CIDIdentity.isCanonical(fact.prevStateCID),
              CIDIdentity.isCanonical(fact.specCID),
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
              CIDIdentity.isCanonical(work.blockHash),
              CIDIdentity.isCanonical(work.contribution.id) else {
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

/// Mutable retained parent facts. Its measures deliberately remain raw; the
/// snapshot preserves that relation, while the fork-choice index derives the
/// strongest value for every covered physical grind.
private struct InheritedWorkAccumulator {
    struct Update {
        let blockHash: String
        let contribution: VerifiedWorkContribution
    }

    private var rawWorkByBlock: [String: WorkMeasure]
    private var strongestWorkByGrind: [String: UInt256]
    private(set) var revision: UInt64

    init(_ snapshot: InheritedWorkSnapshot = .zero) {
        rawWorkByBlock = snapshot.entriesByBlock
        strongestWorkByGrind = snapshot.strongestWorkByGrind
        revision = snapshot.revision
    }

    func snapshot() -> InheritedWorkSnapshot {
        InheritedWorkSnapshot(
            revision: revision,
            workByBlock: rawWorkByBlock
        )
    }

    func work(forBlock blockHash: String) -> WorkMeasure {
        (rawWorkByBlock[blockHash] ?? .zero).normalized(
            using: strongestWorkByGrind
        )
    }

    mutating func merge(
        _ snapshot: InheritedWorkSnapshot
    ) -> (changed: Bool, updates: [Update]) {
        revision = max(revision, snapshot.revision)
        var changed = false
        var updates: [Update] = []

        for (blockHash, measure) in snapshot.entriesByBlock {
            let hadBlock = rawWorkByBlock[blockHash] != nil
            var rawMeasure = rawWorkByBlock[blockHash] ?? .zero
            if !hadBlock { changed = true }

            for (id, work) in measure.entries {
                let hadCoverage = rawMeasure.work(forGrind: id) != nil
                let strongest = strongestWorkByGrind[id] ?? .zero
                _ = rawMeasure.insert(VerifiedWorkContribution(id: id, work: work))
                if work > strongest {
                    strongestWorkByGrind[id] = work
                }

                // New coverage changes the covered segment set; a new global
                // maximum changes every existing coverage for this grind.
                guard work > .zero,
                      !hadCoverage || work > strongest else { continue }
                changed = true
                updates.append(Update(
                    blockHash: blockHash,
                    contribution: VerifiedWorkContribution(id: id, work: work)
                ))
            }
            rawWorkByBlock[blockHash] = rawMeasure
        }
        return (changed, updates)
    }
}

public actor ChainState {
    var chainTip: String
    var mainChainHashes: Set<String>
    var indexToBlockHash: [UInt64: Set<String>]
    var hashToBlock: [String: BlockMeta]
    var workByGrind: [String: WorkContributionRecord]
    var forkChoiceWorkByGrind: [String: WorkContributionRecord]
    /// Derived GHOST weights exist only where a choice can be made: genesis
    /// roots and children of a same-chain fork. Per-block facts remain the
    /// source of truth because scalar weights cannot preserve grind identity.
    var segmentBaseWeights: [String: WorkSum]
    private var segmentIndex: SegmentIndex
    /// The selected quotient path. A normal leaf extension updates only this
    /// final tail instead of rewalking the unchanged unary prefix.
    private var canonicalSegmentSpine: [CanonicalSegment]
#if DEBUG
    /// Test-visible diagnostic for a whole-block canonical materialization.
    var fullCanonicalProjectionCount: UInt64
#endif
    /// Diagnostic prefix/subtree totals are derived local views. They are not
    /// fork-choice inputs and are rebuilt only when an API exposes them.
    private var localWorkCachesDirty: Bool

    var inheritedWorkProvider: InheritedWorkProvider?
    private var inheritedWorkFacts: InheritedWorkAccumulator?
    var inheritedWorkSnapshot: InheritedWorkSnapshot? {
        inheritedWorkFacts?.snapshot()
    }

    var mainChainBlockAtIndex: [UInt64: String]
    var blockTimestamps: [String: Int64]
    /// Advances for every successful consensus mutation.
    var mutationGeneration: UInt64
    /// Capacity held across the node's asynchronous stage boundary. These
    /// reservations are fungible and disappear on restart; staged facts replay
    /// against the same pre-stage revision floor.
    var reservedAdmissionRevisions: UInt64

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
        self.forkChoiceWorkByGrind = [:]
        self.segmentBaseWeights = [:]
        self.segmentIndex = SegmentIndex()
        self.canonicalSegmentSpine = []
#if DEBUG
        self.fullCanonicalProjectionCount = 0
#endif
        self.localWorkCachesDirty = true
        var allByHeight = indexToBlockHash
        for meta in hashToBlock.values {
            allByHeight[meta.blockHeight, default: []].insert(meta.blockHash)
        }
        self.indexToBlockHash = allByHeight
        let initialInherited = (inheritedWorkSnapshot ?? inheritedWorkProvider?())
            .flatMap { $0.hasNoCIDTextAliases ? $0 : nil }
        self.inheritedWorkProvider = inheritedWorkProvider
        self.inheritedWorkFacts = initialInherited.map(InheritedWorkAccumulator.init)
        self.tipSnapshot = tipSnapshot
        self.tipSnapshotsByHash = tipSnapshotsByHash
        if let tipSnapshot {
            self.tipSnapshotsByHash[chainTip] = tipSnapshot
        }
        self.blockTimestamps = blockTimestamps
        self.mutationGeneration = mutationGeneration
        self.reservedAdmissionRevisions = 0
        self.mainChainBlockAtIndex = [:]
        for meta in self.hashToBlock.values {
            let contributions = meta.workContributions.values
            guard !contributions.isEmpty,
                  contributions.allSatisfy({ $0.work > .zero }) else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
        }
        self.workByGrind = Self.workIndex(in: self.hashToBlock)
        let inherited = initialInherited ?? .zero
        self.segmentIndex = Self.makeSegmentIndex(in: self.hashToBlock)
        self.forkChoiceWorkByGrind = Self.workIndex(
            in: self.hashToBlock,
            inherited: inherited
        )
        self.segmentBaseWeights = Self.buildSegmentBaseWeights(
            index: self.segmentIndex,
            workByGrind: &self.forkChoiceWorkByGrind
        )
        self.canonicalSegmentSpine = Self.segmentSpine(
            endingAt: chainTip,
            in: self.hashToBlock,
            index: self.segmentIndex
        )
        for hash in mainChainHashes {
            guard let height = self.hashToBlock[hash]?.blockHeight,
                  self.mainChainBlockAtIndex[height] == nil else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            self.mainChainBlockAtIndex[height] = hash
        }
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
        guard hasUnreservedMutationCapacity else { return nil }
        let inheritedChanged = refreshInheritedWork()
        let canonicalChange = projectCanonicalChain()
        guard inheritedChanged || canonicalChange != nil else { return nil }
        mutationGeneration += 1
        return (canonicalChange ?? ChainCommit(tipHash: chainTip))
            .atRevision(mutationGeneration)
    }

    /// Merge one locally authenticated inherited-work update. Updates are
    /// monotonic facts, not a proof exchange: an old revision may still add
    /// coverage, while an equal snapshot is a no-op. Only the new facts touch
    /// the incremental GHOST caches.
    @discardableResult
    public func mergeInheritedWork(
        _ snapshot: InheritedWorkSnapshot
    ) -> ChainCommit? {
        guard hasUnreservedMutationCapacity else { return nil }
        guard mergeInheritedWorkSnapshot(snapshot) else { return nil }
        let canonicalChange = projectCanonicalChain()
        mutationGeneration += 1
        return (canonicalChange ?? ChainCommit(tipHash: chainTip))
            .atRevision(mutationGeneration)
    }

    /// Atomically export the parent-side work securing each child block. The node
    /// supplies bindings already verified from content-addressed paths and may
    /// supply the child's session-scoped accepted coverage quotient. Only those
    /// explicit ancestry relations remove dominated routes; unmentioned coverage
    /// remains conservatively incomparable. Lattice stores no cross-process
    /// parent/child relationship index.
    public func inheritedWorkSnapshot(
        forChildCoverage verifiedParentBlocksByChildBlock: [String: Set<String>],
        acceptedChildPredecessorByBlock: [String: String?]? = nil
    ) -> InheritedWorkSnapshot? {
        let coveredChildBlocks = Set(verifiedParentBlocksByChildBlock.keys)
        let suppliedQuotient = acceptedChildPredecessorByBlock ?? [:]
        let conservativeQuotient = Dictionary(
            uniqueKeysWithValues: coveredChildBlocks.map { childBlock in
                let predecessor = suppliedQuotient[childBlock]
                    .flatMap { $0 }
                    .flatMap { coveredChildBlocks.contains($0) ? $0 : nil }
                return (childBlock, predecessor)
            }
        )
        guard let quotient = ChildCoverageQuotient(conservativeQuotient) else {
            return nil
        }
        let requestedParentBlocks = Set(
            verifiedParentBlocksByChildBlock.values.joined()
        )
        guard requestedParentBlocks.allSatisfy({ hashToBlock[$0] != nil }) else {
            return nil
        }
        let connectedCoverage = verifiedParentBlocksByChildBlock.compactMapValues {
            let eligible = $0.filter { segmentIndex.baseByBlock[$0] != nil }
            return eligible.isEmpty ? nil : eligible
        }
        guard !connectedCoverage.isEmpty else { return nil }

        var childBlocksByParentBlock: [String: Set<String>] = [:]
        for (childBlock, parentBlocks) in connectedCoverage {
            for parentBlock in parentBlocks {
                childBlocksByParentBlock[parentBlock, default: []].insert(childBlock)
            }
        }
        let inherited = retainedInheritedWork()
        let strongestWork = Self.strongestWorkByGrind(
            in: hashToBlock,
            inherited: inherited
        )
        let roots = hashToBlock.values.filter {
            $0.parentBlockHash == nil && $0.blockHeight == 0
        }.map(\.blockHash).sorted()
        let terminalGrinds = deepestConnectedWorkOccurrences(
            from: roots,
            inherited: inherited
        )
        var candidatesByGrind: [String: Set<String>] = [:]
        var routedStatesByGrind: [String: Set<Int>] = [:]
        var activeChildren = quotient.makeFrontier()
        var pending: [(parentBlock: String, undo: [LaminarFrontier.Mutation]?)] =
            roots.reversed().map { ($0, nil) }
        while let frame = pending.popLast() {
            if let mutations = frame.undo {
                for mutation in mutations.reversed() {
                    activeChildren.undo(mutation)
                }
                continue
            }
            guard let block = hashToBlock[frame.parentBlock],
                  segmentIndex.baseByBlock[frame.parentBlock] != nil else {
                continue
            }
            let mutations = (childBlocksByParentBlock[frame.parentBlock] ?? [])
                .sorted()
                .map { activeChildren.insert($0) }
            if let grindIDs = terminalGrinds[frame.parentBlock] {
                var routedChildren: [String]?
                for grindID in grindIDs {
                    guard routedStatesByGrind[grindID, default: []]
                        .insert(activeChildren.stateID).inserted else { continue }
                    if routedChildren == nil {
                        routedChildren = activeChildren.blocks
                    }
                    candidatesByGrind[grindID, default: []]
                        .formUnion(routedChildren ?? [])
                }
            }
            pending.append((frame.parentBlock, mutations))
            for child in block.childHashes.reversed() {
                pending.append((child, nil))
            }
        }

        var workByChildBlock: [String: WorkMeasure] = [:]
        for (grindID, candidates) in candidatesByGrind {
            guard let work = strongestWork[grindID] else { continue }
            for childBlock in quotient.maximalBlocks(in: candidates) {
                _ = workByChildBlock[childBlock, default: .zero].insert(
                    VerifiedWorkContribution(id: grindID, work: work)
                )
            }
        }
        return InheritedWorkSnapshot(
            revision: mutationGeneration,
            workByBlock: workByChildBlock
        )
    }

    /// For one grind, an occurrence below another connected occurrence carries
    /// every child route active above it. Only deepest incomparable parent
    /// occurrences can therefore add coverage to the exported frontier.
    private func deepestConnectedWorkOccurrences(
        from roots: [String],
        inherited: InheritedWorkSnapshot
    ) -> [String: Set<String>] {
        var order: [String] = []
        var pending = Array(roots.reversed())
        while let hash = pending.popLast() {
            guard let block = hashToBlock[hash],
                  segmentIndex.baseByBlock[hash] != nil else { continue }
            order.append(hash)
            pending.append(contentsOf: block.childHashes.reversed())
        }

        var subtreeGrinds: [String: Set<String>] = [:]
        var terminalGrinds: [String: Set<String>] = [:]
        for hash in order.reversed() {
            guard let block = hashToBlock[hash] else { continue }
            let largestChild = block.childHashes.max {
                (subtreeGrinds[$0]?.count ?? 0)
                    < (subtreeGrinds[$1]?.count ?? 0)
            }
            var descendants = largestChild.flatMap {
                subtreeGrinds.removeValue(forKey: $0)
            } ?? []
            for child in block.childHashes where child != largestChild {
                descendants.formUnion(subtreeGrinds.removeValue(forKey: child) ?? [])
            }
            var local = Set(block.workContributions.keys)
            local.formUnion(inherited.sourceWork(forBlock: hash).grindIDs)
            let terminal = local.subtracting(descendants)
            if !terminal.isEmpty { terminalGrinds[hash] = terminal }
            descendants.formUnion(local)
            subtreeGrinds[hash] = descendants
        }
        return terminalGrinds
    }

    private func retainedInheritedWork() -> InheritedWorkSnapshot {
        inheritedWorkSnapshot ?? .zero
    }

    private func inheritedWork(forBlock blockHash: String) -> WorkMeasure {
        inheritedWorkFacts?.work(forBlock: blockHash) ?? .zero
    }

    @discardableResult
    private func refreshInheritedWork() -> Bool {
        guard let candidate = inheritedWorkProvider?() else { return false }
        return mergeInheritedWorkSnapshot(candidate)
    }

    /// Apply only newly covered blocks and new global grind maxima. The retained
    /// accumulator keeps raw coverage, while `applyForkChoiceContribution`
    /// continues to own global normalization for the live GHOST cache.
    @discardableResult
    private func mergeInheritedWorkSnapshot(
        _ candidate: InheritedWorkSnapshot
    ) -> Bool {
        guard candidate.hasNoCIDTextAliases else { return false }
        if inheritedWorkFacts == nil {
            inheritedWorkFacts = InheritedWorkAccumulator()
        }
        let result = inheritedWorkFacts!.merge(candidate)
        for update in result.updates {
            applyForkChoiceContribution(
                update.contribution,
                to: update.blockHash
            )
        }
        return result.changed
    }

    public func contains(blockHash: String) -> Bool {
        hashToBlock[blockHash] != nil
    }

    /// Project the connected accepted forest onto the supplied block set. Each
    /// retained block points to its nearest retained accepted ancestor. The
    /// node sends this session-scoped quotient to its immediate parent only as
    /// a sparse-export hint; it is not child-validity evidence.
    public func connectedAcceptedCoverageQuotient(
        for blockCIDs: Set<String>
    ) -> [String: String?] {
        let roots = hashToBlock.values.filter {
            $0.parentBlockHash == nil && $0.blockHeight == 0
        }.map(\.blockHash).sorted()
        var result: [String: String?] = [:]
        var pending = roots.reversed().map {
            (block: $0, nearest: Optional<String>.none)
        }
        while let frame = pending.popLast() {
            guard let block = hashToBlock[frame.block],
                  segmentIndex.baseByBlock[frame.block] != nil else { continue }
            var nearest = frame.nearest
            if blockCIDs.contains(frame.block) {
                result.updateValue(nearest, forKey: frame.block)
                nearest = frame.block
            }
            for child in block.childHashes.reversed() {
                pending.append((child, nearest))
            }
        }
        return result
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
              !hasValidatedAncestry(blockHash: parent) else { return nil }
        return SameChainPredecessorRequirement(
            descendantCID: block.blockHash,
            predecessorCID: parent
        )
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
        let strongestWork = Self.strongestWorkByGrind(
            in: hashToBlock,
            inherited: .zero
        )
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

    /// The local-only same-chain subtree measure of `hash`, deduplicated by grind
    /// identity. Live inherited work is joined only during fork-choice projection.
    public func subtreeWeight(forHash hash: String) -> WorkSum? {
        guard hashToBlock[hash] != nil else { return nil }
        materializeLocalWorkCachesIfNeeded()
        return hashToBlock[hash]?.subtreeWeight
    }

    /// Public simulator/test view of the real local fork-choice descent.
    public func forkChoiceSnapshot(startingAt hash: String) -> ForkChoiceSnapshot? {
        guard let meta = hashToBlock[hash],
              segmentIndex.baseByBlock[hash] != nil else { return nil }
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
#endif

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

        guard hasUnreservedMutationCapacity else { return .discarded() }
        let topologyChanged = requiresSegmentCacheRebuild(for: input)

        let result = insertBlock(
            input: input,
            contributions: [contribution],
            addedContribution: true,
            rebuildSegmentCache: topologyChanged
        )
        if !result.addedBlock { return result }
        mutationGeneration += 1
        let inheritedChanged = refreshInheritedWork()

        let canonicalChange: ChainCommit?
        if !inheritedChanged,
           canAppendCanonicalTip(blockHash, parentHash: input.parentBlockHash, oldTip: oldTip) {
            canonicalChange = appendCanonicalTip(blockHash)
        } else {
            canonicalChange = projectCanonicalChain(forceFull: topologyChanged)
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
        rebuildSegmentCache: Bool
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
        let canUpdateIncrementally = childHashes.isEmpty
        let parentChildCount = input.parentBlockHash.flatMap {
            hashToBlock[$0]?.childHashes.count
        } ?? 0
        // A late parent connects an existing subtree, and a second child turns
        // an old unary suffix into two segment bases. Both cases change the
        // compressed topology and therefore rebuild the derived cache.
        let meta = BlockMeta(
            blockHash: blockHash,
            parentBlockHash: input.parentBlockHash,
            blockHeight: input.blockHeight,
            childHashes: childHashes,
            workContributions: canUpdateIncrementally ? [] : contributions,
            cumulativeWork: .zero,
            subtreeWeight: canUpdateIncrementally ? .zero : nil
        )

        hashToBlock[blockHash] = meta
        blockTimestamps[blockHash] = input.timestamp
        tipSnapshotsByHash[blockHash] = input.snapshot
        if let prevHash = input.parentBlockHash,
           hashToBlock[prevHash]?.childHashes.contains(blockHash) == false {
            hashToBlock[prevHash]?.childHashes.append(blockHash)
        }
        if !rebuildSegmentCache {
            extendSegmentIndex(
                for: blockHash,
                parentChildCount: parentChildCount
            )
        }

        if canUpdateIncrementally {
            for contribution in contributions {
                applyLocalContribution(contribution, to: blockHash)
            }
            if rebuildSegmentCache {
                rebuildForkChoiceSegmentCache()
            } else {
                for contribution in contributions {
                    applyForkChoiceContribution(contribution, to: blockHash)
                }
                for (id, work) in inheritedWork(forBlock: blockHash).entries {
                    applyForkChoiceContribution(
                        VerifiedWorkContribution(id: id, work: work),
                        to: blockHash
                    )
                }
            }
        } else {
            rebuildWorkIndexesAndCaches()
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
        // Quantity is a property of the physical grind, not of the local
        // segment that happened to report it. A disconnected accepted fact can
        // strengthen an already-routed coverage for the same grind, but it
        // cannot put its otherwise unique coverage on that route.
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

    nonisolated static func workIndex(
        in blocks: [String: BlockMeta],
        inherited: InheritedWorkSnapshot = .zero
    ) -> [String: WorkContributionRecord] {
        var result: [String: WorkContributionRecord] = [:]
        func observe(_ contribution: VerifiedWorkContribution, at hash: String?) {
            var record = result[contribution.id] ?? WorkContributionRecord(
                blockHashes: [],
                contribution: contribution
            )
            if contribution.work > record.contribution.work {
                record.contribution = contribution
            }
            if let hash, blocks[hash] != nil { record.blockHashes.insert(hash) }
            result[contribution.id] = record
        }

        for (hash, meta) in blocks {
            for contribution in meta.workContributions.values {
                observe(contribution, at: hash)
            }
        }
        for (hash, measure) in inherited.entriesByBlock {
            for (id, work) in measure.entries {
                observe(VerifiedWorkContribution(id: id, work: work), at: hash)
            }
        }
        return result
    }

    private func rebuildWorkIndexesAndCaches() {
        workByGrind = Self.workIndex(in: hashToBlock)
        localWorkCachesDirty = true
        rebuildForkChoiceSegmentCache()
    }

    private func rebuildForkChoiceSegmentCache() {
        segmentIndex = Self.makeSegmentIndex(in: hashToBlock)
        forkChoiceWorkByGrind = Self.workIndex(
            in: hashToBlock,
            inherited: retainedInheritedWork()
        )
        segmentBaseWeights = Self.buildSegmentBaseWeights(
            index: segmentIndex,
            workByGrind: &forkChoiceWorkByGrind
        )
    }

    /// Extend an unchanged segment topology without walking its unary prefix.
    /// A second child is handled by a full rebuild before this helper runs.
    private func extendSegmentIndex(
        for blockHash: String,
        parentChildCount: Int
    ) {
        guard let block = hashToBlock[blockHash] else { return }
        guard let parentHash = block.parentBlockHash else {
            guard block.blockHeight == 0 else { return }
            segmentIndex.baseByBlock[blockHash] = blockHash
            segmentIndex.parentBaseByBase.removeValue(forKey: blockHash)
            segmentIndex.tailByBase[blockHash] = blockHash
            return
        }
        guard let parentBase = segmentIndex.baseByBlock[parentHash] else {
            return
        }
        if parentChildCount > 1 {
            segmentIndex.baseByBlock[blockHash] = blockHash
            segmentIndex.parentBaseByBase[blockHash] = parentBase
            segmentIndex.tailByBase[blockHash] = blockHash
        } else {
            segmentIndex.baseByBlock[blockHash] = parentBase
            segmentIndex.tailByBase[parentBase] = blockHash
        }
    }

    private func applyLocalContribution(
        _ contribution: VerifiedWorkContribution,
        to blockHash: String
    ) {
        guard hashToBlock[blockHash]?.setWorkContribution(contribution) == true else {
            return
        }
        let id = contribution.id
        var record = workByGrind[id] ?? WorkContributionRecord(
            blockHashes: [],
            contribution: contribution
        )
        if contribution.work > record.contribution.work {
            record.contribution = contribution
        }
        record.blockHashes.insert(blockHash)
        workByGrind[id] = record
        localWorkCachesDirty = true
    }

    /// Rebuild non-consensus diagnostic totals lazily. Fork choice always uses
    /// the identity-aware segment cache instead.
    func materializeLocalWorkCachesIfNeeded() {
        guard localWorkCachesDirty else { return }
        Self.recomputeWorkCaches(in: &hashToBlock)
        localWorkCachesDirty = false
    }

    private func strengthenSegmentBaseWeights(
        by delta: WorkSum,
        bases: Set<String>
    ) {
        for base in bases {
            segmentBaseWeights[base, default: .zero] =
                segmentBaseWeights[base, default: .zero] + delta
        }
    }

    private func applyForkChoiceContribution(
        _ contribution: VerifiedWorkContribution,
        to blockHash: String
    ) {
        let id = contribution.id
        if forkChoiceWorkByGrind[id] == nil {
            forkChoiceWorkByGrind[id] = WorkContributionRecord(
                blockHashes: [],
                contribution: contribution
            )
        }
        if let existing = forkChoiceWorkByGrind[id],
           contribution.work > existing.contribution.work {
            let delta = WorkSum(contribution.work)
                .subtracting(WorkSum(existing.contribution.work))!
            strengthenSegmentBaseWeights(
                by: delta,
                bases: existing.coveredSegmentBases
            )
            forkChoiceWorkByGrind[id]?.contribution = contribution
        }

        guard hashToBlock[blockHash] != nil,
              forkChoiceWorkByGrind[id]?.blockHashes.contains(blockHash) == false,
              let strongest = forkChoiceWorkByGrind[id]?.contribution else { return }
        let newBases = segmentIndex.bases(covering: blockHash)
        let priorBases = forkChoiceWorkByGrind[id]?.coveredSegmentBases ?? []
        for base in newBases.subtracting(priorBases) {
            segmentBaseWeights[base, default: .zero] =
                segmentBaseWeights[base, default: .zero] + strongest.work
        }
        forkChoiceWorkByGrind[id]?.blockHashes.insert(blockHash)
        forkChoiceWorkByGrind[id]?.coveredSegmentBases.formUnion(newBases)
    }

    // MARK: - Additional proof facts

    func addWorkContribution(
        _ contribution: VerifiedWorkContribution,
        to blockHash: String
    ) -> SubmissionResult {
        guard hashToBlock[blockHash] != nil else { return .discarded() }
        if let existing = workContribution(id: contribution.id, at: blockHash),
           existing.work >= contribution.work {
            return .discarded()
        }
        guard hasUnreservedMutationCapacity else { return .discarded() }
        applyLocalContribution(contribution, to: blockHash)
        applyForkChoiceContribution(contribution, to: blockHash)
        mutationGeneration += 1
        _ = refreshInheritedWork()

        let canonicalChange = projectCanonicalChain()
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

    /// Apply one already-durable, locally authenticated admission batch. Live
    /// admission and recovery share this reducer so staging is the only
    /// linearization point.
    func applyStaged(_ batch: ChainAdmissionBatch) throws -> SubmissionResult? {
        guard let trusted = TrustedAdmissionBatch(batch) else {
            throw ChainStateRestoreError.corruptConsensusGraph
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
                return submission
            }
            let submission = submitBlock(input: input, contribution: trusted.contribution)
            guard submission.addedBlock, submission.addedContribution else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
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
    }

    private func hydrateMetadata(from input: ConsensusBlockInput) {
        blockTimestamps[input.blockHash] = input.timestamp
        tipSnapshotsByHash[input.blockHash] = input.snapshot
        if chainTip == input.blockHash {
            tipSnapshot = input.snapshot
        }
    }

    // MARK: - Index Management

    private func requiresSegmentCacheRebuild(for input: ConsensusBlockInput) -> Bool {
        !findChildren(hash: input.blockHash, blockHeight: input.blockHeight).isEmpty
            || input.parentBlockHash.flatMap {
                hashToBlock[$0]?.childHashes.count
            } == 1
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
        in blocks: [String: BlockMeta],
        inherited: InheritedWorkSnapshot
    ) -> [String: UInt256] {
        var strongestWork = inherited.strongestWorkByGrind
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
        inherited: InheritedWorkSnapshot,
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
            let largestChild = meta.childHashes.max {
                (accumulators[$0]?.entries.count ?? 0)
                    < (accumulators[$1]?.entries.count ?? 0)
            }
            var measure = largestChild.flatMap {
                accumulators.removeValue(forKey: $0)
            } ?? .zero
            for childHash in meta.childHashes where childHash != largestChild {
                if let child = accumulators.removeValue(forKey: childHash) {
                    measure.formUnion(child)
                }
            }
            measure.formUnion(
                WorkMeasure(meta.workContributions.values)
                    .normalized(using: strongestWork)
            )
            measure.formUnion(
                inherited.work(forBlock: hash).normalized(using: strongestWork)
            )
            if retainedHashes.contains(hash) { retained[hash] = measure }
            accumulators[hash] = measure
        }
        return retained
    }

    /// Partition every connected root component into maximal unary segments.
    /// A fork vertex stays in its incoming segment; each fork child starts the
    /// next segment. Orphans intentionally receive no route until attachment.
    nonisolated private static func makeSegmentIndex(
        in blocks: [String: BlockMeta]
    ) -> SegmentIndex {
        let roots = blocks.values
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
            .sorted()
        var index = SegmentIndex()
        var visited = Set<String>()
        var pending = roots.reversed().map { (hash: $0, base: $0) }
        while let frame = pending.popLast() {
            guard visited.insert(frame.hash).inserted,
                  let block = blocks[frame.hash] else { continue }
            index.baseByBlock[frame.hash] = frame.base
            let forks = block.childHashes.count > 1
            for childHash in block.childHashes.reversed() {
                guard blocks[childHash] != nil else { continue }
                if forks {
                    index.parentBaseByBase[childHash] = frame.base
                    pending.append((hash: childHash, base: childHash))
                } else {
                    pending.append((hash: childHash, base: frame.base))
                }
            }
        }
        for (hash, base) in index.baseByBlock {
            guard blocks[hash]?.childHashes.count != 1 else { continue }
            index.tailByBase[base] = hash
        }
        return index
    }

    /// Compress the supplied canonical path once while constructing a chain.
    /// Later steady-state projections use `segmentGhostSpine` and do not walk
    /// unary blocks unless the selected quotient path changes.
    nonisolated private static func segmentSpine(
        endingAt tipHash: String,
        in blocks: [String: BlockMeta],
        index: SegmentIndex
    ) -> [CanonicalSegment] {
        var reversePath: [String] = []
        var currentHash: String? = tipHash
        var visited = Set<String>()
        while let hash = currentHash,
              visited.insert(hash).inserted,
              let block = blocks[hash] {
            reversePath.append(hash)
            currentHash = block.parentBlockHash
        }

        var spine: [CanonicalSegment] = []
        var base: String?
        var tail: String?
        for hash in reversePath.reversed() {
            let nextBase = index.baseByBlock[hash] ?? hash
            if nextBase != base {
                if let base, let tail {
                    spine.append(CanonicalSegment(base: base, tail: tail))
                }
                base = nextBase
            }
            tail = hash
        }
        if let base, let tail {
            spine.append(CanonicalSegment(base: base, tail: tail))
        }
        return spine
    }

    /// Build the complete derived GHOST cache from identity-aware coverage.
    /// This is used on recovery and whenever a topology change splits a linear
    /// segment. Ordinary work updates use the incremental path above.
    nonisolated private static func buildSegmentBaseWeights(
        index: SegmentIndex,
        workByGrind: inout [String: WorkContributionRecord]
    ) -> [String: WorkSum] {
        var weights: [String: WorkSum] = [:]
        for base in Set(index.baseByBlock.values) {
            weights[base] = .zero
        }
        for id in workByGrind.keys {
            guard var record = workByGrind[id] else { continue }
            let bases = record.blockHashes.reduce(into: Set<String>()) {
                $0.formUnion(index.bases(covering: $1))
            }
            record.coveredSegmentBases = bases
            workByGrind[id] = record
            for base in bases where weights[base] != nil {
                weights[base] = weights[base]! + record.contribution.work
            }
        }
        return weights
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
        let start = hashToBlock[startingBlock.blockHash] ?? startingBlock
        if let descent = Self.segmentGhostDescent(
            from: start.blockHash,
            in: hashToBlock,
            index: segmentIndex,
            weights: segmentBaseWeights
        ) {
            let baseWeight = segmentBaseWeights[start.blockHash]
                ?? effectiveSubtreeWork(for: start.blockHash)
            return (baseWeight, descent.tipHash, descent.blocks)
        }
        let inherited = retainedInheritedWork()
        let direct = Self.referenceGhostDescent(
            from: start.blockHash,
            in: hashToBlock,
            inherited: inherited
        )
        return (
            effectiveSubtreeWork(for: start.blockHash),
            direct.tipHash,
            direct.blocks
        )
    }

    private func effectiveSubtreeWork(for blockHash: String) -> WorkSum {
        let inherited = retainedInheritedWork()
        let measure = Self.effectiveSubtreeMeasures(
            startingAt: [blockHash],
            retaining: [blockHash],
            in: hashToBlock,
            inherited: inherited,
            strongestWork: Self.strongestWorkByGrind(in: hashToBlock, inherited: inherited)
        )
        return measure[blockHash]?.total ?? .zero
    }

    /// Select GHOST by jumping from a segment base to its tail. This is the
    /// cheap steady-state projection: no unary block path is materialized.
    nonisolated private static func segmentGhostSpine(
        from startHash: String,
        in blocksByHash: [String: BlockMeta],
        index: SegmentIndex,
        weights: [String: WorkSum]
    ) -> [CanonicalSegment]? {
        var currentHash = startHash
        var spine: [CanonicalSegment] = []
        var visitedBases = Set<String>()
        while true {
            guard let base = index.baseByBlock[currentHash],
                  visitedBases.insert(base).inserted,
                  let tail = index.tailByBase[base]
            else { return nil }
            spine.append(CanonicalSegment(base: base, tail: tail))

            let children = blocksByHash[tail]?.childHashes ?? []
            guard !children.isEmpty else {
                return spine
            }
            guard children.count > 1,
                  let next = preferred(among: children, weights: weights)
            else { return nil }
            currentHash = next
        }
    }

    /// Select by quotient segment bases and materialize only the chosen path.
    /// A malformed route returns nil so the actor can take its slow independent
    /// fallback without materializing inherited facts on the steady-state path.
    nonisolated private static func segmentGhostDescent(
        from startHash: String,
        in blocksByHash: [String: BlockMeta],
        index: SegmentIndex,
        weights: [String: WorkSum],
        spine suppliedSpine: [CanonicalSegment]? = nil
    ) -> (tipHash: String, blocks: Set<String>, spine: [CanonicalSegment])? {
        guard let spine = suppliedSpine ?? segmentGhostSpine(
            from: startHash,
            in: blocksByHash,
            index: index,
            weights: weights
        ) else { return nil }

        var selectedBlocks = Set<String>()
        var segmentStart = startHash
        for (offset, segment) in spine.enumerated() {
            var segmentHash = segmentStart
            while true {
                guard selectedBlocks.insert(segmentHash).inserted else {
                    return nil
                }
                if segmentHash == segment.tail { break }
                guard let children = blocksByHash[segmentHash]?.childHashes,
                      children.count == 1 else {
                    return nil
                }
                segmentHash = children[0]
            }
            if offset + 1 < spine.count {
                let nextBase = spine[offset + 1].base
                guard blocksByHash[segment.tail]?.childHashes.contains(nextBase) == true else {
                    return nil
                }
                segmentStart = nextBase
            }
        }
        return (spine.last!.tail, selectedBlocks, spine)
    }

    /// Slow direct GHOST walk kept separate from the quotient implementation
    /// so differential tests can detect a routing-cache bug.
    nonisolated private static func referenceGhostDescent(
        from startHash: String,
        in blocksByHash: [String: BlockMeta],
        weights: [String: WorkSum]
    ) -> (tipHash: String, blocks: Set<String>) {
        var currentHash = startHash
        var blocks: Set<String> = [currentHash]
        while let children = blocksByHash[currentHash]?.childHashes, !children.isEmpty {
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
        inherited: InheritedWorkSnapshot
    ) -> (tipHash: String, blocks: Set<String>) {
        let measures = effectiveSubtreeMeasures(
            startingAt: [startHash],
            retaining: Set(blocksByHash.keys),
            in: blocksByHash,
            inherited: inherited,
            strongestWork: strongestWorkByGrind(in: blocksByHash, inherited: inherited)
        )
        return referenceGhostDescent(
            from: startHash,
            in: blocksByHash,
            weights: measures.mapValues(\.total)
        )
    }

    nonisolated static func canonicalProjection(
        in blocksByHash: [String: BlockMeta],
        inherited: InheritedWorkSnapshot
    ) -> (chainTip: String, mainChainHashes: Set<String>)? {
        var workByGrind = workIndex(
            in: blocksByHash,
            inherited: inherited
        )
        let index = makeSegmentIndex(in: blocksByHash)
        let weights = buildSegmentBaseWeights(
            index: index,
            workByGrind: &workByGrind
        )
        return canonicalProjection(
            in: blocksByHash,
            index: index,
            weights: weights,
            inherited: inherited
        )
    }

    /// Slow, exact per-block reference used only by differential tests. The
    /// normal restore validator intentionally uses the compact cache builder.
    nonisolated static func referenceCanonicalProjection(
        in blocksByHash: [String: BlockMeta],
        inherited: InheritedWorkSnapshot
    ) -> (chainTip: String, mainChainHashes: Set<String>)? {
        let roots = blocksByHash.values
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
        let measures = effectiveSubtreeMeasures(
            startingAt: roots,
            retaining: Set(blocksByHash.keys),
            in: blocksByHash,
            inherited: inherited,
            strongestWork: strongestWorkByGrind(in: blocksByHash, inherited: inherited)
        )
        return referenceCanonicalProjection(
            in: blocksByHash,
            weights: measures.mapValues(\.total)
        )
    }

    nonisolated private static func canonicalProjection(
        in blocksByHash: [String: BlockMeta],
        index: SegmentIndex,
        weights: [String: WorkSum],
        inherited: InheritedWorkSnapshot
    ) -> (chainTip: String, mainChainHashes: Set<String>)? {
        let roots = blocksByHash.values
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
        guard let root = preferred(among: roots, weights: weights) else { return nil }
        let descent = segmentGhostDescent(
            from: root,
            in: blocksByHash,
            index: index,
            weights: weights
        )
        if let descent {
            return (descent.tipHash, descent.blocks)
        }
        let direct = referenceGhostDescent(
            from: root,
            in: blocksByHash,
            inherited: inherited
        )
        return (direct.tipHash, direct.blocks)
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

    private func canAppendCanonicalTip(
        _ blockHash: String,
        parentHash: String?,
        oldTip: String
    ) -> Bool {
        guard parentHash == oldTip,
              mainChainHashes.contains(oldTip),
              let block = hashToBlock[blockHash],
              block.childHashes.isEmpty,
              let parent = hashToBlock[oldTip],
              mainChainBlockAtIndex[parent.blockHeight] == oldTip,
              parent.childHashes.count == 1,
              parent.childHashes[0] == blockHash,
              let base = segmentIndex.baseByBlock[oldTip],
              segmentIndex.baseByBlock[blockHash] == base,
              segmentIndex.tailByBase[base] == blockHash,
              canonicalSegmentSpine.last == CanonicalSegment(base: base, tail: oldTip)
        else { return false }

        return true
    }

    private func appendCanonicalTip(_ blockHash: String) -> ChainCommit {
        let block = hashToBlock[blockHash]!
        chainTip = blockHash
        mainChainHashes.insert(blockHash)
        mainChainBlockAtIndex[block.blockHeight] = blockHash
        canonicalSegmentSpine[canonicalSegmentSpine.count - 1].tail = blockHash
        tipSnapshot = tipSnapshotsByHash[blockHash]
        return ChainCommit(
            tipHash: blockHash,
            mainChainBlocksAdded: [blockHash: block.blockHeight]
        )
    }

    private func projectCanonicalChain(forceFull: Bool = false) -> ChainCommit? {
        let roots = Array(indexToBlockHash[0] ?? []).filter {
            hashToBlock[$0]?.parentBlockHash == nil
        }
        guard let root = Self.preferred(among: roots, weights: segmentBaseWeights)
        else { return nil }
        let spine = Self.segmentGhostSpine(
            from: root,
            in: hashToBlock,
            index: segmentIndex,
            weights: segmentBaseWeights
        )
        if !forceFull,
           let spine,
           spine == canonicalSegmentSpine {
            return nil
        }

#if DEBUG
        fullCanonicalProjectionCount += 1
#endif
        let descent = Self.segmentGhostDescent(
            from: root,
            in: hashToBlock,
            index: segmentIndex,
            weights: segmentBaseWeights,
            spine: spine
        ) ?? {
            let direct = Self.referenceGhostDescent(
                from: root,
                in: hashToBlock,
                inherited: retainedInheritedWork()
            )
            return (direct.tipHash, direct.blocks, [])
        }()
        let projection = (
            chainTip: descent.tipHash,
            mainChainHashes: descent.blocks
        )
        let newHashes = projection.mainChainHashes
        let newTip = projection.chainTip
        canonicalSegmentSpine = descent.spine
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
