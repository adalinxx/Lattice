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

/// Content-bound predecessor blocks used to prove that each carrier's
/// `prevState` follows its same-chain predecessor's `postState`.
public struct ParentStateWitness: Sendable {
    public let entries: [(cid: String, data: Data)]

    public init(entries: [(cid: String, data: Data)]) {
        self.entries = entries
    }
}

/// The complete cross-chain evidence required to validate one child candidate.
/// Security proof and execution-state witness remain distinct values so neither
/// can silently stand in for the other.
public struct ChildValidationPackage: Sendable {
    public let proof: ChildBlockProof
    public let parentStateWitness: ParentStateWitness

    public init(proof: ChildBlockProof, parentStateWitness: ParentStateWitness) {
        self.proof = proof
        self.parentStateWitness = parentStateWitness
    }
}

public enum ChildProofVerificationFailure: Error, Sendable, Equatable {
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
