import cashew

public actor Lattice {
    public let nexus: ChainLevel

    public init(nexus: ChainLevel) {
        self.nexus = nexus
    }
}

public enum ChainLevelTopologyError: Error, Sendable, Equatable {
    case emptyDirectory
    case childChainRequiresRootForest
    case directoryAlreadyAttached
}

public actor ChainLevel {
    public let chain: ChainState
    nonisolated let admissionContext: ChainAdmissionContext
    public private(set) var children: [String: ChainLevel]

    /// Create the root runtime. Child runtimes are derived only by this level's
    /// bootstrap or restore APIs so their admission identity follows topology.
    public init(chain: ChainState) {
        precondition(
            chain.rootPolicy == .singleGenesis,
            "A root ChainLevel must use .singleGenesis; child forests use bootstrapChild or restoreChildChain."
        )
        self.chain = chain
        self.children = [:]
        self.admissionContext = .root
    }

    private init(chain: ChainState, admissionContext: ChainAdmissionContext) {
        precondition(
            chain.rootPolicy == .childRootForest,
            "Child ChainLevels must use .childRootForest."
        )
        self.chain = chain
        self.children = [:]
        self.admissionContext = admissionContext
    }

    // MARK: - Child Chain Management

    /// Verify, durably prepare, and install the first root for a child runtime.
    ///
    /// A child does not exist until this succeeds, so the parent derives its
    /// immutable path context first and validates the candidate as that path's
    /// genesis. There is no raw-block bootstrap escape hatch: the same proof and
    /// durable-before-visibility rule applies to the first root and every later
    /// competing root.
    @discardableResult
    public func bootstrapChild(
        to directory: String,
        genesisHeader: BlockHeader,
        fetcher: Fetcher,
        childProof: ChildBlockProof,
        prepare: @escaping ChainCommitPreparer,
        retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE
    ) async throws -> ChainLevel {
        guard !directory.isEmpty else {
            throw ChainLevelTopologyError.emptyDirectory
        }
        guard children[directory] == nil else {
            throw ChainLevelTopologyError.directoryAlreadyAttached
        }

        let childContext = ChainAdmissionContext(parent: admissionContext, directory: directory)
        let genesisBlock: Block
        switch await ChainLocalAdmission.resolveBlock(genesisHeader, fetcher: fetcher) {
        case .success(let resolved):
            genesisBlock = resolved
        case .failure(let failure):
            throw failure
        }

        let transition: (stateDiff: StateDiff, materializedPostState: LatticeState?)
        switch await ChainLocalAdmission.validateGenesis(
            blockHeader: genesisHeader,
            block: genesisBlock,
            fetcher: fetcher,
            context: childContext,
            childProof: childProof
        ) {
        case .success(let validated):
            transition = validated
        case .failure(let failure):
            throw failure
        }

        if let failure = await ChainLocalAdmission.prepare(
            block: genesisBlock,
            stateDiff: transition.stateDiff,
            materializedPostState: transition.materializedPostState,
            prepare: prepare
        ) {
            throw failure
        }

        // The actor may have serviced another bootstrap while durable preparation
        // awaited. Do not replace or reinterpret the already-attached path.
        guard children[directory] == nil else {
            throw ChainLevelTopologyError.directoryAlreadyAttached
        }
        let childChain = ChainState.fromGenesis(
            block: genesisBlock,
            retentionDepth: retentionDepth,
            rootPolicy: .childRootForest
        )
        let childLevel = ChainLevel(
            chain: childChain,
            admissionContext: childContext
        )
        children[directory] = childLevel
        return childLevel
    }

    /// Return an already-attached child runtime without treating a repeated
    /// bootstrap request as a second root admission.
    public func childLevel(directory: String) -> ChainLevel? {
        children[directory]
    }

    #if DEBUG
    /// Test-only topology fixture for unit tests that exercise `ChainState`
    /// fork-choice directly. It is internal, unavailable to normal library
    /// consumers, and deliberately rejects non-genesis input. Production child
    /// creation must use the verified public overload above.
    func attachRestoredChildForTesting(
        to directory: String,
        genesisBlock: Block,
        retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE
    ) async throws -> ChainLevel {
        precondition(genesisBlock.parent == nil && genesisBlock.height == 0)
        let childChain = ChainState.fromGenesis(
            block: genesisBlock,
            retentionDepth: retentionDepth,
            rootPolicy: .childRootForest
        )
        return try await restoreChildChain(directory: directory, chain: childChain)
    }
    #endif

    /// Attach a previously restored child state under this level. The parent
    /// derives the child's immutable admission identity after checking that the
    /// state was restored as a child-root forest.
    @discardableResult
    public func restoreChildChain(directory: String, chain: ChainState) async throws -> ChainLevel {
        guard !directory.isEmpty else {
            throw ChainLevelTopologyError.emptyDirectory
        }
        guard await chain.getRootPolicy() == .childRootForest else {
            throw ChainLevelTopologyError.childChainRequiresRootForest
        }
        guard children[directory] == nil else {
            throw ChainLevelTopologyError.directoryAlreadyAttached
        }

        let childLevel = ChainLevel(
            chain: chain,
            admissionContext: ChainAdmissionContext(parent: admissionContext, directory: directory)
        )
        children[directory] = childLevel
        return childLevel
    }

}
