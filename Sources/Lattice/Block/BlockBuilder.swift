import Foundation
import cashew
import UInt256

public enum BlockBuilderError: Error {
    case missingPrevState
    case missingSpec
    case heightOverflow
}

public struct BlockBuildResult: Sendable {
    public let block: Block
    public let stateDiff: StateDiff
    public let materializedPostState: LatticeState?

    public init(block: Block, stateDiff: StateDiff, materializedPostState: LatticeState?) {
        self.block = block
        self.stateDiff = stateDiff
        self.materializedPostState = materializedPostState
    }
}

public struct BlockBuilder {

    // MARK: - Build Genesis Block

    public static func buildGenesis(
        spec: ChainSpec,
        transactions: [Transaction] = [],
        children: [String: Block] = [:],
        timestamp: Int64,
        target: UInt256,
        nonce: UInt64 = 0,
        version: UInt16 = Block.currentVersion,
        fetcher: Fetcher
    ) async throws -> Block {
        try await buildGenesisWithTransition(
            spec: spec,
            transactions: transactions,
            children: children,
            timestamp: timestamp,
            target: target,
            nonce: nonce,
            version: version,
            fetcher: fetcher
        ).block
    }

    public static func buildGenesisWithTransition(
        spec: ChainSpec,
        transactions: [Transaction] = [],
        children: [String: Block] = [:],
        timestamp: Int64,
        target: UInt256,
        nonce: UInt64 = 0,
        version: UInt16 = Block.currentVersion,
        fetcher: Fetcher
    ) async throws -> BlockBuildResult {
        try await buildGenesisWithTransition(
            spec: spec,
            transactions: transactions,
            children: children,
            parentState: LatticeState.emptyHeader,
            timestamp: timestamp,
            target: target,
            nonce: nonce,
            version: version,
            fetcher: fetcher
        )
    }

    /// Build a child-chain genesis that commits the entering state of the
    /// parent carrier which will contain it. The child's own `prevState` remains
    /// empty; `parentState` is the vertical binding verified by
    /// `ChildBlockProof`.
    public static func buildChildGenesis(
        spec: ChainSpec,
        parentState: LatticeStateHeader,
        transactions: [Transaction] = [],
        children: [String: Block] = [:],
        timestamp: Int64,
        target: UInt256,
        nonce: UInt64 = 0,
        version: UInt16 = Block.currentVersion,
        fetcher: Fetcher
    ) async throws -> Block {
        try await buildChildGenesisWithTransition(
            spec: spec,
            parentState: parentState,
            transactions: transactions,
            children: children,
            timestamp: timestamp,
            target: target,
            nonce: nonce,
            version: version,
            fetcher: fetcher
        ).block
    }

    public static func buildChildGenesisWithTransition(
        spec: ChainSpec,
        parentState: LatticeStateHeader,
        transactions: [Transaction] = [],
        children: [String: Block] = [:],
        timestamp: Int64,
        target: UInt256,
        nonce: UInt64 = 0,
        version: UInt16 = Block.currentVersion,
        fetcher: Fetcher
    ) async throws -> BlockBuildResult {
        try await buildGenesisWithTransition(
            spec: spec,
            transactions: transactions,
            children: children,
            parentState: parentState,
            timestamp: timestamp,
            target: target,
            nonce: nonce,
            version: version,
            fetcher: fetcher
        )
    }

    private static func buildGenesisWithTransition(
        spec: ChainSpec,
        transactions: [Transaction],
        children: [String: Block],
        parentState: LatticeStateHeader,
        timestamp: Int64,
        target: UInt256,
        nonce: UInt64,
        version: UInt16,
        fetcher: Fetcher
    ) async throws -> BlockBuildResult {
        let emptyState = LatticeState.emptyState()
        let prevState = try LatticeStateHeader(node: emptyState)

        let transactionBodies = transactions.compactMap { $0.body.node }
        let (postState, stateDiff) = try await computePostState(
            prevState: prevState,
            transactionBodies: transactionBodies,
            fetcher: fetcher
        )

        let block = Block(
            version: version,
            parent: nil,
            transactions: try buildTransactionsDictionary(transactions),
            target: target,
            nextTarget: target,
            spec: try VolumeImpl<ChainSpec>(node: spec),
            parentState: parentState.removingNode(),
            prevState: prevState.removingNode(),
            postState: postState,
            children: try buildChildrenDictionary(children),
            height: 0,
            timestamp: timestamp,
            nonce: nonce
        )
        return BlockBuildResult(
            block: block,
            stateDiff: stateDiff,
            materializedPostState: postState.node
        )
    }

