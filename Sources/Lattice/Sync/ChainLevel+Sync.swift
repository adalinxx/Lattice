import Foundation
import cashew
import UInt256

extension ChainLevel {

    /// Apply a sync result to this chain level and recursively apply child
    /// sync results to each child level. This is the chain-level sync
    /// application layer — download (HeaderChain) happens above this at the
    /// network layer, but the state application is purely chain machinery.
    ///
    /// Design constraint: every ChainLevel behaves identically. A child of
    /// nexus applies its sync result the same way nexus does, and triggers its
    /// own children recursively. There are no special cases for the root chain.
    ///
    /// - Parameters:
    ///   - result: The sync result for this chain (built by ChainSyncer).
    ///   - childResults: Sync results for descendant chains, keyed by directory.
    ///     The recursive call extracts its own children's results from this map.
    ///   - fetcher: Used to resolve the tip block to update the tip snapshot.
    ///   - retentionDepth: How many blocks to retain in the persisted chain state.
    public func applySync(
        result: SyncResult,
        childResults: [String: SyncResult],
        fetcher: Fetcher,
        retentionDepth: UInt64
    ) async throws {
        // Fail closed / CFC-A3): a sync result whose persisted weight data
        // is corrupt must NOT be installed with silently zeroed work. `resetFrom`
        // throws on such a snapshot; propagate it so the caller refetches/halts.
        try await chain.resetFrom(result.persisted, retentionDepth: retentionDepth)

        let tipStub = VolumeImpl<Block>(rawCID: result.tipBlockHash, node: nil, encryptionInfo: nil)
        if let tipBlock = try? await tipStub.resolve(fetcher: fetcher).node {
            await chain.updateTipSnapshot(block: tipBlock)
        }

        // Recursively apply each registered child level's result.
        for (childDir, childLevel) in children {
            guard let childResult = childResults[childDir] else { continue }
            try await childLevel.applySync(
                result: childResult,
                childResults: childResults,
                fetcher: fetcher,
                retentionDepth: retentionDepth
            )
        }
    }

    /// (the production fetch trigger / sync choke point): when fork choice
    /// is HELD on a strictly-heavier subtree whose interior bodies are missing
    /// (CFC-A1 no-downgrade + retained weight index), REQUEST the missing
    /// bodies over the real sync transport, VALIDATE them, SUBMIT them into this
    /// chain, and let fork choice CONVERGE on the heavier tip automatically.
    ///
    /// This closes the loop the rest of left open: `backfillSubtree` is the
    /// transport and `heldHeavierBackfillTarget()` is the detector, but nothing in
    /// the chain machinery tied them together — a held heavier subtree would never
    /// actually request its missing bodies. This is that wiring, on the same chain
    /// layer as `applySync`: the node calls it whenever a held heavier branch may
    /// exist (after a block submission that did not extend/reorg the tip, or on a
    /// periodic sync pass).
    ///
    /// Flow:
    ///   1. Ask the chain whether a held heavier subtree exists and which interior
    ///      bodies it must refetch (`heldHeavierBackfillTarget()`). `nil` ⇒ no hold,
    ///      nothing to do.
    ///   2. Refetch + validate those bodies over the REAL `ChainSyncer` transport
    ///      (`backfillSubtree`), wired to skip any body this chain already holds.
    ///   3. Submit each validated body parent-first via the SAME `submitBlock` path
    ///      gossip/mining use, propagating any resulting reorg to child chains
    ///      (mirroring `Lattice.processBlockHeader`). Fork choice converges as the
    ///      heavier branch becomes contiguously body-present.
    ///
    /// Fails closed: `backfillSubtree` throws on a forged (`cid != hash`), invalid,
    /// or unresolvable body, so a held heavier branch is adopted ONLY on fully
    /// validated bodies and a missing/forged body never downgrades the incumbent
    /// (invalid/unavailable ≠ a downgrade). Returns `true` ONLY when fork choice
    /// actually CONVERGED — every fetched body was added by `submitBlock` and the
    /// chain tip is now the targeted heavier tip. Fetching bodies is not adoption:
    /// if any submission is rejected/not-added or the tip did not reach the target,
    /// returns `false` so the hold persists (the caller may re-run to drain a
    /// multi-hop hold) rather than falsely reporting convergence.
    @discardableResult
    public func backfillHeldHeavierSubtree(
        syncer: ChainSyncer,
        maxBodies: UInt64
    ) async throws -> Bool {
        guard let target = await chain.heldHeavierBackfillTarget() else {
            return false
        }

        let backfilled = try await syncer.backfillSubtree(
            heaviestTipCID: target.tipHash,
            // Only refetch bodies this chain does not already hold; the first
            // body-present ancestor terminates the walk (its prefix is local).
            haveBody: { [chain] hash in await chain.contains(blockHash: hash) },
            maxBodies: maxBodies
        )

        // Submit the validated bodies parent-first through the real fork-choice
        // path. Each `submitBlock` runs the same insert/reorg machinery gossip and
        // mining use, so fork choice converges on the heavier tip once the branch is
        // contiguously body-present — and any reorg propagates to child chains.
        //
        // Fetching a body is NOT adoption: a `submitBlock` may add nothing (already
        // present, or rejected). Track whether every submission was actually added so
        // a silent non-adoption cannot be reported as convergence.
        var allAdded = true
        for block in backfilled {
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try VolumeImpl<Block>(node: block),
                block: block
            )
            if let reorg = result.reorganization {
                await propagateReorgToChildren(reorg: reorg)
            }
            if !result.addedBlock { allAdded = false }
        }

