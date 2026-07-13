import cashew
import UInt256

/// Result of the node's durable preparation step for one fully verified block.
/// Storage availability is deliberately distinct from protocol validity.
public enum ChainCommitPreparation: Sendable, Equatable {
    case ready
    case unavailable
    case storageFailed
}

/// Chain-local admission result. This vocabulary preserves the architectural
/// distinctions that the legacy `BlockProcessingResult` collapses:
///
/// - unavailable data is not invalid data;
/// - a valid side block is accepted but not canonical;
/// - canonicity changes only on the chain being evaluated;
/// - local storage failure is not peer invalidity.
public enum ChainLocalBlockResult: Sendable {
    case canonicalized(StateDiff, materializedPostState: LatticeState? = nil)
    case acceptedSide(StateDiff, materializedPostState: LatticeState? = nil)
    case duplicate
    case invalid
    case unavailable
    case storageFailed

    public var isValidAdmission: Bool {
        switch self {
        case .canonicalized, .acceptedSide, .duplicate: return true
        case .invalid, .unavailable, .storageFailed: return false
        }
    }

    public var becameCanonical: Bool {
        if case .canonicalized = self { return true }
        return false
    }

    public var stateDiff: StateDiff {
        switch self {
        case .canonicalized(let diff, _), .acceptedSide(let diff, _): return diff
        case .duplicate, .invalid, .unavailable, .storageFailed: return .empty
        }
    }

    public var materializedPostState: LatticeState? {
        switch self {
        case .canonicalized(_, let state), .acceptedSide(_, let state): return state
        case .duplicate, .invalid, .unavailable, .storageFailed: return nil
        }
    }
}

public extension Lattice {
    /// Validate and admit one block on this Lattice facade's own chain only.
    ///
    /// Unlike the legacy `processBlockHeader`, this method:
    ///
    /// - never invokes a transport or body-backfill provider;
    /// - never propagates a reorganization to child `ChainLevel`s;
    /// - reports valid side admission separately from invalidity;
    /// - reports unavailable validation input separately from invalidity;
    /// - reports local durable-write failure separately from unavailable data.
    ///
    /// Cross-chain evidence may be supplied through `fetcher`, `rootHash`, and
    /// `chainPath`, but the resulting mutation and fork choice are strictly local
    /// to `nexus.chain` of this facade.
    func admitBlockHeaderChainLocal(
        _ blockHeader: BlockHeader,
        fetcher: Fetcher,
        skipValidation: Bool = false,
        rootHash: UInt256? = nil,
        chainPath: [String]? = nil,
        beforeCommit: (@Sendable (Block, StateDiff, LatticeState?) async -> ChainCommitPreparation)? = nil
    ) async -> ChainLocalBlockResult {
        if await nexus.chain.contains(blockHash: blockHeader.rawCID) {
            return .duplicate
        }

        let block: Block
        do {
            guard let resolved = try await blockHeader.resolveBlockContent(fetcher: fetcher).node else {
                return .unavailable
            }
            block = resolved
        } catch {
            return .unavailable
        }

        let processingHash = rootHash ?? block.proofOfWorkHash()
        guard skipValidation || block.validateProofOfWork(nexusHash: processingHash) else {
            return .invalid
        }

        var diff = StateDiff.empty
        var materializedPostState: LatticeState?
        if !skipValidation {
            do {
                let validation = try await block.validateNexus(
                    fetcher: fetcher,
                    chain: nexus.chain,
                    chainPath: chainPath
                )
                guard validation.0 else { return .invalid }
                diff = validation.1
                materializedPostState = validation.2
            } catch {
                // Validation could not obtain enough authenticated content to decide.
                // A deterministic rule violation is represented by `validation.0 == false`.
                return .unavailable
            }
        }

        if let beforeCommit {
            switch await beforeCommit(block, diff, materializedPostState) {
            case .ready:
                break
            case .unavailable:
                return .unavailable
            case .storageFailed:
                return .storageFailed
            }
        }

        let submission = await nexus.chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: blockHeader,
            block: block
        )

        if submission.extendsMainChain || submission.reorganization != nil {
            return .canonicalized(diff, materializedPostState: materializedPostState)
        }
        if submission.addedBlock {
            return .acceptedSide(diff, materializedPostState: materializedPostState)
        }
        return .duplicate
    }

    /// Batched-content overload. It preserves exactly the same decision semantics
    /// while coalescing each resolution wave through one `ContentSource`.
    func admitBlockHeaderChainLocal(
        _ blockHeader: BlockHeader,
        source: any ContentSource,
        skipValidation: Bool = false,
        rootHash: UInt256? = nil,
        chainPath: [String]? = nil,
        beforeCommit: (@Sendable (Block, StateDiff, LatticeState?) async -> ChainCommitPreparation)? = nil
    ) async -> ChainLocalBlockResult {
        await admitBlockHeaderChainLocal(
            blockHeader,
            fetcher: CoalescingFetcher(source),
            skipValidation: skipValidation,
            rootHash: rootHash,
            chainPath: chainPath,
            beforeCommit: beforeCommit
        )
    }
}
