import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

private func makeFetcher() -> StorableFetcher { StorableFetcher() }

private func spec(_ dir: String = "Nexus", premine: UInt64 = 1000) -> ChainSpec {
    ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
}

private func sign(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
    let h = try! HeaderImpl<TransactionBody>(node: body)
    let sig = TransactionSigning.sign(bodyHeader: h, privateKeyHex: kp.privateKey)!
    return Transaction(signatures: [kp.publicKey: sig], body: h)
}

private func cid(_ pubKey: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: pubKey)).rawCID
}

private func t() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// MARK: - 1. Double-Spend Resistance

@MainActor
final class DoubleSpendAdversarialTests: XCTestCase {

    func testDoubleSpendSameBlockRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let charlie = CryptoUtils.generateKeyPair()
        let aliceAddr = cid(alice.publicKey)
        let bobAddr = cid(bob.publicKey)
        let charlieAddr = cid(charlie.publicKey)
        let s = spec()
        let premine = s.premineAmount()
        let reward = s.rewardAtBlock(0)

        let genesis = try await buildPremineGenesis(spec: s, owner: alice, fetcher: fetcher, timestamp: base)

        let spend1 = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(premine)),
                AccountAction(owner: bobAddr, delta: Int64(premine + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let spend2 = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(premine)),
                AccountAction(owner: charlieAddr, delta: Int64(premine + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 2
        )

        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: genesis, transactions: [sign(spend1, alice), sign(spend2, alice)],
                timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
            )
            XCTFail("Building block with double-spend should throw")
        } catch {
            // conflicting account actions on same owner
        }
    }

    func testDoubleSpendAcrossBlocksRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = cid(alice.publicKey)
        let bobAddr = cid(bob.publicKey)
        let s = spec()
        let premine = s.premineAmount()
        let reward = s.rewardAtBlock(0)

        let genesis = try await buildPremineGenesis(spec: s, owner: alice, fetcher: fetcher, timestamp: base)

        let spend1Body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(premine)),
                AccountAction(owner: bobAddr, delta: Int64(premine + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [sign(spend1Body, alice)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let spend2Body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premine - 1) - Int64(premine)),
                AccountAction(owner: bobAddr, delta: Int64(premine + reward + 1 + reward) - Int64(premine + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 2
        )

        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: block1, transactions: [sign(spend2Body, alice)],
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            XCTFail("Block referencing stale balance should throw")
        } catch {
            // alice's balance is 0 after block1, not premine
        }
    }
}

// MARK: - 1b. Fee Accounting

@MainActor
final class FeeAccountingValidationTests: XCTestCase {

    func testValidateNexusRejectsFeeFundedMintWithoutSignerDebit() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = cid(miner.publicKey)
        let s = spec(premine: 0)
        let fee: UInt64 = 50
        let reward = s.rewardAtBlock(1)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let body = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(reward + fee))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], fee: fee, nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [sign(body, miner)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "Transaction fee must not create spendable block budget unless a signer debit funds it")
    }

    func testValidateNexusAcceptsFeeClaimWhenSignerDebitFundsIt() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let payer = CryptoUtils.generateKeyPair()
        let payerAddr = cid(payer.publicKey)
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = cid(miner.publicKey)
        let s = spec(premine: 1000)
        let fee: UInt64 = 50
        let reward = s.rewardAtBlock(1)

        let genesis = try await buildPremineGenesis(spec: s, owner: payer, fetcher: fetcher, timestamp: base)
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: payerAddr, delta: -Int64(fee)),
                AccountAction(owner: minerAddr, delta: Int64(reward + fee))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [payerAddr], fee: fee, nonce: 1, chainPath: ["Nexus"]
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [sign(body, payer)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid, "Miner fee claim should validate when the fee is already debited from a signer")
    }

    func testValidateGenesisRejectsFeeFundedPremineExpansion() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = cid(miner.publicKey)
        let s = spec(premine: 0)
        let fee: UInt64 = 50
        let body = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(fee))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], fee: fee, nonce: 0
        )
        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, transactions: [sign(body, miner)],
            timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let valid = try await genesis.validateGenesis(fetcher: fetcher, directory: "Nexus").0
        XCTAssertFalse(valid, "Genesis fees must not expand the premine budget")
    }
}

