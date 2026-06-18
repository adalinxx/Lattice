import Foundation
import Crypto
import Multikey
import cashew
import CID
import Multicodec

public struct CryptoUtils {
    public static let signatureDomain = "lattice-tx-v1:"

    // MARK: - Key Generation (Ed25519 default)

    public static func generateKeyPair() -> (privateKey: String, publicKey: String) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pubKeyData = privateKey.publicKey.rawRepresentation
        let privKeyData = privateKey.rawRepresentation
        let mk = Multikey(keyType: .ed25519, keyBytes: pubKeyData)
        return (privKeyData.hexString, mk.hexEncoded)
    }

    // MARK: - Signing

    public static func sign(message: String, privateKeyHex: String) -> String? {
        guard let privateKeyData = Data(hex: privateKeyHex),
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) else {
            return nil
        }
        let messageData = signaturePayload(message)
        guard let signature = try? privateKey.signature(for: messageData) else { return nil }
        return signature.hexString
    }

    // MARK: - Verification (dispatches by key type in Multikey encoding)

    public static func verify(message: String, signature: String, publicKeyHex: String) -> Bool {
        guard let sigData = Data(hex: signature) else { return false }
        let messageData = signaturePayload(message)

        // Exactly ONE accepted key encoding: Multikey. The pre-genesis legacy
        // branch that also accepted a bare 32-byte Ed25519 hex key gave the
        // same key two valid encodings on live consensus surface — fail closed
        // on anything that is not canonical Multikey.
        guard let mk = try? Multikey.decode(fromHex: publicKeyHex) else { return false }
        return verifyWithMultikey(mk, message: messageData, signature: sigData)
    }

    static func signaturePayload(_ message: String) -> Data {
        var data = Data(signatureDomain.utf8)
        data.append(contentsOf: message.utf8)
        return data
    }

    private static func verifyWithMultikey(_ mk: Multikey, message: Data, signature: Data) -> Bool {
        switch mk.keyType {
        case .ed25519:
            guard mk.keyBytes.count == 32,
                  let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: mk.keyBytes),
                  signature.count == 64 else { return false }
            return pubKey.isValidSignature(signature, for: message)
        default:
            return false
        }
    }

    // MARK: - Address derivation

    /// Derive an address from a public key.
    /// Returns the CID of the PublicKey struct — consistent with the on-chain
    /// address format used since the original protocol design.
    public static func createAddress(from publicKey: String) -> String {
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        try! HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
    }

    /// Cheap structural pre-check: `address` is a canonical CIDv1 / dag-cbor /
    /// sha2-256 (32-byte) CID — the shape `createAddress(from:)` produces. This
    /// is necessary but NOT sufficient: a structurally valid CID for any other
    /// content also passes. Callers that disburse value MUST additionally bind
    /// the address to a public key via ``isAddress(_:of:)``. Decodes with the
    /// same `CID` primitive used to *build* the address — no bespoke base32 —
    /// and rejects non-canonical encodings (the re-encoded form must match the
    /// input byte-for-byte).
    public static func isValidAddress(_ address: String) -> Bool {
        guard let cid = try? CID(address) else { return false }
        guard cid.version == .v1, cid.codec == .dag_cbor else { return false }
        guard cid.multihash.algorithm == .sha2_256, cid.multihash.length == 32 else { return false }
        return cid.toBaseEncodedString == address
    }

    /// Confirm `address` is the CID of the `PublicKey` for `publicKeyHex` — i.e.
    /// it round-trips through the exact construction path ``createAddress(from:)``
    /// uses. A structurally-valid CID for any other content fails here. Fail
    /// closed: also require the structural check so a malformed `publicKeyHex`
    /// that happens to derive a matching string cannot slip through.
    public static func isAddress(_ address: String, of publicKeyHex: String) -> Bool {
        guard isValidAddress(address) else { return false }
        return createAddress(from: publicKeyHex) == address
    }

    // MARK: - Hashing

    public static func sha256(_ input: String) -> String {
        Data(SHA256.hash(data: Data(input.utf8))).hexString
    }

    public static func sha256Data(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

public extension Data {
    init?(hex: String) {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard clean.count % 2 == 0 else { return nil }
        var data = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
