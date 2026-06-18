import XCTest
@testable import Lattice
import UInt256
import cashew
import WasmParser
import WAT

struct NoopFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw NSError(domain: "NoopFetcher", code: 1)
    }
}

let testFetcher = NoopFetcher()

func testSpec() -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1024,
        halvingInterval: 10_000
    )
}

func genesisBlock(
    spec: ChainSpec? = nil,
    timestamp: Int64 = 1_000_000,
    target: UInt256 = UInt256(1000),
    nonce: UInt64 = 0
) async throws -> Block {
    try await BlockBuilder.buildGenesis(
        spec: spec ?? testSpec(),
        timestamp: timestamp,
        target: target,
        nonce: nonce,
        fetcher: testFetcher
    )
}

func nextBlock(
    previous: Block,
    timestamp: Int64,
    target: UInt256? = nil,
    nonce: UInt64 = 0
) async throws -> Block {
    try await BlockBuilder.buildBlock(
        previous: previous,
        timestamp: timestamp,
        target: target,
        nonce: nonce,
        fetcher: testFetcher
    )
}

func signedTransaction(
    body: TransactionBody,
    privateKeyHex: String,
    publicKeyHex: String
) -> Transaction {
    let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
    let signature = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: privateKeyHex) ?? ""
    return Transaction(
        signatures: [publicKeyHex: signature],
        body: bodyHeader
    )
}

// MARK: - Block Builder Pipeline Tests

@MainActor
final class BlockBuilderTests: XCTestCase {

    func testBuildGenesisProducesValidBlock() async throws {
        let genesis = try await genesisBlock()
        XCTAssertNil(genesis.parent)
        XCTAssertEqual(genesis.height, 0)
        XCTAssertEqual(genesis.prevState.rawCID,
            try! LatticeStateHeader(node: LatticeState.emptyState()).rawCID)
        XCTAssertEqual(genesis.prevState.rawCID, genesis.postState.rawCID,
            "Genesis with no transactions should have prevState == postState")
    }

    func testBuildBlockChainsFrontierToHomestead() async throws {
        let genesis = try await genesisBlock()
        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000)
        XCTAssertEqual(block1.prevState.rawCID, genesis.postState.rawCID)
        XCTAssertEqual(block1.height, 1)
        XCTAssertNotNil(block1.parent)
        XCTAssertEqual(block1.parent?.rawCID, try! VolumeImpl<Block>(node: genesis).rawCID)
    }

    func testBuildBlockPreservesSpec() async throws {
        let genesis = try await genesisBlock()
        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000)
        let block2 = try await nextBlock(previous: block1, timestamp: 3_000_000)
        XCTAssertEqual(genesis.spec.rawCID, block1.spec.rawCID)
        XCTAssertEqual(block1.spec.rawCID, block2.spec.rawCID)
    }

    func testBuildBlockWithDifferentNonceProducesDifferentCID() async throws {
        let genesis = try await genesisBlock()
        let block1a = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 1)
        let block1b = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 2)
        XCTAssertNotEqual(
            try! VolumeImpl<Block>(node: block1a).rawCID,
            try! VolumeImpl<Block>(node: block1b).rawCID
        )
    }

    func testBuildBlockDifficultyHashChangesWithNonce() async throws {
        let genesis = try await genesisBlock()
        let block1a = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 1)
        let block1b = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 2)
        XCTAssertNotEqual(block1a.proofOfWorkHash(), block1b.proofOfWorkHash())
    }

    func testMineFindsValidNonce() async throws {
        let genesis = try await genesisBlock()
        let template = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 0)
        let target = UInt256.max
        let mined = BlockBuilder.mine(block: template, target: target, maxAttempts: 100)
        XCTAssertNotNil(mined)
        let hash = mined!.proofOfWorkHash()
        XCTAssertTrue(target >= hash)
    }

    func testMineReturnsNilWhenImpossible() async throws {
        let genesis = try await genesisBlock()
        let template = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 0)
        let mined = BlockBuilder.mine(block: template, target: UInt256(0), maxAttempts: 100)
        XCTAssertNil(mined)
    }
}

// MARK: - Full Submission Pipeline via BlockBuilder

@MainActor
final class BlockBuilderSubmissionTests: XCTestCase {

