import UInt256

public enum ChainStateRestoreError: Error, Sendable, Equatable {
    case corruptConsensusGraph
}

/// Node-persistable projection of one chain's consensus state.
public struct PersistedChainState: Codable, Sendable {
    public let chainTip: String
    public let mainChainHashes: [String]
    public let blocks: [PersistedBlockMeta]
    public let prunedBlocks: [PersistedBlockMeta]

    public init(
        chainTip: String,
        mainChainHashes: [String],
        blocks: [PersistedBlockMeta],
        prunedBlocks: [PersistedBlockMeta] = []
    ) {
        self.chainTip = chainTip
        self.mainChainHashes = mainChainHashes
        self.blocks = blocks
        self.prunedBlocks = prunedBlocks
    }
}

public struct PersistedBlockMeta: Codable, Sendable {
    public let blockHash: String
    public let parentBlockHash: String?
    public let blockHeight: UInt64
    public let childHashes: [String]
    public let createdDiffs: [String: Int]
    public let removedDiffs: [String: Int]
    public let workContributions: [VerifiedWorkContribution]
    public let cumulativeWork: String
    public let subtreeWeight: String?
    public let target: String?
    public let timestamp: Int64?
    public let postStateCID: String?
    public let prevStateCID: String?
    public let specCID: String?
    public let nextTarget: String?

    public init(
        blockHash: String,
        parentBlockHash: String?,
        blockHeight: UInt64,
        childHashes: [String],
        createdDiffs: [String: Int] = [:],
        removedDiffs: [String: Int] = [:],
        workContributions: [VerifiedWorkContribution],
        cumulativeWork: String,
        subtreeWeight: String? = nil,
        target: String? = nil,
        timestamp: Int64? = nil,
        postStateCID: String? = nil,
        prevStateCID: String? = nil,
        specCID: String? = nil,
        nextTarget: String? = nil
    ) {
        self.blockHash = blockHash
        self.parentBlockHash = parentBlockHash
        self.blockHeight = blockHeight
        self.childHashes = childHashes
        self.createdDiffs = createdDiffs
        self.removedDiffs = removedDiffs
        self.workContributions = workContributions
        self.cumulativeWork = cumulativeWork
        self.subtreeWeight = subtreeWeight
        self.target = target
        self.timestamp = timestamp
        self.postStateCID = postStateCID
        self.prevStateCID = prevStateCID
        self.specCID = specCID
        self.nextTarget = nextTarget
    }
}

private extension PersistedBlockMeta {
    var decodedWork: UInt256? {
        guard !workContributions.isEmpty,
              Set(workContributions.map(\.id)).count == workContributions.count,
              workContributions.allSatisfy({ $0.work > .zero }) else { return nil }
        return workContributions.reduce(.zero) {
            saturatingWorkSum($0, $1.work)
        }
    }

    var hasValidEncoding: Bool {
        guard decodedWork != nil,
              UInt256(cumulativeWork, radix: 16) != nil else { return false }
        if let target, UInt256(target, radix: 16) == nil { return false }
        if let subtreeWeight, UInt256(subtreeWeight, radix: 16) == nil { return false }
        return true
    }
}

