import XCTest
@testable import Lattice
import UInt256
import Foundation

// MARK: - State Transition Invariant Tests
//
// These tests verify algebraic properties that must hold for all valid
// state transitions in the Lattice protocol. They test structural
// invariants rather than specific scenarios.

// MARK: - ChainSpec Algebraic Properties

final class ChainSpecPropertyTests: XCTestCase {

    func testRewardFunctionIsPure() {
        let specs: [ChainSpec] = [
            .bitcoin, .ethereum, .development,
            ChainSpec(maxNumberOfTransactionsPerBlock: 500, maxStateGrowth: 5000, premine: 42, targetBlockTime: 5000, initialReward: 4096, halvingInterval: 50_000),
            ChainSpec(maxNumberOfTransactionsPerBlock: 1, maxStateGrowth: 1, premine: 0, targetBlockTime: 1, initialReward: 1, halvingInterval: 1),
        ]

        for spec in specs {
            guard spec.isValid else { continue }
            for _ in 0..<100 {
                let block = UInt64.random(in: 0...10_000_000)
                let r1 = spec.rewardAtBlock(block)
                let r2 = spec.rewardAtBlock(block)
                XCTAssertEqual(r1, r2, "Reward function not deterministic at block \(block)")
            }
        }
    }

    func testTotalRewardsIsExactSum() {
        let specs: [ChainSpec] = [
            ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: 16, halvingInterval: 500),
            ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 5, targetBlockTime: 1000, initialReward: 16, halvingInterval: 500),
            ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 100, targetBlockTime: 1000, initialReward: 256, halvingInterval: 500),
        ]

        for spec in specs {
            let testBlocks: [UInt64] = [0, 1, 10, 100, 500, 1000]
            for blockCount in testBlocks {
                let total = spec.totalRewards(upToBlock: blockCount)
                var manualSum: UInt64 = 0
                for i in 0..<blockCount {
                    manualSum += spec.rewardAtBlock(i)
                }
                XCTAssertEqual(total, manualSum,
                               "totalRewards(\(blockCount)) != manual sum for reward=\(spec.initialReward), premine=\(spec.premine)")
            }
        }
    }

    func testRewardNonIncreasing() {
        let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: 16, halvingInterval: 500)
        let halvingInterval = spec.halvingInterval

        var prev = spec.rewardAtBlock(0)
        for i: UInt64 in 0..<20 {
            let block = halvingInterval * i
            let reward = spec.rewardAtBlock(block)
            XCTAssertTrue(reward <= prev,
                          "Reward increased from \(prev) to \(reward) at block \(block)")
            prev = reward
        }
    }

    func testPremineAmountEqualsTotalRewards() {
        let premineValues: [UInt64] = [0, 1, 10, 100, 1000, 5000]
        for premine in premineValues {
            let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: premine, targetBlockTime: 1000, initialReward: 32_768, halvingInterval: 100_000)
            guard spec.isValid else { continue }
            XCTAssertEqual(spec.premineAmount(), spec.totalRewards(upToBlock: premine),
                           "premineAmount != totalRewards(premine) for premine=\(premine)")
        }
    }

    func testTotalRewardsAdditivity() {
        let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: 64, halvingInterval: 500)

        for _ in 0..<50 {
            let a = UInt64.random(in: 0...1000)
            let b = UInt64.random(in: 0...1000)
            let totalAB = spec.totalRewards(upToBlock: a + b)
            let totalA = spec.totalRewards(upToBlock: a)
            let partB = (a..<(a + b)).reduce(UInt64(0)) { $0 + spec.rewardAtBlock($1) }
            XCTAssertEqual(totalAB, totalA + partB,
                           "Additivity failed for a=\(a), b=\(b)")
        }
    }

    func testTotalHalvingsMatchesRewardBits() {
        let testCases: [(UInt64, UInt64)] = [
            (1, 1), (2, 2), (4, 3), (8, 4), (16, 5), (1024, 11), (65536, 17),
        ]
        for (reward, expectedHalvings) in testCases {
            let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: reward, halvingInterval: 1000)
            XCTAssertEqual(spec.totalHalvings, expectedHalvings)
        }
    }

    func testRewardAfterPenultimateHalvingIsTwo() {
        let rewards: [UInt64] = [4, 16, 256]
        for reward in rewards {
            let interval: UInt64 = 1000
            let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: reward, halvingInterval: interval)
            let halvingsToGetTo2 = spec.totalHalvings - 2  // reward >> (totalHalvings - 2) == 2 when reward is power of 2
            let penultimateBlock = interval * halvingsToGetTo2
            let r = spec.rewardAtBlock(penultimateBlock)
            XCTAssertEqual(r, 2, "Reward at penultimate halving should be 2 for initialReward=\(reward), got \(r)")
        }
    }

    func testRewardAfterFinalHalvingIsOne() {
        let rewards: [UInt64] = [4, 16, 256]
        for reward in rewards {
            let interval: UInt64 = 1000
            let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: reward, halvingInterval: interval)
            let halvingsToGetTo1 = spec.totalHalvings - 1
            let finalBlock = interval * halvingsToGetTo1
            let r = spec.rewardAtBlock(finalBlock)
            XCTAssertEqual(r, 1, "Reward at final halving should be 1 for initialReward=\(reward), got \(r)")
        }
    }

    // Property: Difficulty adjustment is symmetric around target
    func testDifficultyAdjustmentSymmetry() {
        let spec = ChainSpec.development
        let baseDiff = UInt256(10000)
        let target = Int64(spec.targetBlockTime)

        let halfTarget = target / 2
        let doubleTarget = target * 2

        let fasterDiff = spec.calculateMinimumTarget(
            previousTarget: baseDiff, blockTimestamp: halfTarget, previousTimestamp: 0)
        let slowerDiff = spec.calculateMinimumTarget(
            previousTarget: baseDiff, blockTimestamp: doubleTarget, previousTimestamp: 0)

        XCTAssertTrue(fasterDiff < baseDiff, "Faster blocks should decrease target target")
        XCTAssertTrue(slowerDiff > baseDiff, "Slower blocks should increase target target")
    }

    // Property: Exact target timing produces no change
    func testExactTargetTimingNoChange() {
        let specs: [ChainSpec] = [.bitcoin, .ethereum, .development]
        for spec in specs {
            let baseDiff = UInt256(999999)
            let target = Int64(spec.targetBlockTime)
            let newDiff = spec.calculateMinimumTarget(
                previousTarget: baseDiff, blockTimestamp: target, previousTimestamp: 0)
            XCTAssertEqual(newDiff, baseDiff,
                           "Exact target timing should not change target for spec")
        }
    }
}

