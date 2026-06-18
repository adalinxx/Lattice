# Consensus & Fork Choice

This document is the **design of record for Lattice consensus** — the definition
of a block, its proof-of-work, the work metric (`trueCumWork`), and the fork-choice
rule that follows from them. It is the narrative companion to the normative
statement in [`spec.md` §9](spec.md); the two must agree. Consensus is defined
**here, once**, in the library; the node's `docs/design/consensus-fork-choice.md`
covers only how the node *realizes* this and links back up.

> Consensus is the security expression of Lattice's **fractal structure** — a tree
> of chains in which a parent's proof-of-work secures the child blocks anchored
> under it, at every edge of the tree (organizing principle described in the
> `lattice-node` design notes, `docs/design/fractal-structure.md`). This document
> is the work-accounting and fork-choice specifics.

## Summary

A block lives in **two trees**. The **lattice** is a tree of *chains* — the
Nexus at the root (eventually anchored under Bitcoin), each chain securing its
child chains. The **block tree** is the per-block anchoring graph, built from two
*distinct* links: a **same-chain** link to the block's predecessor, and a
**cross-chain** link — by **hash** — to the *parent-chain block that secures it*.

Proof-of-work is *generalized*: a block at a given `target` is valid if some
committed data on an anchoring path hashes at or below the target; work is the
**target**, `max / target`. **Parents secure children:** a child block
inherits the proof-of-work of the parent chain above its anchor.

A block's fork-choice weight is **`trueCumWork`** — the sum of two parts:

