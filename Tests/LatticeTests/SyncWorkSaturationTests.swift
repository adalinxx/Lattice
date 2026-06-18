import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

// The repo's policy for UInt256 work arithmetic is SATURATE, never wrap
// (`saturatingWorkSum`): a modulo wrap makes a HEAVIER chain compare LOWER,
// tripping the insufficientWork gate exactly when the chain is strongest.
// These tests drive ChainSyncer's two work computations into the wrap regime
// (per-block work = max via target 1) and assert clamped, monotone results:
//   - walkChain's running cumulative-work sum (syncSnapshot/syncFull path)
//   - syncStateOnly's estimated full-chain work (perBlock * blockCount)

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

final class SyncWorkSaturationTests: XCTestCase {

    // target = 1 ⇒ workForTarget = max/1 = UInt256.max per block, so any
    // two blocks (or any estimate over >1 block) is in the wrap regime.
    private let maxWorkTarget = UInt256(1)

    /// genesis + `extra` extending blocks, all with target 1, fully stored.
    private func buildMaxWorkChain(extra: Int, into fetcher: StorableFetcher) async throws -> (genesis: String, tip: String) {
        let base = now() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec(), timestamp: base, target: maxWorkTarget, fetcher: fetcher)
        try await storeBlock(genesis, to: fetcher)
        var prev = genesis
        for i in 1...extra {
            let b = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: base + Int64(i) * 1000,
                target: maxWorkTarget, nonce: UInt64(i), fetcher: fetcher)
            try await storeBlock(b, to: fetcher)
            prev = b
        }
        return (try! VolumeImpl<Block>(node: genesis).rawCID, try! VolumeImpl<Block>(node: prev).rawCID)
    }

    /// walkChain's running sum: two max-work blocks must SATURATE at
    /// UInt256.max, not wrap (a `&+` wrap reports max-1... then lower and
    /// lower as blocks are added — heavier chain, lower work).
    func testWalkCumulativeWorkSaturatesInsteadOfWrapping() async throws {
        let fetcher = StorableFetcher()
        let (genesis, tip) = try await buildMaxWorkChain(extra: 2, into: fetcher)

        let syncer = ChainSyncer(
            fetcher: fetcher, store: noopStore, genesisBlockHash: genesis,
            validateBlockConsensus: false)
        let result = try await syncer.syncSnapshot(peerTipCID: tip, skipPoWValidation: true)

        XCTAssertEqual(result.cumulativeWork, UInt256.max,
                       "3 * max-work blocks must clamp to UInt256.max, not wrap")
        // Monotone: the 3-block chain's reported work is >= a single block's.
        XCTAssertGreaterThanOrEqual(result.cumulativeWork, workForTarget(maxWorkTarget))
    }

    /// The saturated sum must still clear the insufficientWork gate against a
    /// max-work local chain — the exact comparison a wrap corrupts.
    func testSaturatedWalkWorkStillClearsInsufficientWorkGate() async throws {
        let fetcher = StorableFetcher()
        let (genesis, tip) = try await buildMaxWorkChain(extra: 2, into: fetcher)

        let syncer = ChainSyncer(
            fetcher: fetcher, store: noopStore, genesisBlockHash: genesis,
            validateBlockConsensus: false)
        // localWork = max: a wrapped sum (max-1) would spuriously throw
        // insufficientWork; the saturated sum (max) passes.
        let result = try await syncer.syncSnapshot(
            peerTipCID: tip, localCumulativeWork: UInt256.max, skipPoWValidation: true)
        XCTAssertEqual(result.cumulativeWork, UInt256.max)
    }

    /// syncStateOnly's full-chain estimate (perBlock * blockCount): a
    /// max-work tip at height >= 1 must clamp to UInt256.max, not wrap to
    /// garbage. PoW at target 1 is unmineable, so the anchored-validator seam
    /// (always-true) bypasses the self-hash gate to isolate the arithmetic.
    func testStateOnlyEstimateClampsInsteadOfWrapping() async throws {
        let fetcher = StorableFetcher()
        let (_, tip) = try await buildMaxWorkChain(extra: 1, into: fetcher)

        let syncer = ChainSyncer(
            fetcher: fetcher, store: noopStore, genesisBlockHash: "unused-for-tip-only",
            anchoredPoWValidator: { _ in true },
            validateBlockConsensus: false)
        // estimate = max * 2: wrapped this is max-1 < localWork=max and the
        // sync spuriously fails; clamped it equals max and succeeds.
        let result = try await syncer.syncStateOnly(
            peerTipCID: tip, localCumulativeWork: UInt256.max)
        XCTAssertEqual(result.cumulativeWork, UInt256.max,
                       "estimate must clamp to UInt256.max on overflow")
    }
}
