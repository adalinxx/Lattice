# Correctness invariant catalog

This catalog gives stable names to the first invariants enforced by the foundational redesign. It will grow as legacy paths migrate.

## SEMANTICS-001 — availability is not invalidity

When required authenticated content cannot be obtained, chain-local admission returns `unavailable`, not `invalid`.

Established by: `ChainLocalAdmissionTests.testUnavailableContentIsNotReportedInvalid`.

## SEMANTICS-002 — valid side admission is not rejection

A valid equal-work sibling enters the accepted graph as `acceptedSide` without becoming canonical.

Established by: `ChainLocalAdmissionTests.testValidEqualWorkSiblingIsAcceptedAsSideBlock`.

## SEMANTICS-003 — duplicate is not invalidity

An already known block returns `duplicate`.

Established by: `ChainLocalAdmissionTests.testDuplicateIsNotReportedInvalid`.

## DURABLE-001 — storage failure precedes mutation

A `storageFailed` preparation result prevents the accepted graph and canonical tip from advancing.

Established by: `ChainLocalAdmissionTests.testStorageFailurePreventsVisibleConsensusMutation`.

## CHAIN-001 — parent reorganization is not child mutation

A parent fork-choice change through the chain-local API causes no direct child tip change.

Established by: `ChainLocalAdmissionTests.testParentReorganizationDoesNotMutateChildChain`.

## INGRESS-001 — one result vocabulary

Every downstream transport maps `ChainLocalBlockResult` without collapsing canonicalized, side-accepted, duplicate, unavailable, invalid, or storage-failed outcomes.

Established downstream by the lattice-node integration PR.
