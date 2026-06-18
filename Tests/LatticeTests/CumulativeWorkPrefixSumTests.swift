import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

// F5-1: per-block cumulative-work prefix sum (`BlockMeta.cumulativeWork`).
// Verifies the sum is maintained incrementally, survives a persistence
// round-trip, and — crucially — stays exact after retention pruning, where the
// windowed `getCumulativeWork(limit:)` would underestimate.

private func f() -> StorableFetcher { StorableFetcher() }
private func s(_ dir: String = "Nexus", premine: UInt64 = 0) -> ChainSpec {
    ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
}
private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

final class CumulativeWorkPrefixSumTests: XCTestCase {

    func testIncrementalPrefixSumEqualsTotalWork() async throws {
        let fetcher = f()
        let base = now() - 50_000
        let diff = UInt256(1000)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s(), timestamp: base, target: diff, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        var prev = genesis
        for i in 1...5 {
            let b = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: base + Int64(i) * 1000,
                target: diff, nonce: UInt64(i), fetcher: fetcher
            )
            _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            prev = b

            // After each extension the tip's cumulative work is the exact prefix
            // sum: (height + 1) blocks each of work = max/diff.
            var expected = UInt256.zero
            for _ in 0...i { expected = expected &+ workForTarget(diff) }
            let tipCum = await chain.getTipCumulativeWork()
            XCTAssertEqual(tipCum, expected, "tip cumulative work at height \(i)")
        }

