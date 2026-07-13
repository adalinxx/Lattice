# Foundational testing strategy

Correctness is established in layers:

1. deterministic unit and golden-vector tests;
2. property tests for paths, proofs, Volumes, and fork graphs;
3. differential tests across ingress paths;
4. live-versus-restart comparison;
5. deterministic storage and network fault injection;
6. crash matrices at every commit boundary;
7. seeded full-stack simulations with replayable traces.

The initial tests in this PR establish the result vocabulary and chain independence. The larger redesign should extend the same invariant catalog rather than adding disconnected happy-path scenarios.