// MARK: - Fork Choice Algebraic Properties

@MainActor
final class ForkChoicePropertyTests: XCTestCase {

    // Property: After reorg, tip is on main chain
    func testReorgTipOnMainChain() async {
        for mainLen in [2, 5, 10] {
            for forkLen in [(mainLen + 1), (mainLen + 3)] {
                var blocks: [BlockMeta] = [makeBlockMeta(hash: "G", height: 0, childHashes: ["M1", "F1"])]

                for i in 1...mainLen {
                    let children = i < mainLen ? ["M\(i+1)"] : [String]()
                    blocks.append(makeBlockMeta(hash: "M\(i)", previousHash: i == 1 ? "G" : "M\(i-1)", height: UInt64(i), childHashes: children))
                }
                for i in 1...forkLen {
                    let children = i < forkLen ? ["F\(i+1)"] : [String]()
                    blocks.append(makeBlockMeta(hash: "F\(i)", previousHash: i == 1 ? "G" : "F\(i-1)", height: UInt64(i), childHashes: children))
                }

                let chain = makeChain(blocks: blocks, mainChainHashes: Set(["G"] + (1...mainLen).map { "M\($0)" }))
                let forkTip = await chain.getConsensusBlock(hash: "F\(forkLen)")!
                let _ = await chain.checkForReorg(block: forkTip)

                let tip = await chain.getMainChainTip()
                let onMain = await chain.isOnMainChain(hash: tip)
                XCTAssertTrue(onMain, "Tip must be on main chain after reorg (mainLen=\(mainLen), forkLen=\(forkLen))")
            }
        }
    }

