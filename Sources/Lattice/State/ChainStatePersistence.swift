import UInt256
import CID

public enum ChainStateRestoreError: Error, Sendable, Equatable {
    case corruptConsensusGraph
    case missingBlockFact
    case missingInheritedWorkSnapshot
}

/// Node-persistable projection of one chain's local consensus state and the
/// inherited revision under which its canonical cache was derived.
public struct PersistedChainState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let revision: UInt64
    public let inheritedWorkRevision: UInt64?
    public let inheritedWorkSnapshot: InheritedWorkSnapshot?
    public let chainTip: String
    public let mainChainHashes: [String]
    public let blocks: [PersistedBlockMeta]

    public init(
        schemaVersion: UInt16 = PersistedChainState.currentSchemaVersion,
        revision: UInt64 = 0,
        inheritedWorkRevision: UInt64? = nil,
        inheritedWorkSnapshot: InheritedWorkSnapshot? = nil,
        chainTip: String,
        mainChainHashes: [String],
        blocks: [PersistedBlockMeta]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.inheritedWorkRevision = inheritedWorkRevision
            ?? inheritedWorkSnapshot?.revision
        self.inheritedWorkSnapshot = inheritedWorkSnapshot
        self.chainTip = chainTip
        self.mainChainHashes = mainChainHashes
        self.blocks = blocks
    }
}

public struct PersistedBlockMeta: Codable, Sendable, Equatable {
    public let blockHash: String
    public let parentBlockHash: String?
    public let blockHeight: UInt64
    public let childHashes: [String]
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
    var decodedWork: WorkSum? {
        guard !workContributions.isEmpty,
              Set(workContributions.map(\.id)).count == workContributions.count,
              workContributions.allSatisfy({
                  $0.work > .zero && (try? CID($0.id)) != nil
              }) else { return nil }
        return WorkMeasure(workContributions).total
    }

    var hasValidEncoding: Bool {
        guard decodedWork != nil,
              WorkSum(hex: cumulativeWork) != nil,
              (try? CID(blockHash)) != nil,
              parentBlockHash.map({ (try? CID($0)) != nil }) ?? true,
              childHashes.allSatisfy({ (try? CID($0)) != nil }),
              postStateCID.map({ (try? CID($0)) != nil }) ?? true,
              prevStateCID.map({ (try? CID($0)) != nil }) ?? true,
              specCID.map({ (try? CID($0)) != nil }) ?? true else { return false }
        if let target, UInt256(target, radix: 16) == nil { return false }
        if let nextTarget, UInt256(nextTarget, radix: 16) == nil { return false }
        if let subtreeWeight, WorkSum(hex: subtreeWeight) == nil { return false }
        return true
    }
}

private struct ConsensusProjection {
    let chainTip: String
    let mainChainHashes: Set<String>
}

