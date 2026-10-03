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

/// A replayed-nonce block is rejected if validation returns false or throws
/// `StateErrors.nonceGap`. Any other error is unexpected and is rethrown so
/// the test fails.
private func isRejectedForNonceReplay(_ block: Block, fetcher: Fetcher) async throws -> Bool {
    do {
        _ = try await block.validateNexus(fetcher: fetcher)
        return false  // only a thrown nonceGap proves the replay rule fired
    } catch StateErrors.nonceGap {
        return true
    }
}

// MARK: - Signature malleability and same-body replay

@MainActor
final class SignatureEdgeTests: XCTestCase {

    /// Ed25519 group order L, little-endian.
    private static let groupOrderLE: [UInt8] = [
        0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
        0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
    ]

    /// S + L as a 32-byte little-endian integer; nil if it overflows 256 bits.
    private func addGroupOrder(toScalar s: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 32)
        var carry: UInt16 = 0
        for i in 0..<32 {
            let sum = UInt16(s[i]) + UInt16(Self.groupOrderLE[i]) + carry
            out[i] = UInt8(sum & 0xff)
            carry = sum >> 8
        }
        return carry == 0 ? out : nil
    }

    func testNonCanonicalScalarSPlusLIsRejected() throws {
        let key = CryptoUtils.generateKeyPair()
        let message = "edge-malleability"
        let signature = try XCTUnwrap(CryptoUtils.sign(message: message, privateKeyHex: key.privateKey))
        XCTAssertTrue(CryptoUtils.verify(message: message, signature: signature, publicKeyHex: key.publicKey))

        let bytes = [UInt8](try XCTUnwrap(Data(hex: signature)))
        XCTAssertEqual(bytes.count, 64)
        // Canonical S < L < 2^253, so S + L < 2^254 never overflows 32 bytes.
        let malleatedS = try XCTUnwrap(addGroupOrder(toScalar: Array(bytes[32..<64])))
        let malleated = Data(bytes[0..<32] + malleatedS).hexString
        XCTAssertNotEqual(malleated, signature)

        XCTAssertFalse(
            CryptoUtils.verify(message: message, signature: malleated, publicKeyHex: key.publicKey),
            "non-canonical S + L must not verify (signature malleability)"
        )
    }

    func testSameBodySignedTwoWaysYieldsDistinctTransactionsButOneSpend() async throws {
        let f = try await CoinbaseFixture.make()
        let payee = freshAddress()
        let body = f.transfer(debit: 10, credits: [(payee, 10)], nonce: 0).body
        let header = try HeaderImpl<TransactionBody>(node: body)
        let envelope = try XCTUnwrap(TransactionSigning.sign(bodyHeader: header, privateKeyHex: f.payer.privateKey))
        let legacy = try XCTUnwrap(CryptoUtils.sign(message: header.rawCID, privateKeyHex: f.payer.privateKey))
        let txA = Transaction(signatures: [f.payer.publicKey: envelope], body: header)
        let txB = Transaction(signatures: [f.payer.publicKey: legacy], body: header)

        let cidA = try HeaderImpl<Transaction>(node: txA).rawCID
        let cidB = try HeaderImpl<Transaction>(node: txB).rawCID
        XCTAssertNotEqual(cidA, cidB, "two signatures over one body are two transaction identities")
        XCTAssertTrue(txA.signaturesAreValid())
        XCTAssertTrue(txB.signaturesAreValid())

        // Each is valid alone.
        for tx in [txA, txB] {
            let block = try await f.block([tx], recipient: nil)
            let valid = try await block.validateNexus(fetcher: f.fetcher).0
            XCTAssertTrue(valid)
        }

        // Both in one block: the shared nonce makes the second a replay.
        // Applying the body twice fails (nonceGap), so the strongest forgery
        // carries both twins over a post-state that applies the body once.
        let forgedBoth = try await f.unchecked([body], [txA, txB], recipient: nil)
        let forgedBothRejected = try await isRejectedForNonceReplay(forgedBoth, fetcher: f.fetcher)
        XCTAssertTrue(forgedBothRejected, "both twins in one block must be rejected")

        // Twin in the next block after the first: nonce already consumed. The
        // builder would refuse it (and re-applying the body throws
        // nonceGap), so forge block 2 directly: it carries txB over the
        // unchanged post-state of block 1 — what a producer bypassing the
        // builder's checks would emit.
        let first = try await f.block([txA], recipient: nil)
        let firstValid = try await first.validateNexus(fetcher: f.fetcher).0
        XCTAssertTrue(firstValid)
        let honestEmpty = try await buildAndStoreBlock(
            previous: first, transactions: [],
            timestamp: f.base + 2000, target: UInt256(1000), nonce: 2,
            fetcher: f.fetcher
        )
        let second = Block(
            version: honestEmpty.version, parent: honestEmpty.parent,
            transactions: try BlockBuilder.buildTransactionsDictionary([txB]),
            target: honestEmpty.target, nextTarget: honestEmpty.nextTarget, spec: honestEmpty.spec,
            parentState: honestEmpty.parentState, prevState: honestEmpty.prevState,
            postState: first.postState, children: honestEmpty.children,
            height: honestEmpty.height, timestamp: honestEmpty.timestamp,
            rewardRecipient: nil, nonce: honestEmpty.nonce
        )
        _ = try await storeBuiltBlock(second, in: f.fetcher)
        let secondRejected = try await isRejectedForNonceReplay(second, fetcher: f.fetcher)
        XCTAssertTrue(secondRejected, "replayed twin in the following block must be rejected")
    }
}

