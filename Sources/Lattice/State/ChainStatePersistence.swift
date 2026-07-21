import UInt256

public enum ChainStateRestoreError: Error, Sendable, Equatable {
    case corruptConsensusGraph
    case missingBlockFact
    case missingInheritedWorkSnapshot
}

/// Node-persistable projection of one chain's local consensus state and the
/// inherited revision under which its canonical cache was derived.
public struct PersistedChainState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: UInt16 = 3

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
                  $0.work > .zero && CIDIdentity.isCanonical($0.id)
              }) else { return nil }
        return WorkMeasure(workContributions).total
    }

    var hasValidEncoding: Bool {
        let snapshotPayload = [
            target != nil,
            postStateCID != nil,
            prevStateCID != nil,
            specCID != nil,
            nextTarget != nil,
        ]
        let hasNoSnapshot = snapshotPayload.allSatisfy { !$0 }
        let hasCompleteSnapshot = timestamp != nil
            && snapshotPayload.allSatisfy { $0 }
        guard decodedWork != nil,
              CIDIdentity.isCanonical(blockHash),
              parentBlockHash.map(CIDIdentity.isCanonical) ?? true,
              childHashes.allSatisfy(CIDIdentity.isCanonical),
              postStateCID.map(CIDIdentity.isCanonical) ?? true,
              prevStateCID.map(CIDIdentity.isCanonical) ?? true,
              specCID.map(CIDIdentity.isCanonical) ?? true,
              hasNoSnapshot || hasCompleteSnapshot else { return false }
        if let target, UInt256(target, radix: 16) == nil { return false }
        if let nextTarget, UInt256(nextTarget, radix: 16) == nil { return false }
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

    let projectionBlocks = blocks.mapValues { block in
        BlockMeta(
            blockHash: block.blockHash,
            parentBlockHash: block.parentBlockHash,
            blockHeight: block.blockHeight,
            childHashes: block.childHashes,
            workContributions: block.workContributions
        )
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
                target: snapshot?.target.toHexString(),
                timestamp: blockTimestamps[meta.blockHash],
                postStateCID: snapshot?.postStateCID,
                prevStateCID: snapshot?.prevStateCID,
                specCID: snapshot?.specCID,
                nextTarget: snapshot?.nextTarget.toHexString()
            )
        }
        let retainedInheritedSnapshot = inheritedWorkSnapshot
        return PersistedChainState(
            revision: mutationGeneration,
            inheritedWorkRevision: retainedInheritedSnapshot?.revision,
            inheritedWorkSnapshot: retainedInheritedSnapshot,
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
        } else if persisted.inheritedWorkRevision != nil {
            throw ChainStateRestoreError.missingInheritedWorkSnapshot
        } else {
            retainedInherited = liveInherited
        }
        let inherited = retainedInherited ?? .zero
        let validInherited = inherited.entriesByBlock.allSatisfy { blockHash, measure in
            CIDIdentity.isCanonical(blockHash) && measure.entries.allSatisfy { grindID, work in
                CIDIdentity.isCanonical(grindID) && work > .zero
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
            guard block.decodedWork != nil else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            let meta = BlockMeta(
                blockHash: block.blockHash,
                parentBlockHash: block.parentBlockHash,
                blockHeight: block.blockHeight,
                childHashes: block.childHashes,
                workContributions: block.workContributions
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
