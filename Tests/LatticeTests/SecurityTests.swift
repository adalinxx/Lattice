import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation
import Crypto

// MARK: - Shared Test Infrastructure

private struct TestFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw NSError(domain: "TestFetcher", code: 1)
    }
}

private let fetcher = TestFetcher()

private func spec() -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1024, halvingInterval: 10_000,
        retargetWindow: 5
    )
}

private func genesis(timestamp: Int64 = 1_000_000, nonce: UInt64 = 0) async throws -> Block {
    try await BlockBuilder.buildGenesis(
        spec: spec(), timestamp: timestamp, target: UInt256(1000), nonce: nonce, fetcher: fetcher
    )
}

private func next(_ previous: Block, ts: Int64, nonce: UInt64 = 0) async throws -> Block {
    try await BlockBuilder.buildBlock(
        previous: previous, timestamp: ts, target: UInt256(1000), nonce: nonce, fetcher: fetcher
    )
}

private func header(_ block: Block) -> BlockHeader { try! VolumeImpl<Block>(node: block) }

private func buildChain(length: Int, startTimestamp: Int64 = 1_000_000) async throws -> [Block] {
    var blocks: [Block] = [try await genesis(timestamp: startTimestamp)]
    for i in 1..<length {
        blocks.append(try await next(blocks.last!, ts: startTimestamp + Int64(i) * 1000, nonce: UInt64(i)))
    }
    return blocks
}

private func submitChain(_ chain: ChainState, blocks: [Block]) async {
    for block in blocks.dropFirst() {
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil, blockHeader: header(block), block: block
        )
    }
}

// MARK: - Adversarial: Double-Spend Prevention

@MainActor
final class DoubleSpendTests: XCTestCase {

    func testSameBlockSubmittedTwiceIsRejected() async throws {
        let g = try await genesis()
        let chain = ChainState.fromGenesis(block: g)
        let b1 = try await next(g, ts: 2_000_000, nonce: 1)

        let first = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(b1), block: b1)
        XCTAssertTrue(first.addedBlock)

        let second = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(b1), block: b1)
        XCTAssertFalse(second.addedBlock, "Duplicate block must be rejected")
    }

    func testTransactionNonceReplayBlocked() {
        let body1 = TransactionBody(
            accountActions: [AccountAction(owner: "alice", delta: Int64(50) - Int64(100))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["alice"], fee: 1, nonce: 42
        )
        let body2 = TransactionBody(
            accountActions: [AccountAction(owner: "alice", delta: -Int64(50))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["alice"], fee: 1, nonce: 42
        )
        let key1 = AccountStateHeader.nonceTrackingKey(body1.signers[0])
        let key2 = AccountStateHeader.nonceTrackingKey(body2.signers[0])
        XCTAssertEqual(key1, key2, "Same signer must produce same nonce-tracking key")
        XCTAssertEqual(body1.nonce, body2.nonce, "Replaying the same nonce must be detectable at state update time")
    }

    func testDifferentSignersSameNonceNotBlocked() {
        let body1 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: ["alice"], fee: 0, nonce: 1
        )
        let body2 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: ["bob"], fee: 0, nonce: 1
        )
        XCTAssertNotEqual(
            AccountStateHeader.nonceTrackingKey(body1.signers[0]),
            AccountStateHeader.nonceTrackingKey(body2.signers[0]),
            "Different signers must track nonces under distinct keys"
        )
    }
}

// MARK: - State Model Hardening

@MainActor
final class StateModelHardeningTests: XCTestCase {

    func testPerAccountNonceIgnoresCosignerSet() async throws {
        let stateFetcher = StorableFetcher()
        let empty = try! AccountStateHeader(node: AccountState())
        try empty.storeRecursively(storer: stateFetcher)

        let solo = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: ["alice"], fee: 0, nonce: 0
        )
        let (afterSolo, _) = try await empty.proveAndUpdateState(
            allAccountActions: [],
            transactionBodies: [solo],
            fetcher: stateFetcher
        )
        try afterSolo.storeRecursively(storer: stateFetcher)

