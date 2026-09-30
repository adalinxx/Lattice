import LatticePrimitives
import LatticePoW

/// The reads and the one write the admission tier (`LatticeImport`) needs
/// from a `ChainTree`. Every one is a view onto the existing value structs.
extension ChainTree {
    /// Whether some block of this chain's executed set produced `stateCID`:
    /// a block on ANY branch, executed from genesis and not under an excluded
    /// root, whose post-state is `stateCID`. This is what a child's
    /// `parentState` must be (parent-chain continuity), and it is not a tip
    /// question: a side branch this chain executed counts the same.
    public func executedSetProduced(stateCID: String) -> Bool {
        guard let canonical = CIDIdentity.canonicalString(stateCID) else {
            return false
        }
        return frontier.chainProduced(stateCID: canonical)
    }

    /// Whether `blockHash` is a proven-invalid subtree root. Its work still
    /// weighs; the fork-choice descent never steps into it.
    public func isExcludedRoot(_ blockHash: String) -> Bool {
        forkChoice.excludedRoots.contains(blockHash)
    }

    /// The recorded header fields of a held block (post/prev state, spec,
    /// target, next target, height, timestamp): what header linkage reads for
    /// a parent.
    public func headerSnapshot(of blockHash: String) -> TipBlockSnapshot? {
        frontier.snapshot(of: blockHash)
    }

    /// The parent CID a held block names, held or not.
    package func parentHash(of blockHash: String) -> String? {
        graph.parent(of: blockHash)
    }

    /// Whether the grind `id` may be credited at `blockHash`: a grind has one
    /// location in a chain.
    package func acceptsWorkLocation(of id: String, at blockHash: String) -> Bool {
        forkChoice.acceptsLocation(of: id, at: blockHash)
    }

    /// The block's strongest own grind (ties to the smaller ID) — never an
    /// attributed run.
    package func strongestGrind(of blockHash: String) -> VerifiedWorkContribution? {
        guard let work = graph.work(of: blockHash) else { return nil }
        return work.contributions.values
            .filter { !work.attributedRuns.contains($0.id) }
            .max {
                $0.work != $1.work ? $0.work < $1.work : $0.id > $1.id
            }
    }

    /// Apply one locally authenticated admission batch through the single
    /// fact reducer that live admission and replay share.
    package mutating func apply(_ batch: BlockImportBatch) throws -> SubmissionResult? {
        try applyStaged(batch)
    }
}
