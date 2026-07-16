# Lattice Architecture

This document defines component and process boundaries. The protocol rules are
normative in [the specification](spec.md), especially [section 9](spec.md#9-consensus).
Fork-choice rationale lives in
[consensus-fork-choice.md](consensus-fork-choice.md).

## Manifesto

1. **The hierarchy is data, not a runtime tree.** One process owns one absolute
   chain path and one `ChainState`. The node supervises additional paths.
2. **Evidence crosses chain boundaries; authority does not.** A parent can prove
   continuity and export accepted work. It cannot select a child tip.
3. **Validity is monotone; canonicity is derived.** A valid side block stays
   valid. The preferred branch may change as accepted evidence grows.
4. **Work and canonicity are orthogonal.** Parent accepted work can secure a
   child. The parent's canonical pointer has no special weight.
5. **One physical grind counts once.** The same grind may secure any amount of
   data or any number of blocks. Coverage does not multiply work.
6. **Operational policy belongs to the node.** Storage budgets, state retention,
   pins, peers, process authentication, and projections are not consensus rules.

The short version is:

> Verify evidence, count identities, choose one chain.

## Runtime Model

An absolute path such as `Nexus/Payments` is the chain identity. A child genesis
CID is a root in that path's accepted forest, not a second identity. Competing
parent histories may introduce competing child roots; the child process chooses
among them with its own fork choice.

The nested content DAG and the runtime topology are intentionally different:

```text
one mined root -> content-addressed paths -> blocks on many chains

one Lattice process -> one path -> one accepted forest and canonical projection
```

There is no recursive child runtime, cross-chain reorganization call, or
multi-chain fork-choice loop inside Lattice.

## Work Model

The root CID identifies one physical grind. Verification separates three facts:

- **identity:** the immutable root CID;
- **quantity:** the strongest verified accepted-target work for that identity;
- **coverage:** the append-only set of blocks secured by that identity.

`WorkMeasure` maps grind IDs to quantities. Union takes the maximum quantity per
ID; only then does `total` sum the distinct values. This is associative,
commutative, and idempotent. It gives the protocol its central law:

```text
one grind + any coverage = one credited quantity
distinct grinds          = exact sum
```

Several independent grinds may occur on one route, but that is normally
economically suboptimal. Correctness supports it without optimizing for it.

## Inherited Work

Each chain exports securing measures from its complete accepted graph, including
noncanonical branches. A child consumes one rolled-up snapshot from its immediate
parent, so it does not track every ancestor process.

The node authenticates and routes the parent process, resolves the
content-addressed bindings, and caches a revisioned `InheritedWorkSnapshot`.
Lattice captures one snapshot per fork-choice decision and unions it with the
retained view. Revisions combine by maximum; even an older or equal revision may
add previously unseen valid coverage. No partial, stale, or missing view can
erase or weaken retained work.

The revision is a source-progress watermark, not a content identifier. Coverage
bindings can be discovered independently of parent-chain mutations, which is why
equal-revision facts still join monotonically.

Accepted work and canonicity remain separate:

- adding accepted parent work may change child fork choice;
- changing only the parent's canonical pointer may not;
- the strongest known quantity for one grind ID applies to all of its local,
  inherited, and transitive coverage, then counts once.

The node may persist the last inherited snapshot directly or reconstruct it from
durable parent facts. A revision watermark or live subset cannot prove complete
coverage, so Lattice rejects a persisted marker without its snapshot rather than
substituting zero. Lattice rebuilds the local graph and projects it under the
restored snapshot. A persisted tip is a cache, not protocol truth.

## Admission And Recovery

Every external candidate follows one boundary:

```text
acquire -> verify -> targeted store -> atomically stage facts -> mutate -> project
```

Lattice verifies the root-work floor before child resolution, proves the exact
sparse path before requesting cross-chain evidence, proves carrier continuity,
executes this chain's transition, and derives typed facts. The node stores
verified local content and materialized state, then stages one immutable batch
before the actor mutation becomes visible. The node's atomic stage either makes
the whole batch durable and returns or throws without exposing any fact. Live
admission and recovery apply that exact receipt through the same reducer, so a
concurrent mutation cannot change the fact that was durably accepted. Root and
child bootstrap use this same boundary and expose a runtime only after its
genesis receipt is durable.

A target miss creates no local consensus fact and causes no implicit Lattice
retention. Likewise, storing a block does not enumerate its child-link trie.
The node may retain a carrier or exact child path when its availability policy
calls for it; Lattice validates only the targeted path submitted for this chain.

Relationship requirements stay explicit. Lattice derives same-chain graph holes
from accepted state, including after restart, so the node can submit each
predecessor through the same boundary. Cross-chain acquisition is different: the
parent carrier commits the child, but the child commits only `parentState`, not the
carrier CID. Lattice therefore names the missing proof or parent-issued fact and
the node routes that requirement to the authenticated parent process. It never
turns a state root into an inferred parent block.

`ChainBlockFact` carries immutable block consensus data and one derived
`StateDiff`. An immutable `ChainWorkFact` is identified by
`(blockHash, grindID, work)`; observations join under the logical coverage key
`(blockHash, grindID)`. This allows one grind to cover many blocks and stronger
verified observations to remain durable without mutable fact IDs.

Recovery does not treat local durable facts as wire evidence. It restores the
snapshot, replays already-authenticated staged batches through the same reducer
used by live admission from the node's durable revision floor, captures inherited
work, and recomputes canonicality. A sparse retained record may be hydrated only
by an authenticated staged fact; conflicting immutable metadata fails closed.
The node then rebuilds its projections from the resulting state.

## Ownership

| Component | Owns |
|---|---|
| Lattice | Protocol validation, state-transition verification, local accepted graph, work algebra, fork choice, securing-work export, `ChainCommit` |
| lattice-node | Acquisition, process authentication and supervision, atomic fact durability, inherited-snapshot routing/cache, retention, pin counts, projections, RPC |
| cashew | Generic content-addressed structures and matching targeted resolve/store traversal |
| VolumeBroker | Storage of complete selected Volumes, node-selected pinning and eviction |
| Ivy | Transport, discovery, authenticated sessions, delivery attribution |
| Tally | Provider observations and policy; never protocol validity |

Storage presence is not validity. Peer identity is not validity. Parent process
authentication establishes who may speak for a parent path, not what child branch
must win.

Nested Volumes remain independent availability units. Storing or pinning an outer
Volume creates no implicit ownership or retention relationship with a referenced
nested Volume.

## State Retention

Lattice retains the complete accepted consensus graph and local work coverage.
It does not prune consensus inputs according to a node storage budget.

The node decides how long to retain block bodies, `StateDiff` payloads,
materialized state, inherited-snapshot caches, and CAS pins. `StateDiff` is local
lifecycle metadata carried by `ChainBlockFact`; it is not committed in `Block` or
stored in `BlockMeta`. This keeps node retention independent from consensus.

## Review Contract

A change is architecturally valid only if all of these remain true:

1. One process owns one path and never recursively runs another chain.
2. The setup-wide root-work floor is checked before child resolution.
3. Every carrier proves same-chain continuity, even when its target misses.
4. Work measures union by grind ID before totaling.
5. Parent accepted work may affect weight; parent canonicity alone may not.
   Securing-work exports require a connected accepted ancestry.
6. Fork choice compares effective `trueCumWork`, then segment-base CID.
7. External ingress uses one admission boundary; recovery replays durable facts.
8. Durable facts precede visible mutation.
9. Lattice retains consensus inputs; the node owns payload retention.
10. Cross-chain interfaces carry evidence and work, never canonical-tip commands.
