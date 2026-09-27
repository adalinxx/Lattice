import cashew
import Foundation

public struct Action: Codable, Sendable {
    public let key: String
    public let oldValue: String?
    public let newValue: String?

    public init(key: String, oldValue: String?, newValue: String?) {
        self.key = key
        self.oldValue = oldValue
        self.newValue = newValue
    }
    
    public func stateDelta() -> Int {
        let keyCount = key.utf8.count
        if oldValue == nil {
            return newValue!.utf8.count + keyCount
        }
        if newValue == nil {
            return 0 - oldValue!.utf8.count - keyCount
        }
        return newValue!.utf8.count - oldValue!.utf8.count
    }
    
    public func verify() -> Bool {
        if key.isEmpty { return false }
        return oldValue != nil || newValue != nil
    }

}
