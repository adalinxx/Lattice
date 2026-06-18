import cashew
import Foundation

public struct DepositAction: Codable, Sendable {
    public let nonce: UInt128
    public let demander: String
    public let amountDemanded: UInt64
    public let amountDeposited: UInt64

    public init(nonce: UInt128, demander: String, amountDemanded: UInt64, amountDeposited: UInt64) {
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
        self.amountDeposited = amountDeposited
    }

    func stateDelta() -> Int {
        return 32 + demander.count
    }

    public func totalSize() -> Int? {
        return toData()?.count
    }

    public func toData() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}
