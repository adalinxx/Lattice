import XCTest
@testable import Lattice

final class NetDebitArithmeticTests: XCTestCase {
    private func body(
        account: [AccountAction] = [],
        receipts: [ReceiptAction] = [],
        fee: UInt64 = 0
    ) -> TransactionBody {
        TransactionBody(
            accountActions: account, actions: [], depositActions: [], genesisActions: [],
            receiptActions: receipts, withdrawalActions: [], signers: [], fee: fee, nonce: 0
        )
    }

    func test_singleDebit() throws {
        let b = body(account: [AccountAction(owner: "A", delta: -100)])
        XCTAssertEqual(try b.netBalanceDeltas(), ["A": -100])
        XCTAssertEqual(b.netOutflows(), ["A": 100])
        XCTAssertEqual(b.netOutflow(of: "A"), 100)
    }

    func test_netCredit_isNoOutflow() throws {
        let b = body(account: [AccountAction(owner: "A", delta: 50)])
        XCTAssertEqual(try b.netBalanceDeltas(), ["A": 50])
        XCTAssertTrue(b.netOutflows().isEmpty)
        XCTAssertEqual(b.netOutflow(of: "A"), 0)
    }

    func test_perOwnerAggregation() throws {
        let b = body(account: [
            AccountAction(owner: "A", delta: -100),
            AccountAction(owner: "A", delta: 30),
            AccountAction(owner: "B", delta: -10),
        ])
        XCTAssertEqual(try b.netBalanceDeltas(), ["A": -70, "B": -10])
        XCTAssertEqual(b.netOutflows(), ["A": 70, "B": 10])
        XCTAssertEqual(b.netOutflow(of: "A"), 70)
        XCTAssertEqual(b.netOutflow(of: "B"), 10)
    }

    func test_receiptImpliedTransfer_debitsWithdrawer() throws {
        // A receipt makes the withdrawer fund `amountDemanded` to the demander.
        let b = body(receipts: [
            ReceiptAction(withdrawer: "W", nonce: 0, demander: "D", amountDemanded: 250, directory: "Nexus")
        ])
        let deltas = try b.netBalanceDeltas()
        XCTAssertEqual(deltas["W"], -250)
        XCTAssertEqual(deltas["D"], 250)
        XCTAssertEqual(b.netOutflow(of: "W"), 250)
        XCTAssertEqual(b.netOutflow(of: "D"), 0, "the credited demander has no outflow")
    }

    func test_emptyOwner_andOverflowReject() throws {
        XCTAssertEqual(body().netOutflow(of: ""), 0)
        // A receipt amount of 0 is rejected by netAccountDeltas → empty outflows.
        let bad = body(receipts: [
            ReceiptAction(withdrawer: "W", nonce: 0, demander: "D", amountDemanded: 0, directory: "Nexus")
        ])
        XCTAssertThrowsError(try bad.netBalanceDeltas())
        XCTAssertTrue(bad.netOutflows().isEmpty)
    }
}
