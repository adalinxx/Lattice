# Foundational testing strategy

Correctness is established in layers:

1. deterministic unit and golden-vector tests;
2. property tests for paths, proofs, Volumes, and fork graphs;
3. differential tests across ingress paths;
4. live-versus-restart comparison;
5. deterministic storage and network fault injection;
6. crash matrices at every commit boundary;
7. seeded full-stack simulations with replayable traces.

The suite must exercise the same candidate through gossip, sync, mining, and
recovery adapters; root-floor failure, carrier target misses, root-CID replay,
multiple grinds for one block, parent reorganization, atomic staging failure,
concurrent commit ordering, node state retention, and restart must not create
alternate consensus meanings. It must also prove that the root floor prevents
child resolution, one captured validation-time context survives retries, and
equal work compares canonical segment-base CID bytes only.
