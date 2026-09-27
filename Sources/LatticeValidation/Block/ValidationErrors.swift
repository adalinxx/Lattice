public enum ValidationErrors: Error, Sendable, Equatable {
    case transactionNotResolved, prevStateNotResolved, postStateNotResolved, serializationError
}
