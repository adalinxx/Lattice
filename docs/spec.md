# Lattice Protocol Specification

Version 0.1.0

## 1. Overview

Lattice is a hierarchical proof-of-work protocol, not a single blockchain. Every chain is simultaneously a chain and a tree of chains rooted at it: any chain can spawn child chains via genesis transactions, and each of those children is itself a chain that can spawn its own children. The **nexus** is the first outermost chain -- the entry point from outside the hierarchy; other outermost chains may also exist. Child chains inherit security from their parent through **parent chain anchoring** and support trustless cross-chain value transfer through a three-phase **deposit/receipt/withdrawal** protocol.

Each chain defines its own operations, `ChainSpec`, and chain policies, so chains are heterogeneous; only the organizing protocol -- block structure, proof-of-work, fork choice, and the cross-chain transfer rules -- is shared across the hierarchy.

All state is content-addressed using IPLD/CID. Blocks reference state via Merkle roots, enabling light client verification without full state replication.

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
    directory:                      string,
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
GenesisAction = (directory: string, block: Block)
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
    blockInfo:          BlockInfoImpl,
    parentChainBlocks:  Map<ParentBlockHash, ParentBlockIndex?>,
    childBlockHashes:   [string]
)
```

#### Reorganization

```
Reorganization = (
    mainChainBlocksAdded:   Map<BlockHash, BlockIndex>,
    mainChainBlocksRemoved: Set<BlockHash>
)
```

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

A `directory` defined in a chain's `ChainSpec` is a **relative edge label** from its parent -- it names the chain only with respect to that parent, and is not a globally unique chain identity. A chain's canonical identity is its full **path** (route) from the outermost chain, e.g. `Nexus/Payments`. The nexus is the first outermost chain; sibling chains under different parents may reuse the same `directory` label without collision because their full paths differ. Child chains are created by including a `GenesisAction` in a transaction on the parent chain.

### 4.2 Chain Level

Each chain is managed by a `ChainLevel`:

```
ChainLevel = (
    chain:    ChainState,      // consensus for this chain
    children: Map<directory, ChainLevel>
)
```

Block processing is recursive: if a block does not satisfy the current chain's target, it is offered to child chains.

## 5. Block Validation

### 5.1 Genesis Block Validation

A genesis block `B` is valid if and only if ALL of the following hold:

1. `B.previousBlock == nil`
2. `B.height == 0`
3. `B.timestamp <= now()`
4. `B.prevState == CID(emptyState())`
5. All transactions in `B.transactions` are fully resolvable
6. For each transaction `tx`: `tx.validateTransactionForGenesis()` returns true
   - Signatures are valid Ed25519 signatures over `CID(tx.body)`
   - Signers match signature public keys
   - Account debits are authorized by signers
   - No withdrawal actions present
7. `B.spec.directory` matches the expected directory name
8. All transaction bodies pass the chain's policies
9. `|transactions| <= spec.maxNumberOfTransactionsPerBlock`
10. `sum(stateDelta(tx) for tx in transactions) <= spec.maxStateGrowth`
11. **Balance conservation (genesis)**:
    ```
    totalCredits + totalDeposited == premineAmount
    ```
12. All `GenesisAction` blocks are themselves valid genesis blocks (recursive)
13. **Post-state correctness**: Applying all actions to `prevState` (empty state) produces `postState`:
    ```
    proveAndUpdateState(prevState, allActions) == postState
    ```

### 5.2 Nexus Block Validation

A non-genesis nexus block `B` with previous block `P` is valid if and only if:

1. `P` is resolvable
2. `B.spec == P.spec` (chain spec continuity)
3. `B.prevState == P.postState` (state continuity)
4. `B.height == P.height + 1`
5. `P.timestamp < B.timestamp <= now()`
6. `B.target == P.nextTarget`, and `B.nextTarget` equals the clamped proportional retarget of section 5.5
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
    totalCredits + totalDeposited == totalDebits + reward(B.height) + totalWithdrawn
    ```
12. All genesis actions valid
13. Post-state correctness