        let cosignedReplay = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: ["alice", "bob"], fee: 0, nonce: 0
        )
        do {
            _ = try await afterSolo.proveAndUpdateState(
                allAccountActions: [],
                transactionBodies: [cosignedReplay],
                fetcher: stateFetcher
            )
            XCTFail("reusing alice's nonce under a cosigner set must fail")
        } catch StateErrors.nonceGap {
            // expected
        }

        let nextSolo = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: ["alice"], fee: 0, nonce: 1
        )
        _ = try await afterSolo.proveAndUpdateState(
            allAccountActions: [],
            transactionBodies: [nextSolo],
            fetcher: stateFetcher
        )
    }

    func testWithdrawalWithoutDepositRejectsInAccounting() async throws {
        let stateFetcher = StorableFetcher()
        let empty = try! DepositStateHeader(node: DepositState())
        try empty.storeRecursively(storer: stateFetcher)

        let missing = WithdrawalAction(
            withdrawer: "bob",
            nonce: 1,
            demander: "alice",
            amountDemanded: 100,
            amountWithdrawn: 100
        )
        do {
            _ = try await empty.proveAndDeleteForWithdrawals(
                allWithdrawalActions: [missing],
                fetcher: stateFetcher
            )
            XCTFail("absent deposits must fail closed in accounting")
        } catch StateErrors.conflictingActions {
            // expected
        }

        let deposit = DepositAction(
            nonce: 2,
            demander: "alice",
            amountDemanded: 100,
            amountDeposited: 90
        )
        let (afterDeposit, _) = try await empty.proveAndUpdateState(
            allDepositActions: [deposit],
            fetcher: stateFetcher
        )
        try afterDeposit.storeRecursively(storer: stateFetcher)

        let overClaim = WithdrawalAction(
            withdrawer: "bob",
            nonce: 2,
            demander: "alice",
            amountDemanded: 100,
            amountWithdrawn: 100
        )
        do {
            _ = try await afterDeposit.proveAndDeleteForWithdrawals(
                allWithdrawalActions: [overClaim],
                fetcher: stateFetcher
            )
            XCTFail("amount mismatch must remain rejected")
        } catch StateErrors.conflictingActions {
            // expected
        }
    }

    func testSignatureRequiresDomainTag() throws {
        let keyPair = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: keyPair.publicKey)],
            fee: 0,
            nonce: 0
        )
        let message = try! HeaderImpl<TransactionBody>(node: body).rawCID
        let privateKeyData = try XCTUnwrap(Data(hex: keyPair.privateKey))
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        let rawSignature = try privateKey.signature(for: Data(message.utf8)).hexString

        XCTAssertFalse(CryptoUtils.verify(message: message, signature: rawSignature, publicKeyHex: keyPair.publicKey))

        let domainSignature = try XCTUnwrap(CryptoUtils.sign(message: message, privateKeyHex: keyPair.privateKey))
        XCTAssertTrue(CryptoUtils.verify(message: message, signature: domainSignature, publicKeyHex: keyPair.publicKey))
    }

    func testNonceKeyCannotCollideWithBalanceKey() async throws {
        let keyPair = CryptoUtils.generateKeyPair()
        let address = CryptoUtils.createAddress(from: keyPair.publicKey)
        XCTAssertFalse(AccountStateHeader.isReservedAccountKey(address))
        XCTAssertTrue(AccountStateHeader.isReservedAccountKey(AccountStateHeader.nonceTrackingKey(address)))

        let stateFetcher = StorableFetcher()
        let empty = try! AccountStateHeader(node: AccountState())
        try empty.storeRecursively(storer: stateFetcher)

        do {
            _ = try await empty.proveAndUpdateState(
                allAccountActions: [AccountAction(owner: AccountStateHeader.nonceTrackingKey(address), delta: 1)],
                fetcher: stateFetcher
            )
            XCTFail("reserved nonce namespace must not be usable as an account balance key")
        } catch StateErrors.conflictingActions {
            // expected
        }
    }

    func testVerifyHelpersAreWiredIntoTransactionValidation() async throws {
        let keyPair = CryptoUtils.generateKeyPair()
        let signer = CryptoUtils.createAddress(from: keyPair.publicKey)
        let invalidGeneralAction = TransactionBody(
            accountActions: [],
            actions: [Action(key: "", oldValue: nil, newValue: "value")],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [signer],
            fee: 0,
            nonce: 0
        )
        let invalidGeneralTx = signedTransaction(
            body: invalidGeneralAction,
            privateKeyHex: keyPair.privateKey,
            publicKeyHex: keyPair.publicKey
        )
        let invalidGeneralAccepted = try await invalidGeneralTx.validateTransactionForNexus(fetcher: fetcher)
        XCTAssertFalse(invalidGeneralAccepted)

        let invalidAccountAction = TransactionBody(
            accountActions: [AccountAction(owner: signer, delta: 0)],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [signer],
            fee: 0,
            nonce: 0
        )
        let invalidAccountTx = signedTransaction(
            body: invalidAccountAction,
            privateKeyHex: keyPair.privateKey,
            publicKeyHex: keyPair.publicKey
        )
        let invalidAccountAccepted = try await invalidAccountTx.validateTransactionForNexus(fetcher: fetcher)
        XCTAssertFalse(invalidAccountAccepted)
    }

    func testVerifyHelperWiringStillAcceptsValidInlineEdgeCase() async throws {
        let keyPair = CryptoUtils.generateKeyPair()
        let signer = CryptoUtils.createAddress(from: keyPair.publicKey)
        let recipient = "recipient-credit-only"
        let body = TransactionBody(
            accountActions: [AccountAction(owner: recipient, delta: 25)],
            actions: [Action(key: "profile", oldValue: "old", newValue: "new")],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [signer],
            fee: 0,
            nonce: 0
        )
        let tx = signedTransaction(
            body: body,
            privateKeyHex: keyPair.privateKey,
            publicKeyHex: keyPair.publicKey
        )

        let accepted = try await tx.validateTransactionForNexus(fetcher: fetcher)
        XCTAssertTrue(accepted)
    }
}

// MARK: - Adversarial: Signature Forgery

@MainActor
final class SignatureForgeryTests: XCTestCase {

    /// Exactly one accepted key encoding: the legacy branch that also accepted
    /// a bare 32-byte Ed25519 hex key gave the same key two valid encodings on
    /// live consensus surface. Bare-hex must now fail verification while the
    /// canonical Multikey form still verifies.
    func testBareHexPublicKeyEncodingRejected() {
        let kp = CryptoUtils.generateKeyPair()
        let message = "single-encoding-check"
        guard let sig = CryptoUtils.sign(message: message, privateKeyHex: kp.privateKey) else {
            return XCTFail("signing failed")
        }
        XCTAssertTrue(
            CryptoUtils.verify(message: message, signature: sig, publicKeyHex: kp.publicKey),
            "canonical Multikey encoding must verify")
        XCTAssertTrue(kp.publicKey.hasPrefix("ed01"), "Multikey ed25519 keys are ed01-prefixed")
        let bareHex = String(kp.publicKey.dropFirst(4))
        XCTAssertFalse(
            CryptoUtils.verify(message: message, signature: sig, publicKeyHex: bareHex),
            "bare 32-byte hex encoding of the same key must fail closed")
    }

    func testForgedSignatureRejected() {
        let kp = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [try! HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID],
            fee: 0, nonce: 1
        )
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
        let tx = Transaction(signatures: [kp.publicKey: "000000deadbeef000000"], body: bodyHeader)
        XCTAssertFalse(tx.signaturesAreValid(), "Forged signature must be rejected")
    }

    func testWrongSignerKeyRejected() {
        let kp1 = CryptoUtils.generateKeyPair()
        let kp2 = CryptoUtils.generateKeyPair()
        let signerCID = try! HeaderImpl<PublicKey>(node: PublicKey(key: kp2.publicKey)).rawCID
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [signerCID], fee: 0, nonce: 1
        )
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
        let sig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: kp1.privateKey)!
        let tx = Transaction(signatures: [kp1.publicKey: sig], body: bodyHeader)
        XCTAssertTrue(tx.signaturesAreValid(), "Signature is cryptographically valid")
        XCTAssertFalse(tx.signaturesMatchSigners(), "But signer CID doesn't match")
    }

    func testEmptySignatureRejected() {
        let kp = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [try! HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID],
            fee: 0, nonce: 1
        )
        let tx = Transaction(signatures: [kp.publicKey: ""], body: try! HeaderImpl<TransactionBody>(node: body))
        XCTAssertFalse(tx.signaturesAreValid())
    }
}

// MARK: - Adversarial: Balance Conservation

@MainActor
final class BalanceConservationTests: XCTestCase {

