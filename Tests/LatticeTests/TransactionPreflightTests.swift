import XCTest
@testable import Lattice
import cashew
import UInt256

@MainActor
final class TransactionPreflightTests: XCTestCase {
    private let easy = UInt256.max

    private func spec(
        premine: UInt64 = 0,
        policies: [WasmPolicyRef] = []
    ) -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 1_000_000,
            premine: premine,
            targetBlockTime: 1_000,
            initialReward: 1_024,
            halvingInterval: 10_000,
            retargetWindow: 5,
            wasmPolicies: policies
        )
    }

    private func transaction(
        signers: [(privateKey: String, publicKey: String)],
        nonce: UInt64,
        chainPath: [String] = [DEFAULT_ROOT_DIRECTORY],
        accountActions: [AccountAction] = [],
        withdrawalActions: [WithdrawalAction] = []
    ) -> Transaction {
        let addresses = signers.map { testAddress(publicKey: $0.publicKey) }
        let body = TransactionBody(
            accountActions: accountActions,
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: withdrawalActions,
            signers: addresses,
            fee: 0,
            nonce: nonce,
            chainPath: chainPath
        )
        let header = try! HeaderImpl<TransactionBody>(node: body)
        let signatures = Dictionary(uniqueKeysWithValues: signers.map {
            ($0.publicKey, TransactionSigning.sign(
                bodyHeader: header,
                privateKeyHex: $0.privateKey
            )!)
        })
        return Transaction(signatures: signatures, body: header)
    }

    private func fundedLevel(
        fetcher: StorableFetcher,
        alice: (privateKey: String, publicKey: String),
        bob: (privateKey: String, publicKey: String)
    ) async throws -> (ChainLevel, ChainState, Block) {
        let aliceAddress = testAddress(publicKey: alice.publicKey)
        let bobAddress = testAddress(publicKey: bob.publicKey)
        let premine = transaction(
            signers: [alice, bob],
            nonce: 0,
            accountActions: [
                AccountAction(owner: aliceAddress, delta: 500),
                AccountAction(owner: bobAddress, delta: 500),
            ]
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec(premine: 1),
            transactions: [premine],
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        return (ChainLevel(testChain: chain), chain, genesis)
    }

    func testMultiSignerNonceClassificationUsesEverySignerFloor() async throws {
        let fetcher = StorableFetcher()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let (level, chain, genesis) = try await fundedLevel(
            fetcher: fetcher,
            alice: alice,
            bob: bob
        )

        let ready = await level.preflightTransaction(
            transaction(signers: [alice, bob], nonce: 1),
            fetcher: fetcher
        )
        XCTAssertEqual(ready.disposition, .ready)
        XCTAssertEqual(ready.tipCID, try BlockHeader(node: genesis).rawCID)

        let future = await level.preflightTransaction(
            transaction(signers: [alice, bob], nonce: 2),
            fetcher: fetcher
        )
        XCTAssertEqual(future.disposition, .future)

        let aliceAdvance = transaction(signers: [alice], nonce: 1)
        let block = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [aliceAdvance],
            timestamp: 2_000,
            target: easy,
            fetcher: fetcher
        )
        let blockHeader = try BlockHeader(node: block)
        _ = await chain.submitTestBlock(blockHeader: blockHeader, block: block)

        let mixedStale = await level.preflightTransaction(
            transaction(signers: [alice, bob], nonce: 1),
            fetcher: fetcher
        )
        XCTAssertEqual(mixedStale.disposition, .invalid)
        XCTAssertEqual(mixedStale.tipCID, blockHeader.rawCID)

        let mixedFuture = await level.preflightTransaction(
            transaction(signers: [alice, bob], nonce: 2),
            fetcher: fetcher
        )
        XCTAssertEqual(mixedFuture.disposition, .future)
    }

    func testStateTransitionAndSignatureFailuresAreInvalid() async throws {
        let fetcher = StorableFetcher()
        let signer = CryptoUtils.generateKeyPair()
        let genesis = try await buildAndStoreGenesis(
            spec: spec(),
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
        let address = testAddress(publicKey: signer.publicKey)

        let overspend = transaction(
            signers: [signer],
            nonce: 0,
            accountActions: [AccountAction(owner: address, delta: -1)]
        )
        let overspendResult = await level.preflightTransaction(
            overspend,
            fetcher: fetcher
        )
        XCTAssertEqual(overspendResult.disposition, .invalid)

        let valid = transaction(signers: [signer], nonce: 0)
        let badSignature = Transaction(
            signatures: [signer.publicKey: "00"],
            body: valid.body
        )
        let badSignatureResult = await level.preflightTransaction(
            badSignature,
            fetcher: fetcher
        )
        XCTAssertEqual(badSignatureResult.disposition, .invalid)
    }

    func testMissingBodyAndPolicyContentAreUnavailable() async throws {
        let fetcher = StorableFetcher()
        let signer = CryptoUtils.generateKeyPair()
        let missingModule = WasmPolicyRef(
            moduleCID: testCID("missing-policy"),
            scope: .transaction
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec(policies: [missingModule]),
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))

        let missingPolicyResult = await level.preflightTransaction(
            transaction(signers: [signer], nonce: 0),
            fetcher: fetcher
        )
        XCTAssertEqual(missingPolicyResult.disposition, .unavailable)

        let missingBody = Transaction(
            signatures: [:],
            body: HeaderImpl<TransactionBody>(rawCID: testCID("missing-body"))
        )
        let missingBodyResult = await level.preflightTransaction(
            missingBody,
            fetcher: fetcher
        )
        XCTAssertEqual(missingBodyResult.disposition, .unavailable)
    }

    func testRejectingPolicyIsInvalid() async throws {
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(
            accepts: false,
            scope: .transaction,
            fetcher: fetcher
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec(policies: [policy]),
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
        let signer = CryptoUtils.generateKeyPair()

        let rejected = await level.preflightTransaction(
            transaction(signers: [signer], nonce: 0),
            fetcher: fetcher
        )
        XCTAssertEqual(rejected.disposition, .invalid)
    }

    func testChildWithdrawalNeedsCandidateParentState() async throws {
        let fetcher = StorableFetcher()
        let signer = CryptoUtils.generateKeyPair()
        let childSpec = spec()
        let genesis = try await buildAndStoreGenesis(
            spec: childSpec,
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: genesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let address = testAddress(publicKey: signer.publicKey)
        let withdrawal = transaction(
            signers: [signer],
            nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"],
            withdrawalActions: [WithdrawalAction(
                withdrawer: address,
                nonce: 1,
                demander: address,
                amountDemanded: 1,
                amountWithdrawn: 1
            )]
        )

        let result = await level.preflightTransaction(
            withdrawal,
            fetcher: fetcher
        )
        XCTAssertEqual(result.disposition, .unavailable)
    }
}