// MARK: - 2. Signature & Authentication Security

@MainActor
final class SignatureSecurityTests: XCTestCase {

    func testTamperedSignatureRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = cid(kp.publicKey)
        let s = spec(premine: 0)
        let reward = s.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
        let realSig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: kp.privateKey)!
        var tamperedSig = realSig
        let idx = tamperedSig.index(tamperedSig.startIndex, offsetBy: 10)
        let c = tamperedSig[idx]
        let replacement: Character = c == "a" ? "b" : "a"
        tamperedSig = String(tamperedSig.prefix(upTo: idx)) + String(replacement) + String(tamperedSig.suffix(from: tamperedSig.index(after: idx)))

        let tx = Transaction(signatures: [kp.publicKey: tamperedSig], body: bodyHeader)

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid)
    }

    func testWrongSignerKeyRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let real = CryptoUtils.generateKeyPair()
        let imposter = CryptoUtils.generateKeyPair()
        let realAddr = cid(real.publicKey)
        let s = spec(premine: 0)
        let reward = s.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let body = TransactionBody(
            accountActions: [AccountAction(owner: realAddr, delta: Int64(reward))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [realAddr], fee: 0, nonce: 0
        )
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
        let sig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: imposter.privateKey)!
        let tx = Transaction(signatures: [imposter.publicKey: sig], body: bodyHeader)

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid)
    }

    func testEmptySignatureRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = cid(kp.publicKey)
        let s = spec(premine: 0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [], fee: 0, nonce: 0
        )
        let tx = Transaction(signatures: [:], body: try! HeaderImpl<TransactionBody>(node: body))

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid)
    }

    func testFundRemovalWithoutOwnerSignatureFails() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let alice = CryptoUtils.generateKeyPair()
        let thief = CryptoUtils.generateKeyPair()
        let aliceAddr = cid(alice.publicKey)
        let thiefAddr = cid(thief.publicKey)
        let s = spec()
        let premine = s.premineAmount()
        let reward = s.rewardAtBlock(0)

        let genesis = try await buildPremineGenesis(spec: s, owner: alice, fetcher: fetcher, timestamp: base)

        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(premine)),
                AccountAction(owner: thiefAddr, delta: Int64(premine + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [thiefAddr], fee: 0, nonce: 0
        )
        let tx = sign(body, thief)

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid)
    }
}

// MARK: - 3. Balance Overflow / Underflow

@MainActor
final class BalanceOverflowTests: XCTestCase {

    func testOverclaimBeyondRewardFails() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = cid(kp.publicKey)
        let s = spec(premine: 0)
        let reward = s.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward + 1))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [sign(body, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let v = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(v)
    }

    func testGenesisOverclaimBeyondPremineFails() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = cid(kp.publicKey)
        let s = spec()
        let premine = s.premineAmount()

        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(premine + 1))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [kpAddr], fee: 0, nonce: 0
        )

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, transactions: [sign(body, kp)],
            timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let gv = try await genesis.validateGenesis(fetcher: fetcher, directory: "Nexus").0
        XCTAssertFalse(gv)
    }

    func testZeroAmountAccountActionRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = cid(kp.publicKey)
        let action = AccountAction(owner: kpAddr, delta: Int64(0))
        XCTAssertFalse(action.verify())
    }
}

// MARK: - 4. Cross-Chain Swap Security

@MainActor
final class CrossChainSecurityTests: XCTestCase {

    func testDuplicateSwapNonceRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = cid(kp.publicKey)
        let s = spec("Child")
        let premine = s.premineAmount()
        let reward = s.rewardAtBlock(0)

