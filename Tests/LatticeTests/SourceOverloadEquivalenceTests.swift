import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

/// Equivalence tests for the additive `source:` overloads on Lattice's
/// block-validation APIs (`validateNexus`, `admitBlockHeaderChainLocal`). Each test runs the same block through the existing
/// `fetcher:` API and the new `source:` API over the SAME backing CAS, and
/// asserts the two paths produce identical results. The `source:` path wraps a
/// batched cashew `ContentSource` in a single `CoalescingFetcher`; these tests
/// prove that batching changes only how content is fetched, never the result.
@MainActor
final class SourceOverloadEquivalenceTests: XCTestCase {

    private func spec() -> ChainSpec {
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
            receiptActions: [], withdrawalActions: [], signers: [], fee: 0, nonce: 0,
            chainPath: ["Nexus"]
        )
        let premineHeader = try! HeaderImpl<TransactionBody>(node: premineBody)
        let premineTx = Transaction(signatures: [:], body: premineHeader)

        let genesis = try await buildAndStoreGenesis(
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
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let transferHeader = try! HeaderImpl<TransactionBody>(node: transferBody)
        let transferSig = TransactionSigning.sign(bodyHeader: transferHeader, privateKeyHex: alice.privateKey)!
        let transferTx = Transaction(signatures: [alice.publicKey: transferSig], body: transferHeader)

        // A child block so the content package exercises the child-link list path.
        let child = try await buildAndStoreGenesis(
            spec: spec(), timestamp: t - 20_000, target: UInt256.max, fetcher: fetcher
        )

        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [transferTx], children: ["Child": child],
            timestamp: t - 10_000, target: UInt256.max, nonce: 1, fetcher: fetcher
        )
        // Persist the full block volume so both paths can resolve it by CID.
        try await VolumeImpl<Block>(node: block).store(
            paths: Block.contentResolutionPaths,
            storer: fetcher
        )

        let genesisHeader = try! VolumeImpl<Block>(node: genesis)
        let blockHeader = VolumeImpl<Block>(rawCID: try! VolumeImpl<Block>(node: block).rawCID)
        return (genesisHeader, blockHeader, block)
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

    func testValidateNexusSourceMatchesFetcherOnInvalidBlock() async throws {
        let fetcher = StorableFetcher()
        let t = now()
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = addr(miner.publicKey)
        let s = spec()
        let genesis = try await buildAndStoreGenesis(
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
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx],
            timestamp: t - 10_000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        try await VolumeImpl<Block>(node: block).store(
            paths: Block.contentResolutionPaths,
            storer: fetcher
        )
        let source = FetcherContentSource(fetcher)

        let viaFetcher = try await block.validateNexus(fetcher: fetcher).0
        let viaSource = try await block.validateNexus(source: source).0
        XCTAssertFalse(viaFetcher, "control: over-claim block must be rejected")
        XCTAssertEqual(viaFetcher, viaSource, "rejection must match across fetcher/source")
    }

    // MARK: - chain-local admission

    func testAdmissionSourceMatchesFetcher() async throws {
        // Build ONE block + CAS, then process that SAME block header against two
        // independent Lattice instances (fresh chains from the same genesis): one
        // via `fetcher:`, one via `source:`. Same inputs ⇒ the only difference is
        // the resolution driver, so the accept/commit outcomes must be identical.
        let fetcher = StorableFetcher()
        let (genesis, blockHeader, _) = try await buildRepresentativeBlock(fetcher: fetcher)
        let genesisBlock = try XCTUnwrap(genesis.node)

        let levelA = ChainLevel(testChain: ChainState.fromGenesis(block: genesisBlock))
        let resultViaFetcher = try await levelA.admitBlockHeaderChainLocal(
            blockHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        let levelB = ChainLevel(testChain: ChainState.fromGenesis(block: genesisBlock))
        let resultViaSource = try await levelB.admitBlockHeaderChainLocal(
            blockHeader,
            source: FetcherContentSource(fetcher),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        guard case let .accepted(fetcherAcceptance) = resultViaFetcher,
              let fetcherDiff = fetcherAcceptance.stateDiff else {
            return XCTFail("control: the representative block must canonicalize")
        }
        guard case let .accepted(sourceAcceptance) = resultViaSource,
              let sourceDiff = sourceAcceptance.stateDiff else {
            return XCTFail("source admission must canonicalize like fetcher admission")
        }
        XCTAssertEqual(fetcherDiff.replaced, sourceDiff.replaced)
        XCTAssertEqual(fetcherDiff.created, sourceDiff.created)
        XCTAssertEqual(
            fetcherAcceptance.sameChainPredecessor,
            sourceAcceptance.sameChainPredecessor
        )
        XCTAssertEqual(
            try fetcherAcceptance.materializedPostState.map { try LatticeStateHeader(node: $0).rawCID },
            try sourceAcceptance.materializedPostState.map { try LatticeStateHeader(node: $0).rawCID }
        )
    }
}
