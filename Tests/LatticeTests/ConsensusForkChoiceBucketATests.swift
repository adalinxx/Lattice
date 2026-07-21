import Foundation
import XCTest
@testable import Lattice
import cashew
import UInt256

private func bucketFetcher() -> StorableFetcher { StorableFetcher() }

private func bucketSpec() -> ChainSpec {
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

private func bucketContribution(_ id: String, work: UInt256 = UInt256(1)) -> VerifiedWorkContribution {
    VerifiedWorkContribution(id: testCID(id), work: work)
}

private let persistedGenesisCID = "bafyreieonsjxgx7d7cnbebfixgzcdoxopsbrfbbgujnqp74przhtmmbn5a"

final class ConsensusForkChoiceBucketATests: XCTestCase {
    private var forkMainSet: Set<String> { ["G", "M1", "M2"] }

    private func forkDag() -> [BlockMeta] {
        let mainWork = UInt256(2)
        let forkWork = UInt256(1)
        return [
            makeBlockMeta(hash: "G", height: 0, childHashes: ["M1", "F1"], work: forkWork, cumulativeWork: UInt256(1)),
            makeBlockMeta(hash: "M1", previousHash: "G", height: 1, childHashes: ["M2"], work: mainWork, cumulativeWork: UInt256(3)),
            makeBlockMeta(hash: "M2", previousHash: "M1", height: 2, work: mainWork, cumulativeWork: UInt256(5)),
            makeBlockMeta(hash: "F1", previousHash: "G", height: 1, childHashes: ["F2"], work: forkWork, cumulativeWork: UInt256(2)),
            makeBlockMeta(hash: "F2", previousHash: "F1", height: 2, childHashes: ["F3"], work: forkWork, cumulativeWork: UInt256(3)),
            makeBlockMeta(hash: "F3", previousHash: "F2", height: 3, childHashes: ["F4"], work: forkWork, cumulativeWork: UInt256(4)),
            makeBlockMeta(hash: "F4", previousHash: "F3", height: 4, childHashes: ["F5"], work: forkWork, cumulativeWork: UInt256(5)),
            makeBlockMeta(hash: "F5", previousHash: "F4", height: 5, work: forkWork, cumulativeWork: UInt256(6)),
        ]
    }

    func testStrictlyHeavierFullyAvailableBranchWins() async {
        let chain = makeChain(blocks: forkDag(), mainChainHashes: forkMainSet)
        _ = await chain.reevaluateForkChoice()

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, "F5")
    }

    func testWindowedCumulativeWorkIsExactBeyondUInt256() async throws {
        let fetcher = bucketFetcher()
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 50_000
        let target = UInt256(1)
        let genesis = try await buildAndStoreGenesis(
            spec: bucketSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let block = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 1_000,
            target: target,
            nextTarget: target,
            nonce: 1,
            fetcher: fetcher
        )

        _ = await chain.submitTestBlock(blockHeader: try BlockHeader(node: block), block: block)

        let cumulativeWork = await chain.getCumulativeWork(limit: 10)
        XCTAssertEqual(cumulativeWork, WorkSum(UInt256.max) + UInt256.max)
        XCTAssertGreaterThan(cumulativeWork, WorkSum(UInt256.max))
    }

    func testRestoreRejectsUndecodableTarget() {
        let block = PersistedBlockMeta(
            blockHash: persistedGenesisCID,
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            workContributions: [bucketContribution("grind:G")],
            target: "not-hex"
        )
        let persisted = PersistedChainState(
            chainTip: persistedGenesisCID,
            mainChainHashes: [persistedGenesisCID],
            blocks: [block]
        )

        XCTAssertThrowsError(try ChainState.restore(from: persisted)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreRejectsUndecodableNextTarget() {
        let block = PersistedBlockMeta(
            blockHash: persistedGenesisCID,
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            workContributions: [bucketContribution("grind:G")],
            nextTarget: "not-hex"
        )
        let persisted = PersistedChainState(
            chainTip: persistedGenesisCID,
            mainChainHashes: [persistedGenesisCID],
            blocks: [block]
        )

        XCTAssertThrowsError(try ChainState.restore(from: persisted)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreAllowsAbsentTargetWhenWorkContributionIsPresent() throws {
        let block = PersistedBlockMeta(
            blockHash: persistedGenesisCID,
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            workContributions: [bucketContribution("grind:G")]
        )
        let persisted = PersistedChainState(
            chainTip: persistedGenesisCID,
            mainChainHashes: [persistedGenesisCID],
            blocks: [block]
        )

        XCTAssertNoThrow(try ChainState.restore(from: persisted))
    }

    func testRestoreRejectsMalformedBlockCID() {
        let block = PersistedBlockMeta(
            blockHash: "G",
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            workContributions: [bucketContribution("grind:G")]
        )
        let persisted = PersistedChainState(
            chainTip: "G",
            mainChainHashes: ["G"],
            blocks: [block]
        )

        XCTAssertThrowsError(try ChainState.restore(from: persisted)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreRejectsUnsupportedPersistenceSchema() {
        let block = PersistedBlockMeta(
            blockHash: persistedGenesisCID,
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            workContributions: [bucketContribution("grind:G")]
        )
        for schemaVersion in [
            PersistedChainState.currentSchemaVersion - 1,
            PersistedChainState.currentSchemaVersion + 1,
        ] {
            let persisted = PersistedChainState(
                schemaVersion: schemaVersion,
                chainTip: persistedGenesisCID,
                mainChainHashes: [persistedGenesisCID],
                blocks: [block]
            )

            XCTAssertThrowsError(try ChainState.restore(from: persisted)) { error in
                XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
            }
        }
    }
}
