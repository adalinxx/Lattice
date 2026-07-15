# Removed Legacy Paths

This file is retained only as a stable link from earlier reviews. There is no
active dual-path migration or conflict register in Lattice.

The following legacy behaviors are removed:

- recursive `Lattice` / `ChainLevel.children` runtime ownership;
- `bootstrapChild` and raw child-block bootstrap;
- caller-supplied path, root hash, or validation bypasses;
- parent-chain block maps and live inherited-weight providers;
- parent-to-child reorganization propagation;
- library `ChainSyncer`, direct reset, and trusted sync replacement;
- transport or body fetching initiated by consensus;
- block-committed `createdDiffs` / `removedDiffs`; and
- Cashew storage ownership relationships between outer and nested Volumes.

The replacement is one boundary, not a compatibility layer:

```text
ChainRuntimeContext + ChildValidationPackage
  -> ChainLevel.bootstrap / admitBlockHeaderChainLocal
  -> targeted store + node durable stage
  -> one ChainState commit
```

`lattice-node` owns one-process-per-chain topology, acquisition, filesystem
persistence, CAS pin counts, retention, and projections. Every candidate from
gossip, sync, mining, or peer recovery re-enters the same admission API.
