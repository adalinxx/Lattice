# Lattice Protocol Specification

Version 0.1.0

## 1. Overview

Lattice is a hierarchical proof-of-work protocol, not a single blockchain. Every chain may commit child blocks, and each child may do the same. One mined root therefore commits a nested block tree. The **nexus** is the first outermost chain -- the entry point from outside the hierarchy; other outermost chains may also exist. Descendants inherit identity-bearing work from accepted ancestor graphs: the root CID identifies one grind, its strongest verified accepted-target bound fixes its quantity, and arbitrary coverage never multiplies it. Value moves across chains through a three-phase **deposit/receipt/withdrawal** protocol.

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

**Protocol constants:**

```
maxTargetChange = 2
```

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
GenesisAction = (directory: string, blockCID: CID(Block))
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

### 3.8 Consensus Types

#### BlockMeta

```
BlockMeta = (
    blockHash:          CID,
    parentBlockHash:    CID?,
    blockHeight:        U64,
    childBlockHashes:   [string],
    workContributions:  Map<RootCID, VerifiedWorkContribution>,
    cumulativeWork:     WorkSum,
    subtreeWeight:      WorkSum
)
```

`BlockMeta` contains consensus graph and fork-choice state only. It does not
retain materialized-state lifecycle metadata.

#### Admission facts and chain commits

```
ChainAdmissionFact = ChainBlockFact | ChainWorkFact

ChainAdmissionBatch = (
    facts: [ChainAdmissionFact]
)

ChainCommit = (
    revision:               U64,
    tipHash:                BlockHash,
    mainChainBlocksAdded:   Map<BlockHash, BlockIndex>,
    mainChainBlocksRemoved: Set<BlockHash>,
    canonicalChanged:       Bool  // derived from the canonical delta
)
```

`ChainBlockFact` records one immutable admitted block and its derived
`StateDiff`. `ChainWorkFact` records one immutable verified observation, identified
by `(blockHash, grindID, work)`. Its logical coverage key is
`(blockHash, grindID)`. The same grind may cover many blocks and many grinds may
cover one block. Observations join by maximum work and coverage-set union; weaker
or equal replay is idempotent. A batch stages the initial block and work facts
atomically. `ChainCommit` orders successful consensus mutations; a nonempty
canonical delta is the output of a chain-local reorganization.

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
`ChainSpec`. A chain's canonical identity is its full **path** from the outermost
chain, e.g. `Nexus/Payments`. Siblings under different parents may reuse a
directory because their full paths differ.

### 4.2 Chain Level

Each chain process is managed by one `ChainLevel`:

```
ChainLevel = (
    context: ChainRuntimeContext, // absolute path + minimum root work
    chain:   ChainState            // consensus for this chain only
)
```

`ChainLevel` contains no child runtimes. A target miss yields a carrier-only
result. The node may pass the corresponding sparse proof to a separately
supervised descendant process, which performs its own admission.

## 5. Block Validation

### 5.1 Genesis Block Validation

A genesis block `B` is valid if and only if ALL of the following hold:

1. `B.previousBlock == nil`
2. `B.height == 0`
3. `B.timestamp <= validationContext.now + 2 hours`, where the admission
   attempt captures `validationContext.now` once
4. `B.prevState == CID(emptyState())`
5. `B.target >= minimumTarget` and `B.nextTarget == B.target`
6. All transactions in `B.transactions` are fully resolvable
7. For each transaction `tx`: `tx.validateTransactionForGenesis()` returns true
   - Signatures are valid Ed25519 signatures over `CID(tx.body)`
   - Signers match signature public keys
   - Account debits are authorized by signers
   - No withdrawal actions present
8. Every transaction's `chainPath` equals the runtime's absolute path
9. All transaction bodies pass the chain's policies
10. `|transactions| <= spec.maxNumberOfTransactionsPerBlock`
11. `sum(stateDelta(tx) for tx in transactions) <= spec.maxStateGrowth`
12. **Balance conservation (genesis)**:
    ```
    totalCredits + totalDeposited <= premineAmount
    ```
13. Every `GenesisAction` has a non-empty separator-free directory and non-empty
    genesis block CID. The child process validates that block's content.