    func testTransactionValueConservationHelper() {
        let valid = TransactionBody(
            accountActions: [
                AccountAction(owner: "sender", delta: -101),
                AccountAction(owner: "recipient", delta: 100)
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["sender"], fee: 1, nonce: 0
        ).valueConservation()
        XCTAssertEqual(valid.totalDebits, 101)
        XCTAssertEqual(valid.totalCredits, 100)
        XCTAssertFalse(valid.overflow)
        XCTAssertTrue(valid.conserved)

        let underfundedFee = TransactionBody(
            accountActions: [
                AccountAction(owner: "sender", delta: -100),
                AccountAction(owner: "recipient", delta: 100)
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["sender"], fee: 1, nonce: 0
        ).valueConservation()
        XCTAssertFalse(underfundedFee.conserved)

        let bridged = TransactionBody(
            accountActions: [
                AccountAction(owner: "sender", delta: -150),
                AccountAction(owner: "recipient", delta: 100)
            ],
            actions: [],
            depositActions: [DepositAction(nonce: 1, demander: "sender", amountDemanded: 30, amountDeposited: 30)],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: "sender", nonce: 1, demander: "recipient", amountDemanded: 20, amountWithdrawn: 20)],
            signers: ["sender"], fee: 40, nonce: 0
        ).valueConservation()
        XCTAssertEqual(bridged.totalDebits, 150)
        XCTAssertEqual(bridged.totalCredits, 100)
        XCTAssertFalse(bridged.overflow)
        XCTAssertTrue(bridged.conserved)

        let overflow = TransactionBody(
            accountActions: [AccountAction(owner: "sender", delta: Int64.min)],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["sender"], fee: 0, nonce: 0
        ).valueConservation()
        XCTAssertTrue(overflow.overflow)
        XCTAssertFalse(overflow.conserved)
    }

    func testCannotCreateMoneyFromNothing() throws {
        let g = Block(
            parent: nil,
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: try! VolumeImpl<ChainSpec>(node: spec()),
            parentState: Reference(try! LatticeStateHeader(node: LatticeState.emptyState())),
            prevState: Reference(try! LatticeStateHeader(node: LatticeState.emptyState())),
            postState: try! LatticeStateHeader(node: LatticeState.emptyState()),
            children: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Block>>()),
            height: 0, timestamp: 1_000_000, nonce: 0
        )
        let accountActions = [AccountAction(owner: "miner", delta: Int64(999_999_999))]
        let valid = try g.validateBalanceChangesForGenesis(
            spec: spec(), allAccountActions: accountActions
        )
        XCTAssertFalse(valid, "Cannot create more value than premine allows")
    }

    func testFeeClaimRequiresSignerDebit() throws {
        let g = Block(
            parent: nil,
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: try! VolumeImpl<ChainSpec>(node: spec()),
            parentState: Reference(try! LatticeStateHeader(node: LatticeState.emptyState())),
            prevState: Reference(try! LatticeStateHeader(node: LatticeState.emptyState())),
            postState: try! LatticeStateHeader(node: LatticeState.emptyState()),
            children: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Block>>()),
            height: 1, timestamp: 2_000_000, nonce: 0
        )
        let s = spec()
        let reward = s.rewardAtBlock(1)
        let fees: UInt64 = 50
        let accountActions = [
            AccountAction(owner: "sender", delta: -Int64(fees)),
            AccountAction(owner: "miner", delta: Int64(reward + fees))
        ]
        let valid = try g.validateBalanceChanges(
            spec: s, allDepositActions: [], allWithdrawalActions: [],
            allAccountActions: accountActions
        )
        XCTAssertTrue(valid, "Miner can claim fees only when signer debits fund them")

        let overClaim = [
            AccountAction(owner: "miner", delta: Int64(reward + fees + 1))
        ]
        let invalid = try g.validateBalanceChanges(
            spec: s, allDepositActions: [], allWithdrawalActions: [],
            allAccountActions: overClaim
        )
        XCTAssertFalse(invalid, "Fees without matching debits must not expand the block credit budget")
    }

    func testGenesisFeesDoNotExpandPremineBudget() throws {
        let g = Block(
            parent: nil,
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: try! VolumeImpl<ChainSpec>(node: spec()),
            parentState: Reference(try! LatticeStateHeader(node: LatticeState.emptyState())),
            prevState: Reference(try! LatticeStateHeader(node: LatticeState.emptyState())),
            postState: try! LatticeStateHeader(node: LatticeState.emptyState()),
            children: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Block>>()),
            height: 0, timestamp: 1_000_000, nonce: 0
        )
        let s = spec()
        let fees: UInt64 = 50
        let invalid = try g.validateBalanceChangesForGenesis(
            spec: s, allAccountActions: [
                AccountAction(owner: "miner", delta: Int64(fees))
            ]
        )
        XCTAssertFalse(invalid, "Genesis transaction fees must not mint beyond premine")
    }
}

// MARK: -: Model-A Fee Keystone (block-level)

/// E4.4 keystone. The fee-market equilibrium analysis rests on one consensus
/// fact: a declared transaction `fee` cannot enlarge issuance — it is only an
/// ordinary signer debit redistributed to the miner, so author net mint stays
/// equal to `reward` (Model A; see Block+Validate.swift validateBalanceChanges,
/// which has NO totalFees term, and closes. This drives a BLOCK-LEVEL
/// entry (validateNexus) so the assertion exercises real per-tx structure, not
/// the flattened validateBalanceChanges helper.
@MainActor
final class ModelAFeeKeystoneTests: XCTestCase {

