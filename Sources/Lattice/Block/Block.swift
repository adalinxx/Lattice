import Foundation
import Crypto
import cashew
import UInt256
import CollectionConcurrencyKit

let PARENT_PROPERTY = "parent"
let TRANSACTIONS_PROPERTY = "transactions"
let SPEC_PROPERTY = "spec"
let PARENT_STATE_PROPERTY = "parentState"
let PREV_STATE_PROPERTY = "prevState"
let POST_STATE_PROPERTY = "postState"
let CHILDREN_PROPERTY = "children"

// Owned children only. parent/parentState/prevState are References (not
// children): excluded here so the generic store/resolve/proof walkers never
// descend into them. This is the structural half of "owned vs referenced".
// (spec is owned — a chain-shared leaf, kept transitively, not a history chain.)
let BLOCK_PROPERTIES = Set([TRANSACTIONS_PROPERTY, SPEC_PROPERTY, POST_STATE_PROPERTY, CHILDREN_PROPERTY])

public struct Block: Hashable {
    public static let currentVersion: UInt16 = 1

    public let version: UInt16
    // Backward links into unbounded history are REFERENCES, not owned children:
    // the block commits their CIDs but does not own their stored closure. They
    // are not in `properties()`, so the store/resolve walkers never descend into
    // them — pinning a block root cannot climb backward into prior state
    // (prevState), the parent chain's state (parentState), or ancestor blocks
    // (parent). Resolve them explicitly by CID via `.resolve(fetcher:)`.
    //
    // `spec` stays an OWNED child: it is a small chain-shared leaf with no
    // history chain, stored once (dedup) and kept transitively while ANY block
    // of the chain is pinned — retention-correct without a separate pin.
    public let parent: Reference<Block>?
    public let transactions: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>
    public let target: UInt256
    public let nextTarget: UInt256
    public let spec: VolumeImpl<ChainSpec>
    public let parentState: Reference<LatticeState>
    public let prevState: Reference<LatticeState>
    public let postState: LatticeStateHeader
    public let children: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>>
    public let height: UInt64
    public let timestamp: Int64
    public let nonce: UInt64

    public init(version: UInt16 = Block.currentVersion, parent: Reference<Block>?, transactions: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>, target: UInt256, nextTarget: UInt256, spec: VolumeImpl<ChainSpec>, parentState: Reference<LatticeState>, prevState: Reference<LatticeState>, postState: LatticeStateHeader, children: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>>, height: UInt64, timestamp: Int64, nonce: UInt64) {
        self.version = version
        self.parent = parent
        self.transactions = transactions
        self.target = target
        self.nextTarget = nextTarget
        self.spec = spec
        self.parentState = parentState
        self.prevState = prevState
        self.postState = postState
        self.children = children
        self.height = height
        self.timestamp = timestamp
        self.nonce = nonce
    }

    enum CodingKeys: String, CodingKey {
        case version
        case parent
        case transactions
        case target
        case nextTarget
        case spec
        case parentState
        case prevState
        case postState
        case children
        case height
        case timestamp
        case nonce
    }

    public static func == (lhs: Block, rhs: Block) -> Bool {
        canonicalSerialization(lhs) == canonicalSerialization(rhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(UInt256.hash(Self.canonicalSerialization(self)))
    }

    private static func canonicalSerialization(_ block: Block) -> Data {
        guard let data = block.toData() else {
            preconditionFailure("Block canonical serialization failed")
        }
        return data
    }

    public static func getTotalDeposited(_ allDepositActions: [DepositAction]) -> (total: UInt64, overflow: Bool) {
        var total: UInt64 = 0
        for action in allDepositActions {
            let (result, overflow) = total.addingReportingOverflow(action.amountDeposited)
            if overflow { return (0, true) }
            total = result
        }
        return (total, false)
    }

    public static func getTotalWithdrawn(_ allWithdrawalActions: [WithdrawalAction]) -> (total: UInt64, overflow: Bool) {
        var total: UInt64 = 0
        for action in allWithdrawalActions {
            let (result, overflow) = total.addingReportingOverflow(action.amountWithdrawn)
            if overflow { return (0, true) }
            total = result
        }
        return (total, false)
    }
}

extension Block: Node {
    public func get(property: PathSegment) -> (any cashew.Header)? {
        switch property {
            // parent/parentState/prevState are References, not children — not exposed here.
            case TRANSACTIONS_PROPERTY: return transactions
            case SPEC_PROPERTY: return spec
            case POST_STATE_PROPERTY: return postState
            case CHILDREN_PROPERTY: return children
            default: return nil
        }
    }

    public func properties() -> Set<PathSegment> {
        return BLOCK_PROPERTIES
    }

    public func set(properties: [PathSegment : any cashew.Header]) -> Block {
        // References (parent/parentState/prevState) are not children and are
        // never updated through this path — they carry through unchanged.
        return Block(
            version: version,
            parent: parent,
            transactions: properties[TRANSACTIONS_PROPERTY] as? HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>> ?? transactions,
            target: target,
            nextTarget: nextTarget,
            spec: properties[SPEC_PROPERTY] as? VolumeImpl<ChainSpec> ?? spec,
            parentState: parentState,
            prevState: prevState,
            postState: properties[POST_STATE_PROPERTY] as? LatticeStateHeader ?? postState,
            children: properties[CHILDREN_PROPERTY] as? HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>> ?? children,
            height: height,
            timestamp: timestamp,
            nonce: nonce
        )
    }
}

public enum ValidationErrors: Error {
    case transactionNotResolved, prevStateNotResolved, postStateNotResolved, serializationError
}
