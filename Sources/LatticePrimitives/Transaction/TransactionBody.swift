import cashew
import CollectionConcurrencyKit
import Foundation
import UInt256

public enum AccountBalanceDelta: Sendable, Equatable {
    case credit(UInt64)
    case debit(UInt64)

    public var outflow: UInt64 {
        if case .debit(let amount) = self { return amount }
        return 0
    }
}

public struct TransactionBody: Scalar {
    public let accountActions: [AccountAction]
    public let actions: [Action]
    public let depositActions: [DepositAction]
    public let receiptActions: [ReceiptAction]
    public let withdrawalActions: [WithdrawalAction]
    public let signers: [String]
    public let nonce: UInt64
    public let chainPath: [String]

    public init(accountActions: [AccountAction], actions: [Action], depositActions: [DepositAction], receiptActions: [ReceiptAction], withdrawalActions: [WithdrawalAction], signers: [String], nonce: UInt64, chainPath: [String]) {
        self.accountActions = accountActions
        self.actions = actions
        self.depositActions = depositActions
        self.receiptActions = receiptActions
        self.withdrawalActions = withdrawalActions
        self.signers = signers
        self.nonce = nonce
        self.chainPath = chainPath
    }

}