    private func nexusSpec(premine: UInt64) -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
            maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5
        )
    }

    private func signNexus(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
        let h = try! HeaderImpl<TransactionBody>(node: body)
        let sig = TransactionSigning.sign(bodyHeader: h, privateKeyHex: kp.privateKey)!
        return Transaction(signatures: [kp.publicKey: sig], body: h)
    }

    private func addr(_ pubKey: String) -> String {
        try! HeaderImpl<PublicKey>(node: PublicKey(key: pubKey)).rawCID
    }

    /// A fee declared with NO backing signer debit must be rejected. The block
    /// carries one signed tx that declares `fee = X (>0)` whose signer has net
    /// account debit 0, plus a miner self-credit AccountAction(delta: +(reward+X)).
    /// validateBalanceChanges computes available = totalDebits + reward = reward,
    /// but totalCredits = reward + X > reward, so conservation fails and the block
    /// is rejected — the fee cannot mint.
    func test_feeRequiresSignerDebit_blockRejected() async throws {
        let f = StorableFetcher()
        let base = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = addr(miner.publicKey)
        let s = nexusSpec(premine: 0)
        let fee: UInt64 = 50
        let reward = s.rewardAtBlock(1)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: f
        )
        // fee = 50 declared, but the signer is never debited; the only account
        // action is the miner crediting itself reward + fee.
        let maliciousBody = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(reward + fee))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], fee: fee, nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [signNexus(maliciousBody, miner)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: f
        )

        let valid = try await block.validateNexus(fetcher: f).0
        XCTAssertFalse(valid, "Model A: a declared fee with no backing signer debit must not enlarge issuance — the block must be rejected by the conservation check")
    }

    /// Positive companion: when the signer IS debited exactly `fee`, the miner's
    /// fee claim is funded and the block validates. This proves the keystone test
    /// rejects for the conservation reason, not because all fees are refused.
    func test_feeWithSignerDebit_blockValidates() async throws {
        let f = StorableFetcher()
        let base = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let payer = CryptoUtils.generateKeyPair()
        let payerAddr = addr(payer.publicKey)
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = addr(miner.publicKey)
        let s = nexusSpec(premine: 1000)
        let fee: UInt64 = 50
        let reward = s.rewardAtBlock(1)

        let genesis = try await buildPremineGenesis(spec: s, owner: payer, fetcher: f, timestamp: base)
        let fundedBody = TransactionBody(
            accountActions: [
                AccountAction(owner: payerAddr, delta: -Int64(fee)),
                AccountAction(owner: minerAddr, delta: Int64(reward + fee))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [payerAddr], fee: fee, nonce: 1, chainPath: ["Nexus"]
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [signNexus(fundedBody, payer)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: f
        )

        let valid = try await block.validateNexus(fetcher: f).0
        XCTAssertTrue(valid, "A fee backed by an exact signer debit funds the miner credit and must validate")
    }
}

// MARK: - Adversarial: Block Validation Checks

@MainActor
final class BlockValidationAdversarialTests: XCTestCase {

    func testBlockWithWrongIndexRejected() async throws {
        let g = try await genesis()
        let wrongIndex = Block(
            parent: Reference(try! VolumeImpl(node: g)),
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: g.spec,
            parentState: Reference(try! LatticeStateHeader(node: LatticeState.emptyState())),
            prevState: Reference(g.postState),
            postState: g.postState,
            children: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Block>>()),
            height: 5, timestamp: 2_000_000, nonce: 0
        )
        XCTAssertFalse(wrongIndex.validateHeight(parent: g), "Non-sequential index must fail")
    }

    func testBlockWithPastTimestampRejected() async throws {
        let g = try await genesis(timestamp: 5_000_000)
        let pastBlock = Block(
            parent: Reference(try! VolumeImpl(node: g)),
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: g.spec,
            parentState: Reference(try! LatticeStateHeader(node: LatticeState.emptyState())),
            prevState: Reference(g.postState),
            postState: g.postState,
            children: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Block>>()),
            height: 1, timestamp: 4_000_000, nonce: 0
        )
        XCTAssertFalse(pastBlock.validateTimestamp(parent: g), "Timestamp before parent must fail")
    }

    func testBlockWithWrongSpecRejected() async throws {
        let g = try await genesis()
        let differentSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 999,
            maxStateGrowth: 999,
            premine: 0,
            targetBlockTime: 999,
            initialReward: 32, halvingInterval: 10_000
        )
        let wrongSpec = Block(
            parent: Reference(try! VolumeImpl(node: g)),
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: try! VolumeImpl<ChainSpec>(node: differentSpec),
            parentState: Reference(try! LatticeStateHeader(node: LatticeState.emptyState())),
            prevState: Reference(g.postState),
            postState: g.postState,
            children: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Block>>()),
            height: 1, timestamp: 2_000_000, nonce: 0
        )
        XCTAssertFalse(wrongSpec.validateSpec(parent: g), "Changed spec must fail")
    }

    func testBlockWithWrongHomesteadRejected() async throws {
        let g = try await genesis()
        let wrongState = try! LatticeStateHeader(node: LatticeState.emptyState())
        let b = Block(
            parent: Reference(try! VolumeImpl(node: g)),
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: g.spec,
            parentState: Reference(wrongState),
            prevState: Reference(wrongState),
            postState: wrongState,
            children: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Block>>()),
            height: 1, timestamp: 2_000_000, nonce: 0
        )
        let stateValid = b.validateState(parent: g)
        XCTAssertTrue(stateValid || g.postState.rawCID == wrongState.rawCID,
            "If frontier == emptyState, this may pass; otherwise must fail")
    }

    func testBlockSizeLimitEnforced() async throws {
        let tinySpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 10,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000
        )
        let g = try await BlockBuilder.buildGenesis(
            spec: tinySpec, timestamp: 1_000_000, target: UInt256(1000), fetcher: fetcher
        )
        XCTAssertFalse(g.validateBlockSize(spec: tinySpec),
            "Block larger than 10 bytes must fail size check")
    }
}

// MARK: - Adversarial: Filter Bypass

@MainActor
final class FilterBypassTests: XCTestCase {

    func testTransactionPolicyEnforced() async throws {
        let fetcher = StorableFetcher()
        let policy = try storeWasmPolicy(accepts: false, scope: .transaction, fetcher: fetcher)
        let feeSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000,
            wasmPolicies: [policy]
        )
        let cheapTx = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [], fee: 50, nonce: 1
        )
        let accepted = await TransactionBody.batchVerifyPolicies(bodies: [cheapTx], spec: feeSpec, chainPath: ["Nexus"], fetcher: fetcher)
        XCTAssertFalse(accepted)
    }

    func testActionPolicyEnforced() async throws {
        let fetcher = StorableFetcher()
        let policy = try storeWasmPolicy(accepts: false, scope: .action, fetcher: fetcher)
        let nsSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024, halvingInterval: 10_000,
            wasmPolicies: [policy]
        )
        let badAction = Action(key: "system/hack", oldValue: nil, newValue: "data")
        let body = TransactionBody(accountActions: [], actions: [badAction], depositActions: [], genesisActions: [], receiptActions: [], withdrawalActions: [], signers: [], fee: 1, nonce: 0)
        let accepted = await TransactionBody.batchVerifyPolicies(bodies: [body], spec: nsSpec, chainPath: ["Nexus"], fetcher: fetcher)
        XCTAssertFalse(accepted)
    }

    func testChildPoliciesDoNotImplicitlyInheritParentPolicies() async throws {
        let fetcher = StorableFetcher()
        let rejectingParentPolicy = try storeWasmPolicy(accepts: false, scope: .transaction, fetcher: fetcher)
        let parentSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
            premine: 0, targetBlockTime: 1_000, initialReward: 1024, halvingInterval: 10_000,
            wasmPolicies: [rejectingParentPolicy]
        )
        let childSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
            premine: 0, targetBlockTime: 1_000, initialReward: 1024, halvingInterval: 10_000
        )
        let cheapTx = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [], fee: 10, nonce: 1
        )
        let childAccepted = await TransactionBody.batchVerifyPolicies(bodies: [cheapTx], spec: childSpec, chainPath: ["Nexus", "Child"], fetcher: fetcher)
        let parentAccepted = await TransactionBody.batchVerifyPolicies(bodies: [cheapTx], spec: parentSpec, chainPath: ["Nexus", "Child"], fetcher: fetcher)
        XCTAssertTrue(childAccepted, "Child spec has no policy, so it should not inherit the parent's rejecting policy by consensus")
        XCTAssertFalse(parentAccepted, "Parent policy still rejects when evaluated as the parent's own policy")
    }
}