// MARK: - Coinbase arithmetic edges

@MainActor
final class CoinbaseEdgeTests: XCTestCase {

    func testZeroFeeValidatesAndOverspendByOneIsRejected() async throws {
        let f = try await CoinbaseFixture.make()
        let recipient = freshAddress()
        let payee = freshAddress()
        let zeroFee = f.transfer(debit: 100, credits: [(payee, 100)])
        let block = try await f.block([zeroFee.transaction], recipient: recipient)
        let (valid, _, post) = try await block.validateNexus(fetcher: f.fetcher)
        XCTAssertTrue(valid)
        XCTAssertEqual(try balance(post, recipient), f.reward, "zero fee: coinbase is exactly R")
        XCTAssertEqual(try balance(post, payee), 100)

        let overspend = f.transfer(debit: 100, credits: [(payee, 101)])
        for r in [recipient, nil] as [String?] {
            let forged = try await f.unchecked([overspend.body], [overspend.transaction], recipient: r)
            let forgedValid = try await forged.validateNexus(fetcher: f.fetcher).0
            XCTAssertFalse(forgedValid, "C + P == D + W + 1 must be rejected (recipient \(String(describing: r)))")
        }
    }

    func testRecipientWhoIsAlsoPayeeGetsCreditPlusRewardPlusFeesExactly() async throws {
        let f = try await CoinbaseFixture.make()
        let recipient = freshAddress()
        // Prior balance for the recipient via a block-1 payment.
        let seed = f.transfer(debit: 40, credits: [(recipient, 40)], nonce: 0)
        let block1 = try await f.block([seed.transaction], recipient: nil)
        let (v1, _, post1) = try await block1.validateNexus(fetcher: f.fetcher)
        XCTAssertTrue(v1)
        let prior = try XCTUnwrap(try balance(post1, recipient))
        XCTAssertEqual(prior, 40)

        // Block 2: recipient is credited 60, fee 15.
        let pay = f.transfer(debit: 75, credits: [(recipient, 60)], nonce: 1)
        let honest = try await buildAndStoreBlock(
            previous: block1, transactions: [pay.transaction],
            timestamp: f.base + 2000, target: UInt256(1000), nonce: 2,
            rewardRecipient: recipient, fetcher: f.fetcher
        )
        let (valid, _, post) = try await honest.validateNexus(fetcher: f.fetcher)
        XCTAssertTrue(valid)
        let reward2 = f.spec.rewardAtBlock(2)
        XCTAssertEqual(try balance(post, recipient), prior + 60 + reward2 + 15)

        let (forgedPost, _) = try await BlockBuilder.computePostState(
            prevState: block1.postState, transactionBodies: [pay.body],
            coinbase: AccountAction(owner: recipient, delta: Int64(reward2 + 15 + 1)),
            fetcher: f.fetcher
        )
        let forged = Block(
            version: honest.version, parent: honest.parent,
            transactions: honest.transactions, target: honest.target,
            nextTarget: honest.nextTarget, spec: honest.spec,
            parentState: honest.parentState, prevState: honest.prevState,
            postState: forgedPost, children: honest.children,
            height: honest.height, timestamp: honest.timestamp,
            rewardRecipient: honest.rewardRecipient, nonce: honest.nonce
        )
        let forgedValid = try await forged.validateNexus(fetcher: f.fetcher).0
        XCTAssertFalse(forgedValid, "reward + fees + 1 must be rejected")
    }