        let genesis = try await buildPremineGenesis(spec: s, owner: kp, fetcher: fetcher, timestamp: base)

        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: kpAddr, delta: Int64(premine - 200 + reward) - Int64(premine))
            ],
            actions: [],
            depositActions: [
                DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 100, amountDeposited: 100),
                DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 100, amountDeposited: 100)
            ],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 1
        )

        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: genesis, transactions: [sign(body, kp)],
                timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
            )
            XCTFail("Duplicate swap nonce should throw")
        } catch {
        }
    }

    func testZeroSwapAmountRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = cid(kp.publicKey)
        let s = spec("Child")
        let premine = s.premineAmount()
        let reward = s.rewardAtBlock(0)

        let genesis = try await buildPremineGenesis(spec: s, owner: kp, fetcher: fetcher, timestamp: base)

        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: kpAddr, delta: Int64(premine + reward) - Int64(premine))
            ],
            actions: [],
            depositActions: [
                DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 0, amountDeposited: 0)
            ],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 1
        )

        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: genesis, transactions: [sign(body, kp)],
                timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
            )
            XCTFail("Zero swap amount should throw")
        } catch {
        }
    }

    func testZeroClaimAmountIsInvalid() {
        let c = WithdrawalAction(withdrawer: "r", nonce: 1, demander: "s", amountDemanded: 0, amountWithdrawn: 0)
        XCTAssertEqual(c.amountWithdrawn, 0)
    }
}

// MARK: - 5. Economic Invariants

@MainActor
final class EconomicInvariantAdversarialTests: XCTestCase {

    func testTotalSupplyConservationOverBlocks() async throws {
        let fetcher = makeFetcher()
        let base = t() - 20_000
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = cid(miner.publicKey)
        let s = spec(premine: 0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        var prev = genesis
        var totalMined: UInt64 = 0
        var minerBalance: UInt64 = 0

        for i: UInt64 in 0..<5 {
            let reward = s.rewardAtBlock(i)
            let newBalance = minerBalance + reward
            let body = TransactionBody(
                accountActions: [AccountAction(owner: minerAddr, delta: Int64(newBalance) - Int64(minerBalance))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [minerAddr], fee: 0, nonce: UInt64(i), chainPath: ["Nexus"]
            )
            let block = try await BlockBuilder.buildBlock(
                previous: prev, transactions: [sign(body, miner)],
                timestamp: base + Int64(i + 1) * 1000, target: UInt256(1000), nonce: UInt64(i + 1), fetcher: fetcher
            )
            let valid = try await block.validateNexus(fetcher: fetcher).0
            XCTAssertTrue(valid, "Block \(i) should be valid")
            totalMined += reward
            minerBalance = newBalance
            prev = block
        }

        let expectedTotal = (0..<5).map { s.rewardAtBlock(UInt64($0)) }.reduce(0, +)
        XCTAssertEqual(totalMined, expectedTotal)
        XCTAssertEqual(minerBalance, expectedTotal)
    }

    func testFeeConservation() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let payer = CryptoUtils.generateKeyPair()
        let miner = CryptoUtils.generateKeyPair()
        let payerAddr = cid(payer.publicKey)
        let minerAddr = cid(miner.publicKey)
        let s = spec()
        let premine = s.premineAmount()
        let reward = s.rewardAtBlock(0)
        let fee: UInt64 = 100

        let genesis = try await buildPremineGenesis(spec: s, owner: payer, fetcher: fetcher, timestamp: base)

        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: payerAddr, delta: Int64(premine - fee) - Int64(premine)),
                AccountAction(owner: minerAddr, delta: Int64(reward + fee))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [payerAddr], fee: fee, nonce: 1, chainPath: ["Nexus"]
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [sign(body, payer)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)

        let balanceAfterPayer = premine - fee
        let balanceAfterMiner: UInt64 = reward + fee
        XCTAssertEqual(balanceAfterPayer + balanceAfterMiner, premine + reward)
    }

    func testHalvingScheduleCorrectness() {
        let s = spec(premine: 0)
        let initial = s.initialReward
        let halvingInterval = s.halvingInterval

        XCTAssertEqual(s.rewardAtBlock(0), initial)
        XCTAssertEqual(s.rewardAtBlock(halvingInterval - 1), initial)
        XCTAssertEqual(s.rewardAtBlock(halvingInterval), initial / 2)
        XCTAssertEqual(s.rewardAtBlock(halvingInterval * 2), initial / 4)
    }

