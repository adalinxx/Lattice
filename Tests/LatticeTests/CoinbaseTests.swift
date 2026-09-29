import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
import cashew
import UInt256

/// The failure a coinbase computation reports, or nil on success.
/// (`AccountAction` is not `Equatable`, so neither is the `Result`.)
func coinbaseFailure(_ result: Result<AccountAction?, CoinbaseError>) -> CoinbaseError? {
    if case .failure(let error) = result { return error }
    return nil
}

typealias CoinbaseKeyPair = (privateKey: String, publicKey: String)

/// A copy of `block` with a different `rewardRecipient` and nothing else
/// changed — the relayer's swap.
func withRewardRecipient(_ block: Block, _ recipient: String?) -> Block {
    Block(
        version: block.version, parent: block.parent,
        transactions: block.transactions, target: block.target,
        nextTarget: block.nextTarget, spec: block.spec,
        parentState: block.parentState, prevState: block.prevState,
        postState: block.postState, children: block.children,
        height: block.height, timestamp: block.timestamp,
        rewardRecipient: recipient, nonce: block.nonce
    )
}

func freshAddress() -> String {
    CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
}

/// A premined root chain: `payer` holds the premine at genesis.
struct CoinbaseFixture {
    let spec: ChainSpec
    let fetcher: StorableFetcher
    let genesis: Block
    let payer: CoinbaseKeyPair
    let payerAddress: String
    let base: Int64

    /// `bystanders` fresh accounts are each premined 1 alongside `payer`, so
    /// the account trie branches and an absence proof needs its own nodes.
    static func make(
        spec: ChainSpec = ChainSpec.test(premine: 1000),
        bystanders: Int = 0
    ) async throws -> CoinbaseFixture {
        let fetcher = StorableFetcher()
        let payer = CryptoUtils.generateKeyPair()
        let payerAddress = testAddress(publicKey: payer.publicKey)
        let base = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let premine = TransactionBody(
            accountActions: [AccountAction(
                owner: payerAddress, delta: Int64(spec.premineAmount()) - Int64(bystanders)
            )] + (0..<bystanders).map { _ in AccountAction(owner: freshAddress(), delta: 1) },
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [], nonce: 0, chainPath: ["Nexus"]
        )
        let result = try await BlockBuilder.buildGenesisWithTransition(
            spec: spec,
            transactions: [Transaction(signatures: [:], body: try HeaderImpl(node: premine))],
            timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let genesis = try await storeBuiltBlock(result, in: fetcher)
        return CoinbaseFixture(
            spec: spec, fetcher: fetcher, genesis: genesis, payer: payer,
            payerAddress: payerAddress, base: base
        )
    }

    var premine: UInt64 { spec.premineAmount() }
    var reward: UInt64 { spec.rewardAtBlock(1) }

    /// `payer` is debited `debit` and each payee credited its amount; the rest
    /// is left to the coinbase as a fee.
    func transfer(
        debit: UInt64,
        credits: [(String, UInt64)] = [],
        nonce: UInt64 = 0,
        chainPath: [String] = ["Nexus"]
    ) -> (body: TransactionBody, transaction: Transaction) {
        let body = TransactionBody(
            accountActions: [AccountAction(owner: payerAddress, delta: -Int64(debit))]
                + credits.map { AccountAction(owner: $0.0, delta: Int64($0.1)) },
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [payerAddress], nonce: nonce, chainPath: chainPath
        )
        return (body, signedTestTransaction(body, by: payer))
    }

    func block(_ transactions: [Transaction], recipient: String?) async throws -> Block {
        try await buildAndStoreBlock(
            previous: genesis, transactions: transactions,
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: recipient, fetcher: fetcher
        )
    }
}

func balance(_ state: LatticeState?, _ owner: String) throws -> UInt64? {
    try state?.accountState.node?.get(key: owner)
}

@MainActor
final class CoinbaseRuleTests: XCTestCase {

    // MARK: - Amount

