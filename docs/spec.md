# Lattice Protocol Specification

Version 0.1.0

This document is the normative consensus definition. For an intuitive reading
order, start with the [documentation index](index.md),
[architecture](foundational-architecture.md), and
[work and fork choice](consensus-fork-choice.md).

## 1. Overview

Lattice is a hierarchical proof-of-work protocol, not a single blockchain. Every chain may commit child blocks, and each child may do the same. One mined root therefore commits a nested block tree. **Nexus** is the single outermost chain and the entry point from outside the hierarchy; every absolute chain path begins with `Nexus`. Descendants inherit identity-bearing work from accepted ancestor graphs: the root CID identifies one grind, its strongest verified accepted-target bound fixes its quantity, and its sparse proof terminates at exactly one block per chain. Value moves across chains through a three-phase **deposit/receipt/withdrawal** protocol.

Each chain defines its own operations, `ChainSpec`, and chain policies, so chains are heterogeneous; only the organizing protocol -- block structure, proof-of-work, fork choice, and the cross-chain transfer rules -- is shared across the hierarchy.

All state is content-addressed using IPLD/CID. Blocks reference state via Merkle roots, enabling light client verification without full state replication.

The protocol hierarchy is not a recursive runtime topology. One Lattice process
owns one absolute chain path. Node software supervises separate processes and may
obtain evidence from parent or sibling peers, but those peers are availability
sources rather than validity or fork-choice authorities.

## 2. Notation

- `H(x)` -- SHA-256 hash of `x`
- `CID(x)` -- Content Identifier of serialized `x` (IPLD DAG-CBOR + SHA-256)
- `SMT` -- Sparse Merkle Tree
- `B[i]` -- Block at height `i` on a given chain
- `||` -- concatenation
- `>>` -- arithmetic right shift
- `U256` -- 256-bit unsigned integer

Consensus ingress accepts only the unique canonical textual spelling of a CID,
bounded by the child-proof wire's `UInt16` length capacity (65535 bytes) — a
structural encoding bound, not a policy cap. Honest DAG-CBOR + SHA-256 CIDs are
~59 bytes, far below it; the canonical round-trip is the real identity check, and
this bound only limits parse work on untrusted input to what the wire can carry.

## 3. Data Structures

### 3.1 Block

A block `B` is a tuple:

```
B = (
    version:          uint16,
    previousBlock:    CID(Block) | nil,
    transactions:     CID(MerkleDictionary<CID(Transaction)>),
    target:           U256,
    nextTarget:       U256,
    spec:             CID(ChainSpec),
    parentState:      CID(LatticeState),
    prevState:        CID(LatticeState),
    postState:        CID(LatticeState),
    children:         CID(MerkleDictionary<CID(Block)>),
    height:           uint64,
    timestamp:        int64,
    nonce:            uint64
)
```

### 3.2 Transaction

```
Transaction = (
    signatures: Map<PublicKeyHex, SignatureHex>,
    body:       CID(TransactionBody)
)
```

### 3.3 TransactionBody

```
TransactionBody = (
    accountActions:     [AccountAction],
    actions:            [Action],
    depositActions:     [DepositAction],
    genesisActions:     [GenesisAction],
    receiptActions:     [ReceiptAction],
    withdrawalActions:  [WithdrawalAction],
    signers:            [CID(PublicKey)],
    fee:                uint64,
    nonce:              uint64,
    chainPath:          [string]
)
```

### 3.4 LatticeState

The world state is a 5-tuple of Sparse Merkle Tree roots:

```
LatticeState = (
    accountState:      SMT<CID(PublicKey) -> uint64>,
    generalState:      SMT<string -> string>,
    depositState:      SMT<DepositKey -> uint64>,
    genesisState:      SMT<string -> CID(Block)>,
    receiptState:      SMT<ReceiptKey -> CID(PublicKey)>
)
```

### 3.5 ChainSpec

```
ChainSpec = (
    maxNumberOfTransactionsPerBlock: uint64,
    maxStateGrowth:                 int,
    maxBlockSize:                   int,
    premine:                        uint64,
    targetBlockTime:                uint64,     // milliseconds
    initialReward:                  uint64,
    halvingInterval:                uint64,
    retargetWindow:                 uint64,
    wasmPolicies:                   [WasmPolicyRef]
)
```

`maxBlockSize` bounds the canonical unique content bytes owned by one logical
block. The measured closure is the block root Volume boundary (including its
transaction and child indexes and their reference CIDs) plus every referenced
transaction Volume and transaction body. Each CID's canonical bytes count once.
The contents of the chain spec, wasm modules, parent blocks, all state Volumes,
child blocks, and admission evidence are independent Volumes and do not count.

**Chain-committed retarget clamp (default):**

```
maxTargetChange = 2   // ChainSpec default; a chain may commit its own value
```

The per-retarget clamp factor is the chain's own committed
`ChainSpec.maxTargetChange`; the default above applies only when a chain commits
none. There is no protocol-imposed difficulty floor and no protocol-wide difficulty
constant. The positive `ChainSpec` values are chain-selected validity. Storage, transport,
bootstrap-spec, and parent-witness ceilings are node-local acquisition policy,
not common consensus constants. A node may decline to operate a chain whose
committed parameters exceed its resources without proving any block invalid.
Bounds required by a serialized field width and the deterministic WASM
execution profile remain protocol rules.

State keys use a small consensus grammar so radix work cannot grow with
attacker-chosen Unicode. Every key is non-empty visible-ASCII (`0x21`...`0x7e`);
directories are additionally separator-free (`/`-banned, to keep ReceiptKey
injectivity) and bounded by the child-proof wire's `UInt16` length. There is no
protocol length cap on account identifiers or general-state keys — key size is a
node storage concern, not a consensus rule. Derived account, deposit, and genesis keys remain
plain text and enumerable. Receipt-state storage alone uses
`SHA256("lattice/receipt-state/v1\0" || ReceiptKey)` as a 64-character lowercase
hex path, because a child may need that proof from a remote same-chain peer.
Withdrawal receipt identities must be unique within a transaction and their
proofs exact. The parent-receipt closure is validation witness data outside
`maxBlockSize` and materialized state growth; each node bounds acquisition
before decoding it.