    func testBuiltBlocksFormValidChain() async throws {
        let genesis = try await genesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        var prev = genesis
        var ts: Int64 = 2_000_000
        for i in 1...10 {
            let block = try await nextBlock(previous: prev, timestamp: ts, nonce: UInt64(i))
            let header = try! VolumeImpl<Block>(node: block)
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: header,
                block: block
            )
            XCTAssertTrue(result.extendsMainChain, "Block \(i) should extend")
            prev = block
            ts += 1_000
        }

        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 10)
    }

    func testBuiltForkTriggersReorg() async throws {
        let genesis = try await genesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        var mainPrev = genesis
        var ts: Int64 = 2_000_000
        for i in 1...3 {
            let block = try await nextBlock(previous: mainPrev, timestamp: ts, nonce: UInt64(i))
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try! VolumeImpl<Block>(node: block),
                block: block
            )
            mainPrev = block
            ts += 1_000
        }

        let tipBefore = await chain.getMainChainTip()
        let heightBefore = await chain.getHighestBlockHeight()
        XCTAssertEqual(heightBefore, 3)

        var forkPrev = genesis
        ts = 2_000_000
        var sawReorg = false
        for i in 1...5 {
            let block = try await nextBlock(previous: forkPrev, timestamp: ts, nonce: UInt64(100 + i))
            let result = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try! VolumeImpl<Block>(node: block),
                block: block
            )
            if result.reorganization != nil { sawReorg = true }
            forkPrev = block
            ts += 1_000
        }

        XCTAssertTrue(sawReorg, "Longer fork should trigger reorg")
        let tipAfter = await chain.getMainChainTip()
        XCTAssertNotEqual(tipBefore, tipAfter)
        let heightAfter = await chain.getHighestBlockHeight()
        XCTAssertEqual(heightAfter, 5)
    }
}

// MARK: - Signature Verification Tests

@MainActor
final class SignatureVerificationTests: XCTestCase {

    func testValidSignatureVerifies() {
        let keyPair = CryptoUtils.generateKeyPair()
        let message = "test_message_cid"
        let signature = CryptoUtils.sign(message: message, privateKeyHex: keyPair.privateKey)
        XCTAssertNotNil(signature)
        let valid = CryptoUtils.verify(message: message, signature: signature!, publicKeyHex: keyPair.publicKey)
        XCTAssertTrue(valid)
    }

    func testInvalidSignatureRejected() {
        let keyPair = CryptoUtils.generateKeyPair()
        let message = "test_message_cid"
        let valid = CryptoUtils.verify(message: message, signature: "deadbeef", publicKeyHex: keyPair.publicKey)
        XCTAssertFalse(valid)
    }

    func testWrongKeyRejected() {
        let keyPair1 = CryptoUtils.generateKeyPair()
        let keyPair2 = CryptoUtils.generateKeyPair()
        let message = "test_message_cid"
        let signature = CryptoUtils.sign(message: message, privateKeyHex: keyPair1.privateKey)!
        let valid = CryptoUtils.verify(message: message, signature: signature, publicKeyHex: keyPair2.publicKey)
        XCTAssertFalse(valid)
    }

    func testTamperedMessageRejected() {
        let keyPair = CryptoUtils.generateKeyPair()
        let signature = CryptoUtils.sign(message: "original", privateKeyHex: keyPair.privateKey)!
        let valid = CryptoUtils.verify(message: "tampered", signature: signature, publicKeyHex: keyPair.publicKey)
        XCTAssertFalse(valid)
    }

    func testTransactionSignatureMatching() {
        let keyPair = CryptoUtils.generateKeyPair()
        let publicKeyCID = try! HeaderImpl<PublicKey>(node: PublicKey(key: keyPair.publicKey)).rawCID

        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [publicKeyCID],
            fee: 0,
            nonce: 1
        )
        let tx = signedTransaction(body: body, privateKeyHex: keyPair.privateKey, publicKeyHex: keyPair.publicKey)
        XCTAssertTrue(tx.signaturesAreValid())
        XCTAssertTrue(tx.signaturesMatchSigners())
    }

    func testTransactionWrongSignerRejected() {
        let keyPair1 = CryptoUtils.generateKeyPair()
        let keyPair2 = CryptoUtils.generateKeyPair()
        let wrongSignerCID = try! HeaderImpl<PublicKey>(node: PublicKey(key: keyPair2.publicKey)).rawCID

        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [wrongSignerCID],
            fee: 0,
            nonce: 1
        )
        let tx = signedTransaction(body: body, privateKeyHex: keyPair1.privateKey, publicKeyHex: keyPair1.publicKey)
        XCTAssertTrue(tx.signaturesAreValid(), "Signature itself is valid")
        XCTAssertFalse(tx.signaturesMatchSigners(), "But signer doesn't match")
    }
}

// MARK: - Transaction Nonce Scoping Tests

@MainActor
final class TransactionNonceScopingTests: XCTestCase {

    func testSameNonceDifferentSignersProduceDifferentKeys() {
        let body1 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["alice"], fee: 0, nonce: 42
        )
        let body2 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["bob"], fee: 0, nonce: 42
        )

        let key1 = AccountStateHeader.nonceTrackingKey(body1.signers[0])
        let key2 = AccountStateHeader.nonceTrackingKey(body2.signers[0])
        XCTAssertNotEqual(key1, key2, "Different signers should track nonces under distinct keys")
    }

    func testSameSignerSameNonceProducesSameKey() {
        let body1 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["alice"], fee: 0, nonce: 42
        )
        let body2 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["alice"], fee: 0, nonce: 42
        )

        let key1 = AccountStateHeader.nonceTrackingKey(body1.signers[0])
        let key2 = AccountStateHeader.nonceTrackingKey(body2.signers[0])
        XCTAssertEqual(key1, key2, "Same signer should share a nonce-tracking key")
    }

    func testMultipleSignersOrderIndependent() {
        let body1 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["alice", "bob"], fee: 0, nonce: 1
        )
        let body2 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["bob", "alice"], fee: 0, nonce: 1
        )

        let keys1 = Set(body1.signers.map { AccountStateHeader.nonceTrackingKey($0) })
        let keys2 = Set(body2.signers.map { AccountStateHeader.nonceTrackingKey($0) })
        XCTAssertEqual(keys1, keys2, "Signer order should not affect the per-account nonce key set")
    }
}

