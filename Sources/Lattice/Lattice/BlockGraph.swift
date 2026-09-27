import UInt256

/// The immutable identity of one held block: what its PoW-bound content says
/// about its place in the tree. Nothing here changes once the block is held,
/// except that a fact written before `childCommitments` existed may later be
/// supplied its commitments (`BlockGraph.adoptChildCommitments`).
struct BlockRecord: Sendable, Equatable {
    let blockHash: String
    let parentBlockHash: String?
    let blockHeight: UInt64
    /// Nil when NOT RECORDED, never "commits nothing" (see
    /// `BlockMeta.childCommitments`).
    let childCommitments: [String: String]?
}

/// One block's verified work facts: every contribution by ID, which of them
/// are a parent's attributed runs rather than grinds, and their credited total.
struct BlockWork: Sendable {
    let contributions: [String: VerifiedWorkContribution]
    let attributedRuns: Set<String>
    let work: WorkSum

    /// This block's grinds: every contribution that is not an attributed run.
    var grinds: Set<String> {
        Set(contributions.keys.filter { !attributedRuns.contains($0) })
    }

    /// The credited work of this block's grinds alone. Derived from the
    /// contributions, never cached beside `work`, so it cannot drift from it.
    var grindWork: WorkSum {
        WorkMeasure(contributions.values.filter { !attributedRuns.contains($0.id) }).total
    }
}

/// The block tree `ChainState` holds: every held block's record, its child
/// edges, its work facts, its difficulty anchor and the diagnostic prefix and
/// subtree totals. This is the ONE representation of the tree — fork choice,
/// the execution frontier and run attribution store no edge of their own and
/// read this one.
struct BlockGraph: Sendable {
    private(set) var blocksByHash: [String: BlockMeta]

    init(_ blocks: [String: BlockMeta] = [:]) {
        self.blocksByHash = blocks
    }

    // MARK: Queries

    var count: Int { blocksByHash.count }

    func contains(_ hash: String) -> Bool {
        blocksByHash[hash] != nil
    }

    subscript(hash: String) -> BlockRecord? {
        blocksByHash[hash].map(Self.record)
    }

    /// Every held block's record, in no particular order.
    var records: some Collection<BlockRecord> {
        blocksByHash.values.lazy.map(Self.record)
    }

    func parent(of hash: String) -> String? {
        blocksByHash[hash]?.parentBlockHash
    }

    func height(of hash: String) -> UInt64? {
        blocksByHash[hash]?.blockHeight
    }

    /// The held children of `hash`, in the order they were recorded — never
    /// re-sorted. Empty for an unknown block.
    func children(of hash: String) -> [String] {
        blocksByHash[hash]?.childHashes ?? []
    }

    func work(of hash: String) -> BlockWork? {
        blocksByHash[hash].map {
            BlockWork(
                contributions: $0.workContributions,
                attributedRuns: $0.attributedRuns,
                work: $0.work
            )
        }
    }

    func contribution(id: String, at hash: String) -> VerifiedWorkContribution? {
        blocksByHash[hash]?.workContributions[id]
    }

    func difficultyAnchor(of hash: String) -> DifficultyAnchor? {
        blocksByHash[hash]?.difficultyAnchor
    }

    func cumulativeWork(of hash: String) -> WorkSum? {
        blocksByHash[hash]?.cumulativeWork
    }

    func subtreeWeight(of hash: String) -> WorkSum? {
        blocksByHash[hash]?.subtreeWeight
    }

    /// The public read view of one block.
    func meta(of hash: String) -> BlockMeta? {
        blocksByHash[hash]
    }

    private static func record(_ meta: BlockMeta) -> BlockRecord {
        BlockRecord(
            blockHash: meta.blockHash,
            parentBlockHash: meta.parentBlockHash,
            blockHeight: meta.blockHeight,
            childCommitments: meta.childCommitments
        )
    }

    // MARK: Mutations

    /// Hold a newly admitted block with no work yet, zero diagnostics and the
    /// children already held for it.
    mutating func insert(
        _ record: BlockRecord,
        children: [String],
        difficultyAnchor: DifficultyAnchor?
    ) {
        blocksByHash[record.blockHash] = BlockMeta(
            blockHash: record.blockHash,
            parentBlockHash: record.parentBlockHash,
            blockHeight: record.blockHeight,
            childHashes: children,
            workContributions: [],
            cumulativeWork: .zero,
            subtreeWeight: .zero,
            difficultyAnchor: difficultyAnchor,
            childCommitments: record.childCommitments
        )
    }

    /// Record `child` under a held `parent`, appended last, unless already
    /// recorded.
    mutating func appendChild(_ child: String, to parent: String) {
        if blocksByHash[parent]?.childHashes.contains(child) == false {
            blocksByHash[parent]?.childHashes.append(child)
        }
    }

    /// False when the block is unknown or `contribution` is not strictly
    /// stronger than the one held under its ID.
    mutating func setWorkContribution(
        _ contribution: VerifiedWorkContribution,
        attributed: Bool,
        at hash: String
    ) -> Bool {
        blocksByHash[hash]?.setWorkContribution(contribution, attributed: attributed) == true
    }

    mutating func adoptDifficultyAnchor(_ anchor: DifficultyAnchor, at hash: String) {
        blocksByHash[hash]?.adoptDifficultyAnchor(anchor)
    }

    mutating func adoptChildCommitments(_ commitments: [String: String], at hash: String) {
        blocksByHash[hash]?.adoptChildCommitments(commitments)
    }

    /// Rebuild the diagnostic prefix and subtree totals; see
    /// `ChainState.recomputeWorkCaches`.
    mutating func recomputeWorkCaches() {
        ChainState.recomputeWorkCaches(in: &blocksByHash)
    }
}
