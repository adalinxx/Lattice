# Lattice Documentation

**Lattice** is a proof-of-work protocol in which one root grind commits a nested
tree of chain blocks. Each chain verifies the exact sparse path to its block and
applies fork choice independently. The data hierarchy is fractal; runtime
ownership is not. One Lattice process owns one absolute route, such as
`Nexus/Payments`, while the node supervises the multi-process topology.

## By goal

| I want to… | Read |
|---|---|
| Get the project running | [README](../README.md#quickstart) |
| Understand the design philosophy | [philosophy.md](philosophy.md) |
| Read the protocol specification | [spec.md](spec.md) |
| Understand runtime and node boundaries | [foundational-architecture.md](foundational-architecture.md) |
| Understand hierarchical work and fork choice | [consensus-fork-choice.md](consensus-fork-choice.md) |
| Run deterministic fork-choice scenarios | [consensus-simulator.md](consensus-simulator.md) |
| Understand trustless cross-chain transfers | [cross-chain.md](cross-chain.md) |

## Core documents

- **[philosophy.md](philosophy.md)** — the design philosophy and ideas: the hierarchical insight, content-addressing, the three-phase state model, partitioned state, fork choice, and cross-chain transfers without bridges.
- **[spec.md](spec.md)** — the formal protocol specification: data structures, consensus, transaction validation, the state model, the cross-chain protocol, and constants.
- **[foundational-architecture.md](foundational-architecture.md)** — the one-chain runtime model and component ownership boundaries.
- **[consensus-fork-choice.md](consensus-fork-choice.md)** — identity-bearing work, live inheritance, and chain-local GHOST.
- **[consensus-simulator.md](consensus-simulator.md)** — the deterministic `LatticeSim` harness for Hierarchical-GHOST fork-choice fixtures.
- **[cross-chain.md](cross-chain.md)** — the deposit → receipt → withdrawal protocol for trustless value transfer between a parent and a child chain.
