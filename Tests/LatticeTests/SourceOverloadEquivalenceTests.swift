import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

/// Equivalence tests for the additive `source:` overloads on Lattice's
/// block-validation/resolution APIs (`resolveBlockContent`, `validateNexus`,
/// `processBlockHeader`). Each test runs the same block through the existing
/// `fetcher:` API and the new `source:` API over the SAME backing CAS, and
/// asserts the two paths produce identical results. The `source:` path wraps a
/// batched cashew `ContentSource` in a single `CoalescingFetcher`; these tests
/// prove that batching changes only how content is fetched, never the result.
@MainActor
final class SourceOverloadEquivalenceTests: XCTestCase {

    private func spec(_ dir: String = "Nexus") -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 1_000_000,
            premine: 1000,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            retargetWindow: 5
        )
    }

    private func addr(_ publicKey: String) -> String {
        try! HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
    }

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Build a representative valid Nexus block (premine genesis + a transfer
    /// block carrying a transaction) plus a child block, all stored in `fetcher`.
    /// Returns (genesisHeader, blockHeader, block).
    private func buildRepresentativeBlock(
        fetcher: StorableFetcher
    ) async throws -> (BlockHeader, BlockHeader, Block) {
        let t = now()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = addr(alice.publicKey)
        let bobAddr = addr(bob.publicKey)
        let s = spec()
        let premineAmount = s.premineAmount()
        let reward = s.rewardAtBlock(0)

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [aliceAddr], fee: 0, nonce: 0
        )
        let premineHeader = try! HeaderImpl<TransactionBody>(node: premineBody)
        let premineSig = TransactionSigning.sign(bodyHeader: premineHeader, privateKeyHex: alice.privateKey)!
        let premineTx = Transaction(signatures: [alice.publicKey: premineSig], body: premineHeader)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, transactions: [premineTx],
            timestamp: t - 20_000, target: UInt256.max, fetcher: fetcher
        )

        let transferAmount: UInt64 = 250
        let transferBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premineAmount - transferAmount) - Int64(premineAmount)),
                AccountAction(owner: bobAddr, delta: Int64(transferAmount + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let transferHeader = try! HeaderImpl<TransactionBody>(node: transferBody)
        let transferSig = TransactionSigning.sign(bodyHeader: transferHeader, privateKeyHex: alice.privateKey)!
        let transferTx = Transaction(signatures: [alice.publicKey: transferSig], body: transferHeader)

        // A child block so the content package exercises the child-link list path.
        let child = try await BlockBuilder.buildGenesis(
            spec: spec("Child"), timestamp: t - 20_000, target: UInt256.max, fetcher: fetcher
        )

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [transferTx], children: ["Child": child],
            timestamp: t - 10_000, target: UInt256.max, nonce: 1, fetcher: fetcher
        )
        // Persist the full block volume so both paths can resolve it by CID.
        try VolumeImpl<Block>(node: block).storeRecursively(storer: fetcher)

        let genesisHeader = try! VolumeImpl<Block>(node: genesis)
        let blockHeader = VolumeImpl<Block>(rawCID: try! VolumeImpl<Block>(node: block).rawCID)
        return (genesisHeader, blockHeader, block)
    }

    // MARK: - resolveBlockContent

    func testResolveBlockContentSourceMatchesFetcher() async throws {
        let fetcher = StorableFetcher()
        let (_, blockHeader, _) = try await buildRepresentativeBlock(fetcher: fetcher)
        let source = FetcherContentSource(fetcher)

        let viaFetcher = try await blockHeader.resolveBlockContent(fetcher: fetcher)
        // Fresh header (no node) so the source path resolves from scratch, not a cache.
        let freshHeader = VolumeImpl<Block>(rawCID: try! blockHeader.rawCID)
        let viaSource = try await freshHeader.resolveBlockContent(source: source)

        // The resolved block must be byte-identical: same root CID, same resolved
        // children CIDs, and the same resolved/unresolved structure.
        let f = try XCTUnwrap(viaFetcher.node)
        let s = try XCTUnwrap(viaSource.node)
        XCTAssertEqual(try! viaFetcher.rawCID, try! viaSource.rawCID)
        XCTAssertEqual(f.spec.rawCID, s.spec.rawCID)
        XCTAssertEqual(f.transactions.rawCID, s.transactions.rawCID)
        XCTAssertEqual(f.children.rawCID, s.children.rawCID)
        XCTAssertEqual(f.toData(), s.toData())

        // Same resolution policy applied: spec/transactions/children resolved,
        // postState left external.
        XCTAssertNotNil(s.spec.node)
        XCTAssertNotNil(s.transactions.node)
        XCTAssertNotNil(s.children.node)
        XCTAssertNil(s.postState.node)

        let fTxs = try XCTUnwrap(f.transactions.node?.allKeysAndValues())
        let sTxs = try XCTUnwrap(s.transactions.node?.allKeysAndValues())
        XCTAssertEqual(fTxs.count, sTxs.count)
        XCTAssertEqual(
            fTxs.values.compactMap { $0.node?.body.node?.toData() },
            sTxs.values.compactMap { $0.node?.body.node?.toData() }
        )
    }

    // MARK: - validateNexus

    func testValidateNexusSourceMatchesFetcher() async throws {
        let fetcher = StorableFetcher()
        let (_, _, block) = try await buildRepresentativeBlock(fetcher: fetcher)
        let source = FetcherContentSource(fetcher)

        let viaFetcher = try await block.validateNexus(fetcher: fetcher)
        let viaSource = try await block.validateNexus(source: source)

        XCTAssertTrue(viaFetcher.0, "control: the representative block must validate")
        XCTAssertEqual(viaFetcher.0, viaSource.0, "validity bit must match")
        XCTAssertEqual(viaFetcher.1.replaced, viaSource.1.replaced, "state diff (replaced) must be identical")
        XCTAssertEqual(viaFetcher.1.created, viaSource.1.created, "state diff (created) must be identical")
        XCTAssertEqual(
            try viaFetcher.2.map { try LatticeStateHeader(node: $0).rawCID },
            try viaSource.2.map { try LatticeStateHeader(node: $0).rawCID },
            "materialized post-state must be identical"
        )
    }

    func testValidateNexusSourceMatchesFetcherStructuralOnly() async throws {
        let fetcher = StorableFetcher()
        let (_, _, block) = try await buildRepresentativeBlock(fetcher: fetcher)
        let source = FetcherContentSource(fetcher)

        let viaFetcher = try await block.validateNexus(fetcher: fetcher, requirePostState: false)
        let viaSource = try await block.validateNexus(source: source, requirePostState: false)
        XCTAssertTrue(viaFetcher.0)
        XCTAssertEqual(viaFetcher.0, viaSource.0)
    }

    func testValidateNexusSourceMatchesFetcherOnInvalidBlock() async throws {
        let fetcher = StorableFetcher()
        let t = now()
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = addr(miner.publicKey)
        let s = spec("Nexus")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000, maxBlockSize: 1_000_000, premine: 0,
                targetBlockTime: 1_000, initialReward: 1024, halvingInterval: 10_000,
                retargetWindow: 5
            ),
            timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )
        let reward = s.rewardAtBlock(0)
        // Over-claim the reward → invalid block.
        let overclaimBody = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(reward + 1))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: overclaimBody)
        let sig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: miner.privateKey)!
        let tx = Transaction(signatures: [miner.publicKey: sig], body: bodyHeader)
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx],
            timestamp: t - 10_000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        try VolumeImpl<Block>(node: block).storeRecursively(storer: fetcher)
        let source = FetcherContentSource(fetcher)

        let viaFetcher = try await block.validateNexus(fetcher: fetcher).0
        let viaSource = try await block.validateNexus(source: source).0
        XCTAssertFalse(viaFetcher, "control: over-claim block must be rejected")
        XCTAssertEqual(viaFetcher, viaSource, "rejection must match across fetcher/source")
    }

    // MARK: - processBlockHeader

    func testProcessBlockHeaderSourceMatchesFetcher() async throws {
        // Build ONE block + CAS, then process that SAME block header against two
        // independent Lattice instances (fresh chains from the same genesis): one
        // via `fetcher:`, one via `source:`. Same inputs ⇒ the only difference is
        // the resolution driver, so the accept/commit outcomes must be identical.
        let fetcher = StorableFetcher()
        let (genesis, blockHeader, _) = try await buildRepresentativeBlock(fetcher: fetcher)
        let genesisBlock = try XCTUnwrap(genesis.node)

        let latticeA = Lattice(nexus: ChainLevel(chain: ChainState.fromGenesis(block: genesisBlock), children: [:]))
        let resultViaFetcher = await latticeA.processBlockHeader(
            blockHeader, fetcher: fetcher
        )

        let latticeB = Lattice(nexus: ChainLevel(chain: ChainState.fromGenesis(block: genesisBlock), children: [:]))
        let resultViaSource = await latticeB.processBlockHeader(
            blockHeader, source: FetcherContentSource(fetcher)
        )

        XCTAssertTrue(resultViaFetcher.isAccepted, "control: the representative block must be accepted")
        XCTAssertEqual(resultViaFetcher.isAccepted, resultViaSource.isAccepted)
        XCTAssertEqual(resultViaFetcher.isRejected, resultViaSource.isRejected)
        XCTAssertEqual(resultViaFetcher.isDeferred, resultViaSource.isDeferred)
        XCTAssertEqual(resultViaFetcher.stateDiff.replaced, resultViaSource.stateDiff.replaced)
        XCTAssertEqual(resultViaFetcher.stateDiff.created, resultViaSource.stateDiff.created)
        XCTAssertEqual(
            try resultViaFetcher.materializedPostState.map { try LatticeStateHeader(node: $0).rawCID },
            try resultViaSource.materializedPostState.map { try LatticeStateHeader(node: $0).rawCID }
        )
    }
}
