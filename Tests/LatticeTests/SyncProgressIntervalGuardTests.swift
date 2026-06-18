import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

// SYN-A2: `walkChain` reports progress on a `collected.count % progressInterval`
// cadence. A `progressInterval` of 0 would trap the entire sync with a
// divide-by-zero the moment the first block is collected. The walk clamps the
// interval to `max(1, …)` so a 0 (e.g. a misconfigured caller) degrades to
// per-block progress instead of trapping. Exercised through the real public
// `syncSnapshot` entry point, which forwards `progressInterval` into the walk.

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

final class SyncProgressIntervalGuardTests: XCTestCase {
    private let easy = UInt256.max

    /// Without the clamp, `collected.count % 0` traps as soon as the first block
    /// is collected. With the clamp the walk completes and reports progress
    /// per-block. We also assert progress callbacks actually fire (cadence == 1).
    func testZeroProgressIntervalDoesNotTrapAndReportsPerBlock() async throws {
        let fetcher = StorableFetcher()
        let base = now() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(spec: spec(), timestamp: base, target: easy, fetcher: fetcher)
        let genesisCID = try! VolumeImpl<Block>(node: genesis).rawCID
        try await storeBlock(genesis, to: fetcher)

        let progressCalls = ProgressCounter()
        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesisCID)
        let result = try await syncer.syncSnapshot(
            peerTipCID: genesisCID,
            progressInterval: 0,
            progress: { _, _ in await progressCalls.bump() }
        )

        XCTAssertEqual(result.tipBlockHash, genesisCID, "a 0 progressInterval must not trap the walk")
        XCTAssertEqual(result.tipBlockHeight, 0)
        let calls = await progressCalls.count
        XCTAssertGreaterThanOrEqual(calls, 1, "clamped to per-block cadence, progress must fire for the collected block")
    }
}

private actor ProgressCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
