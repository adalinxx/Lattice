import Foundation

/// Canonical Ed25519 public-key bytes used to authorize a parent process to
/// supply inherited work for a child chain. Lattice intentionally owns this
/// wire shape instead of depending on a networking library's key type.
public struct ParentWorkAuthorityKey: Codable, Hashable, Sendable,
    LosslessStringConvertible {
    public static let encodedByteCount = 64

    public let value: String

    public init?(_ value: String) {
        guard value.utf8.count == Self.encodedByteCount,
              value.utf8.allSatisfy({
                  (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
              }) else {
            return nil
        }
        self.value = value
    }

    public var description: String { value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let key = Self(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "parent work authority must be 32 lowercase hex bytes"
            )
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