- **own-chain work** — the proof-of-work the block piles on its *own* chain
  (accepted blocks only; work done on a *parent* chain doesn't count here).
- **inherited securing work** — the `trueCumWork` it inherits from the parent block
  that secures it, recursing toward the root.

Fork choice is simply **highest `trueCumWork` wins** — a single work metric, not a
two-tier positional key. The consequence is *shared security*: a weak or new
**child** chain inherits the full hashrate of the parent it anchors under. No work
number need be committed in a block, so this is not a block-format change.

---

## 1. The Block — and its two parents

A block sits in **two trees**; keeping them distinct is the whole game.

**The lattice — a tree of *chains*.** The Nexus is the root chain (eventually
itself anchored under Bitcoin); each chain may have child chains, recursively.
This is the static topology — who secures whom. *Every chain secures its
children through one shared proof-of-work.*

**The block tree — per-block anchoring.** Each block has **two different
parents**, and every rule below must say which:

- a **same-chain parent** — its *predecessor on the same chain* (the normal chain
  link). The block's own work piles **on top** of it; this is the link the
  own-chain work accumulates along (§3, §6).
- a **cross-chain parent** — the *block on the parent chain that secures it*,
  referenced by **hash**. The parent's proof-of-work covers the child; the child
  **inherits** the parent chain's accumulated work above that anchor. This is the
  link inheritance, `trueCumWork`, and fork choice follow (§3–§6).

**Parents secure children.** Security flows from the cross-chain parent *down* to
the child: a child block is valid because a parent block's PoW covers it, and a
weak/new child chain thereby rides the parent's hashrate (§5). The **anchor cap** —
one parent block secures ≤1 child block per child chain — bounds each *parent
block* to a single child per child chain; it does **not** restrict a child to a
single securing parent. A child is secured by **every** parent block that committed
it (usually exactly one, occasionally several — §3); their subtrees are unioned with
each block counted once (GHOST), so work stays attributable without double counting
even under multiple securing parents (§3, §6.2).

A block commits its cross-chain parent reference and its `target`; no work
number is committed. How a node identifies a block's securing parent(s) and
computes the inherited term is an implementation concern (§6, §7) — the model
requires only that the securing parent is the parent-chain block that committed
this child, and that the anchor cap keeps that relation a tree (so work is
attributable without double counting).

## 2. Proof-of-work (generalized)

We do **not** prescribe how a block is "mined." A block at `target` `D`
is valid if:

> there exists an anchoring path `A → … → block` such that `hash(A) ≤ D`.

That is: some committed preimage on a path that reaches the block hashed below
the target. Whatever data `A` is, and however it was produced, the *existence*
of such a path is the proof. Finding `A` with `hash(A) ≤ D` costs ≈ `max / D`
expected hashing — that is the block's **work**:

```
work(block) = max / block.target
```

`target` is a *threshold*: a smaller `target` requires a lower hash
⇒ more work (a larger `target` is easier to satisfy). Work is the **target**, never the actual achieved hash: the achieved
`hash(A)` only has to clear the bar (`hash(A) ≤ D`) for *validity*; the credited
work is `max/D` regardless of how lucky the hash was. (Crediting the actual hash
would be high-variance and grindable — a miner could hunt for an unusually low
hash to claim outsized work.) So: **achieved hash → validity only; the
`target` → work; each block credited its own independent grind, once (§3.1).**

This generalizes self-mined PoW (the preimage is the block's own content) and
anchored/merged PoW (the preimage lives on a parent path) under one rule. The
validity gate is therefore role-shaped but uniform in spirit:

- **Root chain:** the path terminates in the block's own content —
  `target ≥ proofOfWorkHash()` (self-anchored).
- **Child chain:** the path runs through the anchoring parent block —
  `target ≥ anchorParent.proofOfWorkHash()`, **and** a merged-mining proof
  that the parent block *committed to this child* (see below).

> **Inheritance must be earned — two linked commitments.** The `target` gate and
> the anchor cap are **not sufficient** to let a child claim the parent's work: a
> miner could otherwise point a brand-new child at any old high-work parent and
> claim all the work above it, having done nothing. Two commitments, in opposite
> directions, close this — and they are arranged to avoid a circular reference:
>
> - **Child → parent (the anchor), non-circular.** The child commits to the parent
>   chain block's **previous state**: `child.parentState == parentChainBlock.prevState`
>   — data that exists *before* the parent block is assembled, **not** the parent
>   block's own hash (the parent *contains* the child via `parent.children`, so that
>   would be circular). (No `coreId` split is needed — the child is fully determined
>   before the parent, so the parent commits to the *full* child.)
> - **Parent → child (the proof), anti-freeload.** A parent block secures this child
>   only if it actually includes it — `parent.children ∋ child` — proven by the
>   mandatory **`ChildBlockProof`**.
>
> A child may be secured by **multiple** parent blocks (each that committed it):
> the pair (`prevState` match **and** commitment) identifies *all* of them, and the
> child inherits the **GHOST subtree** over that securing-parent set (§3, §6) — the
> "subtree aspect applied to parent chain blocks." This is intended, not an
> ambiguity: two parent blocks sharing a `prevState` (e.g. across a no-op) both
> legitimately secure the child iff both committed it; the commitment-check excludes
> any that did not.
>
> No cycle: `parent.prevState → child (commits parentState) → child CID →
> parent (commits child in `children`) → parent.hash`; the child's CID never
> depends on the parent's hash. The anchor cap prevents *re-using* one parent slot
> for two children. Inheriting work (§3, §6) requires **both** commitments on the
> anchor link; without them the cross-chain term is `0` (the child is, at best,
> self-mined on its own chain).

`target` itself is not free: it must follow the retarget schedule
(`nextTarget` is bounded by a windowed-timestamp adjustment, and a block's
`target` is its predecessor's `nextTarget`). Otherwise `max/target`
would be a number anyone could inflate by declaring an easy target.

## 3. `trueCumWork` — the work metric

The security weight of a block is the **total work of its subtree, counting each
block exactly once** — **GHOST** applied in *both* dimensions: its own chain's
work piled on top of it, **and** the work of the parent block(s) that secure it
(and their subtrees), recursing toward the root.

```
trueCumWork(B) =  work to redo B and everything above it on B's own chain   // own-chain term, inclusive of B
              +  trueCumWork of B's securing parent(s), counted once         // inherited, recursing toward the root
```

where the securing parents are *all* parent blocks that committed `B` —
**usually exactly one**, occasionally several.

**Convention: inclusive of `B`.** Reorging `B` means redoing `B` *and* everything
after it, so the own-chain term weighs the whole segment from `B`'s same-chain
**parent** onward, not from `B` — otherwise a tip would score zero against its own
chain and forks couldn't be compared. The recursion bottoms out at the root chain
(Nexus, eventually Bitcoin), which has no securing parent.

**Count once.** When `B` has several securing parents, their subtrees may
**overlap** (e.g. two on the same parent fork — the no-op `prevState==postState`
case, §3.2), so the GHOST term unions them and counts each block once; it never
sums overlapping work twice. The single-securing-parent case (the norm) is just
`+ trueCumWork(thatParent)` — the O(depth) recursion of §6, no dedup needed.

Because **parents secure children** (§1), the inheritance flows *from the parent
chain down*: a child block's reorg cost is dominated by the **parent's**
accumulated work above its anchor — which is exactly the shared-security pitch
(§5). This is *not* a sum over descendants; a busy child chain does not make its
parent harder to reorg (the child rode the parent's work, it didn't add to it,
unless the child *self-mines* — §3.1).

**No double counting (structural).** Each block has exactly one cross-chain parent
(the anchor cap, §1), so the recursion walks a path toward the root, never a graph
— each ancestor's work is added once. Each *grind* is counted once at the block
that performed it (§3.1), and only if accepted on the chain (§3.2).

### 3.1 Count each block's own independent work — once

There is a second, subtler double-count to avoid, from *merged mining*: a single
physical grind can satisfy a self-mined block **and** be referenced by anchored
blocks on other chains. The hash was found once; it must be counted once. So the
unit of accounting is the **grind**, credited to the block that performed it.

> **Credit rule.** A block contributes its **own independent work** — the grind
> it performed *beyond what its anchor already provided* — to its chain's work,
> and each physical grind is counted **once, at the block that performed it**:
> - **purely anchored** block → **0** (its `target` is only a *claim* on the
>   anchor's grind, `target ≥ anchorParent.proofOfWorkHash()`, §2, bounded
>   by what the anchor already achieved — no new work);
> - **self-mined** block (a root, *or an intermediate chain that self-mines*) →
>   its own `max/target`;
> - **anchored *and* independently grinding** (an independent preimage `A'` with
>   `hash(A') < anchorParent.hash`, beating the anchor) → its **marginal** own
>   work, the part beyond the inherited claim.

**"Root of the block tree" is only the common case.** A path `A → … → block` is
often assumed to contain one grinder (the topmost root `A`), but it need not: an
intermediate block can self-mine *on top of* its anchor, contributing real work a
non-root block performed. That work exists nowhere else in the tree, so counting
it is not double-counting — dropping it would *under*-count security. The rule is
therefore per-block own-work, summed over the subtree, **not** "only the root."

A block's own work is **not new information**: the role-correct PoW gate already
tells us whether (and how) a block satisfies its target by its own grind vs. by
inheriting an anchor's. Each block contributes its own independent work —
`max/target` when self-mined, `0` when fully anchored, the marginal part when
both — to its own chain's accumulated work.

The consequence is that a *purely* anchored child chain has ≈0 independent work —
its security is the root's work above its anchor (the shared-security property §5
relies on) — while a chain that does its own PoW *adds* that work, counted once at
its blocks. Each grind is credited exactly at its origin, never twice and never
zero-when-real.

### 3.2 Only *accepted* blocks accrue work

A grind's nominal root may not be a block Lattice **accepts** at all. The PoW
root can sit *outside* the accepted tree — the eventual external root (Bitcoin:
Lattice anchors to a Bitcoin block but never accepts it as a *Lattice* block), or
a would-be root the root chain **rejected/orphaned** while a child still accepted
the PoW. In those cases "the block tree isn't accepted at the root, only at the
children." Work cannot be credited to a block that is not in the tree.

> **Acceptance rule.** Backward `cumWork` accrues **only over blocks accepted into
> the block tree**, and a grind's work lands at the **boundary where it first
> enters that tree** — the *highest accepted* block carrying it.
> - A child anchored to an **accepted parent** inherits (own work 0 / marginal).
> - A block whose only root is a **genuinely external root** (Bitcoin — *by
>   definition* never a Lattice block) is itself the entry point and accrues the
>   **full** work. This is deterministic: "external" is a fixed property, not "I
>   haven't synced it."
> - A child whose Lattice parent the node **has not yet accepted** (not synced, or
>   reorged out) is **pending** — *not* yet classified as anchored, and *not* given
>   full credit. Its anchored classification (and cumWork) resolves once the parent
>   is accepted. So "unaccepted Lattice parent" never silently becomes "full
>   credit"; only true external roots do.

This keeps `cumWork` **deterministic relative to the accepted tree** — the
consensus view. Two honest nodes that have accepted the same tree compute the same
`trueCumWork`; a node mid-sync may have a *pending* child, which resolves to the
same value on convergence (it never diverges to a different accepted number). This
is the **single acceptance chokepoint** invariant (§7, epic F5): `trueCumWork` is
summed only over accepted blocks and is derived from that accepted tree, not a
committed wire value.

## 4. Fork choice — highest `trueCumWork` wins

> **Every chain follows the fork of greatest `trueCumWork`.**

There is no separate primary/secondary key. A fork's weight is its
`trueCumWork` (§3) — own-chain work on top, plus inherited work from the
cross-chain parent — and the canonical fork is simply the one with the most.

For the **root chain** (Nexus) this is ordinary heaviest-chain: a block's
own-chain work, inclusive of `B` (§3). For a **child** chain it is
*inheritance-dominated*: a child block's weight is mostly its cross-chain parent's
`trueCumWork`, so a child **rides whichever parent fork carries the most work**.
The old `(parentIndex, work)` two-tier key was a *positional proxy* for this —
"anchored earlier = more parent history behind me." A single `trueCumWork` max
replaces the proxy with the real inherited work.

This is **not** a lexicographic re-implementation of the old key: with real
inherited work, a child anchored *later* to a **heavier** parent fork can
correctly beat one anchored *earlier* to a lighter fork — "most actual inherited
work wins," which is the intended rule, not "earliest anchor wins."

Children **select** the heaviest parent fork; they do not *make* it heaviest —
parent heaviness is determined by the parent/root chain's own work (child work
does not flow upward, §5). Convergence is therefore driven by the root chain and
is stable under an honest majority of the *root* hashrate that secures the tree.