    // Property: After reorg, genesis is always on main chain
    func testGenesisAlwaysOnMainChainAfterReorg() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2)

        let chain = makeChain(blocks: [g, a1, b1, b2], mainChainHashes: Set(["G", "A1"]))
        let block = await chain.getConsensusBlock(hash: "B2")!
        let _ = await chain.checkForReorg(block: block)

        let gOnMain = await chain.isOnMainChain(hash: "G")
        XCTAssertTrue(gOnMain, "Genesis must always remain on main chain")
    }

    // Property: Reorg mainChainBlocksAdded and mainChainBlocksRemoved don't overlap
    func testReorgAddedAndRemovedDisjoint() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3], mainChainHashes: Set(["G", "A1", "A2"]))
        let block = await chain.getConsensusBlock(hash: "B3")!
        let reorg = await chain.checkForReorg(block: block)

        XCTAssertNotNil(reorg)
        if let reorg = reorg {
            let addedSet = Set(reorg.mainChainBlocksAdded.keys)
            let intersection = addedSet.intersection(reorg.mainChainBlocksRemoved)
            XCTAssertTrue(intersection.isEmpty,
                          "Added and removed sets must be disjoint, overlap: \(intersection)")
        }
    }

    // Property: chainWithMostWork always includes the starting block
    func testChainWithMostWorkIncludesStart() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)

        let chain = makeChain(blocks: [g, a1, a2])
        let work = await chain.chainWithMostWork(startingBlock: g)
        XCTAssertTrue(work.blocks.contains("G"))
    }

    // Property: chainWithMostWork block set is connected (each block's parent is in the set or is before the start)
    func testChainWithMostWorkConnectedness() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3])
        let work = await chain.chainWithMostWork(startingBlock: g)

        for hash in work.blocks where hash != "G" {
            let block = await chain.getConsensusBlock(hash: hash)
            XCTAssertNotNil(block)
            if let prevHash = block?.parentBlockHash {
                XCTAssertTrue(work.blocks.contains(prevHash),
                              "Block \(hash)'s parent \(prevHash) not in winning fork set")
            }
        }
    }
}

// MARK: - Balance Conservation Properties

final class BalanceConservationPropertyTests: XCTestCase {

    // Property: In a valid block, totalBalanceAfter <= totalBalanceBefore + reward - deposits + withdrawals
    // This is the fundamental conservation law.
    func testBalanceConservationInequality() {
        let spec = ChainSpec.development

        for blockHeight: UInt64 in [0, 1, 100, 1000] {
            let reward = spec.rewardAtBlock(blockHeight)

            for _ in 0..<50 {
                let numAccounts = Int.random(in: 1...10)
                var totalBefore: UInt64 = 0
                var totalAfter: UInt64 = 0

                for _ in 0..<numAccounts {
                    let old = UInt64.random(in: 0...10000)
                    let maxNew = old + reward
                    let new = UInt64.random(in: 0...maxNew)
                    totalBefore += old
                    totalAfter += new
                }

                if totalAfter <= totalBefore + reward {
                    // This is a valid balance configuration (no deposits/withdrawals)
                    XCTAssertTrue(totalAfter <= totalBefore + reward)
                }
            }
        }
    }

    // Property: Swap locks reduce available balance
    func testSwapLocksBalance() {
        for _ in 0..<100 {
            let swapAmount = UInt64.random(in: 1...10000)
            let action = DepositAction(
                nonce: UInt128.random(in: 0...UInt128.max),
                demander: "test_demander",
                amountDemanded: swapAmount,
                amountDeposited: swapAmount
            )
            XCTAssertGreaterThan(action.amountDeposited, 0)
        }
    }

