import cashew
import UInt256

/// Compute proof-of-work for a given target threshold.
/// Higher target value = easier proof; work is inversely proportional.
public func workForTarget(_ target: UInt256) -> UInt256 {
    guard target > UInt256.zero else { return UInt256.zero }
    return UInt256.max / target
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

public let RECENT_BLOCK_DISTANCE: UInt64 = UInt64.max
public typealias BlockHeader = VolumeImpl<Block>

// MARK: - Concrete Types

public struct BlockInfoImpl: Sendable {
    public let blockHash: String
    public let parentBlockHash: String?
    public let blockHeight: UInt64
    public let work: UInt256
}

public struct BlockMeta: Sendable {
    public let blockInfo: BlockInfoImpl
    public var parentChainBlocks: [String: UInt64?]
    public var childHashes: [String]
    public private(set) var cachedParentIndex: UInt64?

    /// Backward cumulative proof-of-work prefix sum: the total work of this
    /// block's own chain from genesis up to and including this block,
    /// `cumulativeWork(B) = cumulativeWork(B.parent) + work(B)`.
    ///
    /// Stored (not recomputed) so it remains exact after retention pruning
    /// discards ancestors, and survives a persistence round-trip. The windowed
    /// `getCumulativeWork(limit:)` underestimates once ancestors are pruned;
    /// this prefix sum is the genesis-relative truth.
    ///
    /// Mutable only so a block inserted before its own-chain parent (out-of-order
    /// delivery) can be repaired once the parent — and thus its true prefix —
    /// becomes known; see `ChainState.propagateCumulativeWork(from:)`.
    public private(set) var cumulativeWork: UInt256

    /// F5-4 (Hierarchical GHOST): the **forward** same-chain subtree weight —
    /// `subtreeWeight(B) = work(B) + Σ_{c ∈ children(B)} subtreeWeight(c)`, the
    /// total work of `B`'s descendant subtree on this chain, counting each block
    /// once (docs/consensus-fork-choice.md §3, §6). This is the GHOST quantity
    /// the fork-choice weight is built from — the *descendant* dual of the
    /// *ancestor* `cumulativeWork` prefix sum. Forks do not enter its definition:
    /// a block either descends from `B` or not. Maintained bottom-up and repaired
    /// up the ancestor chain on insert (`propagateSubtreeWeight(from:)`), so it is
    /// correct under out-of-order delivery. Robust to retention pruning, which
    /// only discards ancestors (never a remaining block's descendants).
    ///
    /// `subtreeWeight` is the block's **own chain** weight only. The fork-choice
    /// quantity `trueCumWork = subtreeWeight + inherited(P)` adds the securing
    /// parent's weight, but that inherited term is **not stored here** — it is
    /// *derived, not cached* (docs/consensus-fork-choice.md §6.1): `ChainState` asks a
    /// provider for it fresh at fork-choice time (`effectiveWeight`). Keeping it
    /// off the block avoids the staleness/refresh burden of caching a value that
    /// grows whenever the parent chain extends.
    public private(set) var subtreeWeight: UInt256

    public var blockHeight: UInt64 { blockInfo.blockHeight }
    public var parentBlockHash: String? { blockInfo.parentBlockHash }
    public var blockHash: String { blockInfo.blockHash }
    public var work: UInt256 { blockInfo.work }

    public var parentIndex: UInt64? { cachedParentIndex }

    public init(
        blockInfo: BlockInfoImpl,
        parentChainBlocks: [String: UInt64?],
        childHashes: [String],
        cumulativeWork: UInt256 = .zero,
        subtreeWeight: UInt256? = nil
    ) {
        self.blockInfo = blockInfo
        self.parentChainBlocks = parentChainBlocks
        self.childHashes = childHashes
        self.cachedParentIndex = parentChainBlocks.values.compactMap { $0 }.min()
        self.cumulativeWork = cumulativeWork
        // A freshly-inserted leaf's subtree is just itself; the bottom-up repair
        // (`propagateSubtreeWeight`) folds in any out-of-order children. Default to
        // own work so a block always weighs at least itself.
        self.subtreeWeight = subtreeWeight ?? blockInfo.work
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

    public mutating func setParentChainBlock(_ hash: String, index: UInt64?) {
        parentChainBlocks[hash] = index
        recomputeParentIndex()
    }

    public mutating func removeParentChainBlock(_ hash: String) {
        parentChainBlocks.removeValue(forKey: hash)
        recomputeParentIndex()
    }

    private mutating func recomputeParentIndex() {
        cachedParentIndex = parentChainBlocks.values.compactMap { $0 }.min()
    }
}

/// (SOTA most-work fork choice, Bitcoin Core `-prune` model): the
/// fork-choice-relevant projection of a block — its weight (`cumulativeWork` /
/// `subtreeWeight` / own `work`) and DAG linkage (`parentBlockHash` /
/// `childHashes` / `blockHeight`) — retained in an index that **survives block-
/// body pruning** (analogous to `CBlockIndex`/`nChainWork`, which Bitcoin Core
/// keeps even when `-prune` deletes the block body/undo files).
///
/// The fix this closes / CFC-A1 liveness half): `pruneBlocksAtIndex`
/// evicts a block's `BlockMeta` from the prunable `hashToBlock` store, which
/// previously also lost its weight + linkage — holing the fork-choice index so a
/// heavier subtree behind a pruned interior could no longer be *computed* (CFC-A1
/// could only fail-safe and hold). Retaining this entry on prune lets GHOST
/// descent traverse and weigh a branch whose interior bodies are gone, so the
/// node positively identifies the heaviest subtree from the index — not from body
/// presence. This is a pure projection of `BlockMeta`; it introduces NO new work
/// metric and never double-counts (the index is consulted only when the body is
/// absent).
struct BlockWeightIndexEntry: Sendable {
    let parentBlockHash: String?
    let blockHeight: UInt64
    let work: UInt256
    var cumulativeWork: UInt256
    var subtreeWeight: UInt256
    var childHashes: [String]

    init(from meta: BlockMeta) {
        self.parentBlockHash = meta.parentBlockHash
        self.blockHeight = meta.blockHeight
        self.work = meta.work
        self.cumulativeWork = meta.cumulativeWork
        self.subtreeWeight = meta.subtreeWeight
        self.childHashes = meta.childHashes
    }

    ///: reconstruct a retained entry for a body-pruned block from its
    /// persisted projection (`PersistedBlockMeta` carrying `cumulativeWork` and
    /// `subtreeWeight`), so the fork-choice weight index survives a restart.
    init(parentBlockHash: String?, blockHeight: UInt64, work: UInt256, cumulativeWork: UInt256, subtreeWeight: UInt256, childHashes: [String]) {
        self.parentBlockHash = parentBlockHash
        self.blockHeight = blockHeight
        self.work = work
        self.cumulativeWork = cumulativeWork
        self.subtreeWeight = subtreeWeight
        self.childHashes = childHashes
    }
}

///: reconstruct the retained weight-index entries of body-pruned blocks
/// from their persisted projection. Each carries the durable `cumulativeWork` and
/// `subtreeWeight` the live tree can no longer recompute (its descendants may also
/// be pruned), so the restored fork-choice weight index still weighs a branch whose
/// interior bodies are gone. Shared by `ChainState.init` and `resetFrom`.
///
/// Fail-closed at the choke point: a retained pruned entry's `cumulativeWork` and
/// `subtreeWeight` are non-recomputable and ALWAYS persisted, so a missing or
/// undecodable value is corruption, not a legitimate absence. Rather than mapping it
/// to `.zero` (which silently underweights a branch — the hole), this
/// helper itself THROWS `ChainStateRestoreError.corruptWeightIndex` so NO construction
/// path (restore, resetFrom, or a direct `ChainState.init`) can reach a zeroed required
/// weight. The upstream `hasUndecodableTarget()` guard remains as an early reject, but
/// this is the authoritative fail-closed point.
///
/// `invalid ≠ unavailable`: a legitimately-absent (`nil`) `target` / `workHex` is still
/// recomputed (`work` falls back to the target-derived value, or zero for a nil target);
/// only a present-but-undecodable `target` / `workHex`, or a missing/undecodable REQUIRED
/// weight, fails closed.
func weightIndexEntries(fromPruned pruned: [PersistedBlockMeta]) throws -> [String: BlockWeightIndexEntry] {
    var result: [String: BlockWeightIndexEntry] = [:]
    for block in pruned {
        // Required, non-recomputable weights: missing OR undecodable is corruption.
        guard let cumHex = block.cumulativeWork, let cumulativeWork = UInt256(cumHex, radix: 16) else {
            throw ChainStateRestoreError.corruptWeightIndex
        }
        guard let subHex = block.subtreeWeight, let subtreeWeight = UInt256(subHex, radix: 16) else {
            throw ChainStateRestoreError.corruptWeightIndex
        }
        // Absence-tolerant: a nil target/workHex is recomputed, but a present-but-
        // undecodable value is corruption (it cannot be recovered, only fabricated).
        let target: UInt256
        if let targetHex = block.target {
            guard let decoded = UInt256(targetHex, radix: 16) else {
                throw ChainStateRestoreError.corruptWeightIndex
            }
            target = decoded
        } else {
            target = .zero
        }
        let work: UInt256
        if let workHex = block.workHex {
            guard let decoded = UInt256(workHex, radix: 16) else {
                throw ChainStateRestoreError.corruptWeightIndex
            }
            work = decoded
        } else {
            //: fall back to the lossy target-derived work for pre-upgrade
            // entries that omit `workHex`.
            work = workForTarget(target)
        }
        result[block.blockHash] = BlockWeightIndexEntry(
            parentBlockHash: block.parentBlockHash,
            blockHeight: block.blockHeight,
            work: work,
            cumulativeWork: cumulativeWork,
            subtreeWeight: subtreeWeight,
            childHashes: block.childHashes
        )
    }
    return result
}

public struct SubmissionResult: Sendable {
    public let addedBlock: Bool
    public let extendsMainChain: Bool
    public let needsChildBlock: Bool
    public let reorganization: Reorganization?

    public static func extendsMainChain() -> Self {
        SubmissionResult(addedBlock: true, extendsMainChain: true, needsChildBlock: false, reorganization: nil)
    }

    public static func discarded() -> Self {
        SubmissionResult(addedBlock: false, extendsMainChain: false, needsChildBlock: false, reorganization: nil)
    }
}

public struct Reorganization: Sendable {
    public let mainChainBlocksAdded: [String: UInt64]
    public let mainChainBlocksRemoved: Set<String>

    /// Public initializer for per-process Phase 3: when a parent chain reorg is
    /// detected externally (via ParentChainBlockExtractor tracking parent chain view),
    /// construct the reorg descriptor to propagate to child chain state.
    public init(mainChainBlocksAdded: [String: UInt64] = [:], mainChainBlocksRemoved: Set<String>) {
        self.mainChainBlocksAdded = mainChainBlocksAdded
        self.mainChainBlocksRemoved = mainChainBlocksRemoved
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
    public let trueCumWork: UInt256
    public let tipHash: String
    public let mainChainPath: Set<String>

    public init(startingHash: String, trueCumWork: UInt256, tipHash: String, mainChainPath: Set<String>) {
        self.startingHash = startingHash
        self.trueCumWork = trueCumWork
        self.tipHash = tipHash
        self.mainChainPath = mainChainPath
    }
}

public actor ChainState {
    var chainTip: String
    var mainChainHashes: Set<String>
    var indexToBlockHash: [UInt64: Set<String>]
    var hashToBlock: [String: BlockMeta]

    ///: the pruning-durable fork-choice weight/linkage index (see
    /// `BlockWeightIndexEntry`). When `pruneBlocksAtIndex` evicts a block body from
    /// `hashToBlock`, its weight + linkage is retained here so GHOST descent and the
    /// work comparisons can still traverse and weigh a branch whose interior bodies
    /// are gone. Consulted only as a fallback for blocks absent from `hashToBlock`,
    /// so present blocks (and their maintained weights) are unaffected and nothing
    /// is double-counted. Built/restored alongside `hashToBlock` and never holed by
    /// pruning.
    var weightIndex: [String: BlockWeightIndexEntry]

    var parentChainBlockHashToBlockHash: [String: String]
    var mainChainBlockAtIndex: [UInt64: String]
    var blockTimestamps: [String: Int64]
    var missingBlockHashes: Set<String>

    /// F5-4 (Hierarchical GHOST): the inherited cross-chain weight provider plus
    /// its per-decision memo, behind one narrow API (`effectiveWeight`/`clearMemo`).
    /// See `InheritedWeightProvider`.
    var inheritedWeight: InheritedWeightProvider

    /// This node's retention-depth policy and the prune arithmetic that depends on
    /// it. See `RetentionFinalityPolicy`.
    var policy: RetentionFinalityPolicy
    public private(set) var tipSnapshot: TipBlockSnapshot?

    // (3): never force-unwrap the tip. A state where `chainTip ∉ hashToBlock`
    // (a detached-fallback fork tip, or a future prune-ordering change) must not trap
    // the whole actor on every query that reaches the tip. `highestBlock` is optional;
    // `highestBlockHeight` fails closed to `0` (the lowest height, so retention-window
    // guards stay conservative) when the tip body is absent.
    var highestBlock: BlockMeta? { hashToBlock[chainTip] }
    var highestBlockHeight: UInt64 { highestBlock?.blockHeight ?? 0 }

    var retentionDepth: UInt64 { policy.retentionDepth }

    public func getRetentionDepth() -> UInt64 { policy.retentionDepth }

    public init(
        chainTip: String,
        mainChainHashes: Set<String>,
        indexToBlockHash: [UInt64: Set<String>],
        hashToBlock: [String: BlockMeta],
        parentChainBlockHashToBlockHash: [String: String],
        retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE,
        blockTimestamps: [String: Int64] = [:],
        tipSnapshot: TipBlockSnapshot? = nil,
        prunedWeightIndex: [PersistedBlockMeta] = [],
        inheritedWeightProvider: (@Sendable (String) -> UInt256)? = nil
    ) throws {
        self.chainTip = chainTip
        self.mainChainHashes = mainChainHashes
        self.indexToBlockHash = indexToBlockHash
        self.hashToBlock = hashToBlock
        self.weightIndex = [:]
        self.parentChainBlockHashToBlockHash = parentChainBlockHashToBlockHash
        self.policy = RetentionFinalityPolicy(retentionDepth: retentionDepth)
        self.tipSnapshot = tipSnapshot
        self.missingBlockHashes = Set()
        self.blockTimestamps = blockTimestamps
        self.inheritedWeight = InheritedWeightProvider(provider: inheritedWeightProvider)
        var blockAtIndex: [UInt64: String] = [:]
        for hash in mainChainHashes {
            if let block = hashToBlock[hash] {
                blockAtIndex[block.blockHeight] = hash
            }
        }
        self.mainChainBlockAtIndex = blockAtIndex
        //: seed the retained entries of already-body-pruned blocks FIRST, so
        // the subtree-weight recompute below can fold a pruned descendant tail in via
        // the index (a present block whose child was pruned would otherwise be
        // understated). Carried across the restart via persistence.
        //: fail closed if a pruned entry's required weight is missing/undecodable
        // (the choke point throws) — a direct `ChainState.init` cannot silently zero them.
        let prunedEntries = try weightIndexEntries(fromPruned: prunedWeightIndex)
        self.weightIndex = prunedEntries
        // F5-4: rebuild forward subtree weights from the installed tree (the
        // per-block default is own-work only; fold in descendants bottom-up).
        // (7): the bottom-up rebuild lives in ONE `nonisolated static` helper shared
        // with `recomputeAllSubtreeWeights` (an actor's nonisolated init cannot call
        // the isolated method, but it can call the static), so the two paths cannot
        // drift. A pruned child contributes its retained subtree weight from the
        // seeded pruned entries.
        Self.recomputeSubtreeWeights(in: &self.hashToBlock, prunedIndex: prunedEntries)
        //: write the freshly-installed live tree through on top of the pruned
        // entries (subtree weights are now final), leaving the pruned entries intact.
        for meta in self.hashToBlock.values {
            self.weightIndex[meta.blockHash] = BlockWeightIndexEntry(from: meta)
        }
    }

    public func resetFrom(_ persisted: PersistedChainState, retentionDepth: UInt64? = nil) throws {
        // / CFC-A3 (fail closed before mutating the live chain): reject a
        // corrupt snapshot — a present-but-undecodable target, or a pruned-entry
        // `cumulativeWork` / `subtreeWeight` that is missing/undecodable — so we
        // never overwrite the running tip with a silently zeroed-weight projection
        // (the no-downgrade obligation, CFC-A1). The live state is left intact.
        guard !persisted.hasUndecodableTarget() else {
            throw ChainStateRestoreError.corruptWeightIndex
        }
        var newHashToBlock: [String: BlockMeta] = [:]
        var newIndexToBlockHash: [UInt64: Set<String>] = [:]
        var newTimestamps: [String: Int64] = [:]
        let cumByHash = persisted.cumulativeWorkByHash()
        for block in persisted.blocks {
            let target = block.target.flatMap { UInt256($0, radix: 16) } ?? UInt256.zero
            //: recover the block's own work from the directly-persisted
            // `workHex` (byte-identical to the live value) rather than re-deriving it
            // from `target` via a lossy floor-division round-trip, so the rebuilt
            // subtree/effective weight does not depend on restart history. A `nil`
            // `workHex` is a pre-upgrade snapshot that falls back to the target-derived
            // work; a present-but-undecodable value was already rejected by the
            // `hasUndecodableTarget()` guard above (fail closed).
            let work = block.workHex.flatMap { UInt256($0, radix: 16) } ?? workForTarget(target)
            let meta = BlockMeta(
                blockInfo: BlockInfoImpl(
                    blockHash: block.blockHash,
                    parentBlockHash: block.parentBlockHash,
                    blockHeight: block.blockHeight,
                    work: work
                ),
                parentChainBlocks: block.parentChainBlocks,
                childHashes: block.childHashes,
                cumulativeWork: cumByHash[block.blockHash] ?? .zero
            )
            newHashToBlock[block.blockHash] = meta
            newIndexToBlockHash[block.blockHeight, default: Set()].insert(block.blockHash)
            if let ts = block.timestamp {
                newTimestamps[block.blockHash] = ts
            }
        }
        self.chainTip = persisted.chainTip
        self.mainChainHashes = Set(persisted.mainChainHashes)
        self.indexToBlockHash = newIndexToBlockHash
        self.hashToBlock = newHashToBlock
        self.parentChainBlockHashToBlockHash = persisted.parentChainMap
        self.policy.retentionDepth = retentionDepth ?? self.policy.retentionDepth
        self.missingBlockHashes = Set(persisted.missingBlockHashes)
        self.blockTimestamps = newTimestamps
        var blockAtIndex: [UInt64: String] = [:]
        for hash in self.mainChainHashes {
            if let block = self.hashToBlock[hash] {
                blockAtIndex[block.blockHeight] = hash
            }
        }
        // Rebuild the header/timestamp index for body-pruned main-chain ancestors,
        // so median-time-past + difficulty-retarget validation keeps working after a
        // restart even when the retarget window reaches past `retentionDepth` (the
        // live `pruneBlocksAtIndex` retains this index; restore must too). Walk the
        // parent spine from the tip: live blocks resolve through `hashToBlock`,
        // pruned ones through the persisted `prunedWeightIndex` (which now carries
        // each block's height, parent, and timestamp). Only the unique parent chain
        // is followed, so orphan pruned entries are never mistaken for main chain.
        var prunedSpine: [String: (parent: String?, height: UInt64, timestamp: Int64?)] = [:]
        for block in persisted.prunedWeightIndex {
            prunedSpine[block.blockHash] = (block.parentBlockHash, block.blockHeight, block.timestamp)
        }
        var cursor: String? = persisted.chainTip
        var guardCounter = 0
        let spineLimit = hashToBlock.count + prunedSpine.count + 1
        while let hash = cursor, guardCounter < spineLimit {
            guardCounter += 1
            if let meta = self.hashToBlock[hash] {
                blockAtIndex[meta.blockHeight] = hash
                cursor = meta.parentBlockHash
            } else if let pruned = prunedSpine[hash] {
                blockAtIndex[pruned.height] = hash
                if let ts = pruned.timestamp { self.blockTimestamps[hash] = ts }
                cursor = pruned.parent
            } else {
                break
            }
            if cursor?.isEmpty == true { break }
        }
        self.mainChainBlockAtIndex = blockAtIndex
        self.tipSnapshot = nil
        //: seed the retained entries of already-body-pruned blocks FIRST, so
        // the subtree-weight recompute below can fold a pruned descendant tail in via
        // the index (a present block whose child was pruned would otherwise be
        // understated). Carried across the restart via persistence.
        self.weightIndex = try weightIndexEntries(fromPruned: persisted.prunedWeightIndex)
        // F5-4: rebuild forward subtree weights from the freshly-installed tree.
        recomputeAllSubtreeWeights()
        //: write the freshly-installed live tree through on top of the pruned
        // entries (subtree weights are now final), leaving the pruned entries intact.
        for meta in hashToBlock.values {
            weightIndex[meta.blockHash] = BlockWeightIndexEntry(from: meta)
        }
    }

    public static func fromGenesis(block: Block, retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE) -> ChainState {
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        let blockHeader = try! BlockHeader(node: block)
        let blockHash = blockHeader.rawCID
        let meta = BlockMeta(
            blockInfo: BlockInfoImpl(
                blockHash: blockHash,
                parentBlockHash: nil,
                blockHeight: 0,
                work: workForTarget(block.target)
            ),
            parentChainBlocks: [:],
            childHashes: [],
            // Genesis has no parent: its cumulative work is its own work.
            cumulativeWork: workForTarget(block.target)
        )
        // Genesis carries no pruned weight index, so the throwing init cannot fail here.
        return try! ChainState(
            chainTip: blockHash,
            mainChainHashes: Set([blockHash]),
            indexToBlockHash: [0: Set([blockHash])],
            hashToBlock: [blockHash: meta],
            parentChainBlockHashToBlockHash: [:],
            retentionDepth: retentionDepth,
            blockTimestamps: [blockHash: block.timestamp],
            tipSnapshot: TipBlockSnapshot(
                postStateCID: block.postState.rawCID,
                prevStateCID: block.prevState.rawCID,
                specCID: block.spec.rawCID,
                target: block.target,
                nextTarget: block.nextTarget,
                tipHeight: block.height,
                timestamp: block.timestamp
            )
        )
    }

    // MARK: - Queries

    public func contains(blockHash: String) -> Bool {
        hashToBlock.keys.contains(blockHash)
    }

    public func getMainChainTip() -> String {
        chainTip
    }

    /// Test seam: drive the actor into a state where `chainTip` is absent from the
    /// body store, to verify `highestBlock` no longer traps (3)).
    func setChainTip(_ hash: String) {
        chainTip = hash
    }

    public func isOnMainChain(hash: String) -> Bool {
        guard let block = hashToBlock[hash] else { return false }
        return mainChainBlockAtIndex[block.blockHeight] == hash
    }

    /// Sum cumulative PoW for up to `limit` blocks from the current chain tip,
    /// entirely within the actor. Replaces the previous O(limit) sequential
    /// `await chainState.getConsensusBlock()` loop in `localCumulativeWork`,
    /// reducing retentionDepth actor-hop round-trips to 1.
    public func getCumulativeWork(limit: UInt64) -> UInt256 {
        var total = UInt256.zero
        var current: String? = chainTip
        var walked: UInt64 = 0
        while let hash = current, walked <= limit {
            guard let meta = hashToBlock[hash] else { break }
            // CFC-A2: saturating add — a bare `&+` here could wrap modulo 2^256
            // and report a *lower* windowed work than a competing fork, inverting
            // the fork-choice comparison. Reuse the same clamp as the prefix sum.
            total = saturatingWorkSum(total, meta.work)
            current = meta.parentBlockHash
            walked += 1
        }
        return total
    }

    /// Exact total proof-of-work from genesis to the current chain tip, read
    /// from the stored prefix sum. Unlike `getCumulativeWork(limit:)`, this does
    /// not underestimate once retention has pruned ancestors, because each
    /// block's `cumulativeWork` was accumulated when its ancestors were present
    /// and persists across restarts.
    public func getTipCumulativeWork() -> UInt256 {
        highestBlock?.cumulativeWork ?? .zero
    }

    /// Exact genesis-relative cumulative work at a specific block, or nil if the
    /// block is unknown.
    public func getCumulativeWork(forHash hash: String) -> UInt256? {
        //: fall back to the pruning-durable index so a body-pruned block's
        // durable genesis-relative cumulative work remains queryable.
        indexedCumulativeWork(hash)
    }

    /// F5-4 (Hierarchical GHOST): the forward same-chain subtree weight of `hash`
    /// — the total work of its descendant subtree on this chain, counting each
    /// block once (design §3/§6). This is the GHOST quantity the fork-choice weight
    /// is built from; for a tip it equals the block's own work, for an interior
    /// block the sum of itself and everything that builds on it across all forks.
    public func subtreeWeight(forHash hash: String) -> UInt256? {
        //: fall back to the pruning-durable index so a body-pruned block's
        // retained subtree weight is still queryable (it survives the body prune).
        indexedSubtreeWeight(hash)
    }

    ///: the heaviest-`trueCumWork` descent from `fromHash` computed purely
    /// from the pruning-durable weight/linkage index — the leaf the node identifies
    /// as the tip of the heaviest subtree below `fromHash`, plus that leaf's durable
    /// genesis-relative cumulative work, *even when the branch's bodies are pruned*.
    /// This is the SOTA "node always knows the heaviest branch's weight" deliverable
    /// (Bitcoin Core's `pindexBestHeader`): the answer is independent of which bodies
    /// are local. Returns `nil` if `fromHash` is unknown to both stores.
    /// Resolve a block's meta from the live body store, or — when the body is pruned —
    /// synthesize a minimal meta from the pruning-durable weight index, so
    /// index-aware descents and the backfill trigger can start from a body-pruned base.
    /// Returns `nil` only when `hash` is unknown to BOTH stores.
    private func liveOrIndexedMeta(_ hash: String) -> BlockMeta? {
        if let meta = hashToBlock[hash] { return meta }
        guard let entry = weightIndex[hash] else { return nil }
        return BlockMeta(
            blockInfo: BlockInfoImpl(blockHash: hash, parentBlockHash: entry.parentBlockHash, blockHeight: entry.blockHeight, work: entry.work),
            parentChainBlocks: [:],
            childHashes: entry.childHashes,
            cumulativeWork: entry.cumulativeWork,
            subtreeWeight: entry.subtreeWeight
        )
    }

    /// Test-facing (via `@testable`): the index-computed heaviest leaf below `hash`
    /// and its durable cumulative work. Not part of the public API — production fork
    /// choice runs through `checkForReorg`/`heldHeavierBackfillTarget`.
    func heaviestDescent(fromHash hash: String) -> (tipHash: String, cumulativeWork: UInt256)? {
        clearInheritedWeightMemo()
        guard let start = liveOrIndexedMeta(hash) else { return nil }
        let descent = ghostDescent(from: start)
        guard let work = indexedCumulativeWork(descent.heaviestTipHash) else { return nil }
        return (descent.heaviestTipHash, work)
    }

    /// (body-backfill refetch trigger): when fork choice is HELD on a
    /// strictly-heavier subtree whose interior bodies are missing (CFC-A1 no-downgrade
    /// + retained weight index), report what the node must REFETCH to converge.
    ///
    /// Returns the index-known heaviest leaf (`tipHash`) and the interior body hashes
    /// on its path that are absent from the body store (`missingBodies`, ordered
    /// tip→base — the order a tip-anchored sync walk fetches them), but ONLY when:
    ///   - that leaf's branch is strictly heavier by the SAME fork-choice metric
    ///     GHOST/inherited-weight selection uses (`trueCumWork = subtreeWeight +
    ///     inherited`, compared as `forkWork > mainWork`) than the main
    ///     chain it diverges from — a genuine heavier branch, not a tie/lighter. A
    ///     branch made strictly heavier purely by inherited parent weight (even with
    ///     `<=` genesis-relative prefix work) therefore still triggers backfill, and
    ///   - the body-present prefix the node can actually install falls short of it
    ///     (i.e. there ARE missing interior bodies holding fork choice).
    ///
    /// This is the FETCH TRIGGER, computed entirely from the pruning-durable index —
    /// missing data signals "go refetch", never a fork-choice downgrade. Returns `nil`
    /// when the incumbent already is (or contains) the heaviest leaf, or when the
    /// heaviest leaf's full body-present path is already installable (no hold).
    public func heldHeavierBackfillTarget() -> (tipHash: String, missingBodies: [String])? {
        clearInheritedWeightMemo()
        // The index-known heaviest leaf across the whole tree, and the deepest
        // body-present prefix of its path, both via the real GHOST descent from
        // genesis (reusing the same fork-choice machinery, not a parallel metric).
        guard let genesisHash = mainChainBlockAtIndex[0],
              let genesisMeta = hashToBlock[genesisHash] else { return nil }
        let descent = ghostDescent(from: genesisMeta)
        let heaviestTip = descent.heaviestTipHash

        // Strictly heavier by the EFFECTIVE fork-choice weight (`trueCumWork`), not the
        // genesis-relative prefix sum: find the heaviest branch's fork base (its deepest
        // ancestor off the main chain) and run the SAME GHOST decision reorgs use —
        // `chainWithMostWork > mainChainWork` over `indexedEffectiveWeight`.
        // This fires for a branch made heavier by inherited parent weight even when its
        // prefix cumulative work only ties/loses; it never fires on a tie/lighter branch.
        guard let forkBaseHash = forkBaseOffMainChain(ofLeaf: heaviestTip),
              let forkBase = liveOrIndexedMeta(forkBaseHash) else { return nil }
        let forkWork = chainWithMostWork(startingBlock: forkBase)
        let mainWork = mainChainWork(fromIndex: forkBase.blockHeight)
        guard forkWork.cumulativeWork > mainWork.cumulativeWork else { return nil }

        // Walk the heaviest leaf's same-chain path to its deepest body-present
        // ancestor, collecting the interior hashes whose bodies are absent. The walk
        // rides the pruning-durable linkage (`previousHash`) so it can cross
        // body-pruned interiors the index still knows.
        var missing: [String] = []
        var cursor: String? = heaviestTip
        while let hash = cursor {
            if hashToBlock[hash] == nil {
                // A body we don't hold on the heaviest path — a refetch target.
                missing.append(hash)
            } else if hash != heaviestTip {
                // Reached the deepest body-present anchor; the prefix below is local.
                break
            }
            cursor = previousHash(of: hash)
        }

        // No missing bodies ⇒ the full heaviest path is already installable; this is
        // not a hold (fork choice will adopt it directly), so there is nothing to
        // backfill.
        guard !missing.isEmpty else { return nil }
        return (heaviestTip, missing)
    }

    /// The fork base of the branch ending at `leaf`: its deepest ancestor that is NOT
    /// on the current main chain (the sibling of the main-chain block at that height),
    /// found by riding the pruning-durable linkage up until the parent lands on the
    /// main chain. This is the block reorg evaluation starts `chainWithMostWork` from.
    /// Returns `nil` when `leaf` is already on the main chain (no divergence — the
    /// incumbent already contains it) or its linkage cannot be traced to the main chain.
    private func forkBaseOffMainChain(ofLeaf leaf: String) -> String? {
        guard let leafHeight = indexedBlockHeight(leaf),
              mainChainBlockAtIndex[leafHeight] != leaf else { return nil }
        var cursor = leaf
        while let parent = previousHash(of: cursor) {
            guard let parentHeight = indexedBlockHeight(parent) else { return nil }
            if mainChainBlockAtIndex[parentHeight] == parent {
                // `cursor`'s parent is on the main chain ⇒ `cursor` is the fork base.
                return cursor
            }
            cursor = parent
        }
        return nil
    }

    /// F5-4 (Hierarchical GHOST): install the inherited-weight provider — the node
    /// wires this to resolve a block's securing parent on the parent chain and
    /// return its current `trueCumWork(P)`. Asked fresh at fork-choice time; never
    /// cached on the block (§6.1), so it can't go stale as the parent chain extends.
    public func setInheritedWeightProvider(_ provider: (@Sendable (String) -> UInt256)?) {
        inheritedWeight.setProvider(provider)
    }

    /// The fork-choice weight of a block: `trueCumWork = subtreeWeight (own chain)
    /// + inherited parent weight`. The inherited term is fetched live from the
    /// provider (0 for the root chain / when no provider). This is the single
    /// metric GHOST compares — own-chain descendant subtree plus the security
    /// riding down the lattice.
    func effectiveWeight(_ meta: BlockMeta) -> UInt256 {
        inheritedWeight.effectiveWeight(subtreeWeight: meta.subtreeWeight, blockHash: meta.blockHash)
    }

    /// The authoritative fork-choice weight (`trueCumWork = subtreeWeight + inherited`)
    /// of a block by hash — the exact single metric GHOST compares — robust to body
    /// pruning (falls back to the durable weight index). `nil` if the block is unknown
    /// to both stores.
    ///
    /// Exposed for the trusted consensus provider: an ancestor serves this
    /// authoritative value down the spawn tree so a descendant READS its inherited
    /// term instead of re-deriving it (which would risk diverging from this metric).
    /// The per-decision memo is cleared first so the value is derived fresh from the
    /// current inherited-weight provider; the next real fork-choice decision re-clears
    /// it, so this read never perturbs a decision (ChainState is an actor — calls are
    /// serialized, no decision is in flight).
    public func effectiveWeight(forBlockHash hash: String) -> UInt256? {
        clearInheritedWeightMemo()
        return indexedEffectiveWeight(hash)
    }

    /// Hierarchical-GHOST faithful inherited weight that THIS (parent) chain
    /// serves for a child committed by `committerHashes` — the set of blocks on
    /// this chain whose `children[dir]` names that child (the many-to-one inverse;
    /// usually exactly one, occasionally several across this chain's forks). The
    /// value is the UNION of the committers' securing cones with every grinding
    /// block counted exactly ONCE (docs/consensus-fork-choice.md §3, §6.2):
    ///
    /// - 0 committers → `0`.
    /// - 1 committer (the norm) → exactly `trueCumWork(committer) =
    ///   effectiveWeight(forBlockHash: committer)`.
    /// - several committers → the union: each committer's FORWARD subtree own-work
    ///   counted once across all committers (nested re-commits collapse to the
    ///   earliest committer's subtree; disjoint forks sum), PLUS the cross-chain
    ///   inherited term counted once (the maximal committer's inherited, which
    ///   subsumes the shared parent-chain securing spine).
    ///
    /// It is deliberately NEITHER the sum of the committers' `trueCumWork`s (that
    /// double-counts the shared cone) NOR the max (that drops a disjoint fork — the
    /// longest-chain reduction, not GHOST). The parent serves this because only it
    /// has full fork visibility of its own blocks committing the child.
    public func unionInheritedWeight(committerHashes: Set<String>) -> UInt256 {
        clearInheritedWeightMemo()
        guard committerHashes.count > 1 else {
            return committerHashes.first.flatMap { indexedEffectiveWeight($0) } ?? .zero
        }
        // Forward-subtree own-work, unioned across all committers, each block once.
        // On a tree two committers' forward subtrees overlap iff one descends from
        // the other, so the CID-dedup collapses nested re-commits to the earliest
        // committer's subtree and sums disjoint sibling forks.
        var counted = Set<String>()
        var subtreeUnion = UInt256.zero
        for committer in committerHashes.sorted() {
            var stack = [committer]
            while let current = stack.popLast() {
                guard counted.insert(current).inserted,
                      let meta = liveOrIndexedMeta(current) else { continue }
                subtreeUnion = saturatingWorkSum(subtreeUnion, meta.work)
                stack.append(contentsOf: meta.childHashes)
            }
        }
        // The cross-chain inherited cone, counted once. The committers share this
        // chain's inherited spine, so the maximal committer inherited term subsumes
        // the others; `inherited(P) = effectiveWeight(P) − subtreeWeight(P)`.
        var inheritedOnce = UInt256.zero
        for committer in committerHashes {
            let eff = indexedEffectiveWeight(committer) ?? .zero
            let sub = indexedSubtreeWeight(committer) ?? .zero
            let inh = eff > sub ? eff &- sub : .zero
            if inh > inheritedOnce { inheritedOnce = inh }
        }
        return saturatingWorkSum(subtreeUnion, inheritedOnce)
    }

    /// Drop the per-decision inherited-weight memo. Called at the top of every
    /// top-level fork-choice entry so each decision re-derives fresh values.
    private func clearInheritedWeightMemo() { inheritedWeight.clearMemo() }

    /// Re-run fork choice after the node has updated inherited weights (e.g. the
    /// parent chain extended a fork some block rides). The provider now returns the
    /// fresh values, so a block whose `trueCumWork` now exceeds the main chain is
    /// promoted. Returns the resulting `Reorganization`, if any.
    @discardableResult
    public func reevaluateForkChoice(blockHash: String) -> Reorganization? {
        guard let meta = hashToBlock[blockHash] else { return nil }
        if mainChainBlockAtIndex[meta.blockHeight] == blockHash { return nil }
        return checkForReorg(block: meta)
    }

    /// Public simulator/test view of the real fork-choice descent from a fork
    /// candidate. This wraps `chainWithMostWork`, so callers observe the same
    /// `trueCumWork = subtreeWeight + inherited` decision path used by reorgs.
    public func forkChoiceSnapshot(startingAt hash: String) -> ForkChoiceSnapshot? {
        clearInheritedWeightMemo()
        guard let meta = hashToBlock[hash] else { return nil }
        let choice = chainWithMostWork(startingBlock: meta)
        return ForkChoiceSnapshot(
            startingHash: hash,
            trueCumWork: choice.cumulativeWork,
            tipHash: choice.tipHash,
            mainChainPath: choice.blocks
        )
    }

    /// Walk `limit` ancestors from `tip` entirely within the actor, returning
    /// the set of all ancestor hashes (including `tip` itself). Replaces the
    /// previous pattern of `limit` sequential `await chain.getConsensusBlock()`
    /// calls from outside the actor, which created `limit` actor-hop suspension
    /// points (up to 1000 for the default retentionDepth).
    public func getAncestorSet(from tip: String, limit: UInt64) -> Set<String> {
        var hashes = Set<String>()
        hashes.reserveCapacity(Int(min(limit, UInt64(hashToBlock.count))))
        var current = tip
        for _ in 0..<limit {
            hashes.insert(current)
            guard let meta = hashToBlock[current],
                  let prev = meta.parentBlockHash else { break }
            current = prev
        }
        return hashes
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

    public func getMissingBlockHashes() -> Set<String> {
        missingBlockHashes
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

    public func updateTipSnapshot(block: Block) {
        tipSnapshot = TipBlockSnapshot(
            postStateCID: block.postState.rawCID,
            prevStateCID: block.prevState.rawCID,
            specCID: block.spec.rawCID,
            target: block.target,
            nextTarget: block.nextTarget,
            tipHeight: block.height,
            timestamp: block.timestamp
        )
    }

    public func submitBlock(
        parentBlockHeaderAndIndex: (String, UInt64?)?,
        blockHeader: BlockHeader,
        block: Block
    ) -> SubmissionResult {
        let blockHash = blockHeader.rawCID
        let target = block.target

        let (indexPlusRetention, overflow1) = block.height.addingReportingOverflow(retentionDepth)
        if !overflow1 && indexPlusRetention < highestBlockHeight {
            return .discarded()
        }
        if parentBlockHeaderAndIndex == nil && block.parent == nil {
            return .discarded()
        }

        if hashToBlock[blockHash] != nil {
            return handleDuplicateBlock(
                parentBlockHeaderAndIndex: parentBlockHeaderAndIndex,
                blockHash: blockHash
            )
        }

        let result = insertBlock(
            parentBlockHeaderAndIndex: parentBlockHeaderAndIndex,
            blockHash: blockHash,
            block: block,
            target: target
        )
        if !result.addedBlock { return result }

        if let parentInfo = parentBlockHeaderAndIndex {
            addParentBlockReference(
                parentBlockHeader: parentInfo.0,
                parentIndex: parentInfo.1,
                blockHash: blockHash
            )
        }

        if result.extendsMainChain {
            updateTipSnapshot(block: block)
            // (1): forward the tip-extend connect set (if any) so out-of-order
            // descendants the GHOST re-descent pulled onto the main chain reach the
            // node's reorg consumers; `.extendsMainChain()` carries `nil` otherwise.
            return SubmissionResult(
                addedBlock: true,
                extendsMainChain: true,
                needsChildBlock: false,
                reorganization: result.reorganization
            )
        }
        if result.needsChildBlock { return result }

        let meta = hashToBlock[blockHash]!
        if let reorg = checkForReorg(block: meta) {
            updateTipSnapshot(block: block)
            return SubmissionResult(
                addedBlock: true,
                extendsMainChain: false,
                needsChildBlock: false,
                reorganization: reorg
            )
        }

        return result
    }

    // MARK: - Insert

    func insertBlock(
        parentBlockHeaderAndIndex: (String, UInt64?)?,
        blockHash: String,
        block: Block,
        target: UInt256
    ) -> SubmissionResult {
        addToBlockIndex(hash: blockHash, blockHeight: block.height)

        // Backward `cumulativeWork` (the F5-1 nChainWork-style prefix sum, used by
        // sync's work comparison — NOT by fork choice, which uses `trueCumWork` =
        // subtreeWeight + inherited): parent's cumulative work plus this block's own
        // work (with the out-of-order fallback to own work when the in-chain parent
        // is absent).
        let ownWork = workForTarget(target)
        let parentCumulativeWork: UInt256
        if let parentHash = block.parent?.rawCID, let parentMeta = hashToBlock[parentHash] {
            parentCumulativeWork = parentMeta.cumulativeWork
        } else {
            parentCumulativeWork = .zero
        }
        let blockCumulativeWork = saturatingWorkSum(parentCumulativeWork, ownWork)
        //: re-submitting a body-PRUNED block rehydrates its body, but
        // `findChildren` only sees live children (`indexToBlockHash`/`hashToBlock`).
        // The retained `weightIndex` entry still holds children whose own bodies were
        // pruned (e.g. a pruned descendant tail F4/F5 under F3); union them in so the
        // subsequent `syncWeightIndexEntry` write-through cannot drop the retained
        // linkage. Live children stay authoritative for the rebuilt meta.
        var childHashes = findChildren(hash: blockHash, blockHeight: block.height)
        if let retained = weightIndex[blockHash] {
            let live = Set(childHashes)
            for retainedChild in retained.childHashes where !live.contains(retainedChild) {
                childHashes.append(retainedChild)
            }
        }
        let meta = BlockMeta(
            blockInfo: BlockInfoImpl(
                blockHash: blockHash,
                parentBlockHash: block.parent?.rawCID,
                blockHeight: block.height,
                work: ownWork
            ),
            parentChainBlocks: parentBlockHeaderAndIndex.map { [$0.0: $0.1] } ?? [:],
            childHashes: childHashes,
            cumulativeWork: blockCumulativeWork
        )

        hashToBlock[blockHash] = meta
        blockTimestamps[blockHash] = block.timestamp
        missingBlockHashes.remove(blockHash)

        if let prevHash = block.parent?.rawCID,
           hashToBlock[prevHash]?.childHashes.contains(blockHash) == false {
            // Guard against a duplicate edge when rehydrating a body-pruned block: its
            // live parent still lists it in `childHashes` (pruning a child never holes
            // the parent's linkage), so a blind append would double-count its subtree.
            hashToBlock[prevHash]?.childHashes.append(blockHash)
        }

        // Out-of-order repair: if children of this block were delivered before it,
        // they were inserted with a provisional prefix sum (own work only, since
        // their parent was missing). Now that this block's prefix is known, fix
        // them and their descendants.
        propagateCumulativeWork(from: blockHash)

        // F5-4 (GHOST): fold this block's own work — and any out-of-order children
        // already attached to it — into the forward subtree weight of itself and
        // every same-chain ancestor.
        propagateSubtreeWeight(from: blockHash)

        //: mirror the new block (and the parent whose `childHashes` just
        // gained it) into the pruning-durable weight index. The propagate* calls
        // above already write-through the ancestor chain they touch; here we capture
        // the freshly-inserted block and its immediate parent linkage.
        syncWeightIndexEntry(blockHash)
        if let prevHash = block.parent?.rawCID {
            syncWeightIndexEntry(prevHash)
        }

        guard let previousBlockCID = block.parent?.rawCID else {
            return SubmissionResult(
                addedBlock: true,
                extendsMainChain: false,
                needsChildBlock: false,
                reorganization: nil
            )
        }

        if previousBlockCID == chainTip {
            // (1): the tip-extend path runs a full GHOST re-descent, which can
            // advance the tip past already-attached out-of-order descendants. Emit the
            // connect set so `updateParentsForReorg` re-anchors every newly-canonical
            // block (parent/child anchoring would otherwise silently desync). A
            // `Reorganization` is emitted ONLY when the connect set is more than the
            // single new block `{B}` (the plain in-order extend stays reorg-free).
            let connectSet = setNewTip(block: meta)
            if connectSet.count > 1 {
                let reorg = Reorganization(mainChainBlocksAdded: connectSet, mainChainBlocksRemoved: Set())
                updateParentsForReorg(reorg: reorg)
                return SubmissionResult(
                    addedBlock: true,
                    extendsMainChain: true,
                    needsChildBlock: false,
                    reorganization: reorg
                )
            }
            return .extendsMainChain()
        }

        let (idxPlusRet, ovf) = block.height.addingReportingOverflow(retentionDepth)
        if hashToBlock[previousBlockCID] == nil
            && (ovf || idxPlusRet > highestBlockHeight)
        {
            missingBlockHashes.insert(previousBlockCID)
            return SubmissionResult(
                addedBlock: true,
                extendsMainChain: false,
                needsChildBlock: true,
                reorganization: nil
            )
        }

        return SubmissionResult(
            addedBlock: true,
            extendsMainChain: false,
            needsChildBlock: false,
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
                    syncWeightIndexEntry(childHash) //: keep durable index in sync
                    queue.append(childHash)
                }
            }
        }
    }

    /// F5-4 (GHOST): repair the forward subtree weight up the same-chain ancestor
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
                //: fold in the child's RETAINED subtree weight (pruned children
                // live only in `weightIndex`); summing `hashToBlock` alone would drop a
                // pruned descendant tail and write the understated value back through
                // `syncWeightIndexEntry`, holing the durable index. Matches the
                // restore-time recompute (`recomputeAllSubtreeWeights`).
                weight = saturatingWorkSum(weight, indexedSubtreeWeight(childHash) ?? .zero)
            }
            if !isStart && weight == meta.subtreeWeight { break }
            hashToBlock[h]?.setSubtreeWeight(weight)
            syncWeightIndexEntry(h) //: keep durable index in sync
            isStart = false
            current = meta.parentBlockHash
        }
    }

    /// Recompute every block's forward subtree weight from scratch (children-before
    /// -parents). Used after a bulk install (`restore`/`resetFrom`) that rebuilds
    /// `hashToBlock` without per-insert propagation.
    ///
    ///: a live block may have a body-PRUNED child (the child's body is gone
    /// but its retained subtree weight lives in `weightIndex`). Fold the child in via
    /// `indexedSubtreeWeight` so a present block whose descendant tail was pruned is
    /// not understated — requires the pruned index to be seeded BEFORE this runs.
    private func recomputeAllSubtreeWeights() {
        Self.recomputeSubtreeWeights(in: &hashToBlock, prunedIndex: weightIndex)
    }

    /// (7): the single bottom-up subtree-weight rebuild, shared by `init`
    /// (which cannot call the isolated `recomputeAllSubtreeWeights`) and
    /// `recomputeAllSubtreeWeights`. `subtreeWeight(B) = work(B) + Σ subtreeWeight(c)`,
    /// computed children-before-parents (descending height) so each block's children
    /// are finalized first. A child's weight is read live from `blocks` (already
    /// finalized this pass) and, when its body is absent, from `prunedIndex`:
    /// a body-pruned descendant tail's retained weight must not be dropped). Pure
    /// projection, no isolation needed.
    nonisolated static func recomputeSubtreeWeights(
        in blocks: inout [String: BlockMeta],
        prunedIndex: [String: BlockWeightIndexEntry]
    ) {
        let ordered = blocks.values.sorted { $0.blockHeight > $1.blockHeight }
        for meta in ordered {
            var weight = meta.work
            for childHash in meta.childHashes {
                let childWeight = blocks[childHash]?.subtreeWeight
                    ?? prunedIndex[childHash]?.subtreeWeight ?? .zero
                weight = saturatingWorkSum(weight, childWeight)
            }
            blocks[meta.blockHash]?.setSubtreeWeight(weight)
        }
    }

    // MARK: - Pruning-durable weight/linkage index

    /// Write-through the live `BlockMeta` of `hash` into the weight index, keeping
    /// the pruning-durable projection in lock-step with the maintained weight +
    /// linkage. Called wherever a present block's `cumulativeWork` / `subtreeWeight`
    /// / `childHashes` changes, so that when the body is later pruned the retained
    /// entry already holds the final values. No-op if the body is absent (a pruned
    /// block's entry is authoritative and must not be overwritten with nothing).
    private func syncWeightIndexEntry(_ hash: String) {
        guard let meta = hashToBlock[hash] else { return }
        weightIndex[hash] = BlockWeightIndexEntry(from: meta)
    }

    /// The fork-choice subtree weight of `hash`, preferring the live body and
    /// falling back to the pruning-durable index. Returns `nil` only when the block
    /// is unknown to *both* (genuinely absent, not merely body-pruned) — which fork
    /// choice treats as an incomplete descent (CFC-A1), distinct from a pruned
    /// interior whose weight the index still supplies.
    private func indexedSubtreeWeight(_ hash: String) -> UInt256? {
        if let meta = hashToBlock[hash] { return meta.subtreeWeight }
        return weightIndex[hash]?.subtreeWeight
    }

    /// The genesis-relative cumulative-work prefix sum of `hash`, preferring the
    /// live body and falling back to the pruning-durable index.
    private func indexedCumulativeWork(_ hash: String) -> UInt256? {
        if let meta = hashToBlock[hash] { return meta.cumulativeWork }
        return weightIndex[hash]?.cumulativeWork
    }

    /// (3): the incumbent tip's durable genesis-relative cumulative work for
    /// the no-downgrade guards, read via the pruning-durable index so it survives a
    /// body prune of the tip, and failing closed to `.zero` when the tip is unknown
    /// to both stores (rather than force-unwrapping `highestBlock`).
    private func incumbentTipCumulativeWork() -> UInt256 {
        indexedCumulativeWork(chainTip) ?? .zero
    }

    /// The block height of `hash`, preferring the live body and falling back to the
    /// pruning-durable index, so reorg bookkeeping can place a body-pruned block the
    /// descent rode through.
    private func indexedBlockHeight(_ hash: String) -> UInt64? {
        if let meta = hashToBlock[hash] { return meta.blockHeight }
        return weightIndex[hash]?.blockHeight
    }

    /// The same-chain children of `hash` for GHOST descent, preferring the live
    /// body and falling back to the pruning-durable index so descent can traverse a
    /// branch whose interior bodies have been pruned.
    private func indexedChildHashes(_ hash: String) -> [String]? {
        if let meta = hashToBlock[hash] { return meta.childHashes }
        return weightIndex[hash]?.childHashes
    }

    /// The fork-choice weight (`trueCumWork = subtreeWeight + inherited`) of `hash`,
    /// computed from the pruning-durable index when the body is absent. Returns
    /// `nil` if the block is unknown to both stores.
    private func indexedEffectiveWeight(_ hash: String) -> UInt256? {
        guard let subtree = indexedSubtreeWeight(hash) else { return nil }
        return inheritedWeight.effectiveWeight(subtreeWeight: subtree, blockHash: hash)
    }

    // MARK: - Duplicate Block (new parent chain anchoring for already-known block)

    func handleDuplicateBlock(
        parentBlockHeaderAndIndex: (String, UInt64?)?,
        blockHash: String
    ) -> SubmissionResult {
        guard let parentInfo = parentBlockHeaderAndIndex else { return .discarded() }
        if parentChainBlockHashToBlockHash[parentInfo.0] != nil { return .discarded() }

        parentChainBlockHashToBlockHash[parentInfo.0] = blockHash
        guard let parentBlockIndex = parentInfo.1 else { return .discarded() }

        hashToBlock[blockHash]?.setParentChainBlock(parentInfo.0, index: parentBlockIndex)

        if mainChainBlockAtIndex[hashToBlock[blockHash]!.blockHeight] == blockHash {
            return .discarded()
        }

        if let reorg = checkForReorg(block: hashToBlock[blockHash]!) {
            return SubmissionResult(
                addedBlock: false,
                extendsMainChain: false,
                needsChildBlock: false,
                reorganization: reorg
            )
        }
        return .discarded()
    }

    // MARK: - Parent Chain Reorg

    public func applyParentReorg(
        reorg: Reorganization,
        parentBlockHeaderAndIndex: (String, UInt64?)?,
        blockHash: String,
        block: Block
    ) -> SubmissionResult {
        var tempResult: SubmissionResult = .discarded()

        // Guarded retention-window check: `block.height + retentionDepth` is an
        // unchecked UInt64 add that traps on overflow, and `retentionDepth`
        // defaults to `RECENT_BLOCK_DISTANCE == UInt64.max`, so a crafted parent
        // reorg with any non-genesis height would crash the actor. An overflow
        // means the block is astronomically far inside the retention window, so
        // the `>= highestBlockHeight` predicate saturates to `true` (matches the
        // `addingReportingOverflow` guard already used in `insertBlock`/`submit`).
        let (heightPlusRetention, retentionOverflow) = block.height.addingReportingOverflow(retentionDepth)
        let withinRetention = retentionOverflow || heightPlusRetention >= highestBlockHeight
        let shouldInsert = withinRetention
            && (reorg.mainChainBlocksAdded[blockHash] != nil
                || (block.parent != nil && hashToBlock[blockHash] == nil))

        if shouldInsert {
            tempResult = insertBlock(
                parentBlockHeaderAndIndex: parentBlockHeaderAndIndex,
                blockHash: blockHash,
                block: block,
                target: block.target
            )
        }

        updateParentsForReorg(reorg: reorg)

        var affectedHashes = reorg.mainChainBlocksAdded.keys.compactMap {
            parentChainBlockHashToBlockHash[$0]
        }
        affectedHashes.append(blockHash)

        let orphanCandidates = affectedHashes.filter {
            guard let block = hashToBlock[$0] else { return false }
            return mainChainBlockAtIndex[block.blockHeight] != $0
        }
        let earliestOrphans = findEarliestOrphansConnectedToMainChain(blockHeaders: orphanCandidates)

        if let reorgResult = findBestReorg(among: earliestOrphans) {
            return SubmissionResult(
                addedBlock: tempResult.addedBlock,
                extendsMainChain: tempResult.extendsMainChain,
                needsChildBlock: tempResult.needsChildBlock,
                reorganization: reorgResult
            )
        }

        return tempResult
    }

    // MARK: - Parent Chain Reorg Propagation

    public func propagateParentReorg(reorg: Reorganization) -> Reorganization? {
        updateParentsForReorg(reorg: reorg)

        var affectedBlockHashes: Set<String> = Set()
        for addedHash in reorg.mainChainBlocksAdded.keys {
            if let blockHash = parentChainBlockHashToBlockHash[addedHash] {
                affectedBlockHashes.insert(blockHash)
            }
        }
        for removedHash in reorg.mainChainBlocksRemoved {
            if let blockHash = parentChainBlockHashToBlockHash[removedHash] {
                affectedBlockHashes.insert(blockHash)
            }
        }

        let orphanCandidates = affectedBlockHashes.filter {
            guard let block = hashToBlock[$0] else { return false }
            return mainChainBlockAtIndex[block.blockHeight] != $0
        }
        guard !orphanCandidates.isEmpty else { return nil }

        let earliestOrphans = findEarliestOrphansConnectedToMainChain(
            blockHeaders: Array(orphanCandidates)
        )

        return findBestReorg(among: earliestOrphans)
    }

    // MARK: - Shared Reorg Evaluation

    private func findBestReorg(among orphans: [BlockMeta]) -> Reorganization? {
        clearInheritedWeightMemo()
        var bestWork: UInt256? = nil
        var bestBlocks: Set<String> = Set()
        // P-1103: track tipHash alongside blocks — avoids rescanning bestBlocks at the end
        var bestTipHash: String = ""
        var bestForkIndex: UInt64 = 0

        for orphan in orphans {
            let forkWork = chainWithMostWork(startingBlock: orphan)
            let mainWork = mainChainWork(fromIndex: orphan.blockHeight)

            // CFC-A1 no-downgrade obligation (see checkForReorg): an incomplete
            // descent that doesn't strictly beat the incumbent tip's durable
            // cumulative work is refetch-required, not a reorg.: compare the
            // HEAVIEST (index-computed) tip's durable cumulative work — even if its
            // body is pruned — so the guard reflects the real heaviest branch, not
            // just the body-present prefix we could install.
            if !forkWork.complete,
               let forkTipWork = indexedCumulativeWork(forkWork.heaviestTipHash),
               forkTipWork <= incumbentTipCumulativeWork() {
                continue
            }

            // no-downgrade obligation on the INSTALLABLE tip (see
            // checkForReorg): when the heaviest branch's bodies are pruned/missing,
            // refuse to install the body-present prefix unless it strictly beats the
            // incumbent. The heavier branch stays KNOWN for backfill.
            if forkWork.tipHash != forkWork.heaviestTipHash,
               let installableTipWork = indexedCumulativeWork(forkWork.tipHash),
               installableTipWork <= incumbentTipCumulativeWork() {
                continue
            }

            if forkWork.cumulativeWork > mainWork.cumulativeWork {
                if let current = bestWork {
                    if forkWork.cumulativeWork > current {
                        bestWork = forkWork.cumulativeWork
                        bestBlocks = forkWork.blocks
                        bestTipHash = forkWork.tipHash
                        bestForkIndex = orphan.blockHeight
                    }
                } else {
                    bestWork = forkWork.cumulativeWork
                    bestBlocks = forkWork.blocks
                    bestTipHash = forkWork.tipHash
                    bestForkIndex = orphan.blockHeight
                }
            }
        }

        if bestWork != nil {
            return applyReorg(
                newForkBlocks: bestBlocks,
                newForkTipHash: bestTipHash.isEmpty ? nil : bestTipHash,
                mainChainBlocks: mainChainHashesFrom(index: bestForkIndex)
            )
        }
        return nil
    }

    // MARK: - Index Management

    func addToBlockIndex(hash: String, blockHeight: UInt64) {
        indexToBlockHash[blockHeight, default: []].insert(hash)
    }

    func findChildren(hash: String, blockHeight: UInt64) -> [String] {
        guard let hashes = indexToBlockHash[blockHeight + 1] else { return [] }
        return hashes.filter { hashToBlock[$0]?.parentBlockHash == hash }
    }

    // MARK: - Parent Chain Tracking

    func addParentBlockReference(parentBlockHeader: String, parentIndex: UInt64?, blockHash: String) {
        parentChainBlockHashToBlockHash[parentBlockHeader] = blockHash
        hashToBlock[blockHash]?.setParentChainBlock(parentBlockHeader, index: parentIndex)
    }

    func updateParentsForReorg(reorg: Reorganization) {
        for removedHash in reorg.mainChainBlocksRemoved {
            if let blockHash = parentChainBlockHashToBlockHash[removedHash] {
                hashToBlock[blockHash]?.removeParentChainBlock(removedHash)
            }
        }
        for (addedHash, idx) in reorg.mainChainBlocksAdded {
            if let blockHash = parentChainBlockHashToBlockHash[addedHash] {
                hashToBlock[blockHash]?.setParentChainBlock(addedHash, index: idx)
            }
        }
    }

    // MARK: - Fork Choice (Hierarchical GHOST, design §4/§6)
    //
    // Every chain follows the fork of greatest `trueCumWork` (a single metric, no
    // positional tie-break): `trueCumWork(B) = subtreeWeight(B)` (own-chain
    // descendant subtree, §3/§6) `+ inherited(B)` (the securing parent's
    // `trueCumWork`, fetched live from the provider, §6.2). The inherited term is
    // *derived, not cached* — asked fresh each time (`effectiveWeight`) so it can't
    // go stale as the parent chain extends.

    // P-1103: return tipHash so callers (setNewTip, checkForReorg, findBestReorg)
    // don't need to re-scan blocks to find the leaf node — it's already computed here.
    /// The canonical continuation from a block is the **heaviest-`trueCumWork`
    /// descent** — at each step move to the child with the greatest `trueCumWork`,
    /// ties broken deterministically by hash so every node agrees. The fork's
    /// *weight* is just `effectiveWeight(startingBlock)` (no path accumulation).
    /// The comparison against the main chain is a single metric — `cumulativeWork`
    /// alone (design §4; the old positional `(parentIndex, work)` two-tier key and
    /// the N20 reorg tautology are dismantled).
    func chainWithMostWork(
        startingBlock: BlockMeta
    ) -> (cumulativeWork: UInt256, tipHash: String, blocks: Set<String>, complete: Bool, heaviestTipHash: String) {
        // Resolve the live meta: callers may pass a stale copy captured before the
        // block (and its maintained `subtreeWeight`/`childHashes`) was indexed.
        let start = hashToBlock[startingBlock.blockHash] ?? startingBlock
        let descent = ghostDescent(from: start)
        //: weigh the fork base from the pruning-durable index so the base's
        // weight is the never-pruned value even if its own body was pruned.
        let baseWeight = indexedEffectiveWeight(start.blockHash) ?? effectiveWeight(start)
        return (baseWeight, descent.tipHash, descent.blocks, descent.complete, descent.heaviestTipHash)
    }

    /// Descend to the heaviest-`trueCumWork` leaf, returning the path taken.
    ///
    /// CFC-A1 (no-downgrade obligation): `complete` is `false` when the descent
    /// skipped a child referenced in `childHashes` that is unknown to BOTH the body
    /// store AND the pruning-durable weight index (`indexedEffectiveWeight == nil`)
    /// — i.e. the interior of a candidate branch was never fetched, not merely
    /// body-pruned. A heavier sibling branch can hide behind such a hole, so
    /// silently descending the visible-but-lighter sibling would let fork choice
    /// regress the tip. The caller treats an incomplete descent as refetch-required
    /// and refuses any tip downgrade.
    ///
    ///: a child whose *body* was pruned but whose weight/linkage the index
    /// retains is NOT a hole — descent traverses and weighs it from the index, so
    /// the heaviest subtree is positively computed despite missing bodies.
    ///
    /// Two tips are returned (Bitcoin Core's `pindexBestHeader` vs. validated tip):
    /// - `heaviestTipHash` / `complete`: the index-computed heaviest leaf — the
    ///   *knowledge* the no-downgrade guard compares (its durable cumulative work).
    /// - `tipHash` / `blocks`: the deepest **body-present** prefix of that heaviest
    ///   path — the tip we may actually INSTALL and serve. We never advance the main
    ///   chain onto a block whose body we don't hold; the body-backfill transport
    ///   follow-up 2/2) fetches the missing bodies, after which a re-run
    ///   advances the tip the rest of the way.
    private func ghostDescent(
        from start: BlockMeta
    ) -> (tipHash: String, blocks: Set<String>, complete: Bool, heaviestTipHash: String) {
        var currentHash = start.blockHash
        // The installable (body-present) path and tip. The fork base is body-present
        // (callers resolve it from `hashToBlock`), so it seeds both.
        var blocks: Set<String> = [currentHash]
        var installableTip = currentHash
        var heaviestTip = currentHash
        var complete = true
        //: descend over the pruning-durable weight/linkage index, not the
        // body store. A block whose body was pruned still has its `childHashes` and
        // `subtreeWeight` in `weightIndex`, so descent traverses and weighs it just
        // as the never-pruned oracle would (Bitcoin Core keeps `CBlockIndex` past a
        // body prune). `complete` is `false` ONLY when a referenced child is unknown
        // to BOTH stores — genuinely absent / not-yet-fetched, not merely
        // body-pruned — preserving CFC-A1's no-downgrade obligation for that case
        // (invalid≠unavailable: a hole we cannot weigh, vs. a pruned body we can).
        while let children = indexedChildHashes(currentHash), !children.isEmpty {
            var bestHash: String? = nil
            var bestWeight: UInt256 = .zero
            for childHash in children {
                guard let childWeight = indexedEffectiveWeight(childHash) else { complete = false; continue }
                guard let incumbent = bestHash else { bestHash = childHash; bestWeight = childWeight; continue }
                if childWeight > bestWeight
                    || (childWeight == bestWeight && childHash < incumbent) {
                    bestHash = childHash
                    bestWeight = childWeight
                }
            }
            guard let next = bestHash, next != currentHash else { break }
            currentHash = next
            heaviestTip = currentHash
            // Only extend the installable path while bodies are present and
            // contiguous from the base: we can't validate/serve a tip past the first
            // pruned body. The heaviest-path knowledge (heaviestTip/complete) keeps
            // going regardless, so fork choice still KNOWS the branch is heavier.
            if installableTip == previousHash(of: currentHash), hashToBlock[currentHash] != nil {
                installableTip = currentHash
                blocks.insert(currentHash)
            }
        }
        return (installableTip, blocks, complete, heaviestTip)
    }

    /// The same-chain parent hash of `hash` from whichever store holds it
    /// linkage helper for the body-present-prefix walk in `ghostDescent`).
    private func previousHash(of hash: String) -> String? {
        if let meta = hashToBlock[hash] { return meta.parentBlockHash }
        return weightIndex[hash]?.parentBlockHash
    }

    /// The main chain's competing weight at a fork height: the `trueCumWork` of the
    /// main-chain block at `blockHeight` (the sibling of the fork base) — the GHOST
    /// weight of the branch the main chain currently takes. `blocks` is the
    /// main-chain segment from that height to the tip (the reorg removal set).
    func mainChainWork(
        fromIndex blockHeight: UInt64
    ) -> (cumulativeWork: UInt256, blocks: Set<String>) {
        //: weigh the main-chain sibling from the pruning-durable index so a
        // body-pruned main-chain block at the fork height is still weighed correctly.
        let weight = mainChainBlockAtIndex[blockHeight].flatMap { indexedEffectiveWeight($0) } ?? .zero
        return (weight, mainChainHashesFrom(index: blockHeight))
    }

    // MARK: - Reorganization

    func checkForReorg(block: BlockMeta) -> Reorganization? {
        clearInheritedWeightMemo()
        guard let earliestHash = findEarliestOrphanConnectedToMainChain(
            blockHeader: block.blockHash
        ) else {
            return nil
        }
        guard let earliest = hashToBlock[earliestHash] else { return nil }

        let mainWork = mainChainWork(fromIndex: earliest.blockHeight)
        let forkWork = chainWithMostWork(startingBlock: earliest)

        if forkWork.cumulativeWork > mainWork.cumulativeWork {
            // CFC-A1 no-downgrade obligation: if GHOST descent skipped a pruned /
            // not-yet-fetched interior child, the chosen leaf may be a *lighter*
            // sibling standing in for a heavier branch hidden behind the hole.
            // Refuse to switch to a tip whose durable genesis-relative cumulative
            // work does not strictly exceed the incumbent's — that would regress
            // the chain. Treat as refetch-required (decline now; re-evaluated once
            // the missing block arrives). Reuses the pruning-proof `cumulativeWork`
            // prefix sum, the one work measure that survives retention.
            if !forkWork.complete,
               let forkTipWork = indexedCumulativeWork(forkWork.heaviestTipHash),
               forkTipWork <= incumbentTipCumulativeWork() {
                return nil
            }
            // no-downgrade obligation on the INSTALLABLE tip: when the
            // heaviest branch's bodies are pruned/missing, the tip we can actually
            // serve is only the body-present PREFIX (`tipHash`), shorter than the
            // index-known heaviest leaf (`heaviestTipHash`). Refuse to install that
            // prefix if its durable cumulative work does not strictly exceed the
            // incumbent's — installing a lighter prefix would regress the chain. Only
            // applies when the installable tip falls short of the heaviest leaf; when
            // they coincide the full heaviest path is installable and the existing
            // most-work decision stands. The heavier branch stays KNOWN (drives the
            // body-backfill follow-up); once its bodies arrive a re-run advances the
            // tip the rest of the way.
            if forkWork.tipHash != forkWork.heaviestTipHash,
               let installableTipWork = indexedCumulativeWork(forkWork.tipHash),
               installableTipWork <= incumbentTipCumulativeWork() {
                return nil
            }
            // P-1103: use tipHash from chainWithMostWork instead of rescanning blocks
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
            //: the fork descent may ride through body-pruned blocks; resolve
            // their height from the pruning-durable index rather than force-unwrap.
            guard let idx = indexedBlockHeight(hash) else { continue }
            forkHashToIndex[hash] = idx
            if idx > highestIndex { highestIndex = idx }
        }

        let newTip = newForkTipHash ?? chainTip
        advanceTip(to: newTip, newHighestIndex: highestIndex)

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
            mainChainBlocksAdded: forkHashToIndex,
            mainChainBlocksRemoved: mainChainBlocks
        )
    }

    /// Advance the main-chain tip onto the heaviest descent from `block` (whose parent
    /// is the current tip). Returns the **connect set**: the blocks that newly joined
    /// the main chain, keyed by height — `chainWithMostWork`'s descent `blocks`. In the
    /// common in-order extend this is just `{block}`; when GHOST descent advances the
    /// tip past already-attached out-of-order descendants it also includes those, so
    /// the caller can emit a `Reorganization` and re-anchor them (1)).
    @discardableResult
    func setNewTip(block: BlockMeta) -> [String: UInt64] {
        clearInheritedWeightMemo()
        let oldHighest = highestBlockHeight
        let chain = chainWithMostWork(startingBlock: block)
        // P-1103: use tipHash returned by chainWithMostWork instead of rescanning blocks
        chainTip = chain.tipHash
        var connectSet: [String: UInt64] = [:]
        for hash in chain.blocks {
            mainChainHashes.insert(hash)
            if let b = hashToBlock[hash] {
                mainChainBlockAtIndex[b.blockHeight] = hash
                connectSet[hash] = b.blockHeight
            }
        }
        let newHighest = highestBlockHeight
        if let prunable = policy.newlyPrunableRange(oldHighest: oldHighest, newHighest: newHighest) {
            for idx in prunable {
                pruneBlocksAtIndex(idx)
            }
        }
        return connectSet
    }

    func advanceTip(to blockHash: String, newHighestIndex: UInt64) {
        let oldHighest = highestBlockHeight
        chainTip = blockHash

        if let prunable = policy.newlyPrunableRange(oldHighest: oldHighest, newHighest: newHighestIndex) {
            for idx in prunable {
                pruneBlocksAtIndex(idx)
            }
        }
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

    func findEarliestOrphansConnectedToMainChain(blockHeaders: [String]) -> [BlockMeta] {
        var toVisit = Set(blockHeaders)
        var visited: Set<String> = Set()
        var result: [BlockMeta] = []

        while let startHash = toVisit.popFirst() {
            visited.insert(startHash)
            guard var current = hashToBlock[startHash] else { continue }
            var currentHash = startHash

            while let prevHash = current.parentBlockHash,
                  !mainChainHashes.contains(prevHash),
                  !visited.contains(prevHash)
            {
                guard let prev = hashToBlock[prevHash] else { break }
                currentHash = prevHash
                visited.insert(currentHash)
                current = prev
            }

            if let prevHash = current.parentBlockHash {
                if mainChainHashes.contains(prevHash) {
                    result.append(hashToBlock[currentHash]!)
                }
            } else if current.blockHeight == 0 {
                result.append(hashToBlock[currentHash]!)
            }
        }
        return result
    }

    // MARK: - Main Chain Queries

    func mainChainHashesFrom(index blockHeight: UInt64) -> Set<String> {
        var hashes: Set<String> = Set()
        var currentHash = chainTip
        // (3): the tip may be absent from the body store; an absent tip yields
        // just the tip hash rather than trapping.
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

    func pruneBlocksAtIndex(_ index: UInt64) {
        guard let hashes = indexToBlockHash.removeValue(forKey: index) else { return }
        for hash in hashes {
            mainChainHashes.remove(hash)
            if let block = hashToBlock.removeValue(forKey: hash) {
                // (Bitcoin Core `-prune` model): pruning evicts the block
                // BODY from the prunable `hashToBlock` store but must NEVER hole the
                // header-derived indices that consensus still reads. (1) Retain the
                // final weight + linkage so GHOST descent can traverse and weigh a
                // branch whose interior bodies are gone (CFC-A1 liveness half).
                weightIndex[hash] = BlockWeightIndexEntry(from: block)
                for parentChainBlock in block.parentChainBlocks.keys {
                    parentChainBlockHashToBlockHash.removeValue(forKey: parentChainBlock)
                }
            }
            // (2) Retain the block's TIMESTAMP. A node validates its next block by
            // reading the median-time-past (last 11) and the difficulty-retarget
            // window (`spec.retargetWindow`, e.g. 120) of ancestor timestamps via the
            // `getMainChainTimestamps` fast path. That window is independent of —
            // and can far exceed — the content `retentionDepth`, so holing the
            // timestamp on body-prune starves the validator and the chain can no
            // longer extend itself once height passes `retentionDepth`. The
            // timestamp is part of the header, which (Bitcoin's prune model) the
            // weight index already keeps; keep the timestamp alongside it.
        }
        // (3) `mainChainBlockAtIndex` is the height→hash header index the timestamp
        // walk steps through; retaining it (not holing it on prune) lets the walk
        // reach every ancestor in the validation window from the in-memory header
        // index alone, never falling back to resolving a pruned block body.
    }
}