## 5. Why this is the right metric — security

**`reorgCost(B) = trueCumWork(B)`.** To reorg block `B`, an attacker must produce
an alternative through `B'` whose `trueCumWork` *exceeds* `B`'s. Because a child's
weight is dominated by the **inherited** parent work, flipping a child block means
out-producing the **parent chain's work above its anchor** — not merely the
child's own (≈0) work. The attacker cannot orphan a child "for cheap": the child's
security *is* the parent's accumulated PoW.

The payoff is **shared security in the direction parents → children**: a weak or
brand-new **child** chain inherits the full hashrate of the parent it anchors
under. It needs no hashrate of its own to be hard to reorg — anchoring to the
Nexus (eventually Bitcoin) buys it the root's security immediately. That is the
property the fractal design exists to provide, and a per-chain work metric would
*not* give a new child chain this protection.

(The converse does **not** hold: a busy child does not make its parent harder to
reorg, because the child rode the parent's work rather than adding to it — unless
the child *self-mines* independent work, §3.1, which then counts on the child's
own chain, not the parent's.)

## 6. Efficiency — `trueCumWork` is cheap to evaluate

`trueCumWork` is a **forward** sum (a block's own-chain work plus the work it
inherits from its securing parent), which sounds like it must be recomputed every
time the chain extends. It need not be: **an O(depth) evaluation exists**, because
the metric decomposes into two terms, each cheap to obtain.

- **Own-chain term** — the work to redo `B` and everything above it *on its own
  chain*. A single chain-local quantity; it does not require walking the
  descendant subtree. Per §3.1/§3.2 a fully anchored chain's own term is ~0, and a
  self-mining chain credits its own work here.
- **Inherited term** — the `trueCumWork` of `B`'s securing parent, recursing up
  the hierarchy to the root. Depth is the fixed number of levels, so the recursion
  is O(depth) ≈ O(1).

Neither term needs a new committed block field, and neither forces a global
recompute on insert: a same-chain extension only grows the own-chain term, and a
cross-chain parent reorg never moves an existing child block — it only changes
*which competing child fork* is canonical (§6.1).

> This section asserts only that such an evaluation **exists** and is O(depth). It
> deliberately does not prescribe *how* a node obtains a securing parent's
> contribution, nor any index, prefix-sum, or data structure — those are
> implementation choices, not load-bearing to the model.

### 6.1 Inheritance under a parent reorg

A block's securing parent can exist on more than one competing parent fork. The
inherited term must be measured on a parent fork the anchor actually belongs to:

- If the anchor is on the **canonical** parent fork, the child inherits the full
  canonical parent work above it — large.
- If the anchor was **orphaned** by a parent reorg, the child inherits only the
  *orphaned* fork's work (now small/dead). The child does **not** silently
  re-anchor; instead fork choice prefers a **competing child block** anchored to
  the now-heavier parent fork, whose `trueCumWork` is higher because its inherited
  term is the canonical parent's. Children thus *ride the heaviest parent fork*
  purely through the `trueCumWork` max — no special re-anchor logic — provided the
  inherited term is always evaluated against a parent fork the anchor descends
  from, never the global parent tip blindly.

### 6.2 Cost of the inherited term — common vs. rare

- **One securing parent (the norm):** the inherited term is just that parent's
  `trueCumWork` — the O(depth) recursion above, no dedup.
- **Several securing parents (rare):** their contributions may overlap, so they
  must be **unioned with each block counted once**. This is the only place the
  evaluation re-enters a walk, and it is acceptable because it is **PoW-gated**:
  every securing parent is a distinct PoW-backed block, so an adversary cannot
  cheaply manufacture many to blow up the union — the cost is rate-limited by real
  hashing and arises only in that uncommon case.

The own-work credit rule (§3.1) is what makes the cross-level sum exact: a fully
anchored chain's own term is ~0, so its parent's work is not re-added to it, and a
self-mining chain contributes its own work at its own blocks. **Each grind is
counted once.**

### 6.3 Fork choice on top

Fork choice compares **forks at their branch point**, not tips in isolation. At a
common ancestor `A`, each competing fork is weighed by the `trueCumWork` of its
first divergent block (evaluated with that fork's tip) — by the inclusive
convention, exactly the whole fork segment plus its inherited term. Take the
**max** over forks: a single metric, no separate primary key (§4). (Scoring the
*tip* block instead of the fork base would compare only each tip's own one-block
work — wrong; always weigh the fork from the **common ancestor**.) A securing
parent's reorg doesn't move existing child blocks — each stays pinned to its
committed parent hash (§6.1) — it only changes which competing child fork is
canonical.

> **Boundary care.** The own-chain term and the inherited term must partition the
> work with each block counted once; the seam where a child segment meets its
> anchor is where a double-count would creep in. This is the one spot to test
> hard, and the strict anchor tree (§1, anchor cap) is what makes a clean
> partition possible.

## 7. Realization

The model above is the consensus of record; it is realized in the Lattice
consensus library and the per-process node wiring (F5). Two load-bearing
properties carry over verbatim and are what the implementation must preserve —
independent of *how* it stores or transports anything:

- **Fork choice is a single `trueCumWork` max.** One metric, no secondary
  positional key. A block's weight is its own-chain segment plus its inherited
  securing weight (§3, §6); the heaviest fork wins (§4).
- **One acceptance chokepoint, on every path.** `trueCumWork` is summed only over
  blocks that passed acceptance, and the *same* gate must run on every path that
  installs chain state — gossip/extend **and** sync/replace alike. The recurring
  class of consensus bug is a sync/replace path skipping what the gossip/extend
  path enforces; a single chokepoint is what closes it.

How a node obtains a block's inherited securing weight, and how it stores or
indexes anything to do so, is an implementation concern deliberately left out of
this document — it lives in the Lattice consensus library and the per-process node
wiring, not in the model.

## 8. Open questions

To be stress-tested before this is treated as settled — not objections to the
model:

1. **Balance / splitting attacks.** Can an adversary keep two *parent* forks
   near-equal in `trueCumWork`, so children oscillate between which parent they
   ride, delaying convergence without majority hashrate? Since a child's weight is
   inherited, this routes through the *root/parent* chain's own balance — analyze
   whether the cross-chain inheritance amplifies or dampens it.
2. **Convergence under latency.** "Children ride the heaviest parent" is a
   fixpoint stable under an honest majority of *root* hashrate, but it must
   converge fast relative to block time and not oscillate when two parent forks
   trade the lead — where it interacts with reorg-thrash and the parent-reorg
   machinery.
3. **Cap as tree-invariant.** The anchor cap is what keeps each block's
   cross-chain parent **unique**, so `trueCumWork` recursion walks a *path* to the
   root rather than a graph (no block inherited twice — which *would* double-count).
   Confirm that is its enforced role.
4. **Self-mining children.** The metric admits a child chain that does its *own*
   independent PoW (§3.1) — its work then counts on its own chain, not the
   parent's. Confirm the intended interaction: does a self-mining child's work
   ever flow *back up* to secure its parent, or strictly stay on its own chain?

---

## References

- Fractal structure — the organizing principle this secures (`lattice-node` `docs/design/fractal-structure.md`).
- [`spec.md` §9](spec.md) — the normative consensus statement this narrates.
- Sompolinsky & Zohar, *Secure High-Rate Transaction Processing in Bitcoin* (GHOST), 2015.