14. **Post-state correctness**: Applying all actions to `prevState` (empty
    state) produces `postState`:
    ```
    proveAndUpdateState(prevState, allActions) == postState
    ```

### 5.2 Nexus Block Validation

A non-genesis nexus block `B` with previous block `P` is valid if and only if:

1. `P` is resolvable
2. `B.spec == P.spec` (chain spec continuity)
3. `B.prevState == P.postState` (state continuity)
4. `B.height == P.height + 1`
5. `P.timestamp < B.timestamp <= validationContext.now + 2 hours`, and
   `B.timestamp > MedianTimePast(11)` when that window is available. The
   attempt captures `validationContext.now` once.
6. `B.target == P.nextTarget`, and `B.nextTarget` equals the clamped
   proportional retarget of section 5.5
7. All transactions pass `validateTransactionForNexus()`:
   - Signatures valid (Ed25519 over `CID(tx.body)`)
   - Signers match signature public keys
   - Account debits authorized by signers
   - Receipt action withdrawers are signers
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
verification: after the setup-wide floor passes, a root that misses the nexus
target may still be a valid carrier for a descendant. An invalid child does not
affect the root candidate or a sibling.

### 5.3 Child Chain Block Validation

A child candidate `B` is admitted with a `ChildValidationPackage` containing:

- a `ChildBlockProof` for the exact sparse path from the mined root to `B`; and
- a `ParentContinuityLink` for each non-genesis carrier on that path; and
- a `ParentGenesisLink` for every parentless child-chain genesis encountered on
  that path, proving that validated parent state anchored that exact genesis CID.

The Lattice process responsible for a parent path issues these immutable facts
after validating its own chain. The node authenticates that process and
transports or caches the facts. The child process binds each fact to the exact
path and content-addressed successor or genesis CID. The successor CID already
commits its predecessor, spec, and state references. The fact grants no
authority over child validity or fork choice.

The vertical relationship is directional: a parent carrier commits the child in
its `children` trie, while the child commits only the carrier's `prevState` as
`parentState`. The child does not identify the carrier block. Consequently,
cross-chain acquisition asks the authenticated parent process for a proof or
parent-issued fact keyed by child CID and chain path; it never attempts to invert
`parentState` into a parent block CID. Different valid proofs may contribute
different grinds for the same child.

Let `R` be the proof root and `h = proofOfWorkHash(R)`. Validation proceeds in
this order:

1. Recompute `CID(R)` and require `workForHash(h) >= minimumRootWork`.
2. Require the proof path to equal the runtime path below the outer root, consume
   every supplied proof entry, and require its terminal CID to equal `CID(B)`.
   Reject any locally impossible parentless carrier shape before requesting
   parent-issued evidence. If that level accepts the grind, also enforce the
   complete genesis shape, including `nextTarget == target`.
3. For every non-genesis carrier `Q` above `B`, require its parent-issued
   continuity link. For every parentless carrier below the setup root, and for
   `B` itself when it is a genesis block, require its exact parent-issued genesis
   link. Every supplied link must be consumed exactly once.
   The issuing process validates version, spec, `prevState`, height, target
   succession, and a strictly increasing timestamp against `Q`'s own same-chain
   predecessor. MTP/future drift, state execution, and `Q`'s proposed
   `nextTarget` are admission rules only if `Q`'s chain accepts the grind; they
   do not become dependencies of descendant validity.
4. At every vertical edge, require the nested child's `parentState` to equal the
   carrier's committed `prevState`.
5. Compare the same hash `h` with each level's target. A miss makes that level a
   carrier only; verification continues toward descendants.
6. Require `h <= B.target` for admission into this chain.
7. Apply the ordinary genesis or non-genesis transition rules to `B`, including
   withdrawal proofs against `B.parentState`.

Parent or sibling canonicity is not part of these checks. Once this package
derives a valid work fact, a later reorganization or unavailability in another
process cannot revoke it.

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

For a nested tree, only the outer root's hash `h` is evaluated. Before any chain
target, admission requires the setup-wide gate:

