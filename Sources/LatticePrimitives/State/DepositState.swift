import cashew

public struct DepositKey: LosslessStringConvertible {
    public let nonce: UInt128
    public let demander: String
    public let amountDemanded: UInt64

    public init(depositAction: DepositAction) {
        nonce = depositAction.nonce
        demander = depositAction.demander
        amountDemanded = depositAction.amountDemanded
    }

    public init(withdrawalAction: WithdrawalAction) {
        nonce = withdrawalAction.nonce
        demander = withdrawalAction.demander
        amountDemanded = withdrawalAction.amountDemanded
    }

    public init(nonce: UInt128, demander: String, amountDemanded: UInt64) {
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
    }

    public init?(_ description: String) {
        let split = description.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: true)
        guard split.count >= 3 else { return nil }
        let demander = String(split[0])
        guard let amountDemanded = UInt64(String(split[1])) else { return nil }
        guard let nonce = UInt128(String(split[2])) else { return nil }
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
    }

    public var description: String {
        return "\(demander)/\(amountDemanded.description)/\(nonce.description)"
    }
}

public typealias DepositState = VolumeMerkleDictionaryImpl<UInt64>
public typealias DepositStateHeader = VolumeImpl<DepositState>
let SPENT_DEPOSIT_MARKER: UInt64 = 0
