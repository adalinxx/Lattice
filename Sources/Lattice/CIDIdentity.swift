import CID

/// The one wire spelling for a content identity. CIDv1 uses canonical base32;
/// CIDv0 retains its required base58btc spelling. Consensus must never use a
/// presentation string as an identity key without this check.
public enum CIDIdentity {
    public static func canonicalString(_ value: String) -> String? {
        guard let parsed = try? CID(value),
              let canonical = try? CID(
                version: parsed.version,
                codec: parsed.codec,
                multihash: parsed.multihash
              )
        else { return nil }
        return canonical.toBaseEncodedString
    }

    public static func isCanonical(_ value: String) -> Bool {
        canonicalString(value) == value
    }
}