### 3.6 Action Types

#### AccountAction

```
AccountAction = (owner: CID(PublicKey), delta: int64)
```

**Validity:** `delta != 0` and `delta != Int64.min`

#### Action (Generic Key-Value)

```
Action = (key: string, oldValue: string?, newValue: string?)
```

**Validity:** `key != ""` AND (`oldValue != nil` OR `newValue != nil`)

#### DepositAction

```
DepositAction = (nonce: uint128, demander: CID(PublicKey), amountDemanded: uint64, amountDeposited: uint64)
```

#### WithdrawalAction

```
WithdrawalAction = (withdrawer: CID(PublicKey), nonce: uint128, demander: CID(PublicKey), amountDemanded: uint64, amountWithdrawn: uint64)
```

#### ReceiptAction

```
ReceiptAction = (withdrawer: CID(PublicKey), nonce: uint128, demander: CID(PublicKey), amountDemanded: uint64, directory: string)
```

#### GenesisAction

```
GenesisAction = (
    directory: string,
    blockCID:  CID(Block)
)
```

### 3.7 Keys

#### DepositKey

```
DepositKey = demander || "/" || amountDemanded || "/" || nonce
```

Used to index `depositState`. Uniquely identifies a pending cross-chain deposit by the demander's address, the amount demanded on the parent chain, and a nonce.

#### ReceiptKey

```
ReceiptKey = directory || "/" || demander || "/" || amountDemanded || "/" || nonce
```

Used to index `receiptState`. Associates a receipt on the parent chain with the child chain directory where the deposit originated.

## 4. Chain Hierarchy

### 4.1 Structure

Chains form a rooted tree:

```
    Nexus
   /     \
  A       B
 / \
A1  A2
```

A `directory` in a parent's `GenesisAction` is a **relative edge label** -- it
names the child only with respect to that parent and is not stored in
`ChainSpec`. A chain's canonical identity is its full **path** from Nexus, e.g.
`Nexus/Payments`. Siblings under different parents may reuse a
directory because their full paths differ.

### 4.2 Process Boundary

One validator process owns one absolute chain path, one accepted same-chain
forest, and one canonical projection. It contains no child validators. A target
miss at the current level yields only a carrier result; the node may route the
corresponding sparse proof to a separately supervised descendant process.

## 5. Block Validation

### 5.1 Genesis Block Validation

A genesis block `B` is valid if and only if ALL of the following hold:

1. `B.previousBlock == nil`
2. `B.height == 0`
3. `B.timestamp <= validationContext.now`, where the admission attempt captures
   `validationContext.now` once (node-local, retriable admission — a future
   timestamp is deferred until real time reaches it, not permanently rejected)
4. `B.prevState == CID(emptyState())`
5. `B.nextTarget == B.target`, and the target `B` commits is actually met — the
   same inclusive `hash <= target` rule every block obeys, evaluated against the
   hash that secures `B` at its own level (per §5.4 and §9.5):
   - **Nexus (root) genesis:** `proofOfWorkHash(B) <= B.target` — `B`'s own grind.
   - **Child genesis:** the securing root-grind hash `h` carried by its
     `ChildBlockProof` satisfies `h <= B.target`; `B`'s own block hash is not
     evaluated (a child inherits identity-bearing work from the root grind, not
     from mining its own block).

   Consensus does not constrain the target *value* a genesis may commit, but that
   target must be met, so `target == 0` — which no hash satisfies at either level —
   is invalid. By convention `GenesisCeremony` commits the canonical maximum
   (easiest) target, which every hash satisfies, so the chain starts trivial, needs
   no grinding, and self-calibrates from block 1; an operator wanting a harder
   genesis must grind to meet it. A genesis therefore always carries positive work
   (one unit at the canonical target), so there is no zero-work-genesis exemption
   in construction or replay.
6. All transactions in `B.transactions` are fully resolvable
7. For each transaction `tx`: `tx.validateTransactionForGenesis()` returns true
   - Account and general actions are structurally valid
   - No deposit, receipt, or withdrawal actions are present
8. Every transaction's `chainPath` equals the runtime's absolute path
9. All transaction bodies pass the chain's policies
10. `|transactions| <= spec.maxNumberOfTransactionsPerBlock`
11. `sum(stateDelta(tx) for tx in transactions) <= spec.maxStateGrowth`
12. **Balance conservation (genesis)**:
    ```
    totalCredits <= premineAmount
    ```
13. Every `GenesisAction` has a non-empty, visible-ASCII, separator-free
    directory whose byte length fits the child-proof wire's `UInt16` length
    prefix, and a canonical genesis block CID. Its child-proof depth likewise
    fits the wire's `UInt16` prefix. These are the wire format's structural
    capacities, not policy caps. The child process validates that block's
    content.
14. **Post-state correctness**: Applying all actions to `prevState` (empty
    state) produces `postState`:
    ```
    proveAndUpdateState(prevState, allActions) == postState
    ```

Genesis authority is the exact content-addressed block: Nexus by its configured
genesis CID and a child by its parent's `GenesisAction.blockCID`. Signature and
declared-signer fields on genesis transactions carry no authority and are not
shape-constrained. All later transactions remain signature-strict. The
reference node binds
`bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq` locally.

### 5.2 Nexus Block Validation

A non-genesis nexus block `B` with previous block `P` is valid if and only if:

