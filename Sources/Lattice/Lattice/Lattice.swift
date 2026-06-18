import cashew
import UInt256

public enum BlockProcessingResult: Sendable {
    case accepted(StateDiff, materializedPostState: LatticeState? = nil)
    case rejected
    case deferred

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    public var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }

    public var isDeferred: Bool {
        if case .deferred = self { return true }
        return false
    }

    public var stateDiff: StateDiff {
        if case let .accepted(diff, materializedPostState: _) = self { return diff }
        return .empty
    }

    public var materializedPostState: LatticeState? {
        if case let .accepted(_, materializedPostState: materializedPostState) = self {
            return materializedPostState
        }
        return nil
    }
}

public actor Lattice {
    public let nexus: ChainLevel

    /// (production fetch trigger): the node wires this to hand
    /// `processBlockHeader` the real sync transport for a level (a `ChainSyncer`
    /// to a peer holding the heavier branch's bodies), plus the per-refetch body
    /// cap. When a submission is valid but does NOT extend/reorg the main chain —
    /// the non-extending choke point where a held strictly-heavier subtree may now
    /// exist — `processBlockHeader` asks this for a syncer and drives
    /// `backfillHeldHeavierSubtree` so the node refetches the missing interior
    /// bodies and fork choice converges. `nil` (or no provider) ⇒ no backfill
    /// (e.g. a node with no peer/transport yet); the hold simply persists until a
    /// later submission or a periodic sync pass observes it.
    private var backfillSyncerProvider: (@Sendable (ChainLevel) async -> (syncer: ChainSyncer, maxBodies: UInt64)?)?

    ///: optional diagnostic sink for a FAILED body-backfill at the
    /// non-extending choke point. The backfill failing must NOT adopt or downgrade
    /// (fail closed), but the failure type still needs to be observable — otherwise a
    /// persistent forgery attack on the choke point (e.g. repeated
    /// `SyncError.contentMismatch`) retries silently on every non-extending submission
    /// with no signal. The node wires this to its log/metrics; `nil` ⇒ no observation.
    private var backfillFailureObserver: (@Sendable (Error) -> Void)?

    public init(nexus: ChainLevel) {
        self.nexus = nexus
    }

    /// Install the body-backfill transport provider (see `backfillSyncerProvider`).
    public func setBackfillSyncerProvider(
        _ provider: (@Sendable (ChainLevel) async -> (syncer: ChainSyncer, maxBodies: UInt64)?)?
    ) {
        backfillSyncerProvider = provider
    }

    /// Install the body-backfill failure observer (see `backfillFailureObserver`).
    public func setBackfillFailureObserver(_ observer: (@Sendable (Error) -> Void)?) {
        backfillFailureObserver = observer
    }

    /// Process a block header and update chain state.
    ///
    /// - `skipValidation`: Skip structural and state validation. Use for self-mined
    ///   blocks where BlockBuilder already computed and verified the state transition.
    ///   The parent's state trie may not be locally cached after a stateOnly sync,
    ///   so running validatePostState on own-mined blocks would fail unnecessarily.
    ///
    /// Gossip callers should relay the nexus block volume to peers immediately
    /// after PoW check, before calling this — so block data propagates through
    /// the network while local state validation runs.
    /// Process a block header for this chain.
    ///
    /// - Parameter rootHash: The PoW root hash used for target validation.
    ///   For the root chain (Nexus/Bitcoin), pass `nil` — the block's own hash
    ///   is used. For child chains running as a per-process node (Phase 3),
    ///   pass the parent chain block's `proofOfWorkHash()` — this is the
    ///   hash that was actually mined and seals the embedded child block.
    ///   The root hash propagates from the absolute root of the hierarchy
    ///   (today Nexus, eventually Bitcoin) to all descendant chains.
    /// `beforeCommit`, when provided, runs AFTER the block passes full validation
    /// but BEFORE the in-memory chain tip advances (`submitBlock`). It is the
    /// durable-store-then-commit hook (Bitcoin/geth ordering): the caller persists
    /// the validated block + its state diff durably here and returns `true` only
    /// once that is confirmed. If it returns `false` (e.g. a transient storage
    /// outage), the commit is aborted and the result is `.deferred` — the in-memory
    /// tip never advances past what is durable, so a failed durable write can never
    /// leave the chain ahead of storage, and the block is simply retried later.
    public func processBlockHeader(_ blockHeader: BlockHeader, fetcher: Fetcher, skipValidation: Bool = false, rootHash: UInt256? = nil, chainPath: [String]? = nil, beforeCommit: (@Sendable (Block, StateDiff, LatticeState?) async -> Bool)? = nil) async -> BlockProcessingResult {
        if await nexus.chain.contains(blockHash: blockHeader.rawCID) {
            return .rejected
        }
        let resolvedBlock: Block
        do {
            guard let block = try await blockHeader.resolveBlockContent(fetcher: fetcher).node else {
                return .deferred
            }
            resolvedBlock = block
        } catch {
            return .deferred
        }

        // rootHash: externally-provided when this node is a per-process child chain.
        // nil means use the block's own hash (correct for the root chain).
        let nexusHash = rootHash ?? resolvedBlock.proofOfWorkHash()
        let meetsPoW = skipValidation || resolvedBlock.validateProofOfWork(nexusHash: nexusHash)
        guard meetsPoW else { return .rejected }

        var nexusAccepted = false
        var nexusDiff = StateDiff.empty
        var nexusMaterializedPostState: LatticeState?
        let blockValid: Bool
        if skipValidation {
            blockValid = true
        } else {
            do {
                let result = try await resolvedBlock.validateNexus(fetcher: fetcher, chain: nexus.chain, chainPath: chainPath)
                blockValid = result.0
                nexusDiff = result.1
                nexusMaterializedPostState = result.2
            } catch {
                return .deferred
            }
        }
        if blockValid {
            // Durable-store-then-commit: persist before the tip advances. A false
            // return aborts the commit (no divergence) and the block is retried.
            if let beforeCommit,
               !(await beforeCommit(resolvedBlock, nexusDiff, nexusMaterializedPostState)) {
                return .deferred
            }
            let result = await nexus.chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: blockHeader,
                block: resolvedBlock
            )
            if let reorg = result.reorganization {
                await nexus.propagateReorgToChildren(reorg: reorg)
            }
            nexusAccepted = result.extendsMainChain || result.reorganization != nil

            // (the production fetch trigger): the block was accepted as a
            // VALID side block that did not extend or reorg the main chain — the
            // non-extending choke point where it may have completed a strictly-heavier
            // subtree whose interior bodies the node lacks (a CFC-A1 hold). Drive the
            // wired backfill so the node refetches those bodies over the real transport
            // and fork choice converges. No provider/syncer ⇒ no-op (the hold persists
            // for a later submission or periodic sync to drain).
            if result.addedBlock, !nexusAccepted,
               let provider = backfillSyncerProvider,
               let (syncer, maxBodies) = await provider(nexus) {
                // `backfillHeldHeavierSubtree` refetches+validates the missing bodies,
                // submits them through the same fork-choice path, and propagates any
                // resulting reorg to child chains itself. A successful backfill means
                // the heavier branch was adopted, so report the block as accepted.
                //
                // Fail CLOSED but not SILENT: an explicit catch keeps `nexusAccepted`
                // false on any backfill failure (no adoption, no downgrade — the hold
                // simply persists), while surfacing the failure type to the observer so
                // a persistent forgery attack on this choke point (e.g. repeated
                // `SyncError.contentMismatch`) is diagnosable rather than invisible.
                do {
                    if try await nexus.backfillHeldHeavierSubtree(syncer: syncer, maxBodies: maxBodies) {
                        nexusAccepted = true
                    }
                } catch {
                    backfillFailureObserver?(error)
                }
            }
        }

        return nexusAccepted ? .accepted(nexusDiff, materializedPostState: nexusMaterializedPostState) : .rejected
    }

    /// `source:` overload of
    /// ``processBlockHeader(_:fetcher:skipValidation:rootHash:chainPath:beforeCommit:)``.
    /// Wraps the batched cashew ``ContentSource`` in a single ``CoalescingFetcher``
    /// and delegates to the `fetcher:` version unchanged. The one coalescer is
    /// threaded through both the content resolution and the full validation walk,
    /// so the accept/commit outcome is byte-identical to the per-CID path while
    /// content fetches collapse into batched requests. This lets a downstream node
    /// drive consensus processing from a `ContentSource` without synthesizing a
    /// per-CID `Fetcher`.
    public func processBlockHeader(_ blockHeader: BlockHeader, source: any ContentSource, skipValidation: Bool = false, rootHash: UInt256? = nil, chainPath: [String]? = nil, beforeCommit: (@Sendable (Block, StateDiff, LatticeState?) async -> Bool)? = nil) async -> BlockProcessingResult {
        await processBlockHeader(blockHeader, fetcher: CoalescingFetcher(source), skipValidation: skipValidation, rootHash: rootHash, chainPath: chainPath, beforeCommit: beforeCommit)
    }
}