    func testRecipientIsCreditedExactlyRewardPlusFees() async throws {
        let f = try await CoinbaseFixture.make()
        let payee = freshAddress()
        let recipient = freshAddress()
        // Two transactions leave 30 and 25 as fees.
        let first = f.transfer(debit: 100, credits: [(payee, 70)], nonce: 0)
        let second = f.transfer(debit: 25, nonce: 1)
        let block = try await f.block([first.transaction, second.transaction], recipient: recipient)

        let (valid, _, post) = try await block.validateNexus(fetcher: f.fetcher)
        XCTAssertTrue(valid)
        XCTAssertEqual(try balance(post, recipient), f.reward + 55, "fresh recipient account is created with R + F")
        XCTAssertEqual(try balance(post, payee), 70)
        XCTAssertEqual(try balance(post, f.payerAddress), f.premine - 125)
    }

    func testNilRecipientBurnsRewardAndFees() async throws {
        let f = try await CoinbaseFixture.make()
        let payee = freshAddress()
        let payment = f.transfer(debit: 100, credits: [(payee, 70)])
        let block = try await f.block([payment.transaction], recipient: nil)

        let (valid, _, post) = try await block.validateNexus(fetcher: f.fetcher)
        XCTAssertTrue(valid)
        let accounts = try XCTUnwrap(post?.accountState.node?.allKeysAndValues())
        let supply = accounts.filter { !AccountStateHeader.isReservedAccountKey($0.key) }
            .values.reduce(UInt64(0), +)
        XCTAssertEqual(supply, f.premine - 30, "the 30 fee burns and no reward is minted")
    }

