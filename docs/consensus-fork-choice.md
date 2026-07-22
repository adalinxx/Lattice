# Hierarchical Work And Fork Choice

[Specification section 9](spec.md#9-consensus) is normative. This document
explains the model operationally.

## The Rule

A physical grind has one identity, one quantity, and exactly one terminal
location in each chain it reaches:

```text
identity = CID(root)
quantity = strongest verified accepted-target bound
location = exact terminal block in this chain
```

One block may contain many independent grinds. One grind cannot be placed at
two blocks in the same chain. Ordinary same-chain ancestry makes work at a
descendant support that descendant's ancestors; the grind is not copied to
those ancestors.

Fork choice asks one local question:

> Which competing same-chain subtree contains the greatest total quantity of
> uniquely located grinds?

Parent canonicity, arrival order, segment-tip target, and unrelated parent work
are not inputs.

## From A Root To A Candidate

Let `R` be the mined root and `C` the candidate for this chain. A
`ChildBlockProof` supplies the exact sparse path from `R` to `C`.

Validation:

1. recomputes `CID(R)` and the proof-of-work hash;
2. applies the setup-wide minimum root-work floor;
3. verifies the sparse path and requires its terminal CID to equal `CID(C)`;
4. verifies immediate-parent continuity and every vertical
   `child.parentState == carrier.prevState` binding;
5. checks the same hash against this level's target; and
6. executes and admits `C` only when this chain's target accepts the grind.

A target miss at one level does not invalidate deeper candidates. It means only
that the missed level creates no block or work location for that grind.

## Direct Parent Inheritance

The immediate parent publishes a child-independent relation:

```text
(parent block, grind, quantity)
```

It includes connected accepted blocks from canonical and noncanonical branches.
It contains no child topology and no canonical pointer. The parent receives no
child data.

The child owns verified direct edges:

```text
parent block -> child block
```

It joins the two relations on the exact parent block:

```text
(P, grind, quantity) + (P -> C) = (C, grind, quantity)
```

Parent ancestry creates no implicit child location. If `P0 -> C` is known and a
later parent block `P1` contains another grind but no direct commitment to a
child block, the second grind does not secure `C`.

This transformation is recursive. A middle chain first projects its parent's
facts onto its own blocks, unions them with distinct local grinds at those same
locations, and publishes the resulting child-independent relation to its child.
Each process therefore knows only its own accepted graph, one immediate-parent
view, and its own incoming direct edges.

## Exact Work Algebra

`WorkMeasure` is a map from grind identity to quantity:

```text
(A union B)[id] = max(A[id], B[id])
total(A)        = exactSum(A.values)
```

Union is associative, commutative, and idempotent. It combines duplicate
observations of the same grind at the same location and prevents recursive
inheritance from counting the same physical work twice. A snapshot that places
one identity at different blocks in the same chain is invalid and is rejected
atomically.

Snapshots join monotonically. New unique facts and stronger quantities at the
same location may be added; facts cannot be retracted or moved. Revision is a
progress watermark, so an older or equal revision may still carry a previously
unseen monotonic fact.

## GHOST

For a connected same-chain block `B`:

```text
effectiveSubtree(B) = own(B)
                      union inherited(B)
                      union each effectiveSubtree(C)
                            for C in sameChainChildren(B)

trueCumWork(B) = total(effectiveSubtree(B))
```

Fork choice starts at an accepted height-zero root and repeatedly chooses the
child segment base with greatest `trueCumWork`. An exact tie selects the smaller
canonical CID bytes.

Canonicity is an output of this descent, never a filter on work. Consequently a
grind on a connected noncanonical branch remains eligible, and moving only a
canonical pointer cannot change any weight.

The implementation compresses maximal unary runs into segments. A newly
accepted work location updates only the segment containing it and the ancestor
fork segments that can compare it. The common tip-extension case has one such
segment, so it does not scan chain history. Cost grows with fork depth, not
linear-chain height. The immutable block graph and unique grind locations remain
the source of truth; segment weights are rebuildable caches.

## Connectivity And Recovery

Only a block connected through validated same-chain predecessor edges to an
accepted height-zero root participates in GHOST or parent export. A disconnected
accepted block retains its authenticated fact but has no route until its missing
predecessor attaches.

Persistence records the accepted graph, local work locations, the retained
immediate-parent facts, direct incoming edges, and the revision floor. Recovery
replays the same immutable facts and rebuilds segment caches. A persisted
canonical tip is only a cache. A revision watermark without its facts fails
closed because absence cannot mean zero work.
