import Foundation
import UInt256

/// A consensus work fact derived by admission from authenticated proof bytes.
/// Codable conformance is for trusted local snapshots; consensus mutation APIs
/// accept these values only from package-internal verification paths.
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

public enum ChildProofVerificationFailure: Error, Sendable, Equatable {
    case unavailableEvidence
    case malformedEvidence
    case protocolInvalid
}

/// Result of verifying a child package. Its initializer is internal so callers
/// cannot turn wire claims into consensus facts.
public struct VerifiedChildEvidence: Sendable {
    public let grindID: String
    public let rootHash: UInt256
    public let acceptedAncestorWork: UInt256

    init(
        grindID: String,
        rootHash: UInt256,
        acceptedAncestorWork: UInt256
    ) {
        self.grindID = grindID
        self.rootHash = rootHash
        self.acceptedAncestorWork = acceptedAncestorWork
    }

    /// Credit this physical grind exactly once at the highest accepted boundary.
    /// An accepted ancestor makes the contribution inherited; otherwise the child
    /// is the first accepting boundary and receives it as own work.
    public func contribution(for child: Block) -> VerifiedWorkContribution? {
        guard child.validateProofOfWork(nexusHash: rootHash) else { return nil }
        if acceptedAncestorWork > .zero {
            return VerifiedWorkContribution(
                id: grindID,
                work: acceptedAncestorWork
            )
        }
        return VerifiedWorkContribution(
            id: grindID,
            work: workForTarget(child.target)
        )
    }
}
