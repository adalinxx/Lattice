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
        self.childGenesisCID =
            CIDIdentity.canonicalString(childGenesisCID) ?? childGenesisCID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentPath = try container.decode([String].self, forKey: .parentPath)
        directory = try container.decode(String.self, forKey: .directory)
        let child = try container.decode(String.self, forKey: .childGenesisCID)
        childGenesisCID = CIDIdentity.canonicalString(child) ?? child
    }

    private enum CodingKeys: String, CodingKey {
        case parentPath
        case directory
        case childGenesisCID
    }
}

/// The complete cross-chain evidence required to validate one child candidate.
/// Sparse security proof and authenticated parent-issued facts remain distinct
/// values so neither can silently stand in for the other.
public struct ChildValidationPackage: Sendable {
    public let proof: ChildBlockProof
    public let parentCarrierLink: ParentCarrierLink?
    public let parentGenesisLink: ParentGenesisLink?

    public init(
        proof: ChildBlockProof,
        parentCarrierLink: ParentCarrierLink? = nil,
        parentGenesisLink: ParentGenesisLink? = nil
    ) {
        self.proof = proof
        self.parentCarrierLink = parentCarrierLink
        self.parentGenesisLink = parentGenesisLink
    }
}

/// Node-owned acquisition needed before child-chain admission can continue.
/// A child CID commits its parent-state root but does not identify a parent-chain
/// carrier; the authenticated parent process supplies these facts.
public enum CrossChainEvidenceRequirement: Sendable, Equatable {
    case childProof(chainPath: [String], childCID: String)
    case parentCarrier(parentPath: [String], carrierCID: String, rootCID: String)
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
    package let childCID: String
    package let contribution: VerifiedWorkContribution?

    init(
        grindID: String,
        rootHash: UInt256,
        strongestAncestorWork: UInt256,
        childCID: String,
        contribution: VerifiedWorkContribution?
    ) {
        self.grindID = grindID
        self.rootHash = rootHash
        self.strongestAncestorWork = strongestAncestorWork
        self.childCID = childCID
        self.contribution = contribution
    }
}