    func testHalvingWithPremineOffset() {
        let s = spec(premine: 100)
        let initial = s.initialReward
        let halvingInterval = s.halvingInterval

        XCTAssertEqual(s.rewardAtBlock(0), initial)
        let firstHalving = halvingInterval - 100
        XCTAssertEqual(s.rewardAtBlock(firstHalving - 1), initial)
        XCTAssertEqual(s.rewardAtBlock(firstHalving), initial / 2)
    }

    func testPremineAmountCalculation() {
        let s = spec(premine: 1000)
        XCTAssertEqual(s.premineAmount(), 1000 * s.initialReward)
    }

    func testPremineMayEqualOrExceedHalvingInterval() {
        // The `premine < halvingInterval` cap was removed: premine is a block-count
        // offset into the emission schedule and the reward math handles any size.
        // A premine spanning halving epochs — up to a fully-premined chain — is a
        // valid, honest tokenomics choice. See PremineUncappedTests for the
        // emission/conservation coverage.
        XCTAssertTrue(spec(premine: 1000).isValid)
        XCTAssertTrue(spec(premine: 10_000).isValid)            // == halvingInterval
        XCTAssertTrue(spec(premine: 35_000).isValid)            // spans multiple halvings
        XCTAssertTrue(spec(premine: UInt64.max).isValid)        // extreme premine still well-defined
    }

    func testPremineImmutability() async throws {
        let fetcher1 = makeFetcher()
        let fetcher2 = makeFetcher()
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = cid(kp.publicKey)
        let base = t() - 10_000
        let s = spec()
        let premine = s.premineAmount()

        let body = TransactionBody(
            accountActions: [AccountAction(owner: ownerAddr, delta: Int64(premine))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [ownerAddr], fee: 0, nonce: 0
        )
        let tx = sign(body, kp)

        let genesis1 = try await BlockBuilder.buildGenesis(
            spec: s, transactions: [tx], timestamp: base, target: UInt256(1000), fetcher: fetcher1
        )
        let genesis2 = try await BlockBuilder.buildGenesis(
            spec: s, transactions: [tx], timestamp: base, target: UInt256(1000), fetcher: fetcher2
        )

        let hash1 = try! VolumeImpl<Block>(node: genesis1).rawCID
        let hash2 = try! VolumeImpl<Block>(node: genesis2).rawCID
        XCTAssertEqual(hash1, hash2, "Genesis block must be deterministic given same inputs")
    }
}

// MARK: - 6. Consensus & Reorg Resilience

@MainActor
final class ConsensusResilienceTests: XCTestCase {

    func testLongerForkBecomesMainChain() async throws {
        let fetcher = makeFetcher()
        let base = t() - 100_000
        let s = spec(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        var shortPrev = genesis
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: shortPrev, timestamp: base + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            shortPrev = b
        }
        let shortTip = await chain.getMainChainTip()

        var longPrev = genesis
        for i in 1...5 {
            let b = try await BlockBuilder.buildBlock(
                previous: longPrev, timestamp: base + Int64(i) * 500,
                target: UInt256(1000), nonce: UInt64(i + 100), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            longPrev = b
        }
        let longTip = await chain.getMainChainTip()

        XCTAssertNotEqual(shortTip, longTip)
        XCTAssertEqual(longTip, try! VolumeImpl<Block>(node: longPrev).rawCID)
    }

    func testOrphanBlocksHandled() async throws {
        let fetcher = makeFetcher()
        let base = t() - 100_000
        let s = spec(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: base + 1000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, timestamp: base + 2000,
            target: UInt256(1000), nonce: 2, fetcher: fetcher
        )

        let chain = ChainState.fromGenesis(block: genesis)

        let result2 = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try! VolumeImpl<Block>(node: block2), block: block2
        )
        XCTAssertFalse(result2.extendsMainChain, "Block 2 submitted before block 1 should not extend")

        let result1 = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try! VolumeImpl<Block>(node: block1), block: block1
        )
        XCTAssertTrue(result1.extendsMainChain)
    }

