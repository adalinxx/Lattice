# Subtree work by spine accumulation

Status: **design landed, structure built and proven, not yet wired into fork
choice.** This note records the derivation so it survives outside the review
thread, including two rules that were wrong on the first and second statements
and why.

## What it replaces, and why

Subtree work is currently an Euler range query: O(log n) per admission, no
special cases. The requirement is that the **common-case insertion be constant
time**. The accumulator meets that; the Euler structure cannot, because a
balanced sequence tree pays a logarithmic path on every insert by construction.

Measured on a 400-height merged-mining sync, the Euler structure costs about 12
node touches per admission (18,894 cells over 1,600 admissions). The accumulator
takes the common case to one add and one stamp. That gain is real but modest in
absolute terms, and it buys spine/off-spine duality and re-basing on reorg. The
tradeoff is recorded here rather than assumed away.

## The rule

Each block on the canonical spine stores `base`, its subtree total when stamped,
and `snapshot`, the accumulator's value at that moment:

```
subtreeWork(B) = base(B) + (accum - snapshot(B))
```

Admitting work `w` at block X:

1. `A0 = accum`
2. **Freeze every leaver at `A0`**, using its pre-bump stamp.
3. `accum += w`
4. **Correct the spine blocks that are not ancestors-or-self of X.**
5. **Stamp each joiner at the post-increment `accum`**, with `base` set to its
   true current subtree total.

## Why it is sound, and exactly when it stops being sound

One predicate licenses the formula: **every admission since a block was stamped
has been a descendant of it.** While that holds, `accum - snapshot` is exactly
the work added inside that block's subtree. The moment an admission is not a
descendant, the accrual is invalid and the block must stop accruing — which is
what leaving the spine means.

So the on-spine flag is not bookkeeping. It is the predicate that licenses the
formula, and a block is frozen at the instant the predicate fails. A rule
expressed that way fails loudly; one expressed as a bookkeeping bit can be
deleted by a later tidy-up without anything noticing.

Freezing uses `A0` and not the incremented value because the block being
admitted is, by construction, not the frozen block's descendant.

## Two rules that were wrong, and why

### The repair set is the ancestor line, not its complement

An earlier formulation stored "work outside the subtree when the block arrived"
and derived the total as `total - outside`. That inverts the quantity. With
`outside(B) = W_arrival - own(B)`:

```
total_now - outside(B) = dW + own(B)        // dW is ALL work added since
true subtreeWork(B)    = own(B) + dW_inside(B)
```

These agree only if every later admission landed inside B's subtree. A losing
sibling has `dW_inside = 0` while the chain keeps extending, so its total would
grow without bound. Repairing that means touching every block that is **not** an
ancestor of the new block — on a merged-mining shape, roughly n losing siblings
on every tip extension. That is quadratic on the exact workload the preceding
work existed to fix.

The correct statement is the inverse: `subtreeWork(B)` changes exactly when the
admitted block is a **descendant** of B, so the repair set is B's ancestor line.
The losing siblings are not ancestors and correctly receive nothing.

### Step 4 is an ancestor test, not a height test

"Spine blocks at height >= h" and "spine blocks that are not ancestors-or-self of
X" are the same set **only while X attaches at the tip of the spine**. They
diverge in two reachable cases:

- **A stronger observation on a block already on the spine.** The height form
  includes X itself, which must gain the work.
- **A sibling arriving after its canonical rival.** X attaches off-spine under a
  fork at height `f`, so its ancestors are not a spine prefix ending at `h-1`,
  and the suffix to correct starts above `f`, not above `h`.

The second is the dangerous one. The merged-mining measurement delivers the
sibling *first*, so it is briefly on-spine and the height form works there. Under
the reverse delivery order the sibling is off-spine on arrival and the height
form is wrong — passing the entire measurement while being silently wrong one
delivery order over.

`SpineWorkAccumulatorOrderTests` asserts the two delivery orders agree, which is
what closes this.

### Stamping is post-increment

`snapshot(B)` is read **after** `accum += own(B)`. Stamping before makes a
block's own work count twice — once in `base`, once again in `accum - snapshot`
— giving `subtreeWork(R) = 2 * own(R)` for a lone root. The ordering reads as
arbitrary at the call site, so it is asserted by a test rather than left to a
comment.

## What the cost model rests on

Measured, not assumed, on a 400-height merged-mining sync:

| observation | value |
|---|---|
| ordinary admissions | 800, **all at depth 0** from the tip |
| late restrike (securing work) | reached depth **399** |
| spine displacements | **400** over 800 admissions, **max 1 block removed** |

Read together: optimise the tip case, because that is every ordinary admission;
the deep case is real but rare, so O(distance from tip) is acceptable there; and
re-basing is *frequent but constant-sized*, so both directions of it must be
O(1) — which is why the freeze and the stamp are each a couple of arithmetic
operations.

The displacement figure needed no production instrumentation:
`ChainCommit.mainChainBlocksRemoved` is already public, so the measurement added
no counter, no threshold and no change to the admission path.

## Spec constraints honoured

- §9.2 permits it: implementations may cache local totals while the accepted
  graph and unique proof-derived work facts remain authoritative. The
  accumulator is derived and rebuildable, never a durable fact.
- `WorkSum` must not wrap or saturate, so `accum >= snapshot(B)` is a guard that
  fails closed, not an assumption. `debugStampsAreInThePast` asserts it.
- Measure union occurs before totalling, so the additivity dependency is
  unchanged and `testAGrindIdentityCannotOccupyTwoBlocks` stays load-bearing.
- Promotion between weighed and validated moves no weight, and inherited work is
  not a second comparison term, so neither needs a special case.
- Exclusion subtracts, and the spec mandates reprojection rather than
  incremental repair — the existing full-rebuild path.

## What remains

The structure is proven in isolation; it is **not** wired into `ChainState`.
Remaining:

1. Compute the leaver, correction and joiner sets from the real graph at each
   admission, and drive `apply` from `projectCanonicalChain`.
2. Maintain off-spine subtree totals directly, including their own ancestors up
   to the fork.
3. Rebuild the accumulator from the accepted graph on restore and on the
   exclusion rebuild.
4. A `ChainState`-level order-independence test, which is what §9.9 actually
   requires; the accumulator-level test here is narrower by design.
5. Retire the Euler range structure once fork choice reads the accumulator, and
   collapse `canonicalProjectionSegmentVisitCount` into the block counter, which
   has been provably redundant since the quotient was deleted.
