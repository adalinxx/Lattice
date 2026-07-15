# Lattice Foundational Architecture

> Normative architectural laws, target boundaries, and correctness obligations

## Status and authority

This document is the architectural source of truth for the Lattice project. It governs the relationship between:

- `Lattice` consensus and execution;
- `lattice-node` orchestration, synchronization, durability, recovery, and supervision;
- Ivy transport, discovery, and content exchange;
- VolumeBroker storage and retention;
- Tally peer observations and admission policy;
- cashew content-addressed data structures and Volume traversal.

It does not replace exact protocol encodings, state-transition rules, work formulas, or wire layouts. Those specifications **MUST** conform to these laws.

When code, tests, comments, historical behavior, and this document disagree, the disagreement must be made explicit and reconciled. Existing code is not authoritative merely because it exists. A passing test is not authoritative when it preserves behavior that violates these laws.

The words **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are normative.

### Current migration status

This document specifies the target architecture. The accompanying PR makes its
Lattice admission boundary executable: legacy ingress, caller-controlled
context, consensus-triggered transport, and parent-to-child reorg commands are
removed. The node remains responsible for durable storage, transport scheduling,
and trusted bootstrap; those handoff obligations are recorded in [the migration
conflict register](migration-conflict-register.md). A claim that a node conforms
to a law is valid only when it satisfies those obligations too.

---

## 1. Why this redesign exists

The hardest Lattice failures increasingly come from architectural drift rather than isolated algorithms:

- missing data treated as invalid data;
- valid side blocks treated as rejected;
- parent canonicity leaking into child canonicity;
- sync, gossip, mining, rescue, and restart assigning different meanings to the same evidence;
- local storage failures being treated as peer behavior;
- recovery rebuilding different fork-choice inputs from those used live;
- public peer discovery becoming an accidental authority mechanism;
- per-CID presence being confused with availability of a complete Volume.

The redesign goal is therefore not abstraction count or file count. It is:

> **Make the implementation mechanically express the architecture of Lattice.**

A redesign succeeds when violations become difficult or impossible and correctness can be demonstrated independently of reviewer intuition.

### Non-goals

This redesign does not introduce:

- multiple Lattice namespaces;
- a second chain identity alongside the absolute path;
- semantic DAG-completeness logic in VolumeBroker;
- Lattice-specific materialization plans or traversal diagnostics in cashew;
- a parent canonical-transition mechanism that drives child behavior;
- trusted networking or storage shortcuts around verification.

---

## 2. The intuitive model

Lattice is one singular hierarchy rooted at Nexus.

```text
Nexus
  ├─ Payments
  │    └─ Settlement
  └─ Identity
```

An absolute path uniquely identifies a chain:

```text
Nexus
Nexus/Payments
Nexus/Payments/Settlement
```

The path is the identity. A genesis CID is not a second chain identity.

### 2.1 Nexus is the fixed base case

Nexus is the only chain with one protocol-fixed genesis CID. Compatible implementations hard-code the same CID, and every valid Nexus branch descends from that block.

Runtime consensus does not discover the Nexus genesis from peers and does not need Bitcoin data to start, validate, synchronize, mine, or recover.

Separately, the project publishes a Bitcoin block index and transaction that commit to the fixed Nexus genesis. Consumers may independently verify that historical provenance. The Bitcoin record proves publication precedence for the already-defined root; it is not a Lattice consensus input.

A codebase using the same fixed Nexus genesis and protocol rules is another implementation of the same Lattice. A different hard-coded Nexus genesis defines another network.

### 2.2 Child genesis CIDs are forks, not identities

Within one parent history, validated state transition rules prevent assigning the same child directory twice. Across competing valid parent forks, the same child path may be introduced with different child genesis CIDs.

Those CIDs are competing roots of the **same** path-defined child chain:

```text
Nexus/Payments
  ├─ genesis A → A1 → A2
  └─ genesis B → B1
```

The child chain owns the accepted forest and selects among those roots with its own fork choice. Parent canonicity neither determines child-genesis validity nor selects the child’s canonical root.

