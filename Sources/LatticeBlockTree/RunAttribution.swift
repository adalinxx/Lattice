import cashew
import CID
import UInt256
import LatticePrimitives
import LatticePoW

// Parent-attributed run work (§9.10): what a parent serves its children
// about committing blocks, and how a child derives a strengthening from
// it.

/// What a parent serves a child about one of its blocks that commits into a
/// child directory (§9.10): the RUN work at that block, the credited work of
/// the block's own grinds, and the revision the pair was read at, for
/// provenance.
///
/// The run is the sum of credited work — grinds and attributed runs alike —
/// over every connected parent block
/// whose nearest committer into `directory` — by parent pointer, never by
/// canonical chain — is `blockHash`. Runs partition the graph, so each parent
/// grind is in exactly one run and a fork below the committer puts each branch
/// in its own branch's run: nothing missed, nothing counted twice. Insert-only
/// and never revoked. Served in O(1) plus the committer's grind set.
public struct ParentRunReport: Sendable, Equatable {
    /// The committing parent block.
    public let blockHash: String
    public let directory: String
    /// The child block `blockHash` commits into `directory` — what the child
    /// binds the report to before reading any number.
    public let childBlock: String
    /// Every grind — never an attributed run — credited at the committer; the
    /// child requires one of them at `childBlock`, which is what makes the
    /// committer a committer of it.
    public let grinds: Set<String>
    public let runWork: WorkSum
    /// The credited work of the committer's own grinds: what the child already
    /// holds, at its own price. A run the committer's OWN parent attributed at
    /// it is in `runWork` and not here, so it flows down another level.
    public let ownWork: WorkSum
    public let revision: UInt64

    /// Public so a node can rebuild the report it received on the wire; the
    /// binding and the quantity are checked by `strengthenFromParentReport`,
    /// never by construction.
    public init(
        blockHash: String,
        directory: String,
        childBlock: String,
        grinds: Set<String>,
        runWork: WorkSum,
        ownWork: WorkSum,
        revision: UInt64
    ) {
        self.blockHash = blockHash
        self.directory = directory
        self.childBlock = childBlock
        self.grinds = grinds
        self.runWork = runWork
        self.ownWork = ownWork
        self.revision = revision
    }
}

/// The identity under which a parent's attributed run work is credited at a
/// child block: keyed by the committing parent block and the directory — one
/// run, one identity — so a committer mined under several grinds is credited
/// once, not once per grind. A SEPARATE identity from any grind, deliberately:
/// crediting the run by strengthening the grind itself is not idempotent (the
/// second identical report would count the first attribution as the child's
/// own price and add it again), whereas a separate contribution ratchets on
/// its own value.
public struct AttributedRunIdentity: Hashable, Scalar {
    public let committerBlockHash: String
    public let directory: String

    public init(committerBlockHash: String, directory: String) {
        self.committerBlockHash = committerBlockHash
        self.directory = directory
    }

    public var contributionID: String? {
        try? HeaderImpl<AttributedRunIdentity>(node: self).rawCID
    }
}

/// The outcome of applying a parent's run report to a child block. Refusals
/// are typed so the node can make them VISIBLE: a parent whose reports keep
/// being refused is the likeliest symptom of a parent-side accounting bug, and
/// a silent refusal is exactly what would hide it.
public enum ParentReportStrengthening: Sendable, Equatable {
    /// Stage this work-only batch durably, then apply it.
    case strengthened(BlockImportBatch)
    /// The report does not name this child block, or none of the committer's
    /// grinds is credited here — so the reported block is not a committer of
    /// this child block as far as this chain knows.
    case notCommitterOfChild
    /// The report is for another directory: a parent committing into several
    /// directories serves one run per directory, and only this chain's own
    /// may be applied here.
    case wrongDirectory
    /// This committer's run is already credited at ANOTHER child block. A
    /// location is write-once and never revoked, so unlike every other refusal
    /// this one is permanent: it is the signature of a parent that once named
    /// the wrong child block, and it must be visible as exactly that. It must
    /// also never become a fact: staged anyway, it is a corrupt graph on apply
    /// and on every restore — derive under the lease held through the write
    /// (see `strengthenFromParentReport`).
    case locationConflict
    /// `ownWork` exceeds `runWork`, which no honest run can do.
    case malformedReport
    /// The derived quantity exceeds what one contribution can carry. Refused
    /// rather than saturated: a saturated value ties with every other and
    /// erases the ordering fork choice needs (§9.2).
    case unrepresentable(derived: WorkSum)
    /// Not a strict increase over what the child already holds. Monotonic
    /// refusal: a report may only ever raise.
    case notStronger(existing: WorkSum, derived: WorkSum)
}