private func hasValidConsensusGraph(_ persisted: PersistedChainState) -> Bool {
    let blocks = Dictionary(
        uniqueKeysWithValues: (persisted.blocks + persisted.prunedBlocks)
            .map { ($0.blockHash, $0) }
    )
    guard blocks[persisted.chainTip] != nil else { return false }

    for block in blocks.values {
        if Set(block.childHashes).count != block.childHashes.count { return false }
        if block.parentBlockHash == nil, block.blockHeight != 0 { return false }
        for childHash in block.childHashes {
            let (expectedHeight, overflow) = block.blockHeight.addingReportingOverflow(1)
            guard let child = blocks[childHash],
                  !overflow,
                  child.parentBlockHash == block.blockHash,
                  child.blockHeight == expectedHeight else { return false }
        }
        if let parentHash = block.parentBlockHash,
           let parent = blocks[parentHash],
           !parent.childHashes.contains(block.blockHash) {
            return false
        }
    }

    var cumulativeMemo: [String: UInt256] = [:]
    var cumulativeVisiting = Set<String>()
    func cumulativeWork(_ hash: String) -> UInt256? {
        if let work = cumulativeMemo[hash] { return work }
        guard cumulativeVisiting.insert(hash).inserted,
              let block = blocks[hash],
              let ownWork = block.decodedWork,
              let persistedWork = UInt256(block.cumulativeWork, radix: 16)
        else { return nil }
        let parentWork: UInt256
        if let parentHash = block.parentBlockHash, blocks[parentHash] != nil {
            guard let work = cumulativeWork(parentHash) else { return nil }
            parentWork = work
        } else {
            parentWork = .zero
        }
        let work = saturatingWorkSum(parentWork, ownWork)
        cumulativeVisiting.remove(hash)
        guard work == persistedWork else { return nil }
        cumulativeMemo[hash] = work
        return work
    }

    var subtreeMemo: [String: UInt256] = [:]
    var subtreeVisiting = Set<String>()
    func subtreeWork(_ hash: String) -> UInt256? {
        if let work = subtreeMemo[hash] { return work }
        guard subtreeVisiting.insert(hash).inserted,
              let block = blocks[hash],
              var work = block.decodedWork else { return nil }
        for childHash in block.childHashes {
            guard let childWork = subtreeWork(childHash) else { return nil }
            work = saturatingWorkSum(work, childWork)
        }
        subtreeVisiting.remove(hash)
        if let persistedSubtree = block.subtreeWeight {
            guard UInt256(persistedSubtree, radix: 16) == work else { return nil }
        }
        subtreeMemo[hash] = work
        return work
    }

    for hash in blocks.keys {
        guard cumulativeWork(hash) != nil, subtreeWork(hash) != nil else { return false }
    }

    var canonicalPath = Set<String>()
    var cursor: String? = persisted.chainTip
    while let hash = cursor {
        guard canonicalPath.insert(hash).inserted,
              let block = blocks[hash] else { return false }
        cursor = block.parentBlockHash
    }
    guard canonicalPath == Set(persisted.mainChainHashes),
          let canonicalRoot = canonicalPath.first(where: {
              blocks[$0]?.parentBlockHash == nil
          }),
          let canonicalRootWork = subtreeMemo[canonicalRoot]
    else { return false }

    var canonicalChild: [String: String] = [:]
    for hash in canonicalPath {
        if let parent = blocks[hash]?.parentBlockHash {
            canonicalChild[parent] = hash
        }
    }
    func selectedChild(of hash: String) -> String? {
        guard let children = blocks[hash]?.childHashes, !children.isEmpty else {
            return nil
        }
        let weighted = children.compactMap { child -> (String, UInt256)? in
            guard let work = subtreeMemo[child] else { return nil }
            return (child, work)
        }
        guard weighted.count == children.count,
              let bestWork = weighted.map(\.1).max() else { return nil }
        let tied = weighted.filter { $0.1 == bestWork }.map(\.0).sorted()
        if let incumbent = canonicalChild[hash], tied.contains(incumbent) {
            return incumbent
        }
        return tied.first
    }

    func selectedPath(from start: String) -> [String]? {
        var path: [String] = []
        var visited = Set<String>()
        var current: String? = start
        while let hash = current {
            guard visited.insert(hash).inserted, blocks[hash] != nil else { return nil }
            path.append(hash)
            current = selectedChild(of: hash)
        }
        return path
    }

    let rootWeights = blocks.values
        .filter { $0.parentBlockHash == nil }
        .compactMap { subtreeMemo[$0.blockHash] }
    guard rootWeights.count == blocks.values.filter({ $0.parentBlockHash == nil }).count,
          canonicalRootWork == rootWeights.max(),
          let selected = selectedPath(from: canonicalRoot),
          selected.last == persisted.chainTip,
          Set(selected) == canonicalPath else { return false }
    return true
}

