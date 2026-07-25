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

Parent canonicity, carrier validity, arrival order, and segment-tip target are
not inputs.

## From A Root To A Candidate

Let `R` be the mined root and `C` the candidate for this chain. A
`ChildBlockProof` supplies the exact sparse path from `R` to `C`.

Work verification:

1. recomputes `CID(R)` and the proof-of-work hash;
2. verifies the sparse path and requires its terminal CID to equal `CID(C)`;
3. verifies every vertical `child.parentState == carrier.prevState` binding;
4. checks the same hash against the terminal target; and
5. derives the strongest target-derived quantity that hash earns along the
   committed directory path.

A carrier may fail its own chain's target or validity rules and still prove real
work for the terminal child. The work affects fork choice only after `C` is
independently accepted and connected.

## Parent-State Continuity

For a non-genesis candidate `C` with same-chain predecessor `P`, define:

```text
old = P.parentState
new = C.parentState
```

Continuity holds when `old == new`, or when the immediate parent's connected
accepted graph contains a transitive state path from `old` to `new`. Direct
adjacency is not required. A noncanonical parent branch may prove the fact;
backward, sideways, unrelated, and disconnected movement cannot.

This reachability fact is distinct from the directory proof. The configured
immediate parent authenticates the exact parent path and state pair, but it
asserts no work and commands no child fork choice.

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
                      union each effectiveSubtree(C)
                            for C in sameChainChildren(B)

trueCumWork(B) = total(effectiveSubtree(B))
```

Fork choice starts at an accepted height-zero root and repeatedly chooses the
child segment base with greatest `trueCumWork`. An exact tie selects the smaller
canonical CID bytes.

Holding the incumbent on an exact tie is deliberately not part of consensus.
It would make the result depend on arrival order or on a persisted canonical
cache, so peers with the same facts—and the same peer before and after
recovery—could select different tips. A miner can grind the deterministic CID
tie-break after matching the incumbent's work, but the tie-break contributes no
weight and any strictly heavier branch still wins.

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

Persistence records the accepted graph, proof-derived work locations, and
authenticated parent-state facts. Recovery replays the same immutable facts and
rebuilds segment caches. A persisted canonical tip is only a cache.