/// Parent-attributed run work (§9.10) as a value: the served directories,
/// one accumulator per run, and each settled block's nearest committer per
/// served directory. It stores no parent or child edge — its two walks take
/// the block graph as a parameter — so a run is exactly one accumulator cell
/// plus a per-block pointer inherited from the parent, never a second
/// representation of the tree.
struct RunAttribution: Sendable {
    /// The child directories this node serves run reports for — the child
    /// chains it hosts. Operator choice, so the per-block run cost is bounded
    /// by what this node asked for, not by what any block commits into.
    private(set) var served: Set<String> = []
    /// Run work per child directory per committing block (§9.10): the sum of
    /// credited work — grinds and attributed runs alike — over CONNECTED
    /// blocks whose nearest committer into that directory is the key.
    /// Insert-only, independent of exclusion, and maintained by the one
    /// reducer live admission and replay both use.
    /// Served to children; never a fork-choice input on THIS chain.
    private(set) var runWork: [String: [String: WorkSum]] = [:]
    /// Block → directory → the nearest block at or above that block, by
    /// parent pointer, that commits into that directory — the block itself
    /// where it commits. Held only for the directories this node SERVES runs
    /// for (the child chains it hosts — an operator choice), so it costs
    /// O(#served) per block, never O(#directories ever committed); inherited
    /// from the parent like `difficultyAnchor`, and absent until the block is
    /// connected.
    private(set) var nearestCommitter: [String: [String: String]] = [:]
#if DEBUG
    /// Run-bucket updates. Each connected block costs one per directory it
    /// has a nearest committer for, so this is O(#directories) per block —
    /// asserted by ratio, never by stopwatch.
    private(set) var updateCount: UInt64 = 0
#endif

    /// Start serving `directory`: settle every connected block's nearest
    /// committer and run for that one directory, parent before child, over
    /// the UNFILTERED graph. Idempotent.
    mutating func serve(
        _ directory: String,
        in graph: BlockGraph,
        isRouted: (String) -> Bool
    ) {
        guard served.insert(directory).inserted else { return }
        var stack = graph.records
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
        while let hash = stack.popLast() {
            guard isRouted(hash), graph.contains(hash) else { continue }
            settle(hash, in: graph, directories: [directory])
            stack.append(contentsOf: graph.children(of: hash))
        }
    }

    /// Settle a block that just routed and every descendant that routed with
    /// it: its nearest committers and runs for every served directory, parent
    /// before child. Nothing below a just-routed block can have been settled
    /// before — a block never routes under an unrouted parent — so the walk
    /// needs no record of what it has settled. Unfiltered on purpose: an
    /// excluded descendant is still connected and still credited.
    mutating func connect(
        rootedAt rootHash: String,
        in graph: BlockGraph
    ) {
        var stack = [rootHash]
        var visited = Set<String>()
        while let hash = stack.popLast() {
            guard graph.contains(hash), visited.insert(hash).inserted else { continue }
            settle(hash, in: graph, directories: served)
            stack.append(contentsOf: graph.children(of: hash))
        }
    }