A child runtime is keyed by path, never by genesis CID. A later valid genesis candidate updates the existing runtime rather than creating a second chain.

### 2.3 Cross-chain relationships carry evidence

The parent-child relationship is:

```text
Parent block produces verifiable evidence
        ↓
Child validates the evidence
        ↓
Child derives its own fork-choice inputs
        ↓
Child selects its own canonical branch
```

The parent does not send child canonical-state commands.

> **Evidence may cross chain boundaries. Authority and canonicity do not.**

---

## 3. Hierarchy of responsibility

```text
Core philosophy
      ↓
Protocol semantics
      ↓
Consensus and execution
      ↓
Node orchestration and durability
      ↓
Networking and process authority
      ↓
Storage and caching
```

A lower layer supports a higher layer. It does not redefine it.

Therefore:

- storage does not define validity;
- networking does not define consensus;
- process authorization does not make content valid;
- restart recovery does not define protocol truth;
- parent canonicity does not define child canonicity;
- local availability does not define global validity;
- optimization does not redefine semantics.

Every review should ask:

> Is a supporting layer being allowed to decide something that belongs to a higher layer?

---

## 4. Independent domains

### 4.1 Availability

Availability asks whether this node can currently obtain the complete Volumes and evidence required for an operation.

It is local, temporary, and retriable. An unavailable object is not invalid; it is not yet evaluable by this node. A timeout, absent object, or response that does not match the requested CID is an availability or provider-reliability observation, not proof that the requested candidate is protocol-invalid.

### 4.2 Validity

Validity asks whether complete required bytes and evidence satisfy protocol rules, including CID integrity, proof-of-work, signatures, nonces, path binding, continuity, state transitions, cross-chain proofs, and contribution derivation.

For fixed bytes, complete evidence, and one protocol version, validity is immutable.

### 4.2.1 Temporal admissibility

Temporal admissibility asks whether otherwise valid evidence may be admitted at a particular protocol time. A future-dated candidate is `notYetAdmissible`, not unavailable and not permanently invalid. Reaching the relevant time may change admissibility without changing the candidate bytes, verified evidence, or protocol validity.

### 4.3 Canonicity

Canonicity asks which valid branch this chain’s own fork-choice rule selects.

A valid block may be canonical, noncanonical, promoted, or displaced without changing validity.

### 4.4 Durability

Durability asks whether this node persisted enough accepted evidence to reconstruct the same accepted graph or forest and fork-choice state after restart.

It is a local implementation property, not a protocol judgment about a block and not a behavioral judgment about a peer.

### 4.5 Authority

Authority asks which authenticated peer or process may perform an operational action, such as serving a parent-evidence protocol or registering a child endpoint.

Authority does not make bytes valid. Authorized peers may send invalid data; unauthorized peers may provide content that is independently verifiable.

### 4.6 Evidence

Evidence is content whose protocol meaning can be independently verified. It may establish block inclusion, work contribution, state facts, genesis admission, or continuity.

Evidence does not become true because it is stored, transported by an authorized peer, or carried by a canonical block.

### 4.7 Provider reliability

Provider reliability asks whether a provider delivered requested content correctly and promptly. It is operational evidence for Ivy and Tally, separate from protocol correctness. A provider may be attributed for a malformed or CID-mismatching response, but that response alone does not classify the requested candidate as invalid.

---

## 5. Architectural laws

### Law 1 — Availability is not validity

Missing required data yields an unavailable/deferred result, never invalidity. Nodes with different caches must not disagree about protocol truth.

### Law 2 — Validity is not canonicity

Valid side blocks remain valid. Fork choice compares valid alternatives; it does not decide validity.

### Law 3 — Protocol validity knowledge is monotonic

For fixed bytes, complete evidence, and one protocol version, a candidate moves from unknown to valid or invalid. Canonicity, retention, peer availability, and provider reliability do not reverse that judgment. Temporal admissibility is a separate, time-dependent result.

### Law 4 — Canonicity is chain-local

Each chain owns its valid graph or forest, fork-choice inputs, canonical branch, and reorganization decisions.

### Law 5 — Parent canonicity never changes child validity

