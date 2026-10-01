import Foundation
import UInt256
import LatticePrimitives
import LatticePoW

/// A local fact derived from one chain's validated, connected block graph.
/// Equality is reflexive and needs no fact.
public struct ParentStateContinuityLink: Hashable, Sendable {
    public let parentPath: [String]
    public let fromStateCID: String
    public let toStateCID: String

    public init(
        parentPath: [String],
        fromStateCID: String,
        toStateCID: String
    ) {
        self.parentPath = parentPath
        self.fromStateCID =
            CIDIdentity.canonicalString(fromStateCID) ?? fromStateCID
        self.toStateCID = CIDIdentity.canonicalString(toStateCID) ?? toStateCID
    }
}

/// Structural proof plus facts derived by this node's chain processes.
/// The facts deliberately are not Codable: peers send bytes to validate, not
/// verdicts to decode.
public struct ChildValidationPackage: Sendable {
    public let proof: ChildBlockProof
    public let parentStateContinuityLink: ParentStateContinuityLink?

    public init(
        proof: ChildBlockProof,
        parentStateContinuityLink: ParentStateContinuityLink? = nil
    ) {
        self.proof = proof
        self.parentStateContinuityLink = parentStateContinuityLink
    }
}

/// Node-owned acquisition needed before child-chain admission can continue.
/// Providers supply content-addressed evidence; the node derives every
/// state-validity fact locally before constructing this package.
public enum CrossChainEvidenceRequirement: Sendable, Equatable {
    case childProof(chainPath: [String], childCID: String)
    case parentStateContinuity(
        parentPath: [String],
        fromStateCID: String,
        toStateCID: String
    )
}

public enum ChildProofVerificationFailure: Error, Sendable, Equatable {
    case crossChainEvidenceRequired(CrossChainEvidenceRequirement)
    case malformedEvidence
    case protocolInvalid
}

/// Result of verifying a child package. Its initializer is internal so callers
/// cannot turn wire claims into consensus facts.
public struct VerifiedChildEvidence: Sendable {
    public let grindID: String
    public let rootHash: UInt256
    /// Work of the root-most carrier whose target this grind's hash beat —
    /// the highest chain the grind legitimately participated in. Not a max
    /// over every met target: see `verifySecuringWork`.
    public let creditedAncestorWork: UInt256
    public let childCID: String
    public let terminalCarrierCID: String
    public let contribution: VerifiedWorkContribution?

    init(
        grindID: String,
        rootHash: UInt256,
        creditedAncestorWork: UInt256,
        childCID: String,
        terminalCarrierCID: String,
        contribution: VerifiedWorkContribution?
    ) {
        self.grindID = grindID
        self.rootHash = rootHash
        self.creditedAncestorWork = creditedAncestorWork
        self.childCID = childCID
        self.terminalCarrierCID = terminalCarrierCID
        self.contribution = contribution
    }
}
