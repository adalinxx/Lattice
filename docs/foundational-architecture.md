# Lattice Architecture

This document explains who decides, who stores, and how facts cross process
boundaries. The [protocol specification](spec.md) is normative. The work algebra
and fork-choice rationale live in
[consensus-fork-choice.md](consensus-fork-choice.md).

## Mental Model

A mined root and a running chain are different things.

```text
mined root R -> nested CID paths -> candidates for many chains

process Nexus          -> validates and chooses Nexus
process Nexus/Payments -> validates and chooses Nexus/Payments
node                   -> authenticates, routes, persists, and retains
```

Think of `R` as a content-addressed envelope containing sparse routes to many
chain candidates. The node delivers one route and its authenticated supporting
facts to the process responsible for that path. Lattice verifies the evidence,
updates only that path's accepted forest, and returns only that path's canonical
delta.

The content graph may recurse to arbitrary depth. A Lattice runtime never does.

## Manifesto

1. **One process, one chain.** One runtime owns one absolute path, one accepted
   forest, and one canonical projection.
2. **The hierarchy is data.** Content commitments connect chains; runtimes do not
   recursively contain other runtimes.
3. **Each child decides.** Parent evidence may prove facts, but cannot validate a
   child or choose its tip.
4. **One grind, one quantity.** Coverage may grow without multiplying physical
   work.
5. **Work is not canonicity.** Accepted parent work may matter; the parent's
   preferred pointer does not.
6. **State is not ancestry.** `parentState` commits the carrier's `prevState`; it
   is not a parent-block backlink.
7. **The node owns operations.** Acquisition, process authentication, durability,
   retention, pinning, routing, and projections are node policy.
8. **Durability precedes visibility.** The staged immutable batch is the record
   applied by both live admission and recovery.

## Runtime Boundary

An absolute path such as `Nexus/Payments` is the chain identity. A child genesis
CID is one root in that path's accepted forest, not a new runtime identity.
Competing parent histories may introduce competing child roots; the child process
chooses among them with its own fork choice.

Each process owns:

```text
ChainLevel
|- ChainRuntimeContext  absolute path + setup-wide minimum root work
`- ChainState           accepted same-chain forest + canonical projection
```

`ChainLevel` contains no child runtimes. Lattice has no cross-chain
reorganization call and no multi-chain fork-choice loop.

## Evidence Boundary

A child candidate arrives with a sparse proof from one mined root to that exact
candidate. Lattice first verifies the setup-wide root-work floor, then the path,
carrier continuity, vertical state bindings, and this chain's transition.

At a vertical edge, the nested child commits the carrier's `prevState` as
`parentState`. It does not commit the carrier CID. Therefore:

- same-chain predecessors are explicit block links and missing predecessors are
  derived as holes in the accepted graph;
- cross-chain acquisition asks the authenticated parent process for a proof or
  parent-issued continuity fact;
- Lattice never tries to invert `parentState` into a parent block.

A parent may export rolled-up accepted work, including eligible noncanonical
branches, through the immediate-parent provider. That work may change a child's
weight. A parent canonical-pointer change by itself may not. See
[Work and fork choice](consensus-fork-choice.md) for the exact model.

## Admission And Recovery

Every external candidate follows one boundary:

```text
acquire
  -> verify
  -> targeted store
  -> atomically stage one immutable batch
  -> apply that exact batch
  -> project one chain
```

The node's stage callback is atomic: returning means the whole batch is durable;
throwing means none of its facts became visible. An existing runtime reserves one
commit revision before staging so another actor mutation cannot consume the last
available revision while the batch is becoming durable.

Live admission does not reacquire or rebuild a candidate after staging. Recovery
replays already-authenticated staged batches through the same reducer. Replaying
an identical batch is a no-op; conflicting immutable metadata fails closed.
Root and child bootstrap expose no runtime until the genesis batch has been
stored, staged, and restored.

A target miss returns a carrier result. It creates no local consensus fact,
executes no local transition, and causes no implicit Lattice retention. The node
may retain the carrier or an exact child path when its availability policy calls
for it.

## Ownership

| Component | Owns |
|---|---|
| Lattice | Validation, deterministic state transitions, accepted graph, work algebra, fork choice, securing-work export, `ChainCommit` |
| lattice-node | Acquisition, process authentication and supervision, atomic fact durability, inherited-work routing, retention, pin counts, projections, RPC |
| cashew | Generic content-addressed structures and matching targeted resolve/store traversal |
| VolumeBroker | Complete selected Volumes, node-selected pinning, and eviction |
| Ivy | Transport, discovery, authenticated sessions, and delivery attribution |
| Tally | Provider observations and policy, never protocol validity |

Storage presence is not validity. Peer identity is not validity. Authenticating a
parent process establishes who may speak for that parent path, not which child
branch must win.

Nested Volumes remain independent availability units. Storing or pinning an outer
Volume creates no implicit retention relationship with another Volume merely
referenced by CID.

## Retention

Lattice retains the complete accepted consensus graph and verified local grind
coverage. It does not prune consensus inputs according to a node storage budget.

The node decides how long to retain block bodies, materialized state,
`StateDiff` payloads, inherited-work caches, and CAS pins. `StateDiff` is local
lifecycle metadata carried by the durable block fact; it is not committed in a
block or stored in `BlockMeta`.

## Review Contract

A change preserves the architecture only if all of these remain true:

1. One process owns one path and never recursively runs another chain.
2. The root-work floor is checked before child resolution.
3. Every carrier proves same-chain continuity, even on a target miss.
4. Work is joined by grind identity before quantities are totaled.
5. Accepted parent work may affect child weight; parent canonicity alone may not.
6. Fork choice compares effective `trueCumWork`, then segment-base CID.
7. External ingress uses one admission boundary; recovery replays durable facts.
8. Durable facts precede visible mutation.
9. Lattice retains consensus inputs; the node owns payload retention.
10. Cross-chain interfaces carry evidence and work, never canonical-tip commands.
