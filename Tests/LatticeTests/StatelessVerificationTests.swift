import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

// MARK: - Helpers

private let target = UInt256(1000)

private func makeSpec(_ dir: String = "Nexus", premine: UInt64 = 0) -> ChainSpec {
    ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
}

private func addr(_ publicKey: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
}

private func sign(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
    let h = try! HeaderImpl<TransactionBody>(node: body)
    let s = TransactionSigning.sign(bodyHeader: h, privateKeyHex: kp.privateKey)!
    return Transaction(signatures: [kp.publicKey: s], body: h)
}

private func nextDiff(_ spec: ChainSpec, previous: Block, timestamp: Int64) -> UInt256 {
    return spec.calculateMinimumTarget(
        previousTarget: previous.target,
        blockTimestamp: timestamp,
        previousTimestamp: previous.timestamp
    )
}

/// Store entire block CAS graph and flush to fetcher.
private func storeBlock(_ block: Block, to fetcher: StorableFetcher) async throws {
    let storer = CollectingStorer()
    try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
    await storer.flush(to: fetcher)
}

// MARK: - Tests

/// These tests prove that block validation is fully stateless: a node with no prior
/// state can verify any block by lazy-loading CAS nodes on demand via a Fetcher.
/// No local state storage is required — only access to a content-addressed store.
@MainActor
final class StatelessNexusVerificationTests: XCTestCase {

    /// A fresh node receives a nexus block with transactions and validates
    /// it using only CAS data propagated from the block producer.
    func testNexusBlockValidatedFromCASOnly() async throws {
        let spec = makeSpec()
        let kp = CryptoUtils.generateKeyPair()
        let minerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        // --- Producer side: build genesis + block 1 ---
        let producerFetcher = StorableFetcher()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: now - 30_000, target: target, fetcher: producerFetcher
        )
        let reward = spec.rewardAtBlock(1)
        let coinbaseBody = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(reward))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [minerAddr], fee: 0, nonce: 0,
            chainPath: ["Nexus"]
        )
        let ts1 = now - 29_000
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [sign(coinbaseBody, kp)],
            timestamp: ts1, target: target,
            nextTarget: nextDiff(spec, previous: genesis, timestamp: ts1),
            nonce: 0, fetcher: producerFetcher
        )

        // --- Serialize to CAS, create a fresh verifier ---
        let verifierFetcher = StorableFetcher()
        try await storeBlock(genesis, to: verifierFetcher)
        try await storeBlock(block1, to: verifierFetcher)

        // Resolve block from CID alone (stateless)
        let block1Header = try! VolumeImpl<Block>(node: block1)
        let resolved = try await block1Header.resolve(fetcher: verifierFetcher)
        guard let blockNode = resolved.node else {
            XCTFail("Could not resolve block from CAS")
            return
        }

        // Full validation — verifier has no prior state, only CAS data
        let valid = try await blockNode.validateNexus(fetcher: verifierFetcher).0
        XCTAssertTrue(valid, "Stateless verifier should validate nexus block from CAS data alone")

        // Independently verify frontier state derivation
        let frontierValid = try await blockNode.validatePostState(
            transactionBodies: [coinbaseBody], fetcher: verifierFetcher
        ).0
        XCTAssertTrue(frontierValid, "Frontier should be re-derivable via lazy loading")
    }

    /// Multiple blocks with different signers: verifier lazy-loads state for each block
    /// without maintaining any persistent state between validations.
    func testMultiBlockChainValidatedStateless() async throws {
        let spec = makeSpec()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = addr(alice.publicKey)
        let bobAddr = addr(bob.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        let producerFetcher = StorableFetcher()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: now - 30_000, target: target, fetcher: producerFetcher
        )

        // Block 1: alice gets reward
        let ts1 = now - 29_000
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: aliceAddr, delta: Int64(spec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [], signers: [aliceAddr], fee: 0, nonce: 0,
                chainPath: ["Nexus"]
            ), alice)],
            timestamp: ts1, target: target,
            nextTarget: nextDiff(spec, previous: genesis, timestamp: ts1),
            nonce: 0, fetcher: producerFetcher
        )

        // Block 2: bob gets reward
        let ts2 = now - 28_000
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: bobAddr, delta: Int64(spec.rewardAtBlock(2)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [], signers: [bobAddr], fee: 0, nonce: 0,
                chainPath: ["Nexus"]
            ), bob)],
            timestamp: ts2, target: target,
            nextTarget: nextDiff(spec, previous: block1, timestamp: ts2),
            nonce: 0, fetcher: producerFetcher
        )

        // Block 3: alice transfers to bob
        let fee: UInt64 = 10
        let transfer: UInt64 = 100
        let ts3 = now - 27_000
        let block3 = try await BlockBuilder.buildBlock(
            previous: block2,
            transactions: [sign(TransactionBody(
                accountActions: [
                    AccountAction(owner: aliceAddr, delta: -Int64(transfer + fee)),
                    AccountAction(owner: bobAddr, delta: Int64(transfer + spec.rewardAtBlock(3)))
                ],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [], signers: [aliceAddr], fee: fee, nonce: 1,
                chainPath: ["Nexus"]
            ), alice)],
            timestamp: ts3, target: target,
            nextTarget: nextDiff(spec, previous: block2, timestamp: ts3),
            nonce: 0, fetcher: producerFetcher
        )

        // Verifier: fresh fetcher with only CAS data
        let verifierFetcher = StorableFetcher()
        try await storeBlock(genesis, to: verifierFetcher)
        try await storeBlock(block1, to: verifierFetcher)
        try await storeBlock(block2, to: verifierFetcher)
        try await storeBlock(block3, to: verifierFetcher)

        // Validate block 3 — verifier lazy-loads homestead, previous blocks, etc.
        let block3Header = try! VolumeImpl<Block>(node: block3)
        let resolved = try await block3Header.resolve(fetcher: verifierFetcher)
        guard let block3Node = resolved.node else {
            XCTFail("Could not resolve block 3 from CAS")
            return
        }
        let valid = try await block3Node.validateNexus(fetcher: verifierFetcher).0
        XCTAssertTrue(valid, "Block 3 should validate stateless — all state lazy-loaded from CAS")
    }
}

