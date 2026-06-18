# Lattice Documentation

**Lattice** is a proof-of-work protocol in which every chain is both a *root chain* (its own blocks, state, and operations) and a *tree of chains* (the subtree rooted at it) — the same object, which is what makes Lattice fractal. Each chain secures its children with one shared proof-of-work (nested merged mining). The first outermost chain is the **nexus** (other outermost chains may exist); descendants are addressed by route, e.g. `Nexus/Payments`.

## By goal

| I want to… | Read |
|---|---|
| Get the project running | [README](../README.md#quickstart) |
| Understand the design philosophy | [philosophy.md](philosophy.md) |
| Read the protocol specification | [spec.md](spec.md) |
| Run deterministic fork-choice scenarios | [consensus-simulator.md](consensus-simulator.md) |
| Understand trustless cross-chain transfers | [cross-chain.md](cross-chain.md) |

## Documents

- **[philosophy.md](philosophy.md)** — the design philosophy and ideas: the hierarchical insight, content-addressing, the three-phase state model, partitioned state, fork choice, and cross-chain transfers without bridges.
- **[spec.md](spec.md)** — the formal protocol specification: data structures, consensus, transaction validation, the state model, the cross-chain protocol, and constants.
- **[consensus-simulator.md](consensus-simulator.md)** — the deterministic `LatticeSim` harness for Hierarchical-GHOST fork-choice fixtures.
- **[cross-chain.md](cross-chain.md)** — the deposit → receipt → withdrawal protocol for trustless value transfer between a parent and a child chain.