1. `P` is resolvable
2. `B.spec == P.spec` (chain spec continuity)
3. `B.prevState == P.postState` (state continuity)
4. `B.height == P.height + 1`
5. `P.timestamp < B.timestamp <= validationContext.now`. The strict increase
   over the parent is the sole agreed-state timestamp rule (it makes timestamps
   strictly increasing along the chain, subsuming a MedianTimePast lower bound,
   which is therefore not imposed). The `<= now` bound is node-local, retriable
   admission — a future block is deferred until real time reaches its timestamp,
   never permanently rejected. The attempt captures `validationContext.now` once.
6. `B.target <= P.nextTarget` (as hard or harder than scheduled, never easier),
   and `B.nextTarget` equals section 5.5's clamped proportional retarget computed
   from `B.target`
7. All transactions pass `validateTransactionForNexus()`:
   - Signatures are valid over the `lattice-tx-v1` envelope
   - Signers match signature public keys
   - Account debits authorized by signers
   - Receipt action withdrawers are signers
   - No deposit or withdrawal actions are present; a root chain has no parent
8. The chain's policies pass
9. Transaction count within limits
10. State delta within limits
11. **Balance conservation (non-genesis)**:
    ```
    totalCredits + totalDeposited <= totalDebits + reward(B.height) + totalWithdrawn
    ```
12. All genesis actions valid
13. Post-state correctness

**Nexus validation does not validate child blocks.** The `children` field is
committed by the root hash, but every child is validated by its own chain
process. Root-chain canonical acceptance is not a prerequisite for child proof
verification: a root that misses the nexus target may still be a valid carrier
for a descendant. An invalid child does not affect the root candidate or a
sibling.

### 5.3 Child Chain Block Validation

A child candidate `B` is admitted with a `ChildValidationPackage` containing:

- a `ChildBlockProof` for the exact sparse directory path from the mined root to
  `B`;
- when `B` is parentless, one immediate-parent `ParentGenesisLink` authorizing
  that exact genesis CID; or
- when `B` has a same-chain predecessor whose `parentState` differs, one
  immediate-parent `ParentStateContinuityLink` for the exact old and new state
  CIDs.

The node authenticates immediate-parent facts and transports or caches them.
The child process still verifies the proof, transition, and fact fields. These
facts grant no authority over child validity or fork choice.

The vertical relationship is directional: a parent carrier commits the child in
its `children` trie, while the child commits only the carrier's `prevState` as
`parentState`. The child does not identify the carrier block. Consequently,
cross-chain acquisition asks the authenticated parent process for a proof or
parent-issued fact keyed by child CID and chain path; it never attempts to invert
`parentState` into a parent block CID. Different valid proofs may contribute
different grinds for the same child.

Let `R` be the proof root and `h = proofOfWorkHash(R)`. Validation proceeds in
this order:

1. Recompute `CID(R)` and its proof-of-work hash.
2. Require the proof path to equal the runtime path below the outer root, consume
   every supplied proof entry, and require its terminal CID to equal `CID(B)`.
3. At every vertical edge, require the nested child's `parentState` to equal the
   carrier's committed `prevState`.
4. Require `h <= B.target`. Among every content-bound block on the path whose
   target is beaten by `h`, credit the strongest target-derived quantity.
5. For genesis, require the exact parent genesis link and the complete genesis
   shape, including `nextTarget == target`.
6. For non-genesis, compare the predecessor's `parentState` with `B.parentState`.
   Equality is sufficient; otherwise require an exact continuity link proving
   transitive forward reachability through the immediate parent's connected
   accepted graph.
7. Apply the ordinary genesis or non-genesis transition rules to `B`, including
   withdrawal proofs against `B.parentState`.

Intermediate carriers need not satisfy their own target, transition, timing,
target-succession, admission, connectivity, or canonicity rules. Their exact
bytes and directory commitments are sufficient for work verification. Parent
or sibling canonicity is not part of these checks. Once this package derives a
valid work fact, a later reorganization or unavailability in another process
cannot revoke it.

### 5.4 Proof-of-Work

The canonical proof-of-work preimage uses a zero byte between variable-width
fields and a fixed-width big-endian nonce:

```text
powPrefix(B) =
    decimal(B.version)       || 0x00 ||
    rawCID(B.previousBlock)? || 0x00 ||
    rawCID(B.transactions)   || 0x00 ||
    hex(B.target)            || 0x00 ||
    hex(B.nextTarget)        || 0x00 ||
    rawCID(B.spec)           || 0x00 ||
    rawCID(B.parentState)    || 0x00 ||
    rawCID(B.prevState)      || 0x00 ||
    rawCID(B.postState)      || 0x00 ||
    rawCID(B.children)       || 0x00 ||
    decimal(B.height)        || 0x00 ||
    decimal(B.timestamp)     || 0x00

proofOfWorkHash(B) = U256(SHA256(powPrefix(B) || uint64BE(B.nonce)))
```

The absent genesis predecessor contributes the empty field between separators.

For a nested tree, only the outer root's hash `h` is evaluated:

```text
workForHash(h) = h == 0 ? U256_MAX : floor(U256_MAX / h)
```

Every level compares the same `h` with its own target. `h <= target(B)` accepts
at that level; a miss leaves the block as a carrier for descendants. A node may
apply its own root-work floor before spending resources on acquisition, but
that is a non-punitive local preference and never changes validity.

Every accepting level establishes the conservative work bound
`workForTarget(target(B))`. Because proof validity is inclusive (`hash <= target`,
so `target + 1` hashes qualify), this is `floor(2^256 / (target + 1))`, computed as
Bitcoin's chainwork `(~target / (target + 1)) + 1` in 256-bit arithmetic (edge
cases: `target 0 -> 0`, `target max -> 1`). The exclusive `U256_MAX / target` form
over-credits by up to ~2x at tiny targets — exploitable now that a miner may
select any `target <= parent.nextTarget` — so it is not used. For one root CID the
strongest verified bound is credited; a larger target is easier and is less work.