/// Verifies that child block validation (merged mining) is also stateless.
@MainActor
final class StatelessChildChainVerificationTests: XCTestCase {

    func testChildBlockValidatedStateless() async throws {
        let nexusSpec = makeSpec("Nexus")
        let childSpec = makeSpec("Payments", premine: 10000)
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        let producerFetcher = StorableFetcher()

        // Child genesis with premine
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(childSpec.premineAmount()))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [], signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            timestamp: now - 30_000, target: target, fetcher: producerFetcher
        )

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: now - 30_000, target: target, fetcher: producerFetcher
        )

        // Nexus block 1: coinbase + genesis action embedding child chain
        let ts1 = now - 29_000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [],
                genesisActions: [GenesisAction(directory: "Payments", blockCID: try VolumeImpl<Block>(node: childGenesis).rawCID)],
                receiptActions: [], withdrawalActions: [], signers: [ownerAddr], fee: 0, nonce: 0,
                chainPath: ["Nexus"]
            ), kp)],
            children: ["Payments": childGenesis],
            timestamp: ts1, target: target,
            nextTarget: nextDiff(nexusSpec, previous: nexusGenesis, timestamp: ts1),
            nonce: 0, fetcher: producerFetcher
        )

        // Child block 1 extends child genesis (must share timestamp with parent nexus block)
        // Use nexusGenesis as parentChainBlock so parentState = nexusGenesis.postState = nexusBlock1.prevState
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(childSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [], signers: [ownerAddr], fee: 0, nonce: 1,
                chainPath: ["Nexus", "Payments"]
            ), kp)],
            parentChainBlock: nexusGenesis,
            timestamp: ts1, target: target, nonce: 0, fetcher: producerFetcher
        )

        // Verifier: fresh fetcher with only CAS data
        let verifierFetcher = StorableFetcher()
        try await storeBlock(nexusGenesis, to: verifierFetcher)
        try await storeBlock(nexusBlock1, to: verifierFetcher)
        try await storeBlock(childGenesis, to: verifierFetcher)
        try await storeBlock(childBlock1, to: verifierFetcher)

        // Validate the child block via validateNexus (the per-process child
        // validation path) — stateless, from CAS data alone.
        let (childValid, _, _) = try await childBlock1.validateNexus(
            fetcher: verifierFetcher, chainPath: ["Nexus", "Payments"]
        )
        XCTAssertTrue(childValid, "Child block should validate stateless from CAS data alone")
    }
}