    // MARK: - Build Next Block (extends a chain)

    public static func buildBlock(
        previous: Block,
        transactions: [Transaction] = [],
        children: [String: Block] = [:],
        parentChainBlock: Block? = nil,
        timestamp: Int64,
        target: UInt256? = nil,
        nextTarget: UInt256? = nil,
        nonce: UInt64 = 0,
        fetcher: Fetcher
    ) async throws -> Block {
        try await buildBlockWithTransition(
            previous: previous,
            transactions: transactions,
            children: children,
            parentChainBlock: parentChainBlock,
            timestamp: timestamp,
            target: target,
            nextTarget: nextTarget,
            nonce: nonce,
            fetcher: fetcher
        ).block
    }

    public static func buildBlockWithTransition(
        previous: Block,
        transactions: [Transaction] = [],
        children: [String: Block] = [:],
        parentChainBlock: Block? = nil,
        timestamp: Int64,
        target: UInt256? = nil,
        nextTarget: UInt256? = nil,
        nonce: UInt64 = 0,
        fetcher: Fetcher
    ) async throws -> BlockBuildResult {
        let (height, heightOverflow) = previous.height.addingReportingOverflow(1)
        guard !heightOverflow else { throw BlockBuilderError.heightOverflow }
        let prevState = previous.postState
        let parentState: LatticeStateHeader
        if let parentChainBlock = parentChainBlock {
            parentState = parentChainBlock.prevState.removingNode()
        } else {
            parentState = previous.parentState
        }

        let blockTarget = target ?? max(previous.nextTarget, ChainSpec.minimumTarget)
        let blockNextTarget: UInt256
        if let nextTarget {
            blockNextTarget = nextTarget
        } else {
            let specNode: ChainSpec
            if let node = previous.spec.node {
                specNode = node
            } else {
                let resolved = try await previous.spec.resolve(fetcher: fetcher)
                guard let node = resolved.node else { throw BlockBuilderError.missingSpec }
                specNode = node
            }
            let ancestorTimestamps = await collectAncestorTimestamps(
                from: previous,
                count: specNode.retargetWindow,
                fetcher: fetcher
            )
            blockNextTarget = specNode.calculateWindowedTarget(
                previousTarget: blockTarget,
                ancestorTimestamps: [timestamp] + ancestorTimestamps
            )
        }
        let previousCID = try BlockHeader(node: previous).rawCID

        let transactionBodies = transactions.compactMap { $0.body.node }
        let (postState, stateDiff) = try await computePostState(
            prevState: prevState,
            transactionBodies: transactionBodies,
            fetcher: fetcher
        )

        let block = Block(
            version: previous.version,
            parent: VolumeImpl<Block>(rawCID: previousCID),
            transactions: try buildTransactionsDictionary(transactions),
            target: blockTarget,
            nextTarget: blockNextTarget,
            spec: previous.spec,
            parentState: parentState,
            prevState: prevState.removingNode(),
            postState: postState,
            children: try buildChildrenDictionary(children),
            height: height,
            timestamp: timestamp,
            nonce: nonce
        )
        return BlockBuildResult(
            block: block,
            stateDiff: stateDiff,
            materializedPostState: postState.node
        )
    }

    private static func collectAncestorTimestamps(from block: Block, count: UInt64, fetcher: Fetcher) async -> [Int64] {
        guard count > 0 else { return [] }
        var timestamps: [Int64] = [block.timestamp]
        var current = block
        for _ in 1..<count {
            guard let parentRef = current.parent,
                  let parent = try? await parentRef.resolve(fetcher: fetcher).node else {
                break
            }
            timestamps.append(parent.timestamp)
            current = parent
        }
        return timestamps
    }

    // MARK: - Mining (find valid nonce)

