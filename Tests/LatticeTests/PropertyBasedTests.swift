import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256
import cashew
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
            ChainSpec(maxNumberOfTransactionsPerBlock: 500, maxStateGrowth: 5000, premine: 42, targetBlockTime: 5000, initialReward: 4096, halvingInterval: 50_000, halfLife: 10),
            ChainSpec(maxNumberOfTransactionsPerBlock: 1, maxStateGrowth: 1, premine: 0, targetBlockTime: 1, initialReward: 1, halvingInterval: 1, halfLife: 10),
        ]

        let seed = propertySeed()
        var rng = seed.generator()
        for spec in specs {
            guard spec.isValid else {
                XCTFail("fixture spec must be valid, or the property runs on nothing: \(spec)")
                continue
            }
            for _ in 0..<100 {
                let block = UInt64.random(in: 0...10_000_000, using: &rng)
                let r1 = spec.rewardAtBlock(block)
                let r2 = spec.rewardAtBlock(block)
                XCTAssertEqual(r1, r2, "Reward function not deterministic at block \(block) \(seed.note)")
            }
        }
    }

    func testTotalRewardsIsExactSum() {
        let specs: [ChainSpec] = [
            ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: 16, halvingInterval: 500, halfLife: 10),
            ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 5, targetBlockTime: 1000, initialReward: 16, halvingInterval: 500, halfLife: 10),
            ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 100, targetBlockTime: 1000, initialReward: 256, halvingInterval: 500, halfLife: 10),
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
        let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: 16, halvingInterval: 500, halfLife: 10)
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
            let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: premine, targetBlockTime: 1000, initialReward: 32_768, halvingInterval: 100_000, halfLife: 10)
            guard spec.isValid else {
                XCTFail("fixture spec must be valid, or the property runs on nothing: premine=\(premine)")
                continue
            }
            XCTAssertEqual(spec.premineAmount(), spec.totalRewards(upToBlock: premine),
                           "premineAmount != totalRewards(premine) for premine=\(premine)")
        }
    }

    func testTotalRewardsAdditivity() {
        let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: 64, halvingInterval: 500, halfLife: 10)

        let seed = propertySeed()
        var rng = seed.generator()
        for _ in 0..<50 {
            let a = UInt64.random(in: 0...1000, using: &rng)
            let b = UInt64.random(in: 0...1000, using: &rng)
            let totalAB = spec.totalRewards(upToBlock: a + b)
            let totalA = spec.totalRewards(upToBlock: a)
            let partB = (a..<(a + b)).reduce(UInt64(0)) { $0 + spec.rewardAtBlock($1) }
            XCTAssertEqual(totalAB, totalA + partB,
                           "Additivity failed for a=\(a), b=\(b) \(seed.note)")
        }
    }

    func testTotalHalvingsMatchesRewardBits() {
        let testCases: [(UInt64, UInt64)] = [
            (1, 1), (2, 2), (4, 3), (8, 4), (16, 5), (1024, 11), (65536, 17),
        ]
        for (reward, expectedHalvings) in testCases {
            let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: reward, halvingInterval: 1000, halfLife: 10)
            XCTAssertEqual(spec.totalHalvings, expectedHalvings)
        }
    }

    func testRewardAfterPenultimateHalvingIsTwo() {
        let rewards: [UInt64] = [4, 16, 256]
        for reward in rewards {
            let interval: UInt64 = 1000
            let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: reward, halvingInterval: interval, halfLife: 10)
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
            let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: reward, halvingInterval: interval, halfLife: 10)
            let halvingsToGetTo1 = spec.totalHalvings - 1
            let finalBlock = interval * halvingsToGetTo1
            let r = spec.rewardAtBlock(finalBlock)
            XCTAssertEqual(r, 1, "Reward at final halving should be 1 for initialReward=\(reward), got \(r)")
        }
    }

    // Property: the schedule hardens ahead of schedule and eases behind it
    func testDifficultyAdjustmentSymmetry() {
        let spec = ChainSpec.development
        let anchor = UInt256(10000)
        let blockTime = Int64(spec.targetBlockTime)
        func scheduled(at timestamp: Int64) -> UInt256 {
            spec.calculateAsertTarget(
                anchorTarget: anchor, anchorTimestamp: 0, anchorHeight: 1,
                blockTimestamp: timestamp, blockHeight: 2
            )
        }

        XCTAssertTrue(scheduled(at: blockTime / 2) < anchor, "a block ahead of schedule hardens the target")
        XCTAssertTrue(scheduled(at: blockTime * 2) > anchor, "a block behind schedule eases the target")
    }

    // Property: exactly on schedule holds the anchor's target
    func testExactTargetTimingNoChange() {
        let specs: [ChainSpec] = [.bitcoin, .ethereum, .development]
        for spec in specs {
            let anchor = UInt256(999999)
            let onSchedule = spec.calculateAsertTarget(
                anchorTarget: anchor, anchorTimestamp: 0, anchorHeight: 1,
                blockTimestamp: Int64(spec.targetBlockTime), blockHeight: 2
            )
            XCTAssertEqual(onSchedule, anchor, "on schedule holds the anchor's target")
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

                let chain = makeChain(blocks: blocks, canonicalHashes: Set(["G"] + (1...mainLen).map { "M\($0)" }))
                let _ = await chain.reevaluateForkChoice()

                let tip = await chain.canonicalTip
                let onMain = await chain.isCanonical(hash: tip)
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

        let chain = makeChain(blocks: [g, a1, b1, b2], canonicalHashes: Set(["G", "A1"]))
        let _ = await chain.reevaluateForkChoice()

        let gOnMain = await chain.isCanonical(hash: "G")
        XCTAssertTrue(gOnMain, "Genesis must always remain on main chain")
    }

    // Property: Reorg canonicalBlocksAdded and canonicalBlocksRemoved don't overlap
    func testReorgAddedAndRemovedDisjoint() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3], canonicalHashes: Set(["G", "A1", "A2"]))
        let reorg = await chain.reevaluateForkChoice()

        XCTAssertNotNil(reorg)
        if let reorg = reorg {
            let addedSet = Set(reorg.canonicalBlocksAdded.keys)
            let intersection = addedSet.intersection(reorg.canonicalBlocksRemoved)
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

    // Property: the block validator accepts an action set whose credits fit
    // within debits + reward + withdrawals - deposits, and rejects the same set
    // once it mints one unit more than that budget.
    func testBalanceConservationInequality() throws {
        let seed = propertySeed()
        var rng = seed.generator()
        let spec = ChainSpec.development

        for blockHeight: UInt64 in [0, 1, 100, 1000] {
            let block = Block(
                parent: nil,
                transactions: try HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
                target: UInt256(1000), nextTarget: UInt256(1000),
                spec: try VolumeImpl<ChainSpec>(node: spec),
                parentState: try LatticeStateHeader(node: LatticeState.emptyState()).removingNode(),
                prevState: try LatticeStateHeader(node: LatticeState.emptyState()).removingNode(),
                postState: try LatticeStateHeader(node: LatticeState.emptyState()),
                children: try HeaderImpl(node: ChildIndex()),
                height: blockHeight, timestamp: 1_000_000, nonce: 0
            )
            let reward = spec.rewardAtBlock(blockHeight)

            for _ in 0..<50 {
                var accountActions: [AccountAction] = []
                var budget = reward
                for i in 0..<Int.random(in: 0...5, using: &rng) {
                    let debit = UInt64.random(in: 1...10_000, using: &rng)
                    accountActions.append(AccountAction(owner: "sender_\(i)", delta: -Int64(debit)))
                    budget += debit
                }
                var withdrawals: [WithdrawalAction] = []
                for i in 0..<Int.random(in: 0...3, using: &rng) {
                    let amount = UInt64.random(in: 1...10_000, using: &rng)
                    withdrawals.append(WithdrawalAction(
                        withdrawer: "withdrawer_\(i)", nonce: UInt128(i),
                        demander: "demander_\(i)", amountDemanded: amount,
                        amountWithdrawn: amount
                    ))
                    budget += amount
                }
                var deposits: [DepositAction] = []
                for i in 0..<Int.random(in: 0...3, using: &rng) where budget > 0 {
                    let amount = UInt64.random(in: 1...budget, using: &rng)
                    deposits.append(DepositAction(
                        nonce: UInt128(i), demander: "depositor_\(i)",
                        amountDemanded: amount, amountDeposited: amount
                    ))
                    budget -= amount
                }
                // Spend the whole budget half the time, so the boundary is exercised.
                var unspent = Bool.random(using: &rng) ? budget : UInt64.random(in: 0...budget, using: &rng)
                let spend = budget - unspent
                var remaining = spend
                var recipient = 0
                while remaining > 0 {
                    let credit = UInt64.random(in: 1...remaining, using: &rng)
                    accountActions.append(AccountAction(owner: "recipient_\(recipient)", delta: Int64(credit)))
                    remaining -= credit
                    recipient += 1
                }

                XCTAssertTrue(
                    try block.validateBalanceChanges(
                        spec: spec, allDepositActions: deposits,
                        allWithdrawalActions: withdrawals, allAccountActions: accountActions
                    ),
                    "credits \(spend) within budget \(budget) must validate at height \(blockHeight) \(seed.note)"
                )

                unspent += 1
                let minting = accountActions + [AccountAction(owner: "minter", delta: Int64(unspent))]
                XCTAssertFalse(
                    try block.validateBalanceChanges(
                        spec: spec, allDepositActions: deposits,
                        allWithdrawalActions: withdrawals, allAccountActions: minting
                    ),
                    "credits \(budget + 1) over budget \(budget) must be rejected at height \(blockHeight) \(seed.note)"
                )
            }
        }
    }

    // Property: applying a deposit with its funding debit moves exactly the
    // deposited amount from the demander's balance into the deposit record,
    // and a deposit larger than the balance cannot be funded.
    func testSwapLocksBalance() async throws {
        let seed = propertySeed()
        var rng = seed.generator()
        for _ in 0..<50 {
            let fetcher = StorableFetcher()
            let demander = "demander_\(rng.randomUUIDString())"
            let balance = UInt64.random(in: 1...10_000, using: &rng)
            let (funded, _) = try await LatticeState.emptyState().proveAndUpdateState(
                allAccountActions: [AccountAction(owner: demander, delta: Int64(balance))],
                allActions: [], allDepositActions: [], allGenesisActions: [],
                allReceiptActions: [], allWithdrawalActions: [], transactionBodies: [],
                fetcher: fetcher
            )
            try await LatticeStateHeader(node: funded).storeRecursively(storer: fetcher)

            let amount = UInt64.random(in: 1...balance, using: &rng)
            let deposit = DepositAction(
                nonce: UInt128.random(in: 0...UInt128.max, using: &rng),
                demander: demander,
                amountDemanded: UInt64.random(in: 1...10_000, using: &rng),
                amountDeposited: amount
            )
            let (locked, _) = try await funded.proveAndUpdateState(
                allAccountActions: [AccountAction(owner: demander, delta: -Int64(amount))],
                allActions: [], allDepositActions: [deposit], allGenesisActions: [],
                allReceiptActions: [], allWithdrawalActions: [], transactionBodies: [],
                fetcher: fetcher
            )
            try await LatticeStateHeader(node: locked).storeRecursively(storer: fetcher)

            let accounts = try await locked.accountState.resolve(fetcher: fetcher)
            let balanceAfter: UInt64 = (try? accounts.node?.get(key: demander)) ?? 0
            XCTAssertEqual(balanceAfter, balance - amount, "deposit must debit the demander \(seed.note)")
            let depositsAfter = try await locked.depositState.resolve(fetcher: fetcher)
            let lockedAmount: UInt64? = try? depositsAfter.node?.get(key: DepositKey(depositAction: deposit).description)
            XCTAssertEqual(lockedAmount, amount, "deposit must lock the deposited amount \(seed.note)")

            let overdraw = DepositAction(
                nonce: deposit.nonce &+ 1, demander: demander,
                amountDemanded: 1, amountDeposited: balance - amount + 1
            )
            do {
                _ = try await locked.proveAndUpdateState(
                    allAccountActions: [AccountAction(owner: demander, delta: -Int64(overdraw.amountDeposited))],
                    allActions: [], allDepositActions: [overdraw], allGenesisActions: [],
                    allReceiptActions: [], allWithdrawalActions: [], transactionBodies: [],
                    fetcher: fetcher
                )
                XCTFail("a deposit beyond the remaining balance must not be funded \(seed.note)")
            } catch StateErrors.insufficientBalance {
                // expected
            }
        }
    }

    // Property: Account actions with negative delta (debit) require signer authorization
    func testDebitRequiresSignerProperty() {
        let seed = propertySeed()
        var rng = seed.generator()
        for _ in 0..<100 {
            let owner = "owner_\(rng.randomUUIDString())"
            let oldBalance = UInt64.random(in: 100...10000, using: &rng)
            let newBalance = UInt64.random(in: 0..<oldBalance, using: &rng)

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
                nonce: 0,
                chainPath: ["Nexus"]
            )
            XCTAssertFalse(body.accountActionsAreValid(),
                           "Debit without signer should be invalid \(seed.note)")

            let bodyWithSigner = TransactionBody(
                accountActions: [action],
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: [owner],
                fee: 0,
                nonce: 0,
                chainPath: ["Nexus"]
            )
            XCTAssertTrue(bodyWithSigner.accountActionsAreValid(),
                          "Debit with matching signer should be valid \(seed.note)")
        }
    }

    // Property: Credit (positive delta) does NOT require signer
    func testCreditDoesNotRequireSigner() {
        let seed = propertySeed()
        var rng = seed.generator()
        for _ in 0..<100 {
            let owner = "owner_\(rng.randomUUIDString())"
            let oldBalance = UInt64.random(in: 0...10000, using: &rng)
            let newBalance = oldBalance + UInt64.random(in: 1...10000, using: &rng)

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
                nonce: 0,
                chainPath: ["Nexus"]
            )
            XCTAssertTrue(body.accountActionsAreValid(),
                          "Credit without signer should be valid \(seed.note)")
        }
    }
}

