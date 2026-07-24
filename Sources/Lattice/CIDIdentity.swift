import CID

/// Normalizes textual CID input before it becomes a consensus identity key.
public enum CIDIdentity {
    static let maximumTextBytes = 128

    public static func canonicalString(_ value: String) -> String? {
        guard !value.isEmpty,
              value.utf8.count <= maximumTextBytes,
              let parsed = try? CID(value),
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