    /// The one per-block step of run attribution, for a connected block whose
    /// parent is already settled: for each directory, the nearest committer is
    /// this block if it commits there, else the parent's; the block's credited
    /// work — grinds and attributed runs alike — is credited to that run.
    /// Used both by live connection (every served directory) and by
    /// `serve` (one directory over the whole graph), so a run has exactly one
    /// definition.
    private mutating func settle(
        _ hash: String,
        in graph: BlockGraph,
        directories: Set<String>
    ) {
        guard let meta = graph[hash], let work = graph.work(of: hash) else { return }
        let inherited = meta.parentBlockHash
            .flatMap { nearestCommitter[$0] } ?? [:]
        var nearest = nearestCommitter[hash] ?? [:]
        var credited: [String: String] = [:]
        for directory in directories {
            let committer = meta.childCommitments?[directory] != nil ? hash : inherited[directory]
            guard let committer else { continue }
            nearest[directory] = committer
            credited[directory] = committer
        }
        nearestCommitter[hash] = nearest
        credit(work.work, nearest: credited)
    }

    /// A connected block's own work rose by `delta`: its runs rise by exactly
    /// that much.
    mutating func credit(_ delta: WorkSum, at hash: String) {
        credit(delta, nearest: nearestCommitter[hash] ?? [:])
    }

    private mutating func credit(_ work: WorkSum, nearest: [String: String]) {
        for (directory, committer) in nearest {
            let current = runWork[directory]?[committer] ?? .zero
            runWork[directory, default: [:]][committer] = current + work
#if DEBUG
            updateCount &+= 1
#endif
        }
    }

    /// Stop serving `directory` and drop everything settled for it, so
    /// `serve` can re-settle it from scratch.
    mutating func forget(directory: String) {
        served.remove(directory)
        runWork[directory] = nil
        for block in nearestCommitter.keys {
            nearestCommitter[block]?[directory] = nil
        }
    }
}

extension ChainState {
#if DEBUG
    var runAttributionUpdateCount: UInt64 { runs.updateCount }
#endif

    /// Start serving run reports for `directory` — the node hosts a child
    /// chain there. Settles every connected block's nearest committer and run
    /// for that one directory, parent before child, over the UNFILTERED graph:
    /// O(N) once, at the operator's choice, and idempotent. Which directories a
    /// node serves is its own choice, so a stranger's block committing into ten
    /// thousand directories costs this node nothing it did not ask for.
    ///
    /// The served set is NOT persisted: the node must call this for every
    /// directory it hosts after every restart, and it runs synchronously on
    /// the actor — one whole-graph walk per directory.
    public func serveRuns(for directory: String) {
        runs.serve(directory, in: graph, isRouted: { forkChoice.isRouted($0) })
    }

    func connectForRunAttribution(rootedAt rootHash: String) {
        runs.connect(rootedAt: rootHash, in: graph)
    }

    /// The run report a parent serves for one of its committing blocks. Nil
    /// when `directory` is not served here (`serveRuns(for:)`), or the block is
    /// unknown, not connected, or does not commit into `directory` — a child
    /// must never be handed a number for a block that is not a committer into
    /// its own directory. O(1).
    ///
    /// The connectivity conjunct is redundant by construction (a run entry is
    /// only ever written for a connected block, so the lookup below already
    /// fails for an orphan) and is kept as the stated rule rather than an
    /// accident of the table's maintenance.
    public func parentRunReport(
        at blockHash: String,
        directory: String
    ) -> ParentRunReport? {
        guard let hash = CIDIdentity.canonicalString(blockHash),
              forkChoice.isRouted(hash),
              let meta = graph[hash],
              let work = graph.work(of: hash),
              let childBlock = meta.childCommitments?[directory],
              let run = runs.runWork[directory]?[hash] else { return nil }
        return ParentRunReport(
            blockHash: hash,
            directory: directory,
            childBlock: childBlock,
            grinds: work.grinds,
            runWork: run,
            ownWork: work.grindWork,
            revision: mutationGeneration
        )
    }

