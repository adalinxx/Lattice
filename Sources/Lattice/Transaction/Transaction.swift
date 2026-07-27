import cashew
import Foundation
import Multikey

let TRANSACTION_BODY_PROPERTY = "body"
let TRANSACTION_PROPERTIES = Set([TRANSACTION_BODY_PROPERTY])

struct SignatureEntry: Codable {
    let key: String
    let value: String
}

public struct Transaction {
    public let signatures: [String: String]
    public let body: HeaderImpl<TransactionBody>

    public init(signatures: [String: String], body: HeaderImpl<TransactionBody>) {
        self.signatures = Self.normalized(signatures) ?? signatures
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case signatures, body
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let sortedSigs = signatures.sorted { $0.key < $1.key }
            .map { SignatureEntry(key: $0.key, value: $0.value) }
        try container.encode(sortedSigs, forKey: .signatures)
        try container.encode(body, forKey: .body)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([SignatureEntry].self, forKey: .signatures)
        var decodedSignatures: [String: String] = [:]
        for entry in entries {
            let key = Self.normalizedPublicKey(entry.key)
            let value = Data(hex: entry.value)?.hexString ?? entry.value
            if decodedSignatures[key] != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .signatures,
                    in: container,
                    debugDescription: "duplicate signature key"
                )
            }
            decodedSignatures[key] = value
        }
        signatures = decodedSignatures
        body = try container.decode(HeaderImpl<TransactionBody>.self, forKey: .body)
    }

    private static func normalizedPublicKey(_ value: String) -> String {
        (try? Multikey.decode(fromHex: value))?.hexEncoded ?? value
    }

    private static func normalized(
        _ signatures: [String: String]
    ) -> [String: String]? {
        var result: [String: String] = [:]
        for (rawKey, rawSignature) in signatures {
            let key = normalizedPublicKey(rawKey)
            guard result[key] == nil else { return nil }
            result[key] = Data(hex: rawSignature)?.hexString ?? rawSignature
        }
        return result
    }

    /// The consensus signature rule: every attached signature must verify over
    /// the current envelope or historical body-CID preimage, and at least one
    /// signature must be present. Requires a resolved body.
    public func signaturesAreValid() -> Bool {
        guard let bodyNode = body.node else { return false }
        return signaturesAreValid(bodyNode)
    }

    private func signaturesAreValid(_ bodyNode: TransactionBody) -> Bool {
        guard let signatures = Self.normalized(signatures),
              !signatures.isEmpty else {
            return false
        }
        for (publicKeyHex, signature) in signatures {
            if !TransactionSigning.verify(body: bodyNode, bodyCID: body.rawCID, signature: signature, publicKeyHex: publicKeyHex) {
                return false
            }
        }
        return true
    }

    /// THE consensus signer-coverage rule: the set of signing keys (by derived
    /// address) must equal the body's declared `signers` exactly. Consumed by
    /// block validation and by node-side admission — one definition so the two
    /// cannot drift. Requires a resolved body.
    public func signaturesMatchSigners() -> Bool {
        guard let bodyNode = body.node else { return false }
        return signaturesMatchSigners(bodyNode)
    }

    private func signaturesMatchSigners(_ bodyNode: TransactionBody) -> Bool {
        guard let signatures = Self.normalized(signatures) else { return false }
        let signatureHashes = Set(signatures.keys.map {
            CryptoUtils.createAddress(from: $0)
        })
        let signerSet = Set(bodyNode.signers)
        return signatureHashes == signerSet
    }

    private func validateSignaturesAndResolve(
        fetcher: Fetcher
    ) async throws -> TransactionBody? {
        let resolvedBody = try await body.resolve(fetcher: fetcher)
        guard let bodyNode = resolvedBody.node else { throw ValidationErrors.transactionNotResolved }
        if !signaturesAreValid(bodyNode) || !signaturesMatchSigners(bodyNode) {
            return nil
        }
        return bodyNode
    }

    func validateTransactionForGenesis(fetcher: Fetcher) async throws -> Bool {
        let resolvedBody = try await body.resolve(fetcher: fetcher)
        guard let bodyNode = resolvedBody.node else {
            throw ValidationErrors.transactionNotResolved
        }
        if !bodyNode.stateAtomsAreValid() { return false }
        if !bodyNode.accountActionsAreValid() { return false }
        if !bodyNode.actionsAreValid() { return false }
        if !bodyNode.depositActions.isEmpty { return false }
        if !bodyNode.withdrawalActions.isEmpty { return false }
        if !bodyNode.receiptActions.isEmpty { return false }
        return true
    }

    func validateTransactionForNexus(fetcher: Fetcher) async throws -> Bool {
        guard let bodyNode = try await validateSignaturesAndResolve(fetcher: fetcher) else { return false }
        if !bodyNode.stateAtomsAreValid() { return false }
        if !bodyNode.accountActionsAreValid() { return false }
        if !bodyNode.actionsAreValid() { return false }
        if !bodyNode.receiptActionsAreValid() { return false }
        if !bodyNode.depositActionsAreValid() { return false }
        if !bodyNode.withdrawalActionsAreValid() { return false }
        return true
    }

    func validateTransaction(directory: String, prevState: LatticeState, parentState: LatticeState, fetcher: Fetcher) async throws -> Bool {
        guard let bodyNode = try await validateSignaturesAndResolve(fetcher: fetcher) else { return false }
        if !bodyNode.stateAtomsAreValid() { return false }
        if !bodyNode.receiptActionsAreValid() { return false }
        if !bodyNode.accountActionsAreValid() { return false }
        if !bodyNode.actionsAreValid() { return false }
        if !bodyNode.depositActionsAreValid() { return false }
        if !bodyNode.withdrawalActionsAreValid() { return false }
        if try await !bodyNode.withdrawalsAreValid(directory: directory, prevState: prevState, parentState: parentState, fetcher: fetcher) { return false }
        return true
    }
}

extension Transaction: Node {
    public func get(property: PathSegment) -> (any cashew.Header)? {
        if property == TRANSACTION_BODY_PROPERTY { return body }
        return nil
    }

    public func properties() -> Set<PathSegment> {
        return TRANSACTION_PROPERTIES
    }

    public func set(properties: [PathSegment : any cashew.Header]) -> Transaction {
        return Self(signatures: signatures, body: properties[TRANSACTION_BODY_PROPERTY] as? HeaderImpl<TransactionBody> ?? body)
    }
}