```text
workForHash(h) = h == 0 ? U256_MAX : floor(U256_MAX / h)
workForHash(h) >= minimumRootWork
```

Failure rejects the whole tree. After that gate, every level compares the same
`h` with its own target. `h <= target(B)` accepts at that level; a miss leaves the
block as a carrier for descendants.

Every accepting level establishes the conservative work bound
`floor(U256_MAX / target(B))`. For one root CID, the strongest verified bound is
credited. A larger target is easier and represents less credited work.

### 5.5 Target Adjustment (Retargeting)

The target is **derived from the parent, not chosen by the miner**. Every block
MUST satisfy the binding rule:

```
B.target == parent.nextTarget
```

Genesis has no parent-derived target: its configured target is committed in the
block and its `nextTarget` MUST equal that target. Each non-genesis block's
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
proposed       = parent.target · weightedActual / weightedTarget
nextTarget     = clamp(proposed,
                       parent.target / maxTargetChange,    // lower bound, floored at minimumTarget
                       parent.target · maxTargetChange)     // upper bound (saturating)
```

The result is never below `minimumTarget`. A faster-than-target window shrinks
`weightedActual`, lowering the target (harder); a slower window raises it
(easier — a larger `target` is easier to satisfy). The per-block change is bounded
to a factor of `maxTargetChange` in either direction. Validity requires
`B.nextTarget == nextTarget` exactly — there is no acceptance band. Because the
retarget reads only the candidate's committed ancestry, is bounded per block,
and `B.target` is bound to the parent, validity is independent of the current
fork-choice projection and a miner cannot choose its own target. Timestamp
influence is bounded separately by the MTP and future-drift rules.

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

For each `(publicKeyHex, signatureHex)` in `tx.signatures`:

```
valid = Ed25519_Verify(
    message:   CID(tx.body),
    signature: signatureHex,
    publicKey: publicKeyHex
)
```

All signatures must verify. All signers listed in `tx.body.signers` must have corresponding valid signatures.

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
| Genesis | Yes | No | No |
| Nexus | No | Yes (from child chains) | No |
| Child chain | Yes | No | Yes (requires parent receipt proof) |

## 8. Cross-Chain Transfer Protocol

The cross-chain transfer protocol enables trustless value movement between parent and child chains in the hierarchy. All verification is performed via Sparse Merkle proofs against state roots committed in blocks. No bridges, federations, or relayers are required.

### 8.1 Protocol Phases

A cross-chain transfer proceeds in three phases across a parent-child chain pair:

**Phase 1 -- Deposit (child chain):**
A user includes a `DepositAction` in a transaction on the child chain. This locks `amountDeposited` tokens and records a demand: `demander` should receive `amountDemanded` tokens on the parent chain. The deposit is stored in the child's `depositState` via an insertion proof.

**Phase 2 -- Receipt (parent chain):**
The parent chain verifies the deposit exists by checking the child's state root (committed in the child block embedded in the parent block). A `ReceiptAction` records the receipt in the parent's `receiptState` and derives two account actions: debiting `amountDemanded` from the `withdrawer` and crediting `amountDemanded` to the `demander`.

**Phase 3 -- Withdrawal (child chain):**
The child chain verifies a receipt exists on the parent by checking `parentState.receiptState`. A `WithdrawalAction` replaces the deposit value with a permanent zero-valued spent marker and releases `amountWithdrawn` back to the `withdrawer`. The stored nonzero `amountDeposited` must exactly match `amountWithdrawn`.

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

Deposits reduce the available balance (tokens locked in deposit state). Withdrawals increase it (tokens released from deposit state).

### 8.3 Security Properties

**No value creation**: The balance equation guarantees that credits cannot exceed debits plus block reward plus net withdrawal flow.

**No double-deposit**: Deposit keys are unique in deposit state (insertion proof prevents duplicate deposits with the same nonce/demander/amount).

**No double-withdrawal**: Withdrawal leaves a permanent zero-valued marker. A
second withdrawal fails the nonzero amount check, and insertion cannot recreate
the same deposit key.

**No over-withdrawal**: The stored `amountDeposited` must exactly match the declared `amountWithdrawn`. If a withdrawer claims more than was deposited, the state proof rejects the transaction.

**No forged receipts**: Receipt verification uses `parentState.receiptState`, which is committed in the child block's proof-of-work hash. An attacker cannot fabricate a receipt without controlling the parent chain's hashrate.

**Cross-chain replay protection**: Each transaction declares a `chainPath` targeting the exact chain hierarchy path. Transactions are rejected if the `chainPath` doesn't match the validating chain.

## 9. Consensus

### 9.1 Verified Work Contributions

The root CID identifies one physical grind. Every level `B_i` that accepts its
root hash proves a conservative lower bound for that same identity:

```text
contribution.id   = rootCID
contribution.work = floor(U256_MAX / target(B_i))
```

Grind identity is immutable. Its credited quantity is the maximum of all verified
accepted-target bounds observed for that identity, so it can strengthen but never
decrease. Coverage is independent and append-only: one grind may secure any
number of blocks or content objects, and one block may be secured by many distinct
grinds. The logical coverage key is `(blockHash, grindID)`, while the immutable
fact ID also includes the observed work. Weaker or equal replay is a duplicate;
a stronger verified observation remains separately durable and updates the one
grind quantity across all of its coverage.

Consensus comparisons use a `WorkMeasure`, conceptually `Map<RootCID, U256>`.
Measure union takes the maximum value per root CID. `total(measure)` is the exact
sum of the resulting distinct values. Therefore one physical grind is counted
once no matter how much data, how many blocks, or how many hierarchy levels it
secures, while independent grinds always sum.

The strongest known quantity for a root CID is normalized across every local and
inherited coverage before any competing subtree is compared. Shared work is
therefore neutral even when its strongest observation arrived on only one side.

### 9.2 Chain State and Hierarchical GHOST

Each `ChainState` contains only one chain's accepted graph:

```text
ChainState = actor {
    chainTip:             string
    mainChainHashes:      Set<string>
    indexToBlockHash:     Map<uint64, Set<string>>
    hashToBlock:          Map<string, BlockMeta>
    inheritedWorkProvider: (() -> InheritedWorkSnapshot)?
}
```

For each block, `own(B)` is the measure formed by all local grind coverage on that
block. `inherited(B)` is the retained immediate-parent measure securing it:

```text
prefix(B) = own(B) union prefix(parent(B))

