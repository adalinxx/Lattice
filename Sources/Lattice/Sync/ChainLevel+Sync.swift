import Foundation
import cashew

/// Node-owned durable preparation for a verified sync projection. The node may
/// retain every body, just the chosen frontier, or an external snapshot; Lattice
/// only requires a positive durable receipt before exposing the replacement.
public typealias ChainSyncPreparer = @Sendable (SyncResult) async -> ChainCommitPreparation

extension ChainLevel {
    /// Build a syncer using this level's fixed identity and root policy.
    public func makeSyncer(
        fetcher: Fetcher,
        store: @Sendable @escaping (String, Data) async -> Void,
        fetchTimeout: Duration = .seconds(30),
        anchoredPoWValidator: (@Sendable (Block) async -> Bool)? = nil,
        validateBlockConsensus: Bool = true
    ) async throws -> ChainSyncer {
        guard let genesisBlockHash = await chain.getMainChainBlockHash(atIndex: 0) else {
            throw SyncError.emptyChain
        }
        return ChainSyncer(
            fetcher: fetcher,
            store: store,
            genesisBlockHash: genesisBlockHash,
            rootPolicy: await chain.getRootPolicy(),
            chainPath: admissionContext.chainPath,
            retentionDepth: await chain.getRetentionDepth(),
            fetchTimeout: fetchTimeout,
            anchoredPoWValidator: anchoredPoWValidator,
            validateBlockConsensus: validateBlockConsensus
        )
    }

    /// Apply one verified linear result. Child-root forests are incrementally
    /// admitted, never replaced by a linear snapshot.
    public func applySync(
        result: SyncResult,
        retentionDepth: UInt64,
        prepare: @escaping ChainSyncPreparer
    ) async throws {
        try await preflightLinearSyncTree()
        guard result.persisted.rootPolicy != .childRootForest else {
            throw SyncError.forestRequiresIncrementalAdmission
        }
        _ = try ChainState.restore(
            from: result.persisted,
            retentionDepth: retentionDepth,
            rootPolicy: .singleGenesis
        )

        let generation = await chain.currentMutationGeneration()
        try await prepareSync(result, prepare: prepare)
        let applied = try await chain.resetFromIfUnchanged(
            result.persisted,
            retentionDepth: retentionDepth,
            expectedMutationGeneration: generation,
            tipBlock: nil
        )
        guard applied else {
            throw SyncError.staleChainState
        }
    }

    /// Reset a linear level to its genesis only after every descendant proves it
    /// cannot be a child-root forest. This prevents a parent reset before a child
    /// rejects the operation.
    public func resetAllToGenesis(
        retentionDepth: UInt64,
        prepare: @escaping ChainSyncPreparer
    ) async throws {
        try await preflightLinearSyncTree()
        guard let genesisHash = await chain.getMainChainBlockHash(atIndex: 0),
              let genesisMeta = await chain.getConsensusBlock(hash: genesisHash)
        else {
            return
        }

        let snapshot = await chain.getBlockSnapshot(hash: genesisHash)
        let genesis = PersistedBlockMeta(
            blockHash: genesisHash,
            parentBlockHash: nil,
            blockHeight: 0,
            parentChainBlocks: genesisMeta.parentChainBlocks,
            childHashes: [],
            target: snapshot?.target.toHexString(),
            timestamp: snapshot?.timestamp,
            cumulativeWork: genesisMeta.cumulativeWork.toHexString(),
            workHex: genesisMeta.work.toHexString(),
            postStateCID: snapshot?.postStateCID,
            prevStateCID: snapshot?.prevStateCID,
            specCID: snapshot?.specCID,
            nextTarget: snapshot?.nextTarget.toHexString()
        )
        let persisted = PersistedChainState(
            chainTip: genesisHash,
            tipPostStateCID: genesis.postStateCID,
            tipPrevStateCID: genesis.prevStateCID,
            tipSpecCID: genesis.specCID,
            tipTarget: genesis.target,
            tipNextTarget: genesis.nextTarget,
            tipHeight: 0,
            tipTimestamp: genesis.timestamp,
            mainChainHashes: [genesisHash],
            blocks: [genesis],
            parentChainMap: [:],
            missingBlockHashes: [],
            rootPolicy: .singleGenesis
        )
        let result = SyncResult(
            persisted: persisted,
            tipBlockHash: genesisHash,
            tipBlockHeight: 0,
            cumulativeWork: genesisMeta.cumulativeWork
        )
        let generation = await chain.currentMutationGeneration()
        try await prepareSync(result, prepare: prepare)
        let applied = try await chain.resetFromIfUnchanged(
            persisted,
            retentionDepth: retentionDepth,
            expectedMutationGeneration: generation,
            tipBlock: nil
        )
        guard applied else {
            throw SyncError.staleChainState
        }
    }

    private func preflightLinearSyncTree() async throws {
        guard await chain.getRootPolicy() == .singleGenesis else {
            throw SyncError.forestRequiresIncrementalAdmission
        }
        for child in children.values {
            try await child.preflightLinearSyncTree()
        }
    }
}

private func prepareSync(
    _ result: SyncResult,
    prepare: @escaping ChainSyncPreparer
) async throws {
    switch await prepare(result) {
    case .ready:
        return
    case .unavailable:
        throw SyncError.durablePreparationUnavailable
    case .storageFailed:
        throw SyncError.durablePreparationFailed
    }
}
