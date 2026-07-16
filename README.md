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

Lattice is a proof-of-work protocol in which every chain is both a chain and a *tree of chains* rooted at it. Any chain can spawn child chains, and one nonce search secures an entire subtree through **nested merged mining**. The **nexus** is the first outermost chain — the entry from outside (other outermost chains may exist). Each chain defines its own operations, while descendants inherit root-CID-deduplicated work from accepted ancestor graphs. Value flows between chains through a cryptographic deposit/receipt/withdrawal protocol verified entirely by Merkle proofs. No bridges. No federations. No relayers.

**This is not a testnet, a token, or a whitepaper.** This is a working implementation in Swift with full block validation, consensus, state management, and cross-chain transfers. (Networking is not part of the library — Lattice defines the `Fetcher` abstraction; the node, e.g. `lattice-node`, provides the actual P2P/networking.)

### Why Lattice exists

Every multi-chain system before Lattice forces the same tradeoff: either chains share security and compete for limited slots (Polkadot), or chains are sovereign and must recruit their own validators (Cosmos, Avalanche). Both fragment security. Both require trusted bridges for cross-chain value transfer — the [most exploited components in crypto](https://www.fxempire.com/news/article/over-2b-lost-in-13-separate-crypto-bridge-hacks-this-year-1085594), responsible for over $2 billion in losses between 2022-2024.

Lattice eliminates both problems:

- **Nested merged mining** — One root hash commits the nested block tree. Every level evaluates that same hash against its own target, and descendants inherit a deduplicated measure of accepted work. This extends [RSK's merged mining with Bitcoin](https://medium.com/iovlabs-innovation-stories/modern-merge-mining-f294e45101a0) across an entire tree of chains without fragmenting the nonce search.

- **Trustless cross-chain transfers** — Value moves between chains via Merkle proof verification against state roots already committed in blocks. No multisig. No federation. No relayer. Compare this to RSK, which despite merged mining still relies on a [federated bridge](https://web3.gate.com/en/crypto-wiki/article/exploring-rootstock-an-in-depth-overview-of-bitcoin-s-sidechain-solution-20251208) for BTC transfers.

- **Unlimited chain creation** — Any chain can spawn children via a genesis transaction. No slot auctions. No governance proposals. No permission required. Each child chain has its own economic parameters, chain policies, and state, while sharing verified root-grind contributions with its ancestors.

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
                  lattice-node
        acquisition, persistence, retention,
          routing, and process supervision
                         |
          +--------------+--------------+
          |                             |
  process: Nexus                process: Nexus/Payments
  ChainLevel(context)           ChainLevel(context)
          |                             |
      ChainState                    ChainState
  one accepted graph            one accepted graph
```

One Lattice process owns exactly one path-defined chain. Its `ChainLevel` has an
immutable `ChainRuntimeContext` and one `ChainState`; it has no child runtimes and
never recurses into another chain. `lattice-node` decides which chains to run and
routes evidence between those processes. A parent process may issue immutable
facts about its own validated chain; it never decides child validity or fork
choice. The node authenticates the process that supplied each fact.

### Core ideas

- **Content-addressed data.** Blocks, transactions, and state use IPLD/CIDs;
  targeted Cashew traversal resolves and stores only the proven paths.
- **One grind, arbitrary coverage.** The root CID identifies physical work, so
  securing more blocks or data does not multiply its quantity.
- **Independent chain processes.** Each process validates one sparse root-to-block
  path and runs fork choice only for its own absolute chain path.
- **Three-phase state.** `parentState`, `prevState`, and `postState` make
  cross-chain verification possible from committed proofs.
- **Node-owned operations.** The node owns routing, durability, retention, pins,
  and projections; Lattice owns validation, accepted consensus facts, and fork
  choice.

### Admission boundary

```
Block arrives
  │
  ├── Capture one explicit validation-time context
  ├── Validate the root CID and root-work floor
  ├── Resolve the targeted child data and validation package
  ├── Check the proof path and carrier continuity
  ├── Compare the same root hash with this chain's target
  ├── Execute this chain's transition when accepted here
  ├── Store verified content and materialized state
  ├── Atomically stage immutable block/work facts in the node
  └── Commit to ChainState and return a revisioned ChainCommit
```

Gossip, sync, and mining use this boundary. Recovery replays authenticated durable
facts through the same graph and projection code. For the exact work algebra,
read [Hierarchical Work And Fork Choice](docs/consensus-fork-choice.md); for
component ownership, read [Lattice Architecture](docs/foundational-architecture.md);
for transfers, read [Cross-chain Protocol](docs/cross-chain.md).

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
- Throughput scales horizontally — sibling chains execute independently while sharing qualifying root-grind evidence
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
├── Lattice/          Single-chain admission, ChainState, ChainLevel, Genesis
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
- [x] Hierarchical GHOST over live, root-CID-deduplicated work measures
- [x] One independent Lattice process per chain; no recursive child runtime tree
- [x] Configurable ChainSpec with halving schedule and windowed target adjustment (clamped per-step band)
- [x] Ed25519 transaction signing and verification
- [x] Per-signer nonce tracking merged into AccountState trie
- [x] Cross-chain replay protection via chainPath
- [x] Stateless block verification (nodes lazy-load state via Fetcher protocol)
- [x] Transaction/action chain policies using the WASM runtime
- [x] Targeted Cashew resolve/store with independent nested Volume boundaries
- [x] Atomic typed block/work admission facts and revisioned chain-local commits
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