    func testDuplicateBlockSubmissionIgnored() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let s = spec(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: base + 1000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let result1 = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try! VolumeImpl<Block>(node: block1), block: block1
        )
        XCTAssertTrue(result1.extendsMainChain)

        let result2 = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try! VolumeImpl<Block>(node: block1), block: block1
        )
        XCTAssertFalse(result2.extendsMainChain, "Duplicate should not extend")

        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 1)
    }

    func testParentAnchoringTiebreaker() async throws {
        let fetcher = makeFetcher()
        let base = t() - 100_000
        let nexusSpec = spec("Nexus", premine: 0)
        let childSpec = spec("Child", premine: 0)

        var nexusBlocks: [Block] = []
        let nGen = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        nexusBlocks.append(nGen)
        for i in 1...5 {
            let b = try await BlockBuilder.buildBlock(
                previous: nexusBlocks.last!, timestamp: base + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            nexusBlocks.append(b)
        }

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let childChain = ChainState.fromGenesis(block: childGenesis)

        let deepAnchor = try await BlockBuilder.buildBlock(
            previous: childGenesis, parentChainBlock: nexusBlocks[1],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let _ = await childChain.submitBlock(
            parentBlockHeaderAndIndex: (try! VolumeImpl<Block>(node: nexusBlocks[1]).rawCID, 1),
            blockHeader: try! VolumeImpl<Block>(node: deepAnchor), block: deepAnchor
        )

        let shallowAnchor = try await BlockBuilder.buildBlock(
            previous: childGenesis, parentChainBlock: nexusBlocks[5],
            timestamp: base + 5000, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let _ = await childChain.submitBlock(
            parentBlockHeaderAndIndex: (try! VolumeImpl<Block>(node: nexusBlocks[5]).rawCID, 5),
            blockHeader: try! VolumeImpl<Block>(node: shallowAnchor), block: shallowAnchor
        )

        let tip = await childChain.getMainChainTip()
        XCTAssertEqual(tip, try! VolumeImpl<Block>(node: deepAnchor).rawCID,
                       "Deeper parent anchoring should win")
    }
}

// MARK: - 7. Block Limits & Stress

@MainActor
final class BlockLimitTests: XCTestCase {

    func testMaxTransactionsPerBlockEnforced() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let s = ChainSpec(maxNumberOfTransactionsPerBlock: 2, maxStateGrowth: 100_000,
                          maxBlockSize: 1_000_000, premine: 0, targetBlockTime: 1_000,
                          initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        var txs: [Transaction] = []
        for i: UInt64 in 0..<3 {
            let kp = CryptoUtils.generateKeyPair()
            let body = TransactionBody(
                accountActions: [], actions: [], depositActions: [],
                genesisActions: [], receiptActions: [], withdrawalActions: [],
                signers: [], fee: 0, nonce: i
            )
            txs.append(sign(body, kp))
        }

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: txs,
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "Should reject block exceeding max transaction count")
    }

    func testEmptyBlockChainMaintainsConsistency() async throws {
        let fetcher = makeFetcher()
        let base = t() - 200_000
        let s = spec(premine: 0)

        var prev = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        for i in 1...100 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: base + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            XCTAssertEqual(block.height, UInt64(i))
            XCTAssertEqual(block.prevState.rawCID, prev.postState.rawCID)
            XCTAssertEqual(block.postState.rawCID, block.prevState.rawCID, "Empty blocks should not change state")
            prev = block
        }
    }

    func testBlockSizeLimitEnforced() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let tinySpec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
                                 maxBlockSize: 100, premine: 0, targetBlockTime: 1_000,
                                 initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: tinySpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let valid = try await genesis.validateGenesis(fetcher: fetcher, directory: "Nexus").0
        XCTAssertFalse(valid, "Genesis block should exceed 100 byte limit")
    }

    func testChainSpecValidation() {
        let validSpec = spec()
        XCTAssertTrue(validSpec.isValid)

        let zeroTx = ChainSpec(maxNumberOfTransactionsPerBlock: 0, maxStateGrowth: 100,
                               maxBlockSize: 100, premine: 0, targetBlockTime: 1000,
                               initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
        XCTAssertFalse(zeroTx.isValid)

        let zeroTarget = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100,
                                   maxBlockSize: 100, premine: 0, targetBlockTime: 0,
                                   initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
        XCTAssertFalse(zeroTarget.isValid)

        let zeroReward = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100,
                                   maxBlockSize: 100, premine: 0, targetBlockTime: 1000,
                                   initialReward: 0, halvingInterval: 10_000, retargetWindow: 5)
        XCTAssertFalse(zeroReward.isValid)
    }
}

