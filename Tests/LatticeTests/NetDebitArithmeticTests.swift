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
        XCTAssertEqual(try b.netBalanceDeltas(), ["A": .debit(100)])
        XCTAssertEqual(try b.netOutflows(), ["A": 100])
        XCTAssertEqual(try b.netOutflow(of: "A"), 100)
    }

    func test_netCredit_isNoOutflow() throws {
        let b = body(account: [AccountAction(owner: "A", delta: 50)])
        XCTAssertEqual(try b.netBalanceDeltas(), ["A": .credit(50)])
        XCTAssertTrue(try b.netOutflows().isEmpty)
        XCTAssertEqual(try b.netOutflow(of: "A"), 0)
    }

    func test_perOwnerAggregation() throws {
        let b = body(account: [
            AccountAction(owner: "A", delta: -100),
            AccountAction(owner: "A", delta: 30),
            AccountAction(owner: "B", delta: -10),
        ])
        XCTAssertEqual(try b.netBalanceDeltas(), ["A": .debit(70), "B": .debit(10)])
        XCTAssertEqual(try b.netOutflows(), ["A": 70, "B": 10])
        XCTAssertEqual(try b.netOutflow(of: "A"), 70)
        XCTAssertEqual(try b.netOutflow(of: "B"), 10)
    }

    func test_receiptImpliedTransfer_debitsWithdrawer() throws {
        // A receipt makes the withdrawer fund `amountDemanded` to the demander.
        let b = body(receipts: [
            ReceiptAction(withdrawer: "W", nonce: 0, demander: "D", amountDemanded: 250, directory: "Nexus")
        ])
        let deltas = try b.netBalanceDeltas()
        XCTAssertEqual(deltas["W"], .debit(250))
        XCTAssertEqual(deltas["D"], .credit(250))
        XCTAssertEqual(try b.netOutflow(of: "W"), 250)
        XCTAssertEqual(try b.netOutflow(of: "D"), 0, "the credited demander has no outflow")
    }

    func test_emptyOwner_andOverflowReject() throws {
        XCTAssertEqual(try body().netOutflow(of: ""), 0)
        // A zero receipt is invalid, so it cannot create an outflow.
        let bad = body(receipts: [
            ReceiptAction(withdrawer: "W", nonce: 0, demander: "D", amountDemanded: 0, directory: "Nexus")
        ])
        XCTAssertThrowsError(try bad.netBalanceDeltas())
        XCTAssertThrowsError(try bad.netOutflows())
    }

    func test_aggregationIsOrderIndependentAcrossInt64Boundary() throws {
        let actions = [
            AccountAction(owner: "A", delta: Int64.max),
            AccountAction(owner: "A", delta: Int64.max),
            AccountAction(owner: "A", delta: Int64.max),
            AccountAction(owner: "A", delta: -Int64.max),
            AccountAction(owner: "A", delta: -Int64.max),
        ]

        XCTAssertEqual(
            try body(account: actions).netBalanceDeltas(),
            try body(account: Array(actions.reversed())).netBalanceDeltas()
        )
        XCTAssertEqual(try body(account: actions).netBalanceDeltas()["A"], .credit(UInt64(Int64.max)))
    }

}
