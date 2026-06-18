import Foundation
import cashew
import UInt256

/// / CFC-A3: a persisted chain-state snapshot whose fork-choice weight
/// data is corrupt cannot be restored without silently understating work. The
/// restore choke point throws this so the node fails closed (reindex-or-halt /
/// markChainUnhealthy) rather than constructing a zeroed-weight `ChainState`.
public enum ChainStateRestoreError: Error {
    /// A persisted block target or a pruned-but-retained weight-index entry's
    /// non-recomputable weight field (`cumulativeWork` / `subtreeWeight`) is
    /// missing-or-undecodable. Defaulting it to zero would hole the fork-choice
    /// weight index (a heavier branch looks weightless), so restore is rejected.
    case corruptWeightIndex
}

public struct PersistedChainState: Codable, Sendable {
    public let chainTip: String
    public let tipPostStateCID: String?
    public let tipPrevStateCID: String?
    public let tipSpecCID: String?
    public let tipTarget: String?
    public let tipNextTarget: String?
    public let tipHeight: UInt64?
    public let tipTimestamp: Int64?
    public let mainChainHashes: [String]
    public let blocks: [PersistedBlockMeta]
    ///: pruning-durable fork-choice weight/linkage entries whose block
    /// BODIES have been evicted from the prunable store (`hashToBlock`). These are
    /// NOT live blocks — they carry only the retained weight + linkage that GHOST
    /// descent needs to traverse and weigh a branch whose interior bodies are gone.
    /// Persisting them (rather than re-deriving the index from live bodies alone)
    /// is what lets a body-pruned block keep its weight across a restart. Optional
    /// for backward compatibility with pre-upgrade persisted states.
    public let prunedWeightIndex: [PersistedBlockMeta]
    public let parentChainMap: [String: String]
    public let missingBlockHashes: [String]

    public init(chainTip: String, tipPostStateCID: String?, tipPrevStateCID: String?, tipSpecCID: String?, tipTarget: String?, tipNextTarget: String?, tipHeight: UInt64?, tipTimestamp: Int64?, mainChainHashes: [String], blocks: [PersistedBlockMeta], prunedWeightIndex: [PersistedBlockMeta] = [], parentChainMap: [String: String], missingBlockHashes: [String]) {
        self.chainTip = chainTip
        self.tipPostStateCID = tipPostStateCID
        self.tipPrevStateCID = tipPrevStateCID
        self.tipSpecCID = tipSpecCID
        self.tipTarget = tipTarget
        self.tipNextTarget = tipNextTarget
        self.tipHeight = tipHeight
        self.tipTimestamp = tipTimestamp
        self.mainChainHashes = mainChainHashes
        self.blocks = blocks
        self.prunedWeightIndex = prunedWeightIndex
        self.parentChainMap = parentChainMap
        self.missingBlockHashes = missingBlockHashes
    }

    private enum CodingKeys: String, CodingKey {
        case chainTip, tipPostStateCID, tipPrevStateCID, tipSpecCID, tipTarget
        case tipNextTarget, tipHeight, tipTimestamp, mainChainHashes, blocks
        case prunedWeightIndex, parentChainMap, missingBlockHashes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chainTip = try c.decode(String.self, forKey: .chainTip)
        tipPostStateCID = try c.decodeIfPresent(String.self, forKey: .tipPostStateCID)
        tipPrevStateCID = try c.decodeIfPresent(String.self, forKey: .tipPrevStateCID)
        tipSpecCID = try c.decodeIfPresent(String.self, forKey: .tipSpecCID)
        tipTarget = try c.decodeIfPresent(String.self, forKey: .tipTarget)
        tipNextTarget = try c.decodeIfPresent(String.self, forKey: .tipNextTarget)
        tipHeight = try c.decodeIfPresent(UInt64.self, forKey: .tipHeight)
        tipTimestamp = try c.decodeIfPresent(Int64.self, forKey: .tipTimestamp)
        mainChainHashes = try c.decode([String].self, forKey: .mainChainHashes)
        blocks = try c.decode([PersistedBlockMeta].self, forKey: .blocks)
        // Fail closed (wave-4, pre-testnet): `persist()`/`save()` ALWAYS encode the
        // pruned-index array (empty when nothing is pruned), and no legacy snapshots
        // exist that omit the key. A missing key therefore means the snapshot was
        // truncated or hand-edited — decoding it as `[]` would silently drop the
        // retained weight of every body-pruned branch (the hole). Require it.
        prunedWeightIndex = try c.decode([PersistedBlockMeta].self, forKey: .prunedWeightIndex)
        parentChainMap = try c.decode([String: String].self, forKey: .parentChainMap)
        missingBlockHashes = try c.decode([String].self, forKey: .missingBlockHashes)
    }
}