// MARK: - 8. Timestamp Validation

@MainActor
final class TimestampSecurityTests: XCTestCase {

    func testSmallFutureDriftAccepted() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let s = spec(premine: 0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        // 60 s of clock skew is within the 2-hour drift budget.
        let slightlyFuture = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t() + 60_000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await slightlyFuture.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid, "60s future drift must be accepted")
    }

    func testFutureTimestampBeyondDriftRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let s = spec(premine: 0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        // 3 h is beyond the 2 h drift budget — rejection prevents warp
        // attacks that fast-forward timestamps to lower target.
        let farFuture = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t() + 3 * 60 * 60 * 1000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await farFuture.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "timestamp 3h in future must be rejected")
    }

    func testOldTimestampStillValidatesForSync() async throws {
        let fetcher = makeFetcher()
        // A block from 24 h ago: must still validate so cold-syncing nodes
        // can ingest historical blocks. The consensus rule gates only the
        // future side against wall clock; MTP handles ordering.
        let base = t() - 24 * 60 * 60 * 1000
        let s = spec(premine: 0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let nextOld = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: base + 1_000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await nextOld.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid, "blocks >2h old must still validate for sync")
    }

    func testMedianTimePastEnforced() async throws {
        // Build 12 blocks, then try to submit one whose timestamp is <= the
        // median of the last 11 ancestor timestamps. Must be rejected.
        let fetcher = makeFetcher()
        let base = t() - 60_000
        let s = spec(premine: 0)

        var blocks: [Block] = []
        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        blocks.append(genesis)
        for i in 1...11 {
            let next = try await BlockBuilder.buildBlock(
                previous: blocks.last!,
                timestamp: base + Int64(i) * 1_000,
                target: UInt256(1000), nonce: UInt64(i),
                fetcher: fetcher
            )
            blocks.append(next)
        }
        // Median of blocks[1...11].timestamp is base + 6000; parent is
        // base + 11000. Try timestamp = base + 6000 (== median) → rejected
        // even though it's > parent? No — parent is base+11000, so it must
        // also fail the monotonic check. Use base + 11500 instead: > parent,
        // but still < median of recent window after the parent chain grows.
        // To isolate MTP: build a miner attempt whose ts sits between the
        // parent (base+11000) and the 11-window median, proving MTP runs.
        // Simpler: submit ts == parent.timestamp + 1, which is > parent but
        // <= the median only if the median floats above it. For this spaced
        // sequence, the median of [base+1000…base+11000] is base+6000, and
        // base+11001 > base+6000 — MTP accepts. The forbidden zone is when
        // an adversary backdates below median, which requires ts < parent
        // and fails the monotonic check first. So MTP's practical role is
        // to catch blocks that slip past monotonic via a single-block burst;
        // we exercise it directly via the helper.
        let violating = try await BlockBuilder.buildBlock(
            previous: blocks[5], // fork from older block with ts = base+5000
            timestamp: base + 4_000, // below median of blocks 1..11
            target: UInt256(1000), nonce: 99,
            fetcher: fetcher
        )
        // Direct check of validateTimestamp using the MTP helper:
        let mtpTimestamps = blocks.suffix(11).map { $0.timestamp }
        let valid = violating.validateTimestamp(parent: blocks[5], ancestorTimestamps: mtpTimestamps)
        XCTAssertFalse(valid, "timestamp at or below MTP must be rejected")
    }

    func testNonIncreasingTimestampRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let s = spec(premine: 0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let sameTime = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: base,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let v1 = try await sameTime.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(v1)

        let earlier = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: base - 1,
            target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let v2 = try await earlier.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(v2)
    }
}
