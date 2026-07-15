# Consensus Simulator

`LatticeSim` is the deterministic simulator harness for the implemented
Hierarchical-GHOST fork-choice path in `docs/consensus-fork-choice.md`.

Run it from a clean checkout:

```bash
swift run LatticeSim --seed 42
```

The output is sorted JSON. The same seed must produce the same trace byte-for-byte.
The three default scenarios pin the chain-local edges in the current library:

- equal subtree work keeps the incumbent main fork;
- a seeded withhold/release schedule converges to the heavier GHOST subtree;
- the 1h proportional retarget path uses `ChainSpec.calculateWindowedTarget`.

For custom fixtures, `LatticeConsensusSimulator.runDiscreteEventScenario(_:)`
accepts a `ConsensusSimScenarioSpec` with block topology, release times
(`atMillis`), and per-block work weights. The harness turns those inputs into
`BlockMeta` fixtures and still evaluates them through `ChainState`.

The simulator does not implement a second fork-choice rule. It constructs
`BlockMeta` fixtures and records `ChainState.forkChoiceSnapshot(startingAt:)`,
which wraps the library's real same-chain GHOST decision. Cross-chain proof and
contribution derivation are tested at admission rather than simulated by a live
parent-weight provider.
