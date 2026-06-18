# Fee-Market Equilibrium and the 51%-Cost Model (E4.4)

This note documents the economic equilibrium of the Lattice fee market under
the **Model A** issuance rule and the cost of a 51% attack against the Nexus
chain. It is a qualitative + concrete-where-locked artifact: numbers that follow
directly from the locked Nexus consensus parameters are stated exactly; numbers
that depend on external market inputs (coin price, $-per-hash) are presented as
named symbols with clearly-labelled placeholder example values.

E4.5 (issuance/supply schedule) and E4.6 (downstream economic models) cite the
same locked parameters reproduced here; this document is their numeric anchor.

For the full emission schedule, premine, and total-supply treatment, see
[`nexus-tokenomics.md`](nexus-tokenomics.md).

## Locked Nexus parameters

These are fixed by consensus and used verbatim (not derived):

| Parameter | Symbol | Value |
|---|---|---|
| Initial block reward | `initialReward` | `1048576` |
| Halving interval (blocks) | `halvingInterval` | `876600` |
| Premine (blocks of emission, = 10% of supply) | `premine` | `175320` |
| Target block time | `targetBlockTime` | `3_600_000` ms (1 h) |
| Max block size | `maxBlockSize` | `1 MB` |
| Target retarget | — | LWMA, window `N = 120`, per block |
| Retarget keystone | — | `block.target == parent.nextTarget` |
| Median-time-past depth | `MTP` | `11` |

Reward schedule (overflow-aware on master, `ChainSpec.rewardAtBlock`):

```
rewardAtBlock(h) = initialReward >> ((h + premine) / halvingInterval)
```

## Per-block revenue

A miner who authors the block at height `h` collects

```
R(h) = rewardAtBlock(h) + Σ (declared fees)
```

where `Σ (declared fees)` is the sum of the `fee` fields of the transactions
included in that block. The first term is *new issuance*; the second term is a
*redistribution* of value that already exists in account balances (proven
below). Only the issuance term expands the money supply.

### Concrete reward / halving check

Using the locked parameters, with `premine = 175320` and
`halvingInterval = 876600`:

- `h = 0`: `(0 + 175320) / 876600 = 0` halvings ⇒
  `rewardAtBlock(0) = 1048576 >> 0 = 1048576`.
- `h = halvingInterval = 876600`:
  `(876600 + 175320) / 876600 = 1051920 / 876600 = 1` halving ⇒
  `rewardAtBlock(876600) = 1048576 >> 1 = 524288`.

So `rewardAtBlock(876600) = rewardAtBlock(0) / 2`: the reward **halves** at the
halving-interval boundary, exactly as the schedule prescribes. (The locked
`premine` shifts the *first* halving earlier in absolute block height by
`premine` blocks, but the spacing between halvings remains `halvingInterval`.)

## Fee equilibrium under Model A (proof sketch)

The keystone claim is: **fees redistribute value but never inflate issuance, so
the author's net mint equals `reward` only.**

Consensus enforces conservation in
`Block+Validate.swift → validateBalanceChanges`, whose budget inequality is

```
totalCredits ≤ totalDebits + reward + totalWithdrawn − totalDeposited
```

Note what is *absent*: there is **no `totalFees` term**. The declared `fee`
field of a transaction does not appear in the conservation budget at all. The
only way value reaches the miner is through ordinary `AccountAction` deltas:

- a fee is expressed as an ordinary **signer debit** (`AccountAction(delta < 0)`
  on a signer) plus a matching **miner credit** (`AccountAction(delta > 0)`);
- the coinbase credits the author `reward + Σfees`, but each `+fee` credit must
  be funded by a corresponding `−fee` signer debit in the same action set, or
  the credit side of the inequality exceeds the debit side and the block is
  rejected.

Therefore, summing over the block, every funded fee contributes `+X` to
`totalCredits` and `−X` (i.e. `+X`) to `totalDebits`; the two cancel in the
inequality. The net new value the author can mint is bounded by `reward`:

```
author net mint = totalCredits − totalDebits − totalWithdrawn + totalDeposited ≤ reward
```

A "fee" that is *declared* but *not* backed by a signer debit cannot mint:
`totalCredits` would carry the miner's `+fee` credit while `totalDebits` carries
nothing for it, so `totalCredits > totalDebits + reward` and conservation fails.

This is a bug fixed in an earlier revision: an earlier `+ totalFees` term let a
declared fee enlarge the credit budget, minting coins out of thin air. Model A
removes that term, so a fee is purely a transfer from signer to miner.

### Keystone regression test

The equilibrium above rests entirely on the absence of the `totalFees` term, so
it is locked by a block-level regression test in
`Tests/LatticeTests/SecurityTests.swift`:

