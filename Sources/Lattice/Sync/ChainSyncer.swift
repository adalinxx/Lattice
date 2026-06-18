
import Foundation
import cashew
import UInt256

public enum SyncStrategy: Sendable {
    case full
    case snapshot
    case headersFirst
    case stateOnly
}

public enum SyncError: Error, Sendable {
    case invalidBlock(UInt64)
    /// The fetched bytes did not hash to the CID they were requested under —
    /// a peer served content that does not match the claimed block hash.
    case contentMismatch(UInt64)
    /// A requested body could not be fetched/decoded (peer pruned it, transport
    /// timed out, or bytes were undecodable). Distinct from `invalidBlock`:
    /// unavailable ≠ invalid. A backfill that hits this has NOT proven the branch
    /// bad — it must keep holding the incumbent and refetch later, never reclassify
    /// missing data as an invalid body. Carries the walk depth at which it occurred.
    case bodyUnavailable(UInt64)
    case invalidPoW(UInt64)
    case invalidStateRoot(UInt64)
    case genesisMismatch
    case cancelled
    case emptyChain
    case insufficientWork
    /// A bounded body-backfill walk exceeded its `maxBodies` depth guard. Distinct
    /// from `insufficientWork` (a PoW/weight invariant): this is a LOCAL refusal to
    /// refetch an over-deep advertised subtree, not a statement about its work.
    case backfillTooDeep
}

public struct SyncResult: Sendable {
    public let persisted: PersistedChainState
    public let tipBlockHash: String
    public let tipBlockHeight: UInt64
    public let cumulativeWork: UInt256
}

public enum SyncFetchError: Error, Sendable {
    case timeout
}