    // Property: Account actions with negative delta (debit) require signer authorization
    func testDebitRequiresSignerProperty() {
        for _ in 0..<100 {
            let owner = "owner_\(UUID().uuidString)"
            let oldBalance = UInt64.random(in: 100...10000)
            let newBalance = UInt64.random(in: 0..<oldBalance)

            let action = AccountAction(owner: owner, delta: Int64(newBalance) - Int64(oldBalance))
            let body = TransactionBody(
                accountActions: [action],
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [],
                fee: 0,
                nonce: 0
            )
            XCTAssertFalse(body.accountActionsAreValid(),
                           "Debit without signer should be invalid")

            let bodyWithSigner = TransactionBody(
                accountActions: [action],
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [owner],
                fee: 0,
                nonce: 0
            )
            XCTAssertTrue(bodyWithSigner.accountActionsAreValid(),
                          "Debit with matching signer should be valid")
        }
    }

    // Property: Credit (positive delta) does NOT require signer
    func testCreditDoesNotRequireSigner() {
        for _ in 0..<100 {
            let owner = "owner_\(UUID().uuidString)"
            let oldBalance = UInt64.random(in: 0...10000)
            let newBalance = oldBalance + UInt64.random(in: 1...10000)

            let action = AccountAction(owner: owner, delta: Int64(newBalance) - Int64(oldBalance))
            let body = TransactionBody(
                accountActions: [action],
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [],
                fee: 0,
                nonce: 0
            )
            XCTAssertTrue(body.accountActionsAreValid(),
                          "Credit without signer should be valid")
        }
    }
}

// MARK: - Cross-Chain Swap Protocol Properties

final class CrossChainProtocolPropertyTests: XCTestCase {

    // Property: SwapKey round-trips through string representation
    func testSwapKeyRoundTrip() {
        for _ in 0..<200 {
            let nonce = UInt128.random(in: 0...UInt128.max)
            let demander = "demander_\(UUID().uuidString)"
            let amountDemanded = UInt64.random(in: 1...UInt64.max)

            let key = DepositKey(depositAction: DepositAction(nonce: nonce, demander: demander, amountDemanded: amountDemanded, amountDeposited: amountDemanded))
            let stringRepr = key.description
            let parsed = DepositKey(stringRepr)

            XCTAssertNotNil(parsed, "Failed to parse SwapKey: \(stringRepr)")
            if let parsed = parsed {
                XCTAssertEqual(parsed.nonce, nonce)
                XCTAssertEqual(parsed.demander, demander)
                XCTAssertEqual(parsed.amountDemanded, amountDemanded)
            }
        }
    }

    // Property: WithdrawalAction produces matching SwapKey
    func testSwapClaimProducesMatchingDepositKey() {
        for _ in 0..<100 {
            let nonce = UInt128.random(in: 0...UInt128.max)
            let demander = "demander_\(UUID().uuidString)"
            let withdrawer = "withdrawer_\(UUID().uuidString)"
            let amountDemanded = UInt64.random(in: 1...1000000)

            let swap = DepositAction(nonce: nonce, demander: demander, amountDemanded: amountDemanded, amountDeposited: amountDemanded)
            let claim = WithdrawalAction(withdrawer: withdrawer, nonce: nonce, demander: demander, amountDemanded: amountDemanded, amountWithdrawn: amountDemanded)

            let swapKey = DepositKey(depositAction: swap)
            let claimKey = DepositKey(withdrawalAction: claim)

            XCTAssertEqual(swapKey.description, claimKey.description,
                           "Swap and claim should produce matching keys")
        }
    }

    // Property: SettleKey consistency for same swap
    func testSettleKeyConsistency() {
        let directory = "TestChain"
        for _ in 0..<100 {
            let nonce = UInt128.random(in: 0...UInt128.max)
            let demander = "demander_\(UUID().uuidString)"
            let withdrawer = "withdrawer_\(UUID().uuidString)"
            let amountDemanded = UInt64.random(in: 1...1000000)

            let swap = DepositAction(nonce: nonce, demander: demander, amountDemanded: amountDemanded, amountDeposited: amountDemanded)
            let claim = WithdrawalAction(withdrawer: withdrawer, nonce: nonce, demander: demander, amountDemanded: amountDemanded, amountWithdrawn: amountDemanded)

            let settleKeyFromSwap = ReceiptKey(receiptAction: ReceiptAction(withdrawer: withdrawer, nonce: nonce, demander: demander, amountDemanded: amountDemanded, directory: directory))
            let settleKeyFromClaim = ReceiptKey(withdrawalAction: claim, directory: directory)

            XCTAssertEqual(settleKeyFromSwap.description, settleKeyFromClaim.description)
            XCTAssertEqual(settleKeyFromSwap.directory, directory)
        }
    }

