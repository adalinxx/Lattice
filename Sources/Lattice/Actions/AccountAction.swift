import UInt256
import cashew
import CID
import Foundation

public struct AccountAction: Codable, Sendable {
    public let owner: String
    /// Positive = credit, negative = debit. Debits require authorization (signature).
    public let delta: Int64

    public init(owner: String, delta: Int64) {
        self.owner = owner
        self.delta = delta
    }

    public func verify() -> Bool {
        delta != 0 && delta != Int64.min
    }

    public var isDebit: Bool { delta < 0 }
    public var isCredit: Bool { delta > 0 }
    public var absoluteAmount: UInt64 { UInt64(delta < 0 ? -delta : delta) }

    public func stateDelta() -> Int {
        // Can't determine insertion/deletion without current state,
        // conservatively assume mutation (no size change)
        return 0
    }

    public func totalSize() -> Int? {
        return toData()?.count
    }

    public func toData() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}
