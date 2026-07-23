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

        try await updatedHeader.storeMaterialized(
            createdBy: diff,
            storer: storage
        )
        let reloaded = try await updatedHeader.removingNode().resolveRecursive(fetcher: storage)
        let reloadedState = try XCTUnwrap(reloaded.node)
        let accounts = try XCTUnwrap(reloadedState.accountState.node?.allKeysAndValues())
        XCTAssertEqual(accounts["shared-owner-alpha"], 1)
        XCTAssertEqual(accounts["shared-owner-beta"], 1)
    }

    func testStoreMaterializedPersistsReceiptBalanceAndNonceChanges() async throws {
        let storage = StorableFetcher()
        try await LatticeState.emptyHeader.storeRecursively(storer: storage)
        let buyer = CryptoUtils.generateKeyPair()
        let seller = CryptoUtils.generateKeyPair()
        let buyerAddress = CryptoUtils.createAddress(from: buyer.publicKey)
        let sellerAddress = CryptoUtils.createAddress(from: seller.publicKey)

        let fundingBody = TransactionBody(
            accountActions: [AccountAction(owner: buyerAddress, delta: 250)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [buyerAddress], fee: 0, nonce: 0,
            chainPath: ["Nexus"]
        )
        let initial = try XCTUnwrap(LatticeState.emptyHeader.node)
        let (funded, fundingDiff) = try await initial.proveAndUpdateState(
            allAccountActions: fundingBody.accountActions,
            allActions: [], allDepositActions: [], allGenesisActions: [],
            allReceiptActions: [], allWithdrawalActions: [],
            transactionBodies: [fundingBody], fetcher: storage
        )
        let fundedHeader = try LatticeStateHeader(node: funded)
        try await fundedHeader.storeMaterialized(
            createdBy: fundingDiff,
            storer: storage
        )
        let resolvedFunded = try await fundedHeader.removingNode()
            .resolveRecursive(fetcher: storage)
        let reloadedFunded = try XCTUnwrap(resolvedFunded.node)

        let receipt = ReceiptAction(
            withdrawer: buyerAddress,
            nonce: 7,
            demander: sellerAddress,
            amountDemanded: 250,
            directory: "Market"
        )
        let receiptBody = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [receipt],
            withdrawalActions: [], signers: [buyerAddress],
            fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let (settled, receiptDiff) = try await reloadedFunded.proveAndUpdateState(
            allAccountActions: [], allActions: [], allDepositActions: [],
            allGenesisActions: [], allReceiptActions: [receipt],
            allWithdrawalActions: [], transactionBodies: [receiptBody],
            fetcher: storage
        )
        let settledHeader = try LatticeStateHeader(node: settled)
        try await settledHeader.storeMaterialized(
            createdBy: receiptDiff,
            storer: storage
        )

        let reloaded = try await settledHeader.removingNode()
            .resolveRecursive(fetcher: storage)
        let state = try XCTUnwrap(reloaded.node)
        let accounts = try XCTUnwrap(state.accountState.node?.allKeysAndValues())
        XCTAssertNil(accounts[buyerAddress])
        XCTAssertEqual(accounts[sellerAddress], 250)
        XCTAssertEqual(
            accounts[AccountStateHeader.nonceTrackingKey(buyerAddress)],
            1
        )
        let receipts = try XCTUnwrap(state.receiptState.node?.allKeysAndValues())
        XCTAssertEqual(
            receipts[ReceiptKey(receiptAction: receipt).storageKey],
            buyerAddress
        )
    }
}