A child block, child genesis candidate, or securing proof does not become invalid merely because a carrier is no longer canonical on the parent.

### Law 6 — Parent canonicity never changes child canonicity

The child does not mirror the parent branch. A parent reorganization is not a child fork-choice instruction.

### Law 7 — Reorganizations are chain-local events

A chain reorganizes only when its own valid graph or verified evidence changes. Production code MUST NOT recursively propagate reorganization commands to descendants.

### Law 8 — Canonical-transition projections are strictly chain-local

A transition may update that chain’s receipts, history, mempool, retention, notifications, and metrics. It has no child consumers.

### Law 9 — Verified security evidence is append-only and deduplicated

Once verified under the protocol, its semantic fact is retained append-only and deduplicated by protocol-defined contribution identity. Parent canonicity alone cannot revoke it. Raw immutable package bytes MAY be compacted only when retained material can re-establish the same verified fact and restart-equivalent fork-choice inputs; compaction cannot turn a fact back into an unverified claim.

### Law 10 — Cross-chain interfaces deliver evidence, never commands

Allowed cross-chain messages include evidence packages and complete content. Forbidden semantics include “set child tip,” “reorganize child,” or “invalidate child because parent changed.”

### Law 11 — Networking supplies bytes, not truth

Peer identity, routing position, reputation, and authorization select whom to ask and what service is permitted. They do not bypass content and protocol verification.

### Law 12 — Storage preserves evidence, not truth

Storage may guarantee atomicity, content-address integrity, retention, and availability. Presence in storage is not proof of protocol validity.

### Law 13 — A stored Volume is complete

A Volume is one atomic availability unit. A storer publishes a Volume only after a successful full traversal of that boundary. A failed traversal publishes no partial scope.

Nested Volumes are independent units. An outer Volume may be complete while one referenced nested Volume is absent; that is partial object-graph availability, not a partial Volume.

### Law 14 — Durable evidence precedes visible consensus mutation

Immutable content and all consensus-relevant semantic evidence required for restart equivalence must be durable before a node exposes the corresponding accepted graph or canonical change. Durability need not pin every raw transport package forever, but it MUST preserve enough material to re-establish the retained facts.

### Law 15 — Restart is not a different consensus path

With no new external evidence, restart reconstructs the same accepted graph or forest, work contributions, and canonical tip used live.

### Law 16 — Every ingress path has one consensus meaning

Gossip, sync, mining, parent extraction, rescue, duplicate evidence updates, and restart may differ in acquisition. Given the same verified candidate and evidence, they MUST produce the same consensus result.

### Law 17 — Local failure is not peer failure

Local cancellation, overload, missing cache data, and storage failure do not lower peer reputation. Remote-attributable delivery failures and malformed responses may affect provider reliability, but protocol-invalidity is established only by verified candidate evidence.

### Law 18 — Chain identity is contextually validated

A path wrapper may prevent formatting bugs but does not prove the path exists or is authorized. Transaction, proof, receipt, genesis, and process-scope uses MUST validate path meaning in context.

### Law 19 — Nexus provenance is external to runtime consensus

A failed or missing Bitcoin provenance check affects the historical claim, not Nexus runtime validity. Bitcoin transitions and reorganizations never become Lattice commands.

### Law 20 — Abstractions must enforce boundaries

A new type or helper is justified when it makes an invalid transition unrepresentable, creates an independent testing seam, or centralizes an authoritative rule. Renaming unchecked data is not architectural progress.

---

## 6. Layer responsibilities

### cashew

Owns immutable Merkle DAG structures, canonical CIDs, owned child versus `Reference` semantics, Volume boundaries, generic traversal, proofs, and transforms.

It does not decide application workflow completeness, retention, peer selection, or consensus.

### VolumeBroker

Owns atomic storage and retrieval of complete declared Volumes, generic CID integrity, retention roots or pins, and eviction.

It does not interpret application DAG semantics or decide which nested Volumes an operation requires.

### Tally

Owns classified peer observations, reputation models, and admission policy.

It MUST distinguish remote-attributable behavior from local availability and durability failures.

### Ivy

