# Subtree work by spine accumulation

Status: **PAUSED — do not wire this.** The structure is built and its arithmetic
is proven, but there is a principled objection that goes underneath the rule,
recorded immediately below. This note survives outside the review thread because
the reasoning is worth more than the code, and because a rule that has now been
stated wrongly three times is worth a written record.

## Why it is paused: canonicity and work must be orthogonal

Fork choice reads weight in order to decide canonicity, so a weight structure
keyed on canonicity is circular. The spec states the property directly: *"moving
only a parent's preferred pointer adds no physical work and therefore cannot
move the child tip"*. A pure canonicity change must therefore cause **zero**
churn in the work structure.

**The measurement in this document is the evidence against its own design.** 400
spine displacements over 400 heights, each freezing one block and stamping
another — and not one joule of work moved in any of them. That entire re-basing
workload is an artifact of tying the accumulator to the spine, not a property of
the chain.

The structure this would replace does not have the problem. An Euler range is
keyed on the **block tree**, so when a sibling loses to its canonical rival,
nothing happens at all.

So the spine restriction was a performance hack: it shrinks the correction set
from "all non-ancestors", which is Θ(n), down to a suffix — and canonicity is
what it smuggled in to pay for that. The arithmetic below is sound; keying it on
canonicity is the part being rejected.

## What it replaces, and why

Subtree work is currently an Euler range query: O(log n) per admission, no
special cases. The requirement is that the **common-case insertion be constant
time**. The accumulator meets that; the Euler structure cannot, because a
balanced sequence tree pays a logarithmic path on every insert by construction.

Measured on a 400-height merged-mining sync, the Euler structure costs about 11
node touches per admission (18,894 cells over 1,600 admissions). The accumulator
takes the common case to one add and one stamp.

That comparison flatters the accumulator, and the honest version is worse for it
in three ways:

- **The worst case regresses.** Euler is ~11 touches *uniformly*; the accumulator
  is 1 in the common case but 399 on the measured deep restrike. Trading a flat
  cost for a spiky one is a different decision from trading 11 for 1.
- **The complexity cost has a concrete measure**: this rule has been stated
  wrongly three times. That is the best available evidence of what it costs to
  hold in a reader's head, and it is worth more than an estimate.
- **The depth measurement is of honest mining.** It shows where work *happens to*
  land, not where an adversary *could* place it. Securing work enters at a
  carrier's depth, and nothing in the measurement bounds an adversary who
  chooses that depth deliberately.

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

## Three statements of this rule have been wrong, and why

The count matters, so it is stated plainly: the **inversion** (storing work
outside the subtree), the **height gloss** (writing the ancestor test as a height
test), and the **example used to justify fixing the gloss** (a shape that does
not in fact separate the two rules). Each was caught by re-derivation rather than
by a test, which is the argument for the re-derivation step — and also the
clearest signal available about how hard this rule is to hold correctly.

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

**This is not yet proven.** `SpineWorkAccumulatorOrderTests` asserts that the two
delivery orders agree, but it does **not** discriminate between the two rules,
for two reasons:

- In that shape the rules compute the same set. The fork sits at height `h-1`
  and the sibling at `h`, so "spine blocks above the fork" and "spine blocks at
  height >= h" coincide. The rules separate only when the mutated block is
  already on the spine, or when a fork sits well below `h`, and that shape
  contains neither.
- More fundamentally, `apply` takes `correctingNonAncestors` as a **parameter**,
  so the test supplies the very rule it purports to check. That is a boundary
  problem, not a coverage gap: no choice of shape fixes it.

So stage one proves the accumulator's **arithmetic**, and its order-independence
**given correct sets**. The height-versus-ancestor rule is **unproven until
wiring**, because the rule lives in the caller.

### The general form of that mistake

**A test cannot validate a rule it is also supplying.** Whenever a function takes
the answer as a parameter, tests of that function pin arithmetic, never policy,
and the policy proof must live at the layer that computes the parameter. This
boundary has now been mistaken twice, so it is written down rather than
remembered.

### Acceptance criterion for the discriminating test

The next stage is not complete until a test exists that would **fail against a
height test**. It must:

- be a **`ChainState`-level** test, with the correction sets computed by
  production code rather than supplied by the test;
- fail against the **height test substituted for the ancestor test**, verified
  as a marker-checked planted bug rather than inferred from a passing run;
- run on shapes where the two rules actually separate.

**This list has itself been wrong.** "A sibling forking well below the tip" does
not separate them: a one-block sibling sits exactly one block above its fork, so
`f = h-1` and "above the fork" and "height >= h" compute the same set *however
deep the fork is*. Fork depth is irrelevant. What matters is the depth of the
admitted block **below** the fork. The minimum sufficient set is three shapes:

1. a **restrike on a block already on the spine** — separates "not
   ancestors-or-self" from "height >= h", which wrongly includes the block
   itself, though it must gain the work;
2. a **one-block sibling delivered canonical-first** — separates "height >= h"
   from "height > h", since the canonical rival at height `h` is a non-ancestor
   and must be corrected;
3. a block **two or more deep inside an off-spine branch** — its deepest spine
   ancestor is at `f`, so the correction must start at `f+1`, while any height
   form starts at `h >= f+2` and misses the spine block at `f+1`. This shape
   separates both.

Stage one contains none of the three.

### Two defects in the stage-one structure

Recorded rather than fixed, because the design is paused and both are
instructive:

- **`apply` trusts the caller's `base` on a joiner.** It discards any existing
  `direct[hash]` without checking the supplied `base` matches it, so a caller
  that takes a fresh reading instead of passing the maintained total is
  undetectable. The parameter is load-bearing and unvalidated.
- **The freeze loop can mutate and then fail.** `preIncrement.subtracting(taken)`
  can return nil mid-loop, after earlier leavers have already been written to
  `direct` and removed from the spine — a partial mutation in a structure with
  no undo. This is the same class as the `splice` pre-validation issue in #23,
  which took two rounds to close there; the up-front validation added here
  checks membership but not that every subtraction will succeed.

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
5. The discriminating test described above — the one that would fail against a
   height test. Until it exists, the central rule of this design rests on
   derivation alone, which is the weakest footing of anything claimed here.
5. Retire the Euler range structure once fork choice reads the accumulator, and
   collapse `canonicalProjectionSegmentVisitCount` into the block counter, which
   has been provably redundant since the quotient was deleted.
