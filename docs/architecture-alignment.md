# Architecture alignment in this PR

This PR establishes the foundational architecture as the governing source of truth and adds a chain-local admission API alongside the legacy compatibility path.

`admitBlockHeaderChainLocal` intentionally:

- distinguishes unavailable input from invalid evidence;
- distinguishes valid side admission from rejection;
- distinguishes duplicate evidence from invalidity;
- distinguishes local storage failure from availability;
- never invokes a transport or body-backfill provider;
- never propagates a reorganization to child `ChainLevel`s.

The legacy `processBlockHeader` remains temporarily so downstream callers can migrate differentially rather than through a flag-day change.

The tests prove duplicate, unavailable, side-admission, durability-before-mutation, and parent-reorganization independence semantics.