private func hasValidConsensusGraph(
    _ persisted: PersistedChainState,
    inherited: InheritedWorkSnapshot,
    projection: inout ConsensusProjection?
) -> Bool {
    let blocks = Dictionary(
        uniqueKeysWithValues: persisted.blocks.map { ($0.blockHash, $0) }
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

    var strongestWorkByGrind: [String: UInt256] = [:]
    for contribution in blocks.values.flatMap(\.workContributions) {
        if contribution.work > (strongestWorkByGrind[contribution.id] ?? .zero) {
            strongestWorkByGrind[contribution.id] = contribution.work
        }
    }
    func ownMeasure(_ block: PersistedBlockMeta) -> WorkMeasure? {
        guard block.decodedWork != nil else { return nil }
        return WorkMeasure(block.workContributions.compactMap { contribution in
            strongestWorkByGrind[contribution.id].map {
                VerifiedWorkContribution(id: contribution.id, work: $0)
            }
        })
    }
    var cumulativeMemo: [String: WorkMeasure] = [:]
    var cumulativeVisiting = Set<String>()
    func cumulativeWork(_ hash: String) -> WorkMeasure? {
        if let work = cumulativeMemo[hash] { return work }
        guard cumulativeVisiting.insert(hash).inserted,
              let block = blocks[hash],
              let ownWork = ownMeasure(block),
              let persistedWork = WorkSum(hex: block.cumulativeWork)
        else { return nil }
        var work = ownWork
        if let parentHash = block.parentBlockHash, blocks[parentHash] != nil {
            guard let parentWork = cumulativeWork(parentHash) else { return nil }
            work.formUnion(parentWork)
        }
        cumulativeVisiting.remove(hash)
        guard work.total == persistedWork else { return nil }
        cumulativeMemo[hash] = work
        return work
    }

    var subtreeMemo: [String: WorkMeasure] = [:]
    var subtreeVisiting = Set<String>()
    func subtreeWork(_ hash: String) -> WorkMeasure? {
        if let work = subtreeMemo[hash] { return work }
        guard subtreeVisiting.insert(hash).inserted,
              let block = blocks[hash],
              var work = ownMeasure(block) else { return nil }
        for childHash in block.childHashes {
            guard let childWork = subtreeWork(childHash) else { return nil }
            work.formUnion(childWork)
        }
        subtreeVisiting.remove(hash)
        if let persistedSubtree = block.subtreeWeight {
            guard WorkSum(hex: persistedSubtree) == work.total else { return nil }
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
          canonicalPath.contains(where: {
              blocks[$0]?.parentBlockHash == nil
          })
    else { return false }

    let projectionBlocks = blocks.mapValues { block in
        BlockMeta(
            blockHash: block.blockHash,
            parentBlockHash: block.parentBlockHash,
            blockHeight: block.blockHeight,
            childHashes: block.childHashes,
            workContributions: block.workContributions
        )
    }
    guard let selected = ChainState.canonicalProjection(
        in: projectionBlocks,
        inherited: inherited
    ) else { return false }
    projection = ConsensusProjection(
        chainTip: selected.chainTip,
        mainChainHashes: selected.mainChainHashes
    )
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
        return PersistedChainState(
            revision: mutationGeneration,
            inheritedWorkRevision: inheritedWorkSnapshot?.revision,
            inheritedWorkSnapshot: inheritedWorkSnapshot,
            chainTip: chainTip,
            mainChainHashes: Array(mainChainHashes).sorted(),
            blocks: hashToBlock.values.map(persistedMeta)
                .sorted { $0.blockHash < $1.blockHash }
        )
    }

    static func restore(
        from persisted: PersistedChainState,
        inheritedWorkProvider: InheritedWorkProvider? = nil
    ) throws -> ChainState {
        let persistedBlocks = persisted.blocks
        let blockHashes = persistedBlocks.map(\.blockHash)
        let cachedInherited = persisted.inheritedWorkSnapshot
        let cachedRevisionMatches = cachedInherited.map {
            Optional($0.revision) == persisted.inheritedWorkRevision
        } ?? true
        guard persisted.schemaVersion == PersistedChainState.currentSchemaVersion,
              cachedRevisionMatches
        else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }

        let liveInherited = inheritedWorkProvider?()
        let retainedInherited: InheritedWorkSnapshot?
        if let cachedInherited {
            retainedInherited = liveInherited.map(cachedInherited.union) ?? cachedInherited
        } else if let previousRevision = persisted.inheritedWorkRevision {
            guard let liveInherited, liveInherited.revision >= previousRevision else {
                throw ChainStateRestoreError.missingInheritedWorkSnapshot
            }
            retainedInherited = liveInherited
        } else {
            retainedInherited = liveInherited
        }
        let inherited = retainedInherited ?? .zero
        let validInherited = inherited.entriesByBlock.allSatisfy { blockHash, measure in
            (try? CID(blockHash)) != nil && measure.entries.allSatisfy { grindID, work in
                (try? CID(grindID)) != nil && work > .zero
            }
        }
        var projection: ConsensusProjection?
        guard Set(blockHashes).count == blockHashes.count,
              Set(persisted.mainChainHashes).count == persisted.mainChainHashes.count,
              validInherited,
              persisted.blocks.allSatisfy(\.hasValidEncoding),
              hasValidConsensusGraph(
                  persisted,
                  inherited: inherited,
                  projection: &projection
              ),
              let projection else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        let projectionChanged = projection.chainTip != persisted.chainTip
            || projection.mainChainHashes != Set(persisted.mainChainHashes)
        let inheritedAdvanced = retainedInherited != cachedInherited
        let revision: UInt64
        if projectionChanged || inheritedAdvanced {
            let (next, overflow) = persisted.revision.addingReportingOverflow(1)
            guard !overflow else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            revision = next
        } else {
            revision = persisted.revision
        }

        var blocks: [String: BlockMeta] = [:]
        var byHeight: [UInt64: Set<String>] = [:]
        var timestamps: [String: Int64] = [:]
        var snapshots: [String: TipBlockSnapshot] = [:]
        for block in persistedBlocks {
            if let timestamp = block.timestamp { timestamps[block.blockHash] = timestamp }
            if let snapshot = snapshot(from: block) { snapshots[block.blockHash] = snapshot }
        }
        for block in persistedBlocks {
            guard block.decodedWork != nil,
                  let cumulativeWork = WorkSum(hex: block.cumulativeWork) else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            let meta = BlockMeta(
                blockHash: block.blockHash,
                parentBlockHash: block.parentBlockHash,
                blockHeight: block.blockHeight,
                childHashes: block.childHashes,
                workContributions: block.workContributions,
                cumulativeWork: cumulativeWork
            )
            blocks[block.blockHash] = meta
            byHeight[block.blockHeight, default: []].insert(block.blockHash)
        }
        return try ChainState(
            chainTip: projection.chainTip,
            mainChainHashes: projection.mainChainHashes,
            indexToBlockHash: byHeight,
            hashToBlock: blocks,
            blockTimestamps: timestamps,
            tipSnapshot: snapshots[projection.chainTip],
            tipSnapshotsByHash: snapshots,
            mutationGeneration: revision,
            inheritedWorkProvider: inheritedWorkProvider,
            inheritedWorkSnapshot: retainedInherited
        )
    }
}
