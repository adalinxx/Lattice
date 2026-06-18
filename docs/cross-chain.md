# Cross-Chain Transfer Protocol: Formal Specification

## Overview

This document specifies the protocol for trustless cross-chain value transfer between parent and child chains in the Lattice hierarchy. The protocol requires no trusted intermediaries -- all verification is performed via Sparse Merkle proofs against state roots committed in blocks.

## Definitions

- **N**: Nexus -- the first of the outermost chains (the merged-mining anchor; not a unique root -- other outermost chains may exist)
- **P**: Parent chain (any chain in the hierarchy)
- **C**: Child chain (direct descendant of P)
- **B[i]**: Block at index `i` on a given chain
- **prevState(B)**: The confirmed state entering block B (equals postState of B's parent block)
- **postState(B)**: The state after applying B's transactions to prevState(B)
- **parentState(B)**: For non-root blocks, a committed snapshot of the parent chain's state
- **SMT**: Sparse Merkle Tree

## Types

### DepositAction

```
DepositAction = {
    nonce:           uint128,          // Unique identifier
    demander:        CID(PublicKey),   // Recipient on the parent chain
    amountDemanded:  uint64,           // Amount to transfer on the parent chain
    amountDeposited: uint64            // Amount locked on the child chain
}
```

A deposit locks `amountDeposited` tokens on the child chain and declares that `demander` should receive `amountDemanded` tokens on the parent chain. The deposit supports variable-rate transfers: `amountDeposited` and `amountDemanded` may differ, enabling exchange rate adjustments between chains.

### ReceiptAction

```
ReceiptAction = {
    withdrawer:     CID(PublicKey),   // Original depositor (will withdraw on child)
    nonce:          uint128,          // Must match the deposit nonce
    demander:       CID(PublicKey),   // Recipient (credited on parent)
    amountDemanded: uint64,           // Amount transferred on parent
    directory:      string            // Child chain where the deposit originated
}
```

A receipt on the parent chain acknowledges a deposit on the child chain. It derives two account actions: debiting `withdrawer` by `amountDemanded` and crediting `demander` by `amountDemanded`.

### WithdrawalAction

```
WithdrawalAction = {
    withdrawer:     CID(PublicKey),   // Must match the receipt's withdrawer
    nonce:          uint128,          // Must match the deposit nonce
    demander:       CID(PublicKey),   // Must match the deposit's demander
    amountDemanded: uint64,           // Must match the deposit's amountDemanded
    amountWithdrawn: uint64           // Must exactly match the stored amountDeposited
}
```

A withdrawal on the child chain releases the originally deposited tokens. The `amountWithdrawn` must exactly match the `amountDeposited` stored in the deposit state -- this is verified at consensus via state proof.

### DepositKey

```
DepositKey = demander || "/" || amountDemanded || "/" || nonce

Serialization: "demander/amountDemanded/nonce"
```

### ReceiptKey

```
ReceiptKey = directory || "/" || demander || "/" || amountDemanded || "/" || nonce

Serialization: "directory/demander/amountDemanded/nonce"
```

## Invariants

**INV-1: State continuity.** For all blocks B with parent block B':
```
prevState(B) == postState(B')
```

**INV-2: Deposit uniqueness.** For any DepositKey K, at most one entry exists in depositState:
```
forall K: |{ entry in depositState | entry.key == K }| <= 1
```

**INV-3: Receipt uniqueness.** For any ReceiptKey K, at most one entry exists in receiptState:
```
forall K: |{ entry in receiptState | entry.key == K }| <= 1
```

**INV-4: Balance conservation.** For any block B at index i with spec S:
```
totalCredits + totalDeposited == totalDebits + S.reward(i) + totalWithdrawn
```

**INV-5: Withdrawal exactness.** The stored amountDeposited must exactly match the declared amountWithdrawn:
```
depositState[key] == withdrawalAction.amountWithdrawn
```

## Protocol Steps

### Step 1: Deposit (on the child chain)

**Preconditions:**
- Transaction is included in a block on the child chain
- Transaction body contains a `DepositAction`
- `demander` is in `tx.body.signers` (authorization)
- `amountDeposited > 0` and `amountDemanded > 0`

**State transition on child chain C:**

```
// Deposit lock
depositKey = DepositKey(demander, amountDemanded, nonce)
C.depositState' = C.depositState.insert(depositKey, amountDeposited)
```

**Proof obligation:**
- DepositKey insertion proof: key does NOT exist in depositState (prevents duplicate deposits)

**Effect on balance conservation (INV-4):**
- `totalDeposited` increases by `amountDeposited`
- The depositor's account is not debited -- the tokens are "locked" by reducing the available balance pool in the conservation equation

### Step 2: Receipt (on the parent chain)

**Preconditions:**
- Transaction is included in a block on the parent chain
- Transaction body contains a `ReceiptAction`
- `withdrawer` is in `tx.body.signers`
- The deposit is verifiable via the child chain's state root committed in the child block embedded in the parent block

**State transition on parent chain P:**

```
// Receipt record
receiptKey = ReceiptKey(directory, demander, amountDemanded, nonce)
P.receiptState' = P.receiptState.insert(receiptKey, CID(withdrawer.publicKey))

// Derived account actions
AccountAction(owner: withdrawer, delta: -amountDemanded)
AccountAction(owner: demander, delta: +amountDemanded)
```

**Proof obligation:**
- ReceiptKey insertion proof: key does NOT exist in receiptState (prevents duplicate receipts)

**Effect on balance conservation (INV-4):**
- The derived account actions produce equal debits and credits, netting to zero

### Step 3: Withdrawal (on the child chain)

**Preconditions:**
- Transaction is included in a block on the child chain
- Transaction body contains a `WithdrawalAction`
- `withdrawer` is in `tx.body.signers`
- Corresponding deposit exists in `prevState.depositState`
- Corresponding receipt exists in `parentState.receiptState`
- Stored `amountDeposited` equals declared `amountWithdrawn`

**State transition on child chain C:**

```
// Deposit deletion
depositKey = DepositKey(demander, amountDemanded, nonce)
C.depositState' = C.depositState.delete(depositKey)
```

**Proof obligations:**
- Deposit deletion proof: key EXISTS in depositState (proves the deposit was made)
- Receipt mutation proof: corresponding ReceiptKey EXISTS in parentState.receiptState (proves the parent acknowledged the deposit)
- Receipt withdrawer verification: the `CID(PublicKey)` stored in the receipt must match the withdrawal's `withdrawer`

**Effect on balance conservation (INV-4):**
- `totalWithdrawn` increases by `amountWithdrawn`
- The tokens return to the available balance pool

## Variable-Rate Transfers

The protocol supports variable-rate cross-chain transfers where `amountDeposited` on the child chain differs from `amountDemanded` on the parent chain. This enables:

- **Exchange rate adjustments**: A child chain with different token economics can define its own exchange rate to the parent
- **Over-collateralized transfers**: The depositor can lock more than is demanded. Because withdrawal returns exactly `amountDeposited` (INV-5), the surplus is *not* a miner fee and is not destroyed -- it is released back to the withdrawer on withdrawal; the demand/deposit spread is an exchange-rate artifact, distinct from the protocol `body.fee`

The withdrawal step verifies that `amountWithdrawn == amountDeposited` (the stored value), ensuring the exact deposited amount is returned regardless of the demanded amount.

## Security Properties

### Property 1: No value creation

The balance equation guarantees that credits cannot exceed debits plus block reward plus the net cross-chain flow. Deposits reduce available balance; withdrawals increase it. The net is always zero across the complete deposit-receipt-withdrawal lifecycle.

### Property 2: No double-deposit

DepositKey uniqueness is enforced by insertion proofs. A deposit with the same (demander, amountDemanded, nonce) tuple cannot be inserted twice.

### Property 3: No double-withdrawal

Withdrawals delete the deposit entry. Once withdrawn, the DepositKey no longer exists in depositState. A second withdrawal attempt fails the deletion proof.

### Property 4: No over-withdrawal

The stored `amountDeposited` must exactly match the declared `amountWithdrawn`. The state proof verifies this at consensus. An attacker cannot claim more than was deposited.

### Property 5: No forged receipts

Receipt verification checks `parentState.receiptState`. The `parentState` is committed in the child block's proof-of-work hash. Fabricating a receipt would require controlling the parent chain's hashrate to produce a block with a forged `parentState`.

### Property 6: Replay protection

Each step uses Sparse Merkle proofs:
- Deposit: insertion proof (DepositKey must not exist) -- prevents duplicate deposits
- Receipt: insertion proof (ReceiptKey must not exist) -- prevents duplicate receipts
- Withdrawal: deletion proof (DepositKey must exist, then delete) -- prevents double-withdrawal

Cross-chain replay is further prevented by `chainPath` -- each transaction declares the exact chain hierarchy path it targets.

### Property 7: Withdrawer verification

The receipt stores `CID(withdrawer.publicKey)`. On withdrawal, the child chain verifies that the withdrawer matches the receipt. This prevents an unauthorized party from claiming the deposited tokens.

## Miner Incentives

Miners are incentivized to include cross-chain transfer transactions through the explicit `body.fee` on each transaction. Receipt transactions are particularly profitable because they require a signer (the withdrawer) who pays fees for the parent-chain account transfer.
