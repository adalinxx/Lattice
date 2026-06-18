import UInt256

// MARK: - Inherited Weight (F5-4 cross-chain securing term)

/// F5-4 (Hierarchical GHOST): supplies a block's **inherited** cross-chain weight
/// — the securing parent's `trueCumWork` (design §6.2) — *fresh* at fork-choice
/// time, and memoizes it per fork-choice decision. Extracted from `ChainState` so
/// the provider closure and its per-decision memo live behind one narrow API
/// (`effectiveWeight`/`clearMemo`) instead of as loose actor fields.
///
/// The node installs the provider; it resolves the block's anchor on the parent
/// chain and returns the parent's current `trueCumWork(P)`. It is **derived, never
/// cached on the block** (§6.1), so it can't go stale as the parent chain extends
/// — fork choice asks for the live value each time. nil (the default, and the root
/// chain) ⇒ no inherited weight.
///
/// **Contract:** the provider must be a *pure read* of the parent chain's current
/// state — deterministic and stable for the duration of one fork-choice decision
/// (it is queried many times per decision: the fork base, the main sibling, and
/// every candidate on a GHOST descent). It may return different values *across*
/// decisions as the parent chain extends; that is the intended liveness.
/// `effectiveWeight` memoizes its result per decision so a single decision is
/// internally consistent even if the underlying value is in flux.
struct InheritedWeightProvider {
    private var provider: (@Sendable (String) -> UInt256)?

    /// Per-decision memo of inherited terms, so each block's `inherited(P)` is
    /// fetched at most once per fork-choice decision (consistency + fewer provider
    /// calls on multi-hop descents). Cleared at every top-level fork-choice entry
    /// so it never carries a stale value across decisions — the value is still
    /// *derived fresh*, just not re-derived mid-decision.
    private var memo: [String: UInt256] = [:]

    init(provider: (@Sendable (String) -> UInt256)? = nil) {
        self.provider = provider
    }

    mutating func setProvider(_ provider: (@Sendable (String) -> UInt256)?) {
        self.provider = provider
    }

    /// The fork-choice weight of a block: `trueCumWork = subtreeWeight (own chain)
    /// + inherited parent weight`. The inherited term is fetched live from the
    /// provider (0 for the root chain / when no provider) and memoized per
    /// decision. This is the single metric GHOST compares — own-chain descendant
    /// subtree plus the security riding down the lattice.
    mutating func effectiveWeight(subtreeWeight: UInt256, blockHash: String) -> UInt256 {
        let inherited: UInt256
        if let memoed = memo[blockHash] {
            inherited = memoed
        } else {
            inherited = provider?(blockHash) ?? .zero
            memo[blockHash] = inherited
        }
        return saturatingWorkSum(subtreeWeight, inherited)
    }

    /// Drop the per-decision inherited-weight memo. Called at the top of every
    /// top-level fork-choice entry so each decision re-derives fresh values.
    mutating func clearMemo() { memo.removeAll(keepingCapacity: true) }
}

// MARK: - Retention Policy

/// Holds this node's per-chain retention depth and the prune arithmetic that
/// depends on it. Extracted from `ChainState` so the "how deep do we retain"
/// policy is one cohesive value type rather than a loose field plus open-coded
/// arithmetic at every call site.
///
/// There is NO finality floor: fork choice is pure heaviest-`trueCumWork`, so a
/// strictly-heavier valid fork is always followed regardless of how deep the
/// reorg is. Retention is a storage/pruning bound only (depth ≠ validity); it
/// never refuses a reorg (SEC-101 /.
struct RetentionFinalityPolicy {
    var retentionDepth: UInt64

    init(retentionDepth: UInt64) {
        self.retentionDepth = retentionDepth
    }

    /// The half-open range of block heights that become prunable when the tip
    /// advances from `oldHighest` to `newHighest`, given `retentionDepth`. Returns
    /// `nil` when nothing crosses the retention cutoff (including the no-retention
    /// `UInt64.max` default, where neither side exceeds the depth). Mirrors the
    /// guard that previously lived inline in `setNewTip`/`advanceTip`.
    func newlyPrunableRange(oldHighest: UInt64, newHighest: UInt64) -> Range<UInt64>? {
        guard oldHighest > retentionDepth && newHighest > retentionDepth else { return nil }
        let oldCutoff = oldHighest - retentionDepth
        let newCutoff = newHighest - retentionDepth
        guard newCutoff > oldCutoff else { return nil }
        return oldCutoff..<newCutoff
    }
}