public struct PersistedBlockMeta: Codable, Sendable {
    public let blockHash: String
    public let parentBlockHash: String?
    public let blockHeight: UInt64
    public let parentChainBlocks: [String: UInt64?]
    public let childHashes: [String]
    public let target: String?
    public let timestamp: Int64?
    /// Hex-encoded backward cumulative-work prefix sum (see `BlockMeta.cumulativeWork`).
    /// Optional for backward compatibility: pre-upgrade persisted states and
    /// sync-produced results omit it, in which case it is recomputed (window-relative)
    /// on restore.
    public let cumulativeWork: String?
    ///: hex-encoded forward subtree weight (see `BlockMeta.subtreeWeight`).
    /// Carried only for pruned-but-retained weight-index entries, whose subtree
    /// weight cannot be recomputed from live bodies (their descendants may also be
    /// pruned). Optional/`nil` for live blocks, whose subtree weight is recomputed
    /// bottom-up from the restored tree.
    public let subtreeWeight: String?
    ///: hex-encoded own work (see `BlockMeta.work`). Carried for live
    /// blocks and pruned-but-retained weight-index entries persisted by
    /// `persist()`, so the restored `work` roundtrips exactly rather than through
    /// the lossy `target = MAX / work` / `work = MAX / target` double division.
    /// Optional/`nil` only for sync-/rebuild-produced snapshots of live blocks
    /// (which reconstruct work from `target`); a pruned entry missing it fails
    /// closed at the restore choke point (wave-4).
    public let workHex: String?

    public init(blockHash: String, parentBlockHash: String?, blockHeight: UInt64, parentChainBlocks: [String: UInt64?], childHashes: [String], target: String? = nil, timestamp: Int64? = nil, cumulativeWork: String? = nil, subtreeWeight: String? = nil, workHex: String? = nil) {
        self.blockHash = blockHash
        self.parentBlockHash = parentBlockHash
        self.blockHeight = blockHeight
        self.parentChainBlocks = parentChainBlocks
        self.childHashes = childHashes
        self.target = target
        self.timestamp = timestamp
        self.cumulativeWork = cumulativeWork
        self.subtreeWeight = subtreeWeight
        self.workHex = workHex
    }
}

public extension PersistedChainState {
    /// CFC-A3: a persisted block whose `target` string is *present
    /// but undecodable* is corruption — the work it contributes can't be
    /// recovered. The restore path currently maps it to `UInt256.zero` (via
    /// `?? .zero`), which silently *understates* this chain's accumulated work and
    /// can make a competing fork look spuriously heavier. Callers (the node restart
    /// guard) use this to fail closed — markChainUnhealthy / reindex-or-halt —
    /// rather than reset onto a silently-zeroed tip.
    ///
    /// A `nil` target is NOT corruption: pre-prefix-sum / sync-produced blocks
    /// legitimately omit it and are recomputed window-relative.
    func hasUndecodableTarget() -> Bool {
        for block in blocks {
            if let hex = block.target, UInt256(hex, radix: 16) == nil {
                return true
            }
            //: a live block's `workHex` is the directly-persisted fork-choice
            // input. A present-but-undecodable value is corruption — silently falling
            // back to the target-derived work would shift the restored subtree/effective
            // weight (the exact determinism hazard this issue fixes). A `nil` workHex is
            // NOT corruption: it is a pre-upgrade snapshot that legitimately falls back.
            if let hex = block.workHex, UInt256(hex, radix: 16) == nil {
                return true
            }
        }
        //: the pruned-but-retained weight-index entries carry hex-encoded
        // weight fields that `weightIndexEntries(fromPruned:)` would otherwise map to
        // zero / a target-derived fallback — silently understating a pruned branch's
        // retained weight, the same fail-open hazard as a corrupt live target. Two
        // distinct cases are both fail-closed here:
        //
        //   * `cumulativeWork` / `subtreeWeight` / `workHex` are weights `persist()`
        //     ALWAYS writes for a retained entry, and pruned entries are produced by
        //     no other path (sync- and rebuild-produced snapshots carry an empty
        //     pruned index). Pre-testnet there are no legacy snapshots, so a missing
        //     OR undecodable value is a hole, not a legitimate absence. Require all
        //     three present and decodable: restoring `?? .zero` would underweight a
        //     heavier pruned branch, and a `workHex` fallback to the target-derived
        //     `workForTarget(target)` is the lossy double-division determinism hazard
        // fixed for live blocks (wave-4 closes it for pruned entries by
        //     failing closed here, the snapshot choke point).
        //   * `target` may legitimately be nil — `persist()` omits it for a zero-work
        //     entry — so only a present-but-undecodable value is corruption.
        for block in prunedWeightIndex {
            for required in [block.cumulativeWork, block.subtreeWeight, block.workHex] {
                guard let hex = required, UInt256(hex, radix: 16) != nil else {
                    return true
                }
            }
            if let hex = block.target, UInt256(hex, radix: 16) == nil {
                return true
            }
        }
        return false
    }