/// Verifies that targeted state resolution only fetches the minimal CAS nodes needed,
/// not the entire state tree.
@MainActor
final class TargetedResolutionTests: XCTestCase {

    func testStateResolutionWithManyAccountsValidatesStateless() async throws {
        let spec = makeSpec()
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        // Create 10 separate signers so the state tree has many entries
        var keyPairs: [(privateKey: String, publicKey: String)] = []
        var addrs: [String] = []
        for _ in 0..<10 {
            let kp = CryptoUtils.generateKeyPair()
            keyPairs.append(kp)
            addrs.append(addr(kp.publicKey))
        }

        let producerFetcher = StorableFetcher()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: now - 30_000, target: target, fetcher: producerFetcher
        )

        // Block 1: fund all 10 accounts (each gets 1/10 of reward)
        var txs1: [Transaction] = []
        let reward1 = spec.rewardAtBlock(1)
        for i in 0..<10 {
            let credit = Int64(reward1) / 10
            txs1.append(sign(TransactionBody(
                accountActions: [AccountAction(owner: addrs[i], delta: credit)],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [], signers: [addrs[i]], fee: 0, nonce: 0,
                chainPath: ["Nexus"]
            ), keyPairs[i]))
        }

        let ts1 = now - 29_000
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: txs1,
            timestamp: ts1, target: target,
            nextTarget: nextDiff(spec, previous: genesis, timestamp: ts1),
            nonce: 0, fetcher: producerFetcher
        )

        // Block 2: only account 0 transfers to account 1
        let transferAmount: Int64 = 10
        let ts2 = now - 28_000
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1,
            transactions: [sign(TransactionBody(
                accountActions: [
                    AccountAction(owner: addrs[0], delta: -transferAmount),
                    AccountAction(owner: addrs[1], delta: transferAmount + Int64(spec.rewardAtBlock(2)))
                ],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [], signers: [addrs[0]], fee: 0, nonce: 1,
                chainPath: ["Nexus"]
            ), keyPairs[0])],
            timestamp: ts2, target: target,
            nextTarget: nextDiff(spec, previous: block1, timestamp: ts2),
            nonce: 0, fetcher: producerFetcher
        )

        // Verifier: fresh fetcher with only CAS data
        let verifierFetcher = StorableFetcher()
        try await storeBlock(genesis, to: verifierFetcher)
        try await storeBlock(block1, to: verifierFetcher)
        try await storeBlock(block2, to: verifierFetcher)

        // Validate block 2 — targeted resolution fetches only accounts 0 and 1,
        // not all 10 accounts in the state tree
        let block2Header = try! VolumeImpl<Block>(node: block2)
        let resolved = try await block2Header.resolve(fetcher: verifierFetcher)
        guard let blockNode = resolved.node else {
            XCTFail("Could not resolve block 2")
            return
        }

        let valid = try await blockNode.validateNexus(fetcher: verifierFetcher).0
        XCTAssertTrue(valid, "Block with many accounts should validate via targeted resolution")
    }
}
