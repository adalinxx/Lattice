import LatticePrimitives

extension AccountAction {
    public func verify() -> Bool {
        delta != 0 && delta != Int64.min
    }
}

extension Action {
    public func verify() -> Bool {
        if key.isEmpty { return false }
        return oldValue != nil || newValue != nil
    }
}
