public enum StateErrors: Error {
    case conflictingActions
    case insufficientBalance
    case balanceOverflow
    case nonceGap
}