        // Genesis carries its own work; every block equals parent + own work.
        let genesisCum = await chain.getCumulativeWork(forHash: try! VolumeImpl<Block>(node: genesis).rawCID)
        XCTAssertEqual(genesisCum, workForTarget(diff), "genesis cumulative work == its own work")
    }

    func testPrefixSumSurvivesPersistRestore() async throws {
        let fetcher = f()
        let base = now() - 50_000
        let diff = UInt256(1000)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s(), timestamp: base, target: diff, fetcher: fetcher
        )
        let chain1 = ChainState.fromGenesis(block: genesis)
        var prev = genesis
        for i in 1...4 {
            let b = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: base + Int64(i) * 1000,
                target: diff, nonce: UInt64(i), fetcher: fetcher
            )
            _ = await chain1.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            prev = b
        }

        let before = await chain1.getTipCumulativeWork()

        // Full JSON round-trip — exercises the Codable path + cumulativeWorkByHash.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let decoded = try JSONDecoder().decode(
            PersistedChainState.self, from: try encoder.encode(await chain1.persist())
        )
        let chain2 = try ChainState.restore(from: decoded)
        let after = await chain2.getTipCumulativeWork()

        XCTAssertEqual(after, before, "cumulative work preserved exactly across persist/restore")
        XCTAssertTrue(before > UInt256.zero)
    }

    func testPrefixSumIsPruningProof() async throws {
        // A persisted state that retained only a 2-block window of a height-1000
        // chain, but whose tip carries the genesis-relative prefix sum. The
        // restored tip must report that full sum, NOT the sum of the two
        // present blocks (which the windowed getCumulativeWork would give).
        let tinyDiff = UInt256.max // work ≈ 1 per present block
        let diffHex = tinyDiff.toHexString()
        let fullTotal = UInt256(987_654_321) // stand-in for work over 1000 pruned blocks

        let parent = PersistedBlockMeta(
            blockHash: "P", parentBlockHash: nil, blockHeight: 999,
            parentChainBlocks: [:], childHashes: ["T"], target: diffHex,
            timestamp: 1, cumulativeWork: (fullTotal &- workForTarget(tinyDiff)).toHexString()
        )
        let tip = PersistedBlockMeta(
            blockHash: "T", parentBlockHash: "P", blockHeight: 1000,
            parentChainBlocks: [:], childHashes: [], target: diffHex,
            timestamp: 2, cumulativeWork: fullTotal.toHexString()
        )
        let persisted = PersistedChainState(
            chainTip: "T", tipPostStateCID: nil, tipPrevStateCID: nil, tipSpecCID: nil,
            tipTarget: nil, tipNextTarget: nil, tipHeight: 1000, tipTimestamp: nil,
            mainChainHashes: ["P", "T"], blocks: [parent, tip],
            parentChainMap: [:], missingBlockHashes: []
        )

        let chain = try ChainState.restore(from: persisted)
        let tipCum = await chain.getTipCumulativeWork()
        XCTAssertEqual(tipCum, fullTotal, "tip reports persisted prefix sum, not windowed sum")

        // The windowed accessor still underestimates (only the present window) —
        // this contrast is exactly why the prefix sum exists.
        let windowed = await chain.getCumulativeWork(limit: 1000)
        XCTAssertTrue(windowed < fullTotal, "windowed sum underestimates after pruning")
    }

    func testLegacyPersistedStateRecomputesWindowRelative() async throws {
        // Pre-upgrade data: no cumulativeWork on any block. Restore must not
        // crash and must produce a sensible window-relative prefix sum.
        let diff = UInt256(1000)
        let work = workForTarget(diff)
        let g = PersistedBlockMeta(blockHash: "G", parentBlockHash: nil, blockHeight: 0,
            parentChainBlocks: [:], childHashes: ["A"], target: diff.toHexString(),
            timestamp: 1, cumulativeWork: nil)
        let a = PersistedBlockMeta(blockHash: "A", parentBlockHash: "G", blockHeight: 1,
            parentChainBlocks: [:], childHashes: ["B"], target: diff.toHexString(),
            timestamp: 2, cumulativeWork: nil)
        let b = PersistedBlockMeta(blockHash: "B", parentBlockHash: "A", blockHeight: 2,
            parentChainBlocks: [:], childHashes: [], target: diff.toHexString(),
            timestamp: 3, cumulativeWork: nil)
        let persisted = PersistedChainState(
            chainTip: "B", tipPostStateCID: nil, tipPrevStateCID: nil, tipSpecCID: nil,
            tipTarget: nil, tipNextTarget: nil, tipHeight: 2, tipTimestamp: nil,
            mainChainHashes: ["G", "A", "B"], blocks: [g, a, b],
            parentChainMap: [:], missingBlockHashes: []
        )

        let chain = try ChainState.restore(from: persisted)
        let tipCum = await chain.getTipCumulativeWork()
        XCTAssertEqual(tipCum, work &+ work &+ work, "legacy recompute = sum of present-window work")
    }

    func testOutOfOrderInsertRepairsDescendantPrefixSum() async throws {
        let fetcher = f()
        let base = now() - 50_000
        let diff = UInt256(1000)
        let work = workForTarget(diff)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s(), timestamp: base, target: diff, fetcher: fetcher
        )
        let a = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher
        )
        let b = try await BlockBuilder.buildBlock(
            previous: a, timestamp: base + 2000, target: diff, nonce: 2, fetcher: fetcher
        )
        let aHash = try! VolumeImpl<Block>(node: a).rawCID
        let bHash = try! VolumeImpl<Block>(node: b).rawCID

        let chain = ChainState.fromGenesis(block: genesis)

        // Deliver B (parent A) BEFORE A — A is missing, so B gets a provisional
        // prefix sum (its own work only).
        _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: b), block: b)
        let provisional = await chain.getCumulativeWork(forHash: bHash)
        XCTAssertEqual(provisional, work, "before parent arrives, B holds only its own work")

        // Now A arrives; the repair must propagate the correct prefix down to B.
        _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: a), block: a)

        let aCum = await chain.getCumulativeWork(forHash: aHash)
        let bCum = await chain.getCumulativeWork(forHash: bHash)
        XCTAssertEqual(aCum, work &+ work, "A = genesis + A")
        XCTAssertEqual(bCum, work &+ work &+ work, "B repaired to genesis + A + B after A arrives")
    }

    func testSaturatingWorkSumClampsOnOverflow() {
        XCTAssertEqual(saturatingWorkSum(UInt256(3), UInt256(4)), UInt256(7))
        XCTAssertEqual(saturatingWorkSum(UInt256.max, UInt256(1)), UInt256.max, "overflow clamps to max, never wraps")
        XCTAssertEqual(saturatingWorkSum(UInt256.max &- UInt256(5), UInt256(10)), UInt256.max)
        XCTAssertEqual(saturatingWorkSum(UInt256.zero, UInt256.zero), UInt256.zero)
    }
}
