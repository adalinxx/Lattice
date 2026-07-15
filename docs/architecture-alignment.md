# Architecture alignment in this PR

## Status: executable Lattice admission boundary

This PR makes `ChainLevel` the Lattice library's public candidate-admission
boundary. The former `processBlockHeader` compatibility path, its caller-supplied
validation bypasses, transport-triggered backfill, and recursive child-reorg
commands are removed.

`admitBlockHeaderChainLocal` now:

- derives path and proof requirements from immutable runtime topology;
- distinguishes unavailable evidence, provider-malformed bytes, protocol
  invalidity, local verification failure, temporal deferral, and durable-store
  failure;
- requires node-owned durable preparation before in-memory graph mutation;
- returns missing-body requirements instead of starting transport;
- admits valid side branches separately from canonical changes; and
- supports a single child runtime with a persisted competing-root forest.

`bootstrapChild` applies the same rule to a first child root: it derives the
child path, verifies a `ChildBlockProof` whose root clears its own PoW target,
validates the genesis transition, and waits for durable preparation before the
runtime becomes visible. There is no public raw-block bootstrap API.

`ChainState.submitBlock` is an implementation primitive, not a public ingress
route. A child runtime's context is derived by its parent; callers cannot attach
an arbitrary level as a child or inject a root context into one.

The node still owns the operational policy deliberately left above Lattice:

- persist the verified block, state transition, and chosen retention facts in
  the mandatory preparation callback;
- schedule retrieval for `MissingBodyRequest` and re-submit the returned
  evidence through chain-local admission;
- supply durable preparation for linear sync adoption or reset; stale sync
  projections are rejected rather than overwriting intervening admission; and
- use incremental verified admission for forests, rather than replacing them
  with a linear sync snapshot.

Those are integration obligations, not alternate Lattice consensus paths. The
remaining handoff points are tracked in the [migration conflict register](migration-conflict-register.md).
