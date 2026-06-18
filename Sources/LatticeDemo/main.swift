import Lattice
import UInt256
import cashew
import Foundation

struct NoopFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw NSError(domain: "NoopFetcher", code: 1)
    }
}

print("Lattice Demo")
print("============")
print()

let spec = ChainSpec(
    maxNumberOfTransactionsPerBlock: 100,
    maxStateGrowth: 100_000,
    premine: 0,
    targetBlockTime: 10_000,
    initialReward: 1_000_000_000,
    halvingInterval: 15_768_000
)

print("Chain spec: \(DEFAULT_ROOT_DIRECTORY)")
print("  Initial reward: \(spec.initialReward) tokens")
print("  Halving interval: \(spec.halvingInterval) blocks")
print("  Target block time: \(spec.targetBlockTime)ms")
print("  Max transactions/block: \(spec.maxNumberOfTransactionsPerBlock)")
print()

let fetcher = NoopFetcher()

Task {
    let genesis = try await BlockBuilder.buildGenesis(
        spec: spec,
        timestamp: Int64(Date().timeIntervalSince1970 * 1000),
        target: UInt256(1000),
        fetcher: fetcher
    )
    let genesisHeader = try VolumeImpl<Block>(node: genesis)
    print("Genesis block CID: \(genesisHeader.rawCID)")
    print("Genesis target hash: \(genesis.proofOfWorkHash())")
    print()

    let chain = ChainState.fromGenesis(block: genesis)

    print("Building a 5-block chain...")
    var prev = genesis
    var prevTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
    for i in 1...5 {
        prevTimestamp += 1000
        let block = try await BlockBuilder.buildBlock(
            previous: prev,
            timestamp: prevTimestamp,
            target: UInt256(1000),
            nonce: UInt64(i),
            fetcher: fetcher
        )
        let header = try VolumeImpl<Block>(node: block)
        let result = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: header,
            block: block
        )
        print("  Block \(i): CID=\(String(header.rawCID.prefix(20)))... extends=\(result.extendsMainChain)")
        prev = block
    }

    let tip = await chain.getMainChainTip()
    let highest = await chain.getHighestBlockHeight()
    print()
    print("Chain state:")
    print("  Tip: \(String(tip.prefix(20)))...")
    print("  Height: \(highest)")
    print()

    print("Creating a longer fork from genesis (6 blocks)...")
    var forkPrev = genesis
    let forkBaseTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
    for i in 1...6 {
        let block = try await BlockBuilder.buildBlock(
            previous: forkPrev,
            timestamp: forkBaseTimestamp + Int64(i) * 1000,
            target: UInt256(1000),
            nonce: UInt64(100 + i),
            fetcher: fetcher
        )
        let header = try VolumeImpl<Block>(node: block)
        let result = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: header,
            block: block
        )
        let reorged = result.reorganization != nil ? " [REORG]" : ""
        print("  Fork block \(i): extends=\(result.extendsMainChain)\(reorged)")
        forkPrev = block
    }

    let newTip = await chain.getMainChainTip()
    let newHighest = await chain.getHighestBlockHeight()
    print()
    print("After fork:")
    print("  Tip: \(String(newTip.prefix(20)))...")
    print("  Height: \(newHighest)")
    print("  Tip changed: \(tip != newTip)")
    print()
    print("Demo complete.")

    exit(0)
}

RunLoop.main.run()
