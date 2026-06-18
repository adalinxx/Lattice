import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

// F5-3: blocks accepted via sync must carry their proof-of-work into the
// persisted chain state. The shared walk decodes each block and knows its
// target, but `buildResult` previously dropped it — every synced
// `PersistedBlockMeta` had no target, so `work = 0` after restore and the
// chain reported ZERO cumulative work. That breaks work comparison and fork
// choice for any node that synced (vs. mined locally). These tests assert a
// restored, synced chain reports the correct non-zero cumulative work.

private func spec(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: 0, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
}
private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

private func storeBlock(_ block: Block, to fetcher: StorableFetcher) async throws {
    let storer = CollectingStorer()
    try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
    await storer.flush(to: fetcher)
}

private let noopStore: @Sendable (String, Data) async -> Void = { _, _ in }

final class SyncBlockWorkTests: XCTestCase {

    // target = max ⇒ target = max ⇒ PoW trivially valid, and
    // work = max / max = 1 per block, so total work == block count.
    private let easy = UInt256.max
    private let highWorkDifficulty = UInt256(10)
    private let lowWorkDifficulty = UInt256(100)

    /// Build genesis + `count` extending blocks, store all in `fetcher`,
    /// return (tipCID, genesisCID).
    private func buildChain(count: Int, into fetcher: StorableFetcher) async throws -> (tip: String, genesis: String) {
        let base = now() - 100_000
        let genesis = try await BlockBuilder.buildGenesis(spec: spec(), timestamp: base, target: easy, fetcher: fetcher)
        try await storeBlock(genesis, to: fetcher)
        var prev = genesis
        for i in 1...count {
            let b = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: base + Int64(i) * 1000,
                target: easy, nonce: UInt64(i), fetcher: fetcher
            )
            try await storeBlock(b, to: fetcher)
            prev = b
        }
        return (try! VolumeImpl<Block>(node: prev).rawCID, try! VolumeImpl<Block>(node: genesis).rawCID)
    }

    private func work(for target: UInt256) -> UInt256 {
        UInt256.max / target
    }

    private func totalWork(for difficulties: [UInt256]) -> UInt256 {
        difficulties.reduce(UInt256.zero) { $0 &+ work(for: $1) }
    }

    private func tipEstimate(for difficulties: [UInt256]) -> UInt256 {
        work(for: difficulties.last!) &* UInt256(difficulties.count)
    }

    private func buildMixedDifficultyChain(
        difficulties: [UInt256],
        into fetcher: StorableFetcher
    ) async throws -> (tip: String, genesis: String, headers: [SyncBlockHeader]) {
        precondition(!difficulties.isEmpty)

        let base = now() - 100_000
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec(), timestamp: base, target: difficulties[0], fetcher: fetcher)
        try await storeBlock(genesis, to: fetcher)

        var headers = [
            SyncBlockHeader(
                cid: try! VolumeImpl<Block>(node: genesis).rawCID,
                height: genesis.height,
                previousBlockCID: nil,
                target: genesis.target,
                timestamp: genesis.timestamp)
        ]
        var prev = genesis
        for (offset, target) in difficulties.dropFirst().enumerated() {
            let b = try await BlockBuilder.buildBlock(
                previous: prev,
                timestamp: base + Int64(offset + 1) * 1000,
                target: target,
                nonce: UInt64(offset + 1),
                fetcher: fetcher
            )
            try await storeBlock(b, to: fetcher)
            headers.append(SyncBlockHeader(
                cid: try! VolumeImpl<Block>(node: b).rawCID,
                height: b.height,
                previousBlockCID: b.parent?.rawCID,
                target: b.target,
                timestamp: b.timestamp))
            prev = b
        }

        return (
            try! VolumeImpl<Block>(node: prev).rawCID,
            try! VolumeImpl<Block>(node: genesis).rawCID,
            headers)
    }

    private func assertInsufficientWork(
        _ operation: @escaping () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected insufficient work", file: file, line: line)
        } catch SyncError.insufficientWork {
            return
        } catch {
            XCTFail("expected insufficient work, got \(error)", file: file, line: line)
        }
    }

    private func mixedDifficultySyncer(fetcher: StorableFetcher, genesis: String) -> ChainSyncer {
        ChainSyncer(
            fetcher: fetcher,
            store: noopStore,
            genesisBlockHash: genesis,
            validateBlockConsensus: false
        )
    }

    func testSnapshotSyncRestoresNonZeroCumulativeWork() async throws {
        let fetcher = StorableFetcher()
        let (tip, genesis) = try await buildChain(count: 3, into: fetcher) // 4 blocks total

        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesis)
        let result = try await syncer.syncSnapshot(peerTipCID: tip)

        // The walk's running total already worked; the bug was in what gets persisted.
        XCTAssertEqual(result.cumulativeWork, UInt256(4), "walk total = 4 blocks * work 1")

        let chain = try ChainState.restore(from: result.persisted)
        let restoredWork = await chain.getCumulativeWork(limit: 100)
        XCTAssertEqual(restoredWork, UInt256(4), "restored synced chain reports full per-block work (was 0 before fix)")
        XCTAssertTrue(restoredWork > UInt256.zero, "synced chain must not report zero work")
    }

    func testFullSyncRestoresNonZeroCumulativeWork() async throws {
        let fetcher = StorableFetcher()
        let (tip, genesis) = try await buildChain(count: 2, into: fetcher) // 3 blocks total

        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesis)
        let result = try await syncer.syncFull(peerTipCID: tip)

        let chain = try ChainState.restore(from: result.persisted)
        let restoredWork = await chain.getCumulativeWork(limit: 100)
        XCTAssertEqual(restoredWork, UInt256(3), "full-synced chain carries per-block work for all 3 blocks")
    }

    /// Headers-first path: `syncFromHeaders` must also persist each header's
    /// target so the restored chain reports non-zero work. Guards against a
    /// regression that drops `SyncBlockHeader.target` in the map.
    func testHeadersFirstSyncRestoresNonZeroCumulativeWork() async throws {
        let fetcher = StorableFetcher()
        let base = now() - 100_000

        // Build a 3-block chain, capturing each block's SyncBlockHeader.
        var headers: [SyncBlockHeader] = []
        let genesis = try await BlockBuilder.buildGenesis(spec: spec(), timestamp: base, target: easy, fetcher: fetcher)
        try await storeBlock(genesis, to: fetcher)
        headers.append(SyncBlockHeader(cid: try! VolumeImpl<Block>(node: genesis).rawCID, height: 0,
                                       previousBlockCID: nil, target: genesis.target,
                                       nextTarget: genesis.nextTarget, timestamp: genesis.timestamp,
                                       specCID: genesis.spec.rawCID, spec: genesis.spec.node))
        var prev = genesis
        for i in 1...2 {
            let b = try await BlockBuilder.buildBlock(previous: prev, timestamp: base + Int64(i) * 1000,
                                                      target: easy, nonce: UInt64(i), fetcher: fetcher)
            try await storeBlock(b, to: fetcher)
            headers.append(SyncBlockHeader(cid: try! VolumeImpl<Block>(node: b).rawCID, height: b.height,
                                           previousBlockCID: b.parent?.rawCID, target: b.target,
                                           nextTarget: b.nextTarget, timestamp: b.timestamp,
                                           specCID: b.spec.rawCID, spec: b.spec.node))
            prev = b
        }

        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore,
                                 genesisBlockHash: try! VolumeImpl<Block>(node: genesis).rawCID)
        let result = try await syncer.syncFromHeaders(headers, cumulativeWork: UInt256(3))

        let chain = try ChainState.restore(from: result.persisted)
        let restoredWork = await chain.getCumulativeWork(limit: 100)
        XCTAssertEqual(restoredWork, UInt256(3), "headers-first synced chain carries per-block work")
    }

    func testSyncSnapshotGatesOnExactSumNotTipEstimate() async throws {
        let fetcher = StorableFetcher()
        let difficulties = [
            lowWorkDifficulty, lowWorkDifficulty, lowWorkDifficulty,
            highWorkDifficulty, highWorkDifficulty
        ]
        let exactSum = totalWork(for: difficulties)
        XCTAssertLessThan(exactSum, tipEstimate(for: difficulties))

        let chain = try await buildMixedDifficultyChain(difficulties: difficulties, into: fetcher)
        let syncer = mixedDifficultySyncer(fetcher: fetcher, genesis: chain.genesis)

        let result = try await syncer.syncSnapshot(
            peerTipCID: chain.tip,
            localCumulativeWork: exactSum,
            skipPoWValidation: true)

        XCTAssertEqual(result.cumulativeWork, exactSum)
    }

    func testSyncSnapshotFalseRejectWhenTipHarderThanHistory() async throws {
        let fetcher = StorableFetcher()
        let difficulties = [
            highWorkDifficulty, highWorkDifficulty, highWorkDifficulty,
            lowWorkDifficulty, lowWorkDifficulty
        ]
        let exactSum = totalWork(for: difficulties)
        XCTAssertLessThan(tipEstimate(for: difficulties), exactSum)

        let chain = try await buildMixedDifficultyChain(difficulties: difficulties, into: fetcher)
        let syncer = mixedDifficultySyncer(fetcher: fetcher, genesis: chain.genesis)

        let result = try await syncer.syncSnapshot(
            peerTipCID: chain.tip,
            localCumulativeWork: exactSum,
            skipPoWValidation: true)

        XCTAssertEqual(result.cumulativeWork, exactSum)
    }

    func testSyncSnapshotRejectsLighterChainThatEstimateWouldAccept() async throws {
        let fetcher = StorableFetcher()
        let difficulties = [
            lowWorkDifficulty, lowWorkDifficulty, lowWorkDifficulty,
            highWorkDifficulty, highWorkDifficulty
        ]
        let exactSum = totalWork(for: difficulties)
        let estimate = tipEstimate(for: difficulties)
        XCTAssertLessThan(exactSum, estimate)

        let chain = try await buildMixedDifficultyChain(difficulties: difficulties, into: fetcher)
        let syncer = mixedDifficultySyncer(fetcher: fetcher, genesis: chain.genesis)

        await assertInsufficientWork {
            _ = try await syncer.syncSnapshot(
                peerTipCID: chain.tip,
                localCumulativeWork: estimate,
                skipPoWValidation: true)
        }
    }

    func testSyncFromHeadersGatesOnPassedCumulativeWork() async throws {
        let fetcher = StorableFetcher()
        let difficulties = [
            highWorkDifficulty, highWorkDifficulty, highWorkDifficulty,
            lowWorkDifficulty, lowWorkDifficulty
        ]
        let exactSum = totalWork(for: difficulties)
        XCTAssertLessThan(tipEstimate(for: difficulties), exactSum)

        let chain = try await buildMixedDifficultyChain(difficulties: difficulties, into: fetcher)
        let syncer = mixedDifficultySyncer(fetcher: fetcher, genesis: chain.genesis)

        let result = try await syncer.syncFromHeaders(
            chain.headers,
            cumulativeWork: exactSum,
            localCumulativeWork: exactSum)

        XCTAssertEqual(result.cumulativeWork, exactSum)

        await assertInsufficientWork {
            _ = try await syncer.syncFromHeaders(
                chain.headers,
                cumulativeWork: exactSum,
                localCumulativeWork: exactSum &+ UInt256(1))
        }
    }

    func testHeadersFirstSyncAcceptsTrustedGenesisBoundary() async throws {
        let fetcher = StorableFetcher()
        let base = now() - 100_000

        let genesis = try await BlockBuilder.buildGenesis(spec: spec(), timestamp: base, target: easy, fetcher: fetcher)
        try await storeBlock(genesis, to: fetcher)

        var headers: [SyncBlockHeader] = []
        var prev = genesis
        for i in 1...2 {
            let b = try await BlockBuilder.buildBlock(
                previous: prev,
                timestamp: base + Int64(i) * 1000,
                target: easy,
                nonce: UInt64(i),
                fetcher: fetcher
            )
            try await storeBlock(b, to: fetcher)
            headers.append(SyncBlockHeader(
                cid: try! VolumeImpl<Block>(node: b).rawCID,
                height: b.height,
                previousBlockCID: b.parent?.rawCID,
                target: b.target,
                nextTarget: b.nextTarget,
                timestamp: b.timestamp,
                specCID: b.spec.rawCID,
                spec: b.spec.node
            ))
            prev = b
        }

        let syncer = ChainSyncer(
            fetcher: fetcher,
            store: noopStore,
            genesisBlockHash: try! VolumeImpl<Block>(node: genesis).rawCID
        )
        let result = try await syncer.syncFromHeaders(headers, cumulativeWork: UInt256(2))

        XCTAssertEqual(result.tipBlockHeight, 2)
        XCTAssertEqual(result.tipBlockHash, headers.last?.cid)
    }

    func testSnapshotSyncReportsGenesisMismatchForWrongTerminalGenesis() async throws {
        let fetcher = StorableFetcher()
        let base = now() - 100_000

        let realGenesis = try await BlockBuilder.buildGenesis(spec: spec(), timestamp: base, target: easy, fetcher: fetcher)
        let fakeGenesis = try await BlockBuilder.buildGenesis(spec: spec(), timestamp: base + 1, target: easy, fetcher: fetcher)
        try await storeBlock(realGenesis, to: fetcher)
        try await storeBlock(fakeGenesis, to: fetcher)

        let syncer = ChainSyncer(
            fetcher: fetcher,
            store: noopStore,
            genesisBlockHash: try! VolumeImpl<Block>(node: realGenesis).rawCID
        )

        do {
            _ = try await syncer.syncSnapshot(peerTipCID: try! VolumeImpl<Block>(node: fakeGenesis).rawCID)
            XCTFail("expected SyncError.genesisMismatch")
        } catch SyncError.genesisMismatch {
            // expected
        }
    }
}
