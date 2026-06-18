import Foundation
import cashew
import UInt256

public struct GenesisConfig: Sendable {
    public let spec: ChainSpec
    public let timestamp: Int64
    public let target: UInt256
    // The chain's directory (name). Directory is positional and NOT stored in the
    // content-addressed `ChainSpec`; for a node this is operator config (the root
    // chain's name), not consensus data. Defaults to the conventional root name.
    public let directory: String

    public init(spec: ChainSpec, timestamp: Int64, target: UInt256, directory: String = DEFAULT_ROOT_DIRECTORY) {
        self.spec = spec
        self.timestamp = timestamp
        self.target = target
        self.directory = directory
    }

    public static func standard(spec: ChainSpec) -> GenesisConfig {
        GenesisConfig(spec: spec, timestamp: 0, target: UInt256.max)
    }
}

public struct GenesisResult: Sendable {
    public let block: Block
    public let blockHash: String
    public let chainState: ChainState

    public init(block: Block, blockHash: String, chainState: ChainState) {
        self.block = block
        self.blockHash = blockHash
        self.chainState = chainState
    }
}

public enum GenesisCeremony {

    public static func create(config: GenesisConfig, fetcher: Fetcher, retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE) async throws -> GenesisResult {
        let block = try await BlockBuilder.buildGenesis(
            spec: config.spec,
            timestamp: config.timestamp,
            target: config.target,
            fetcher: fetcher
        )
        let blockHash = try VolumeImpl<Block>(node: block).rawCID
        let chainState = ChainState.fromGenesis(block: block, retentionDepth: retentionDepth)
        return GenesisResult(block: block, blockHash: blockHash, chainState: chainState)
    }

    public static func verify(block: Block, config: GenesisConfig) -> Bool {
        guard block.height == 0 else { return false }
        guard block.parent == nil else { return false }
        guard block.timestamp == config.timestamp else { return false }
        guard block.spec.node != nil else { return false }
        guard block.target == config.target else { return false }
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        guard block.spec.rawCID == (try! VolumeImpl<ChainSpec>(node: config.spec).rawCID) else { return false }
        let emptyState = LatticeState.emptyHeader
        guard block.prevState.rawCID == emptyState.rawCID else { return false }
        return true
    }
}
