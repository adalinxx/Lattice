import Foundation
import cashew

public struct SameChainPredecessorRequirement: Sendable, Equatable {
    public let descendantCID: String
    public let predecessorCID: String

    public init(descendantCID: String, predecessorCID: String) {
        self.descendantCID = descendantCID
        self.predecessorCID = predecessorCID
    }
}

public struct ChainBlockFact: Codable, Sendable, Equatable {
    public let blockHash: String
    public let parentBlockHash: String?
    public let blockHeight: UInt64
    public let postStateCID: String
    public let prevStateCID: String
    public let specCID: String
    public let target: String
    public let nextTarget: String
    public let timestamp: Int64
    public let stateDiff: StateDiff
    /// Directory → child block CID this block commits, from its PoW-bound
    /// `children` index (§9.10). Optional so facts written before it existed
    /// still decode; absent means NOT RECORDED — never "commits nothing" — and
    /// a later fact for the same block supplies the map (see
    /// `BlockMeta.childCommitments`, `matchesGraph`).
    public let childCommitments: [String: String]?

    /// Explicit so `childCommitments` can default to nil: a defaulted `let`
    /// would drop it from the synthesized memberwise init entirely, and the
    /// one real construction site (`PreparedAdmission.facts`) must set it.
    public init(
        blockHash: String,
        parentBlockHash: String?,
        blockHeight: UInt64,
        postStateCID: String,
        prevStateCID: String,
        specCID: String,
        target: String,
        nextTarget: String,
        timestamp: Int64,
        stateDiff: StateDiff,
        childCommitments: [String: String]? = nil
    ) {
        self.blockHash = blockHash
        self.parentBlockHash = parentBlockHash
        self.blockHeight = blockHeight
        self.postStateCID = postStateCID
        self.prevStateCID = prevStateCID
        self.specCID = specCID
        self.target = target
        self.nextTarget = nextTarget
        self.timestamp = timestamp
        self.stateDiff = stateDiff
        self.childCommitments = childCommitments
    }
}

/// A block's state transition was EXECUTED and its declared `postState`
/// reproduced. Separate from the block fact because the tiers are separate in
/// time: the weighed tier possesses and connects a block from its header alone
/// and records its `postState` as an unverified claim (§9.9); execution is a
/// later, independent judgment.
///
/// It is its own immutable fact rather than a field on `ChainBlockFact` because
/// the block fact is keyed by block hash and is never rewritten — deferred
/// execution keeps it as the state-blind consensus-replay record — so a tier
/// marker stored there could never be updated, and every block would stay
/// unverified across a restart.
///
/// This gates parent-state attestation: a child chain settles cross-chain
/// withdrawals against an attested parent state, so attesting a state the
/// parent never produced lets a forged `receiptState` settle a withdrawal that
/// was never paid.
public struct ChainValidationFact: Codable, Sendable, Equatable {
    public let blockHash: String

    public init(blockHash: String) {
        self.blockHash = blockHash
    }
}

public struct ChainWorkFact: Codable, Sendable, Equatable {
    public let blockHash: String
    public let contribution: VerifiedWorkContribution
    /// Set when the contribution is a parent's attributed run (§9.10), whose
    /// `contributionID` is then `contribution.id`; absent — the shape every
    /// fact before this field carried — for a grind. Replay reads it so a
    /// restored parent serves the same `ownWork` the live one did: a run
    /// attributed AT a committer is no grind of it and stays in the run it
    /// serves.
    public let attributedRun: AttributedRunIdentity?

    public init(
        blockHash: String,
        contribution: VerifiedWorkContribution,
        attributedRun: AttributedRunIdentity? = nil
    ) {
        self.blockHash = blockHash
        self.contribution = contribution
        self.attributedRun = attributedRun
    }

    private enum CodingKeys: String, CodingKey {
        case blockHash
        case contribution
        case attributedRun
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockHash = try container.decode(String.self, forKey: .blockHash)
        contribution = try container.decode(VerifiedWorkContribution.self, forKey: .contribution)
        attributedRun = try container.decodeIfPresent(AttributedRunIdentity.self, forKey: .attributedRun)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(blockHash, forKey: .blockHash)
        try container.encode(contribution, forKey: .contribution)
        try container.encodeIfPresent(attributedRun, forKey: .attributedRun)
    }
}

/// A deterministic, replayable judgment that a possessed block is invalid — its
/// execution completed and FAILED (a `postState` mismatch or a committed
/// validity rule). Recording it removes the block's subtree from THIS chain's
/// own effective weight so fork choice re-projects onto the heaviest VALID
/// chain. It is not pruning: the excluded facts stay in the graph, served and
/// exported unchanged; only this node's own weighting stops counting them.
public struct ChainExclusionFact: Codable, Sendable, Equatable {
    public let blockHash: String

    public init(blockHash: String) {
        self.blockHash = blockHash
    }
}

public enum ChainFactID: Codable, Hashable, Sendable {
    case block(String)
    case work(blockHash: String, grindID: String, work: String)
    case exclusion(String)
    case validation(String)
}

public enum ChainAdmissionFact: Codable, Sendable, Equatable {
    case block(ChainBlockFact)
    case work(ChainWorkFact)
    case exclusion(ChainExclusionFact)
    case validation(ChainValidationFact)

    public var id: ChainFactID {
        switch self {
        case .block(let fact): .block(fact.blockHash)
        // The attributed-run marker is not part of the identity: it is a
        // function of the contribution ID (the one identity that ID is the
        // CID of), so two facts differing only in the marker are one fact.
        case .work(let fact): .work(
            blockHash: fact.blockHash,
            grindID: fact.contribution.id,
            work: fact.contribution.work.toHexString()
        )
        case .exclusion(let fact): .exclusion(fact.blockHash)
        case .validation(let fact): .validation(fact.blockHash)
        }
    }
}

/// One node-atomic durability unit. New blocks stage their block and first work
/// observations together; later work or a stronger observation appends another
/// immutable fact.
public struct ChainAdmissionBatch: Codable, Sendable, Equatable {
    public let facts: [ChainAdmissionFact]

    init(facts: [ChainAdmissionFact]) {
        self.facts = facts
    }

    /// The one batch shape a node may author: "this block's transition was
    /// executed here".
    ///
    /// Deliberately a narrow factory rather than a public initializer. Every
    /// other fact is a claim Lattice must derive for itself from content —
    /// exposing general batch construction would let a caller turn wire claims
    /// into consensus facts. Execution is different in kind: it is a judgment
    /// the node's own validate walk reaches locally, and the node must be able
    /// to make it durable, because the durable batch log is the only recovery
    /// authority and an execution the log forgets is an execution that never
    /// happened.
    public static func validation(blockHash: String) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
            .validation(ChainValidationFact(blockHash: blockHash)),
        ])
    }
}
