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
        halfLife: 5
    )
}

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

}