**Nexus validation does not validate child blocks.** The `children` field is committed to via `CID(B.children)` in the proof-of-work hash (section 5.4), so the miner commits to a specific set of child blocks when mining. However, child blocks are validated independently *after* the nexus block is accepted (section 5.3). An invalid child block does not affect the nexus block's validity, other child chains, or the nexus chain's state. This means a nexus-only miner only needs to compute the nexus portion of the block -- child block validation is deferred to nodes that participate in those child chains.

### 5.3 Child Chain Block Validation

Child blocks embedded in a nexus block via the `children` field are **optional**. They are processed independently after the parent nexus block is accepted onto the main chain. Invalid child blocks are silently skipped without affecting the parent block or sibling child chains.

A child chain block `B` with previous block `P` and parent chain block `Q` is valid if and only if:

1. All nexus validation rules (5.2, items 1-10, 12-13) apply, including the same balance conservation equation
2. `B.timestamp == Q.timestamp` (child block timestamp synchronized with parent)
3. `B.parentState == Q.prevState` (parent state commitment matches actual parent state)
4. Withdrawal validation: each withdrawal requires proof of corresponding deposit in `prevState.depositState` AND proof of receipt in `parentState.receiptState`

### 5.4 Proof-of-Work

The proof-of-work hash of a block is computed as:

```
proofOfWorkHash(B) = U256(H(
    CID(B.previousBlock) ||
    CID(B.transactions) ||
    hex(B.target) ||
    hex(B.nextTarget) ||
    CID(B.spec) ||
    CID(B.parentState) ||
    CID(B.prevState) ||
    CID(B.postState) ||
    CID(B.children) ||
    str(B.height) ||
    str(B.timestamp) ||
    str(B.nonce)
))
```

For genesis blocks, `CID(B.previousBlock)` is omitted from the hash input.

A block satisfies proof-of-work if `proofOfWorkHash(B) ≤ B.target` (equivalently
`B.target ≥ proofOfWorkHash(B)`, the canonical comparator). A larger `target`
value is *easier* to satisfy; the work it represents is `work(B) = ⌊U256_MAX / B.target⌋`
(section 9.1).

### 5.5 Target Adjustment (Retargeting)

The target is **derived from the parent, not chosen by the miner**. Every block
MUST satisfy the binding rule:

```
B.target == parent.nextTarget
```

