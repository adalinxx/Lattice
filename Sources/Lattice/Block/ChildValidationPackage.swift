import Foundation
import UInt256

/// A consensus work fact derived by admission from authenticated proof bytes.
/// Live mutation accepts these only from package-internal verification. Public
/// recovery replay accepts the same fact only after node-owned authentication
/// and durability.
public struct VerifiedWorkContribution: Codable, Sendable, Equatable {
    public let id: String
    public let work: UInt256

    package init(id: String, work: UInt256) {
        self.id = id
        self.work = work
    }
}

/// A permanent semantic fact produced by the Lattice process responsible for
/// `parentPath`. The node authenticates that process, transports this value, and
/// caches it; child admission only verifies that it binds the exact carrier it
/// is about to use.
public struct ParentContinuityLink: Codable, Hashable, Sendable {
    public let parentPath: [String]
    public let successorCID: String

    package init(
        parentPath: [String],
        successorCID: String
    ) {
        self.parentPath = parentPath
        self.successorCID = successorCID
    }
}

/// A permanent parent-chain fact authorizing one genesis root for a path-defined
/// child chain. Competing valid parent branches may produce different links for
/// the same child path; the child forest chooses between those roots locally.
public struct ParentGenesisLink: Codable, Hashable, Sendable {
    public let parentPath: [String]
    public let directory: String
    public let childGenesisCID: String

    package init(
        parentPath: [String],
        directory: String,
        childGenesisCID: String
    ) {
        self.parentPath = parentPath
        self.directory = directory
        self.childGenesisCID = childGenesisCID
    }
}

/// The complete cross-chain evidence required to validate one child candidate.
/// Sparse security proof and authenticated parent-issued facts remain distinct
/// values so neither can silently stand in for the other.
public struct ChildValidationPackage: Sendable {
    public let proof: ChildBlockProof
    public let parentContinuityLinks: [ParentContinuityLink]
    public let parentGenesisLinks: [ParentGenesisLink]

    public init(
        proof: ChildBlockProof,
        parentContinuityLinks: [ParentContinuityLink] = [],
        parentGenesisLinks: [ParentGenesisLink] = []
    ) {
        self.proof = proof
        self.parentContinuityLinks = parentContinuityLinks.sorted {
            if $0.parentPath != $1.parentPath {
                return $0.parentPath.lexicographicallyPrecedes($1.parentPath)
            }
            return $0.successorCID < $1.successorCID
        }
        self.parentGenesisLinks = parentGenesisLinks.sorted {
            if $0.parentPath != $1.parentPath {
                return $0.parentPath.lexicographicallyPrecedes($1.parentPath)
            }
            if $0.directory != $1.directory {
                return $0.directory < $1.directory
            }
            return $0.childGenesisCID < $1.childGenesisCID
        }
    }
}

/// Node-owned acquisition needed before child-chain admission can continue.
/// A child CID commits its parent-state root but does not identify a parent-chain
/// carrier; the authenticated parent process supplies these facts.
public enum CrossChainEvidenceRequirement: Sendable, Equatable {
    case childProof(chainPath: [String], childCID: String)
    case parentContinuity(parentPath: [String], successorCID: String)
    case parentGenesis(parentPath: [String], directory: String, childGenesisCID: String)
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
    public let strongestAncestorWork: UInt256

    init(
        grindID: String,
        rootHash: UInt256,
        strongestAncestorWork: UInt256
    ) {
        self.grindID = grindID
        self.rootHash = rootHash
        self.strongestAncestorWork = strongestAncestorWork
    }

    /// Credit this physical grind at its strongest accepted difficulty while
    /// keeping its coverage of this child as a separate fact.
    public func contribution(for child: Block) -> VerifiedWorkContribution? {
        guard child.validateProofOfWork(nexusHash: rootHash) else { return nil }
        return VerifiedWorkContribution(
            id: grindID,
            work: max(strongestAncestorWork, workForTarget(child.target))
        )
    }
}