    func testRewardExactlyAtHalvingHeightPlusFees() async throws {
        // offset = height + premine; with premine 1000 and interval 1001 the
        // first halving lands exactly on block 1.
        let spec = ChainSpec.test(premine: 1000, halvingInterval: 1001)
        XCTAssertEqual(spec.rewardAtBlock(0), spec.initialReward)
        XCTAssertEqual(spec.rewardAtBlock(1), spec.initialReward / 2)
        let f = try await CoinbaseFixture.make(spec: spec)
        let recipient = freshAddress()
        let pay = f.transfer(debit: 50, credits: [(freshAddress(), 43)])
        let block = try await f.block([pay.transaction], recipient: recipient)
        let (valid, _, post) = try await block.validateNexus(fetcher: f.fetcher)
        XCTAssertTrue(valid)
        XCTAssertEqual(try balance(post, recipient), spec.initialReward / 2 + 7)

        for wrong in [spec.initialReward + 7, spec.initialReward / 2 + 8] {
            let (forgedPost, _) = try await BlockBuilder.computePostState(
                prevState: f.genesis.postState, transactionBodies: [pay.body],
                coinbase: AccountAction(owner: recipient, delta: Int64(wrong)),
                fetcher: f.fetcher
            )
            let forged = Block(
                version: block.version, parent: block.parent,
                transactions: block.transactions, target: block.target,
                nextTarget: block.nextTarget, spec: block.spec,
                parentState: block.parentState, prevState: block.prevState,
                postState: forgedPost, children: block.children,
                height: block.height, timestamp: block.timestamp,
                rewardRecipient: block.rewardRecipient, nonce: block.nonce
            )
            let forgedValid = try await forged.validateNexus(fetcher: f.fetcher).0
            XCTAssertFalse(forgedValid, "coinbase \(wrong) at a halving height must be rejected")
        }
    }

    func testParentAndChildCoinbasesDoNotDoubleCountFees() async throws {
        let nexusSpec = ChainSpec.test()
        let childSpec = ChainSpec.test(premine: 1000, initialReward: 77)
        let fetcher = StorableFetcher()
        let payer = CryptoUtils.generateKeyPair()
        let payerAddress = testAddress(publicKey: payer.publicKey)
        let base = Int64(Date().timeIntervalSince1970 * 1000) - 10_000

        let childGenesis = try await buildPremineGenesis(
            spec: childSpec, owner: payer, fetcher: fetcher, timestamp: base
        )
        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        // Child tx: debit 25, credit 20, fee 5.
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: payerAddress, delta: -25),
                AccountAction(owner: freshAddress(), delta: 20),
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [payerAddress], nonce: 0, chainPath: ["Nexus", "Payments"]
        )
        let childRecipient = freshAddress()
        let childBlock = try await buildAndStoreBlock(
            previous: childGenesis,
            transactions: [signedTestTransaction(body, by: payer)],
            parentChainBlock: nexusGenesis,
            timestamp: base + 1000, target: UInt256(1000), nonce: 0,
            rewardRecipient: childRecipient, fetcher: fetcher
        )
        let (childValid, _, childPost) = try await childBlock.validateNexus(
            fetcher: fetcher, chainPath: ["Nexus", "Payments"]
        )
        XCTAssertTrue(childValid)
        XCTAssertEqual(try balance(childPost, childRecipient), childSpec.rewardAtBlock(1) + 5)

        let parentRecipient = freshAddress()
        let carrier = try await buildAndStoreBlock(
            previous: nexusGenesis,
            children: ["Payments": childBlock],
            timestamp: base + 1000, target: UInt256(1000), nonce: 0,
            rewardRecipient: parentRecipient, fetcher: fetcher
        )
        let (carrierValid, _, carrierPost) = try await carrier.validateNexus(fetcher: fetcher)
        XCTAssertTrue(carrierValid)
        XCTAssertEqual(try balance(carrierPost, parentRecipient), nexusSpec.rewardAtBlock(1),
                       "parent coinbase is parent R + parent F only (no parent txs => F = 0)")
        XCTAssertNil(try balance(carrierPost, childRecipient), "child coinbase never lands in parent state")

        let (forgedPost, _) = try await BlockBuilder.computePostState(
            prevState: nexusGenesis.postState, transactionBodies: [],
            coinbase: AccountAction(owner: parentRecipient, delta: Int64(nexusSpec.rewardAtBlock(1) + 5)),
            fetcher: fetcher
        )
        let forged = Block(
            version: carrier.version, parent: carrier.parent,
            transactions: carrier.transactions, target: carrier.target,
            nextTarget: carrier.nextTarget, spec: carrier.spec,
            parentState: carrier.parentState, prevState: carrier.prevState,
            postState: forgedPost, children: carrier.children,
            height: carrier.height, timestamp: carrier.timestamp,
            rewardRecipient: carrier.rewardRecipient, nonce: carrier.nonce
        )
        let forgedValid = try await forged.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(forgedValid, "parent coinbase claiming child fees must be rejected")
    }
}
