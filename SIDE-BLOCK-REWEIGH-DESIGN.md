# Side-block re-weigh on re-admission (fork-choice re-entry)

Lattice 28.0.0 · branch `fix/side-block-reweigh`

## Symptom

An adopting child host B (whose parent chain is a follower that never mined the
child carriers) cold-syncs child blocks and receives each block's evidence
piecemeal. A child block can be **accepted** into the consensus graph before the
fork-choice landscape that would make it canonical is complete (its inherited
parent/carrier weight, or its predecessor's canonical standing, connects a moment
later). At that instant fork choice does not select it, so it is stored as a
weightless **side** block (`ChainCommit.canonicalChanged == false` →
`.acceptedSide`).

When the completing evidence arrives moments later, the block is **re-admitted**.
Because the block already exists in the graph and this admission carries no
*stronger* work contribution, Lattice short-circuits to `.duplicate` **without
re-running fork choice**. The side block is therefore never promoted, and B's
tip stays at genesis forever. On a many-core box all evidence is present on the
first admission, so it canonicalizes immediately — this is why the failure is
2-core-Linux-timing-specific. Evidence: across 811 admission outcomes on Linux,
0 were `canonicalized`.

## Where it lives (Lattice 28.0.0, file:line)

Canonicity is a **pure function of the durable accepted graph**:
`ChainState.projectCanonicalChain()` (`Sources/Lattice/Lattice/Chain.swift:2534`)
re-derives the heaviest chain from `hashToBlock` + `segmentIndex` +
`segmentWorkIndex`. Every graph/work mutation runs it —
`submitBlock` (`Chain.swift:1226-1231`) and `addWorkContribution`
(`Chain.swift:1830`). The public re-entry that re-runs exactly this selection and
returns a `ChainCommit` iff the tip moved already exists:
`reevaluateForkChoice()` (`Chain.swift:898-906`) — deterministic, bumps the
revision only on an actual change, returns `nil` otherwise.

Inherited/merged parent weight is not a separate fork-choice term: it is folded
into a child block's `VerifiedWorkContribution.work`
(`= max(strongestAncestorWork, workForTarget(child.target))`,
`ChildBlockProof.swift:416-430`) and routed into `segmentWorkIndex`. So a genuine
weight increase for a block flows through `addWorkContribution` and *does* re-run
fork choice. The gap is only the **no-new-work re-admission** path.

The two seams that return `.duplicate` **without** re-running fork choice:

1. `ChainLevel.resolveDuplicatePreflight(_:)`
   (`Sources/Lattice/Lattice/ChainLocalAdmission.swift:975-997`) — the primary
   path. `ChainLocalAdmission.prepare` classifies an already-known block whose
   recorded contribution is `>=` the incoming one as a duplicate
   (`ChainLocalAdmission.swift:584-609`); the node resolves it here. It only
   rechecks ancestry/predecessor and returns `.duplicate(carrierLink,
   sameChainPredecessor:)`. **No projection.**

2. `ChainLevel.commitPreflight(...)`
   (`ChainLocalAdmission.swift:1043-1048`) — `applyReservedStaged` →
   `applyStaged` returns `nil` when the existing contribution is not weaker
   (`Chain.swift:1872-1878`, `1903-1908`), and `commitPreflight` returns
   `.duplicate`. **No projection.**

Node consequence (`/Users/josephbao/src/lattice-node`): `NodeAdmissionDecision`
maps `.accepted` to `.canonicalized` iff `commit.canonicalChanged`, else
`.acceptedSide`; it maps `.duplicate` to `.duplicate`, which carries no commit
(`AdmissionDecision.swift:14-27`). `.duplicate` never publishes a canonical tip
(`ChainProcess.swift:936-941`) and never reconciles
(`ChainService.swift:1800-1810`). There is **no** `reevaluateForkChoice` call
site in the node.

## Fix (minimal, localized, fail-closed)

Re-run the **existing** heaviest-selection at the duplicate seam and surface any
resulting promotion. Reuse `reevaluateForkChoice()` — no new consensus concept,
no new stored state, no change to the weight model.

### Lattice

1. Extend the already-present `.duplicate` result to optionally carry the
   promotion commit:
   `case duplicate(ParentCarrierLink?, sameChainPredecessor:…, promotedCommit: ChainCommit? = nil)`
   (`ChainLocalAdmission.swift:119`). Update the `commit` accessor
   (`ChainLocalAdmission.swift:154-159`) to return `promotedCommit` for
   `.duplicate`, and the two other pattern matches (`:140`, `:169`).

2. In `resolveDuplicatePreflight` (`:990`) and `commitPreflight`'s duplicate
   return (`:1043`), call `await chain.reevaluateForkChoice()` and pass its
   result as `promotedCommit`. Both run under the node's serial mutation
   operation, so the re-projection is linearized with all other admission.

### Node (companion, `lattice-node`)

3. `NodeAdmissionDecision.init(_ result:)`: when `.duplicate` carries a commit
   with `canonicalChanged == true`, map to `.canonicalized(commit)`; otherwise
   `.duplicate` as today (`AdmissionDecision.swift:22-23`). This routes the
   promotion through the existing `.canonicalized` publish + reconcile path
   (`ChainService.swift:1801-1805`) with zero new machinery.

## Promotion condition

Promotion happens iff `reevaluateForkChoice()` returns a non-nil commit — i.e.
the *existing* deterministic GHOST selection over the current durable accepted
graph now chooses a different (heavier) tip that includes the re-admitted block's
segment. This cannot promote a block that is not genuinely heaviest, and returns
`nil` (no-op, no revision bump) when nothing changed. Equal-work still holds the
incumbent (`forkChoicePrefersSegmentBase`), unchanged.

## Durability

No new persisted state. The accepted blocks and their work facts are already
durable; the canonical projection is derived and is recomputed from those facts
on restart/recovery (same as every normal reorg, which also persists only facts,
not the projection). The commit only drives the live node reconcile.

## Why this is localized and not a weight-model change

The fix adds exactly one re-entry call to an existing, deterministic fork-choice
primitive at the two seams that currently skip it, plus one optional associated
value and its 2-3 pattern-match updates, plus a 2-line node decision mapping. No
new consensus rule, no new weight term, no new stored state.

## Node sub-bugs (secondary; only if the E2E still wedges after the above)

`NodeNetworkRuntime.swift` candidate resolution (~4443): (a) a block is parked on
its `sameChainPredecessor` unconditionally — guard with
`hasAcceptedBlock(predecessor) == false` so an already-accepted predecessor
resolves `.connected` instead of wedging; (b) a `.carrier` orphan falls through
to `.terminal` and is dropped/re-fetched. Fix minimally only if verification
shows they are load-bearing for this repro.

## Test

Lattice unit test: admit a block that lands as a weightless side block, then
supply the evidence that makes it the heaviest chain, re-admit it via the
duplicate path, and assert fork choice promotes it to canonical
(`canonicalChanged == true`). Pre-fix it returns `.duplicate` with no promotion.