effectiveSubtree(B) = own(B)
                      union inherited(B)
                      union each effectiveSubtree(C)
                            for C in sameChainChildren(B)

cumulativeWork(B) = total(prefix(B))
trueCumWork(B)     = total(effectiveSubtree(B))
```

Measure union occurs before totaling. A grind covering an ancestor and descendant,
both sibling subtrees, or both local and inherited inputs therefore contributes
once to that comparison. `BlockMeta.cumulativeWork` and `subtreeWeight` cache
local-only totals for persistence and queries. Fork choice captures one inherited
snapshot and computes `trueCumWork` from the effective measures.

`WorkSum` is an exact growable unsigned integer. Individual contributions remain
`U256`, but their sums must not wrap or saturate because either behavior can
erase the strict ordering between two branches.

### 9.3 Admission

The root and child overloads of `ChainLevel.bootstrap`, together with
`ChainLevel.admitBlockHeaderChainLocal`, are the public consensus boundaries.
Admission performs:

1. capture of one explicit `ValidationContext` for the attempt;
2. root CID and setup-wide root-work-floor validation before child resolution;
3. targeted resolution of the candidate and required package;
4. complete structural path validation before requesting cross-chain evidence;
5. exact-path, carrier-continuity, and chain-target checks;
6. deterministic genesis or non-genesis state-transition validation;
7. targeted storage of verified local block content and materialized state;
8. node-owned atomic staging of one immutable `ChainAdmissionBatch`; and
9. application of that exact batch through the same reducer used by recovery,
   returning a revisioned `ChainCommit`.

The staged batch is the durable admission receipt. Live admission never
re-resolves or re-stages it after another local mutation; recovery applies the
same fact through the same reducer. Reapplying an identical batch is idempotent,
while conflicting immutable metadata is rejected. A storage or staging failure
leaves the accepted graph unchanged, and bootstrap exposes no runtime until the
genesis batch has been stored, staged, and restored.

Before staging an existing runtime mutation, Lattice reserves capacity for one
distinct `U64` commit revision. Other mutations cannot consume that slot while
the node stages the batch. Exhaustion returns `revisionExhausted` without
staging. The stage callback is atomic: returning means the complete batch is
durable, while throwing means none of its facts became visible.

A current-level target miss returns a carrier result without executing its
transition, inserting it, or implicitly retaining it for this chain. A node may
explicitly retain a carrier or an exact child-link path as availability policy;
Lattice does not enumerate an attacker-sized child trie. Missing same-chain
predecessors are derived from the accepted graph, including after recovery, and
must enter this same admission boundary. This does not claim a predecessor body
is unavailable.
Missing cross-chain input instead returns a `CrossChainEvidenceRequirement`
identifying the child proof, parent continuity fact, or parent genesis fact the
node must obtain from the authenticated parent process. `parentState` is a state
CID, not a parent-block lookup key. Consensus fetches neither relationship
itself.

### 9.4 Fork Choice and Reorganization

At each fork, GHOST compares the competing segments at their same-chain child
bases. The segment with greatest effective `trueCumWork` wins. Equal
work compares the canonical CID bytes of the segment bases; the
lexicographically smaller CID wins. `nextTarget` and the segment tips are not
comparators. The same rule applies to competing genesis roots, so arrival and
replay order cannot change fork choice. The deliberate security tradeoff of
this grindable deterministic tie-break is quantified in the
[TRE-134 adversarial report](consensus/tre-134-adversarial-report.md).

When a branch wins, `ChainState` updates only this chain's canonical indexes and
returns a revisioned `ChainCommit` describing the new tip and exact added and
removed blocks. This canonical delta represents a chain-local reorganization.
Lattice sends no commands to parent, child, or sibling processes.

Adding grind coverage, strengthening a verified grind quantity, or receiving a
newer inherited-work snapshot may make a subtree strictly heavier and trigger
this same reorganization procedure. None replays the block's state transition.

### 9.5 Cross-Chain Evidence Independence

The sparse proof and authenticated parent-issued continuity/genesis facts derive
local child coverage. In addition, each chain may consume one live rolled-up view
from its immediate parent. The parent exports securing `WorkMeasure`s from its
complete accepted graph, including noncanonical branches. The node authenticates
and routes that process, derives child-block bindings from validated
content-addressed paths, and supplies a coherent revisioned
`InheritedWorkSnapshot`. If any requested securing parent block is unknown, the
export is unavailable rather than a zero-valued measure. A known block whose
accepted ancestry is not yet connected to a genesis root is likewise ineligible
for export.

Snapshots are append-only joins. Every authenticated snapshot unions with the
retained view and revisions combine by maximum. An older or equal revision may
add previously unseen valid coverage, but no snapshot can retract or weaken a
fact. Revision is a source-progress watermark, not a commitment to snapshot
contents; coverage discovery may advance independently. Lattice keeps the
retained view during a provider outage. The node may
persist that cache according to its own restart and storage policy. A chain
consumes only its immediate parent's rolled-up measure, so it need not track every
ancestor process.

The current parent tip and parent canonical branch are not fork-choice inputs.
Parent accepted work and parent canonicity are orthogonal: adding accepted work
may change child `trueCumWork`, while moving only the parent's canonical pointer
cannot. The same root CID is unioned across local, inherited, and transitive input,
so inherited work is never counted twice.

### 9.6 Ingress Equivalence

Gossip, sync, mining, parent extraction, and sibling relay differ only in
acquisition. Every external candidate enters the admission procedure in section
9.3. Recovery instead replays already-authenticated durable facts through the
same graph mutation and fork-choice logic; it does not treat a local fact log as
new wire evidence. There is no library `ChainSyncer`, direct chain replacement,
or trusted sync projection.

### 9.7 Consensus Graph and Node State Lifecycle

Lattice retains the complete accepted consensus graph and every verified local
grind coverage. It performs no age-, depth-, body-, or state-retention pruning of
consensus inputs. Live inherited work is an immediate-parent input retained as a
monotone snapshot, not a recursively stored copy of every ancestor graph.

State execution derives `StateDiff` locally and carries it once in the immutable
`ChainBlockFact`; the diff is not stored in `Block`, `BlockMeta`, or a second
relationship index. The node atomically stages the fact, applies its lifecycle
effects, and decides whether to retain that payload. It owns CID counts, pinning,
materialized-state retention, projections, archival, and garbage collection.

### 9.8 Persistence

The node durably preserves every accepted block's consensus fields, every
distinct coverage fact and strengthening observation, and the latest
`ChainCommit.revision`. Cold fact-log recovery supplies that value as a revision
floor. A crash may occur
after durable staging and before the actor mutation. On recovery, the node gives
those already-authenticated local batches to `ChainState.restore(..., replaying:)`;
Lattice replays them idempotently through its own graph and fork-choice logic.
The node never reconstructs weights, ancestry, or canonical choice itself.

Whether it retains a staged block fact's `StateDiff` is node policy. For
inherited work, the node either retains the snapshot or reconstructs that exact
snapshot from durable parent facts before restore. A revision watermark alone
does not prove complete coverage, so a marker without its snapshot fails closed
rather than accepting a newer-looking live subset or substituting zero.
Restoration rejects malformed graph or work facts, joins idempotent coverage by
grind identity, reconstructs exact local measures, captures the current
inherited snapshot once, and reprojects canonicality. A persisted tip is
a derived cache, not durable protocol truth. With no new evidence the result is
the live decision; with a newer inherited snapshot the restored process starts at
the current decision. The node rebuilds its projections from that final state.
Filesystem layout, snapshots, state retention, and garbage collection belong to
the node. `PersistedChainState.schemaVersion` is mandatory; unsupported layouts
fail closed rather than guessing a migration.

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
state); withdrawals release it.

### 12.3 Consensus Invariants

1. The chain tip is always on the main chain
2. The chain tip block always exists in the block map
3. Exactly one accepted genesis root anchors the selected main-chain path
4. Main chain blocks form a connected path from genesis to tip
5. `mainChainBlocksAdded` and `mainChainBlocksRemoved` in a `ChainCommit` are disjoint sets
6. One `ChainLevel` owns one absolute path and cannot mutate another chain

### 12.4 Cross-Chain Transfer Invariants

1. Each `DepositKey` is unique in deposit state (insertion proof prevents duplicate deposits)
2. Each `ReceiptKey` is unique in receipt state (insertion proof prevents duplicate receipts)
3. A withdrawal requires the corresponding deposit to contain its original
   nonzero amount
4. A withdrawal requires the corresponding receipt to exist in `parentState.receiptState` (mutation proof)
5. The stored `amountDeposited` must exactly match the declared `amountWithdrawn` (prevents over-withdrawal)
6. Withdrawal replaces the deposit value with a permanent spent marker

### 12.5 Fork Choice Invariants

1. The setup-wide minimum root-work floor is evaluated before child resolution
   and all chain targets
2. Every level evaluates the same root hash against its own target
3. Every carrier proves same-chain predecessor continuity even when its target misses
4. A grind is deduplicated by root CID across all local and inherited coverage;
   its credited quantity is the strongest verified accepted-target bound
5. Work measures union by grind ID before totaling, so shared work is counted once
   while distinct grinds sum
6. Effective `trueCumWork` includes one coherent monotone immediate-parent
   snapshot from the full accepted parent graph
7. Equal-work segments prefer the lexicographically smaller canonical base CID;
   `nextTarget` and segment tips are not comparators
8. Parent accepted work may change child fork choice; parent canonicity alone
   cannot change child validity, weight, or fork choice
9. Lattice never prunes accepted graph or verified local-work facts
10. There is no finality threshold; a strictly heavier effective subtree may reorg at any depth
11. Every successful consensus mutation has a monotonically increasing revision
12. One explicit validation-time context governs an admission and its retries

## 13. Constants

| Constant | Value | Description |
|---|---|---|
| `maxTargetChange` | 2 | Maximum target adjustment factor per block |
| `totalExponent` | 64 | Bit width of the reward/halving system |