public actor ChainLevel {
    public let chain: ChainState
    public private(set) var children: [String: ChainLevel]

    public init(chain: ChainState, children: [String: ChainLevel]) {
        self.chain = chain
        self.children = children
    }

    // MARK: - Child Chain Management

    public func subscribe(to directory: String, genesisBlock: Block, retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE) {
        guard children[directory] == nil else { return }
        let childChain = ChainState.fromGenesis(block: genesisBlock, retentionDepth: retentionDepth)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        children[directory] = childLevel
    }

    public func restoreChildChain(directory: String, level: ChainLevel) {
        guard children[directory] == nil else { return }
        children[directory] = level
    }

    public func childDirectories() -> [String] {
        Array(children.keys)
    }

    /// DFS-walk this level and all descendants, returning the level whose
    /// directory matches the target plus the chain path from the receiver
    /// down to (and including) that level. `chainPath` is passed in by the
    /// caller to anchor the path at the correct root (e.g. `[nexusDir]` when
    /// starting from nexus).
    public func findLevel(directory target: String, chainPath: [String]) async -> (level: ChainLevel, chainPath: [String])? {
        if chainPath.last == target { return (self, chainPath) }
        for (childDir, childLevel) in children {
            if childDir == target {
                return (childLevel, chainPath + [childDir])
            }
            if let hit = await childLevel.findLevel(directory: target, chainPath: chainPath + [childDir]) {
                return hit
            }
        }
        return nil
    }

    /// DFS walk collecting every descendant's directory and full chain path.
    /// `chainPath` is the path to this receiver; callers pass e.g. `[nexusDir]`
    /// to anchor paths at the nexus.
    public func collectAllLevels(chainPath: [String]) async -> [(level: ChainLevel, chainPath: [String])] {
        var result: [(level: ChainLevel, chainPath: [String])] = [(self, chainPath)]
        for (childDir, childLevel) in children {
            let sub = await childLevel.collectAllLevels(chainPath: chainPath + [childDir])
            result.append(contentsOf: sub)
        }
        return result
    }

    func propagateReorgToChildren(reorg: Reorganization) async {
        await withTaskGroup(of: Void.self) { group in
            for (_, child) in children {
                group.addTask { [reorg] in
                    if let childReorg = await child.chain.propagateParentReorg(reorg: reorg) {
                        await child.propagateReorgToChildren(reorg: childReorg)
                    }
                }
            }
        }
    }
}