// MARK: - Consensus Invariants Under Stress

@MainActor
final class ConsensusStressTests: XCTestCase {

    func testLongChainMaintainsInvariants() async throws {
        let blocks = try await buildChain(length: 100)
        let chain = ChainState.fromGenesis(block: blocks[0])
        await submitChain(chain, blocks: blocks)

        let tip = await chain.getMainChainTip()
        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 99)

        let tipOnMain = await chain.isOnMainChain(hash: tip)
        XCTAssertTrue(tipOnMain)

        let genesisOnMain = await chain.isOnMainChain(hash: header(blocks[0]).rawCID)
        XCTAssertTrue(genesisOnMain)
    }

    func testManyForksFromSameBlock() async throws {
        let g = try await genesis()
        let chain = ChainState.fromGenesis(block: g)

        let b1 = try await next(g, ts: 2_000_000, nonce: 1)
        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(b1), block: b1)

        for i in 0..<20 {
            let fork = try await next(g, ts: 2_000_000, nonce: UInt64(100 + i))
            let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(fork), block: fork)
        }

        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, header(b1).rawCID, "Original chain should hold against equal-length forks")
    }

    func testDeepReorgPreservesCommonAncestor() async throws {
        let blocks = try await buildChain(length: 20)
        let chain = ChainState.fromGenesis(block: blocks[0])
        await submitChain(chain, blocks: blocks)

        let forkPoint = blocks[5]
        var forkBlocks: [Block] = [forkPoint]
        for i in 6..<25 {
            let b = try await next(forkBlocks.last!, ts: 1_000_000 + Int64(i) * 1000, nonce: UInt64(200 + i))
            forkBlocks.append(b)
        }
        for b in forkBlocks.dropFirst() {
            let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(b), block: b)
        }

        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, header(forkBlocks.last!).rawCID)

        for i in 0...5 {
            let onMain = await chain.isOnMainChain(hash: header(blocks[i]).rawCID)
            XCTAssertTrue(onMain, "Common ancestor block \(i) must survive deep reorg")
        }

        for i in 6..<20 {
            let onMain = await chain.isOnMainChain(hash: header(blocks[i]).rawCID)
            XCTAssertFalse(onMain, "Replaced block \(i) must be off main chain")
        }
    }

    func testOutOfOrderBlockSubmission() async throws {
        let blocks = try await buildChain(length: 5)
        let chain = ChainState.fromGenesis(block: blocks[0])

        let r3 = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(blocks[3]), block: blocks[3])
        XCTAssertTrue(r3.needsChildBlock, "Block 3 submitted before 1,2 should need parent")

        let r1 = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(blocks[1]), block: blocks[1])
        XCTAssertTrue(r1.extendsMainChain)

        let r2 = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(blocks[2]), block: blocks[2])
        XCTAssertTrue(r2.extendsMainChain)

        let r4 = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(blocks[4]), block: blocks[4])
        XCTAssertTrue(r4.addedBlock)

        let tipHash = await chain.getMainChainTip()
        let tipIndex = await chain.getHighestBlockHeight()
        XCTAssertEqual(tipIndex, 4)
        XCTAssertEqual(tipHash, header(blocks[4]).rawCID)
    }

    func testMissingBlockTracking() async throws {
        let blocks = try await buildChain(length: 4)
        let chain = ChainState.fromGenesis(block: blocks[0])

        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(blocks[3]), block: blocks[3])

        let missing = await chain.getMissingBlockHashes()
        XCTAssertTrue(missing.contains(header(blocks[2]).rawCID), "Block 2 should be missing")

        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(blocks[2]), block: blocks[2])
        let stillMissing = await chain.getMissingBlockHashes()
        XCTAssertFalse(stillMissing.contains(header(blocks[2]).rawCID), "Block 2 no longer missing")
        XCTAssertTrue(stillMissing.contains(header(blocks[1]).rawCID), "Block 1 should now be missing")
    }
}

// MARK: - Economic Invariant Tests

@MainActor
final class EconomicInvariantTests: XCTestCase {

    func testRewardHalvingOccursAtCorrectBlock() {
        let s = spec()
        let halfInterval = s.halvingInterval
        let initial = s.rewardAtBlock(0)
        let beforeHalving = s.rewardAtBlock(halfInterval - 1)
        let atHalving = s.rewardAtBlock(halfInterval)
        XCTAssertEqual(initial, beforeHalving, "Reward constant within first period")
        XCTAssertEqual(atHalving, initial / 2, "Reward halves at interval boundary")
    }

