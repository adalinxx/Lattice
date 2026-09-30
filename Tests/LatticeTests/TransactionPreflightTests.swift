import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import cashew
import UInt256

@MainActor
final class TransactionPreflightTests: XCTestCase {
    private let easy = UInt256.max

    private func spec(
        premine: UInt64 = 0,
        policies: [WasmPolicyRef] = []
    ) -> ChainSpec {
        ChainSpec.test(
            premine: premine,
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
        await chain.markValidated(blockHash: blockHeader.rawCID)

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

    func testPreflightClassifiesAgainstTheExecutedTipNotTheWeighedOne() async throws {
        // lattice-node #228: genesis -> block 1 (executed) -> block 2 (weighed
        // only, the canonical tip). Block 2 declares Alice's nonce 1 spent, so
        // her nonce-1 transaction is valid only on block 1's executed state.
        let fetcher = StorableFetcher()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let (level, chain, genesis) = try await fundedLevel(
            fetcher: fetcher,
            alice: alice,
            bob: bob
        )
        let executed = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [],
            timestamp: 2_000,
            target: easy,
            fetcher: fetcher
        )
        let executedHeader = try BlockHeader(node: executed)
        _ = await chain.submitTestBlock(blockHeader: executedHeader, block: executed)
        await chain.markValidated(blockHash: executedHeader.rawCID)
        let weighed = try await buildAndStoreBlock(
            previous: executed,
            transactions: [transaction(signers: [alice], nonce: 1)],
            timestamp: 3_000,
            target: easy,
            fetcher: fetcher
        )
        let weighedHeader = try BlockHeader(node: weighed)
        _ = await chain.submitTestBlock(blockHeader: weighedHeader, block: weighed)
        let canonicalTip = await chain.canonicalTip
        XCTAssertEqual(canonicalTip, weighedHeader.rawCID)
        let executedTipIsExecuted = await chain.hasExecutedAncestry(
            blockHash: executedHeader.rawCID
        )
        let weighedTipIsExecuted = await chain.hasExecutedAncestry(
            blockHash: weighedHeader.rawCID
        )
        XCTAssertTrue(executedTipIsExecuted)
        XCTAssertFalse(weighedTipIsExecuted)

        let aliceNext = transaction(signers: [alice], nonce: 1)
        let atExecuted = await level.preflightTransaction(
            aliceNext,
            at: executedHeader.rawCID,
            fetcher: fetcher
        )
        XCTAssertEqual(atExecuted.disposition, .ready)
        XCTAssertEqual(atExecuted.tipCID, executedHeader.rawCID)
        let futureAtExecuted = await level.preflightTransaction(
            transaction(signers: [alice], nonce: 2),
            at: executedHeader.rawCID,
            fetcher: fetcher
        )
        XCTAssertEqual(futureAtExecuted.disposition, .future)

        // Neither naming the weighed block nor defaulting to the canonical tip
        // classifies against its declared state.
        for (tip, label) in [(Optional(weighedHeader.rawCID), "named"), (nil, "default")] {
            let result = await level.preflightTransaction(
                aliceNext,
                at: tip,
                fetcher: fetcher
            )
            XCTAssertEqual(result.disposition, .unavailable, label)
            XCTAssertEqual(result.tipCID, weighedHeader.rawCID, label)
        }

        // Once the weighed block is executed it is a valid tip, and its state
        // has spent Alice's nonce 1.
        await chain.markValidated(blockHash: weighedHeader.rawCID)
        let afterExecution = await level.preflightTransaction(
            aliceNext,
            fetcher: fetcher
        )
        XCTAssertEqual(afterExecution.disposition, .invalid)
        XCTAssertEqual(afterExecution.tipCID, weighedHeader.rawCID)
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

    func testValueCreatingTransactionIsInvalid() async throws {
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

        // Credits with nothing debited: negative miner surplus. The block
        // reward no longer funds transactions, so no block may carry it.
        let minting = transaction(
            signers: [signer],
            nonce: 0,
            accountActions: [AccountAction(owner: address, delta: 5)]
        )
        let mintingResult = await level.preflightTransaction(minting, fetcher: fetcher)
        XCTAssertEqual(mintingResult.disposition, .invalid)

        let neutral = transaction(signers: [signer], nonce: 0)
        let neutralResult = await level.preflightTransaction(neutral, fetcher: fetcher)
        XCTAssertEqual(neutralResult.disposition, .ready)
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

    func testPolicySeesNextBlockHeight() async throws {
        // The tip is genesis (height 0), so the carrying block is height 1.
        for (minimum, expected) in [(Int64(1), TransactionPreflightDisposition.ready), (2, .invalid)] {
            let fetcher = StorableFetcher()
            let policy = try await storeWasmPolicy(
                contextFieldAt: wasmPolicyContextHeightOffset,
                atLeast: minimum,
                fetcher: fetcher
            )
            let genesis = try await buildAndStoreGenesis(
                spec: spec(policies: [policy]),
                timestamp: 1_000,
                target: easy,
                fetcher: fetcher
            )
            let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
            let result = await level.preflightTransaction(
                transaction(signers: [CryptoUtils.generateKeyPair()], nonce: 0),
                fetcher: fetcher
            )
            XCTAssertEqual(result.disposition, expected, "minimum height \(minimum)")
        }
    }

    func testPolicySeesInjectedValidationTime() async throws {
        // The carrying block is stamped max(tip + 1, now), and the policy
        // requires at least 3_000. Every clock sits far below wall time, which
        // would accept each case, so only the injected clock decides.
        let cases: [(tip: Int64, now: Int64, expected: TransactionPreflightDisposition)] = [
            (1_000, 3_000, .ready),    // now wins and meets the bound
            (1_000, 2_999, .invalid),  // now wins, one below the bound
            (5_000, 0, .ready),        // tip + 1 wins over a stale clock
        ]
        for (tip, now, expected) in cases {
            let fetcher = StorableFetcher()
            let policy = try await storeWasmPolicy(
                contextFieldAt: wasmPolicyContextTimestampOffset,
                atLeast: 3_000,
                fetcher: fetcher
            )
            let genesis = try await buildAndStoreGenesis(
                spec: spec(policies: [policy]),
                timestamp: tip,
                target: easy,
                fetcher: fetcher
            )
            let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
            let result = await level.preflightTransaction(
                transaction(signers: [CryptoUtils.generateKeyPair()], nonce: 0),
                fetcher: fetcher,
                validationContext: ValidationContext(nowMilliseconds: now)
            )
            XCTAssertEqual(result.disposition, expected, "tip \(tip), now \(now)")
        }
    }

    func testNodeLocalPolicyResourceLimitIsUnavailable() async throws {
        // An accepting policy is ready under default limits; a node whose own
        // limits refuse the module has no verdict, which is never `.invalid`.
        let cases: [(limits: WasmPolicyResourceLimits, expected: TransactionPreflightDisposition)] = [
            (.default, .ready),
            (WasmPolicyResourceLimits(maxModuleBytes: 1), .unavailable),
        ]
        for (limits, expected) in cases {
            let fetcher = StorableFetcher()
            let policy = try await storeWasmPolicy(
                accepts: true,
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
            let result = await level.preflightTransaction(
                transaction(signers: [CryptoUtils.generateKeyPair()], nonce: 0),
                fetcher: fetcher,
                validationContext: ValidationContext(
                    nowMilliseconds: 2_000,
                    wasmResourceLimits: limits
                )
            )
            XCTAssertEqual(result.disposition, expected, "maxModuleBytes \(limits.maxModuleBytes)")
        }
    }

    func testWasmPolicyErrorClassificationMatchesImport() {
        // Preflight evicts exactly what import would exclude, and keeps pooled
        // exactly what import would retry (#63). Only an unencodable context is
        // a verdict; every other policy error is no verdict: retry, never
        // exclude.
        let cases: [WasmPolicyError] = [
            .unsupportedABI(WasmPolicyRef.currentABIVersion + 1),
            .missingModule("m"),
            .invalidModule,
            .missingMemory,
            .missingAllocator,
            .missingEntrypoint("e"),
            .invalidFunctionSignature("f"),
            .invalidAllocation,
            .invalidReturn,
            .contextEncodingFailed,
            .resourceUnavailable,
            .nondeterministicConstruct("c"),
        ]
        for error in cases {
            let imported = ChainLevel.classifyValidationFailureForTesting(error)
            let preflightUnavailable = transactionPreflightEvidenceUnavailable(error)
            let isVerdict: Bool
            if case .contextEncodingFailed = error { isVerdict = true } else { isVerdict = false }
            XCTAssertEqual(
                imported,
                isVerdict ? .protocolInvalid : .unavailableEvidence,
                "import: \(error)"
            )
            XCTAssertEqual(preflightUnavailable, !isVerdict, "preflight: \(error)")
            XCTAssertEqual(
                preflightUnavailable,
                !ChainLevel.isDeterministicInvalidityForTesting(imported),
                "preflight and import disagree on \(error)"
            )
        }
    }

    func testMisbehavingPolicyIsUnavailableNotInvalid() async throws {
        // A module without the configured entrypoint throws
        // `.missingEntrypoint` at evaluation: no verdict on the transaction,
        // so it stays pooled rather than being evicted.
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(
            accepts: true,
            scope: .transaction,
            fetcher: fetcher,
            entrypoint: "absent_entrypoint"
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec(policies: [policy]),
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
        let result = await level.preflightTransaction(
            transaction(signers: [CryptoUtils.generateKeyPair()], nonce: 0),
            fetcher: fetcher
        )
        XCTAssertEqual(result.disposition, .unavailable)
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
