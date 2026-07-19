# Hierarchical Work And Fork Choice

This document explains how one physical grind can secure many blocks without
being counted many times. [Specification section 9](spec.md#9-consensus) is
normative; [Architecture](foundational-architecture.md) defines the process and
node boundary.

## The Question

Fork choice asks one local question:

> Which competing same-chain subtree has the greatest `trueCumWork`, after
> observations are joined by grind identity?

It does not ask which parent branch is canonical. It does not compare segment
tips. It does not multiply one grind because that grind covers more content.

## From One Root To One Candidate

Let `R` be the mined root, `h = proofOfWorkHash(R)`, and `C` the candidate for
this chain process. A `ChildBlockProof` supplies the exact sparse path from `R`
to `C`.

Verification proceeds from cheap, global checks to chain-local work:

1. recompute `CID(R)` and `h`;
2. require `workForHash(h) >= minimumRootWork` before resolving child content;
3. consume the exact sparse path and require its terminal CID to equal `CID(C)`;
4. verify the immediate parent's root-bound carrier link, which inductively
   proves the upstream carrier path, and every vertical
   `child.parentState == carrier.prevState` binding;
5. compare the same hash `h` with each level's target;
6. execute and admit `C` only if this chain's target accepts the grind.

The setup-wide floor rejects inadequate work for the entire package. A target
miss is narrower:

```text
h <= target(level)  -> this level accepts the grind
h >  target(level)  -> carrier only; descendants may still accept
```

A carrier still has to prove continuity. A level that misses does not execute a
transition or create a local work fact.

Carrier-link derivation is header-only. If an intermediate level's target hits
but its local transition fails, that rejection remains visible while the same
candidate may still carry the grind to a descendant.

## Grind Identity, Quantity, And Coverage

A verified root grind has three independent properties:

```text
identity = CID(R)
quantity = strongest verified workForTarget among accepting levels
coverage = blocks proven secured by R
```

Identity never changes. Quantity may strengthen. Coverage may grow. A single
grind may cover arbitrary content and any number of blocks; it still contributes
one quantity.

`WorkMeasure` is a set-like map from grind ID to quantity:

```text
(A union B)[id] = max(A[id], B[id])
total(A)        = exactSum(A.values)
```

Union is associative, commutative, and idempotent. Therefore repeated coverage
does not create work, shared work is neutral across a fork, and independent
grinds sum exactly. The exact sum uses `WorkSum`; it cannot wrap or saturate away
an ordering.

## Worked Fork

Suppose one chain has competing segment bases `A` and `B`:

```text
        G
       / \
      A   B
```

The accepted coverage is:

| Grind | Quantity | Covers |
|---|---:|---|
| `shared` | 10 | `A`, `B` |
| `local-A` | 4 | `A` |
| `local-B` | 3 | `B` |
| `parent-B` | 2 | `B` |

`parent-B` came from a connected, accepted parent branch. That source branch may
be noncanonical; acceptance and coverage matter, not the parent's preferred
pointer.

```text
measure(A) = {shared: 10, local-A: 4}               -> 14
measure(B) = {shared: 10, local-B: 3, parent-B: 2} -> 15
```

`B` wins. `shared` contributes once to each comparison and is neutral between
the branches.

Now suppose another proof verifies `shared` at quantity 12, but that observation
arrives through only one branch. Lattice first normalizes the strongest known
quantity for that identity across all existing coverage:

```text
measure(A) = {shared: 12, local-A: 4}               -> 16
measure(B) = {shared: 12, local-B: 3, parent-B: 2} -> 17
```

The stronger observation benefits both covered branches and does not create a
false preference for the branch where it arrived.

If the totals tie exactly, Lattice compares the canonical CID bytes of `A` and
`B` and chooses the smaller. These are the segment bases. Their descendant tips,
their `nextTarget` values, arrival order, and the parent's canonical pointer are
not tie-break inputs.

## Inherited Work

For each covered child block, the immediate parent exports only connected,
accepted work whose validated binding covers that child. Eligible work may come
from noncanonical parent branches; unrelated parent work is excluded. The node
authenticates and routes that parent process and supplies a coherent
`InheritedWorkSnapshot`.

The child does not retain every ancestor graph. Each parent snapshot already
contains transitive securing work, deduplicated by root CID.

Snapshots join monotonically:

- new coverage may be added;
- a quantity for one grind may strengthen;
- no later snapshot may delete or weaken a retained fact;
- an unknown or disconnected parent block is unavailable, not zero work.

A snapshot revision is a source-progress watermark, not a hash of its contents.
An older or equal revision may still reveal valid coverage and must still join.

Parent work and parent canonicity are orthogonal. New accepted work may change a
child's fork choice. Moving only the parent's canonical pointer may not.

## GHOST Projection

For a same-chain block `B`:

```text
prefix(B) = own(B) union prefix(parent(B))

effectiveSubtree(B) = own(B)
                      union inherited(B)
                      union each effectiveSubtree(C)
                            for C in sameChainChildren(B)

cumulativeWork(B) = total(prefix(B))
trueCumWork(B)     = total(effectiveSubtree(B))
```

Fork choice captures one inherited snapshot and performs GHOST descent:

1. choose the accepted genesis root with greatest `trueCumWork`;
2. at each fork choose the child segment base with greatest `trueCumWork`;
3. on an exact tie choose the lexicographically smaller canonical base CID.

The deterministic tie makes arrival and replay order irrelevant. Its grindable
security tradeoff is quantified in the
[TRE-134 adversarial report](consensus/tre-134-adversarial-report.md).

## Admission And Persistence

Admission stores targeted verified content, atomically stages one immutable
`ChainAdmissionBatch`, then applies that exact batch to the graph. Work facts
are logically keyed by `(blockHash, grindID)`: weaker or equal replays are no-ops,
while a stronger verified observation remains durable.

Persistence records the accepted local graph, local grind coverage, the retained
inherited snapshot, and the revision floor. Recovery replays already-authenticated
batches through the same reducer and reprojects the chain. A persisted tip is a
cache, not protocol truth. A revision marker without the inherited snapshot fails
closed because absence cannot be interpreted as zero work.
