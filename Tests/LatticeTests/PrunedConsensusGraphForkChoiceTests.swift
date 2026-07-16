import Foundation
import XCTest
@testable import Lattice
import cashew
import UInt256

final class ConsensusGraphPersistenceTests: XCTestCase {
    func testCompleteConsensusGraphAndRevisionSurviveRestore() async throws {
        let fetcher = StorableFetcher()
        let target = UInt256(1_000)
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 30_000
        let genesis = try await buildAndStoreGenesis(
            spec: consensusGraphSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let first = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 1_000,
            target: target,
            nonce: 1,
            fetcher: fetcher
        )
        let second = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 2_000,
            target: target,
            nonce: 2,
            fetcher: fetcher
        )
        let descendant = try await buildAndStoreBlock(
            previous: second,
            timestamp: base + 3_000,
            target: target,
            nonce: 3,
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        for block in [first, second, descendant] {
            let header = try BlockHeader(node: block)
            let result = await chain.submitBlock(
                blockHeader: header,
                block: block,
                contribution: VerifiedWorkContribution(
                    id: header.rawCID,
                    work: workForTarget(block.target)
                )
            )
            XCTAssertTrue(result.addedBlock)
        }

        let genesisHash = try BlockHeader(node: genesis).rawCID
        let firstHash = try BlockHeader(node: first).rawCID
        let secondHash = try BlockHeader(node: second).rawCID
        let descendantHash = try BlockHeader(node: descendant).rawCID
        let expectedHashes = Set([genesisHash, firstHash, secondHash, descendantHash])
        let snapshot = await chain.persist()
        let root = try XCTUnwrap(snapshot.blocks.first { $0.blockHash == genesisHash })
        let branch = try XCTUnwrap(snapshot.blocks.first { $0.blockHash == secondHash })

        XCTAssertEqual(snapshot.revision, 3)
        XCTAssertEqual(Set(snapshot.blocks.map(\.blockHash)), expectedHashes)
        XCTAssertEqual(Set(root.childHashes), [firstHash, secondHash])
        XCTAssertEqual(branch.childHashes, [descendantHash])

        let restored = try ChainState.restore(from: snapshot)
        let restoredSnapshot = await restored.persist()
        let originalRootWork = await chain.subtreeWeight(forHash: genesisHash)
        let restoredRootWork = await restored.subtreeWeight(forHash: genesisHash)
        let originalTip = await chain.getMainChainTip()
        let restoredTip = await restored.getMainChainTip()

        XCTAssertEqual(restoredSnapshot.revision, snapshot.revision)
        XCTAssertEqual(Set(restoredSnapshot.blocks.map(\.blockHash)), expectedHashes)
        XCTAssertEqual(restoredTip, originalTip)
        XCTAssertEqual(restoredRootWork, originalRootWork)
        XCTAssertTrue(restoredSnapshot.blocks.allSatisfy { !$0.workContributions.isEmpty })
    }
}

private func consensusGraphSpec() -> ChainSpec {
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
