# Architecture Alignment in This PR

## Single-Chain Runtime

`ChainLevel` is the public Lattice admission boundary for exactly one absolute
chain path. Its immutable `ChainRuntimeContext` contains that path and the
setup-wide minimum root-work floor. A `ChainLevel` owns one `ChainState`; it has
no child map, recursive dispatch, or cross-chain reorganization commands.

`ChainLevel.bootstrap` creates a standalone runtime through the same verified,
durable admission boundary used for later candidates. The removed
`bootstrapChild` and raw-block bootstrap paths have no replacement inside
Lattice. `lattice-node` owns process topology and starts one Lattice process for
each chain it chooses to follow.

## Admission

`admitBlockHeaderChainLocal`:

1. resolves only the targeted block and validation data;
2. verifies the root CID and setup-wide minimum root-work floor;
3. verifies the exact sparse root-to-candidate path;
4. binds every carrier to a continuity fact issued by the responsible parent
   process, and binds child genesis to its parent-issued genesis fact;
5. compares the same root hash with this chain's target;
6. executes this chain's state transition when accepted at this level;
7. stores verified block content and materialized state before visible mutation;
8. calls the node's durable staging callback; and
9. commits the contribution and block to `ChainState` if the prepared generation
   is still current.

A failed setup floor rejects the whole nested tree. A target miss at this level
returns a carrier result; it does not reject descendants. A competing valid
branch remains valid even when it does not become canonical.

All acquisition modes, including gossip and sync, use this API. Lattice no longer
contains `ChainSyncer`, direct reset/replacement, transport-triggered backfill, or
another trusted ingress route.

## Work Facts

The first target-accepting boundary on the root-to-leaf path fixes the grind's
contribution amount. Deeper levels carry the same immutable fact. The root CID is
the contribution identity, so one physical grind is counted once and conflicting
reuse is rejected.

These facts are immutable. Parent or sibling processes may provide their proof
bytes, but their current tips and canonicality are not inputs to this chain's
fork choice. There is no live inherited-weight provider or parent anchor map.

## Cross-Process Facts

`ParentContinuityLink` records that the process for one path validated a
carrier's same-chain predecessor continuity. `ParentGenesisLink` records that a
validated parent state anchored one child genesis CID. The node authenticates,
transports, and caches these values; Lattice produces and consumes their
consensus meaning. Once validated, neither fact depends on parent canonicity or
continued parent availability.

## Storage and Lifecycle

Cashew resolve and store operations use matching targeted paths. Each nested
`Volume` remains an independent content-addressed storage unit; storing an outer
Volume creates no ownership or retention relationship with a referenced nested
Volume.

Validation derives `StateDiff` locally. It is lifecycle metadata on `BlockMeta`
and `ChainAdmissionRecord`, not block-committed data. Lattice reports admitted
and evicted metadata; the node owns filesystem persistence, CID reference counts,
pinning, retention, archival, and garbage collection.

Retention never gates GHOST. A reorganization names its new tip, exact canonical
changes, and any newly canonical blocks whose transition metadata is absent so
the node can satisfy acquisition without becoming a consensus authority.

## Responsibility Boundary

Lattice owns validity, execution, contribution derivation, the accepted graph,
GHOST fork choice, and chain-local reorganization. The node owns acquisition,
durable orchestration, retention, projections, and multi-process topology.

The concise rule is:

> Acquire bytes, verify one chain, persist evidence, then mutate one chain.