// MARK: - Balance Validation Tests

@MainActor
final class BalanceValidationTests: XCTestCase {

    func testEmptyBlockBuildsCorrectState() async throws {
        let genesis = try await genesisBlock()
        XCTAssertEqual(genesis.prevState.rawCID, genesis.postState.rawCID,
            "Empty genesis should not change state")

        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000)
        XCTAssertEqual(block1.prevState.rawCID, block1.postState.rawCID,
            "Empty block should not change state")
    }

    func testChainOfEmptyBlocksMaintainsStateInvariant() async throws {
        let genesis = try await genesisBlock()
        var prev = genesis
        var ts: Int64 = 2_000_000
        for _ in 1...5 {
            let block = try await nextBlock(previous: prev, timestamp: ts)
            XCTAssertEqual(block.prevState.rawCID, prev.postState.rawCID,
                "prevState must equal previous postState")
            XCTAssertEqual(block.prevState.rawCID, block.postState.rawCID,
                "Empty block should not change state")
            prev = block
            ts += 1_000
        }
    }
}

// MARK: - Key Parsing Safety Tests

@MainActor
final class KeyParsingSafetyTests: XCTestCase {

    func testSwapKeyRoundTrip() {
        let original = DepositKey(depositAction: DepositAction(nonce: 42, demander: "demander1", amountDemanded: 1000, amountDeposited: 1000))
        let serialized = original.description
        let parsed = DepositKey(serialized)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.nonce, 42)
        XCTAssertEqual(parsed?.demander, "demander1")
        XCTAssertEqual(parsed?.amountDemanded, 1000)
    }

    func testSwapKeyMalformedReturnsNil() {
        XCTAssertNil(DepositKey(""))
        XCTAssertNil(DepositKey("onlyone"))
        XCTAssertNil(DepositKey("two/parts"))
    }

    func testSettleKeyRoundTrip() {
        let receiptAction = ReceiptAction(withdrawer: "w1", nonce: 99, demander: "d1", amountDemanded: 500, directory: "chain1")
        let original = ReceiptKey(receiptAction: receiptAction)
        let serialized = original.description
        let parsed = ReceiptKey(serialized)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.directory, "chain1")
        XCTAssertEqual(parsed?.demander, "d1")
        XCTAssertEqual(parsed?.amountDemanded, 500)
        XCTAssertEqual(parsed?.nonce, 99)
    }

    func testSettleKeyMalformedReturnsNil() {
        XCTAssertNil(ReceiptKey(""))
        XCTAssertNil(ReceiptKey("nodirectory"))
        XCTAssertNil(ReceiptKey("dir/demander"))
        XCTAssertNil(ReceiptKey("dir/demander/notanumber"))
    }
}

// MARK: - Address and Hashing Tests

@MainActor
final class CryptoUtilsTests: XCTestCase {

    func testSha256IsDeterministic() {
        let hash1 = CryptoUtils.sha256("hello")
        let hash2 = CryptoUtils.sha256("hello")
        XCTAssertEqual(hash1, hash2)
    }

    func testSha256ProducesNonEmptyOutput() {
        let hash = CryptoUtils.sha256("hello")
        XCTAssertFalse(hash.isEmpty)
        XCTAssertNotEqual(hash, "hello")
    }

    func testCreateAddressIsDeterministic() {
        let keyPair = CryptoUtils.generateKeyPair()
        let addr1 = CryptoUtils.createAddress(from: keyPair.publicKey)
        let addr2 = CryptoUtils.createAddress(from: keyPair.publicKey)
        XCTAssertEqual(addr1, addr2)
    }

    func testCreateAddressIsNonEmpty() {
        let keyPair = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: keyPair.publicKey)
        XCTAssertFalse(addr.isEmpty)
    }

    func testDifferentKeysDifferentAddresses() {
        let kp1 = CryptoUtils.generateKeyPair()
        let kp2 = CryptoUtils.generateKeyPair()
        let addr1 = CryptoUtils.createAddress(from: kp1.publicKey)
        let addr2 = CryptoUtils.createAddress(from: kp2.publicKey)
        XCTAssertNotEqual(addr1, addr2)
    }

    func testKeyPairGeneration() {
        let kp = CryptoUtils.generateKeyPair()
        XCTAssertFalse(kp.privateKey.isEmpty)
        XCTAssertFalse(kp.publicKey.isEmpty)
        XCTAssertNotEqual(kp.privateKey, kp.publicKey)
    }
}

// MARK: - Missing Block Tracking Tests

@MainActor
final class MissingBlockTrackingTests: XCTestCase {

