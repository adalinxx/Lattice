import cashew
import Foundation

public struct ReceiptAction: Codable, Sendable {
    public let withdrawer: String
    public let nonce: UInt128
    public let demander: String
    public let amountDemanded: UInt64
    public let directory: String

    public init(withdrawer: String, nonce: UInt128, demander: String, amountDemanded: UInt64, directory: String) {
        self.withdrawer = withdrawer
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
        self.directory = directory
    }

    func stateDelta() -> Int {
        withdrawer.utf8.count + demander.utf8.count + directory.utf8.count + 24
    }

    public func totalSize() -> Int? {
        return toData()?.count
    }

    public func toData() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}
