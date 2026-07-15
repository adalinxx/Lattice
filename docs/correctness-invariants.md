# Correctness invariant catalog

## SEMANTICS-001 — availability is not invalidity

Unavailable content, a CID-mismatching provider response, a protocol violation,
and a local verifier failure have distinct admission outcomes.

Established by: `ChainLocalAdmissionTests.testResolutionFailuresHaveTypedOutcomes`.

## SEMANTICS-002 — temporal admissibility is distinct

A future-dated otherwise-valid candidate returns `notYetAdmissible`, not
permanent invalidity or unavailable evidence.

Established by: `ChainLocalAdmissionTests.testNotYetAdmissibleCandidateIsDeferredByTypedOutcome` and `SyncForestIntegrationTests.testSyncReportsFutureGenesisAsNotYetAdmissible`.

## ADMISSION-001 — context is runtime-owned

Path and child-proof requirements come from the chain runtime. Child admission
requires a proof bound to that path and candidate CID; its absolute root must
also clear its declared PoW target.

Established by: `ChainLocalAdmissionTests.testChildAdmissionRequiresVerifiedProofAndThenAcceptsIt`, `ChainLocalAdmissionTests.testChildProofRejectsAnUnminedRootCarrier`, and `ChainLocalAdmissionTests.testRestoreDerivesChildContextAndRejectsInvalidTopology`.

## DURABLE-001 — preparation precedes visible mutation

Every public candidate admission requires a preparation result before it can
change the accepted graph. Independent verification may run concurrently; final
fork choice is serialized by `ChainState` against its current state. Public
first-root bootstrap and linear sync adoption obey the same durable gate; sync
also rejects a projection made stale by intervening admission.

Established by: `ChainLocalAdmissionTests.testDurablePreparationFailureLeavesNoVisibleMutation`, `ChainLocalAdmissionTests.testPublicBootstrapRequiresVerifiedGenesisAndDurablePreparation`, `ChainLocalAdmissionTests.testConcurrentAdmissionReachesDurablePreparationTogether`, and `SyncForestIntegrationTests.testApplySyncRequiresDurablePreparationAndRejectsAStaleProjection`.

## FOLLOWUP-001 — consensus requests bodies without fetching them

An accepted orphan or held heavier branch returns its missing body requirements
without starting transport.

Established by: `ChainLocalAdmissionTests.testAcceptedOrphanReturnsItsMissingParentAsFollowUp` and `ChildRootForestTests.testForestReportsHeldHeavierMissingSideRoot`.

## FOREST-001 — one path admits competing child roots

A child-root forest is one runtime and one persistent chain state. It accepts
valid additional roots, selects ties deterministically, and can reorganize
between roots without a common child ancestor.

Established by: `ChainLocalAdmissionTests.testSecondChildRootPreparationReceivesMaterializedState`, `ChildRootForestTests.testChildForestSelectsEqualWeightRootsIndependentlyOfArrivalOrder`, `ChildRootForestTests.testHeavierCompetingRootReorganizesWithoutCommonAncestor`, and `ChildRootForestTests.testRestoredForestReorganizesToKnownSideDescendantWithItsSnapshot`.

The public boundary version is established by
`ChainLocalAdmissionTests.testVerifiedBootstrapAndSecondRootAdmissionShareOneForest`.

## CHAIN-001 — parent commands do not mutate children

No public Lattice path propagates a parent reorganization into a child chain.
Children change only when their own verified evidence is admitted.

The governing cross-runtime test remains in the [migration conflict register](migration-conflict-register.md).
