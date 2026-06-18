<p align="center">
  <h1 align="center">Lattice</h1>
  <p align="center">
    <strong>Every chain is a tree of chains — secured by one proof-of-work.</strong>
    <br />
    One proof-of-work. Every chain secured. No bridges. No trusted third parties.
  </p>
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> &bull;
  <a href="docs/index.md">Docs</a> &bull;
  <a href="docs/spec.md">Protocol Spec</a> &bull;
  <a href="docs/philosophy.md">Philosophy</a> &bull;
  <a href="docs/cross-chain.md">Cross-Chain Protocol</a> &bull;
  <a href="#architecture">Architecture</a> &bull;
  <a href="#roadmap">Roadmap</a>
</p>

---

## What is Lattice?

Lattice is a proof-of-work protocol in which every chain is both a chain and a *tree of chains* rooted at it. Any chain can spawn child chains, and one nonce search secures an entire subtree through **nested merged mining**. The **nexus** is the first outermost chain — the entry from outside (other outermost chains may exist). Each chain defines its own operations, yet every child inherits the full proof-of-work security of its ancestors. Value flows between chains through a cryptographic deposit/receipt/withdrawal protocol verified entirely by Merkle proofs. No bridges. No federations. No relayers.

**This is not a testnet, a token, or a whitepaper.** This is a working implementation in Swift with full block validation, consensus, state management, and cross-chain transfers. (Networking is not part of the library — Lattice defines the `Fetcher` abstraction; the node, e.g. `lattice-node`, provides the actual P2P/networking.)

### Why Lattice exists