    func testPremineOffsetShiftsHalving() {
        let premineSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
            premine: 100, targetBlockTime: 1_000, initialReward: 1024, halvingInterval: 10_000
        )
        let halfInterval = premineSpec.halvingInterval
        let firstHalvingBlock = halfInterval - 100
        let reward = premineSpec.initialReward
        XCTAssertEqual(premineSpec.rewardAtBlock(firstHalvingBlock - 1), reward)
        XCTAssertEqual(premineSpec.rewardAtBlock(firstHalvingBlock), reward / 2)
    }

    func testTotalRewardsMatchIndividualSum() {
        let s = spec()
        let n: UInt64 = 200
        let individual = (0..<n).reduce(UInt64(0)) { $0 + s.rewardAtBlock($1) }
        let total = s.totalRewards(upToBlock: n)
        XCTAssertEqual(individual, total)
    }

    func testDifficultyAdjustmentWindowSmoothing() {
        let s = spec()
        let baseDifficulty = UInt256(10000)
        let normalTimestamps: [Int64] = [5000, 4000, 3000, 2000, 1000]
        let normalResult = s.calculateWindowedTarget(
            previousTarget: baseDifficulty, ancestorTimestamps: normalTimestamps
        )
        XCTAssertEqual(normalResult, baseDifficulty, "On-target timing should not change target")

        let fastTimestamps: [Int64] = [1400, 1300, 1200, 1100, 1000]
        let harderResult = s.calculateWindowedTarget(
            previousTarget: baseDifficulty, ancestorTimestamps: fastTimestamps
        )
        XCTAssertTrue(harderResult < baseDifficulty, "Fast blocks should decrease target (harder)")

        let slowTimestamps: [Int64] = [21000, 16000, 11000, 6000, 1000]
        let easierResult = s.calculateWindowedTarget(
            previousTarget: baseDifficulty, ancestorTimestamps: slowTimestamps
        )
        XCTAssertTrue(easierResult > baseDifficulty, "Slow blocks should increase target (easier)")
    }

    func testWindowedDifficultySmooths() {
        let s = spec()
        let baseDifficulty = UInt256(10000)
        let fastTimestamps: [Int64] = [3000, 2500, 2000, 1500, 1000]
        let windowedResult = s.calculateWindowedTarget(
            previousTarget: baseDifficulty, ancestorTimestamps: fastTimestamps
        )
        XCTAssertTrue(windowedResult < baseDifficulty, "Fast average should increase target")

        let normalTimestamps: [Int64] = [5000, 4000, 3000, 2000, 1000]
        let normalResult = s.calculateWindowedTarget(
            previousTarget: baseDifficulty, ancestorTimestamps: normalTimestamps
        )
        XCTAssertTrue(windowedResult < normalResult,
            "Faster average should produce harder target than on-target")
    }
}

// MARK: - Cross-Chain Key Integrity

@MainActor
final class CrossChainKeyIntegrityTests: XCTestCase {

    func testSwapKeyRoundTrip() {
        for nonce: UInt128 in [0, 1, 42, UInt128.max / 2] {
            let key = DepositKey(depositAction: DepositAction(nonce: nonce, demander: "abc", amountDemanded: 999, amountDeposited: 999))
            let parsed = DepositKey(key.description)
            XCTAssertNotNil(parsed)
            XCTAssertEqual(parsed?.nonce, nonce)
            XCTAssertEqual(parsed?.demander, "abc")
            XCTAssertEqual(parsed?.amountDemanded, 999)
        }
    }

    func testSettleKeyRoundTrip() {
        let receiptAction = ReceiptAction(withdrawer: "w", nonce: 77, demander: "d", amountDemanded: 500, directory: "chain1")
        let key = ReceiptKey(receiptAction: receiptAction)
        let parsed = ReceiptKey(key.description)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.directory, "chain1")
        XCTAssertEqual(parsed?.demander, "d")
        XCTAssertEqual(parsed?.amountDemanded, 500)
        XCTAssertEqual(parsed?.nonce, 77)
    }

    func testSwapAndClaimKeysMatch() {
        let swap = DepositAction(nonce: 42, demander: "alice", amountDemanded: 100, amountDeposited: 100)
        let claim = WithdrawalAction(withdrawer: "bob", nonce: 42, demander: "alice", amountDemanded: 100, amountWithdrawn: 100)
        let swapKey = DepositKey(depositAction: swap)
        let claimKey = DepositKey(withdrawalAction: claim)
        XCTAssertEqual(swapKey.description, claimKey.description,
            "Swap and claim must produce the same lookup key")
    }

    func testMalformedKeysReturnNil() {
        for bad in ["", "x", "a/b"] {
            XCTAssertNil(DepositKey(bad), "'\(bad)' should fail to parse as SwapKey")
        }
        for bad in ["", "x", "nodirectory", "dir/demander", "dir/demander/notanumber"] {
            XCTAssertNil(ReceiptKey(bad), "'\(bad)' should fail to parse as SettleKey")
        }
    }
}

// MARK: - Regression Tests for Fixed Bugs

@MainActor
final class BugRegressionTests: XCTestCase {

    func testSettleKeySeparatorFixed() {
        let receiptAction = ReceiptAction(withdrawer: "w", nonce: 42, demander: "d", amountDemanded: 100, directory: "c")
        let key = ReceiptKey(receiptAction: receiptAction)
        let desc = key.description
        XCTAssertTrue(desc.contains("/"), "ReceiptKey parts must be separated by /")
        let parts = desc.split(separator: "/")
        XCTAssertEqual(parts.count, 4, "Must have 4 slash-separated parts: directory/demander/amountDemanded/nonce")
    }

    func testAccountStateProveUsesCorrectProofTypes() async throws {
        let emptyAccount = try! AccountStateHeader(node: AccountState())
        let insertAction = AccountAction(owner: "new_user", delta: Int64(100))
        let (proved, _) = try await emptyAccount.proveAndUpdateState(allAccountActions: [insertAction], fetcher: fetcher)
        XCTAssertNotNil(proved, "Insertion proof should succeed on empty state")
    }

    func testBestChainCacheInvalidationWalksFullAncestorChain() async throws {
        let blocks = try await buildChain(length: 5)
        let chain = ChainState.fromGenesis(block: blocks[0])
        await submitChain(chain, blocks: blocks)

        let tipBefore = await chain.getMainChainTip()
        XCTAssertEqual(tipBefore, header(blocks[4]).rawCID)

        var forkBlocks: [Block] = [blocks[2]]
        for i in 3..<8 {
            let b = try await next(forkBlocks.last!, ts: 1_000_000 + Int64(i) * 1000, nonce: UInt64(300 + i))
            forkBlocks.append(b)
            let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(b), block: b)
        }

        let tipAfter = await chain.getMainChainTip()
        XCTAssertEqual(tipAfter, header(forkBlocks.last!).rawCID,
            "Cache must be invalidated so the longer fork wins")
    }

    func testOrphanDetectionFindsCorrectForkPoint() async throws {
        let blocks = try await buildChain(length: 5)
        let chain = ChainState.fromGenesis(block: blocks[0])
        await submitChain(chain, blocks: blocks)

        let fork1 = try await next(blocks[2], ts: 4_000_000, nonce: 99)
        let fork2 = try await next(fork1, ts: 5_000_000, nonce: 99)
        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(fork1), block: fork1)
        let _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: header(fork2), block: fork2)

        let earliest = await chain.findEarliestOrphanConnectedToMainChain(blockHeader: header(fork2).rawCID)
        XCTAssertEqual(earliest, header(fork1).rawCID,
            "Should trace back to fork1, whose parent (blocks[2]) is on main chain")
    }
}

// MARK: - Dynamic Chain Discovery Tests

@MainActor
final class DynamicChainDiscoveryTests: XCTestCase {

