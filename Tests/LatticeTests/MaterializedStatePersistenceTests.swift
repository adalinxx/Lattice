import XCTest
@testable import Lattice
import cashew

final class MaterializedStatePersistenceTests: XCTestCase {
    func testStoreMaterializedPersistsCompressedRadixDescendants() async throws {
        let storage = StorableFetcher()
        try await LatticeState.emptyHeader.storeRecursively(storer: storage)

        let initialState = try XCTUnwrap(LatticeState.emptyHeader.node)
        let (updatedState, diff) = try await initialState.proveAndUpdateState(
            allAccountActions: [
                AccountAction(owner: "shared-owner-alpha", delta: 1),
                AccountAction(owner: "shared-owner-beta", delta: 1)
            ],
            allActions: [],
            allDepositActions: [],
            allGenesisActions: [],
            allReceiptActions: [],
            allWithdrawalActions: [],
            transactionBodies: [],
            fetcher: storage
        )
        let updatedHeader = try LatticeStateHeader(node: updatedState)

        try await updatedHeader.storeMaterialized(createdBy: diff, storer: storage)
        let reloaded = try await updatedHeader.removingNode().resolveRecursive(fetcher: storage)
        let reloadedState = try XCTUnwrap(reloaded.node)
        let accounts = try XCTUnwrap(reloadedState.accountState.node?.allKeysAndValues())
        XCTAssertEqual(accounts["shared-owner-alpha"], 1)
        XCTAssertEqual(accounts["shared-owner-beta"], 1)
    }
}
