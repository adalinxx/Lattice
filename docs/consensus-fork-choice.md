# Hierarchical Work And Fork Choice

This document explains the model. [Specification section 9](spec.md#9-consensus)
is normative; [foundational-architecture.md](foundational-architecture.md) defines
the Lattice/node boundary.

## Three Structures

Lattice keeps three ideas separate:

1. The **content DAG** under one mined root commits blocks and data across chain
   paths.
2. The **same-chain forest** contains every accepted root, block, and fork for one
   absolute path.
3. The **process graph** is node-owned. One Lattice process handles one path and
   talks only to an authenticated immediate-parent provider.

The content DAG may be recursive. The Lattice runtime is not.

## Verifying A Root Grind

Let `R` be the outer root, `h = proofOfWorkHash(R)`, and `C` the candidate for
this process. A `ChildBlockProof` supplies the exact sparse path from `R` to `C`.
Verification proceeds in this order:

1. Recompute the root CID and hash.
2. Require `workForHash(h) >= minimumRootWork` before resolving child content.
3. Resolve the targeted path and require its terminal CID to be `C`.
4. Verify same-chain continuity for every carrier above `C`.
5. Verify every vertical `parentState` binding.
6. Compare the same root hash `h` with each level's target.

Failure of the setup-wide floor rejects the whole nested tree. A target miss has
narrower meaning:

```text
h <= target(level)  -> this level accepts the grind
h >  target(level)  -> carrier only; descendants may still accept
```

Carrier continuity remains mandatory. Acceptance-only execution, time, and
retarget rules do not leak from one chain process into descendant validity.

## Work Is A Set, Not A Scalar

One physical grind has:

```text
identity = CID(R)
quantity = max(workForTarget(B) for every verified accepting level B)
coverage = every block proven secured by R
```

Identity is immutable. Quantity only strengthens. Coverage only grows. One grind
may cover any amount of content or any number of blocks, while several distinct
grinds may cover the same route. The latter is valid but usually wasteful.

`WorkMeasure` is a map from grind ID to quantity:

```text
(A union B)[id] = max(A[id], B[id])
total(A)        = exactSum(A.values)
```

Union is associative, commutative, and idempotent. Consequently:

- repeated coverage never multiplies work;
- a shared grind on both sides of a fork is neutral;
- local and inherited observations of one grind count once;
- independent grinds sum exactly, without `UInt256` saturation.

Admission stages immutable `ChainWorkFact(blockHash, contribution)` observations
identified by `(blockHash, grindID, work)`. Their logical coverage key omits the
work value. A weaker or equal replay is a no-op; a stronger observation remains
separately durable and updates that grind across every covered block without
re-executing a state transition.

## Live Inherited Work

The immediate parent exports securing measures from its complete accepted graph,
including noncanonical branches. The node authenticates and routes that process,
derives child-block bindings from validated content-addressed paths, and supplies
a coherent revisioned `InheritedWorkSnapshot`. An export naming an unknown parent
block is unavailable, not zero work.

Lattice captures one snapshot per decision and unions it with the retained view.
Revision combines by maximum. An older or equal revision may still add previously
unseen valid coverage, but no stale, partial, or missing snapshot can delete or
weaken work. Each snapshot is already rolled up by the immediate parent, so the
child does not retain every ancestor graph.

Revision is a source-progress watermark rather than a hash of snapshot contents:
the node may discover another valid content binding without a parent mutation.

Before comparing branches, Lattice finds the strongest known quantity for every
grind across both local and inherited inputs and applies it to all coverage of
that identity. A harder observation on one branch therefore cannot make shared
work favor that branch.

Parent work and parent canonicity are orthogonal. More accepted parent work may
change child fork choice. Changing only the parent's canonical pointer may not.

## GHOST Projection

For a block `B`:

```text
prefix(B) = own(B) union prefix(parent(B))

effectiveSubtree(B) = own(B)
                      union inherited(B)
                      union each effectiveSubtree(C)
                            for C in sameChainChildren(B)

cumulativeWork(B) = total(prefix(B))
trueCumWork(B)     = total(effectiveSubtree(B))
```

`BlockMeta` caches local-only prefix and subtree totals. Fork choice captures one
inherited snapshot, constructs effective measures, then performs GHOST descent:

1. choose the root with greatest `trueCumWork`;
2. at each fork choose the child segment base with greatest `trueCumWork`;
3. on an exact tie choose the lexicographically smaller canonical CID of the two
   segment bases.

`nextTarget` and segment tips are not tie-break inputs. Comparing segment bases,
not tips, makes the result independent of arrival, staging, and replay order.

## Persistence

External candidates use `ChainLevel.admitBlockHeaderChainLocal`. Recovery replays
only previously authenticated durable facts through the same graph mutation and
fork-choice code.

Persistence stores the accepted local graph, all grind coverage, and the retained
inherited snapshot used by the decision. A node may omit that cache only if it can
provide a complete live view at least as new during restore; absence is not zero
work. The canonical tip remains a derived cache. Restore validates and rebuilds
the graph, unions cached and live inherited facts, and reprojects the preferred
branch. The node rebuilds its retained projections from that result.