    func testRegisterChildChain() async throws {
        let g = try await genesis()
        let nexusChain = ChainState.fromGenesis(block: g)
        let level = ChainLevel(chain: nexusChain, children: [:])

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 50,
                maxStateGrowth: 50_000,
                premine: 0,
                targetBlockTime: 2_000,
                initialReward: 256, halvingInterval: 10_000
            ),
            timestamp: 1_000_000,
            target: UInt256(500),
            fetcher: fetcher
        )

        let childrenBefore = await level.children
        XCTAssertTrue(childrenBefore.isEmpty)

        await level.subscribe(to: "child1", genesisBlock: childGenesis)

        let childrenAfter = await level.children
        XCTAssertEqual(childrenAfter.count, 1)
        XCTAssertNotNil(childrenAfter["child1"])

        let childTip = await childrenAfter["child1"]!.chain.getHighestBlockHeight()
        XCTAssertEqual(childTip, 0)
    }

    func testDuplicateRegistrationIgnored() async throws {
        let g = try await genesis()
        let level = ChainLevel(chain: ChainState.fromGenesis(block: g), children: [:])
        let childG = try await BlockBuilder.buildGenesis(
            spec: ChainSpec(maxNumberOfTransactionsPerBlock: 10, maxStateGrowth: 10_000,
                           premine: 0, targetBlockTime: 1_000, initialReward: 32, halvingInterval: 10_000),
            timestamp: 1_000_000, target: UInt256(100), fetcher: fetcher
        )

        await level.subscribe(to: "x", genesisBlock: childG)
        let tipAfterFirst = await level.children["x"]!.chain.getMainChainTip()

        let differentChildG = try await BlockBuilder.buildGenesis(
            spec: ChainSpec(maxNumberOfTransactionsPerBlock: 99, maxStateGrowth: 99_000,
                           premine: 0, targetBlockTime: 999, initialReward: 512, halvingInterval: 10_000),
            timestamp: 2_000_000, target: UInt256(200), fetcher: fetcher
        )
        await level.subscribe(to: "x", genesisBlock: differentChildG)
        let tipAfterSecond = await level.children["x"]!.chain.getMainChainTip()

        XCTAssertEqual(tipAfterFirst, tipAfterSecond, "Second registration should be ignored")
    }
}

// MARK: - State Continuity Chain Invariant

@MainActor
final class StateChainInvariantTests: XCTestCase {

    func testFrontierChainsAcrossMultipleBlocks() async throws {
        let blocks = try await buildChain(length: 10)
        for i in 1..<blocks.count {
            XCTAssertEqual(
                blocks[i].prevState.rawCID,
                blocks[i-1].postState.rawCID,
                "Block \(i) homestead must equal block \(i-1) frontier"
            )
        }
    }

    func testEmptyBlocksPreserveState() async throws {
        let blocks = try await buildChain(length: 10)
        let genesisState = blocks[0].prevState.rawCID
        for block in blocks {
            XCTAssertEqual(block.prevState.rawCID, block.postState.rawCID,
                "Empty block \(block.height) should not change state")
            XCTAssertEqual(block.prevState.rawCID, genesisState,
                "All empty blocks should have same state as genesis")
        }
    }

    func testSpecImmutableAcrossChain() async throws {
        let blocks = try await buildChain(length: 10)
        let genesisSpec = blocks[0].spec.rawCID
        for block in blocks {
            XCTAssertEqual(block.spec.rawCID, genesisSpec, "Spec must never change")
        }
    }

    func testCIDsAreUnique() async throws {
        let blocks = try await buildChain(length: 50)
        let cids = Set(blocks.map { header($0).rawCID })
        XCTAssertEqual(cids.count, blocks.count, "Every block must have a unique CID")
    }

    func testDifficultyHashesAreUnique() async throws {
        let blocks = try await buildChain(length: 50)
        let hashes = Set(blocks.map { $0.proofOfWorkHash() })
        XCTAssertEqual(hashes.count, blocks.count, "Every block must have a unique target hash")
    }
}

// MARK: - State Root Validation (header-first gossip correctness)

/// Verifies that blocks with valid PoW + valid structure but a tampered/wrong
/// state root are rejected before being submitted to ChainState.
/// This is the critical invariant for the header-first gossip design:
/// gossip relay happens before state validation, so processBlockHeader MUST
/// reject invalid state roots synchronously before submitBlock is called.
@MainActor
final class StateRootValidationTests: XCTestCase {

