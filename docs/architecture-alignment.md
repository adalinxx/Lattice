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

1. captures one explicit validation-time context for the whole attempt,
   including generation-checked retries;
2. verifies the supplied root CID and setup-wide minimum root-work floor before
   resolving child content;
3. resolves only the targeted candidate and validation data;
4. verifies the exact sparse root-to-candidate path;
5. binds every carrier to a continuity fact issued by the responsible parent
   process, and binds child genesis to its parent-issued genesis fact;
6. compares the same root hash with this chain's target;
7. executes this chain's state transition when accepted at this level;
8. stores verified block content and materialized state before visible mutation;
9. atomically stages an immutable `ChainAdmissionBatch` of typed block/work facts
   through the node; and
10. commits to `ChainState` if the prepared generation is still current, returning
    a revisioned `ChainCommit`.

A failed setup floor rejects the whole nested tree. A target miss at this level
returns a carrier result; it does not reject descendants. A competing valid
branch remains valid even when it does not become canonical.

All acquisition modes, including gossip and sync, use this API. Lattice no longer
contains `ChainSyncer`, direct reset/replacement, transport-triggered backfill, or
another trusted ingress route.

## Work Facts

The first target-accepting boundary on the root-to-leaf path fixes the grind's
contribution amount. Deeper levels carry the same immutable fact. Each distinct
root CID is a grind identity and is staged as its own `ChainWorkFact`, including
additional grinds later attached to an existing block. Replay is idempotent and
conflicting reuse is rejected.

These facts are immutable. Parent or sibling processes may provide their proof
bytes, but their current tips and canonicality are not inputs to this chain's
fork choice. There is no live inherited-weight provider or parent anchor map.

Fork choice compares competing segment bases by `trueCumWork`, then by canonical
CID bytes only. The lexicographically smaller CID wins an exact tie;
`nextTarget` and segment tips are not comparators.

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

Validation derives `StateDiff` locally and carries it once in the immutable
`ChainBlockFact`; it is neither block-committed nor retained in `BlockMeta`.
The node owns filesystem persistence, CID reference counts, pinning, state
retention, archival, garbage collection, and projections. After atomically
staging the fact, the node may compact its lifecycle payload once it has
preserved restart-equivalent consensus data. If a crash happens before the
actor mutation, the node replays its authenticated staged batches through
Lattice's `ChainState.restore(..., replaying:)`; it does not reconstruct fork
choice itself.

Lattice retains the complete accepted consensus graph and every verified work
contribution. It does not prune that graph according to node retention policy.

## Responsibility Boundary

Lattice owns protocol validity (including execution and contribution derivation),
the accepted graph, GHOST fork choice, and chain-local reorganization. It emits
revisioned `ChainCommit` values so the node can apply concurrent results in
consensus order. The node owns acquisition, atomic fact durability, state
retention and pinning, projections, recovery, and multi-process topology.

The concise rule is:

> Acquire bytes, verify one chain, persist evidence, then mutate one chain.
