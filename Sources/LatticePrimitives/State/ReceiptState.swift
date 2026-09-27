import cashew

/// The field separator in the `/`-delimited `ReceiptKey` (and `DepositKey`)
/// string encodings used as merkle-dictionary keys. A chain's `directory` is a
/// free-text `ReceiptKey` field, so it must never contain this separator or two
/// distinct keys could collide (a withdrawal settling against the wrong chain's
/// receipt). Enforced at the single entry point for directory names,
/// `TransactionBody.genesisActionsAreValid`. Must stay equal to the literal "/"
/// used in `ReceiptKey`/`DepositKey` `description` and their parsers.
public let DIRECTORY_KEY_SEPARATOR: Character = "/"

public struct ReceiptKey: LosslessStringConvertible {
    public let directory: String
    public let nonce: UInt128
    public let demander: String
    public let amountDemanded: UInt64

    public init(receiptAction: ReceiptAction) {
        directory = receiptAction.directory
        nonce = receiptAction.nonce
        demander = receiptAction.demander
        amountDemanded = receiptAction.amountDemanded
    }

    public init(withdrawalAction: WithdrawalAction, directory: String) {
        self.directory = directory
        nonce = withdrawalAction.nonce
        demander = withdrawalAction.demander
        amountDemanded = withdrawalAction.amountDemanded
    }

    public init?(_ description: String) {
        let split = description.split(separator: "/", maxSplits: 4, omittingEmptySubsequences: true)
        guard split.count >= 4 else { return nil }
        let directory = String(split[0])
        let demander = String(split[1])
        guard let amountDemanded = UInt64(String(split[2])) else { return nil }
        guard let nonce = UInt128(String(split[3])) else { return nil }
        self.directory = directory
        self.nonce = nonce
        self.demander = demander
        self.amountDemanded = amountDemanded
    }

    public var description: String {
        return "\(directory)/\(demander)/\(amountDemanded.description)/\(nonce.description)"
    }

    /// Fixed-depth state-trie path. `description` remains the logical wire key;
    /// only ReceiptState storage uses this domain-separated digest.
    public var storageKey: String {
        CryptoUtils.sha256("lattice/receipt-state/v1\u{0}" + description)
    }
}

public typealias ReceiptState = VolumeMerkleDictionaryImpl<String>
public typealias ReceiptStateHeader = VolumeImpl<ReceiptState>