    func testPostStateOffByOneFromTheCoinbaseIsRejected() async throws {
        let f = try await CoinbaseFixture.make()
        let recipient = freshAddress()
        let payment = f.transfer(debit: 100, credits: [(freshAddress(), 70)])
        let honest = try await f.block([payment.transaction], recipient: recipient)
        let valid = try await honest.validateNexus(fetcher: f.fetcher).0
        XCTAssertTrue(valid)

        let exact = Int64(f.reward + 30)
        for credit in [exact + 1, exact - 1, nil] as [Int64?] {
            let (forgedPost, _) = try await BlockBuilder.computePostState(
                prevState: f.genesis.postState,
                transactionBodies: [payment.body],
                coinbase: credit.map { AccountAction(owner: recipient, delta: $0) },
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
            XCTAssertFalse(forgedValid, "a coinbase credit of \(String(describing: credit)) instead of \(exact) must be rejected")
        }
    }

    // MARK: - Fee rule

    func testTransactionFundedByTheRewardIsRejected() async throws {
        let f = try await CoinbaseFixture.make()
        // Credits 10 more than it debits: under the old rule the reward paid
        // for it; now nothing does.
        let subsidized = f.transfer(debit: 5, credits: [(freshAddress(), 15)])
        let recipient = freshAddress()
        do {
            _ = try await f.block([subsidized.transaction], recipient: recipient)
            XCTFail("the builder must refuse a block whose transactions create value")
        } catch BlockBuilderError.invalidCoinbase(let error) {
            XCTAssertEqual(error, .feeRuleViolated)
        }
        let burned = try await f.block([subsidized.transaction], recipient: nil)
        let burnedValid = try await burned.validateNexus(fetcher: f.fetcher).0
        XCTAssertFalse(burnedValid, "the fee rule holds without a recipient too")
        let swapped = try await withRewardRecipient(burned, recipient).validateNexus(fetcher: f.fetcher).0
        XCTAssertFalse(swapped)
    }

    func testReplayedOldStyleRewardTransactionIsRejected() async throws {
        let f = try await CoinbaseFixture.make()
        let miner = CryptoUtils.generateKeyPair()
        let minerAddress = testAddress(publicKey: miner.publicKey)
        let oldReward = signedTestTransaction(TransactionBody(
            accountActions: [AccountAction(owner: minerAddress, delta: Int64(f.reward))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [minerAddress], nonce: 0, chainPath: ["Nexus"]
        ), by: miner)
        for recipient in [nil, minerAddress] as [String?] {
            let block = try await buildAndStoreBlock(
                previous: f.genesis, transactions: [oldReward],
                timestamp: f.base + 1000, target: UInt256(1000), nonce: 1,
                fetcher: f.fetcher
            )
            let valid = try await withRewardRecipient(block, recipient).validateNexus(fetcher: f.fetcher).0
            XCTAssertFalse(valid, "a signed self-credit cannot mint the reward (recipient \(String(describing: recipient)))")
        }
    }

    // MARK: - Recipient

    func testInvalidRecipientIsRejected() async throws {
        let f = try await CoinbaseFixture.make()
        let payment = f.transfer(debit: 10)
        for bad in ["", "miner", freshAddress().uppercased()] {
            XCTAssertEqual(coinbaseFailure(Block.coinbaseCredit(
                spec: f.spec, height: 1, recipient: bad,
                accountActions: payment.body.accountActions,
                depositActions: [], withdrawalActions: []
            )), .invalidRecipient, bad)
            do {
                _ = try await f.block([payment.transaction], recipient: bad)
                XCTFail("the builder must refuse recipient \(bad)")
            } catch BlockBuilderError.invalidCoinbase(let error) {
                XCTAssertEqual(error, .invalidRecipient)
            }
            let honest = try await f.block([payment.transaction], recipient: nil)
            let valid = try await withRewardRecipient(honest, bad).validateNexus(fetcher: f.fetcher).0
            XCTAssertFalse(valid, "recipient \(bad) must be rejected")
        }
    }

    func testZeroAmountAddsNoAction() throws {
        let spec = ChainSpec.test(initialReward: 1, halvingInterval: 1)
        let height: UInt64 = 1_000
        XCTAssertEqual(spec.rewardAtBlock(height), 0, "fixture must be past the last halving")
        let result = Block.coinbaseCredit(
            spec: spec, height: height, recipient: freshAddress(),
            accountActions: [], depositActions: [], withdrawalActions: []
        )
        guard case .success(let action) = result else { return XCTFail("\(result)") }
        XCTAssertNil(action, "M == 0 credits nothing")
    }

    func testAmountIsBoundedByInt64Max() throws {
        let spec = ChainSpec.test()
        let reward = spec.rewardAtBlock(1)
        let atBound = [AccountAction(owner: "payer", delta: -(Int64.max - Int64(reward)))]
        let result = Block.coinbaseCredit(
            spec: spec, height: 1, recipient: freshAddress(),
            accountActions: atBound, depositActions: [], withdrawalActions: []
        )
        guard case .success(let action?) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(action.delta, Int64.max)

        XCTAssertEqual(coinbaseFailure(Block.coinbaseCredit(
            spec: spec, height: 1, recipient: freshAddress(),
            accountActions: atBound + [AccountAction(owner: "other", delta: -1)],
            depositActions: [], withdrawalActions: []
        )), .amountOverflow)
        // Burning has no bound: nothing is credited.
        XCTAssertNil(coinbaseFailure(Block.coinbaseCredit(
            spec: spec, height: 1, recipient: nil,
            accountActions: atBound + [AccountAction(owner: "other", delta: -1)],
            depositActions: [], withdrawalActions: []
        )))
    }

    func testRecipientEqualToPayerNetsThroughOneBalance() async throws {
        let f = try await CoinbaseFixture.make()
        let payee = freshAddress()
        let payment = f.transfer(debit: 100, credits: [(payee, 70)])
        let block = try await f.block([payment.transaction], recipient: f.payerAddress)
        let (valid, _, post) = try await block.validateNexus(fetcher: f.fetcher)
        XCTAssertTrue(valid)
        XCTAssertEqual(try balance(post, f.payerAddress), f.premine - 100 + f.reward + 30)
    }

    func testGenesisWithRecipientIsRejected() async throws {
        let f = try await CoinbaseFixture.make()
        let honest = try await f.genesis.validateGenesis(fetcher: f.fetcher, chainPath: ["Nexus"]).0
        XCTAssertTrue(honest)
        let paid = withRewardRecipient(f.genesis, f.payerAddress)
        XCTAssertFalse(paid.hasGenesisShape())
        let paidValid = try await paid.validateGenesis(fetcher: f.fetcher, chainPath: ["Nexus"]).0
        XCTAssertFalse(paidValid)
    }

    // MARK: - Proof-of-work binding

    func testSwappingRecipientKeepingNonceInvalidatesProofOfWork() async throws {
        let f = try await CoinbaseFixture.make()
        let payment = f.transfer(debit: 10)
        let recipient = freshAddress()
        let thief = freshAddress()
        let target = UInt256.max >> 12
        let unmined = try await buildAndStoreBlock(
            previous: f.genesis, transactions: [payment.transaction],
            timestamp: f.base + 1000, target: target, nonce: 0,
            rewardRecipient: recipient, fetcher: f.fetcher
        )
        // Mine for `recipient`. A nonce that also happens to satisfy the
        // target for the thief (probability 2^-12) proves nothing about the
        // binding, so skip it and keep mining.
        var nonce: UInt64 = 0
        while true {
            let hash = UInt256.hash(Block.makeProofOfWorkPreimage(block: unmined, nonce: nonce))
            let stolen = UInt256.hash(Block.makeProofOfWorkPreimage(
                block: withRewardRecipient(unmined, thief), nonce: nonce
            ))
            if target >= hash && !(target >= stolen) { break }
            nonce += 1
        }
        let mined = BlockBuilder.mine(block: unmined, target: target, maxAttempts: nonce + 1)
        let honest = try XCTUnwrap(mined)
        XCTAssertEqual(honest.rewardRecipient, recipient)
        XCTAssertTrue(honest.validateProofOfWork(nexusHash: honest.proofOfWorkHash()))

        let swapped = withRewardRecipient(honest, thief)
        XCTAssertEqual(swapped.nonce, honest.nonce)
        XCTAssertNotEqual(swapped.proofOfWorkHash(), honest.proofOfWorkHash())
        XCTAssertFalse(swapped.validateProofOfWork(nexusHash: swapped.proofOfWorkHash()))
        XCTAssertNotEqual(
            Block.makeProofOfWorkPreimagePrefix(block: withRewardRecipient(honest, nil)),
            Block.makeProofOfWorkPreimagePrefix(block: honest)
        )
    }

    func testPreimagePrefixGolden() throws {
        let block = Block(
            parent: VolumeImpl<Block>(rawCID: testCID("parent")),
            transactions: HeaderImpl(rawCID: testCID("transactions")),
            target: UInt256(1000), nextTarget: UInt256(999),
            spec: VolumeImpl(rawCID: testCID("spec")),
            parentState: LatticeStateHeader(rawCID: testCID("parentState")),
            prevState: LatticeStateHeader(rawCID: testCID("prevState")),
            postState: LatticeStateHeader(rawCID: testCID("postState")),
            children: HeaderImpl(rawCID: testCID("children")),
            height: 7, timestamp: 1_700_000_000_000,
            rewardRecipient: testCID("recipient"), nonce: 42
        )
        let prefix = Block.makeProofOfWorkPreimagePrefix(block: block)
        let tail = Data("1700000000000\u{0}\(testCID("recipient"))\u{0}".utf8)
        XCTAssertEqual(prefix.suffix(tail.count), tail, "recipient is the last field before the nonce")
        XCTAssertEqual(UInt256.hash(prefix).toHexString(), "572a319b70ee17ff9a7e0ed4a9a9317f4de6143e423c2c6fb0c5e336fdb88c69")

        let burned = Block.makeProofOfWorkPreimagePrefix(block: withRewardRecipient(block, nil))
        let burnedTail = Data("\u{0}1700000000000\u{0}\u{0}".utf8)
        XCTAssertEqual(burned.suffix(burnedTail.count), burnedTail, "nil hashes as the empty field")
        XCTAssertEqual(UInt256.hash(burned).toHexString(), "7ad0ad3499d54106ba9a3b6df393f2468d53342f906093cce79197e6f599cfad")
    }

    // MARK: - Reconstruction and encoding

    func testReconstructionPathsCarryTheRecipient() async throws {
        let f = try await CoinbaseFixture.make()
        let recipient = freshAddress()
        let block = try await f.block([f.transfer(debit: 10).transaction], recipient: recipient)
        XCTAssertEqual(block.rewardRecipient, recipient)
        XCTAssertEqual(block.set(properties: [:]).rewardRecipient, recipient)
        XCTAssertEqual(
            block.set(properties: ["transactions": block.transactions.removingNode()]).rewardRecipient,
            recipient
        )
        XCTAssertEqual(BlockBuilder.mine(block: block, target: .max, maxAttempts: 1)?.rewardRecipient, recipient)

        let data = try XCTUnwrap(block.toData())
        XCTAssertEqual(Block(data: data)?.rewardRecipient, recipient)
        XCTAssertNotNil(data.range(of: Data("rewardRecipient".utf8)))
        let burnedData = try XCTUnwrap(withRewardRecipient(block, nil).toData())
        XCTAssertNil(burnedData.range(of: Data("rewardRecipient".utf8)), "nil is omitted from the encoding")
        XCTAssertNil(Block(data: burnedData)?.rewardRecipient)
    }

    // MARK: - Content resolution

    func testFreshRecipientValidatesFromStagedContent() async throws {
        let f = try await CoinbaseFixture.make(bystanders: 64)
        let recipient = freshAddress()
        let paths = Block.validationPaths(transactionBodies: [], rewardRecipient: recipient)
        XCTAssertEqual(paths[[PREV_STATE_PROPERTY, ACCOUNT_STATE_PROPERTY, recipient]], .targeted)
        XCTAssertNil(Block.validationPaths(transactionBodies: [], rewardRecipient: nil)[
            [PREV_STATE_PROPERTY, ACCOUNT_STATE_PROPERTY, recipient]
        ])

        let block = try await f.block([f.transfer(debit: 10).transaction], recipient: recipient)
        // A verifier holding only what `storeBlock` stages for each block.
        let staged = StorableFetcher()
        try await VolumeImpl<Block>(node: f.genesis).storeBlock(fetcher: f.fetcher, storer: staged)
        try await VolumeImpl<Block>(node: block).storeBlock(fetcher: f.fetcher, storer: staged)
        let (valid, _, post) = try await block.validateNexus(fetcher: staged)
        XCTAssertTrue(valid, "the staged package must prove the fresh recipient's absence")
        XCTAssertEqual(try balance(post, recipient), f.reward + 10)
    }
}

// MARK: - Child chains

@MainActor
final class CoinbaseChildChainTests: XCTestCase {

    func testChildRewardUsesChildSpecAndDepositsEnterFees() async throws {
        let nexusSpec = ChainSpec.test()
        let childSpec = ChainSpec.test(premine: 1000, initialReward: 77)
        XCTAssertNotEqual(nexusSpec.rewardAtBlock(1), childSpec.rewardAtBlock(1))
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

        // Debit 25: 20 is deposited for the parent chain, 5 is the fee.
        let body = TransactionBody(
            accountActions: [AccountAction(owner: payerAddress, delta: -25)],
            actions: [],
            depositActions: [DepositAction(nonce: 1, demander: payerAddress, amountDemanded: 20, amountDeposited: 20)],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [payerAddress], nonce: 0, chainPath: ["Nexus", "Payments"]
        )
        XCTAssertEqual(body.minerSurplus(), WorkSum(UInt256(5)))
        let recipient = freshAddress()
        let childBlock = try await buildAndStoreBlock(
            previous: childGenesis,
            transactions: [signedTestTransaction(body, by: payer)],
            parentChainBlock: nexusGenesis,
            timestamp: base + 1000, target: UInt256(1000), nonce: 0,
            rewardRecipient: recipient, fetcher: fetcher
        )
        let (valid, _, post) = try await childBlock.validateNexus(
            fetcher: fetcher, chainPath: ["Nexus", "Payments"]
        )
        XCTAssertTrue(valid)
        XCTAssertEqual(try balance(post, recipient), childSpec.rewardAtBlock(1) + 5)

        // The recipient is bound through the parent's child commitment: the
        // proof names the child's CID, and a swapped recipient is another CID.
        let carrier = try await buildAndStoreBlock(
            previous: nexusGenesis,
            children: ["Payments": childBlock],
            timestamp: base + 1000, target: UInt256(1000), nonce: 0,
            fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Payments",
            fetcher: fetcher
        )
        let hop = await proof.directHop()
        let directHop = try XCTUnwrap(hop)
        XCTAssertTrue(directHop.binds(child: childBlock))
        XCTAssertFalse(directHop.binds(child: withRewardRecipient(childBlock, freshAddress())))
        XCTAssertFalse(directHop.binds(child: withRewardRecipient(childBlock, nil)))
    }
}
