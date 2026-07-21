import XCTest
import UInt256
@testable import Lattice

@MainActor
final class LazyLocalWorkCacheTests: XCTestCase {
    func testLinearAdmissionsLeaveLocalTotalsDirtyUntilAQueryNeedsThem() async throws {
        let (chain, hashes) = try await lazyCacheLinearChain(count: 6)
        let rootHash = hashes[0]
        let tipHash = hashes[5]

        let blocksBeforeQuery = await chain.hashToBlock
        let rawBeforeQuery = try XCTUnwrap(blocksBeforeQuery[rootHash])
        XCTAssertEqual(rawBeforeQuery.subtreeWeight, WorkSum(UInt256(1)))

        let queriedRootValue = await chain.getConsensusBlock(hash: rootHash)
        let queriedRoot = try XCTUnwrap(queriedRootValue)
        XCTAssertEqual(queriedRoot.subtreeWeight, WorkSum(UInt256(21)))
        let tipWork = await chain.getCumulativeWork(forHash: tipHash)
        XCTAssertEqual(tipWork, WorkSum(UInt256(21)))
    }

    func testPersistKeepsDerivedLocalTotalsOutOfDurableState() async throws {
        let (chain, hashes) = try await lazyCacheLinearChain(count: 6)
        let rootHash = hashes[0]
        let tipHash = hashes[5]

        let blocksBeforePersist = await chain.hashToBlock
        let rawBeforePersist = try XCTUnwrap(blocksBeforePersist[rootHash])
        XCTAssertEqual(rawBeforePersist.subtreeWeight, WorkSum(UInt256(1)))

        let persisted = await chain.persist()
        let blocksAfterPersist = await chain.hashToBlock
        let rawAfterPersist = try XCTUnwrap(blocksAfterPersist[rootHash])
        XCTAssertEqual(rawAfterPersist.subtreeWeight, WorkSum(UInt256(1)))

        let restored = try ChainState.restore(from: persisted)
        let restoredTip = await restored.getMainChainTip()
        let restoredRootWork = await restored.subtreeWeight(forHash: rootHash)
        let restoredTipWork = await restored.getCumulativeWork(forHash: tipHash)
        let restoredPersisted = await restored.persist()
        XCTAssertEqual(restoredTip, tipHash)
        XCTAssertEqual(restoredRootWork, WorkSum(UInt256(21)))
        XCTAssertEqual(restoredTipWork, WorkSum(UInt256(21)))
        XCTAssertEqual(restoredPersisted, persisted)
    }
}

private func lazyCacheLinearChain(
    count: Int
) async throws -> (ChainState, [String]) {
    precondition(count > 0)
    let hashes = (0..<count).map { testCID("lazy-local-cache-\($0)") }
    let chain = try await ChainState.restore(replaying: [
        lazyCacheAdmission(index: 0, hash: hashes[0], parentHash: nil),
    ])
    for index in 1..<count {
        _ = try await chain.applyStaged(lazyCacheAdmission(
            index: index,
            hash: hashes[index],
            parentHash: hashes[index - 1]
        ))
    }
    return (chain, hashes)
}

private func lazyCacheAdmission(
    index: Int,
    hash: String,
    parentHash: String?
) -> ChainAdmissionBatch {
    let contribution = VerifiedWorkContribution(
        id: testCID("lazy-local-cache-work-\(index)"),
        work: UInt256(index + 1)
    )
    return ChainAdmissionBatch(facts: [
        .block(ChainBlockFact(
            blockHash: hash,
            parentBlockHash: parentHash,
            blockHeight: UInt64(index),
            postStateCID: testCID("lazy-local-cache-post-\(index)"),
            prevStateCID: testCID("lazy-local-cache-prev-\(index)"),
            specCID: testCID("lazy-local-cache-spec-\(index)"),
            target: "1",
            nextTarget: "1",
            timestamp: Int64(index),
            stateDiff: .empty
        )),
        .work(ChainWorkFact(blockHash: hash, contribution: contribution)),
    ])
}
