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
| `retargetWindow` | `120` blocks | About five days |
| `maxBlockSize` | `1,000,000` bytes | Unique canonical block + transaction Volume bytes |
| `maxStateGrowth` | `3,000,000` bytes | Per block |
| `maxNumberOfTransactionsPerBlock` | `5,000` | Per block |
| `maxTargetChange` | unset (`nil`) | No per-retarget clamp |

`ChainSpec.maxTargetChange` defaults to `nil` — no per-retarget clamp. A chain
may commit a factor; **Nexus commits none**, so Nexus retargets by the full
unclamped proportional correction. There is no minimum-target floor. A chain
directory is positional path data, not a `ChainSpec` field.

## Emission

The public block subsidy is

```text
rewardAtBlock(height)
    = initialReward >> ((height + premine) / halvingInterval)
```

`premine` advances public mining along the same reward curve. For Nexus, the
first public halving is therefore

```text
876,600 - 175,320 = 701,280 blocks
```

or about 80 years at the target cadence. Later halvings remain 876,600 blocks
apart. Integer shifts eventually reduce the reward to zero; there is no tail
emission.

The implementation returns zero instead of trapping if `height + premine`
overflows or the shift reaches 64 bits.

## Premine

Because the Nexus premine is shorter than one halving interval, every premined
block uses the initial reward:

```text
premineAmount
    = 175,320 * 1,048,576
    = 183,836,344,320
```

The recipient and exact genesis transaction are fixed by
`NexusGenesis.swift`. Generic genesis validation permits total credits up to the
configured `premineAmount`; it does not infer a recipient.

## Supply

The geometric closed-form limit is

```text
2 * halvingInterval * initialReward
    = 1,838,363,443,200
```

The exact integer-terminated schedule is

```text
halvingInterval * (2^21 - 1)
    = 1,838,362,566,600
```

The premine is exactly 10% of the closed-form limit and approximately 10% of the
exact integer-terminated supply. The small difference is the finite tail removed
by integer halving.

## Cadence And Fees

Nexus retargets every block using an **unclamped** LWMA over the candidate's
own ancestor branch: `maxTargetChange` is unset, so one step may correct by an
arbitrary factor (a ×1150 step has been observed live). A block's target is its
parent's `nextTarget` or voluntarily harder, never easier — there is no
minimum-target floor and no recovery exception.

Because the window is linearly weighted, the retarget reads the candidate's gap
from the *mean* of the previous 120 timestamps, and holds difficulty steady at
`(120+1)/2 = 60.5` hours rather than at one hour. Redistributing timestamps
within the window can make the next target at most about 2× easier than honest
spacing, but up to 60.5× harder, with no clamp on the harder direction. A
clustered window is self-reinforcing and takes roughly 15 days of elapsed time to
walk back even at matched hashrate. See
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