public extension ChainState {
    func persist() -> PersistedChainState {
        func persistedMeta(_ meta: BlockMeta) -> PersistedBlockMeta {
            let snapshot = tipSnapshotsByHash[meta.blockHash]
            return PersistedBlockMeta(
                blockHash: meta.blockHash,
                parentBlockHash: meta.parentBlockHash,
                blockHeight: meta.blockHeight,
                childHashes: meta.childHashes,
                createdDiffs: meta.createdDiffs,
                removedDiffs: meta.removedDiffs,
                workContributions: Array(meta.workContributions.values).sorted { $0.id < $1.id },
                cumulativeWork: meta.cumulativeWork.toHexString(),
                subtreeWeight: meta.subtreeWeight.toHexString(),
                target: snapshot?.target.toHexString(),
                timestamp: blockTimestamps[meta.blockHash],
                postStateCID: snapshot?.postStateCID,
                prevStateCID: snapshot?.prevStateCID,
                specCID: snapshot?.specCID,
                nextTarget: snapshot?.nextTarget.toHexString()
            )
        }
        var blocks: [PersistedBlockMeta] = []
        var pruned: [PersistedBlockMeta] = []
        for meta in hashToBlock.values {
            if meta.stateDiff != nil {
                blocks.append(persistedMeta(meta))
            } else {
                pruned.append(persistedMeta(meta))
            }
        }
        return PersistedChainState(
            chainTip: chainTip,
            mainChainHashes: Array(mainChainHashes).sorted(),
            blocks: blocks.sorted { $0.blockHash < $1.blockHash },
            prunedBlocks: pruned.sorted { $0.blockHash < $1.blockHash }
        )
    }

    static func restore(
        from persisted: PersistedChainState,
        retentionDepth: UInt64 = .max
    ) throws -> ChainState {
        let persistedBlocks = persisted.blocks + persisted.prunedBlocks
        let blockHashes = persistedBlocks.map(\.blockHash)
        let contributionIDs = persistedBlocks.flatMap {
            $0.workContributions.map(\.id)
        }
        guard Set(blockHashes).count == blockHashes.count,
              Set(persisted.mainChainHashes).count == persisted.mainChainHashes.count,
              Set(contributionIDs).count == contributionIDs.count,
              persisted.blocks.allSatisfy(\.hasValidEncoding),
              persisted.prunedBlocks.allSatisfy({
                  $0.hasValidEncoding && $0.subtreeWeight != nil
              }),
              hasValidConsensusGraph(persisted) else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }

        var blocks: [String: BlockMeta] = [:]
        var byHeight: [UInt64: Set<String>] = [:]
        var timestamps: [String: Int64] = [:]
        var snapshots: [String: TipBlockSnapshot] = [:]
        for block in persistedBlocks {
            if let timestamp = block.timestamp { timestamps[block.blockHash] = timestamp }
            if let snapshot = snapshot(from: block) { snapshots[block.blockHash] = snapshot }
        }
        for block in persisted.blocks {
            guard block.decodedWork != nil,
                  let cumulativeWork = UInt256(block.cumulativeWork, radix: 16) else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            let meta = BlockMeta(
                blockHash: block.blockHash,
                parentBlockHash: block.parentBlockHash,
                blockHeight: block.blockHeight,
                childHashes: block.childHashes,
                stateDiff: StateDiff(
                    replaced: block.removedDiffs,
                    created: block.createdDiffs
                ),
                workContributions: block.workContributions,
                cumulativeWork: cumulativeWork
            )
            blocks[block.blockHash] = meta
            byHeight[block.blockHeight, default: []].insert(block.blockHash)
        }
        return try ChainState(
            chainTip: persisted.chainTip,
            mainChainHashes: Set(persisted.mainChainHashes),
            indexToBlockHash: byHeight,
            hashToBlock: blocks,
            retentionDepth: retentionDepth,
            blockTimestamps: timestamps,
            tipSnapshot: snapshots[persisted.chainTip],
            tipSnapshotsByHash: snapshots,
            prunedBlocks: persisted.prunedBlocks
        )
    }
}