        // Converged iff every fetched body was added AND fork choice now actually
        // holds the targeted heavier tip. Fetching/submitting without the tip
        // reaching `target.tipHash` is a non-convergent hold, not success.
        let convergedTip = await chain.getMainChainTip()
        return allAdded && convergedTip == target.tipHash
    }

    /// Reset this chain and all descendant chains to genesis so the sync
    /// application pass rebuilds state from scratch. Mirrors the design
    /// constraint: every level resets itself, then recurses into children.
    public func resetAllToGenesis(retentionDepth: UInt64) async throws {
        if let genesisHash = await chain.getMainChainBlockHash(atIndex: 0) {
            if let genesisMeta = await chain.getConsensusBlock(hash: genesisHash) {
                let genesisPersisted = PersistedChainState(
                    chainTip: genesisHash,
                    tipPostStateCID: nil, tipPrevStateCID: nil, tipSpecCID: nil,
                    tipTarget: nil, tipNextTarget: nil,
                    tipHeight: 0, tipTimestamp: nil,
                    mainChainHashes: [genesisHash],
                    blocks: [PersistedBlockMeta(
                        blockHash: genesisHash,
                        parentBlockHash: nil,
                        blockHeight: 0,
                        parentChainBlocks: genesisMeta.parentChainBlocks,
                        childHashes: genesisMeta.childHashes,
                        // Carry genesis work so the reset chain's cumulative-work
                        // prefix sum starts correct (not zero) and blocks mined
                        // after the reset accumulate from the right base.
                        target: genesisMeta.work > UInt256.zero
                            ? (UInt256.max / genesisMeta.work).toHexString()
                            : nil,
                        cumulativeWork: genesisMeta.cumulativeWork.toHexString()
                    )],
                    parentChainMap: [:],
                    missingBlockHashes: []
                )
                // The genesis snapshot is freshly built from a live, valid block, so
                // the fail-closed restore guard never fires here; propagate the typed
                // error rather than swallowing it (fail closed, not silent).
                try await chain.resetFrom(genesisPersisted, retentionDepth: retentionDepth)
            }
        }
        for (_, childLevel) in children {
            try await childLevel.resetAllToGenesis(retentionDepth: retentionDepth)
        }
    }
}