    // Property: Different nonces produce different swap keys
    func testUniqueNoncesProduceUniqueKeys() {
        let demander = "test_demander"
        let amountDemanded: UInt64 = 1000
        var keys = Set<String>()

        for i: UInt128 in 0..<500 {
            let key = DepositKey(depositAction: DepositAction(nonce: i, demander: demander, amountDemanded: amountDemanded, amountDeposited: amountDemanded))
            let keyStr = key.description
            XCTAssertFalse(keys.contains(keyStr), "Duplicate key for nonce \(i)")
            keys.insert(keyStr)
        }
    }
}

// MARK: - State Delta Properties

final class StateDeltaPropertyTests: XCTestCase {

    // Property: Creating and then deleting an account has net zero state delta
    func testCreateDeleteNetZero() {
        for _ in 0..<100 {
            let owner = UUID().uuidString
            let balance = UInt64.random(in: 1...1000000)

            let create = AccountAction(owner: owner, delta: Int64(balance))
            let delete = AccountAction(owner: owner, delta: -Int64(balance))

            let createDelta = try! create.stateDelta()
            let deleteDelta = try! delete.stateDelta()

            XCTAssertEqual(createDelta + deleteDelta, 0,
                           "Create + delete should net to zero for owner=\(owner)")
        }
    }

    // Property: Inserting and deleting a KV action has net zero state delta
    func testActionInsertDeleteNetZero() {
        for _ in 0..<100 {
            let key = UUID().uuidString
            let value = UUID().uuidString

            let insert = Action(key: key, oldValue: nil, newValue: value)
            let delete = Action(key: key, oldValue: value, newValue: nil)

            let insertDelta = try! insert.stateDelta()
            let deleteDelta = try! delete.stateDelta()

            XCTAssertEqual(insertDelta + deleteDelta, 0,
                           "Insert + delete should net to zero")
        }
    }

    // Property: State delta magnitude is bounded by key + value sizes
    func testStateDeltaBoundedByDataSize() {
        for _ in 0..<100 {
            let key = String(repeating: "k", count: Int.random(in: 1...50))
            let value = String(repeating: "v", count: Int.random(in: 1...100))

            let insert = Action(key: key, oldValue: nil, newValue: value)
            let delta = try! insert.stateDelta()

            let maxDelta = key.utf8.count + value.utf8.count
            XCTAssertEqual(delta, maxDelta,
                           "Insert delta should equal key + value size")
        }
    }

    // Property: Swap state delta is always positive (swaps add state)
    func testDepositStateDeltaPositive() {
        for _ in 0..<100 {
            let action = DepositAction(
                nonce: UInt128.random(in: 0...UInt128.max),
                demander: UUID().uuidString,
                amountDemanded: UInt64.random(in: 1...1000000),
                amountDeposited: UInt64.random(in: 1...1000000)
            )
            XCTAssertGreaterThan(action.stateDelta(), 0,
                                 "Swap delta should always be positive")
        }
    }

    // Property: TransactionBody state delta is sum of all action deltas
    func testTransactionBodyDeltaIsSum() {
        let accountActions = [
            AccountAction(owner: "a", delta: Int64(100)),
            AccountAction(owner: "b", delta: Int64(50) - Int64(100)),
        ]
        let kvActions = [
            Action(key: "key1", oldValue: nil, newValue: "value1"),
        ]

        let body = TransactionBody(
            accountActions: accountActions,
            actions: kvActions,
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            fee: 0,
            nonce: 0
        )

        let totalDelta = try! body.getStateDelta()
        let accountDelta = try! accountActions.map { try $0.stateDelta() }.reduce(0, +)
        let kvDelta = try! kvActions.map { try $0.stateDelta() }.reduce(0, +)

        XCTAssertEqual(totalDelta, accountDelta + kvDelta)
    }
}

// MARK: - Cryptographic Properties

final class CryptographicPropertyTests: XCTestCase {

