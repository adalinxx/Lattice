import Foundation
import XCTest
@testable import Lattice
import cashew
import UInt256

private func prefixSpec() -> ChainSpec {
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

final class CumulativeWorkPrefixSumTests: XCTestCase {
    func testIncrementalPrefixSumEqualsTotalWork() async throws {
        let fetcher = StorableFetcher()
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 50_000
        let target = UInt256(1_000)
        let perBlock = workForTarget(target)
        let genesis = try await buildAndStoreGenesis(
            spec: prefixSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        var previous = genesis
        var expected = WorkSum(perBlock)
        for height in 1...5 {
            let block = try await buildAndStoreBlock(
                previous: previous,
                timestamp: base + Int64(height) * 1_000,
                target: target,
                nonce: UInt64(height),
                fetcher: fetcher
            )
            _ = await chain.submitTestBlock(blockHeader: try BlockHeader(node: block), block: block)
            previous = block
            expected = expected + perBlock
            let cumulativeWork = await chain.getTipCumulativeWork()
            XCTAssertEqual(cumulativeWork, expected)
        }
    }

    func testPrefixSumSurvivesFactReplay() async throws {
        let fetcher = StorableFetcher()
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 50_000
        let target = UInt256(1_000)
        let genesis = try await buildAndStoreGenesis(
            spec: prefixSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        var batches = [try testAdmissionBatch(for: genesis)]
        var previous = genesis
        for height in 1...4 {
            let block = try await buildAndStoreBlock(
                previous: previous,
                timestamp: base + Int64(height) * 1_000,
                target: target,
                nonce: UInt64(height),
                fetcher: fetcher
            )
            _ = await chain.submitTestBlock(blockHeader: try BlockHeader(node: block), block: block)
            batches.append(try testAdmissionBatch(for: block))
            previous = block
        }

        let before = await chain.getTipCumulativeWork()
        let restored = try await ChainState.restore(replaying: batches)

        let after = await restored.getTipCumulativeWork()
        XCTAssertEqual(after, before)
    }

    func testOutOfOrderInsertRepairsDescendantPrefixSum() async throws {
        let fetcher = StorableFetcher()
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 50_000
        let target = UInt256(1_000)
        let work = workForTarget(target)
        let genesis = try await buildAndStoreGenesis(
            spec: prefixSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let parent = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 1_000,
            target: target,
            nonce: 1,
            fetcher: fetcher
        )
        let child = try await buildAndStoreBlock(
            previous: parent,
            timestamp: base + 2_000,
            target: target,
            nonce: 2,
            fetcher: fetcher
        )
        let parentHash = try BlockHeader(node: parent).rawCID
        let childHash = try BlockHeader(node: child).rawCID
        let chain = ChainState.fromGenesis(block: genesis)

        _ = await chain.submitTestBlock(blockHeader: try BlockHeader(node: child), block: child)
        let provisional = await chain.getCumulativeWork(forHash: childHash)
        XCTAssertEqual(provisional, WorkSum(work))

        _ = await chain.submitTestBlock(blockHeader: try BlockHeader(node: parent), block: parent)

        let parentWork = await chain.getCumulativeWork(forHash: parentHash)
        let childWork = await chain.getCumulativeWork(forHash: childHash)
        XCTAssertEqual(parentWork, WorkSum(work) + work)
        XCTAssertEqual(childWork, WorkSum(work) + work + work)
    }

    func testWorkSumPreservesOverflowedOrdering() {
        XCTAssertEqual(WorkSum(UInt256(3)) + UInt256(4), WorkSum(UInt256(7)))
        let beyondMax = WorkSum(UInt256.max) + UInt256(1)
        XCTAssertGreaterThan(beyondMax, WorkSum(UInt256.max))
        XCTAssertEqual(
            WorkSum(UInt256.max - UInt256(5)) + UInt256(10),
            beyondMax + UInt256(4)
        )
    }

    func testWorkSumPreservesUInt256WordOrder() {
        let values = [
            UInt256(0),
            UInt256(1),
            UInt256(UInt64.max),
            UInt256.max - UInt256(1),
            UInt256.max
        ]

        for value in values {
            XCTAssertEqual(WorkSum(value).toHexString(), value.toHexString())
        }
    }
}
