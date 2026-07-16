# Coordinated Repository Boundaries

Lattice is the consensus and execution library in a coordinated stack. Its
boundary is deliberately narrow: one process validates and chooses one chain.

Companion repositories implement independent responsibilities:

- **cashew** provides content-addressed structures and matching targeted
  resolve/store traversal. Nested Volumes remain independent.
- **VolumeBroker** stores complete selected Volumes and implements node-chosen
  pins and eviction.
- **Ivy** acquires and serves bytes.
- **Tally** records provider behavior without turning availability into validity.
- **lattice-node** supervises one Lattice process per followed chain and owns
  atomic typed-fact durability, state retention and pinning, revision-ordered
  projections, and ingress routing.

These layers may transport or persist evidence. None supplies an alternate
validity, work, sync, or fork-choice path around
`ChainLevel.admitBlockHeaderChainLocal`.
