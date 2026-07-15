# Migration conflict register

The in-library conflicts that motivated the redesign are closed in this PR:

| Removed or constrained path | Replacement | Evidence |
| --- | --- | --- |
| `Lattice.processBlockHeader`, raw `skipValidation`, `rootHash`, and `chainPath` | `ChainLevel.admitBlockHeaderChainLocal` with immutable runtime context and `ChildBlockProof` | typed-resolution and forged-proof admission tests |
| Optional `beforeCommit` callback | mandatory `ChainCommitPreparer` | durable failure and concurrent-admission tests |
| Raw child `Block` bootstrap | verified `ChainLevel.bootstrapChild` with `ChildBlockProof` and mandatory preparation | first-root durable-gate and unmined-anchor tests |
| Core-triggered body fetch/backfill | `MissingBodyRequest` in the admission result | orphan and held-heavier follow-up tests |
| Parent-to-child reorganization propagation | independently admitted child evidence | parent-independence and forest tests |
| One child genesis per runtime | persisted `childRootForest` policy | second-root, arrival-order, root-to-root, and restart tests |
| Direct linear sync/reset replacement | mandatory `ChainSyncPreparer` plus a chain mutation generation | durable-sync and stale-projection tests |

## Node integration obligations

These remaining items belong to `lattice-node`, not to a fallback Lattice
mutation path:

| Node responsibility | Required behavior |
| --- | --- |
| Durable preparation | Store the verified immutable candidate and enough fork-choice/state facts to reconstruct the same graph before returning `.ready`. |
| Missing-body scheduling | Consume `MissingBodyRequest` outside consensus, retrieve content, and submit it through the same chain-local boundary. |
| Child bootstrap | Call the verified `bootstrapChild` boundary for the first root; route every later root to that runtime's admission API. |
| Sync adoption | Persist the sync projection and retention policy in `ChainSyncPreparer`; retry when Lattice reports a stale projection. |
| Forest recovery | Do not apply a linear snapshot over a child-root forest; use incremental verified admission or durable restoration of the complete forest. |

## Governing parent-independence test

Given the same child path, accepted child graph or forest, verified evidence set,
protocol version, and admissibility time, two runs that differ only in their
parent canonical tips **MUST** produce the same child accepted graph or forest,
contribution set, and canonical tip. A parent extension, side admission,
reorganization, or restart **MUST NOT** directly mutate child consensus state.