    /// Resolve each block's backward cumulative-work prefix sum
    /// (see `BlockMeta.cumulativeWork`). Prefers the persisted per-block value;
    /// for blocks that omit it (pre-upgrade data or sync-produced results) it
    /// falls back to a height-ordered recompute over the blocks present here —
    /// window-relative, matching pre-prefix-sum behavior.
    func cumulativeWorkByHash() -> [String: UInt256] {
        var result: [String: UInt256] = [:]
        let ordered = blocks.sorted { $0.blockHeight < $1.blockHeight }
        for block in ordered {
            if let hex = block.cumulativeWork, let value = UInt256(hex, radix: 16) {
                result[block.blockHash] = value
                continue
            }
            let target = block.target.flatMap { UInt256($0, radix: 16) } ?? UInt256.zero
            let ownWork = workForTarget(target)
            let parentCum = block.parentBlockHash.flatMap { result[$0] } ?? .zero
            result[block.blockHash] = saturatingWorkSum(parentCum, ownWork)
        }
        return result
    }
}

public extension ChainState {

    func persist() async -> PersistedChainState {
        var blocks: [PersistedBlockMeta] = []
        for (_, meta) in hashToBlock {
            // Recover target from work: if work > 0, target = MAX / work
            let targetHex: String? = meta.work > UInt256.zero
                ? (UInt256.max / meta.work).toHexString()
                : nil
            blocks.append(PersistedBlockMeta(
                blockHash: meta.blockHash,
                parentBlockHash: meta.parentBlockHash,
                blockHeight: meta.blockHeight,
                parentChainBlocks: meta.parentChainBlocks,
                childHashes: meta.childHashes,
                target: targetHex,
                timestamp: blockTimestamps[meta.blockHash],
                cumulativeWork: meta.cumulativeWork.toHexString(),
                //: persist the block's OWN work directly. The fork-choice
                // subtree weight is rebuilt from `work`, so reconstructing it on
                // restore via `workForTarget(target = MAX / work)` applies a second
                // and third floor-division — `work' >= work`, not equal — making the
                // restored weight depend on restart history (a determinism split).
                // Carry `work` verbatim; `target` is retained only as a fallback for
                // pre-upgrade snapshots that omit `workHex`.
                workHex: meta.work.toHexString()
            ))
        }
        //: persist the weight/linkage of blocks whose bodies have been
        // pruned (present in `weightIndex` but absent from `hashToBlock`). Without
        // this they would be re-derived from live bodies only and lost across a
        // restart, holing the fork-choice weight index.
        var pruned: [PersistedBlockMeta] = []
        for (hash, entry) in weightIndex where hashToBlock[hash] == nil {
            let targetHex: String? = entry.work > UInt256.zero
                ? (UInt256.max / entry.work).toHexString()
                : nil
            pruned.append(PersistedBlockMeta(
                blockHash: hash,
                parentBlockHash: entry.parentBlockHash,
                blockHeight: entry.blockHeight,
                parentChainBlocks: [:],
                childHashes: entry.childHashes,
                target: targetHex,
                // Carry the pruned block's timestamp so the validation header index
                // (median-time-past + retarget window) survives a restart, the same
                // way the weight/linkage above survives for fork choice. The walk
                // back through pruned ancestors on restore reads these.
                timestamp: blockTimestamps[hash],
                cumulativeWork: entry.cumulativeWork.toHexString(),
                subtreeWeight: entry.subtreeWeight.toHexString(),
                workHex: entry.work.toHexString()
            ))
        }
        return PersistedChainState(
            chainTip: chainTip,
            tipPostStateCID: tipSnapshot?.postStateCID,
            tipPrevStateCID: tipSnapshot?.prevStateCID,
            tipSpecCID: tipSnapshot?.specCID,
            tipTarget: tipSnapshot?.target.toHexString(),
            tipNextTarget: tipSnapshot?.nextTarget.toHexString(),
            tipHeight: tipSnapshot?.tipHeight,
            tipTimestamp: tipSnapshot?.timestamp,
            mainChainHashes: Array(mainChainHashes),
            blocks: blocks,
            prunedWeightIndex: pruned,
            parentChainMap: parentChainBlockHashToBlockHash,
            missingBlockHashes: Array(missingBlockHashes)
        )
    }

