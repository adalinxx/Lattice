import Foundation
import XCTest
@testable import Lattice
import UInt256

final class FactReplayRecoveryTests: XCTestCase {
    func testFactReplayIsOrderIndependentAndRecomputesForkChoice() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: recoverySpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let light = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2,
            target: UInt256.max,
            nonce: 1,
            fetcher: fetcher
        )
        let heavy = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 3,
            target: UInt256.max / UInt256(2),
            nonce: 2,
            fetcher: fetcher
        )
        let batches = try [genesis, light, heavy].map {
            try testAdmissionBatch(for: $0)
        }

        let forward = try await ChainState.restore(replaying: batches)
        let reverse = try await ChainState.restore(replaying: Array(batches.reversed()))
        let heavyCID = try BlockHeader(node: heavy).rawCID

        let forwardTip = await forward.getMainChainTip()
        let reverseTip = await reverse.getMainChainTip()
        let forwardWork = await forward.getTipCumulativeWork()
        let reverseWork = await reverse.getTipCumulativeWork()
        XCTAssertEqual(forwardTip, heavyCID)
        XCTAssertEqual(reverseTip, heavyCID)
        XCTAssertEqual(forwardWork, reverseWork)
    }

    func testFactReplayIsIdempotentAcrossEncodedDurableBatches() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: recoverySpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let block = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2,
            target: UInt256.max,
            fetcher: fetcher
        )
        let batches = try [genesis, block].map {
            try testAdmissionBatch(for: $0)
        }
        let encoded = try JSONEncoder().encode(batches)
        let decoded = try JSONDecoder().decode([ChainAdmissionBatch].self, from: encoded)

        let restored = try await ChainState.restore(
            replaying: decoded + Array(decoded.reversed())
        )

        let restoredTip = await restored.getMainChainTip()
        let revision = await restored.currentRevision()
        XCTAssertEqual(restoredTip, try BlockHeader(node: block).rawCID)
        XCTAssertEqual(revision, 1)
    }

    func testFactReplayRejectsMissingGenesisAndConflictingImmutableFacts() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: recoverySpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let block = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2,
            target: UInt256.max,
            fetcher: fetcher
        )
        let genesisBatch = try testAdmissionBatch(for: genesis)
        let blockBatch = try testAdmissionBatch(for: block)

        await XCTAssertThrowsErrorAsync(
            try await ChainState.restore(replaying: [blockBatch])
        )

        guard case .block(let fact) = blockBatch.facts[0] else {
            return XCTFail("expected block fact")
        }
        let conflicting = ChainAdmissionBatch(facts: [
            .block(ChainBlockFact(
                blockHash: fact.blockHash,
                parentBlockHash: fact.parentBlockHash,
                blockHeight: fact.blockHeight,
                postStateCID: fact.postStateCID,
                prevStateCID: fact.prevStateCID,
                specCID: fact.specCID,
                target: fact.target,
                nextTarget: fact.nextTarget,
                timestamp: fact.timestamp + 1,
                stateDiff: fact.stateDiff
            )),
            blockBatch.facts[1],
        ])
        await XCTAssertThrowsErrorAsync(
            try await ChainState.restore(
                replaying: [genesisBatch, blockBatch, conflicting]
            )
        )
    }

    func testZeroWorkGenesisSurvivesDurableReplay() async throws {
        // A zero-work (target 0) genesis is exempt from the positive-work rule in
        // memory; it must ALSO restore from durable facts after a restart rather
        // than becoming corruptConsensusGraph — the in-memory and durable/replay
        // paths agree that genesis is the one work-exempt block.
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: recoverySpec(),
            timestamp: 1,
            target: .zero,
            fetcher: fetcher
        )
        let batch = try testAdmissionBatch(for: genesis)
        // Sanity: the work fact really is zero-work, so this exercises the exemption.
        if case .work(let fact) = batch.facts[1] {
            XCTAssertEqual(fact.contribution.work, .zero)
        } else {
            return XCTFail("expected a work fact")
        }

        let restored = try await ChainState.restore(replaying: [batch])
        let tip = await restored.getMainChainTip()
        XCTAssertEqual(tip, try BlockHeader(node: genesis).rawCID)
    }

    func testRevisionFloorIsFinalAndStableAcrossRepeatedRecovery() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: recoverySpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let block = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2,
            target: UInt256.max,
            fetcher: fetcher
        )
        let batches = try [genesis, block].map {
            try testAdmissionBatch(for: $0)
        }

        let first = try await ChainState.restore(
            replaying: batches,
            revisionFloor: 100
        )
        let second = try await ChainState.restore(
            replaying: batches,
            revisionFloor: await first.currentRevision()
        )

        let firstRevision = await first.currentRevision()
        let secondRevision = await second.currentRevision()
        XCTAssertEqual(firstRevision, 100)
        XCTAssertEqual(secondRevision, 100)
    }

}

private func recoverySpec() -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1,
        halvingInterval: 1_000
    )
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