- `test_feeRequiresSignerDebit_blockRejected` — builds a Nexus block containing
  one signed `TransactionBody` that declares `fee = 50` whose signer has net
  account debit `0`, plus a miner self-credit `AccountAction(delta: +(reward +
  50))`. Driven through `Block.validateNexus(...)` (block-level entry, not the
  flattened helper), the block is **rejected**: `available = totalDebits +
  reward = reward`, but `totalCredits = reward + 50 > reward`, so the
  conservation check in `validateBalanceChanges` fails. This confirms a declared
  fee with no backing signer debit cannot enlarge issuance.
- `test_feeWithSignerDebit_blockValidates` — positive companion: the same shape
  but with the signer debited exactly `fee`. The block **validates**, proving
  the rejection above is for the conservation reason, not a blanket refusal of
  fees.

Both tests are green on `master`, confirming Model A is enforced at the block
level.

### Equilibrium consequence

Because fees never mint, the marginal block-space price is set purely by demand
for the scarce `maxBlockSize = 1 MB` per `targetBlockTime = 1 h`. In
equilibrium, a fee-paying user bids up to their private value of inclusion, and
the miner accepts any fee that exceeds their marginal cost of including the
transaction (≈ 0 at the margin, bounded by the orphan risk of a larger block).
Fees therefore clear a competitive market for block space without affecting the
issuance schedule — the security budget from issuance (`rewardAtBlock(h)`) and
the security budget from fees are independent and additive in `R(h)`.

## 51%-attack cost model

### From the retarget keystone to hashrate

The target keystone `block.target == parent.nextTarget` ties each
block to the LWMA retarget computed over the trailing `N = 120` window at the
`targetBlockTime` cadence. In steady state the network solves one block per
`targetBlockTime`, so the honest network hashrate `H` (hashes/second) satisfies

```
H ≈ D / targetBlockTime_seconds
```

where `D` is the *work* implied by the current `target` (expected
hashes per block; `targetBlockTime_seconds = targetBlockTime / 1000 = 3600`).
The LWMA window `N = 120` means roughly the last `120 h ≈ 5 days` of block times
drive the current `D`, so a sustained hashrate change is reflected in `D` within
that window — an attacker cannot instantaneously lower the difficulty they must
match.

### Cost to attack

To out-pace the honest chain a 51% attacker must sustain hashrate `> H` for the
duration of the attack. Introduce the two **external assumptions** (named
symbols, not derived from consensus):

- `c` = **$-per-hash** — the all-in marginal cost of one hash (energy +
  amortized hardware). *Assumption / placeholder:* `c = 1e-13 $/hash`.
- `p` = **coin fiat price** — used only to value the issuance/fees the attacker
  forgoes or the double-spend they gain. *Assumption / placeholder:*
  `p = 1.00 $/coin`.

For an attack sustained over `t` seconds at the minimum winning hashrate `≈ H`,
the direct energy/hardware cost is

```
costToAttack(D) ≈ c · H · t = c · (D / targetBlockTime_seconds) · t
```

Over a window of `k` blocks the attacker reproduces `k` blocks of honest work,
so equivalently

```
costToAttack(D) ≈ c · D · k      (D = expected hashes per block)
```

The attacker also forgoes the honest revenue they would have earned with the
same hardware, `≈ p · Σ_{i} R(h_i)` over the `k` blocks, which raises the
*opportunity* cost but is dominated by the direct term when `c · D ≫ p · R`.

#### Worked example (placeholder assumptions — illustrative only)

Assume the current difficulty implies `D = 1e18` expected hashes per block, an
attack spanning `k = 6` blocks (a 6-confirmation reorg), and the placeholders
above (`c = 1e-13 $/hash`, `p = 1.00 $/coin`):

```
costToAttack ≈ c · D · k = 1e-13 · 1e18 · 6 = 6e5 = $600,000
```

i.e. ~$600k of hash spend to rewrite 6 blocks, plus the forgone honest revenue
`p · Σ R(h_i)`. **`D`, `c`, and `p` are placeholders** chosen to exercise the
formula; substitute live network difficulty, the prevailing $-per-hash, and the
market price to obtain a real figure. The structural point is what the locked
parameters fix: the attack cost scales linearly with the difficulty `D` that the
`block.target == parent.nextTarget` keystone and the LWMA `N = 120` window pin
to sustained honest hashrate.

## Summary

- Revenue per block is `R(h) = rewardAtBlock(h) + Σ fees`; only the reward term
  is new issuance.
- Model A (`validateBalanceChanges`, no `totalFees` term) makes fees a pure
  signer→miner transfer; author net mint `≤ reward`. Locked by the keystone test
  in `SecurityTests.swift`.
- `rewardAtBlock(0) = 1048576`, `rewardAtBlock(876600) = 524288` (halves at the
  interval boundary).
- 51%-attack cost scales as `costToAttack(D) ≈ c · D · k`, with `D` pinned to
  honest hashrate by the retarget keystone + LWMA `N = 120` window, and `c`
  ($-per-hash) and `p` (coin price) supplied as external assumptions.
- E4.5/E4.6 cite these locked parameters.