    func testNoMissingBlocksInitially() async {
        let (chain, _) = makeLinearChain(length: 3)
        let missing = await chain.getMissingBlockHashes()
        XCTAssertTrue(missing.isEmpty)
    }

    func testMissingParentIsTracked() async throws {
        let genesis = try await genesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 1)
        let block2 = try await nextBlock(previous: block1, timestamp: 3_000_000, nonce: 2)

        let result = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try! VolumeImpl<Block>(node: block2),
            block: block2
        )
        XCTAssertTrue(result.needsChildBlock, "Block with missing parent should flag needsChildBlock")

        let missing = await chain.getMissingBlockHashes()
        let block1Hash = try! VolumeImpl<Block>(node: block1).rawCID
        XCTAssertTrue(missing.contains(block1Hash), "Missing parent should be tracked")
    }

    func testMissingBlockResolvedWhenParentArrives() async throws {
        let genesis = try await genesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 1)
        let block2 = try await nextBlock(previous: block1, timestamp: 3_000_000, nonce: 2)

        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try! VolumeImpl<Block>(node: block2),
            block: block2
        )

        let missingBefore = await chain.getMissingBlockHashes()
        XCTAssertFalse(missingBefore.isEmpty)

        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try! VolumeImpl<Block>(node: block1),
            block: block1
        )

        let missingAfter = await chain.getMissingBlockHashes()
        let block1Hash = try! VolumeImpl<Block>(node: block1).rawCID
        XCTAssertFalse(missingAfter.contains(block1Hash), "Should be resolved after parent arrives")
    }
}

// MARK: - WASM Policy Tests

@MainActor
final class WasmPolicyTests: XCTestCase {

    func testWasmPolicyExecutionProfileIsPinned() throws {
        XCTAssertEqual(WasmPolicyEvaluator.executionFeatureSet, [.referenceTypes])
        XCTAssertFalse(WasmPolicyEvaluator.executionFeatureSet.contains(.memory64))
        XCTAssertFalse(WasmPolicyEvaluator.executionFeatureSet.contains(.threads))
        XCTAssertFalse(WasmPolicyEvaluator.executionFeatureSet.contains(.tailCall))

        let memory64Module = Data([
            0x00, 0x61, 0x73, 0x6d, // magic
            0x01, 0x00, 0x00, 0x00, // version
            0x05, 0x03,             // memory section, 3-byte payload
            0x01,                   // one memory
            0x04,                   // memory64 limits, no maximum
            0x01                    // min pages
        ])
        let policy = WasmPolicyRef(moduleCID: "memory64", scope: .transaction)

        XCTAssertThrowsError(try WasmPolicyEvaluator.validate(
            policy: policy,
            moduleBytes: memory64Module
        ))
    }

