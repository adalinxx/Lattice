import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

private let fetcher = ThrowingFetcher()

private func acceptanceSpec() -> ChainSpec {
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
        let spec = acceptanceSpec()
        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: 1_000_000, target: UInt256.max, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        let block1 = try await buildAndStoreBlock(
            previous: genesis, timestamp: 2_000_000,
            target: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let mined = BlockBuilder.mine(block: block1, target: UInt256.max, maxAttempts: 10)
        XCTAssertNotNil(mined)

        let header = try! VolumeImpl<Block>(node: mined!)
        let result = await chain.submitTestBlock(
            blockHeader: header, block: mined!
        )
        XCTAssertTrue(result.extendsMainChain)

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, header.rawCID)
    }

}