    static func restore(
        from persisted: PersistedChainState,
        retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE
    ) throws -> ChainState {
        // / CFC-A3 (fail closed at the restore choke point): a corrupt
        // persisted target — or a pruned-but-retained weight-index entry whose
        // non-recomputable `cumulativeWork` / `subtreeWeight` is missing or
        // undecodable — would otherwise be mapped to `UInt256.zero` by
        // `cumulativeWorkByHash()` / `weightIndexEntries(fromPruned:)`, silently
        // holing the fork-choice weight index (a heavier branch looks weightless).
        // Reject the snapshot here so the node reindexes/halts rather than restoring
        // a downgraded tip; missing weight ≠ "zero", it = "this index is incomplete".
        guard !persisted.hasUndecodableTarget() else {
            throw ChainStateRestoreError.corruptWeightIndex
        }
        var hashToBlock: [String: BlockMeta] = [:]
        var indexToBlockHash: [UInt64: Set<String>] = [:]
        var blockTimestamps: [String: Int64] = [:]
        let cumByHash = persisted.cumulativeWorkByHash()
        for block in persisted.blocks {
            let target = block.target.flatMap { UInt256($0, radix: 16) } ?? UInt256.zero
            //: recover the block's own work from the directly-persisted
            // `workHex` so it is byte-identical to the live value (fork choice must
            // not depend on restart history). The `hasUndecodableTarget()` guard above
            // already rejected a present-but-undecodable `workHex`, so here a non-nil
            // `workHex` decodes; a `nil` `workHex` is a pre-upgrade snapshot, which
            // falls back to the (lossy, but unavoidable for legacy data) target-derived
            // work, matching the historical restore behavior.
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
            hashToBlock[block.blockHash] = meta
            indexToBlockHash[block.blockHeight, default: Set()].insert(block.blockHash)
            if let ts = block.timestamp {
                blockTimestamps[block.blockHash] = ts
            }
        }
        var snapshot: TipBlockSnapshot? = nil
        if let postStateCID = persisted.tipPostStateCID,
           let prevStateCID = persisted.tipPrevStateCID,
           let specCID = persisted.tipSpecCID,
           let targetHex = persisted.tipTarget,
           let nextTargetHex = persisted.tipNextTarget,
           let index = persisted.tipHeight,
           let timestamp = persisted.tipTimestamp,
           let target = UInt256(targetHex, radix: 16),
           let nextTarget = UInt256(nextTargetHex, radix: 16) {
            snapshot = TipBlockSnapshot(
                postStateCID: postStateCID,
                prevStateCID: prevStateCID,
                specCID: specCID,
                target: target,
                nextTarget: nextTarget,
                tipHeight: index,
                timestamp: timestamp
            )
        }
        return try ChainState(
            chainTip: persisted.chainTip,
            mainChainHashes: Set(persisted.mainChainHashes),
            indexToBlockHash: indexToBlockHash,
            hashToBlock: hashToBlock,
            parentChainBlockHashToBlockHash: persisted.parentChainMap,
            retentionDepth: retentionDepth,
            blockTimestamps: blockTimestamps,
            tipSnapshot: snapshot,
            //: carry the retained weight/linkage of body-pruned blocks into
            // the restored fork-choice weight index (init's choke point fails closed
            // on a corrupt required weight, complementing the early guard above).
            prunedWeightIndex: persisted.prunedWeightIndex
        )
    }
}

public actor ChainStatePersister {
    private let path: URL

    public init(storagePath: URL, directory: String) {
        self.path = storagePath
            .appendingPathComponent(directory)
            .appendingPathComponent("chain_state.json")
    }

    public func save(_ state: PersistedChainState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: path)
    }

    public func load() throws -> PersistedChainState? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(PersistedChainState.self, from: data)
    }

    public func delete() throws {
        try? FileManager.default.removeItem(at: path)
    }
}
