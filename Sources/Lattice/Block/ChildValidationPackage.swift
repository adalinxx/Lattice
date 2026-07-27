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
        self.id = CIDIdentity.canonicalString(id) ?? id
        self.work = work
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(String.self, forKey: .id)
        id = CIDIdentity.canonicalString(decodedID) ?? decodedID
        work = try container.decode(UInt256.self, forKey: .work)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case work
    }
}

/// A permanent fact produced by the Lattice process responsible for
/// `parentPath` after it verifies this exact grind's path to `carrierCID`.
/// The node authenticates the immediate-parent process and transports or caches
/// the value; no ancestor process identity crosses this boundary.
public struct ParentCarrierLink: Codable, Hashable, Sendable {
    public let parentPath: [String]
    public let carrierCID: String
    public let rootCID: String

    package init(
        parentPath: [String],
        carrierCID: String,
        rootCID: String
    ) {
        self.parentPath = parentPath
        self.carrierCID = CIDIdentity.canonicalString(carrierCID) ?? carrierCID
        self.rootCID = CIDIdentity.canonicalString(rootCID) ?? rootCID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentPath = try container.decode([String].self, forKey: .parentPath)
        let carrier = try container.decode(String.self, forKey: .carrierCID)
        let root = try container.decode(String.self, forKey: .rootCID)
        carrierCID = CIDIdentity.canonicalString(carrier) ?? carrier
        rootCID = CIDIdentity.canonicalString(root) ?? root
    }

    private enum CodingKeys: String, CodingKey {
        case parentPath
        case carrierCID
        case rootCID
    }
}

/// A permanent fact derived locally from a validated parent-chain state,
/// authorizing one genesis root for a path-defined child chain. Competing valid
/// parent branches may produce different links for the same child path.
public struct ParentGenesisLink: Codable, Hashable, Sendable {
    public let parentPath: [String]
    public let directory: String
    public let childGenesisCID: String
    public let parentStateCID: String

    public init(
        parentPath: [String],
        directory: String,
        childGenesisCID: String,
        parentStateCID: String
    ) {
        self.parentPath = parentPath
        self.directory = directory
        self.childGenesisCID =
            CIDIdentity.canonicalString(childGenesisCID) ?? childGenesisCID
        self.parentStateCID =
            CIDIdentity.canonicalString(parentStateCID) ?? parentStateCID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentPath = try container.decode([String].self, forKey: .parentPath)
        directory = try container.decode(String.self, forKey: .directory)
        let child = try container.decode(String.self, forKey: .childGenesisCID)
        childGenesisCID = CIDIdentity.canonicalString(child) ?? child
        let parentState = try container.decode(String.self, forKey: .parentStateCID)
        parentStateCID =
            CIDIdentity.canonicalString(parentState) ?? parentState
    }

    private enum CodingKeys: String, CodingKey {
        case parentPath
        case directory
        case childGenesisCID
        case parentStateCID
    }
}

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
    public let parentGenesisLink: ParentGenesisLink?
    public let parentStateContinuityLink: ParentStateContinuityLink?

    public init(
        proof: ChildBlockProof,
        parentGenesisLink: ParentGenesisLink? = nil,
        parentStateContinuityLink: ParentStateContinuityLink? = nil
    ) {
        self.proof = proof
        self.parentGenesisLink = parentGenesisLink
        self.parentStateContinuityLink = parentStateContinuityLink
    }

    /// Verify only the structural work carrier. Parent facts are intentionally
    /// outside this operation because they gate child admission, not relay.
    public func verifiedCarrierLink(
        child: Block,
        chainPath: [String]
    ) async -> Result<ParentCarrierLink, ChildProofVerificationFailure> {
        await proof.verifySecuringWork(
            child: child,
            chainPath: chainPath
        ).map {
            ParentCarrierLink(
                parentPath: chainPath,
                carrierCID: $0.childCID,
                rootCID: $0.grindID
            )
        }
    }
}

/// Node-owned acquisition needed before child-chain admission can continue.
/// Providers supply content-addressed evidence; the node derives every
/// state-validity fact locally before constructing this package.
public enum CrossChainEvidenceRequirement: Sendable, Equatable {
    case childProof(chainPath: [String], childCID: String)
    case parentGenesis(
        parentPath: [String],
        directory: String,
        childGenesisCID: String,
        parentStateCID: String
    )
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
    public let strongestAncestorWork: UInt256
    public let childCID: String
    public let terminalCarrierCID: String
    public let contribution: VerifiedWorkContribution?

    init(
        grindID: String,
        rootHash: UInt256,
        strongestAncestorWork: UInt256,
        childCID: String,
        terminalCarrierCID: String,
        contribution: VerifiedWorkContribution?
    ) {
        self.grindID = grindID
        self.rootHash = rootHash
        self.strongestAncestorWork = strongestAncestorWork
        self.childCID = childCID
        self.terminalCarrierCID = terminalCarrierCID
        self.contribution = contribution
    }
}