    public static func mine(
        block: Block,
        target: UInt256,
        maxAttempts: UInt64 = UInt64.max
    ) -> Block? {
        for nonce in 0..<maxAttempts {
            let data = Block.makeProofOfWorkPreimage(block: block, nonce: nonce)
            let hash = UInt256.hash(data)
            if target >= hash {
                return Block(
                    version: block.version,
                    parent: block.parent,
                    transactions: block.transactions,
                    target: block.target,
                    nextTarget: block.nextTarget,
                    spec: block.spec,
                    parentState: block.parentState,
                    prevState: block.prevState,
                    postState: block.postState,
                    children: block.children,
                    height: block.height,
                    timestamp: block.timestamp,
                    nonce: nonce
                )
            }
        }
        return nil
    }

    // MARK: - Post State Computation

    static func computePostState(
        prevState: LatticeStateHeader,
        transactionBodies: [TransactionBody],
        fetcher: Fetcher
    ) async throws -> (LatticeStateHeader, StateDiff) {
        if transactionBodies.isEmpty {
            return (prevState, .empty)
        }

        guard let prevStateNode = prevState.node else {
            let resolved = try await prevState.resolve(fetcher: fetcher)
            guard let resolvedNode = resolved.node else {
                throw BlockBuilderError.missingPrevState
            }
            return try await computePostStateFromState(
                state: resolvedNode,
                transactionBodies: transactionBodies,
                fetcher: fetcher
            )
        }

        return try await computePostStateFromState(
            state: prevStateNode,
            transactionBodies: transactionBodies,
            fetcher: fetcher
        )
    }

    static func computePostStateFromState(
        state: LatticeState,
        transactionBodies: [TransactionBody],
        fetcher: Fetcher
    ) async throws -> (LatticeStateHeader, StateDiff) {
        // Collect each action family in one pass.
        var allAccountActions: [AccountAction] = []
        var allActions: [Action] = []
        var allDepositActions: [DepositAction] = []
        var allGenesisActions: [GenesisAction] = []
        var allReceiptActions: [ReceiptAction] = []
        var allWithdrawalActions: [WithdrawalAction] = []
        for body in transactionBodies {
            allAccountActions.append(contentsOf: body.accountActions)
            allActions.append(contentsOf: body.actions)
            allDepositActions.append(contentsOf: body.depositActions)
            allGenesisActions.append(contentsOf: body.genesisActions)
            allReceiptActions.append(contentsOf: body.receiptActions)
            allWithdrawalActions.append(contentsOf: body.withdrawalActions)
        }

        let (updatedState, stateDiff) = try await state.proveAndUpdateState(
            allAccountActions: allAccountActions,
            allActions: allActions,
            allDepositActions: allDepositActions,
            allGenesisActions: allGenesisActions,
            allReceiptActions: allReceiptActions,
            allWithdrawalActions: allWithdrawalActions,
            transactionBodies: transactionBodies,
            fetcher: fetcher
        )

        return (try LatticeStateHeader(node: updatedState), stateDiff)
    }

    // MARK: - Merkle Dictionary Construction

    static func buildTransactionsDictionary(
        _ transactions: [Transaction]
    ) throws -> HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>> {
        if transactions.isEmpty {
            return try HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>(
                node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()
            )
        }

        var dict = MerkleDictionaryImpl<VolumeImpl<Transaction>>()
        for (i, tx) in transactions.enumerated() {
            let txHeader = try VolumeImpl<Transaction>(node: tx)
            dict = (try? dict.inserting(key: String(i), value: txHeader)) ?? dict
        }
        return try HeaderImpl(node: dict)
    }

    static func buildChildrenDictionary(
        _ children: [String: Block]
    ) throws -> HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>> {
        if children.isEmpty {
            return try HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>>(
                node: MerkleDictionaryImpl<VolumeImpl<Block>>()
            )
        }

        var dict = MerkleDictionaryImpl<VolumeImpl<Block>>()
        for (directory, block) in children {
            let blockHeader = try VolumeImpl<Block>(node: block)
            dict = (try? dict.inserting(key: directory, value: blockHeader)) ?? dict
        }
        return try HeaderImpl(node: dict)
    }
}
