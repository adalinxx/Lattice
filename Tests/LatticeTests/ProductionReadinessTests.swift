import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

private let fetcher = ThrowingFetcher()

// MARK: - Genesis Ceremony Tests

@MainActor
final class GenesisCeremonyTests: XCTestCase {

    func testCreateDeterministicGenesis() async throws {
        let config = GenesisConfig.standard(spec: ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000
        ))

        let result1 = try await GenesisCeremony.create(config: config, fetcher: fetcher)
        let result2 = try await GenesisCeremony.create(config: config, fetcher: fetcher)

        XCTAssertEqual(result1.blockHash, result2.blockHash,
            "Same genesis config must produce identical genesis block")

        let tip1 = await result1.chainState.getMainChainTip()
        let tip2 = await result2.chainState.getMainChainTip()
        XCTAssertEqual(tip1, tip2)
    }

    func testVerifyValidGenesis() async throws {
        let config = GenesisConfig(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 1024, halvingInterval: 10_000
            ),
            timestamp: 42,
            target: UInt256(1000)
        )
        let result = try await GenesisCeremony.create(config: config, fetcher: fetcher)
        XCTAssertTrue(GenesisCeremony.verify(block: result.block, config: config))
    }

    func testVerifyRejectsWrongTimestamp() async throws {
        let config = GenesisConfig(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 1024, halvingInterval: 10_000
            ),
            timestamp: 42,
            target: UInt256(1000)
        )
        let result = try await GenesisCeremony.create(config: config, fetcher: fetcher)

        let wrongConfig = GenesisConfig(
            spec: config.spec, timestamp: 999, target: config.target
        )
        XCTAssertFalse(GenesisCeremony.verify(block: result.block, config: wrongConfig))
    }

    func testVerifyRejectsDifficultyMismatch() async throws {
        let specA = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000
        )
        let configA = GenesisConfig(spec: specA, timestamp: 0, target: UInt256.max)
        let result = try await GenesisCeremony.create(config: configA, fetcher: fetcher)

        let configB = GenesisConfig(spec: specA, timestamp: 0, target: UInt256(1))
        XCTAssertTrue(GenesisCeremony.verify(block: result.block, config: configA))
        XCTAssertFalse(GenesisCeremony.verify(block: result.block, config: configB))
    }

    func testVerifyRejectsSpecMismatch() async throws {
        let specA = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000
        )
        // ChainSpec no longer carries a directory; mismatch on a real field (premine)
        // so the two specs genuinely differ.
        let specB = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 999,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000
        )
        let configA = GenesisConfig(spec: specA, timestamp: 0, target: UInt256.max)
        let result = try await GenesisCeremony.create(config: configA, fetcher: fetcher)

        let configC = GenesisConfig(spec: specB, timestamp: 0, target: UInt256.max)
        XCTAssertTrue(GenesisCeremony.verify(block: result.block, config: configA))
        XCTAssertFalse(GenesisCeremony.verify(block: result.block, config: configC))
    }

    func testGenesisChainStateIsUsable() async throws {
        let config = GenesisConfig.standard(spec: ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000
        ))
        let result = try await GenesisCeremony.create(config: config, fetcher: fetcher)

        let height = await result.chainState.getHighestBlockHeight()
        XCTAssertEqual(height, 0)

        let contains = await result.chainState.contains(blockHash: result.blockHash)
        XCTAssertTrue(contains)

        let onMain = await result.chainState.isOnMainChain(hash: result.blockHash)
        XCTAssertTrue(onMain)

        let block1 = try await BlockBuilder.buildBlock(
            previous: result.block, timestamp: 1_000, target: UInt256.max,
            nonce: 1, fetcher: fetcher
        )
        let submitResult = await result.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try! VolumeImpl<Block>(node: block1),
            block: block1
        )
        XCTAssertTrue(submitResult.extendsMainChain, "Should be able to extend genesis chain")
    }
}

// MARK: - Block Validation on Receipt Tests

@MainActor
final class BlockReceptionTests: XCTestCase {

    func testReceivedBlockDataIsStoredAndResolvable() async throws {
        let config = GenesisConfig.standard(spec: ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000
        ))

        let storableFetcher = StorableFetcher()

        let result = try await GenesisCeremony.create(config: config, fetcher: fetcher)
        if let data = result.block.toData() {
            await storableFetcher.store(rawCid: result.blockHash, data: data)
        }

        let block1 = try await BlockBuilder.buildBlock(
            previous: result.block, timestamp: 1_000,
            target: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let block1Hash = try! VolumeImpl<Block>(node: block1).rawCID
        guard let block1Data = block1.toData() else {
            XCTFail("Block serialization failed")
            return
        }

        await storableFetcher.store(rawCid: block1Hash, data: block1Data)

        let fetchedData = try await storableFetcher.fetch(rawCid: block1Hash)
        XCTAssertEqual(fetchedData, block1Data)

        let resolvedBlock = Block(data: fetchedData)
        XCTAssertNotNil(resolvedBlock, "Block must deserialize from stored data")
    }