// MARK: - Cross-Chain Swap Protocol Properties

final class CrossChainProtocolPropertyTests: XCTestCase {

    // Property: SwapKey round-trips through string representation
    func testSwapKeyRoundTrip() {
        let seed = propertySeed()
        var rng = seed.generator()
        for _ in 0..<200 {
            let nonce = UInt128.random(in: 0...UInt128.max, using: &rng)
            let demander = "demander_\(rng.randomUUIDString())"
            let amountDemanded = UInt64.random(in: 1...UInt64.max, using: &rng)

            let key = DepositKey(depositAction: DepositAction(nonce: nonce, demander: demander, amountDemanded: amountDemanded, amountDeposited: amountDemanded))
            let stringRepr = key.description
            let parsed = DepositKey(stringRepr)

            XCTAssertNotNil(parsed, "Failed to parse SwapKey: \(stringRepr) \(seed.note)")
            if let parsed = parsed {
                XCTAssertEqual(parsed.nonce, nonce, seed.note)
                XCTAssertEqual(parsed.demander, demander, seed.note)
                XCTAssertEqual(parsed.amountDemanded, amountDemanded, seed.note)
            }
        }
    }

    // Property: WithdrawalAction produces matching SwapKey
    func testSwapClaimProducesMatchingDepositKey() {
        let seed = propertySeed()
        var rng = seed.generator()
        for _ in 0..<100 {
            let nonce = UInt128.random(in: 0...UInt128.max, using: &rng)
            let demander = "demander_\(rng.randomUUIDString())"
            let withdrawer = "withdrawer_\(rng.randomUUIDString())"
            let amountDemanded = UInt64.random(in: 1...1000000, using: &rng)

            let swap = DepositAction(nonce: nonce, demander: demander, amountDemanded: amountDemanded, amountDeposited: amountDemanded)
            let claim = WithdrawalAction(withdrawer: withdrawer, nonce: nonce, demander: demander, amountDemanded: amountDemanded, amountWithdrawn: amountDemanded)

            let swapKey = DepositKey(depositAction: swap)
            let claimKey = DepositKey(withdrawalAction: claim)

            XCTAssertEqual(swapKey.description, claimKey.description,
                           "Swap and claim should produce matching keys \(seed.note)")
        }
    }

