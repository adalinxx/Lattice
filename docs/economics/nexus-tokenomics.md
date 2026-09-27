# Nexus Tokenomics

This non-normative note summarizes the configured economics of Nexus, Lattice's
single outermost chain. The concrete configuration lives in
[`NexusGenesis.swift`](https://github.com/adalinxx/lattice-node/blob/2.0.0/Sources/LatticeNode/Architecture/NexusGenesis.swift).
Lattice interprets it using
[`ChainSpec.swift`](../../Sources/Lattice/Block/ChainSpec.swift) and the generic
[economic rules](../spec.md#10-economic-model).

Do not copy a premine recipient, timestamp, or genesis CID from this page. Those
identity-bearing values have one canonical home in `NexusGenesis.swift`.

## Design Intent

Nexus favors a light, long-lived root:

- one-hour blocks and one-megabyte block bodies limit payload growth;
- bounded state growth limits each transition's expansion;
- a long issuance schedule keeps subsidy available over a long horizon;
- applications needing different capacity or cadence can use child chains.

A child receives only path-bound verified work that actually covers it. It does
not automatically inherit all Nexus hashpower or Nexus canonicity.

## Configured Parameters

| Parameter | Value | Meaning |
|---|---:|---|
| `initialReward` | `1,048,576` | Initial subsidy, `2^20` |
| `halvingInterval` | `876,600` blocks | About 100 years at one-hour blocks |
| `premine` | `175,320` blocks | Front-of-schedule issuance |
| `targetBlockTime` | `3,600,000` ms | One hour |
| `halfLife` | `120` blocks | The schedule's half-life, about five days |
| `maxBlockSize` | `1,000,000` bytes | Unique canonical block + transaction Volume bytes |
| `maxStateGrowth` | `3,000,000` bytes | Per block |
| `maxNumberOfTransactionsPerBlock` | `5,000` | Per block |


The schedule holds difficulty steady at exactly one-hour spacing, and moves one
doubling per half-life of accumulated drift, where the half-life is
`halfLife × targetBlockTime` = 120 hours. Because the target depends only
on the anchor and the present block, a stretch of unusual block times stops
mattering the moment it stops happening — there is no window to drain and no
clustered-window attractor to walk back out of. Moving a timestamp backwards
hardens rather than eases, and moving it forwards is capped by the validating
node's clock and eases only the single successor without compounding. See
[specification §5.5](../spec.md#55-target-adjustment-retargeting).

The signed `fee` field does not automatically move value. Lattice enforces the
block-wide non-creation bound over explicit actions. A node may require an
explicit payer debit and construct an author credit as fee policy. See
[Fee Policy And Majority-Reorg Cost](fee-market-and-51pct.md).

## Sources

| Fact | Canonical home |
|---|---|
| Nexus parameters and genesis identity | `lattice-node/Sources/LatticeNode/Architecture/NexusGenesis.swift` |
| Reward and premine arithmetic | `Sources/Lattice/Block/ChainSpec.swift` |
| Generic consensus rules | [Protocol specification](../spec.md) |
| Adversarial fork-choice model | [TRE-134 report](../consensus/tre-134-adversarial-report.md) |
