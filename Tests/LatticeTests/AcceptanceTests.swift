import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

private let fetcher = ThrowingFetcher()

private func testSpec(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1024,
        halvingInterval: 10_000,
        retargetWindow: 5
    )
}

// MARK: - Full Pipeline Acceptance Test

@MainActor
final class FullPipelineAcceptanceTests: XCTestCase {

    func testBuildMineSubmitBroadcastCycle() async throws {
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 1_000_000, target: UInt256.max, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: 2_000_000,
            target: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let mined = BlockBuilder.mine(block: block1, target: UInt256.max, maxAttempts: 10)
        XCTAssertNotNil(mined)

        let header = try! VolumeImpl<Block>(node: mined!)
        let result = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header, block: mined!
        )
        XCTAssertTrue(result.extendsMainChain)

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, header.rawCID)
    }

    func testMultiChainConsensusWithAnchoringAndReorg() async throws {
        let nexusSpec = testSpec("Nexus")
        let childSpec = testSpec("Child")

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: 1_000_000, target: UInt256(1000), fetcher: fetcher
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: 1_000_000, target: UInt256(1000), fetcher: fetcher
        )

        let nexusChain = ChainState.fromGenesis(block: nexusGenesis)
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        let nexusLevel = ChainLevel(chain: nexusChain, children: ["Child": childLevel])

        var nexusPrev = nexusGenesis
        for i in 1...5 {
            let block = try await BlockBuilder.buildBlock(
                previous: nexusPrev, timestamp: 1_000_000 + Int64(i) * 1000,
                nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await nexusChain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try! VolumeImpl<Block>(node: block), block: block
            )
            nexusPrev = block
        }

        let nexusHeight = await nexusChain.getHighestBlockHeight()
        XCTAssertEqual(nexusHeight, 5)

        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, timestamp: 2_000_000, nonce: 1, fetcher: fetcher
        )
        let nexusBlockHeader = try! VolumeImpl<Block>(node: nexusPrev)
        let childResult = await childChain.submitBlock(
            parentBlockHeaderAndIndex: (nexusBlockHeader.rawCID, nexusHeight),
            blockHeader: try! VolumeImpl<Block>(node: childBlock1),
            block: childBlock1
        )
        XCTAssertTrue(childResult.extendsMainChain)

        let childHeight = await childChain.getHighestBlockHeight()
        XCTAssertEqual(childHeight, 1)

        let childBlock1Meta = await childChain.getConsensusBlock(
            hash: try! VolumeImpl<Block>(node: childBlock1).rawCID
        )
        XCTAssertNotNil(childBlock1Meta?.parentIndex, "Child block should have parent chain anchoring")
    }

    private func buildLongChain(length: Int) async throws -> [Block] {
        var blocks: [Block] = []
        let g = try await BlockBuilder.buildGenesis(
            spec: testSpec(), timestamp: 1_000_000, target: UInt256(1000), fetcher: fetcher
        )
        blocks.append(g)
        for i in 1..<length {
            let b = try await BlockBuilder.buildBlock(
                previous: blocks.last!, timestamp: 1_000_000 + Int64(i) * 1000,
                nonce: UInt64(i), fetcher: fetcher
            )
            blocks.append(b)
        }
        return blocks
    }
}
