# Fee Policy And Majority-Reorg Cost

This note separates consensus-enforced accounting from node fee policy, then
gives a narrow cost model for a majority-work reorganization of Nexus. It is
not a complete economic-security model.

For issuance and supply, see [Nexus Tokenomics](nexus-tokenomics.md).

## What Consensus Enforces

`TransactionBody.fee` is signed metadata because it is part of the transaction
body. Lattice does not automatically debit that amount, credit a block author,
or require total author credits to equal the sum of declared fees.

Block validation instead evaluates the explicit account, deposit, and
withdrawal actions under one non-creation bound:

```text
totalCredits + totalDeposited
    <= totalDebits + reward(height) + totalWithdrawn
```

The fee field is absent from this equation. Therefore:

- declaring a fee never creates spendable budget;
- credits above the block reward need explicit debits or withdrawals to fund
  them;
- unused budget is burned;
- consensus does not name the recipient of a funded surplus.

The fee regression tests in
[`SecurityTests.swift`](../../Tests/LatticeTests/SecurityTests.swift) demonstrate
this aggregate rule. An unfunded `reward + fee` credit fails, while the same
credit with an explicit matching debit succeeds. They do not establish an
automatic fee-routing rule.

## What The Node May Enforce

A node's mempool and block builder may adopt the familiar policy:

1. require a transaction's explicit signer debit to cover its declared fee;
2. select transactions by fee policy;
3. add an explicit author credit funded by those debits.

Under that policy, realized author revenue is

```text
R(h) = rewardAtBlock(h) + collectedFees
```

Only `rewardAtBlock(h)` is new issuance. `collectedFees` is redistribution. The
mapping from declared fees to debits and author credits is node policy unless a
chain-specific WASM policy makes it part of that chain's validity rules.

## Nexus Difficulty Inputs

| Parameter | Value |
|---|---:|
| Target block time `T` | `3,600` seconds |
| Retarget window | `120` blocks, about 5 days |
| Per-block target clamp | factor `2` |

Normally, `block.target == parent.nextTarget`. A successor recovering from a
legacy below-floor target instead uses `minimumTarget` for both `target` and
`nextTarget`.

Let `D` be the expected hashes represented by the current target, approximately
`U256_MAX / target`. At steady state, the observed honest hashrate is

```text
H ~= D / T
```

The LWMA tracks sustained changes in `H`; it does not make a short attack free
to choose an easier target.

## Majority-Reorg Estimate

Let:

- `c` be the external all-in cost per hash;
- `k` be the number of same-target blocks of work the attacker must replace.

A first-order direct-cost estimate is

```text
costMajorityReorg ~= c * D * k
```

Equivalently, for an attack lasting `t` seconds:

```text
costMajorityReorg ~= c * H * t
```

This estimates the hash spend needed to outwork an honest branch. It does not
price hardware scarcity, market impact, opportunity cost, varying targets,
network position, proof-derived work on nested child paths, or the deterministic
CID tie-break. Those inputs must be modeled separately.

## Not A Complete Security Threshold

Majority reorg safety is not the same as the earliest profitable deviation.
The deterministic [adversarial report](../consensus/tre-134-adversarial-report.md)
also models selfish mining and balancing attacks; in its assumptions, the
selfish-mining profitability threshold is lower than the majority threshold.
Security-budget analysis must state which attack and assumptions it prices.