    /// Derive the strengthening a parent's run report implies for one of this
    /// chain's blocks, as a work-only batch the node must make durable and
    /// then apply. This is the ONLY route by which a wire number reaches a
    /// `VerifiedWorkContribution`, and it does not take the number as-is: the
    /// quantity is DERIVED here from this chain's own state and refused unless
    /// it is a strict increase.
    ///
    /// The report is BOUND before any number is read: it must name this child
    /// block as the one its committer commits, it must be for `directory` —
    /// this chain's own, which the caller knows and this actor does not — and
    /// one of the grinds the report attributes to the committer must already be
    /// credited here — the parent's word, like the quantity. The attributed
    /// quantity is `runWork − ownWork`: the committer's own grinds stay counted
    /// exactly once, at the child's own price; the run's other blocks are
    /// credited under `AttributedRunIdentity(committer, directory)`, which
    /// ratchets on its own value, so a repeated report is a refusal, not a
    /// second addition. A run the committer was itself attributed by ITS
    /// parent is in the run and none of its grinds, so it is credited here
    /// too: the recursion holds at the committer, not only above it.
    ///
    /// The QUANTITY is the parent's word. The child already trusts its
    /// configured parent process for state continuity (§5.3), which gates
    /// minting outright, so this is not a new trust class; a verified path can
    /// replace it later with no consensus change (§9.10).
    ///
    /// Everything downstream is the existing work path: `applyStaged`
    /// re-checks strict increase and returns nil on a stale or duplicate batch,
    /// so a report computed before a concurrent STRONGER one applied is a
    /// harmless no-op, live and on replay alike. A report naming a DIFFERENT
    /// child block for a committer whose run is already located is another
    /// matter: a location is write-once, and a durable fact that loses that
    /// race is a corrupt graph on apply and on every restore, exactly as a
    /// second location for any grind is. So the node MUST hold its mutation
    /// lease from a derive through the durable write and `replay` — derive
    /// once to decide, and again under the lease to write; the cost is O(1)
    /// plus the report's grind set — the same shape as `commitPreflight`'s
    /// exclusion re-check. `.locationConflict` is then a refusal, never a fact.
    public func strengthenFromParentReport(
        child childHash: String,
        directory: String,
        report: ParentRunReport
    ) -> ParentReportStrengthening {
        guard report.directory == directory else { return .wrongDirectory }
        guard let hash = CIDIdentity.canonicalString(childHash),
              CIDIdentity.canonicalString(report.childBlock) == hash,
              let committer = CIDIdentity.canonicalString(report.blockHash),
              report.grinds.contains(where: { workContribution(id: $0, at: hash) != nil }),
              let attributedID = AttributedRunIdentity(
                  committerBlockHash: committer, directory: directory
              ).contributionID else {
            return .notCommitterOfChild
        }
        guard forkChoice.acceptsLocation(of: attributedID, at: hash) else { return .locationConflict }
        guard let derived = report.runWork.subtracting(report.ownWork) else {
            return .malformedReport
        }
        guard let derivedWork = derived.uint256Value else {
            return .unrepresentable(derived: derived)
        }
        let existing = workContribution(id: attributedID, at: hash)?.work ?? .zero
        guard derivedWork > existing else {
            return .notStronger(existing: WorkSum(existing), derived: derived)
        }
        return .strengthened(BlockImportBatch(facts: [
            .work(ChainWorkFact(
                blockHash: hash,
                contribution: VerifiedWorkContribution(id: attributedID, work: derivedWork),
                attributedRun: AttributedRunIdentity(
                    committerBlockHash: committer, directory: directory
                )
            )),
        ]))
    }

    /// The commitments recorded for a possessed block, or nil when the block
    /// is unknown or its fact predates the field (§9.10).
    public func recordedChildCommitments(of blockHash: String) -> [String: String]? {
        CIDIdentity.canonicalString(blockHash).flatMap { graph[$0]?.childCommitments }
    }
}