Owns authenticated sessions, public overlay routing, content exchange, and delivery attribution.

A pinned operational relationship and a public discovery overlay are distinct topologies. Public discovery MUST NOT substitute another peer into a pinned authority relationship.

### Lattice

Owns protocol validity, execution, accepted block graphs or forests, work accounting, fork choice, and chain-local transitions.

Consensus returns missing-data requirements to the node. It does not invoke network transport and does not propagate parent reorg commands to children.

### lattice-node

Owns acquisition, durable staging, serialized commit orchestration, recovery, projections, RPC, mining coordination, and process supervision.

It must preserve one Lattice meaning across every ingress transport.

---

## 7. Cross-chain evidence model

The architecture distinguishes:

- `ChildBlockProof`: security evidence that a mined root commits to a child block and derives work contributions;
- `ParentStateWitness`: execution evidence for authenticated parent-state facts required by the child block;
- `ChildValidationPackage`: versioned transport and persistence package combining the two without merging their identities;
- child genesis evidence: evidence admitting a root candidate into the existing path-defined child runtime.

Work contributions are derived locally from verified proofs, never trusted as wire claims.

The exact canonical package stored, served, and relayed should be the same immutable value. Live gossip must not relay a weaker pre-finalization package than sync serves later.

---

## 8. Target consensus lifecycle

```text
Acquire → Verify → Plan → Persist → Commit → Project
```

### Acquire

Obtain complete Volumes and evidence from local stores, Ivy, pinned sessions, RPC, or mining output. Acquisition answers availability only.

### Verify

Perform deterministic, non-mutating protocol validation and derive work contributions locally. Classify unavailable evidence, protocol-invalid evidence, and `notYetAdmissible` evidence distinctly.

### Plan

Evaluate the verified candidate against this chain’s graph and evidence snapshot. Distinguish canonicalization, valid side admission, duplicate, typed missing-body requirements, temporal inadmissibility, and invalidity.

### Persist

Atomically persist the minimum evidence needed to reconstruct the planned decision. Immutable CAS bytes may be staged first; orphan immutable content is harmless.

### Commit

Mutate only this chain’s in-memory consensus state after durable preparation succeeds.

### Project

Apply chain-local derived effects from a durable canonical-transition event. Projectors are idempotent and cannot affect fork choice.

Consensus MUST return missing-body requests rather than invoking Ivy or another transport internally.

---

## 9. Correctness obligations

The redesign is not complete without independent evidence of correctness.

### 9.1 Invariant catalog

Each law must have stable invariant identifiers, an owning layer, explicit assumptions, and tests. Important families include:

```text
SEMANTICS — availability, validity, canonicity separation
CHAIN     — path identity and genesis-root behavior
WORK      — contribution identity and restart stability
VOLUME    — complete-scope storage and CID integrity
DURABLE   — pre-commit persistence and crash atomicity
NETWORK   — authority and peer attribution
INGRESS   — gossip/sync/mining/rescue/restart equivalence
```

### 9.2 Deterministic and golden-vector tests

Canonical encodings, CIDs, work identities, proof paths, transaction rules, and wire formats require cross-platform golden vectors.

### 9.3 Property-based tests

Generate path trees, nested Volumes, proof sets, fork graphs, and transaction batches. Test order independence, deduplication, failed traversal, path isolation, and builder/validator agreement.

### 9.4 Differential tests

The same verified candidate and evidence set must be fed through every ingress path. Compare decision, accepted graph, canonical tip, work, durable package, transition, and restart state.

### 9.5 Parent-independence tests

The governing test is: given the same child path, accepted child graph or forest, verified evidence set, protocol version, and admissibility time, runs with different parent canonical tips MUST select the same child accepted graph or forest, contribution set, and canonical tip.

A parent extension, side admission, reorganization, and restart MUST cause zero direct child consensus mutations. Separate forest tests MUST cover competing child roots with no common child ancestor, arrival-order independence, deterministic selection, and restart preservation.

### 9.6 Reference model

A small model containing accepted blocks, parent links, own work, inherited contributions, available Volumes, and canonical tip serves as an independent oracle for randomized traces.

