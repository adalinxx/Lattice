# Correctness Invariant Catalog

## SEMANTICS-001 - Availability Is Not Invalidity

Unavailable content, CID-mismatching provider bytes, protocol-invalid evidence,
local verification failure, and future temporal admissibility are distinct
admission outcomes.

## RUNTIME-001 - One Runtime Owns One Chain

A `ChainLevel` owns one immutable absolute path and one `ChainState`. It cannot
contain, mutate, or recursively dispatch to another chain runtime.

## PROOF-001 - The Setup Floor Is Global and First

The proof root must clear `ChainRuntimeContext.minimumRootWork` before child
content is resolved or any chain target or state transition is considered.
Failure rejects every descendant under that root.

## PROOF-002 - The Sparse Path Is Exact

A child package is bound to one root CID, one complete directory path, and one
terminal candidate CID. Missing, extra, or substituted path evidence is invalid.

## PROOF-003 - Every Carrier Is Continuous

The process responsible for a carrier's path validates `prevState`, spec,
height, target succession, and strictly increasing timestamp continuity with
its same-chain predecessor, then issues a `ParentContinuityLink` bound to those
blocks and states. A carrier that misses its chain target is not exempt.
Acceptance-only MTP, future-drift, execution, and proposed-next-target rules do
not cross the process boundary into descendant validity.

## PROOF-004 - One Hash, Per-Level Targets

Every level evaluates the same root hash. Missing the current level's target
produces a carrier-only result and does not prevent a deeper level from accepting
against its target.

## PROOF-005 - Parent Facts Have Narrow Authority

The node authenticates the process that supplied a parent fact. Lattice binds
that fact to the exact path and content-addressed successor or child genesis it
describes. The successor CID commits the predecessor and structural fields. The
fact proves only parent-domain continuity or anchoring; it cannot decide child
validity, canonicity, retention, or fork choice.

## WORK-001 - One Grind Is Credited Once

The first accepted boundary from root to leaf defines the contribution. Its root
CID is the immutable grind identity. Replay is a duplicate; conflicting reuse of
the same identity cannot mutate consensus.

## WORK-002 - Parent Canonicity Is Not an Input

Once verified, a work contribution remains valid across parent extension,
reorganization, unavailability, and restart. No parent command or live weight
provider can change child validity, work, or fork choice.

## WORK-003 - Work Sums Are Exact

Individual work contributions are `UInt256`; cumulative and subtree work use an
unbounded exact sum. Overflow may not wrap or collapse distinct heavier chains
onto the same saturated value.

## WORK-004 - Every Distinct Grind Is Durable

Each accepted root CID produces one immutable `ChainWorkFact`. Multiple distinct
grinds may contribute to one block, and restart restores all of them. Replay is
idempotent; no grind may be collapsed into a block-level aggregate fact.

## FORK-001 - Exact Ties Have a Stable Segment Preference

Fork choice first compares each segment base's same-chain `trueCumWork`. Equal
work chooses the lexicographically smaller canonical base CID. `nextTarget` and
segment tips are not comparators. Arrival and replay order do not affect the result.

## FORK-002 - The Consensus Graph Is Not Pruned

Lattice retains its complete accepted graph and verified work facts. Node-owned
body, state, and pin retention cannot remove consensus inputs or select the tip.

## STORAGE-001 - Durability Precedes Visibility

Targeted verified content, materialized state, and one atomic
`ChainAdmissionBatch` of immutable typed facts must be stored before the
corresponding chain mutation becomes visible. A storage or staging failure
leaves consensus state unchanged.

## STORAGE-002 - Nested Volumes Are Independent

Each stored `Volume` is complete for its selected boundary. Storing an outer
Volume neither stores nor retains a nested Volume unless that nested boundary is
also explicitly targeted.

## LIFECYCLE-001 - StateDiff Is Local Metadata

`StateDiff` is derived during execution and carried once in the immutable
`ChainBlockFact`. It is not committed in `Block` or retained in `BlockMeta`.
Adding proof evidence to an existing block emits no second state diff.

## COMMIT-001 - Consensus Commits Are Revisioned

Every successful consensus mutation returns a `ChainCommit` with a monotonically
increasing revision. Its canonical delta is chain-local and revisions let the
node serialize durability and projections independently of completion order.

## TIME-001 - Admission Uses One Explicit Time Context

Admission captures one `ValidationContext`; every temporal check and stale retry
uses that same value. Internal wall-clock reads cannot change one attempt's result.

## INGRESS-001 - Every Source Has One Meaning

Gossip, sync, mining, parent extraction, sibling relay, and recovery route each
candidate through the same chain-local admission API. Equal candidate bytes,
evidence, runtime context, and `ValidationContext` produce equal outcomes.

## RESTART-001 - Restart Preserves Consensus

Without new external evidence, restoration reconstructs the complete accepted
graph, every distinct contribution, cumulative and subtree work, commit revision,
and canonical tip. Node retention may remove bodies or pins but cannot rewrite
those facts.
