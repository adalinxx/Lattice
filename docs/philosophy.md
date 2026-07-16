# Lattice: Design Philosophy and Ideas

## The Core Problem

Every multi-chain blockchain system forces the same fundamental compromise: either chains share security by competing for limited capacity on a single root chain, or chains are sovereign and must independently recruit their own set of validators. The first approach (Polkadot's parachain model) caps the number of chains and creates artificial scarcity. The second approach (Cosmos, Avalanche) fragments security — each new chain starts with minimal economic backing and must bootstrap trust from scratch.

Both approaches also require **bridges** to move value between chains. Bridges are trusted intermediaries — multisigs, federations, relayer networks — that hold custody of assets during transfer. They are the most exploited components in the blockchain ecosystem, responsible for billions in losses. The bridge problem is not incidental; it is structural. When chains have independent state, transferring value between them requires some external entity to attest that a debit on one chain corresponds to a credit on another.

Lattice asks: what if the relationship between chains were not lateral (independent chains connected by bridges) but **hierarchical** (a tree of chains where each child inherits its parent's security)? And what if cross-chain value transfer were not an external coordination problem but an **internal state transition** verifiable by the same Merkle proofs that secure each individual chain?

## The Hierarchical Insight

Lattice is a **protocol**, not a chain. It is the organizing scheme — merged mining, sparse root-to-child proofs, and content addressing — that binds chains into a rooted tree. The protocol is what is fractal and self-similar; the chains it secures are free to differ.

The key idea is that a **Lattice chain** is two things at once, and they are the same object:

- a **root chain** — it has its own blocks, its own state, its own operations; and
- a **tree of chains** — the entire subtree rooted at it.

Every chain is both. That identity is the literal source of the fractal self-similarity: a child chain is, from its own vantage point, a root chain with its own subtree, governed by exactly the same protocol as the chain above it. There is no distinguished "leaf" versus "trunk" type — only chains, each simultaneously a root and a tree.

A chain can spawn child chains via genesis transactions. Each child can spawn its own children, forming an arbitrarily deep hierarchy. The **nexus** is the first outermost chain — the primary entry point into the lattice from outside. It is not the unique root: other outermost chains may exist. The nexus is simply the conventional, first point of entry.

```
      Nexus
     /     \
    A       B
   / \
  A1  A2
```

Every chain secures its children with one shared proof-of-work (nested merged mining). This hierarchy is not just organizational. It defines three relationships that solve the problems above:

**Security inheritance through nested merged mining.** One mined root commits a
nested block tree. A child verifies an exact sparse path through the committed
`children` fields, so every level evaluates the same root hash. The root must
first clear a setup-wide minimum work floor. Each level then compares that hash
with its own target: a miss makes the level a carrier, while descendants continue.
One hash computation can therefore secure every accepting level in the hierarchy
without pretending that all levels have the same difficulty.

This is a recursive generalization of merged mining (as pioneered by Namecoin with Bitcoin, and later RSK). The key difference is that RSK's merged mining is a flat, bilateral relationship — Bitcoin secures RSK, but RSK cannot spawn its own merged-mined children. Lattice's merged mining is tree-structured, enabling unlimited depth.

**Trustless cross-chain transfers through state commitment.** Each block carries three state snapshots: `parentState` (a committed snapshot of the parent chain's state), `prevState` (the chain's own confirmed state entering the block), and `postState` (the state after applying the block's transactions). Because `parentState` is committed in the child block's proof-of-work hash, a child chain can verify facts about its parent's state without querying the parent at validation time.

This three-phase state model is what makes bridgeless cross-chain transfers possible. A deposit on a child chain creates an entry in the child's deposit state. The parent chain can verify that deposit by checking the child's state root (committed in the child block embedded in the parent block). A withdrawal on the child requires proving that a corresponding receipt exists in the parent's state — which the child can verify against `parentState`. No external attestation needed. The chain hierarchy itself is the bridge.

**Permissionless chain creation.** Any chain can spawn children via a `GenesisAction` in a transaction. No slot auctions, no governance votes, no staking requirements. The child chain defines its own `ChainSpec` — block time, reward schedule, transaction throughput, custom validation policies — and inherits each verified grind accepted first at an ancestor boundary. It does not need a separate miner set, and it does not depend on the ancestor's current canonical tip.

Operations are per-chain and heterogeneous: each chain defines its own `ChainSpec` and chain policies, so two sibling chains can enforce entirely different policy. Only the organizing protocol — merged mining, proof paths, addressing — is fractal and self-similar. The chains it secures are not required to resemble one another.

## A Deliberately Light Base Chain

The hierarchy is not only a security construction — it is what lets the protocol optimize the base chain for **decentralization instead of throughput**, and put the two where each belongs.

Decentralization is bounded by a simple fact: a network is only as decentralized as the number of independent parties who can *afford to run and mine the root*. A heavyweight base chain — fast blocks, large blocks, unbounded state — quietly prices ordinary operators out and concentrates the network among the few who can run a multi-terabyte full node. So the nexus is deliberately kept **light**: a slow block interval, a small block size, and a bounded per-block state growth mean its data and state grow slowly enough that almost anyone can keep up. Because all data is content-addressed and refetchable, a node runs to a small, configurable storage budget — evicting and refetching from peers rather than retaining everything — and a *stateless* node holding no local chain data at all can still **both validate and produce blocks**, fetching the subtrees it needs on demand. Mining is external to the node, so participating as a miner needs no specialized hardware. The barrier to running and mining the root is kept as low as the protocol can make it, and that low barrier *is* the decentralization.

The cost of throughput is then paid where it belongs. An application that needs many fast, large blocks does not impose that cost on everyone running the base chain; it spawns a **child chain** whose own `ChainSpec` selects a faster block time and larger limits. Only that child's participants store and validate its heavier data, while qualifying nexus-root grinds still become immutable inherited contributions through merged mining. The result is **a decentralized base with high-throughput edges** — the opposite of a single chain that everyone must keep up with as it grows.

The economic parameters follow the same logic. The nexus's emission schedule is stretched over a very long horizon (its first halving is roughly a century out at the nexus block interval) so that the block subsidy stays meaningful for a long time, sustaining the broad, low-barrier miner base economically rather than front-loading emission and letting the network centralize as the subsidy fades and fee pressure dominates. A slow base chain is paired with slow money. See [`docs/economics/nexus-tokenomics.md`](economics/nexus-tokenomics.md) for the concrete schedule.

## Content-Addressed Everything

Every data structure in Lattice — blocks, transactions, state trees, chain specs — is wrapped in content-addressed headers using IPLD/CID (Content Identifiers with DAG-CBOR serialization and SHA-256 hashing). A CID is a self-describing hash: given any piece of data, you can compute its CID deterministically, and given a CID, you can verify that any claimed data matches it.

This design choice has several consequences:

**Structural sharing.** Two blocks that reference the same transaction don't duplicate it — they reference the same CID. Two state trees that differ in one account share every other branch. This is the same principle behind Git's content-addressed object store, applied to every layer of the protocol.

**Lazy resolution.** A node doesn't need to have all data locally. It can hold CID references and resolve them on demand from any peer that stores the data. The `Fetcher` protocol abstracts this: validation code works against CIDs and calls `fetcher.fetch(rawCid:)` when it needs the underlying data. A light client can validate a block by fetching only the Sparse Merkle proofs it needs, not the entire state.

**Data locality through Volumes.** Block and transaction boundaries use
`Volume` headers as explicit availability units. Resolve and store take matching
targeted paths, so a caller fetches and persists only the DAG portion required by
its operation. Nested Volumes remain independent: storing an outer block Volume
does not own, pin, or implicitly store a referenced transaction, state, or child
Volume.

## The Three-Phase State Model

Each block carries three states rather than the typical two (before and after). This seemingly small addition is what enables the entire cross-chain verification system.

- **parentState** — A snapshot of the parent chain's state at the time this block was mined. For nexus blocks, this is empty. For child blocks, it contains the parent's confirmed state, including the parent's receipt state.

- **prevState** — The chain's own confirmed state entering this block. Equals the `postState` of the previous block (state continuity invariant). For genesis blocks, this is the empty state.

- **postState** — The state after applying this block's transactions to `prevState`. This is what becomes the next block's `prevState`.

The critical property is that `parentState` is committed in the child block's proof-of-work hash. A validator checking a child block can verify cross-chain references (deposits, receipts, withdrawals) against `parentState` without querying the parent chain. The parent chain's state is baked into the child's proof-of-work commitment.

## Partitioned State

World state is split into five independent Sparse Merkle Trees:

| Sub-state | Purpose |
|---|---|
| `accountState` | Token balances and per-signer nonces |
| `generalState` | Arbitrary key-value storage |
| `depositState` | Pending cross-chain deposits |
| `receiptState` | Cross-chain transfer receipts |
| `genesisState` | Child chain genesis block references |

Each sub-state is an independent Sparse Merkle Tree with its own root hash. The five roots are combined into a `LatticeState` composite. This partitioning has two benefits:

**Concurrent updates.** When processing a block's transactions, all five sub-states can be proved and updated in parallel via Swift `async let`. Account balance changes don't block deposit state changes. This is a direct mapping of the data model onto Swift's structured concurrency.

**Selective verification.** A light client that only cares about account balances can request Sparse Merkle proofs against `accountState` without downloading proofs for the other four sub-states. A node tracking cross-chain deposits only needs proofs against `depositState` and `receiptState`.

## Sparse Merkle Proofs as the Universal Verification Primitive

Lattice uses Sparse Merkle Trees rather than Patricia tries (Ethereum) or UTXO commitments (Bitcoin). The choice is deliberate: Sparse Merkle Trees support both inclusion proofs (key exists with value V) and **exclusion proofs** (key does not exist) efficiently.

Exclusion proofs are essential for several protocol operations:

- **Deposit insertion**: Proving a deposit key doesn't already exist prevents double-deposits.
- **Receipt insertion**: Proving a receipt key doesn't exist prevents duplicate receipts.
- **Genesis action**: Proving a child chain directory doesn't exist prevents overwriting an existing chain.

Every state transition in Lattice is proved against the current state before it is applied. The pattern is consistent across all five sub-states: generate a proof that the current value matches expectations, then apply the mutation. This means block validation is a pure function of the block data and the current state proofs — no side effects, no external queries, no consensus-layer assumptions.

## Actor-Based Consensus

The protocol tree is content-addressed data, not an actor tree. One Lattice
process owns one `ChainLevel` and one `ChainState` for one absolute path. The node
starts and supervises additional processes for other paths.

Within a process, fork tracking and reorganization run in actor isolation. Across
processes, parent and sibling peers may supply sparse proofs and content, but they
cannot mutate consensus state or issue canonical-tip commands. Every received
fact is verified locally before it can affect the chain. Swift 6's strict
sendability checking enforces the in-process isolation; process supervision and
routing remain node responsibilities.

## Fork Choice: Chain-Local GHOST with Inherited Facts

Proof verification turns a physical root grind into one immutable contribution.
Walking root-to-leaf, the first level whose target accepts the root hash is the
credited boundary. Deeper levels carry the same contribution as an inherited
fact. The root CID identifies the grind, so replay cannot count it twice.

Within one chain:

```text
blockWork(B) = sum(verified contributions attached to B)
subtreeWeight(B) = blockWork(B)
                 + sum(subtreeWeight(C) for same-chain child C)
```

GHOST follows the greatest same-chain subtree. Equal-work segments prefer the
lexicographically smaller canonical CID of their segment bases. Targets and
segment tips do not break ties. There is no live parent weight lookup, parent
block map, or parent-canonicality tiebreak. Security crosses
the hierarchy as verified proof facts, not as authority delegated to another
runtime.

## Cross-Chain Value Transfer Without Bridges

The deposit/receipt/withdrawal protocol enables trustless value movement between parent and child chains:

1. **Deposit** (child chain): A user creates a deposit action on the child chain, locking tokens and declaring a demand (amount and recipient on the parent). The deposit is recorded in the child's `depositState`.

2. **Receipt** (parent chain): The parent chain verifies the deposit exists by checking the child's state root (committed in the child block embedded in the parent block). A receipt is recorded in the parent's `receiptState`, and the demanded amount is transferred between accounts on the parent.

3. **Withdrawal** (child chain): The child chain verifies that a receipt exists on the parent by checking `parentState.receiptState`. The original deposited tokens are released to the withdrawer.

At no point does any trusted third party hold custody of tokens. The verification is purely cryptographic: Sparse Merkle proofs against state roots that are committed in proof-of-work hashes.

## No Smart Contracts: The Chain Is a Data Backend, Not a Computer

The view that motivates Lattice is that **a blockchain is a global, trustless data backend.** The only thing a chain *must* define is how that backend is updated: which atomic, authorized mutations are allowed, and the rules — the **filters** — that gate them. Everything else — automation, workflows, "if-this-then-that" orchestration — belongs to a higher **application layer** built on top of the backend, not baked into consensus.

From that view, smart contracts are simply **unnecessary**, because the two things people reach for them to provide are already covered:

- **The right chain structure.** Application-specific behavior is a *child chain* with its own `ChainSpec`, operations, and economics — spawned permissionlessly and secured by merged mining — rather than a contract competing for space on one congested chain. The unit of "a new application" is a chain, not a deployed program.
- **Governance via filters.** Each chain defines the rules that gate how *its* data may change: content-addressed validity policies that accept or reject a proposed update (see [WASM policies](#wasm-policies-programmable-chain-policy)). These filters are how a chain governs its own backend — declarative constraints on valid updates, not programs that run.

With chain structure and filters in place, a built-in contract system would add nothing: the chain defines the *valid atomic updates* to the shared data, and the application layer above decides *when and why* to make them. Keeping automation off-chain is a deliberate simplification — **less is built in, so less can go wrong.** There is no shared virtual machine every node must run, no gas, and none of the reentrancy / unbounded-execution / upgradeable-proxy exploit surface that on-chain programmability drags in.

This is possible because Lattice **derives** state rather than executing it. Each block commits pre- and post-update state roots, and the protocol verifies a transition by structurally diffing the Merkle trees (see [The Three-Phase State Model](#the-three-phase-state-model)) — the backend is *data*, and updates are *validated*, never *replayed through a VM*. That is also what keeps a node cheap to run (see [A Deliberately Light Base Chain](#a-deliberately-light-base-chain)): there is no world-computer whose every step the entire network must replicate.

To be precise: Lattice has no smart contracts **built in** as a chain primitive. It does not forbid automation — automation lives where it belongs, in the application layer above the data backend, composing over the chain's atomic, filtered updates and the cross-chain transfer protocol.

## WASM Policies: Programmable Chain Policy

Each `ChainSpec` can include chain policy modules that act as custom validation rules. In the current implementation those policies are WASM modules: the chain spec, chain path, and transaction or action under validation are serialized into a versioned canonical binary policy context; a transaction is only valid if every referenced policy returns accept.

This is deliberately not a global smart-contract system. Policies are chain-local validation programs: they can reject transactions but cannot modify state directly. The module CID is committed in the chain spec, the ABI is versioned, and unsupported policies make a node unable to validate that chain.

The intent is to allow chain creators to define economic policy without introducing Turing-complete state transitions. A chain for stablecoins might filter out transactions above a certain size. A chain for a specific application might require transactions to include certain metadata fields. Policies are chain-local: each chain chooses the validation programs that apply to its own transactions.

## What Lattice Does Not Solve

Lattice restructures where the blockchain trilemma's tradeoffs land, but it does not eliminate them.

**The nexus is still a single chain.** It is bounded by the same throughput constraints as any single-chain PoW system. Horizontal scaling happens through child chains, not through making the nexus faster.

**Settlement remains probabilistic.** Lattice has no explicit finality. A block
hardens as more verified root grinds contribute to its same-chain subtree, and a
strictly heavier competing subtree can still reorganize it at any depth. Parent
canonical confirmations are not a prerequisite and a parent reorganization does
not revoke already verified child work. Greater hierarchy depth instead costs
larger proof packages and more availability coordination between independently
run chain processes.

**Cross-chain MEV is structurally easier for merged miners.** A miner that mines both the nexus and a child chain sees pending transactions on both chains simultaneously. This is the same miner-extractable value problem that exists in single-chain systems, amplified across the hierarchy. Lattice does not attempt to solve MEV — it acknowledges it as an inherent property of the hierarchical mining structure.

**Block size grows with child chain count.** Each child block is embedded in its parent's `children` field. More child chains means larger parent blocks. The `maxBlockSize` parameter in `ChainSpec` provides a hard cap, but the tension between chain count and block size is fundamental.

## Implementation Language Choice

Lattice is implemented in Swift 6 for several reasons that align with the protocol's design:

- **Actor model.** Swift's native actor system isolates one chain's admission and fork choice inside each Lattice process. The node, not an actor tree, owns multi-chain process topology.

- **Strict sendability.** Swift 6's sendability checking means data races in the consensus layer are compile-time errors, not runtime heisenbugs.

- **Apple ecosystem.** The roadmap includes an iOS light client SDK, SwiftUI wallet, and on-device cross-chain proof verification. Writing the protocol layer in Swift means the mobile client shares the same validation code as full nodes.

- **Performance.** Swift compiles to native code with predictable performance characteristics. There is no garbage collector introducing latency spikes during block validation.

## Design Principles

Several principles guided the design decisions throughout Lattice:

**Verify everything locally.** No validation step requires querying an external system. Block validation is a pure function of the block data and Sparse Merkle proofs. Cross-chain verification uses committed state roots, not external oracles.

**Derive, don't declare.** Receipt actions automatically derive the account actions they imply (debit withdrawer, credit demander). The transaction doesn't redundantly declare what the protocol can compute. This reduces the surface for inconsistency and simplifies validation.

**Make the common case fast.** Five independent sub-state trees update concurrently. Fork choice results are cached and invalidated incrementally. Main chain timestamps are indexed for fast target calculation without fetcher round-trips.

**Fail early, fail cheaply.** Validation checks are ordered from cheapest to most expensive. Structural checks (timestamps, height continuity, difficulty) happen before signature verification, which happens before state proof generation. A malformed block is rejected in microseconds, not milliseconds.

**No implicit trust.** Even carriers that miss their chain's `target` must prove
same-chain `prevState` continuity inside a descendant's sparse package. This
prevents an attacker from fabricating intermediate state that a deeper block
references.

**Keep the base runnable by anyone.** The nexus's parameters — block interval, block size, the per-block state-growth bound — and its emission schedule are chosen to keep the cost of running and *mining* the root low and stable over time. Decentralization is bounded by who can afford to participate, so the base layer optimizes for accessibility (down to a stateless, fetch-on-demand node) and pushes throughput onto opt-in child chains that bear their own cost. See [A Deliberately Light Base Chain](#a-deliberately-light-base-chain).