### 5.5 Target Adjustment (Retargeting)

The scheduled target is derived from the parent. A block may meet that schedule
or voluntarily exceed it — **as hard or harder, never easier**:

```
B.target <= parent.nextTarget      // smaller target = harder = more work
```

A larger (easier) target is rejected; there is no minimum-target floor. Mining
harder than scheduled only adds weight at proportional cost and cannot lower
difficulty: `B.nextTarget` is recomputed from the *actual* `B.target` (below), so
overachieving ratchets the schedule harder, never easier — self-penalizing, not
gameable. A miner wanting the easiest future difficulty therefore mines exactly at
the scheduled `parent.nextTarget`.

Genesis has no parent-derived target. The `GenesisCeremony` commits the canonical
maximum (easiest) target by convention — every hash satisfies it, so genesis needs
no grinding, block 1's schedule is `max`, and the chain self-calibrates as early
miners voluntarily mine harder. The committed value is unconstrained, but genesis
is NOT exempt from meeting it: the securing hash must satisfy `hash <= target`
like any block — the root genesis's own grind hash, or a child genesis's securing
root-grind hash (§5.1 rule 5) — so a genesis whose committed target is not met,
including `target == 0`, is invalid. Its `nextTarget` MUST equal that target. Each non-genesis block's
`nextTarget` is a **clamped, linearly-weighted retarget (LWMA)** recomputed every
block from the candidate's own ancestor-branch solve times over the most recent
`spec.retargetWindow` intervals (including the current block's own solve time), targeting
`spec.targetBlockTime` per block. More recent intervals are weighted more
heavily: for `N` intervals the `i`-th most-recent (`i = 0` is newest) gets weight
`w_i = N - i`.

```
solveTime_i    = max(0, timestamp(b_i) - timestamp(b_{i-1}))   // clamped ≥ 0
weightedActual = Σ_i (w_i · solveTime_i)
weightedTarget = spec.targetBlockTime · Σ_i w_i
proposed       = B.target · weightedActual / weightedTarget
nextTarget     = clamp(proposed,
                       B.target / spec.maxTargetChange,   // lower bound (saturating)
                       B.target · spec.maxTargetChange)   // upper bound (saturating)
```

`spec.maxTargetChange` is the chain's own committed clamp factor (default 2). The
clamp is the only bound — there is no absolute target floor. A faster-than-target
window shrinks `weightedActual`, lowering the target (harder); a slower window
raises it (easier — a larger `target` is easier to satisfy). The per-block change
is bounded to a factor of `maxTargetChange` in either direction. Validity requires
`B.nextTarget == nextTarget` exactly — there is no acceptance band. Because the
retarget reads only the candidate's committed ancestry, is bounded per block, and
`B.target` is bound at or below the parent's schedule, validity is independent of
the current fork-choice projection and a miner can only make its own block harder
(more work), never easier. This
`maxTargetChange` clamp is itself the bound on how far timestamp manipulation can
move difficulty; timestamps are further constrained by the strict-increase rule.

## 6. State Transitions

### 6.1 State Update Procedure

Given a block's `prevState` and all actions from its transactions:

```
postState = proveAndUpdateState(prevState, actions)
```

This operation:
1. Partitions actions by type into 5 groups (one per sub-state)
2. For each sub-state, concurrently:
   a. Generates Sparse Merkle proofs that current values match `prevState`
   b. Applies mutations (inserts, updates, deletions)
   c. Returns new Merkle root
3. Assembles the 5 new roots into a new `LatticeState`

### 6.2 Account State Transitions

For each `AccountAction(owner, delta)`:
- **Proof**: Verify `prevState.accountState[owner]` exists (or does not, for new accounts)
- **Update**: Apply `delta` to balance. Positive delta = credit, negative = debit.
  - If resulting balance > 0: set `accountState[owner] = newBalance`
  - If resulting balance == 0: delete `accountState[owner]`

Per-signer nonces are tracked in the same trie via `_nonce_<signerPrefix>` keys.

### 6.3 General State Transitions

For each `Action(key, oldValue, newValue)`:
- **Proof**: Verify `prevState.generalState[key] == oldValue`
- **Update**:
  - If `newValue != nil`: set `generalState[key] = newValue`
  - If `newValue == nil`: delete `generalState[key]`

### 6.4 Deposit State Transitions

For each `DepositAction`:
- **Key**: `DepositKey(demander, amountDemanded, nonce)`
- **Proof**: Verify key does NOT exist in `prevState.depositState` (insertion proof -- prevents duplicate deposits)
- **Validation**: `amountDeposited > 0` and `amountDemanded > 0`
- **Update**: `depositState[key] = amountDeposited`

For each `WithdrawalAction`:
- **Key**: `DepositKey(demander, amountDemanded, nonce)`
- **Proof**: Verify key exists in `depositState` with a nonzero value
- **Validation**: Stored `amountDeposited` must equal `amountWithdrawn`
- **Update**: Set `depositState[key] = 0` as a permanent spent marker

Withdrawals are processed before new deposits within the same block. Since
valid deposits are nonzero and insertion requires absence, the spent marker
prevents both replayed withdrawal and recreation of the same deposit identity.

### 6.5 Receipt State Transitions

For each `ReceiptAction`:
- **Key**: `ReceiptKey(directory, demander, amountDemanded, nonce)`
- **Proof**: Verify key does NOT exist in `prevState.receiptState` (insertion proof -- prevents duplicate receipts)
- **Update**: `receiptState[key] = CID(withdrawer's PublicKey)`

Receipt actions also derive account actions: the `withdrawer` is debited `amountDemanded` and the `demander` is credited `amountDemanded`.

### 6.6 Genesis State Transitions

For each `GenesisAction`:
- **Key**: `action.directory`
- **Proof**: Verify key does not exist in `prevState.genesisState` (insertion proof)
- **Update**: `genesisState[directory] = action.blockCID`

### 6.7 State Delta Accounting

Each action type reports a state delta in bytes:

| Action Type | Delta |
|---|---|
| `AccountAction` (update) | `0` |
| `Action` (insert) | `+len(key) + len(newValue)` |
| `Action` (delete) | `-(len(key) + len(oldValue))` |
| `Action` (update) | `len(newValue) - len(oldValue)` |
| `DepositAction` | `+32 + len(demander)` |
| `WithdrawalAction` | `+len(withdrawer) + len(demander) + 32` |
| `ReceiptAction` | `+len(withdrawer) + len(demander) + len(directory) + 24` |
| `GenesisAction` | `+len(blockCID) + len(directory)` |

Total delta per block must not exceed `spec.maxStateGrowth`.

## 7. Transaction Validation

### 7.1 Signature Verification

Transactions use both an outer `lattice-tx-v1:` signature prefix and an inner
versioned envelope. The inner envelope is the following newline-separated text,
with every length measured in UTF-8 bytes and no trailing newline:

```text
domain:13:lattice-tx-v1
chainPath.count:<component count>
chainPath.component:<byte length>:<component>
nonce:<decimal uint64>
bodyCID:<byte length>:<CID(tx.body)>
```

The `chainPath.component` line is repeated once per component, in order. The
exact Ed25519 message is:

```text
signaturePayload = UTF8("lattice-tx-v1:" || envelope)
```

Both domain markers are consensus bytes; there is no newline between the outer
prefix and the first envelope line.

Writers MUST sign this exact preimage. For compatibility, validators accept
either that signature or the historical body-CID input to the same outer
domain: `UTF8("lattice-tx-v1:" || CID(tx.body))`. A truly bare
`UTF8(CID(tx.body))` signature is not accepted. The body CID commits the complete
transaction body, including its absolute `chainPath` and nonce, so mutation or
cross-path replay still fails. This fallback does not accept bare public-key
encodings; signing keys remain canonical Multikey values.

For each `(publicKeyHex, signatureHex)` in an ordinary transaction's
`tx.signatures`, one accepted Ed25519 verification MUST succeed. At least one
signature is required. The set of addresses derived from the signing public
keys MUST equal the set in `tx.body.signers`; extra and missing signers are both
invalid. Genesis transaction signature fields are non-authoritative as described
in section 5.1.

### 7.2 Authorization

For each `AccountAction` where `delta < 0` (debit):
- `action.owner` MUST be in `tx.body.signers`

Credits (`delta > 0`) do not require signer authorization.

### 7.3 Deposit/Receipt/Withdrawal Authorization

- **DepositAction**: `demander` MUST be in `tx.body.signers`
- **ReceiptAction**: `withdrawer` MUST be in `tx.body.signers`
- **WithdrawalAction**: `withdrawer` MUST be in `tx.body.signers`; requires proof of corresponding deposit in `prevState.depositState` AND proof of receipt in `parentState.receiptState`

### 7.4 WASM Policies

Chain policies are content-addressed validation modules referenced by `ChainSpec.wasmPolicies`. In ABI version 1, policies are implemented as WASM modules. A policy declares a scope (`transaction` or `action`), ABI version, module CID, and exported entrypoint. The host passes a versioned canonical binary policy context containing the chain spec, chain path, and the transaction/action under validation. The policy returns `1` to accept and any other value to reject.

Genesis validates every configured policy reference and entrypoint, even when
genesis contains no transaction or Action to exercise that scope. This prevents
an immutable spec from admitting a latent missing, oversized, nondeterministic,
or malformed module that would fail only after deployment.

Policy modules MUST export:

| Export | Type | Purpose |
|---|---|---|
| `memory` | WebAssembly memory | Host writes the policy context bytes here |
| `lattice_alloc` | `(i32) -> i32` | Allocates `len` bytes and returns the destination pointer |
| entrypoint | `(i32, i32) -> i32` | Receives `(ptr, len)` and returns `1` to accept |

The policy context byte layout is:

| Field | Encoding |
|---|---|
| Magic | ASCII `LWPCTX` |
| Context encoding version | `uint16`, big-endian |
| Policy ABI version | `uint16`, big-endian |
| Scope | `uint8`; `0` = transaction, `1` = action |
| Chain spec | `uint32` byte length, then DAG-CBOR `ChainSpec` bytes |
| Chain path | `uint32` item count, then each path component as `uint32` byte length + UTF-8 bytes |
| Transaction | `uint8` presence tag; if `1`, `uint32` byte length + DAG-CBOR `TransactionBody` bytes |
| Action | `uint8` presence tag; if `1`, `uint32` byte length + DAG-CBOR `Action` bytes |
| Action index | `uint8` presence tag; if `1`, `uint64` index, big-endian |

### 7.5 Context-Specific Rules

| Context | Deposits | Receipts | Withdrawals |
|---|---|---|---|
| Genesis block | No | No | No |
| Non-genesis Nexus block | No | Yes | No |
| Non-genesis child chain | Yes | Yes | Yes (requires parent receipt proof) |

A non-root chain may be both a child of one chain and a parent of another. Its
deposits and withdrawals relate to its own parent; its receipts may serve its
children.

## 8. Cross-Chain Transfer Protocol

The cross-chain transfer protocol enables trustless value movement between
parent and child chains in the hierarchy. Consensus requires signatures and
Sparse Merkle proofs against state roots committed in blocks. Providers may
relay the required bytes, but no bridge, federation, or relayer has validity
authority.

### 8.1 Protocol Phases

A cross-chain transfer proceeds in three phases across a parent-child chain pair:

**Phase 1 -- Deposit (child chain):**
A signed child transaction includes a `DepositAction`. This locks
`amountDeposited` and records a demand: `demander` should receive
`amountDemanded` on the parent chain. The demander MUST sign. Block-wide balance
conservation funds aggregate deposits; consensus does not require a
transaction-local debit for this deposit. The deposit is stored in the child's
`depositState` via an insertion proof.

**Phase 2 -- Receipt (parent chain):**
A signed parent transaction includes a `ReceiptAction`. The parent validates
only its own authorized payment: the withdrawer MUST sign, the receipt key MUST
be absent, and the derived account actions debit `amountDemanded` from the
`withdrawer` and credit it to the `demander`. The parent does NOT verify the
child deposit when admitting the receipt.

**Phase 3 -- Withdrawal (child chain):**
The child proves both the matching nonzero deposit in
`prevState.depositState` and the matching withdrawer in
`parentState.receiptState`. For a child nested beneath a carrier,
`parentState` MUST equal that carrier's `prevState`; the receipt must therefore
already exist in the carrier's entering state. A `WithdrawalAction` replaces
the deposit value with a permanent zero-valued spent marker and adds
`amountWithdrawn` to the block-wide credit budget. It does not create an account
credit automatically; any recipient credit MUST be an explicit `AccountAction`.
The stored `amountDeposited` MUST exactly match `amountWithdrawn`.

A parent receipt without a matching child deposit cannot authorize child value,
because withdrawal requires both proofs. It is not cost-free: the signed parent
payment and receipt-state insertion still execute.

### 8.2 Balance Conservation with Cross-Chain Transfers

For any block at index `i`:

```
totalCredits + totalDeposited <= totalDebits + reward(i) + totalWithdrawn
```

Where:
- `totalCredits` = sum of all positive account action deltas
- `totalDebits` = sum of all negative account action deltas (absolute values)
- `totalDeposited` = sum of all `DepositAction.amountDeposited` values
- `totalWithdrawn` = sum of all `WithdrawalAction.amountWithdrawn` values

The transaction `fee` does not independently expand this budget. A block may
claim at most the credits funded by its actual account debits, withdrawals, and
subsidy. Any unused budget is unclaimed and therefore burned; the block subsidy
`reward(i)` remains the only minting source.

Deposits reduce the block-wide available budget by locking value in deposit
state. Withdrawals add the matching locked value back to that budget; explicit
account actions determine any credited recipients.

### 8.3 Security Properties

**No value creation**: The balance equation guarantees that credits cannot exceed debits plus block reward plus net withdrawal flow.

**No double-deposit**: Deposit keys are unique in deposit state (insertion proof prevents duplicate deposits with the same nonce/demander/amount).

**No double-withdrawal**: Withdrawal leaves a permanent zero-valued marker. A
second withdrawal fails the nonzero amount check, and insertion cannot recreate
the same deposit key.

**No over-withdrawal**: The stored `amountDeposited` must exactly match the
declared `amountWithdrawn`. A larger declaration fails the state proof.

**No forged parent state**: A withdrawal accepts only a receipt proven in the
carrier's committed `prevState`, supplied as `parentState`, after the carrier
and sparse proof path pass consensus validation. Receipt admission itself does
not assert that a child deposit exists.

**Cross-chain replay protection**: Each transaction declares a `chainPath` targeting the exact chain hierarchy path. Transactions are rejected if the `chainPath` doesn't match the validating chain.

## 9. Consensus

### 9.1 Verified Work Contributions

The root CID identifies one physical grind. Every level `B_i` that accepts its
root hash proves a conservative lower bound for that same identity:

```text
contribution.id   = rootCID
contribution.work = workForTarget(target(B_i))   // floor(2^256 / (target + 1))
```

Grind identity is immutable. Its credited quantity is the maximum of all verified
accepted-target bounds observed for that identity, so it can strengthen but never
decrease. Its sparse proof has exactly one terminal block in each chain it
reaches. One block may be secured by many distinct grinds, but one grind MUST NOT
be placed at multiple blocks in the same chain. Same-chain ancestry makes a
descendant's work support its ancestors without creating more locations. The
logical location key is `(blockHash, grindID)`, while the immutable fact ID also
includes the observed work. Weaker or equal replay at the same location is a
duplicate. A stronger observation at that location remains durable. A conflicting
location is rejected atomically.

Consensus ingress stores each CID identity in its unique canonical text spelling.
An alternate multibase spelling is rejected before it can create another map key;
this identity-encoding rule is separate from branch canonicity, which never
determines whether accepted work contributes.

Consensus comparisons use a `WorkMeasure`, conceptually `Map<RootCID, U256>`.
Measure union takes the maximum value per root CID. `total(measure)` is the exact
sum of the resulting distinct values. This deduplicates repeated observations
and recursive inheritance of the same physical grind, while independent grinds
always sum. A disconnected staged location remains durable but has no segment
route until its same-chain predecessor attaches.

### 9.2 Chain State and Hierarchical GHOST

Fork-choice state contains only one chain's accepted graph:

```text
accepted blocks + same-chain predecessor edges
local unique grind locations + strongest verified quantities
one derived canonical projection
```

For each block, `own(B)` is the measure formed by every proof-derived grind
located at that block:

```text
prefix(B) = own(B) union prefix(parent(B))

effectiveSubtree(B) = own(B)
                      union each effectiveSubtree(C)
                            for C in sameChainChildren(B)

cumulativeWork(B) = total(prefix(B))
trueCumWork(B)     = total(effectiveSubtree(B))
```

Measure union occurs before totaling. Repeated observations of one grind at the
same location therefore contribute once.
Implementations may cache local totals, but the accepted graph and unique
proof-derived work facts remain authoritative.

`WorkSum` is an exact growable unsigned integer. Individual contributions remain
`U256`, but their sums must not wrap or saturate because either behavior can
erase the strict ordering between two branches.

### 9.3 Admission

Every external candidate enters one admission procedure:

1. capture of one explicit `ValidationContext` for the attempt;
2. root CID and proof-of-work hash verification before child resolution;
3. targeted resolution of the candidate and required package;
4. complete structural path validation before requesting cross-chain evidence;
5. exact-path, vertical state binding, chain-target, and immediate-parent
   state-continuity checks;
6. deterministic genesis or non-genesis state-transition validation;
7. targeted storage of verified local content and materialized state;
8. atomic durability of one immutable accepted-fact batch; and
9. application of that exact batch through the reducer used by recovery.

Durability MUST precede visible graph mutation. Live admission MUST NOT
re-resolve or rebuild the batch after durability, and recovery MUST apply the
same immutable facts through the same reducer. Identical replay is idempotent;
conflicting immutable metadata is rejected. Storage or durability failure leaves
the accepted graph unchanged, and genesis bootstrap exposes no runtime until its
facts are durable and restored.

A current-level target miss returns a carrier result without executing its
transition, inserting it, or implicitly retaining it for this chain. A node may
explicitly retain a carrier or an exact child-link path as availability policy;
Lattice does not enumerate an attacker-sized child trie. Unresolved same-chain
predecessors (absent or accepted-but-unconnected) are derived from the accepted
graph, including after recovery, and must enter this same admission boundary. A
target miss never triggers predecessor backfill because connectivity cannot make
that grind satisfy the current chain's target. A target-hit accepted, duplicate,
or rejected candidate may expose the exact typed predecessor requirement so the
node can complete ordinary chain admission and issuer promotion. This does not
claim a predecessor body is unavailable. Missing cross-chain input instead
identifies the child proof, immediate-parent state-continuity fact, or
immediate-parent genesis fact that the node must obtain from an authenticated
source. For a non-genesis candidate with predecessor `P`, continuity is
reflexive when `P.parentState == B.parentState`; otherwise the immediate
parent's connected accepted graph must contain a transitive same-chain state
path from `P.parentState` to `B.parentState`. Parent canonicity is irrelevant.
`parentState` is a state CID, not a parent-block lookup key. Consensus derives
no relationship by inversion. A target-hit candidate can likewise be rejected
by its local admission rules while still proving real work for a descendant;
carrier validity and securing-work validity are orthogonal.

### 9.4 Fork Choice and Reorganization

At each fork, GHOST compares the competing segments at their same-chain child
bases. The segment with greatest effective `trueCumWork` wins. Equal
work compares the canonical CID bytes of the segment bases; the
lexicographically smaller CID wins. `nextTarget` and the segment tips are not
comparators. The same rule applies to competing genesis roots, so arrival and
replay order cannot change fork choice. The deliberate security tradeoff of
this grindable deterministic tie-break is quantified in the
[TRE-134 adversarial report](consensus/tre-134-adversarial-report.md).

When a branch wins, only this chain's canonical indexes change. The emitted
canonical delta identifies the new tip and exact added and removed blocks. This
is a chain-local reorganization; Lattice sends no commands to parent, child, or
sibling processes.

Adding a grind location or strengthening a verified grind quantity may make a
subtree strictly heavier and trigger this same reorganization procedure.
Neither replays the block's state transition.

### 9.5 Cross-Chain Evidence Independence

Work and parent-state authority are separate.

A `ChildBlockProof` proves work directly from content-addressed bytes. The root
grind must beat the terminal child's target and resolve uniquely to that child
through the sparse directory path. Intermediate carriers need not be admitted,
connected, valid, or canonical on their own chains. Along one proof, the
contribution is the maximum target-derived quantity beaten by that root hash;
the terminal target must be beaten. The terminal child receives that ordinary
work fact only after it is accepted and connected.

The immediate parent authenticates only state continuity and child-genesis
authorization. A continuity fact is bound to the exact parent path and
`(fromStateCID, toStateCID)` pair. It proves transitive reachability through the
parent's connected accepted graph, not parent canonicity and not a work total.
The fact is immutable and may be relayed independently of its original
transport.

The parent receives no child topology, validity, work, attachment, recovery
state, or canonical-tip command. Moving only a parent's canonical pointer
changes neither previously verified work nor continuity.

### 9.6 Ingress Equivalence

Gossip, sync, mining, parent extraction, and sibling relay differ only in
acquisition. Every external candidate enters the admission procedure in section
9.3. Recovery instead replays already-authenticated durable facts through the
same graph mutation and fork-choice logic; it does not treat a local fact log as
new wire evidence. No ingress path may replace the chain directly or inject a
trusted canonical projection.

### 9.7 Consensus Graph and Node State Lifecycle

Lattice retains the complete accepted consensus graph and every verified local
grind location. It performs no age-, depth-, body-, or state-retention pruning
of consensus inputs.

State execution may derive local lifecycle metadata, but that metadata is not a
block commitment or a second cross-volume relationship index. The node decides
whether to retain it and owns CID counts, pinning, materialized-state retention,
projections, archival, and garbage collection.

### 9.8 Persistence

The node durably preserves every accepted block's consensus fields, every
distinct location fact and strengthening observation, and a monotone mutation
order. A crash may occur after durable staging and before in-memory mutation;
recovery therefore replays those already-authenticated facts idempotently through
Lattice's graph and fork-choice reducer. The node does not reconstruct weights,
ancestry, or canonical choice itself.

Lattice exposes staged-fact replay as its recovery authority. A serialized
`ChainState` projection is neither a public recovery input nor protocol truth;
diagnostic projections, if retained by tests or tooling, cannot replace replay.

Restoration rejects malformed facts, reconstructs exact measures, and
reprojects canonicality. A persisted tip is a derived cache, not protocol
truth. Filesystem layout, payload retention, and format migration belong to the
node.

## 10. Economic Model

### 10.1 Reward Schedule

```
rewardAtBlock(height) = initialReward >> ((height + premine) / halvingInterval)
```

The reward halves every `halvingInterval` blocks. After all halvings complete, the reward reaches 0.

### 10.2 Premine

The premine represents blocks conceptually "mined" by chain creators before public mining begins. The premine amount is the sum of the rewards of those `premine` blocks at the front of the schedule:

```
premineAmount = sum(initialReward >> (i / halvingInterval) for i in 0..<premine)
```

When `premine < halvingInterval` this reduces to `premine * initialReward` (all premined blocks fall in the first reward epoch). Premine is **not** capped: it may span multiple halving epochs, up to a fully-premined chain whose entire emission is front-loaded and which mines zero ongoing block reward. Because emission terminates once the reward reaches 0, `premineAmount` is inherently bounded by the chain's total lifetime supply — a chain cannot premine more coins than it will ever emit.

Public mining starts at block index 0, but the halving schedule treats it as block `premine` (`rewardAtBlock` shifts the curve forward by `premine`). When `premine < halvingInterval`, the first public halving occurs at block `halvingInterval - premine`.

### 10.3 Total Supply

```
totalRewards(n) = sum(rewardAtBlock(i) for i in 0..<n)
```

Computed efficiently via geometric series in O(log n) time by iterating through halving periods.

### 10.4 ChainSpec Validity

A `ChainSpec` is valid if:

```
maxNumberOfTransactionsPerBlock > 0
maxStateGrowth > 0
maxBlockSize > 0
targetBlockTime > 0
initialReward > 0
halvingInterval > 0
retargetWindow > 0
```

`premine` is unconstrained (any `uint64`): it is a block-count offset into the emission schedule and the reward math handles any size, supply-bounded, without overflow. Premine is governed by transparency (it is fixed in the content-addressed genesis spec and provable via `premineAmount`), not by a protocol ceiling.

Before decoding a previously unknown `ChainSpec`, a node may apply its own byte
ceiling. That decision is local capacity policy, not `ChainSpec` invalidity.

## 11. Cryptographic Primitives

| Primitive | Algorithm | Usage |
|---|---|---|
| Hash | SHA-256 | Block hashes, Merkle trees, addresses, proof-of-work |
| Signature | Ed25519 | Transaction authorization |
| Content addressing | CID (DAG-CBOR + SHA-256) | All data structure references |
| Sparse proofs | Sparse Merkle Tree | State inclusion/exclusion proofs |

### 11.1 Address Derivation

```
address(publicKey) = CID(PublicKey(key: publicKey))
```

An address is the Content Identifier (DAG-CBOR + SHA-256) of the `PublicKey` struct wrapping the key. Public keys are encoded as Multikey, and Ed25519 is the key type used for signing.

## 12. Invariants

The following invariants MUST hold at all times:

### 12.1 State Continuity

For any consecutive blocks `B[i]` and `B[i+1]` on the same chain:

```
B[i].postState == B[i+1].prevState
```

### 12.2 Balance Conservation

For any valid block, value is conserved as a **non-creation bound**:

```
totalCredits + totalDeposited <= totalDebits + reward + totalWithdrawn
```

No credits may exceed the available budget. Unclaimed budget is burned; the block
subsidy `reward` is the only minting source. A declared transaction fee does not
independently create spendable budget. Deposits lock balance (move it into deposit
state); withdrawals return it to the block-wide credit budget.

### 12.3 Consensus Invariants

1. The chain tip is always on the main chain
2. The chain tip block always exists in the block map
3. Exactly one accepted genesis root anchors the selected main-chain path
4. Main chain blocks form a connected path from genesis to tip
5. A canonical delta's added and removed block sets are disjoint
6. One validator process owns one absolute path and cannot mutate another chain

### 12.4 Cross-Chain Transfer Invariants

1. Each `DepositKey` is unique in deposit state (insertion proof prevents duplicate deposits)
2. Each `ReceiptKey` is unique in receipt state (insertion proof prevents duplicate receipts)
3. A withdrawal requires the corresponding deposit to contain its original
   nonzero amount
4. A withdrawal requires the corresponding receipt to exist in `parentState.receiptState` (mutation proof)
5. The stored `amountDeposited` must exactly match the declared `amountWithdrawn` (prevents over-withdrawal)
6. Withdrawal replaces the deposit value with a permanent spent marker

### 12.5 Fork Choice Invariants

1. Every level evaluates the same root hash against its own target
2. Directory-path work verification is independent of carrier validity,
   admission, connectivity, and canonicity
3. A grind has exactly one terminal location per chain and is deduplicated by
   root CID across observations at that location;
   its credited quantity is the strongest verified accepted-target bound
4. Work measures union by grind ID before totaling, so shared work is counted once
   while distinct grinds sum
5. Effective `trueCumWork` contains only connected, accepted same-chain
   locations derived from verified proof bytes
6. Equal-work segments prefer the lexicographically smaller canonical base CID;
   `nextTarget` and segment tips are not comparators
7. Parent canonicity alone cannot change child validity, weight, or fork choice
8. A non-genesis child keeps the same parent-state reference or moves
   transitively forward through the immediate parent's connected accepted graph
9. Lattice never prunes accepted graph or verified local-work facts
10. There is no finality threshold; a strictly heavier effective subtree may reorg at any depth
11. Every successful consensus mutation has a monotonically increasing revision
12. One explicit validation-time context governs one admission attempt

## 13. Constants

| Constant | Value | Description |
|---|---|---|
| `maxTargetChange` | 2 (default) | Per-block target adjustment clamp factor; chain-committed via `ChainSpec`, a chain may commit its own. Not a protocol-wide constant. |
| `totalExponent` | 64 | Bit width of the reward/halving system |
