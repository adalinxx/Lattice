import Foundation
import UInt256

public struct SyncBlockHeader: Sendable {
    public let cid: String
    public let height: UInt64
    public let previousBlockCID: String?
    public let target: UInt256
    public let nextTarget: UInt256
    public let timestamp: Int64
    public let specCID: String?
    public let spec: ChainSpec?

    public init(
        cid: String,
        height: UInt64,
        previousBlockCID: String?,
        target: UInt256,
        nextTarget: UInt256 = .zero,
        timestamp: Int64,
        specCID: String? = nil,
        spec: ChainSpec? = nil
    ) {
        self.cid = cid
        self.height = height
        self.previousBlockCID = previousBlockCID
        self.target = target
        self.nextTarget = nextTarget
        self.timestamp = timestamp
        self.specCID = specCID
        self.spec = spec
    }
}
