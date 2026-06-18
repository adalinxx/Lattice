# Nexus Tokenomics

The economic parameters of the **Nexus** chain — Lattice's first outermost (mainnet)
chain. This document is the human-readable companion to the canonical, code-pinned
source of truth: [`NexusGenesis.swift`](https://github.com/adalinxx/lattice-node/blob/main/Sources/LatticeNode/Chain/NexusGenesis.swift)
(in `lattice-node`) and the emission formulas in
[`ChainSpec.swift`](../../Sources/Lattice/Block/ChainSpec.swift). Every number below
is derived from those files; if they disagree, **the code wins**.

For the fee market, miner revenue, and the 51%-attack cost model, see
[`fee-market-and-51pct.md`](fee-market-and-51pct.md). For the generic (chain-agnostic)
emission/premine/supply formulas, see [`../spec.md` §10](../spec.md) (Economic Model).

## Design rationale — a light, long-lived base

The Nexus numbers are not tuned for throughput; they are tuned to keep the base
chain **cheap to run and mine, indefinitely**, because that accessibility is what
makes the network decentralized (see [Philosophy → A Deliberately Light Base
Chain](../philosophy.md#a-deliberately-light-base-chain)). Each choice serves that goal:

- **Slow blocks (1 h) + small blocks (1 MB) + bounded state growth (3 MB/block).**
  These cap how fast the Nexus's data and state can grow, so a node — even a
  *stateless* one that holds no local chain data and refetches from peers on demand —
  stays within commodity hardware for the long run. A heavy, fast base chain would
  price ordinary operators out and concentrate the network; a light one keeps the
  door open. Throughput is not sacrificed, it is **relocated**: applications that need
  it spawn child chains whose own `ChainSpec` picks faster/larger parameters, borne
  only by that child's participants while still inheriting Nexus security via merged
  mining.

- **Century-scale halving (`halvingInterval = 876,600` ≈ 100 y at 1 h blocks).** The
  emission schedule is stretched deliberately long so the block subsidy stays
  meaningful for a very long time. Subsidy is what pays the broad, low-barrier miner
  base; front-loading emission would let rewards fade quickly, push the network onto
  fee revenue, and concentrate mining among a few large operators. A slow base chain
  is paired with **slow money** so the decentralized miner set stays economically
  viable across decades, not years.

- **`initialReward = 2²⁰` with simple halving.** Sound-money disinflation: a clean,
  predictable, ever-decreasing issuance with no governance knobs.

- **Premine = 10%, bounded and transparent.** A modest, fixed founder allocation
  (provable from the content-addressed genesis); the remaining ~90% is mined over the
  century-scale horizon by the decentralized miner base — not pre-allocated.

The throughline: **optimize the root for accessibility and longevity, push throughput
to the edges.** The rest of this document is the concrete schedule those choices produce.

## 1. Parameters

The Nexus `ChainSpec` (`NexusGenesis.spec`):

| Parameter | Value | Notes |
|---|---|---|
| `directory` | `Nexus` | chain identity (path root) |
| `initialReward` | `1,048,576` (2²⁰) | block subsidy at genesis |
| `halvingInterval` | `876,600` blocks | ~100 years at 1 h blocks (365.25 d × 24 h × 100) |
| `premine` | `175,320` blocks | `halvingInterval / 5` |
| `targetBlockTime` | `3,600,000` ms | 1 hour |
| `retargetWindow` | `120` blocks | ~5 days; LWMA retarget window |
| `maxBlockSize` | `1,000,000` | 1 MB locked) |
| `maxStateGrowth` | `3,000,000` | 3 MB state delta per block |
| `maxNumberOfTransactionsPerBlock` | `5,000` | |

Protocol-wide constants that also bind Nexus (`ChainSpec`): `maxTargetChange = 2`
(retarget clamp), `minimumTarget = 1`. The unit of account is indivisible — the
smallest unit is `1` (any decimal places are a UI convention, not protocol).

## 2. Emission schedule

The per-block subsidy halves every `halvingInterval` blocks. The reward curve is
defined on an **offset index** that shifts the schedule forward by `premine` so the
premine occupies the front of the same curve (`ChainSpec.rewardAtBlock`):

```
rewardAtBlock(height) = initialReward >> ((height + premine) / halvingInterval)
                      = 1_048_576    >> ((height + 175_320) / 876_600)
```

(The implementation is total: an overflowing `height + premine`, or ≥ 64 halvings,
returns `0` — a content-addressed spec can never trap a validator.)

Because public mining begins at block height `0` but the curve is evaluated at
`height + premine`, **the first public halving happens early** — at
`halvingInterval − premine = 876,600 − 175,320 = 701,280` blocks (~80 years) — and
every `halvingInterval` (~100 years) thereafter.

| Epoch | Per-block reward | Public block range | ≈ wall-clock (1 h blocks) |
|---|---|---|---|
| 0 | 1,048,576 | `0 … 701,279` | first ~80 yr |
| 1 | 524,288 | `701,280 … 1,577,879` | next ~100 yr |
| 2 | 262,144 | `1,577,880 … 2,454,479` | next ~100 yr |
| … | (halves each epoch) | … | … |
| 20 | 1 | final epoch | |
| 21 | 0 | emission ended | ~2000 yr from genesis |

After 20 halvings the integer reward shifts to `0` and **emission terminates** — there
is no tail emission.

## 3. Premine

```
premineAmount = Σ rewardAtBlock over the first `premine` blocks of the curve
              = premine × initialReward          (premine < halvingInterval, so all
              = 175,320 × 1,048,576                premine blocks sit in epoch 0)
              = 183,836,344,320
```

(`ChainSpec.premineAmount()` computes the general epoch-spanning sum; for Nexus it
collapses to the product above because `premine` (175,320) is well under one
`halvingInterval` (876,600).)

- **Recipient:** `NexusGenesis.ownerAddress` — the CID address of
  `NexusGenesis.ownerPublicKeyHex` (`c01c054a…15fa4efd`).
- **How it enters supply:** the genesis block carries a single `AccountAction`
  crediting `premineAmount` to `ownerAddress`, with `fee = 0`, `nonce = 0`. It is
  *not* mined — it represents the blocks conceptually mined by the chain creators
  before public mining begins (see `spec.md §10.2`).
- **Share:** the premine is **exactly 10%** of total supply — by construction, since
  `premine = halvingInterval / 5` makes `premine·initialReward = 0.1 · (2·halvingInterval·initialReward)`.

## 4. Total supply

The reward is a halving geometric series, so the supremum of total emission is the
closed form:

```
maxSupply = 2 × halvingInterval × initialReward
          = 2 × 876,600 × 1,048,576
          = 1,838,363,443,200 tokens
```

The exact terminating emission (integer shifts, ending at epoch 20) is a hair under
this closed form — `halvingInterval × (2²¹ − 1) = 1,838,362,566,600` — the difference
being the single-block tail the geometric limit would add. For all practical purposes
**total supply ≈ 1.8384 × 10¹² tokens**, of which:

- **Premine:** 183,836,344,320 (10%)
- **Mined over ~2000 years:** the remaining ~90%

> Note: the `totalSupply` figure in the `NexusGenesis.swift` comment
> (`1,839,579,033,600`) is a slightly loose approximation; the closed form
> `2 × halvingInterval × initialReward` is `1,838,363,443,200`. Worth correcting the
> comment to match.

## 5. Block production & cadence

- **Target block time:** 1 hour (`targetBlockTime = 3,600,000` ms).
- **Retarget:** per-block clamped LWMA over a 120-block (~5 day) window, bounded to a
  factor of `maxTargetChange = 2` per block; a block's `target` is bound to its
  parent's `nextTarget`. See [`../spec.md` §5.5](../spec.md) and
  [`fee-market-and-51pct.md`](fee-market-and-51pct.md) for the retarget and the
  hashrate/attack-cost relationship.

## 6. Genesis identity (flag-day freeze)

Nexus ships a single, frozen flag-day genesis (no migration/versioning):

- `genesisTimestamp = 1_742_601_600_000` (fixed).
- `config = GenesisConfig(spec, timestamp, target: UInt256.max)` — genesis is mined at
  the easiest possible target.
- `expectedBlockHash = "bafyreieonsjxgx7d7cnbebfixgzcdoxopsbrfbbgujnqp74przhtmmbn5a"` —
  the pinned rawCID of the genesis built from `config`. `verifyGenesis()` enforces a
  built genesis matches this constant, so a node started against a divergent genesis
  (different economics, timestamp, or recipient) is rejected. **Any change to the spec
  or timestamp shifts this CID and must update the constant.**

## 7. Fees & value conservation

Fees do **not** inflate issuance. Under the locked fee model (Model A), the block
subsidy `reward(h)` is the *only* minting source; a transaction `fee` is an ordinary
signer debit credited to the miner via the coinbase (`reward + Σfees`), so it nets to
zero in the conservation identity:

```
totalCredits + totalDeposited == totalDebits + reward + totalWithdrawn
```

Full treatment — including why a declared fee with no backing signer debit cannot mint
— is in [`fee-market-and-51pct.md`](fee-market-and-51pct.md) and [`../spec.md` §8.2 / §12.2](../spec.md).

## 8. Source of truth

| Fact | Defined in |
|---|---|
| Nexus parameter values, premine recipient, genesis hash/timestamp | `lattice-node` → `Sources/LatticeNode/Chain/NexusGenesis.swift` |
| `rewardAtBlock` / `premineAmount` / `totalRewards` formulas | `Lattice` → `Sources/Lattice/Block/ChainSpec.swift` |
| Generic emission/premine/supply model | [`../spec.md` §10](../spec.md) |
| Fee market, 51%-cost, retarget→hashrate | [`fee-market-and-51pct.md`](fee-market-and-51pct.md) |