### 9.7 Fault injection

Every external or durable boundary needs deterministic failure seams: block/state/package writes, work and anchor writes, canonical index updates, pin operations, network loss, malformed bytes, and unavailable nested Volumes.

### 9.8 Crash matrix

Force termination before staging, after staging, during and after metadata commit, before and after in-memory mutation, before relay, and during projection. Restart may recover only the old state or the fully committed new state.

### 9.9 Full-stack simulation

Use virtual time, seeded randomness, crashable stores, simulated Ivy topologies, partitions, reordering, bounded storage, and process lifecycle events. Every failure stores a replayable trace.

---

## 10. Cross-repository contract tests

### cashew ↔ VolumeBroker

- successful traversal emits complete Volume scopes;
- failed traversal publishes no incomplete scope;
- `Reference` fields create no owned retention edges;
- stored Volumes round-trip exactly.

### VolumeBroker ↔ Ivy

- local Volumes are served completely;
- deficient responses are rejected and attributed;
- network bytes are CID-verified before storage;
- absence yields unavailable, never a fabricated partial Volume.

### Ivy ↔ Tally

- typed remote failures affect peer observations;
- local failures do not;
- pinned sessions cannot be widened by public discovery.

### Lattice ↔ lattice-node

- every consensus outcome has one explicit node mapping;
- valid side blocks remain valid;
- unavailable differs from invalid;
- durability precedes visible mutation;
- parent transitions never invoke child consensus.

---

## 11. Review and release gates

Every architecture-sensitive PR must state:

```text
Architectural laws affected
Invariants affected
Behavior deliberately changed
Behavior required to remain equivalent
Independent oracle
Crash boundaries
Fault injection
Parent/child independence impact
Ingress equivalence impact
Schema and wire migration
Rollback plan
```

Pull requests require deterministic tests, golden vectors where relevant, targeted property/fault tests, and macOS/Linux builds. Nightly testing should run model traces, crash matrices, recursive simulations, storage pressure, wire fuzzing, and leak checks.

A release candidate must demonstrate live/restart equivalence, no cross-chain reorg propagation, cold-follower recovery, schema upgrades, and deterministic full-stack simulations.

---

## 12. Redesign sequence

1. Ratify this architecture and identify conflicts explicitly.
2. Build the invariant, differential, fault, crash, and simulation harnesses.
3. Finish `ChildBlockProof` / `ParentStateWitness` / `ChildValidationPackage` separation and durable-before-commit.
4. Make `Lattice` a one-chain kernel with explicit fixed-Nexus and child-root-fork admission.
5. Establish one authoritative consensus commit store and chain-local outbox.
6. Decompose `lattice-node` around one path-keyed `ChainRuntime`.
7. Separate pinned Ivy sessions from the public overlay and version application subprotocols.
8. Simplify VolumeBroker and Tally boundaries.
9. Remove legacy paths only after differential and crash equivalence is established.

---

## 13. Definition of done

The foundational redesign is complete when:

- one absolute path identifies one chain domain;
- Nexus admits exactly the hard-coded genesis CID;
- multiple child genesis CIDs at one path are root forks in one runtime;
- availability, protocol validity, temporal admissibility, canonicity, durability, authority, provider reliability, and evidence have distinct outcomes;
- every chain owns only its own fork choice and reorganization;
- parent reorgs cause zero direct child mutations;
- parent canonical transitions have no child consumers;
- semantic work evidence is deduplicated, append-only, and restart-stable while raw packages remain safely compactable;
- every stored Volume is complete and CID-valid;
- cashew remains generic;
- pinned authority cannot be replaced by public discovery;
- evidence is durable before visible consensus mutation;
- restart reconstructs the live decision;
- projections can be deleted and rebuilt without changing consensus;
- all ingress paths have one meaning;
- every law has falsifiable automated tests;
- randomized failures produce replayable traces.

The governing rule is:

> **Evidence may cross chain boundaries. Authority and canonicity do not.**

The implementation rule is:

> **Acquire bytes, verify meaning, persist evidence, then change one chain’s state.**