Every multi-chain system before Lattice forces the same tradeoff: either chains share security and compete for limited slots (Polkadot), or chains are sovereign and must recruit their own validators (Cosmos, Avalanche). Both fragment security. Both require trusted bridges for cross-chain value transfer — the [most exploited components in crypto](https://www.fxempire.com/news/article/over-2b-lost-in-13-separate-crypto-bridge-hacks-this-year-1085594), responsible for over $2 billion in losses between 2022-2024.

Lattice eliminates both problems:

- **Nested merged mining** — Miners mine every chain in the hierarchy with a single hash. No hashrate fragmentation. No "which chain do I mine?" decision. Every child chain is backed by the full parent hashrate. This extends [RSK's merged mining with Bitcoin](https://medium.com/iovlabs-innovation-stories/modern-merge-mining-f294e45101a0) recursively across an entire tree of chains.

- **Trustless cross-chain transfers** — Value moves between chains via Merkle proof verification against state roots already committed in blocks. No multisig. No federation. No relayer. Compare this to RSK, which despite merged mining still relies on a [federated bridge](https://web3.gate.com/en/crypto-wiki/article/exploring-rootstock-an-in-depth-overview-of-bitcoin-s-sidechain-solution-20251208) for BTC transfers.

- **Unlimited chain creation** — Any chain can spawn children via a genesis transaction. No slot auctions. No governance proposals. No permission required. Each child chain has its own economic parameters, chain policies, and state — but inherits the parent's full proof-of-work security.

- **A base layer anyone can run — and mine.** The nexus is deliberately lightweight (slow blocks, small block size), and a node runs to a configurable budget — as little as a quarter-gig of RAM, or *stateless* with no local chain data at all, validating and mining by fetching from peers on demand. Mining is external, so no specialized hardware is required. A low barrier to running and mining the root is precisely what keeps the network decentralized and censorship-resistant; throughput-hungry workloads live on child chains that pick their own faster/larger parameters and are paid for only by their participants. **Decentralized base, high-throughput edges.**

### How it compares

| | Security Model | Cross-Chain | Chain Limit |
|---|---|---|---|
| **Bitcoin** | Full PoW | None | 1 chain |
| **Ethereum** | L1 + rollup proofs | Bridges (trusted) | Unlimited rollups, L1 bottleneck |
| **Cosmos** | Per-zone validators | IBC + relayers | Unlimited, fragmented security |
| **Polkadot** | Shared via relay chain | XCMP | Limited parachain slots |
| **Avalanche** | Per-subnet validators | Warp messaging | Unlimited, fragmented security |
| **Lattice** | Nested merged mining | Deposit/receipt Merkle proofs, no bridges | Unlimited, shared security |

---

## Quickstart

### Requirements

- Swift 6.0+
- macOS 15+

### Build

```bash
swift build
```

### Test

```bash
swift test
```

### Run

```bash
swift run LatticeDemo
```

### Use as a dependency

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/adalinxx/Lattice.git", branch: "master")
]
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Lattice (actor)                       │
│  Entry point for block processing. Owns the root        │
│  ChainLevel (nexus) and dispatches blocks downward.     │
└────────────────────────┬────────────────────────────────┘
                         │
              ┌──────────▼──────────┐
              │  ChainLevel (actor) │ ◄── One per chain in the hierarchy
              │  ┌────────────────┐ │
              │  │ ChainState     │ │ ◄── Consensus: tips, forks, reorgs
              │  │ (actor)        │ │
              │  └────────────────┘ │
              │  children: [String: │
              │    ChainLevel]      │
              └──┬──────────────┬───┘
                 │              │
          ┌──────▼───┐  ┌──────▼───┐
          │ ChainLevel│  │ ChainLevel│   ... child chains
          └──────────┘  └──────────┘
```

Every `ChainLevel` owns a `ChainState` actor that manages block metadata, fork tracking, and reorganization for a single chain. Child chains are nested `ChainLevel` instances. Block processing cascades downward: if a block doesn't match the current chain's `target`, it's offered to children.

### Core design

**Content-addressed everything.** All data — blocks, transactions, state — is wrapped in content-addressed headers (IPLD/CID). Nodes only fetch what they need. A node tracking the nexus doesn't download child chain state; it verifies Merkle proofs against committed roots. Block and Transaction boundaries use [Volumes](https://github.com/adalinxx/cashew#volumes-data-locality-for-content-addressed-trees) — a `Header` subtype that notifies the fetcher before resolution, so it can locate the peer that stores the block's children contiguously.

**Three-phase state model.** Each block carries `parentState` (parent chain's state), `prevState` (confirmed state entering the block), and `postState` (state after applying transactions). This is what makes trustless cross-chain verification possible without querying another chain at validation time.

**Five partitioned sub-states.** World state is split into five independent Sparse Merkle Trees: accounts, general key-value, deposits, receipts, and genesis blocks. Account state also tracks per-signer nonces via `_nonce_<prefix>` keys in the same trie. All five are proved and updated concurrently via Swift `async let`. Light clients only need proofs for the sub-state they care about.

**Ref-counted state diffs.** Every `proveAndUpdateState` returns a `StateDiff` — reference-counted maps of created and replaced CIDs. The diff is threaded through the entire validation pipeline (`validatePostState` → `validateNexus` → `processBlockHeader`) so the node layer can capture it without re-computing proofs. `diffCIDs(old:new:)` walks only materialized nodes on modified paths — O(log n) per modified key.

**Actor-based concurrency.** The consensus layer maps directly onto Swift's actor model. Each chain is an isolated actor. Reorganizations propagate through the actor hierarchy without shared mutable state. Swift 6's strict sendability checking catches data races at compile time.

### Block processing flow

```
Block arrives
  │
  ├── Validate (structure, PoW, state transitions)
  ├── Determine chain (target, parent ancestry)
  ├── Submit to ChainState (insert, evaluate fork choice, reorg if needed)
  └── Propagate child blocks to child ChainLevels
```

### Fork choice rule — Hierarchical GHOST

The canonical tip is the one of greatest **`trueCumWork`**, a single weight that
combines a block's own descendant-subtree work with the merged-mining security it
inherits from its parent chain:

```
work(B)          = U256_MAX / B.target                     // bigger target = easier to satisfy
subtreeWeight(B) = work(B) + Σ subtreeWeight(children(B))  // forward GHOST subtree, each block once
inherited(B)     = trueCumWork(securingParent(B))          // 0 for the nexus; derived fresh, never cached
trueCumWork(B)   = subtreeWeight(B) + inherited(B)          // the single metric fork choice maximizes
```

Heaviest `trueCumWork` wins; ties hold the incumbent (no thrash). There is **no
explicit finality** — any block can be reorganized at any depth if a heavier
subtree appears (the only depth bound is a node's local retention policy). Because
`inherited` folds the securing parent's weight into the child, a child block is as
hard to displace as the parent hashrate securing it — security propagates upward
through the lattice. (Normative spec: `docs/spec.md` §9.)

### Cross-chain value transfer

Value moves between parent and child chains through a three-phase **deposit/receipt/withdrawal** protocol verified entirely by Merkle proofs:

1. **Deposit** (child chain): A user locks tokens on the child chain via a `DepositAction`, declaring a demand (recipient and amount on the parent). The deposit is recorded in the child's `depositState`.

2. **Receipt** (parent chain): The parent verifies the deposit exists by checking the child's state root (committed in the child block embedded in the parent block). A `ReceiptAction` records the receipt in the parent's `receiptState` and transfers the demanded amount between accounts on the parent.

3. **Withdrawal** (child chain): The child verifies a receipt exists on the parent by checking `parentState.receiptState`. A `WithdrawalAction` releases the original deposited tokens to the withdrawer. The deposit entry is deleted, preventing double-withdrawal.

At no point does any trusted third party hold custody of tokens. The verification is purely cryptographic: Sparse Merkle proofs against state roots committed in proof-of-work hashes.

Cross-chain replay protection is enforced via `chainPath` — each transaction declares the exact chain hierarchy path it targets (e.g., `["Nexus", "Payments"]`). Transactions are rejected if the `chainPath` doesn't match the validating chain.

---

## Economic model

Each chain defines its own economics via `ChainSpec`:

| Parameter | Description |
|---|---|
| `initialReward` | Block reward in base units |
| `halvingInterval` | Blocks between reward halvings |
| `premine` | Halving schedule offset for chain creators |
| `targetBlockTime` | Target milliseconds between blocks |
| `retargetWindow` | Blocks in the target retargeting window |
| `maxNumberOfTransactionsPerBlock` | Throughput limit |
| `maxStateGrowth` | Maximum state size increase per block |
| `maxBlockSize` | Maximum serialized block size in bytes |
| `wasmPolicies` | Chain policy modules using the current WASM runtime |

Block rewards halve on a schedule: `reward(height) = initialReward >> ((height + premine) / halvingInterval)`. The `premine` offsets the halving clock so chain creators can capture early rewards.

Preset configurations: `ChainSpec.bitcoin` (10-min blocks), `ChainSpec.ethereum` (12-sec blocks), `ChainSpec.development` (fast blocks for testing).

---

## The trilemma

Lattice does not solve the blockchain trilemma. [It's been formally proven unsolvable.](https://www.mdpi.com/2076-3417/15/1/19) What Lattice does is restructure where the tradeoffs land:

**What improves:**
- Throughput scales horizontally — ten sibling chains = ten times the throughput, all sharing the same PoW security
- Cross-chain transfers are trustless — no bridge exploits possible
- Light clients can verify cross-chain state via Merkle proofs
- Mining profitability increases with chain count (same nonce, more rewards)

**What doesn't:**
- The nexus chain is still bounded by single-chain PoW limits
- Confirmation latency grows with hierarchy depth: O(depth × block_time) to reach a given confidence (there is no finality gadget; settlement is probabilistic)
- Block size grows with child chain count
- Cross-chain MEV is structurally easier for merged miners to extract

Full analysis including incentive dynamics, failure modes, and comparison to every major L1: see the [detailed trilemma assessment](docs/spec.md).

---

## Project structure

```
Sources/Lattice/
├── Lattice/          Lattice actor, ChainState, ChainLevel, Genesis
├── Block/            Block structure, validation, BlockBuilder, ChainSpec
├── Transaction/      Transaction, TransactionBody, signatures
├── Actions/          Account, Action, Deposit, Receipt, Withdrawal, Genesis
├── State/            LatticeState + 5 sub-state Sparse Merkle Trees
├── Core/             PublicKey type
├── CryptoUtils.swift Ed25519, SHA-256, key generation
└── UInt256+Extensions.swift
```

## Cryptography

| Primitive | Algorithm | Usage |
|---|---|---|
| Hash | SHA-256 | Block hashes, Merkle trees, proof-of-work, addresses |
| Signature | Ed25519 | Transaction authorization (32-byte keys, 64-byte signatures); address = CID of the public key |
| Content addressing | CID (DAG-CBOR + SHA-256) | All data structure references |
| State proofs | Sparse Merkle Tree | Inclusion/exclusion proofs for all 5 sub-states |

## Dependencies

| Dependency | Purpose |
|---|---|
| [cashew](https://github.com/adalinxx/cashew) | Content-addressed Merkle data structures (IPLD, Sparse Merkle Trees, CIDs, Volumes) |
| [swift-crypto](https://github.com/apple/swift-crypto) | Ed25519 signatures, SHA-256 |
| [UInt256](https://github.com/adalinxx/UInt256) | 256-bit integers for targets |
| [swift-cid](https://github.com/swift-libp2p/swift-cid) | Content Identifier encoding |
| [CollectionConcurrencyKit](https://github.com/JohnSundell/CollectionConcurrencyKit) | Concurrent collection operations |
| [WasmKit](https://github.com/swiftwasm/WasmKit) | Deterministic WASM policy execution |

---

## Roadmap

### Done

- [x] Block validation (genesis, nexus, child chain)
- [x] Three-phase state model (parentState / prevState / postState)
- [x] Five partitioned Sparse Merkle Tree sub-states (accounts, general, deposits, receipts, genesis) with concurrent updates
- [x] Cross-chain deposit/receipt/withdrawal protocol (trustless parent-child transfers)
- [x] Hierarchical GHOST fork choice (descendant-subtree weight + inherited merged-mining weight / `trueCumWork`)
- [x] Reorganization propagation through chain hierarchy
- [x] Configurable ChainSpec with halving schedule and windowed target adjustment (clamped per-step band)
- [x] Ed25519 transaction signing and verification
- [x] Per-signer nonce tracking merged into AccountState trie
- [x] Cross-chain replay protection via chainPath
- [x] Stateless block verification (nodes lazy-load state via Fetcher protocol)
- [x] Transaction/action chain policies using the WASM runtime
- [x] Volume-based data locality hints at Block and Transaction boundaries
- [x] StateDiff with ref-counted created/replaced CID tracking
- [x] Validation pipeline threads StateDiff from postState through to processBlockHeader
- [x] State continuity validation — `prevState`/`postState` (anti-forgery for intermediate blocks)
- [x] Formal protocol specification
- [x] Parent-derived target: enforce `B.target == parent.nextTarget` + clamped proportional retarget (see `docs/spec.md` §5.5)

### Next

- [ ] iOS light client SDK
- [ ] SPV block header chain for mobile wallets
- [ ] Cross-chain proof verification on-device
- [ ] SwiftUI wallet reference implementation
- [ ] Alternative consensus per chain (PoS, PoA via ChainSpec extension)
- [ ] On-chain governance for ChainSpec changes
- [ ] EIP-1559-style fee market

---

## License

See [LICENSE](LICENSE) for details.
