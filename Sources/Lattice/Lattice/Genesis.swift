import Foundation
import cashew
import UInt256

public struct GenesisConfig: Sendable {
    public let spec: ChainSpec
    public let timestamp: Int64
    public let target: UInt256

    public init(spec: ChainSpec, timestamp: Int64, target: UInt256) {
        self.spec = spec
        self.timestamp = timestamp
        self.target = target
    }

    public static func standard(spec: ChainSpec) -> GenesisConfig {
        GenesisConfig(spec: spec, timestamp: 0, target: UInt256.max)
    }
}

public struct GenesisResult: Sendable {
    public let block: Block
    public let blockHash: String

    public init(block: Block, blockHash: String) {
        self.block = block
        self.blockHash = blockHash
    }
}

public enum GenesisCeremonyError: Error, Sendable, Equatable {
    case invalidTarget
}

public enum GenesisCeremony {

    /// Build a deterministic root-genesis candidate. Runtime creation belongs to
    /// the store-and-stage `ChainLevel.bootstrap` admission boundary.
    public static func create(
        config: GenesisConfig,
        fetcher: Fetcher
    ) async throws -> GenesisResult {
        guard config.target >= ChainSpec.minimumTarget else {
            throw GenesisCeremonyError.invalidTarget
        }
        let block = try await BlockBuilder.buildGenesis(
            spec: config.spec,
            timestamp: config.timestamp,
            target: config.target,
            fetcher: fetcher
        )
        let blockHash = try VolumeImpl<Block>(node: block).rawCID
        return GenesisResult(block: block, blockHash: blockHash)
    }

    public static func verify(block: Block, config: GenesisConfig) -> Bool {
        guard config.target >= ChainSpec.minimumTarget else { return false }
        guard block.hasGenesisAdmissionShape() else { return false }
        guard block.timestamp == config.timestamp else { return false }
        guard block.spec.node != nil else { return false }
        guard block.target == config.target else { return false }
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        guard block.spec.rawCID == (try! VolumeImpl<ChainSpec>(node: config.spec).rawCID) else { return false }
        return true
    }
}