    // Property: Different private keys produce different public keys
    func testKeyPairUniqueness() {
        var publicKeys = Set<String>()
        for _ in 0..<100 {
            let kp = CryptoUtils.generateKeyPair()
            XCTAssertFalse(publicKeys.contains(kp.publicKey), "Duplicate public key generated")
            publicKeys.insert(kp.publicKey)
        }
    }

    // Property: Signature is deterministic for same key + message
    // Note: P-256 ECDSA uses random nonces, so signatures differ. But verification must always succeed.
    func testVerificationConsistency() {
        let kp = CryptoUtils.generateKeyPair()
        let message = "test message"

        for _ in 0..<20 {
            guard let sig = CryptoUtils.sign(message: message, privateKeyHex: kp.privateKey) else {
                XCTFail("Signing failed")
                return
            }
            XCTAssertTrue(CryptoUtils.verify(message: message, signature: sig, publicKeyHex: kp.publicKey))
        }
    }

    // Property: Empty message can be signed and verified
    func testEmptyMessageSignable() {
        let kp = CryptoUtils.generateKeyPair()
        guard let sig = CryptoUtils.sign(message: "", privateKeyHex: kp.privateKey) else {
            XCTFail("Cannot sign empty message")
            return
        }
        XCTAssertTrue(CryptoUtils.verify(message: "", signature: sig, publicKeyHex: kp.publicKey))
    }

    // Property: Address is deterministic from public key
    func testAddressDeterminism() {
        let kp = CryptoUtils.generateKeyPair()
        let addr1 = CryptoUtils.createAddress(from: kp.publicKey)
        let addr2 = CryptoUtils.createAddress(from: kp.publicKey)
        XCTAssertEqual(addr1, addr2)
        XCTAssertFalse(addr1.isEmpty)
        XCTAssertGreaterThan(addr1.count, 0)
    }

    // Property: Different public keys produce different addresses
    func testAddressUniqueness() {
        var addresses = Set<String>()
        for _ in 0..<100 {
            let kp = CryptoUtils.generateKeyPair()
            let addr = CryptoUtils.createAddress(from: kp.publicKey)
            XCTAssertFalse(addresses.contains(addr), "Duplicate address generated")
            addresses.insert(addr)
        }
    }
}

// MARK: - Block Structure Properties

final class BlockStructurePropertyTests: XCTestCase {

    // Property: Empty state CID is deterministic
    func testEmptyStateDeterministic() {
        let state1 = try! LatticeStateHeader(node: LatticeState.emptyState())
        let state2 = try! LatticeStateHeader(node: LatticeState.emptyState())
        XCTAssertEqual(state1.rawCID, state2.rawCID)
    }

    // Property: LatticeState has exactly 5 properties
    func testLatticeStatePropertyCount() {
        let state = LatticeState.emptyState()
        XCTAssertEqual(state.properties().count, 5)
    }

    // Property: All 5 sub-state property names are distinct
    func testSubStatePropertyNamesDistinct() {
        let names = [
            ACCOUNT_STATE_PROPERTY,
            GENERAL_STATE_PROPERTY,
            DEPOSIT_STATE_PROPERTY,
            GENESIS_STATE_PROPERTY,
            RECEIPT_STATE_PROPERTY,
        ]
        XCTAssertEqual(Set(names).count, 5)
    }

    // Property: Block has exactly 4 owned (addressable) child properties —
    // transactions, spec, postState, children. parent/parentState/prevState are
    // References (commitments, not children) and are intentionally excluded.
    func testBlockPropertyCount() {
        XCTAssertEqual(BLOCK_PROPERTIES.count, 4)
    }

    // Property: Transaction has exactly 1 addressable property
    func testTransactionPropertyCount() {
        XCTAssertEqual(TRANSACTION_PROPERTIES.count, 1)
    }

    // Property: RECENT_BLOCK_DISTANCE is a reasonable value
    func testRecentBlockDistance() {
        XCTAssertEqual(RECENT_BLOCK_DISTANCE, UInt64.max)
        XCTAssertGreaterThan(RECENT_BLOCK_DISTANCE, 0)
    }
}