    func testSubmitBlockAfterStoringData() async throws {
        let config = GenesisConfig.standard(spec: ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000
        ))
        let result = try await GenesisCeremony.create(config: config, fetcher: fetcher)

        let block1 = try await BlockBuilder.buildBlock(
            previous: result.block, timestamp: 1_000,
            target: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let header = try! VolumeImpl<Block>(node: block1)
        let submitResult = await result.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: header,
            block: block1
        )
        XCTAssertTrue(submitResult.extendsMainChain)

        let tip = await result.chainState.getMainChainTip()
        XCTAssertEqual(tip, header.rawCID)
    }
}

// MARK: - End-to-End: Genesis -> Mine -> Submit -> Verify

@MainActor
final class GenesisToBlockE2ETests: XCTestCase {

    func testFullCycle() async throws {
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000
        )
        let genesisConfig = GenesisConfig.standard(spec: spec)
        let genesis = try await GenesisCeremony.create(config: genesisConfig, fetcher: fetcher)

        XCTAssertTrue(GenesisCeremony.verify(block: genesis.block, config: genesisConfig))

        var prev = genesis.block
        for i in 1...10 {
            let template = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: Int64(i) * 1000,
                target: UInt256.max, nonce: 0, fetcher: fetcher
            )
            let mined = BlockBuilder.mine(block: template, target: UInt256.max, maxAttempts: 10)!

            let header = try! VolumeImpl<Block>(node: mined)
            let result = await genesis.chainState.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: header,
                block: mined
            )
            XCTAssertTrue(result.extendsMainChain, "Block \(i) should extend")
            prev = mined
        }

        let height = await genesis.chainState.getHighestBlockHeight()
        XCTAssertEqual(height, 10)

        let tipHash = await genesis.chainState.getMainChainTip()
        XCTAssertEqual(tipHash, try! VolumeImpl<Block>(node: prev).rawCID)

        let genesisOnMain = await genesis.chainState.isOnMainChain(hash: genesis.blockHash)
        XCTAssertTrue(genesisOnMain)
    }

    func testTwoNodesSameGenesis() async throws {
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000
        )
        let genesisConfig = GenesisConfig.standard(spec: spec)

        let nodeA = try await GenesisCeremony.create(config: genesisConfig, fetcher: fetcher)
        let nodeB = try await GenesisCeremony.create(config: genesisConfig, fetcher: fetcher)

        XCTAssertEqual(nodeA.blockHash, nodeB.blockHash, "Both nodes must agree on genesis")

        let blockA1 = try await BlockBuilder.buildBlock(
            previous: nodeA.block, timestamp: 1_000,
            target: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let headerA1 = try! VolumeImpl<Block>(node: blockA1)

        let resultOnA = await nodeA.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: headerA1, block: blockA1
        )
        XCTAssertTrue(resultOnA.extendsMainChain)

        let resultOnB = await nodeB.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: headerA1, block: blockA1
        )
        XCTAssertTrue(resultOnB.extendsMainChain, "Node B accepts block mined by Node A")

        let tipA = await nodeA.chainState.getMainChainTip()
        let tipB = await nodeB.chainState.getMainChainTip()
        XCTAssertEqual(tipA, tipB, "Both nodes must agree on chain tip")
    }

    func testTwoNodesReachConsensusAfterFork() async throws {
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000
        )
        let genesisConfig = GenesisConfig.standard(spec: spec)
        let nodeA = try await GenesisCeremony.create(config: genesisConfig, fetcher: fetcher)
        let nodeB = try await GenesisCeremony.create(config: genesisConfig, fetcher: fetcher)

        let blockA1 = try await BlockBuilder.buildBlock(
            previous: nodeA.block, timestamp: 1_000,
            target: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let blockA2 = try await BlockBuilder.buildBlock(
            previous: blockA1, timestamp: 2_000,
            target: UInt256.max, nonce: 2, fetcher: fetcher
        )

        let blockB1 = try await BlockBuilder.buildBlock(
            previous: nodeB.block, timestamp: 1_000,
            target: UInt256.max, nonce: 100, fetcher: fetcher
        )

        let _ = await nodeA.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl(node: blockA1), block: blockA1
        )
        let _ = await nodeA.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl(node: blockA2), block: blockA2
        )

        let _ = await nodeB.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl(node: blockB1), block: blockB1
        )

        let tipB_before = await nodeB.chainState.getMainChainTip()
        XCTAssertEqual(tipB_before, try! VolumeImpl<Block>(node: blockB1).rawCID)

        let _ = await nodeB.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl(node: blockA1), block: blockA1
        )
        let resultA2onB = await nodeB.chainState.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl(node: blockA2), block: blockA2
        )

        XCTAssertNotNil(resultA2onB.reorganization, "Node B should reorg to longer chain from A")

        let tipA = await nodeA.chainState.getMainChainTip()
        let tipB = await nodeB.chainState.getMainChainTip()
        XCTAssertEqual(tipA, tipB, "Both nodes must converge on same tip after reorg")
    }
}
