import Foundation
import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import cashew
import UInt256

final class ConsensusGraphRecoveryTests: XCTestCase {
    func testCompleteConsensusGraphAndRevisionSurviveFactReplay() async throws {
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
        let rootValue = await chain.getConsensusBlock(hash: genesisHash)
        let branchValue = await chain.getConsensusBlock(hash: secondHash)
        let root = try XCTUnwrap(rootValue)
        let branch = try XCTUnwrap(branchValue)

        let revision = await chain.currentRevision()
        XCTAssertEqual(revision, 3)
        for hash in expectedHashes {
            let contains = await chain.contains(blockHash: hash)
            XCTAssertTrue(contains)
        }
        XCTAssertEqual(Set(root.childHashes), [firstHash, secondHash])
        XCTAssertEqual(branch.childHashes, [descendantHash])

        let restored = try await ChainState.restore(replaying: [
            testAdmissionBatch(for: genesis),
            testAdmissionBatch(for: first),
            testAdmissionBatch(for: second),
            testAdmissionBatch(for: descendant),
        ])
        let originalRootWork = await chain.subtreeWeight(forHash: genesisHash)
        let restoredRootWork = await restored.subtreeWeight(forHash: genesisHash)
        let originalTip = await chain.canonicalTip
        let restoredTip = await restored.canonicalTip

        let restoredRevision = await restored.currentRevision()
        // Replay counts the genesis insert as a mutation; the live chain here
        // was seeded by the test-only `fromGenesis` at revision 0.
        XCTAssertEqual(restoredRevision, revision + 1)
        for hash in expectedHashes {
            let contains = await restored.contains(blockHash: hash)
            XCTAssertTrue(contains)
        }
        XCTAssertEqual(restoredTip, originalTip)
        XCTAssertEqual(restoredRootWork, originalRootWork)
        for hash in expectedHashes {
            let value = await restored.getConsensusBlock(hash: hash)
            let meta = try XCTUnwrap(value)
            XCTAssertFalse(meta.workContributions.isEmpty)
        }
    }
}

private func consensusGraphSpec() -> ChainSpec {
    ChainSpec.test()
}