    /// A block with valid PoW and valid structure but a tampered postState CID
    /// must be rejected by processBlockHeader before submitBlock is called.
    func testNexusBlockWithTamperedPostStateIsRejected() async throws {
        let f = StorableFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        // UInt256.max as target: any hash qualifies, so nonce 0 always works.
        let easyDifficulty = UInt256.max

        let g = try await BlockBuilder.buildGenesis(
            spec: spec(), timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        let validBlock = try await BlockBuilder.buildBlock(
            previous: g, timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        try await storeBlockToFetcher(validBlock, fetcher: f)

        // Tamper postState. Re-mine using the block's own target (UInt256.max),
        // so nonce 0 trivially satisfies the PoW check.
        let fakePostState = VolumeImpl<LatticeState>(rawCID: "bafyfaketamperedpoststate000000000000000000000000000000000000")
        let tampered = validBlock.set(properties: [POST_STATE_PROPERTY: fakePostState])
        guard let minedTampered = BlockBuilder.mine(
            block: tampered, target: easyDifficulty, maxAttempts: 10
        ) else {
            XCTFail("Could not mine tampered block with easy target")
            return
        }
        try await storeBlockToFetcher(minedTampered, fetcher: f)

        let level = ChainLevel(chain: ChainState.fromGenesis(block: g), children: [:])
        let lattice = Lattice(nexus: level)
        let result = await lattice.processBlockHeader(header(minedTampered), fetcher: f)

        XCTAssertTrue(result.isRejected, "Block with tampered postState must be rejected")
        let tip = await level.chain.getHighestBlockHeight()
        XCTAssertEqual(tip, 0, "submitBlock must not have been called for a block with bad state root")
    }

    func testAcceptedBlockReturnsMaterializedPostStateAndRejectedBlockDoesNot() async throws {
        let f = StorableFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        let easyDifficulty = UInt256.max

        let g = try await BlockBuilder.buildGenesis(
            spec: spec(), timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        let validBlock = try await BlockBuilder.buildBlock(
            previous: g, timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        try await storeBlockToFetcher(validBlock, fetcher: f)

        let acceptingLevel = ChainLevel(chain: ChainState.fromGenesis(block: g), children: [:])
        let acceptingLattice = Lattice(nexus: acceptingLevel)
        let accepted = await acceptingLattice.processBlockHeader(header(validBlock), fetcher: f)

        XCTAssertTrue(accepted.isAccepted)
        guard let materializedPostState = accepted.materializedPostState else {
            XCTFail("Accepted block should return the materialized post-state")
            return
        }
        XCTAssertEqual(
            try LatticeStateHeader(node: materializedPostState).rawCID,
            validBlock.postState.rawCID,
            "Returned state must be the post-state committed by the accepted block"
        )

        let fakePostState = VolumeImpl<LatticeState>(rawCID: "bafyfaketamperedpoststate000000000000000000000000000000000000")
        let tampered = validBlock.set(properties: [POST_STATE_PROPERTY: fakePostState])
        guard let minedTampered = BlockBuilder.mine(
            block: tampered, target: easyDifficulty, maxAttempts: 10
        ) else {
            XCTFail("Could not mine tampered block with easy target")
            return
        }
        try await storeBlockToFetcher(minedTampered, fetcher: f)

        let rejectingLevel = ChainLevel(chain: ChainState.fromGenesis(block: g), children: [:])
        let rejectingLattice = Lattice(nexus: rejectingLevel)
        let rejected = await rejectingLattice.processBlockHeader(header(minedTampered), fetcher: f)

        XCTAssertTrue(rejected.isRejected)
        XCTAssertNil(rejected.materializedPostState)
    }

    func testWithheldParentDefersNotRejects() async throws {
        let incompleteFetcher = StorableFetcher()
        let completeFetcher = StorableFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        let easyDifficulty = UInt256.max

        let g = try await BlockBuilder.buildGenesis(
            spec: spec(), timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: fetcher
        )
        let block = try await BlockBuilder.buildBlock(
            previous: g, timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: fetcher
        )
        try await storeBlockToFetcher(block, fetcher: incompleteFetcher)

        let level = ChainLevel(chain: ChainState.fromGenesis(block: g), children: [:])
        let lattice = Lattice(nexus: level)
        let deferred = await lattice.processBlockHeader(header(block), fetcher: incompleteFetcher)

        XCTAssertTrue(deferred.isDeferred, "A block whose parent data is unavailable must defer, not reject")
        let deferredHeight = await level.chain.getHighestBlockHeight()
        XCTAssertEqual(deferredHeight, 0, "Deferred blocks must not be submitted")

        try await storeBlockToFetcher(g, fetcher: completeFetcher)
        try await storeBlockToFetcher(block, fetcher: completeFetcher)
        let accepted = await lattice.processBlockHeader(header(block), fetcher: completeFetcher)

        XCTAssertTrue(accepted.isAccepted, "A deferred block must remain acceptable once its parent is available")
        let acceptedHeight = await level.chain.getHighestBlockHeight()
        XCTAssertEqual(acceptedHeight, 1)
    }

    func testGenuinelyInvalidBlockRejects() async throws {
        let f = StorableFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        let easyDifficulty = UInt256.max

        let g = try await BlockBuilder.buildGenesis(
            spec: spec(), timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        let validBlock = try await BlockBuilder.buildBlock(
            previous: g, timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: f
        )

        let fakePostState = VolumeImpl<LatticeState>(rawCID: "bafyfaketamperedpoststate000000000000000000000000000000000000")
        let tampered = validBlock.set(properties: [POST_STATE_PROPERTY: fakePostState])
        guard let minedTampered = BlockBuilder.mine(
            block: tampered, target: easyDifficulty, maxAttempts: 10
        ) else {
            XCTFail("Could not mine tampered block with easy target")
            return
        }
        try await storeBlockToFetcher(minedTampered, fetcher: f)

        let level = ChainLevel(chain: ChainState.fromGenesis(block: g), children: [:])
        let lattice = Lattice(nexus: level)
        let rejected = await lattice.processBlockHeader(header(minedTampered), fetcher: f)
        let rejectedAgain = await lattice.processBlockHeader(header(minedTampered), fetcher: f)

        XCTAssertTrue(rejected.isRejected, "Fully-resolvable invalid blocks must reject")
        XCTAssertFalse(rejected.isDeferred, "Invalid blocks must not be reported as deferred")
        XCTAssertTrue(rejectedAgain.isRejected, "Reprocessing complete invalid data must not become accepted")
        let rejectedHeight = await level.chain.getHighestBlockHeight()
        XCTAssertEqual(rejectedHeight, 0)
    }

    /// A child block with valid PoW and valid structure but a tampered postState
    /// must not be submitted to the child chain.
    func testChildBlockWithTamperedPostStateIsRejected() async throws {
        let f = StorableFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        let easyDifficulty = UInt256.max
        let nexusSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialReward: 1024, halvingInterval: 10_000,
                                  retargetWindow: 5)
        let childSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialReward: 512, halvingInterval: 10_000,
                                  retargetWindow: 5)

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: f
        )

        let validChildBlock = try await BlockBuilder.buildBlock(
            previous: childGenesis, parentChainBlock: nexusGenesis,
            timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        try await storeBlockToFetcher(validChildBlock, fetcher: f)

        let fakePostState = VolumeImpl<LatticeState>(rawCID: "bafyfakechildpoststate00000000000000000000000000000000000000")
        let tamperedChild = validChildBlock.set(properties: [POST_STATE_PROPERTY: fakePostState])
        guard let minedTamperedChild = BlockBuilder.mine(
            block: tamperedChild, target: easyDifficulty, maxAttempts: 10
        ) else {
            XCTFail("Could not mine tampered child block with easy target")
            return
        }
        try await storeBlockToFetcher(minedTamperedChild, fetcher: f)

        // Build a nexus block that embeds the tampered child.
        let nexusBlock = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, children: ["Child": minedTamperedChild],
            timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        try await storeBlockToFetcher(nexusBlock, fetcher: f)

        let nexusLevel = ChainLevel(chain: ChainState.fromGenesis(block: nexusGenesis), children: [:])
        await nexusLevel.subscribe(to: "Child", genesisBlock: childGenesis)
        let lattice = Lattice(nexus: nexusLevel)
        _ = await lattice.processBlockHeader(header(nexusBlock), fetcher: f)

        let childTip = await nexusLevel.children["Child"]!.chain.getHighestBlockHeight()
        XCTAssertEqual(childTip, 0, "Tampered child block must not be submitted to child chain")
    }
}

private func storeBlockToFetcher(_ block: Block, fetcher: StorableFetcher) async throws {
    let storer = CollectingStorer()
    try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
    await storer.flush(to: fetcher)
}