    func testTransactionPolicyAccepts() async throws {
        let fetcher = StorableFetcher()
        let policy = try storeWasmPolicy(accepts: true, scope: .transaction, fetcher: fetcher)
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], fee: 100, nonce: 1
        )
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            wasmPolicies: [policy]
        )
        let accepted = await TransactionBody.batchVerifyPolicies(bodies: [body], spec: spec, chainPath: ["Nexus"], fetcher: fetcher)
        XCTAssertTrue(accepted)
    }

    func testTransactionPolicyRejects() async throws {
        let fetcher = StorableFetcher()
        let policy = try storeWasmPolicy(accepts: false, scope: .transaction, fetcher: fetcher)
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], fee: 100, nonce: 1
        )
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            wasmPolicies: [policy]
        )
        let accepted = await TransactionBody.batchVerifyPolicies(bodies: [body], spec: spec, chainPath: ["Nexus"], fetcher: fetcher)
        XCTAssertFalse(accepted)
    }

    func testTransactionPolicyCanInspectContextBytes() async throws {
        let fetcher = StorableFetcher()
        let policy = try storeWasmPolicy(requiringSubstring: "high-signer", scope: .transaction, fetcher: fetcher)
        let lowFee = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["low-signer"], fee: 5, nonce: 1
        )
        let highFee = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["high-signer"], fee: 100, nonce: 1
        )
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            wasmPolicies: [policy]
        )
        let lowAccepted = await TransactionBody.batchVerifyPolicies(bodies: [lowFee], spec: spec, chainPath: ["Nexus"], fetcher: fetcher)
        let highAccepted = await TransactionBody.batchVerifyPolicies(bodies: [highFee], spec: spec, chainPath: ["Nexus"], fetcher: fetcher)
        XCTAssertFalse(lowAccepted)
        XCTAssertTrue(highAccepted)
    }

    func testTransactionPolicyCanInspectChainPath() async throws {
        let fetcher = StorableFetcher()
        let policy = try storeWasmPolicy(requiringSubstring: "policy-chain-sentinel", scope: .transaction, fetcher: fetcher)
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], fee: 100, nonce: 1
        )
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            wasmPolicies: [policy]
        )
        let acceptedOnMatchingPath = await TransactionBody.batchVerifyPolicies(
            bodies: [body], spec: spec, chainPath: ["Nexus", "policy-chain-sentinel"], fetcher: fetcher
        )
        let rejectedOnDifferentPath = await TransactionBody.batchVerifyPolicies(
            bodies: [body], spec: spec, chainPath: ["Nexus", "other-chain"], fetcher: fetcher
        )
        XCTAssertTrue(acceptedOnMatchingPath)
        XCTAssertFalse(rejectedOnDifferentPath)
    }

    func testMultiplePoliciesAreAllRequired() async throws {
        let fetcher = StorableFetcher()
        let acceptingPolicy = try storeWasmPolicy(accepts: true, scope: .transaction, fetcher: fetcher)
        let rejectingPolicy = try storeWasmPolicy(accepts: false, scope: .transaction, fetcher: fetcher)
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], fee: 100, nonce: 1
        )
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            wasmPolicies: [acceptingPolicy, rejectingPolicy]
        )
        let accepted = await TransactionBody.batchVerifyPolicies(bodies: [body], spec: spec, chainPath: ["Nexus"], fetcher: fetcher)
        XCTAssertFalse(accepted)
    }

    func testPolicyContextCanonicalEncodingGolden() throws {
        let policy = WasmPolicyRef(moduleCID: "bafy-policy", scope: .transaction)
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            wasmPolicies: [policy]
        )
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(key: "app/v1/data", oldValue: nil, newValue: "value")],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: ["alice"],
            fee: 7,
            nonce: 9,
            chainPath: ["Nexus"]
        )
        let context = WasmPolicyContext(
            scope: .transaction,
            chainSpec: spec,
            chainPath: ["Nexus"],
            transaction: body,
            action: nil,
            actionIndex: nil
        )
        let hex = try context.canonicalData().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "4c5750435458000100010000000106a9677072656d696e65006c6d6178426c6f636b53697a651a000f42406c7761736d506f6c696369657381a46573636f70656b7472616e73616374696f6e696d6f64756c654349446b626166792d706f6c6963796a61626956657273696f6e016a656e747279706f696e74781c6c6174746963655f76616c69646174655f7472616e73616374696f6e6d696e697469616c5265776172641904006e6d6178537461746547726f7774681a000186a06e726574617267657457696e646f770a6f68616c76696e67496e74657276616c1927106f746172676574426c6f636b54696d651903e8781f6d61784e756d6265724f665472616e73616374696f6e73506572426c6f636b186400000001000000054e6578757301000000a9aa6366656507656e6f6e63650967616374696f6e7381a2636b65796b6170702f76312f64617461686e657756616c75656576616c7565677369676e6572738165616c69636569636861696e5061746881654e657875736e6163636f756e74416374696f6e73806e6465706f736974416374696f6e73806e67656e65736973416374696f6e73806e72656365697074416374696f6e7380717769746864726177616c416374696f6e73800000")

        let actionContext = WasmPolicyContext(
            scope: .action,
            chainSpec: spec,
            chainPath: ["Nexus"],
            transaction: body,
            action: body.actions[0],
            actionIndex: 0
        )
        let actionHex = try actionContext.canonicalData().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actionHex, "4c5750435458000100010100000106a9677072656d696e65006c6d6178426c6f636b53697a651a000f42406c7761736d506f6c696369657381a46573636f70656b7472616e73616374696f6e696d6f64756c654349446b626166792d706f6c6963796a61626956657273696f6e016a656e747279706f696e74781c6c6174746963655f76616c69646174655f7472616e73616374696f6e6d696e697469616c5265776172641904006e6d6178537461746547726f7774681a000186a06e726574617267657457696e646f770a6f68616c76696e67496e74657276616c1927106f746172676574426c6f636b54696d651903e8781f6d61784e756d6265724f665472616e73616374696f6e73506572426c6f636b186400000001000000054e6578757301000000a9aa6366656507656e6f6e63650967616374696f6e7381a2636b65796b6170702f76312f64617461686e657756616c75656576616c7565677369676e6572738165616c69636569636861696e5061746881654e657875736e6163636f756e74416374696f6e73806e6465706f736974416374696f6e73806e67656e65736973416374696f6e73806e72656365697074416374696f6e7380717769746864726177616c416374696f6e73800100000020a2636b65796b6170702f76312f64617461686e657756616c75656576616c7565010000000000000000")
    }

    func testActionPolicyAccepts() async throws {
        let fetcher = StorableFetcher()
        let policy = try storeWasmPolicy(accepts: true, scope: .action, fetcher: fetcher)
        let action = Action(key: "test/key", oldValue: nil, newValue: "hello")
        let body = TransactionBody(
            accountActions: [], actions: [action], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], fee: 0, nonce: 1
        )
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            wasmPolicies: [policy]
        )
        let accepted = await TransactionBody.batchVerifyPolicies(bodies: [body], spec: spec, chainPath: ["Nexus"], fetcher: fetcher)
        XCTAssertTrue(accepted)
    }

    func testActionPolicyCanInspectContextBytes() async throws {
        let fetcher = StorableFetcher()
        let policy = try storeWasmPolicy(requiringSubstring: "app", scope: .action, fetcher: fetcher)
        let goodAction = Action(key: "app/v1/data", oldValue: nil, newValue: "value")
        let badAction = Action(key: "forbidden/data", oldValue: nil, newValue: "value")
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            wasmPolicies: [policy]
        )
        let goodBody = TransactionBody(accountActions: [], actions: [goodAction], depositActions: [], genesisActions: [], receiptActions: [], withdrawalActions: [], signers: [], fee: 1, nonce: 1)
        let badBody = TransactionBody(accountActions: [], actions: [badAction], depositActions: [], genesisActions: [], receiptActions: [], withdrawalActions: [], signers: [], fee: 1, nonce: 1)
        let goodAccepted = await TransactionBody.batchVerifyPolicies(bodies: [goodBody], spec: spec, chainPath: ["Nexus"], fetcher: fetcher)
        let badAccepted = await TransactionBody.batchVerifyPolicies(bodies: [badBody], spec: spec, chainPath: ["Nexus"], fetcher: fetcher)
        XCTAssertTrue(goodAccepted)
        XCTAssertFalse(badAccepted)
    }

    func testUnsupportedAbiRejects() async throws {
        let fetcher = StorableFetcher()
        let storedPolicy = try storeWasmPolicy(accepts: true, scope: .transaction, fetcher: fetcher)
        let policy = WasmPolicyRef(
            moduleCID: storedPolicy.moduleCID,
            abiVersion: WasmPolicyRef.currentABIVersion + 1,
            scope: .transaction
        )
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], fee: 100, nonce: 1
        )
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            wasmPolicies: [policy]
        )
        let accepted = await TransactionBody.batchVerifyPolicies(bodies: [body], spec: spec, chainPath: ["Nexus"], fetcher: fetcher)
        XCTAssertFalse(accepted)

        XCTAssertThrowsError(try WasmPolicyEvaluator.validate(
            policy: policy,
            moduleBytes: try wasmPolicyFixture(accepts: true)
        )) { error in
            guard case WasmPolicyError.unsupportedABI(WasmPolicyRef.currentABIVersion + 1) = error else {
                XCTFail("Expected unsupported ABI rejection, got \(error)")
                return
            }
        }
    }

    func testCustomEntrypointAccepts() async throws {
        let fetcher = StorableFetcher()
        let wat = """
        (module
          (memory (export "memory") 1)
          (global $heap (mut i32) (i32.const 1024))
          (func (export "lattice_alloc") (param $len i32) (result i32)
            (local $ptr i32)
            global.get $heap
            local.set $ptr
            global.get $heap
            local.get $len
            i32.add
            global.set $heap
            local.get $ptr)
          (func (export "custom_policy_entrypoint") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """
        let module = try! WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: Data(try wat2wasm(wat))))
        try module.storeRecursively(storer: fetcher)
        let policy = WasmPolicyRef(
            moduleCID: module.rawCID,
            scope: .transaction,
            entrypoint: "custom_policy_entrypoint"
        )
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], fee: 100, nonce: 1
        )
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            wasmPolicies: [policy]
        )
        let accepted = await TransactionBody.batchVerifyPolicies(bodies: [body], spec: spec, chainPath: ["Nexus"], fetcher: fetcher)
        XCTAssertTrue(accepted)
    }

    func testMissingPolicyModuleRejects() async throws {
        let fetcher = StorableFetcher()
        let policy = WasmPolicyRef(moduleCID: "missing", scope: .transaction)
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            wasmPolicies: [policy]
        )
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [], signers: [], fee: 5, nonce: 1
        )
        let accepted = await TransactionBody.batchVerifyPolicies(bodies: [body], spec: spec, chainPath: ["Nexus"], fetcher: fetcher)
        XCTAssertFalse(accepted)
    }

    func testInvalidAllocatorRejectsWithoutWritingOutOfBounds() throws {
        let wat = """
        (module
          (memory (export "memory") 1)
          (func (export "lattice_alloc") (param $len i32) (result i32)
            i32.const 70000)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        XCTAssertThrowsError(try WasmPolicyEvaluator.evaluate(
            policy: policy,
            contextData: Data(#"{"fee":100}"#.utf8),
            moduleBytes: Data(try wat2wasm(wat))
        )) { error in
            XCTAssertTrue(error is WasmPolicyError)
        }
    }

    func testNegativeAllocatorPointerRejectsWithoutTrapping() throws {
        let wat = """
        (module
          (memory (export "memory") 1)
          (func (export "lattice_alloc") (param $len i32) (result i32)
            i32.const -1)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        XCTAssertThrowsError(try WasmPolicyEvaluator.evaluate(
            policy: policy,
            contextData: Data(#"{"fee":100}"#.utf8),
            moduleBytes: Data(try wat2wasm(wat))
        )) { error in
            guard case WasmPolicyError.invalidAllocation = error else {
                XCTFail("Expected invalidAllocation, got \(error)")
                return
            }
        }
    }

    func testAllocatorPointerDomainFailsClosedWithoutTrapping() throws {
        struct AllocCase {
            let name: String
            let pointer: String
            let contextSize: Int
            let accepts: Bool
        }

        let pageBytes = 64 * 1024
        let cases = [
            AllocCase(name: "zero", pointer: "0", contextSize: 16, accepts: true),
            AllocCase(name: "last_valid_range", pointer: "\(pageBytes - 16)", contextSize: 16, accepts: true),
            AllocCase(name: "one_past_last_valid_range", pointer: "\(pageBytes - 15)", contextSize: 16, accepts: false),
            AllocCase(name: "end_of_memory_empty_context", pointer: "\(pageBytes)", contextSize: 0, accepts: true),
            AllocCase(name: "end_of_memory_nonempty_context", pointer: "\(pageBytes)", contextSize: 1, accepts: false),
            AllocCase(name: "negative_one", pointer: "-1", contextSize: 16, accepts: false),
            AllocCase(name: "int32_min", pointer: "-2147483648", contextSize: 16, accepts: false),
            AllocCase(name: "near_int32_max", pointer: "2147483640", contextSize: 16, accepts: false),
            AllocCase(name: "int32_max", pointer: "2147483647", contextSize: 16, accepts: false),
        ]
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)

        for testCase in cases {
            let moduleBytes = try allocatorFixture(pointer: testCase.pointer, memoryPages: 1)
            let context = Data(repeating: 0x41, count: testCase.contextSize)

            if testCase.accepts {
                XCTAssertTrue(try WasmPolicyEvaluator.evaluate(
                    policy: policy,
                    contextData: context,
                    moduleBytes: moduleBytes
                ), testCase.name)
            } else {
                XCTAssertThrowsError(try WasmPolicyEvaluator.evaluate(
                    policy: policy,
                    contextData: context,
                    moduleBytes: moduleBytes
                ), testCase.name) { error in
                    guard case WasmPolicyError.invalidAllocation = error else {
                        XCTFail("Expected invalidAllocation for \(testCase.name), got \(error)")
                        return
                    }
                }
            }
        }
    }

    func testEmptyContextWithZeroPageMemoryDoesNotForceUnwrapBaseAddress() throws {
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        let moduleBytes = try allocatorFixture(pointer: "0", memoryPages: 0)

        XCTAssertTrue(try WasmPolicyEvaluator.evaluate(
            policy: policy,
            contextData: Data(),
            moduleBytes: moduleBytes
        ))
    }

    func testOversizedPolicyContextRejectsBeforeAllocatorCall() throws {
        let wat = """
        (module
          (memory (export "memory") 1)
          (func (export "lattice_alloc") (param $len i32) (result i32)
            unreachable)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        let oversizedContext = Data(repeating: 0, count: WasmPolicyEvaluator.maxMemoryBytes + 1)
        XCTAssertThrowsError(try WasmPolicyEvaluator.evaluate(
            policy: policy,
            contextData: oversizedContext,
            moduleBytes: Data(try wat2wasm(wat))
        )) { error in
            guard case WasmPolicyError.invalidAllocation = error else {
                XCTFail("Expected invalidAllocation, got \(error)")
                return
            }
        }
    }

    private func allocatorFixture(pointer: String, memoryPages: Int) throws -> Data {
        let wat = """
        (module
          (memory (export "memory") \(memoryPages))
          (func (export "lattice_alloc") (param $len i32) (result i32)
            i32.const \(pointer))
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """
        return Data(try wat2wasm(wat))
    }

    func testPolicyPreflightRejectsWrongEntrypointSignature() throws {
        let wat = """
        (module
          (memory (export "memory") 1)
          (func (export "lattice_alloc") (param $len i32) (result i32)
            i32.const 1024)
          (func (export "lattice_validate_transaction") (param $ptr i32) (result i32)
            i32.const 1)
        )
        """
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        XCTAssertThrowsError(try WasmPolicyEvaluator.validate(
            policy: policy,
            moduleBytes: Data(try wat2wasm(wat))
        )) { error in
            guard case WasmPolicyError.invalidFunctionSignature("lattice_validate_transaction") = error else {
                XCTFail("Expected invalid entrypoint signature, got \(error)")
                return
            }
        }
    }

    func testPolicyPreflightRejectsOversizedModule() throws {
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        let oversized = Data(repeating: 0, count: WasmPolicyEvaluator.maxModuleBytes + 1)
        XCTAssertThrowsError(try WasmPolicyEvaluator.validate(
            policy: policy,
            moduleBytes: oversized
        )) { error in
            guard case WasmPolicyError.moduleTooLarge(WasmPolicyEvaluator.maxModuleBytes + 1) = error else {
                XCTFail("Expected oversized module rejection, got \(error)")
                return
            }
        }
    }

    func testPolicyPreflightRejectsExcessInitialMemory() throws {
        let excessivePages = WasmPolicyEvaluator.maxMemoryBytes / (64 * 1024) + 1
        let wat = """
        (module
          (memory (export "memory") \(excessivePages))
          (func (export "lattice_alloc") (param $len i32) (result i32)
            i32.const 1024)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        XCTAssertThrowsError(try WasmPolicyEvaluator.validate(
            policy: policy,
            moduleBytes: Data(try wat2wasm(wat))
        ))
    }

    // MARK: - compiled-module cache

    private func cacheTestSpec(policy: WasmPolicyRef) -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            wasmPolicies: [policy]
        )
    }

    private func cacheTestContext(policy: WasmPolicyRef) -> WasmPolicyContext {
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], fee: 100, nonce: 1
        )
        return WasmPolicyContext(
            scope: .transaction,
            chainSpec: cacheTestSpec(policy: policy),
            chainPath: ["Nexus"],
            transaction: body,
            action: nil,
            actionIndex: nil
        )
    }

    /// RED on cold parse-every-time code: the same module is parsed exactly once
    /// across N evaluations through the real `WasmPolicyEvaluator.evaluate` path.
    func test_compiledModuleCache_parsesOncePerModuleAcrossEvaluations() async throws {
        let cache = WasmPolicyEvaluator.moduleCache
        cache.removeAll()
        defer { cache.onParse = nil; cache.removeAll() }

        var parseCount = 0
        cache.onParse = { _ in parseCount += 1 }

        let fetcher = StorableFetcher()
        let policy = try storeWasmPolicy(accepts: true, scope: .transaction, fetcher: fetcher)
        let context = cacheTestContext(policy: policy)

        for _ in 0..<4 {
            let verdict = try await WasmPolicyEvaluator.evaluate(policy: policy, context: context, fetcher: fetcher)
            XCTAssertTrue(verdict)
        }

        XCTAssertEqual(parseCount, 1, "module must be parsed exactly once across evaluations (cache hit on 2..N)")
    }

    /// A cache hit (warm) produces a byte-identical verdict to a cold parse.
    func test_cacheHitProducesIdenticalVerdict() async throws {
        let cache = WasmPolicyEvaluator.moduleCache
        defer { cache.onParse = nil; cache.removeAll() }

        for accepts in [true, false] {
            let fetcher = StorableFetcher()
            let policy = try storeWasmPolicy(accepts: accepts, scope: .transaction, fetcher: fetcher)
            let context = cacheTestContext(policy: policy)

            cache.removeAll() // force a cold parse
            let cold = try await WasmPolicyEvaluator.evaluate(policy: policy, context: context, fetcher: fetcher)
            // second call is a guaranteed cache hit (warm)
            let warm = try await WasmPolicyEvaluator.evaluate(policy: policy, context: context, fetcher: fetcher)

            XCTAssertEqual(cold, accepts)
            XCTAssertEqual(cold, warm, "warm cache-hit verdict must equal cold-parse verdict")
        }
    }

    /// With the count bound shrunk via the test seam, inserting >bound distinct
    /// modules evicts the least-recently-used module, which is then re-parsed.
    func test_cacheEvictsLRUAtBound() async throws {
        let cache = WasmPolicyEvaluator.moduleCache
        cache.removeAll()
        cache.setMaxModuleCount(2)
        defer {
            cache.onParse = nil
            cache.removeAll()
            cache.setMaxModuleCount(WasmModuleCache.defaultMaxModuleCount)
        }

        var parsedKeys: [String] = []
        cache.onParse = { parsedKeys.append($0) }

        let fetcher = StorableFetcher()
        // Three distinct modules (distinct content ids via distinct sentinel substrings).
        let policyA = try storeWasmPolicy(requiringSubstring: "module-a", scope: .transaction, fetcher: fetcher)
        let policyB = try storeWasmPolicy(requiringSubstring: "module-b", scope: .transaction, fetcher: fetcher)
        let policyC = try storeWasmPolicy(requiringSubstring: "module-c", scope: .transaction, fetcher: fetcher)
        let ctxA = cacheTestContext(policy: policyA)
        let ctxB = cacheTestContext(policy: policyB)
        let ctxC = cacheTestContext(policy: policyC)

        // Fill cache with A, B (bound = 2). A is now LRU.
        _ = try await WasmPolicyEvaluator.evaluate(policy: policyA, context: ctxA, fetcher: fetcher)
        _ = try await WasmPolicyEvaluator.evaluate(policy: policyB, context: ctxB, fetcher: fetcher)
        XCTAssertEqual(parsedKeys.count, 2)

        // Insert C → evicts A (LRU).
        _ = try await WasmPolicyEvaluator.evaluate(policy: policyC, context: ctxC, fetcher: fetcher)
        XCTAssertEqual(parsedKeys.count, 3)

        // B and C are warm (no re-parse).
        _ = try await WasmPolicyEvaluator.evaluate(policy: policyB, context: ctxB, fetcher: fetcher)
        _ = try await WasmPolicyEvaluator.evaluate(policy: policyC, context: ctxC, fetcher: fetcher)
        XCTAssertEqual(parsedKeys.count, 3, "B and C must be cache hits after C insertion")

        // A was evicted → re-parsed.
        _ = try await WasmPolicyEvaluator.evaluate(policy: policyA, context: ctxA, fetcher: fetcher)
        XCTAssertEqual(parsedKeys.count, 4, "evicted LRU module A must be re-parsed")
        XCTAssertEqual(parsedKeys.last, policyA.moduleCID)
    }
}
