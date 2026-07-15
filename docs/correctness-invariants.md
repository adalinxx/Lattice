# Correctness Invariant Catalog

## SEMANTICS-001 - Availability Is Not Invalidity

Unavailable content, CID-mismatching provider bytes, protocol-invalid evidence,
local verification failure, and future temporal admissibility are distinct
admission outcomes.

## RUNTIME-001 - One Runtime Owns One Chain

A `ChainLevel` owns one immutable absolute path and one `ChainState`. It cannot
contain, mutate, or recursively dispatch to another chain runtime.

## PROOF-001 - The Setup Floor Is Global and First

The proof root must clear `ChainRuntimeContext.minimumRootWork` before any chain
target or state transition is considered. Failure rejects every descendant under
that root.

## PROOF-002 - The Sparse Path Is Exact

A child package is bound to one root CID, one complete directory path, and one
terminal candidate CID. Missing, extra, or substituted path evidence is invalid.

## PROOF-003 - Every Carrier Is Continuous

Every carrier above the candidate proves `prevState` continuity with its own
same-chain predecessor, plus spec, height, target succession, and strictly
increasing timestamp continuity. A carrier that misses its chain target is not
exempt. Acceptance-only MTP, future-drift, execution, and proposed-next-target
rules do not cross the process boundary into descendant validity.

## PROOF-004 - One Hash, Per-Level Targets

Every level evaluates the same root hash. Missing the current level's target
produces a carrier-only result and does not prevent a deeper level from accepting
against its target.

## WORK-001 - One Grind Is Credited Once

The first accepted boundary from root to leaf defines the contribution. Its root
CID is the immutable grind identity. Replay is a duplicate; conflicting reuse of
the same identity cannot mutate consensus.

## WORK-002 - Parent Canonicity Is Not an Input

Once verified, a work contribution remains valid across parent extension,
reorganization, unavailability, and restart. No parent command or live weight
provider can change child validity, work, or fork choice.

## FORK-001 - Exact Ties Hold the Incumbent

A reorganization requires strictly greater same-chain subtree work. Equal work
does not invoke a hash, height, arrival, or parent-chain tiebreak.

## FORK-002 - Retention Cannot Select the Tip

Nodes with the same accepted graph and verified work select the same canonical
tip regardless of retained transition metadata. Missing transition bodies are a
typed reorganization output, not a fork-choice veto.

## STORAGE-001 - Durability Precedes Visibility

Targeted verified content, materialized state, and the node's admission record
must be stored before the corresponding chain mutation becomes visible. A
storage or staging failure leaves consensus state unchanged.

## STORAGE-002 - Nested Volumes Are Independent

Each stored `Volume` is complete for its selected boundary. Storing an outer
Volume neither stores nor retains a nested Volume unless that nested boundary is
also explicitly targeted.

## LIFECYCLE-001 - StateDiff Is Local Metadata

`StateDiff` is derived during execution and attached to local `BlockMeta` and
admission records. It is not committed in `Block`. Adding proof evidence to an
existing block emits no second state diff.

## INGRESS-001 - Every Source Has One Meaning

Gossip, sync, mining, parent extraction, sibling relay, and recovery route each
candidate through the same chain-local admission API. Equal candidate bytes,
evidence, context, and protocol time produce equal consensus outcomes.

## RESTART-001 - Restart Preserves Consensus

Without new external evidence, restoration reconstructs the same accepted graph,
contribution set, cumulative and subtree work, and canonical tip. Node retention
may remove bodies or pins but cannot rewrite those facts.