    // Property: SettleKey consistency for same swap
    func testSettleKeyConsistency() {
        let seed = propertySeed()
        var rng = seed.generator()
        let directory = "TestChain"
        for _ in 0..<100 {
            let nonce = UInt128.random(in: 0...UInt128.max, using: &rng)
            let demander = "demander_\(rng.randomUUIDString())"
            let withdrawer = "withdrawer_\(rng.randomUUIDString())"
            let amountDemanded = UInt64.random(in: 1...1000000, using: &rng)

            let swap = DepositAction(nonce: nonce, demander: demander, amountDemanded: amountDemanded, amountDeposited: amountDemanded)
            let claim = WithdrawalAction(withdrawer: withdrawer, nonce: nonce, demander: demander, amountDemanded: amountDemanded, amountWithdrawn: amountDemanded)

            let settleKeyFromSwap = ReceiptKey(receiptAction: ReceiptAction(withdrawer: withdrawer, nonce: nonce, demander: demander, amountDemanded: amountDemanded, directory: directory))
            let settleKeyFromClaim = ReceiptKey(withdrawalAction: claim, directory: directory)

            XCTAssertEqual(settleKeyFromSwap.description, settleKeyFromClaim.description, seed.note)
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
        let seed = propertySeed()
        var rng = seed.generator()
        for _ in 0..<100 {
            let owner = rng.randomUUIDString()
            let balance = UInt64.random(in: 1...1000000, using: &rng)

            let create = AccountAction(owner: owner, delta: Int64(balance))
            let delete = AccountAction(owner: owner, delta: -Int64(balance))

            let createDelta = try! create.stateDelta()
            let deleteDelta = try! delete.stateDelta()

            XCTAssertEqual(createDelta + deleteDelta, 0,
                           "Create + delete should net to zero for owner=\(owner) \(seed.note)")
        }
    }

    // Property: Inserting and deleting a KV action has net zero state delta
    func testActionInsertDeleteNetZero() {
        let seed = propertySeed()
        var rng = seed.generator()
        for _ in 0..<100 {
            let key = rng.randomUUIDString()
            let value = rng.randomUUIDString()

            let insert = Action(key: key, oldValue: nil, newValue: value)
            let delete = Action(key: key, oldValue: value, newValue: nil)

            let insertDelta = try! insert.stateDelta()
            let deleteDelta = try! delete.stateDelta()

            XCTAssertEqual(insertDelta + deleteDelta, 0,
                           "Insert + delete should net to zero \(seed.note)")
        }
    }

    // Property: State delta magnitude is bounded by key + value sizes
    func testStateDeltaBoundedByDataSize() {
        let seed = propertySeed()
        var rng = seed.generator()
        for _ in 0..<100 {
            let key = String(repeating: "k", count: Int.random(in: 1...50, using: &rng))
            let value = String(repeating: "v", count: Int.random(in: 1...100, using: &rng))

            let insert = Action(key: key, oldValue: nil, newValue: value)
            let delta = try! insert.stateDelta()

            let maxDelta = key.utf8.count + value.utf8.count
            XCTAssertEqual(delta, maxDelta,
                           "Insert delta should equal key + value size \(seed.note)")
        }
    }

    // Property: Swap state delta is always positive (swaps add state)
    func testDepositStateDeltaPositive() {
        let seed = propertySeed()
        var rng = seed.generator()
        for _ in 0..<100 {
            let action = DepositAction(
                nonce: UInt128.random(in: 0...UInt128.max, using: &rng),
                demander: rng.randomUUIDString(),
                amountDemanded: UInt64.random(in: 1...1000000, using: &rng),
                amountDeposited: UInt64.random(in: 1...1000000, using: &rng)
            )
            XCTAssertGreaterThan(action.stateDelta(), 0,
                                 "Swap delta should always be positive \(seed.note)")
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
            nonce: 0,
            chainPath: ["Nexus"]
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

    // Property: Block has 6 required addressable child properties. The optional
    // parent is exposed separately when present; storage policy decides which
    // content-addressed edges to traverse.
    func testBlockPropertyCount() {
        XCTAssertEqual(BLOCK_PROPERTIES.count, 6)
    }

    // Property: Transaction has exactly 1 addressable property
    func testTransactionPropertyCount() {
        XCTAssertEqual(TRANSACTION_PROPERTIES.count, 1)
    }

}

// MARK: - Seed Replay

final class PropertySeedTests: XCTestCase {

    // Property: a seed replays. Two generators from the same seed yield the
    // same draws through every stdlib path the seeded properties use, a
    // different seed yields different draws, and the generator is pinned to
    // a known answer so a replay agrees across hosts, not only across runs.
    func testSameSeedReplaysTheSameSequence() {
        let seed = propertySeed()
        func draws(_ value: UInt64) -> [UInt64] {
            var rng = SeededRNG(seed: value)
            var out = (0..<64).map { _ in rng.next() }
            out += (0..<64).map { _ in UInt64.random(in: 0...10_000_000, using: &rng) }
            out += Array(0..<32).shuffled(using: &rng).map(UInt64.init)
            return out
        }
        XCTAssertEqual(draws(seed.value), draws(seed.value), seed.note)
        XCTAssertNotEqual(draws(seed.value), draws(seed.value &+ 1), seed.note)
        var zero = SeededRNG(seed: 0)
        XCTAssertEqual(zero.next(), 0xe220a8397b1dcdaf, "SplitMix64 known answer for seed 0")
    }
}
