# Lattice Documentation

Lattice has two shapes that must not be confused:

- one mined root commits a nested, content-addressed tree of chain candidates;
- one Lattice process validates and chooses a tip for exactly one chain path.

The node runs those processes, moves authenticated evidence between them, and
decides what content to acquire and retain.

## Start Here

1. [README](../README.md) - build the library and learn the model in one minute.
2. [Architecture](foundational-architecture.md) - process boundaries, ownership,
   admission, recovery, and retention.
3. [Work and fork choice](consensus-fork-choice.md) - how verified grinds become
   chain-local weight.
4. [Cross-chain transfers](cross-chain.md) - a worked parent-child exchange.
5. [Protocol specification](spec.md) - exact consensus rules.

Read [Philosophy](philosophy.md) for motivation and tradeoffs, not protocol
definitions.

## Document Roles

| Document | Role |
|---|---|
| [Protocol specification](spec.md) | Normative consensus definition |
| [Architecture](foundational-architecture.md) | Runtime and component boundaries |
| [Work and fork choice](consensus-fork-choice.md) | Intuitive consensus rationale |
| [Cross-chain transfers](cross-chain.md) | Non-normative transfer walkthrough |
| [Philosophy](philosophy.md) | Motivation, design choices, and limits |
| `Sources/` and `Tests/` | Implementation and executable conformance evidence |

A disagreement between these layers is a defect to resolve, not wording to
paper over.

## Mental Model

A recursive content DAG supplies sparse evidence to independent chain-local
forests, each owned by one node-supervised process. The
[architecture guide](foundational-architecture.md) develops those three
structures and their ownership boundaries.

## Vocabulary

| Term | Meaning |
|---|---|
| mined root | The outer block whose hash is evaluated along a proof path |
| chain path | An absolute chain identity such as `Nexus/Payments` |
| chain root | A genesis block in that path's accepted forest |
| predecessor | The previous block on the same chain |
| parent chain | The next chain level toward the mined root |
| `parentState` | The carrier's committed `prevState`, never a parent-block backlink |
| grind | One physical PoW attempt, identified by its root CID |
| carrier | A level that commits descendants even when the grind misses its target |
| accepted | Locally validated consensus evidence retained in the forest |
| canonical | The currently preferred projection of accepted evidence |

## Reference

- [Consensus simulator](consensus-simulator.md)
- [Adversarial consensus report](consensus/tre-134-adversarial-report.md)
- [Nexus tokenomics](economics/nexus-tokenomics.md)
- [Fee policy and majority-reorg model](economics/fee-market-and-51pct.md)
