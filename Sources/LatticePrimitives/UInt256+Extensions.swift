import Foundation
import UInt256
import Crypto

public extension UInt256 {

    /// Converts UInt256 to hexadecimal string with "0x" prefix
    /// - Returns: A hexadecimal string representation with "0x" prefix
    func toPrefixedHexString() -> String {
        let hexString = String(self, radix: 16)
        return "0x" + hexString
    }
    
    /// Creates a UInt256 from a hexadecimal string
    /// - Parameter hexString: A hexadecimal string with or without "0x" prefix
    /// - Returns: A UInt256 value if parsing succeeds, nil otherwise
    static func fromHexString(_ hexString: String) -> UInt256? {
        let cleanHex = hexString.hasPrefix("0x") || hexString.hasPrefix("0X") 
            ? String(hexString.dropFirst(2))
            : hexString
        return UInt256(cleanHex, radix: 16)
    }

}

extension UInt256: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.toPrefixedHexString())
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hexString = try container.decode(String.self)
        guard let value = UInt256.fromHexString(hexString) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid UInt256 hex string: \(hexString)"
            )
        }
        self = value
    }
}

public extension UInt256 {
    /// Creates a UInt256 hash from data using SHA-256
    /// - Parameter data: The data to hash
    /// - Returns: A UInt256 representing the SHA-256 hash
    static func hash(_ data: Data) -> UInt256 {
        let sha256Hash = SHA256.hash(data: data)
        let hashData = Data(sha256Hash)
        
        // Convert 32-byte hash to UInt256 (4 UInt64 parts)
        var parts: [UInt64] = [0, 0, 0, 0]
        
        // Fill parts from hash data (big-endian)
        for i in 0..<4 {
            let startIndex = i * 8
            let endIndex = startIndex + 8 < hashData.count ? startIndex + 8 : hashData.count
            if startIndex < hashData.count {
                let slice = hashData[startIndex..<endIndex]
                var value: UInt64 = 0
                for (index, byte) in slice.enumerated() {
                    value |= UInt64(byte) << (8 * (7 - index))
                }
                parts[i] = value
            }
        }
        
        return UInt256(parts)
    }
    
    /// Creates a UInt256 hash from a string using SHA-256
    /// - Parameter string: The string to hash
    /// - Returns: A UInt256 representing the SHA-256 hash
    static func hash(_ string: String) -> UInt256 {
        guard let data = string.data(using: .utf8) else {
            return UInt256()
        }
        return hash(data)
    }
}
