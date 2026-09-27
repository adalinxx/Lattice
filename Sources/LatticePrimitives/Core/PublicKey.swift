import cashew
import Foundation

public struct PublicKey: Scalar {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

public extension PublicKey {
    init?(data: Data) {
        guard let keyString = String(data: data, encoding: .utf8) else { return nil }
        self.init(key: keyString)
    }
    
    func toData() -> Data? {
        return key.data(using: .utf8)
    }
}
