# Chain-Local Fork Choice and Hierarchical Work

This document explains the work model implemented by Lattice. The normative
rules are in [the protocol specification](spec.md#9-consensus).

## 1. Two Different Trees

Lattice uses two structures that must not be confused.

1. A **nested block tree** is committed by one mined root. Following
   `children[directory]` from the root reaches blocks for deeper chains. One root
   hash therefore supplies proof-of-work evidence to every block on that path.
2. A **same-chain block graph** contains competing blocks and roots for one chain
   path. `ChainState` applies GHOST to this graph.

The first is content-addressed protocol data. The second is consensus state for
one chain. Neither implies a recursive in-process runtime tree: one Lattice
process owns one `ChainLevel`, one `ChainState`, and one absolute chain path.

## 2. Verifying One Root Grind

Let `R` be the outer root block, `h = proofOfWorkHash(R)`, and `C` the candidate
for the chain handled by this process. A `ChildBlockProof` contains the exact
sparse content-addressed path:

```text
R -> children[d0] -> children[d1] -> ... -> C
```

Admission verifies the package in this order:

1. Recompute the root CID and hash from the supplied root bytes.
2. Require `workForHash(h) >= minimumRootWork`, where `minimumRootWork` is the
   setup-wide traversal floor in `ChainRuntimeContext`.
3. Only after the floor passes, resolve the targeted child content.
4. Require the proof's directory path and terminal CID to match this process's
   absolute path and candidate.
5. For every carrier above `C`, require a `ParentContinuityLink` issued by the
   process responsible for that carrier's path after validating `prevState`,
   spec, height, target succession, and strictly increasing timestamp
   continuity. Bind the fact to the exact path and carrier CID; that CID already
   commits the predecessor, spec, and state references.
6. At every vertical edge, require the nested child's `parentState` to match the
   carrier state committed by the protocol.
7. Compare the **same** root hash `h` with each level's target.

The setup floor is checked first and is independent of every chain target. If it
fails, the entire nested tree rooted at `R` is rejected. It cannot be rescued by
an easier descendant target.

A chain target has narrower meaning:

```text
h <= target(level)  -> this level accepts the grind
h >  target(level)  -> carrier only; descendants may continue
```

A target miss at an ancestor is therefore not proof failure. The block remains a
validated carrier in the sparse path, and a deeper chain process may accept the
same root hash against its own target. The carrier's same-chain continuity is
still mandatory; otherwise an attacker could fabricate intermediate state.
Rules that only govern acceptance on the carrier's chain -- state execution,
MTP/future drift, and the carrier's proposed `nextTarget` -- are intentionally
not imported into descendant validity.

## 3. Credit the Grind Once

Walk root-to-leaf and find the first level whose target accepts `h`. That level is
the highest accepted boundary for this physical grind.

```text
acceptedBoundary = first B_i where h <= target(B_i)
creditedWork      = floor(U256_MAX / target(B_i))
grindID           = CID(R)
```

That boundary fixes the contribution amount. A deeper accepted level carries the
same immutable fact; no separate relationship or origin label is needed.

The contribution is immutable and identified by the root CID. A chain counts a
given `grindID` at most once. Replaying the proof is a duplicate; presenting the
same ID with a different block or work fact is conflicting evidence and must not
change consensus state.

This gives security inheritance without a live parent-weight provider:

- no parent block map is consulted during fork choice;
- no parent extension retroactively increases a child block's weight;
- no parent reorganization revokes verified child evidence; and
- restart restores the same contribution facts used before shutdown.

New proof evidence may attach a previously unseen contribution to an already
known block. Every distinct grind is staged and persisted as an immutable
`ChainWorkFact`. Lattice updates that block's weight and reevaluates fork choice,
but does not replay the block's state transition or emit a second `StateDiff`.

Individual contributions remain `UInt256`, while cumulative and subtree work
use an exact growable sum. Saturating at `UInt256.max` would make different
amounts of work compare equal and is therefore not a valid fork-choice rule.

## 4. Chain-Local GHOST

For a block `B` in one chain's graph:

```text
blockWork(B) = sum(contribution.work for contribution in B)

subtreeWeight(B) =
    blockWork(B) + sum(subtreeWeight(X) for X in sameChainChildren(B))
```

Each verified contribution is counted once at its block. `subtreeWeight` is then
maintained upward through the same-chain graph. Fork choice descends through the
child with greatest subtree weight.

At each fork, the competing same-chain children are the segment bases. Their
`subtreeWeight` is their `trueCumWork` and remains the first comparator. Equal
work compares the segment bases' canonical CID bytes; the lexicographically
smaller CID wins. Neither `nextTarget` nor either segment's tip participates.
The same rule applies to competing genesis roots and is independent of arrival
or replay order.

`cumulativeWork(B)` is also retained as the same-chain prefix sum from genesis to
`B`. It supports exact queries, out-of-order repair, and restart. It does not
import live work from another chain or override the GHOST result.

Lattice retains the complete accepted consensus graph and verified contribution
set. Node state retention and body availability are not fork-choice inputs.

## 5. One Admission Path

Gossip, sync, mining output, parent extraction, sibling relays, and recovery may
obtain bytes differently. They all submit candidates through
`ChainLevel.admitBlockHeaderChainLocal` and receive the same decision for the same
candidate, evidence, runtime context, and captured `ValidationContext`. The library has no
separate `ChainSyncer`, trusted snapshot replacement, or transport-triggered
consensus path.

Admission follows one durability boundary:

```text
targeted resolve
  -> deterministic verification and execution
  -> targeted store of verified content and materialized state
  -> node-owned atomic staging of typed block/work facts
  -> revisioned chain-local ChainCommit
```

`ChainLevel.bootstrap` uses this same boundary for a standalone chain runtime.
There is no `bootstrapChild`; process topology is a node concern.

## 6. Ownership Boundaries

Lattice owns:

- proof and continuity validation;
- state-transition execution;
- derivation and deduplication of work contributions;
- the complete accepted same-chain graph, GHOST fork choice, and chain-local
  reorganization decision.

The node owns:

- acquisition and peer selection;
- filesystem persistence and restart orchestration;
- process topology, including which parent or sibling peers to contact;
- CAS pin counts, retention policy, archival, and garbage collection; and
- projections such as mempool, history, notifications, and RPC state.

Parent and sibling processes are never consensus authorities for another chain.
A parent process may issue continuity and genesis facts about its own validated
state; the node authenticates and transports those facts. Commands such as "set
child tip" or "invalidate because the parent reorged" do not cross the boundary.

`StateDiff` follows the same boundary. It is carried once by the immutable
`ChainBlockFact`, not committed in `Block` or retained in `BlockMeta`. The node
uses it to update CID reference counts and choose which materialized state
Volumes to pin. A `ChainAdmissionBatch` atomically stages the block fact and its
initial work fact; later distinct grinds stage separate work facts.

Every successful consensus mutation returns a monotonically revisioned
`ChainCommit`. Its canonical delta describes a chain-local reorganization when
the selected branch changes; the node uses the revision to serialize durable
state and projections even when admissions finish concurrently.

## 7. Required Properties

An implementation must preserve all of the following:

1. A root below the setup-wide work floor is rejected at every depth.
2. Every proof is bound to one exact root-to-candidate path and leaf CID.
3. Every carrier proves same-chain predecessor continuity even when its target
   misses.
4. Every level evaluates the same root hash against its own target.
5. One physical grind is credited at the first accepted boundary and deduplicated
   by root CID.
6. Parent canonicity cannot change child validity, work facts, or fork choice.
7. Exact work ties prefer the smaller canonical segment-base CID; targets and
   tips are not tie-break inputs.
8. Lattice does not prune its accepted consensus graph.
9. Every distinct grind is durable and restart restores all of them.
10. One captured validation-time context governs an admission and its retries.
11. Every ingress source reaches the same admission API.