public actor ChainSyncer {
    private let fetcher: Fetcher
    private let storeFn: @Sendable (String, Data) async -> Void
    private let genesisBlockHash: String
    // The full chainPath this chain is anchored under (e.g. ["Nexus","Child"]).
    // Directory is positional — it is NOT stored in the content-addressed spec —
    // so the chain's identity comes from here. Threaded into validateGenesis
    // (directory = chainPath.last) and validateNexus (chainPath) so a synced
    // chain validates against the path it was anchored under, not a self-declared
    // name. nil ⇒ root (validators fall back to DEFAULT_ROOT_DIRECTORY).
    private let chainPath: [String]?
    private let retentionDepth: UInt64
    private let fetchTimeout: Duration
    private let anchoredPoWValidator: (@Sendable (Block) async -> Bool)?
    private let validateBlockConsensus: Bool
    private var cancelled = false

    public init(
        fetcher: Fetcher,
        store: @Sendable @escaping (String, Data) async -> Void,
        genesisBlockHash: String,
        chainPath: [String]? = nil,
        retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE,
        fetchTimeout: Duration = .seconds(30),
        anchoredPoWValidator: (@Sendable (Block) async -> Bool)? = nil,
        validateBlockConsensus: Bool = true
    ) {
        self.fetcher = fetcher
        self.storeFn = store
        self.genesisBlockHash = genesisBlockHash
        self.chainPath = chainPath
        self.retentionDepth = retentionDepth
        self.fetchTimeout = fetchTimeout
        self.anchoredPoWValidator = anchoredPoWValidator
        self.validateBlockConsensus = validateBlockConsensus
    }

    private func fetchBlockVolume(rawCid: String) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.fetcher.fetch(rawCid: rawCid)
            }
            group.addTask {
                try await Task.sleep(for: self.fetchTimeout)
                throw SyncFetchError.timeout
            }
            guard let result = try await group.next() else {
                throw SyncFetchError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    public func cancel() {
        cancelled = true
    }

    // MARK: - Shared Chain Walk

    private struct WalkResult {
        var collected: [(hash: String, height: UInt64, prevHash: String?, target: UInt256, timestamp: Int64?)]
        var cumulativeWork: UInt256
        var tipBlock: Block?
    }

    /// The per-block pipeline shared by `walkChain` and `backfillSubtree`:
    /// fetch → decode → content-bind → canonicalize → PoW → consensus walk.
    /// ONE implementation so the two walks cannot drift in what they accept —
    /// and, critically, in HOW they classify failures:
    ///
    /// - Fetch failure / undecodable bytes → `bodyUnavailable(walkIndex)`. The
    ///   requested body did not arrive intact (peer pruned it, transport timed
    ///   out). Unavailable ≠ invalid: the branch has NOT been proven bad, so the
    ///   caller must keep holding the incumbent and refetch later, never
    ///   reclassify missing data as an invalid body.
    /// - Content binding: the decoded block must hash to the CID we asked for.
    ///   Both walks follow `parent` links by CID and persist each block under
    ///   its requested CID; without this a peer could serve a different block
    ///   for a CID and we would store it mislabeled and trust its PoW, height,
    ///   and parent linkage. (The normal resolve path does not verify either in
    ///   the pinned cashew, so the walk must assert the binding itself.)
    ///   Collision resistance makes a *different* block matching the requested
    ///   CID infeasible. Failure → `contentMismatch(walkIndex)`.
    /// - Canonicalize: return `block.toData()` (never the raw fetched bytes) so
    ///   what callers persist always byte-hashes to its CID, even if a peer sent
    ///   a non-canonical encoding that happened to decode to this block.
    /// - PoW: a child chain (anchoredPoWValidator set) verifies the bundled
    ///   anchor proof against the root — this runs REGARDLESS of
    ///   `skipPoWValidation`, which only ever applied to the (cheap, local)
    ///   self-hash gate; a root chain self-hashes unless skipped.
    /// - Consensus: `validateGenesis` (with the genesis-CID pin) or
    ///   `validateNexus`, exactly as before. Failure → `invalidBlock(height)`.
    private func fetchDecodeBindValidate(
        cid: String,
        walkIndex: UInt64,
        skipPoWValidation: Bool
    ) async throws -> (block: Block, canonicalData: Data) {
        let data: Data
        do {
            data = try await fetchBlockVolume(rawCid: cid)
        } catch {
            throw SyncError.bodyUnavailable(walkIndex)
        }
        guard let block = Block(data: data) else {
            throw SyncError.bodyUnavailable(walkIndex)
        }

        guard try VolumeImpl<Block>(node: block).rawCID == cid else {
            throw SyncError.contentMismatch(walkIndex)
        }
        guard let canonicalData = block.toData() else {
            throw SyncError.invalidBlock(walkIndex)
        }

        if let anchoredPoWValidator {
            // Child chain: a block's PoW lives on its cross-chain anchor path to
            // the root, NOT its own hash. The node supplies the anchored check
            // (verify the bundled proof against the root); a block that can't
            // present a valid anchored proof is rejected, not accepted self-hashed.
            guard await anchoredPoWValidator(block) else {
                throw SyncError.invalidPoW(block.height)
            }
        } else if !skipPoWValidation {
            // Root chain: the block is self-mined, so its own hash is the gate.
            let powHash = block.proofOfWorkHash()
            guard block.validateProofOfWork(nexusHash: powHash) else {
                throw SyncError.invalidPoW(block.height)
            }
        }

        if validateBlockConsensus {
            let isValid: Bool
            do {
                if block.parent == nil {
                    guard cid == genesisBlockHash else {
                        throw SyncError.genesisMismatch
                    }
                    // Directory is positional: validate the genesis against the path
                    // it was anchored under (chainPath.last), not a self-declared spec
                    // field. nil ⇒ root (validator falls back to DEFAULT_ROOT_DIRECTORY).
                    isValid = try await block.validateGenesis(fetcher: fetcher, directory: chainPath?.last, chainPath: chainPath).0
                } else {
                    isValid = try await block.validateNexus(fetcher: fetcher, chainPath: chainPath, requirePostState: false).0
                }
            } catch let error as SyncError {
                throw error
            } catch {
                throw SyncError.invalidBlock(block.height)
            }
            guard isValid else { throw SyncError.invalidBlock(block.height) }
        }

        return (block, canonicalData)
    }

    /// Walk backwards from a CID, fetching and validating blocks.
    /// - `maxBlocks`: stop after this many blocks (nil = walk to genesis)
    /// - `skipPoWValidation`: skip the `validateProofOfWork` check per block.
    ///   Set to `true` when blocks were already validated by a prior pass
    ///   (e.g., `ParallelBlockFetcher` in headers-first sync), to avoid hashing
    ///   1000 block headers a second time from local CAS.
    /// - `progressInterval`: report progress every N blocks
    private func walkChain(
        from startCID: String,
        maxBlocks: UInt64?,
        skipPoWValidation: Bool = false,
        progressInterval: Int,
        progress: (@Sendable (UInt64, UInt64) async -> Void)?
    ) async throws -> WalkResult {
        // Clamp to >=1 so the `count % progressInterval` cadence below can never
        // divide by zero. A 0 interval (e.g. a misconfigured caller) would trap
        // the whole sync; fail safe to per-block progress instead.
        let progressInterval = max(1, progressInterval)
        var collected: [(hash: String, height: UInt64, prevHash: String?, target: UInt256, timestamp: Int64?)] = []
        var currentCID = startCID
        var targetHeight: UInt64 = 0
        var tipBlock: Block?
        var cumulativeWork = UInt256.zero
        var lastHomesteadCID: String? = nil

        while !cancelled {
            let (block, canonicalData) = try await fetchDecodeBindValidate(
                cid: currentCID,
                walkIndex: UInt64(collected.count),
                skipPoWValidation: skipPoWValidation
            )

            if collected.isEmpty {
                targetHeight = block.height
                tipBlock = block
            }

            // State chain continuity: the next block's homestead must match this block's frontier
            if let expectedFrontier = lastHomesteadCID {
                guard block.postState.rawCID == expectedFrontier else {
                    throw SyncError.invalidStateRoot(block.height)
                }
            }
            lastHomesteadCID = block.prevState.rawCID

            // Saturating, never wrapping: a modulo wrap would make a heavier
            // chain report LOWER work and trip the insufficientWork gate — the
            // same policy as every other cumulative-work sum (saturatingWorkSum).
            cumulativeWork = saturatingWorkSum(cumulativeWork, workForTarget(block.target))

            await storeFn(currentCID, canonicalData)
            collected.append((hash: currentCID, height: block.height, prevHash: block.parent?.rawCID, target: block.target, timestamp: block.timestamp))

            if collected.count % progressInterval == 0 {
                let target = maxBlocks.map { min($0, targetHeight + 1) } ?? (targetHeight + 1)
                await progress?(UInt64(collected.count), target)
            }

            if let max = maxBlocks, UInt64(collected.count) >= max {
                break
            }

            guard let prevCID = block.parent?.rawCID else {
                if maxBlocks == nil {
                    guard currentCID == genesisBlockHash else {
                        throw SyncError.genesisMismatch
                    }
                }
                break
            }
            currentCID = prevCID
        }

        return WalkResult(collected: collected, cumulativeWork: cumulativeWork, tipBlock: tipBlock)
    }

    // MARK: - Body Backfill

    /// Refetch the missing interior block bodies of a HELD strictly-heavier subtree
    /// so the node can VALIDATE them and CONVERGE on the heavier chain.
    ///
    /// CFC-A1 makes fork choice HOLD (never downgrade) when a heavier subtree is
    /// incomplete locally; retains its weight/linkage so the node KNOWS the
    /// branch is heavier even with bodies pruned. This is the transport that closes
    /// the loop: given that heavier branch's tip CID (from
    /// `ChainState.heldHeavierBackfillTarget()`), walk its same-chain path fetching
    /// each missing body over the REAL sync path and validating it exactly as the sync
    /// walk does — content binding (`cid == hash`) plus the per-block consensus walk
    /// (`validateNexus` / `validateGenesis`). Stop at the first ancestor whose body the
    /// node already holds (`haveBody` returns `true`): the prefix below is local.
    ///
    /// Returns the validated bodies **parent-first** so the caller can submit them in
    /// ascending height, after which fork choice converges (the heavier branch is now
    /// fully body-present). Persists each validated body via `store` so the chain can
    /// resolve it. FAILS CLOSED — a forged body (`cid != hash`), an invalid block, or
    /// an unresolvable fetch throws, so the heavier branch is NOT adopted and fork
    /// choice keeps holding the incumbent (invalid/unavailable ≠ a downgrade).
    ///
    /// `maxBodies` bounds the walk so a malicious/very-deep advertised tip cannot make
    /// the node refetch unboundedly; exceeding it throws rather than partially adopting.
    public func backfillSubtree(
        heaviestTipCID: String,
        haveBody: @Sendable (String) async -> Bool,
        maxBodies: UInt64
    ) async throws -> [Block] {
        // Stage validated bodies in memory and admit them to the canonical CAS only
        // after the WHOLE batch validates. Content binding (cid == hash) gates a body
        // into this staging buffer, but it is NOT sufficient for CAS admission:
        // consensus validity matters too. If a later body in the walk fails the
        // consensus/PoW gate the batch throws with nothing persisted, so the CAS never
        // ends up holding earlier hash-bound but consensus-unvalidated bodies that were
        // never submitted to the chain (and could never be rolled back).
        var staged: [(cid: String, data: Data, block: Block)] = []
        var currentCID = heaviestTipCID

        while !cancelled {
            // The walk only fetches bodies we do NOT already hold; the first
            // body-present ancestor terminates the backfill (its prefix is local).
            if await haveBody(currentCID) {
                break
            }

            if UInt64(staged.count) >= maxBodies {
                // A distinct, local bounded-refetch refusal — NOT a PoW/weight
                // invariant failure. `insufficientWork` means the advertised
                // cumulative work was too low; reusing it here would conflate two
                // unrelated failure modes for callers that catch it.
                throw SyncError.backfillTooDeep
            }

            // Per-block fetch + PoW + consensus walk — the SAME pipeline the sync
            // walk runs (shared helper, so the two paths cannot drift).
            let (block, canonicalData) = try await fetchDecodeBindValidate(
                cid: currentCID,
                walkIndex: UInt64(staged.count),
                skipPoWValidation: false
            )

            // Stage the canonical serialization (never the raw fetched bytes) — it is
            // promoted to the CAS below only after the full batch validates.
            staged.append((cid: currentCID, data: canonicalData, block: block))

            guard let prevCID = block.parent?.rawCID else {
                // Reached genesis on a path whose root we do not already hold — the
                // backfill cannot anchor to the local chain. Fail closed.
                if currentCID == genesisBlockHash { break }
                throw SyncError.genesisMismatch
            }
            currentCID = prevCID
        }

        if cancelled { throw SyncError.cancelled }

        // The full subtree validated. NOW promote every staged body to the canonical
        // CAS so it can resolve. Persisting only here (not per-body inside the walk)
        // keeps the CAS free of consensus-unvalidated bodies on any mid-walk failure.
        for body in staged {
            await storeFn(body.cid, body.data)
        }

        // Parent-first so the caller submits in ascending height and fork choice
        // converges as the heavier branch becomes contiguously body-present.
        return staged.map(\.block).reversed()
    }

    // MARK: - Full Sync

    public func syncFull(
        peerTipCID: String,
        localCumulativeWork: UInt256 = UInt256.zero,
        progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil
    ) async throws -> SyncResult {
        let walk = try await walkChain(
            from: peerTipCID, maxBlocks: nil,
            progressInterval: 500, progress: progress
        )

        if cancelled { throw SyncError.cancelled }
        guard !walk.collected.isEmpty else { throw SyncError.emptyChain }
        if walk.cumulativeWork < localCumulativeWork { throw SyncError.insufficientWork }

        if let tip = walk.tipBlock {
            let valid = try await verifyTipFrontier(tip)
            if !valid { throw SyncError.invalidStateRoot(tip.height) }
        }

        var collected = walk.collected
        collected.reverse()
        let targetHeight = collected.last?.height ?? 0
        await progress?(targetHeight + 1, targetHeight + 1)

        return buildResult(from: collected, cumulativeWork: walk.cumulativeWork)
    }

    // MARK: - Snapshot Sync

    public func syncSnapshot(
        peerTipCID: String,
        depth: UInt64? = nil,
        localCumulativeWork: UInt256 = UInt256.zero,
        skipPoWValidation: Bool = false,
        progressInterval: Int = 100,
        progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil
    ) async throws -> SyncResult {
        let effectiveDepth = depth ?? retentionDepth
        let walk = try await walkChain(
            from: peerTipCID, maxBlocks: effectiveDepth,
            skipPoWValidation: skipPoWValidation,
            progressInterval: progressInterval, progress: progress
        )

        if cancelled { throw SyncError.cancelled }
        guard !walk.collected.isEmpty else { throw SyncError.emptyChain }

        if walk.cumulativeWork < localCumulativeWork { throw SyncError.insufficientWork }

        // A3 (long-range attack): if the walk reached a block with no parent
        // (the genesis or the bottom of the window), verify it IS the real genesis.
        // Without this, a fresh node (localWork=0) accepts any chain fragment that
        // has enough window work, even one rooted at a fake genesis.
        if let oldest = walk.collected.last, oldest.prevHash == nil {
            guard oldest.hash == genesisBlockHash else {
                throw SyncError.genesisMismatch
            }
        }

        // Snapshot sync trusts the state root committed in the PoW chain,
        // the same model as Ethereum snap sync. Re-executing state transitions
        // requires state trie data that may not be available (causing stalls).
        // Use syncFull for maximum-trustless state re-execution.

        var collected = walk.collected
        collected.reverse()
        return buildResult(from: collected, cumulativeWork: walk.cumulativeWork)
    }

    /// Sync by downloading only the tip block and trusting the frontier state
    /// root committed in its PoW hash. The state trie is fetched lazily.
    /// Does not require any historical blocks — works even when peers have
    /// evicted old block data beyond their retention window.
    public func syncStateOnly(
        peerTipCID: String,
        localCumulativeWork: UInt256 = UInt256.zero
    ) async throws -> SyncResult {
        // Fetch the tip block. A failed fetch (peer unreachable, transport
        // timeout) is NOT evidence the advertised tip is bad — classify it
        // `bodyUnavailable` (invalid ≠ unavailable, the same error-class
        // contract as the walk pipeline) so callers retry instead of treating
        // the tip as proven invalid. Bytes that ARRIVE but are undecodable or
        // mislabeled stay in the invalid class below: the peer advertised this
        // tip itself, so serving garbage for it is peer fault, not pruning.
        let data: Data
        do {
            data = try await fetchBlockVolume(rawCid: peerTipCID)
        } catch {
            throw SyncError.bodyUnavailable(0)
        }
        guard let tipBlock = Block(data: data) else {
            throw SyncError.invalidBlock(0)
        }

        // Content binding: the decoded tip must hash to the advertised CID.
        // Otherwise a peer could serve a different (even validly-mined) block
        // than the tip it advertised, and we would adopt its frontier state root
        // and record it under the wrong hash. Collision resistance makes a
        // *different* block matching the advertised CID infeasible.
        guard try VolumeImpl<Block>(node: tipBlock).rawCID == peerTipCID else {
            throw SyncError.contentMismatch(0)
        }

        // Verify PoW — the frontier state root is committed to by the hash. A child
        // chain validates against its anchored proof to the root (node-supplied);
        // the root chain uses its own hash.
        if let anchoredPoWValidator {
            guard await anchoredPoWValidator(tipBlock) else {
                throw SyncError.invalidPoW(tipBlock.height)
            }
        } else {
            let powHash = tipBlock.proofOfWorkHash()
            guard tipBlock.validateProofOfWork(nexusHash: powHash) else {
                throw SyncError.invalidPoW(tipBlock.height)
            }
        }

        let workPerBlock = workForTarget(tipBlock.target)
        // Use estimated full chain work (perBlock * height), not single-block work.
        // A node that has mined locally will have localWork > 1 block, so comparing
        // against a single block always fails even when the peer's chain is longer.
        // Overflow-checked, clamped to UInt256.max: a wrapping multiply would turn
        // a very heavy estimate into garbage (possibly tiny) and spuriously throw
        // insufficientWork — same saturating policy as the cumulative-work sums.
        let blockCount = UInt256(tipBlock.height) + UInt256(1) // +1 in UInt256 space: cannot wrap
        let (product, overflow) = workPerBlock.multipliedReportingOverflow(by: blockCount)
        let estimatedChainWork = overflow ? UInt256.max : product
        if estimatedChainWork < localCumulativeWork { throw SyncError.insufficientWork }
        let work = estimatedChainWork

        // Store the tip block so finalizeSyncResult can resolve it. Persist the
        // canonical serialization so the stored bytes always byte-hash to the CID
        // (mirrors walkChain — never fall back to the raw fetched bytes).
        guard let canonicalTipData = tipBlock.toData() else {
            throw SyncError.invalidBlock(0)
        }
        await storeFn(peerTipCID, canonicalTipData)

        let persisted = PersistedChainState(
            chainTip: peerTipCID,
            tipPostStateCID: tipBlock.postState.rawCID.isEmpty ? nil : tipBlock.postState.rawCID,
            tipPrevStateCID: tipBlock.prevState.rawCID.isEmpty ? nil : tipBlock.prevState.rawCID,
            tipSpecCID: tipBlock.spec.rawCID.isEmpty ? nil : tipBlock.spec.rawCID,
            tipTarget: tipBlock.target.toHexString(),
            tipNextTarget: tipBlock.nextTarget.toHexString(),
            tipHeight: tipBlock.height,
            tipTimestamp: tipBlock.timestamp,
            mainChainHashes: [peerTipCID],
            blocks: [PersistedBlockMeta(
                blockHash: peerTipCID,
                parentBlockHash: tipBlock.parent?.rawCID,
                blockHeight: tipBlock.height,
                parentChainBlocks: [:],
                childHashes: [],
                target: tipBlock.target.toHexString(),
                timestamp: tipBlock.timestamp
            )],
            parentChainMap: [:],
            missingBlockHashes: []
        )

        return SyncResult(
            persisted: persisted,
            tipBlockHash: peerTipCID,
            tipBlockHeight: tipBlock.height,
            cumulativeWork: work
        )
    }

    private func verifyTipFrontier(_ block: Block) async throws -> Bool {
        guard let transactionsNode = try? await block.transactions.resolveRecursive(fetcher: fetcher).node else {
            return false
        }
        guard let txKeysAndValues = try? transactionsNode.allKeysAndValues() else {
            return false
        }
        let bodies = txKeysAndValues.values.compactMap { $0.node?.body.node }
        return try await block.validatePostState(transactionBodies: bodies, fetcher: fetcher).0
    }

    /// Build a SyncResult directly from pre-downloaded and pre-verified headers.
    ///
    /// Used by performHeadersFirstSync to skip the second IvyFetcher re-walk pass
    /// that syncSnapshot performs. downloadHeaders already fetched and stored all
    /// block bytes and verified PoW + state chain continuity — re-walking via
    /// IvyFetcher is redundant and fails if DiskBroker writes were lost under load.
    public func syncFromHeaders(
        _ headers: [SyncBlockHeader],
        cumulativeWork: UInt256,
        localCumulativeWork: UInt256 = .zero
    ) async throws -> SyncResult {
        guard !headers.isEmpty else { throw SyncError.emptyChain }
        // A child chain cannot sync headers-first: headers carry no anchoring proof,
        // so anchored PoW (`anchoredPoWValidator`) can't be verified. Refuse rather
        // than adopt unverified child headers.
        guard anchoredPoWValidator == nil else { throw SyncError.invalidPoW(0) }

        if cumulativeWork < localCumulativeWork { throw SyncError.insufficientWork }

        if validateBlockConsensus {
            try await validateHeaderConsensus(headers)
        }

        let blocks = headers.map {
            (hash: $0.cid, height: $0.height, prevHash: $0.previousBlockCID, target: $0.target, timestamp: Optional($0.timestamp))
        }
        return buildResult(from: blocks, cumulativeWork: cumulativeWork)
    }

    private func validateHeaderConsensus(_ headers: [SyncBlockHeader]) async throws {
        guard let first = headers.first else { throw SyncError.emptyChain }
        let validationHeaders: [SyncBlockHeader]
        if first.cid == genesisBlockHash {
            guard first.height == 0, first.previousBlockCID == nil else {
                throw SyncError.genesisMismatch
            }
            validationHeaders = headers
        } else {
            guard first.previousBlockCID == genesisBlockHash,
                  let genesisData = try? await fetchBlockVolume(rawCid: genesisBlockHash),
                  let genesisBlock = Block(data: genesisData),
                  try VolumeImpl<Block>(node: genesisBlock).rawCID == genesisBlockHash,
                  genesisBlock.height == 0,
                  genesisBlock.parent == nil else {
                throw SyncError.genesisMismatch
            }
            validationHeaders = [
                SyncBlockHeader(
                    cid: genesisBlockHash,
                    height: genesisBlock.height,
                    previousBlockCID: nil,
                    target: genesisBlock.target,
                    nextTarget: genesisBlock.nextTarget,
                    timestamp: genesisBlock.timestamp,
                    specCID: genesisBlock.spec.rawCID,
                    spec: genesisBlock.spec.node
                )
            ] + headers
        }
        guard validationHeaders.count > 1 else { return }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // R9 (wave-4): the shared consensus constant, not a re-hardcoded copy.
        let maxFutureDrift = Block.maxFutureDriftMilliseconds
        var specs: [String: ChainSpec] = [:]
        for i in 1..<validationHeaders.count {
            let parent = validationHeaders[i - 1]
            let header = validationHeaders[i]
            guard header.previousBlockCID == parent.cid,
                  header.height == parent.height + 1,
                  header.specCID == parent.specCID else {
                throw SyncError.invalidBlock(header.height)
            }
            guard header.timestamp > parent.timestamp,
                  header.timestamp <= now + maxFutureDrift else {
                throw SyncError.invalidBlock(header.height)
            }

            let parentTimestamps = validationHeaders[..<i].reversed().map(\.timestamp)
            let mtpWindow = parentTimestamps.prefix(Int(Block.mtpDepth)).sorted()
            if !mtpWindow.isEmpty {
                let median = mtpWindow[(mtpWindow.count - 1) / 2]
                guard header.timestamp > median else {
                    throw SyncError.invalidBlock(header.height)
                }
            }

            guard header.target == parent.nextTarget ||
                    ChainSpec.isMinimumTargetRecovery(target: header.target, parentNextTarget: parent.nextTarget) else {
                throw SyncError.invalidBlock(header.height)
            }
            let specCID = header.specCID ?? parent.specCID
            let spec: ChainSpec?
            if let embedded = header.spec ?? parent.spec {
                spec = embedded
            } else if let specCID, let cached = specs[specCID] {
                spec = cached
            } else if let specCID,
                      let resolved = try? await VolumeImpl<ChainSpec>(rawCID: specCID).resolve(fetcher: fetcher).node {
                specs[specCID] = resolved
                spec = resolved
            } else {
                spec = nil
            }
            guard let spec else {
                throw SyncError.invalidBlock(header.height)
            }
            if ChainSpec.isMinimumTargetRecovery(target: header.target, parentNextTarget: parent.nextTarget) {
                guard header.nextTarget == header.target else {
                    throw SyncError.invalidBlock(header.height)
                }
                continue
            }
            let requiredDepth = min(spec.retargetWindow, parent.height + 1)
            guard parentTimestamps.count >= Int(requiredDepth) else {
                throw SyncError.invalidBlock(header.height)
            }
            let window = [header.timestamp] + Array(parentTimestamps.prefix(Int(requiredDepth)))
            let expected = spec.calculateWindowedTarget(
                previousTarget: header.target,
                ancestorTimestamps: window
            )
            guard header.nextTarget == expected else {
                throw SyncError.invalidBlock(header.height)
            }
        }
    }

    // MARK: - Build Result

    private func buildResult(
        from blocks: [(hash: String, height: UInt64, prevHash: String?, target: UInt256, timestamp: Int64?)],
        cumulativeWork: UInt256 = UInt256.zero
    ) -> SyncResult {
        // `blocks.last!` is safe: this private helper is only reached after the
        // caller guards `!collected.isEmpty` / `!headers.isEmpty`
        // (syncFull, syncSnapshot, syncFromHeaders all throw SyncError.emptyChain
        // first), so the tip element always exists.
        let tipHeight = blocks.last!.height
        let cutoff: UInt64 = tipHeight > retentionDepth
            ? tipHeight - retentionDepth
            : 0

        var persistedBlocks: [PersistedBlockMeta] = []
        var mainChainHashes: [String] = []

        var childMap: [String: [String]] = [:]
        for entry in blocks where entry.height >= cutoff {
            if let prevHash = entry.prevHash {
                childMap[prevHash, default: []].append(entry.hash)
            }
        }

        for entry in blocks where entry.height >= cutoff {
            persistedBlocks.append(PersistedBlockMeta(
                blockHash: entry.hash,
                parentBlockHash: entry.prevHash,
                blockHeight: entry.height,
                parentChainBlocks: [:],
                childHashes: childMap[entry.hash] ?? [],
                // Carry per-block target so the restored chain recomputes a
                // correct (non-zero) cumulative-work prefix sum. Without it every
                // synced block has work=0 and the chain reports zero cumulative
                // work — breaking work comparison and fork choice after sync.
                target: entry.target.toHexString(),
                timestamp: entry.timestamp
            ))
            mainChainHashes.append(entry.hash)
        }

        // Populate tipHeight so callers can check chain state without fetching the block.
        // tipTarget/tipTimestamp are unavailable from the header-only walk — callers
        // that need them should use syncStateOnly (which fetches and parses the tip block).
        let tipEntry = blocks.last!
        let persisted = PersistedChainState(
            chainTip: tipEntry.hash,
            tipPostStateCID: nil,
            tipPrevStateCID: nil,
            tipSpecCID: nil,
            tipTarget: nil,
            tipNextTarget: nil,
            tipHeight: tipEntry.height,
            tipTimestamp: nil,
            mainChainHashes: mainChainHashes,
            blocks: persistedBlocks,
            parentChainMap: [:],
            missingBlockHashes: []
        )

        return SyncResult(
            persisted: persisted,
            tipBlockHash: blocks.last!.hash,
            tipBlockHeight: tipHeight,
            cumulativeWork: cumulativeWork
        )
    }
}
