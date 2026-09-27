import CID

/// Normalizes textual CID input before it becomes a consensus identity key.
public enum CIDIdentity {
    // Structural: a CID is length-prefixed with a UInt16 in the child-proof wire
    // format, so this is the encoding capacity, not a policy cap on CID length.
    // The canonical round-trip below is the real identity check; this only bounds
    // parse work on untrusted input to what the wire can represent.
    static let maximumTextBytes = Int(UInt16.max)

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
