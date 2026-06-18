import Foundation

/// A verified parent-chain carrier as seen by a child chain.
///
/// This is not a parent-fork-continuity claim. Child validity is anchored by
/// proof-verified parent state roots; the carrier hash is kept only to bind the
/// accepted child block to the proof that secured it.
public struct ParentAnchor: Sendable, Equatable {
    public let blockHash: String
    public let parentHash: String?
    public let height: UInt64
    public let prevStateCID: String?

    public init(blockHash: String, parentHash: String?, height: UInt64, prevStateCID: String? = nil) {
        self.blockHash = blockHash
        self.parentHash = parentHash
        self.height = height
        self.prevStateCID = prevStateCID
    }

    /// Deterministic content comparator for choosing among multiple verified
    /// anchors. Peer/proof array order is never consensus input.
    public static func canonicalSelectionLess(_ lhs: ParentAnchor, _ rhs: ParentAnchor) -> Bool {
        if lhs.height != rhs.height { return lhs.height < rhs.height }
        if lhs.blockHash != rhs.blockHash { return lhs.blockHash < rhs.blockHash }
        if (lhs.parentHash ?? "") != (rhs.parentHash ?? "") { return (lhs.parentHash ?? "") < (rhs.parentHash ?? "") }
        return (lhs.prevStateCID ?? "") < (rhs.prevStateCID ?? "")
    }
}