(genesis takes its target from the `ChainSpec`.) Each block's `nextTarget` is a
**clamped, linearly-weighted retarget (LWMA)** recomputed *every block* from the
canonical main-chain solve times over the most recent `spec.retargetWindow`
intervals (including the current block's own solve time), targeting
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
retarget reads only canonical timestamps, is bounded per block, and `B.target` is
bound to the parent, a miner cannot grind the target by choosing its own or by
skewing a single timestamp (timestamps are themselves bounded by the MTP /
future-drift rules).

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

For each `WithdrawalAction` (deposits are deleted when withdrawn):
- **Key**: `DepositKey(demander, amountDemanded, nonce)`
- **Proof**: Verify key EXISTS in `depositState` (deletion proof)
- **Validation**: Stored `amountDeposited` must equal `amountWithdrawn`
- **Update**: Delete `depositState[key]`

Withdrawals are processed before new deposits within the same block to avoid key conflicts.

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
- **Update**: `genesisState[directory] = CID(action.block)`

### 6.8 State Delta Accounting

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
| `GenesisAction` | `+genesisSize(block) + len(directory)` |

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

### 7.5 Deposit/Receipt/Withdrawal Authorization

- **DepositAction**: `demander` MUST be in `tx.body.signers`
- **ReceiptAction**: `withdrawer` MUST be in `tx.body.signers`
- **WithdrawalAction**: `withdrawer` MUST be in `tx.body.signers`; requires proof of corresponding deposit in `prevState.depositState` AND proof of receipt in `parentState.receiptState`

### 7.3 WASM Policies

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

### 7.4 Context-Specific Rules

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
The child chain verifies a receipt exists on the parent by checking `parentState.receiptState`. A `WithdrawalAction` deletes the deposit entry from `depositState` (deletion proof, preventing double-withdrawal) and releases `amountWithdrawn` back to the `withdrawer`. The stored `amountDeposited` must exactly match `amountWithdrawn`.

### 8.2 Balance Conservation with Cross-Chain Transfers

For any block at index `i`:

```
totalCredits + totalDeposited == totalDebits + reward(i) + totalWithdrawn
```

Where:
- `totalCredits` = sum of all positive account action deltas (including the miner's coinbase credit of `reward(i) + Σfees`)
- `totalDebits` = sum of all negative account action deltas (absolute values), including each transaction's `body.fee` debited from a signer
- `totalDeposited` = sum of all `DepositAction.amountDeposited` values
- `totalWithdrawn` = sum of all `WithdrawalAction.amountWithdrawn` values

The transaction `fee` is an ordinary transfer — debited from a signer (in `totalDebits`) and credited to the miner via the coinbase (`reward(i) + Σfees`, in `totalCredits`) — so it cancels and does not appear as a separate term. The block subsidy `reward(i)` is the only minting source.

Deposits reduce the available balance (tokens locked in deposit state). Withdrawals increase it (tokens released from deposit state).

### 8.3 Security Properties

**No value creation**: The balance equation guarantees that credits cannot exceed debits plus block reward plus net withdrawal flow.

**No double-deposit**: Deposit keys are unique in deposit state (insertion proof prevents duplicate deposits with the same nonce/demander/amount).

**No double-withdrawal**: Withdrawals delete the deposit entry (deletion proof). Once withdrawn, the deposit key no longer exists, so a second withdrawal fails the proof.

**No over-withdrawal**: The stored `amountDeposited` must exactly match the declared `amountWithdrawn`. If a withdrawer claims more than was deposited, the state proof rejects the transaction.

**No forged receipts**: Receipt verification uses `parentState.receiptState`, which is committed in the child block's proof-of-work hash. An attacker cannot fabricate a receipt without controlling the parent chain's hashrate.

**Cross-chain replay protection**: Each transaction declares a `chainPath` targeting the exact chain hierarchy path. Transactions are rejected if the `chainPath` doesn't match the validating chain.

## 9. Consensus

### 9.1 Fork Choice Rule (Hierarchical GHOST)

Lattice selects the canonical tip by **greatest accumulated work**, but the
accumulator is a *Hierarchical GHOST* weight, not a single-path Nakamoto sum.
Three per-block quantities define it.

**Per-block work.** `work(B) = ⌊U256_MAX / B.target⌋`. A larger `target`
field is *easier* to satisfy, so work is inversely proportional to it.

**Backward cumulative work (ancestor prefix sum).**
```
cumulativeWork(B) = cumulativeWork(parent(B)) + work(B)      // genesis: work(genesis)
```
The total own-chain work from genesis to `B`. It is *stored* (not recomputed) so
it survives retention pruning and persistence round-trips. It is the metric used
for trustless-sync work comparison at the chain-acceptance chokepoint (a synced
chain replaces the local one only if its exact `cumulativeWork` is strictly
greater) — **not** the quantity local fork choice maximizes.

**Forward subtree weight (the GHOST quantity).**
```
subtreeWeight(B) = work(B) + Σ_{c ∈ children(B)} subtreeWeight(c)
```
The total work of `B`'s descendant subtree on *its own chain*, counting each
block once. Forks do not enter the definition — a block either descends from `B`
or it does not. It is maintained bottom-up and repaired up the ancestor chain on
insert, so it is correct under out-of-order delivery and unaffected by ancestor
pruning (pruning only ever discards ancestors, never a retained block's
descendants).

**Inherited (merged-mining) weight.** A block may be *secured* by a block on its
parent chain (section 9.5). That relationship contributes the securing parent's
own fork-choice weight:
```
inherited(B) = trueCumWork(securingParent(B))   // 0 for the nexus / an unsecured block
```
This term is **derived fresh at fork-choice time, never stored on the block**: the
parent chain's weight grows as the parent extends, so a cached copy would go
stale. A node installs an `inheritedWeightProvider` that resolves the securing
parent and returns its current `trueCumWork`.

**Fork-choice weight (`trueCumWork`).** The single scalar fork choice compares:
```
trueCumWork(B) = effectiveWeight(B) = subtreeWeight(B) + inherited(B)
```
a block's own descendant-subtree work plus the security riding down the lattice
from its parent chain.

**Selection.** Among competing tips the one with the greatest `trueCumWork` is
canonical:
```
rightOutweighsLeft(L, R) := trueCumWork(R) > trueCumWork(L)
```
The comparison is **strict**: on an exact tie the incumbent (first-seen) tip is
retained — equal weight never triggers a reorg (no thrash). There is **no explicit
finality**: any block may be reorganized at any depth if a heavier subtree later
appears. The only depth bound is a node's *local* retention horizon, a storage
policy (section 9.7), not a consensus rule.

> The full design rationale — out-of-order repair, the derived-not-cached
> inherited term, and the cross-chain securing union — is in
> [`docs/consensus-fork-choice.md`](consensus-fork-choice.md) (this repo), which
> this section is the normative companion to.

### 9.2 Chain State

Each chain maintains:

```
ChainState = actor {
    chainTip:                       string,         // hash of best known block
    mainChainHashes:                Set<string>,     // all hashes on main chain
    indexToBlockHash:               Map<uint64, Set<string>>,
    hashToBlock:                    Map<string, BlockMeta>,
    parentChainBlockHashToBlockHash: Map<string, string>
}
```

### 9.3 Nexus Block Processing

When a new nexus block arrives, processing happens in two phases:

**Phase 1: Nexus validation and submission** (required)

1. Validate the block via `validateNexus()` (section 5.2) -- child blocks are NOT validated here
2. Verify proof-of-work: `proofOfWorkHash(B) ≤ B.target`
3. Submit to `ChainState`:
   a. If `block.height + RECENT_BLOCK_DISTANCE < highestBlockHeight`, discard (too old)
   b. If block hash already known, handle as duplicate (may add parent chain reference)
   c. Insert into `hashToBlock` and `indexToBlockHash`
   d. If previous block is current chain tip, extend main chain
   e. If previous block is unknown and block is recent, request the missing parent
   f. Otherwise, evaluate fork choice via `checkForReorg()`

**Phase 2: Child block extraction** (deferred, independent)

Only after the nexus block is accepted onto the main chain:

4. Extract child blocks from `B.children` Merkle dictionary
5. For each child block, validate independently against its child chain's rules (section 5.3)
6. Invalid child blocks are silently skipped -- they do not affect the nexus block or other children
7. Newly discovered child chains (genesis blocks) are registered in the chain hierarchy

This two-phase design means nexus miners only need to perform nexus-level validation and mining. Child block validation is entirely the responsibility of nodes that participate in those child chains.

### 9.4 Reorganization

When a competing tip outweighs the current main chain:

1. Find the fork point (the deepest block common to both branches)
2. Take the current main-chain tip's `trueCumWork` (section 9.1)
3. Take the competing tip's `trueCumWork` (its `subtreeWeight` plus its freshly
   derived `inherited` term)
4. If `trueCumWork(fork) > trueCumWork(main)` (strict — a tie holds the incumbent):
   a. Update `chainTip` to the new fork's tip
   b. Remove old main chain blocks from `mainChainHashes` (above fork point)
   c. Add new fork blocks to `mainChainHashes`
   d. Return `Reorganization` describing added/removed blocks
   e. Propagate to child chains

A reorg may also be triggered with no new local block: when the parent chain
extends and raises a fork's `inherited` weight, `reevaluateForkChoice(blockHash)`
re-derives `trueCumWork` and promotes the fork if it now outweighs the main tip.

### 9.5 Parent Chain Anchoring

When a child chain block is included in a parent chain block at index `P_i`:
- Record `parentChainBlockHashToBlockHash[P_hash] = C_hash`
- Record `hashToBlock[C_hash].parentChainBlocks[P_hash] = P_i`

The `parentIndex` of a `BlockMeta` is the minimum of all known parent chain indices:
```
parentIndex = min(parentChainBlocks.values.compactMap { $0 })
```

The recorded anchoring is what lets a node resolve a block's *securing parent* and
so supply its `inherited(B)` weight (section 9.1). Anchoring no longer confers a
lexicographic priority of its own; it contributes additively, through inherited
weight, to the single `trueCumWork` metric.

### 9.6 Parent Reorg Propagation

When the parent chain reorganizes:

1. For each removed parent block hash: clear the corresponding anchoring reference in the child chain's block
2. For each added parent block hash: update the anchoring reference with the new parent index
3. Find affected child chain blocks that are not on the main chain
4. For each, evaluate fork choice -- the changed anchoring may trigger a child chain reorg

### 9.7 Block Pruning

When the chain tip advances, blocks at index `< (tipIndex - RECENT_BLOCK_DISTANCE)` are pruned from memory. `RECENT_BLOCK_DISTANCE = 1000`.

### 9.8 Weight Computation

A block's fork-choice weight is the single scalar
```
trueCumWork(B) = subtreeWeight(B) + inherited(B)
```
defined in section 9.1. `subtreeWeight` is maintained incrementally on the block;
`inherited` is derived live from the securing parent's current `trueCumWork`.

`BlockMeta` still exposes a legacy 2-element `weights` array
(`[UInt64.max - parentIndex, height]`) for backward compatibility, but the
consensus path no longer uses it for selection — `compareWork` is called with
`parentIndex: nil` and the `trueCumWork` scalar, collapsing the former two-tier
lexicographic key into one metric. The positional array is retained only for any
legacy caller and may be removed.

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

For any valid block, value is conserved as a **closed equality**:

```
totalCredits + totalDeposited == totalDebits + reward + totalWithdrawn
```

No tokens are created or destroyed; the block subsidy `reward` is the only minting
source. The transaction `fee` is an ordinary transfer — a real signer-owned debit
(in `totalDebits`) credited to the miner through the coinbase (`reward + Σfees`, in
`totalCredits`) — so it cancels and is not a separate conservation term. Deposits
lock balance (move it into deposit state); withdrawals release it.

### 12.3 Consensus Invariants

1. The chain tip is always on the main chain
2. The chain tip block always exists in the block map
3. The genesis block is always on the main chain (never removed by reorg)
4. Main chain blocks form a connected path from genesis to tip
5. `mainChainBlocksAdded` and `mainChainBlocksRemoved` in a `Reorganization` are disjoint sets

### 12.4 Cross-Chain Transfer Invariants

1. Each `DepositKey` is unique in deposit state (insertion proof prevents duplicate deposits)
2. Each `ReceiptKey` is unique in receipt state (insertion proof prevents duplicate receipts)
3. A withdrawal requires the corresponding deposit to exist (deletion proof)
4. A withdrawal requires the corresponding receipt to exist in `parentState.receiptState` (mutation proof)
5. The stored `amountDeposited` must exactly match the declared `amountWithdrawn` (prevents over-withdrawal)
6. Deposit entries are deleted on withdrawal (prevents double-withdrawal)

### 12.5 Fork Choice Invariants

1. The `trueCumWork` comparison is irreflexive (no tip outweighs itself) and asymmetric (if R outweighs L, L does not outweigh R)
2. Selection is monotone in `trueCumWork`: the canonical tip is the one of maximal `trueCumWork`
3. The comparison is strict — equal `trueCumWork` does **not** reorg; the incumbent (first-seen) tip is retained (no thrash)
4. `subtreeWeight` counts each descendant exactly once; sibling forks are never double-counted
5. `inherited(B)` is derived fresh from the securing parent's current `trueCumWork`; a parent-chain extension that raises a fork's inherited weight may promote it (`reevaluateForkChoice`)
6. There is no finality threshold: no block is permanently irreversible by the consensus rule (depth bounds are a local retention/storage policy, not consensus)

## 13. Constants

| Constant | Value | Description |
|---|---|---|
| `RECENT_BLOCK_DISTANCE` | 1000 | Blocks older than this are pruned from memory |
| `maxTargetChange` | 2 | Maximum target adjustment factor per block |
| `totalExponent` | 64 | Bit width of the reward/halving system |
