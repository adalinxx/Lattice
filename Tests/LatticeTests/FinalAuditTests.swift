import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

private func f() -> StorableFetcher { StorableFetcher() }

private func s(_ dir: String = "Nexus", premine: UInt64 = 1000) -> ChainSpec {
    ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
}

private func tx(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
    let h = try! HeaderImpl<TransactionBody>(node: body)
    let sig = TransactionSigning.sign(bodyHeader: h, privateKeyHex: kp.privateKey)!
    return Transaction(signatures: [kp.publicKey: sig], body: h)
}

private func id(_ pubKey: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: pubKey)).rawCID
}

private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

private func premineGenesis(
    spec: ChainSpec, owner kp: (privateKey: String, publicKey: String),
    fetcher: StorableFetcher, time: Int64
) async throws -> Block {
    let addr = id(kp.publicKey)
    let body = TransactionBody(
        accountActions: [AccountAction(owner: addr, delta: Int64(spec.premineAmount()))],
        actions: [], depositActions: [], genesisActions: [],
        receiptActions: [], withdrawalActions: [], signers: [addr], fee: 0, nonce: 0
    )
    return try await BlockBuilder.buildGenesis(
        spec: spec, transactions: [tx(body, kp)],
        timestamp: time, target: UInt256(1000), fetcher: fetcher
    )
}

// ============================================================================
// MARK: - 1. Double Claim: Same Swap Claimed Twice
// ============================================================================

@MainActor
final class DoubleClaimTests: XCTestCase {

    func testSameSwapCannotBeClaimedTwice() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let premine = childSpec.premineAmount()
        let cr = childSpec.initialReward
        let nr = nexusSpec.rewardAtBlock(0)
        let amount: UInt64 = 500

        let childGenesis = try await premineGenesis(spec: childSpec, owner: kp, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let childSwap = DepositAction(nonce: 1, demander: kpAddr, amountDemanded: amount, amountDeposited: amount)
        let childSwapKey = DepositKey(depositAction: childSwap).description

        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(premine - amount + cr) - Int64(premine))],
            actions: [],
            depositActions: [childSwap],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 1
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(swapBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let bal1 = premine - amount + cr

        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(nr))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, directory: "Child")],
            withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(settleBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let c1Body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(bal1 + amount + cr) - Int64(bal1))],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, amountWithdrawn: amount)],
            signers: [kpAddr], fee: 0, nonce: 2
        )
        let childBlock2 = try await BlockBuilder.buildBlock(
            previous: childBlock1,
            transactions: [tx(c1Body, kp)],
            parentChainBlock: nexusBlock1,
            timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let bal2 = bal1 + amount + cr

        let c2Body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(bal2 + amount + cr) - Int64(bal2))],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, amountWithdrawn: amount)],
            signers: [kpAddr], fee: 0, nonce: 3
        )

        do {
            let childBlock3 = try await BlockBuilder.buildBlock(
                previous: childBlock2,
                transactions: [tx(c2Body, kp)],
                parentChainBlock: nexusBlock1,
                timestamp: base + 3000, target: UInt256(1000), nonce: 3, fetcher: fetcher
            )
            let valid = try await childBlock3.validateNexus(fetcher: fetcher).0
            XCTAssertFalse(valid, "Second claim of same swap should fail — DepositState key already deleted")
        } catch {
        }
    }
}

// ============================================================================
// MARK: - 2. Phantom Settle: Settle Without Corresponding Swap
// ============================================================================

@MainActor
final class PhantomSettleTests: XCTestCase {

    func testSettleAcceptedButClaimWithoutSwapFails() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let premine = childSpec.premineAmount()
        let cr = childSpec.initialReward
        let nr = nexusSpec.rewardAtBlock(0)

        let childGenesis = try await premineGenesis(spec: childSpec, owner: kp, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let phantomSwapKey = DepositKey(depositAction: DepositAction(nonce: 99, demander: kpAddr, amountDemanded: 1000, amountDeposited: 1000)).description

        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(nr))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 99, demander: kpAddr, amountDemanded: 1000, directory: "Child")],
            withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(settleBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let nv = try await nexusBlock1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(nv, "Settle is accepted on nexus — nexus doesn't cross-verify swaps")

        let claimBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(premine + 1000 + cr) - Int64(premine))],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: kpAddr, nonce: 99, demander: kpAddr, amountDemanded: 1000, amountWithdrawn: 1000)],
            signers: [kpAddr], fee: 0, nonce: 1
        )

        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, timestamp: base + 1000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        do {
            let badBlock = try await BlockBuilder.buildBlock(
                previous: childBlock1,
                transactions: [tx(claimBody, kp)],
                parentChainBlock: nexusBlock1,
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            let valid = try await badBlock.validateNexus(fetcher: fetcher).0
            XCTAssertFalse(valid, "Claim referencing phantom swap should fail validation")
        } catch {
            // Deletion proof throws on non-existent swap — phantom swap correctly rejected
        }
    }
}

// ============================================================================
// MARK: - 3. Cross-Chain Replay: Child A Swap Claimed on Child B
// ============================================================================

@MainActor
final class CrossChainReplayTests: XCTestCase {

    func testSwapOnChildACannotBeClaimedOnChildB() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let childASpec = s("ChildA")
        let childBSpec = s("ChildB")
        let nexusSpec = s("Nexus", premine: 0)
        let premineA = childASpec.premineAmount()
        let premineB = childBSpec.premineAmount()
        let crA = childASpec.initialReward
        let nr = nexusSpec.rewardAtBlock(0)
        let amount: UInt64 = 500

        let childAGenesis = try await premineGenesis(spec: childASpec, owner: kp, fetcher: fetcher, time: base)
        let childBGenesis = try await premineGenesis(spec: childBSpec, owner: kp, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let childASwap = DepositAction(nonce: 1, demander: kpAddr, amountDemanded: amount, amountDeposited: amount)
        let childASwapKey = DepositKey(depositAction: childASwap).description

        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(premineA - amount + crA) - Int64(premineA))],
            actions: [],
            depositActions: [childASwap],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 1
        )
        let _ = try await BlockBuilder.buildBlock(
            previous: childAGenesis, transactions: [tx(swapBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(nr))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, directory: "ChildA")],
            withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(settleBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let crB = childBSpec.initialReward
        let replayBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(premineB + amount + crB) - Int64(premineB))],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, amountWithdrawn: amount)],
            signers: [kpAddr], fee: 0, nonce: 1
        )

        do {
            let replayBlock = try await BlockBuilder.buildBlock(
                previous: childBGenesis,
                transactions: [tx(replayBody, kp)],
                parentChainBlock: nexusBlock1,
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            let valid = try await replayBlock.validateNexus(fetcher: fetcher).0
            XCTAssertFalse(valid, "Claim on child B using child A swap should fail — no swap exists on B")
        } catch {
            // Deletion proof throws on non-existent swap key in child B's depositState
        }
    }
}

// ============================================================================
// MARK: - 4. Selfish Mining: Withheld Chain vs Honest Chain
// ============================================================================

@MainActor
final class SelfishMiningTests: XCTestCase {

    func testHonestChainNotDisadvantagedByWithholding() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let spec = s(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        // Honest miner publishes 3 blocks immediately
        var honestPrev = genesis
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: honestPrev, timestamp: base + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            honestPrev = b
        }

        let honestTip = await chain.getMainChainTip()
        XCTAssertEqual(honestTip, try! VolumeImpl<Block>(node: honestPrev).rawCID)

        // Selfish miner withholds 3 blocks (same length), publishes all at once
        var selfishPrev = genesis
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: selfishPrev, timestamp: base + Int64(i) * 500,
                target: UInt256(1000), nonce: UInt64(i + 200), fetcher: fetcher
            )
            selfishPrev = b
        }

        // Submit all withheld blocks
        var cursor = genesis
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: cursor, timestamp: base + Int64(i) * 500,
                target: UInt256(1000), nonce: UInt64(i + 200), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            cursor = b
        }

        // Equal-length selfish chain should NOT replace honest chain (first-seen wins)
        let finalTip = await chain.getMainChainTip()
        XCTAssertEqual(finalTip, honestTip, "Equal-length withheld chain should not displace honest chain")
    }

    func testLongerSelfishChainDoesReorg() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let spec = s(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        // Honest: 3 blocks
        var honestPrev = genesis
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: honestPrev, timestamp: base + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            honestPrev = b
        }

        // Selfish: 4 blocks (longer, wins)
        var selfishPrev = genesis
        for i in 1...4 {
            let b = try await BlockBuilder.buildBlock(
                previous: selfishPrev, timestamp: base + Int64(i) * 500,
                target: UInt256(1000), nonce: UInt64(i + 300), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            selfishPrev = b
        }

        let finalTip = await chain.getMainChainTip()
        XCTAssertEqual(finalTip, try! VolumeImpl<Block>(node: selfishPrev).rawCID, "Longer chain wins regardless of timing")
    }
}

// ============================================================================
// MARK: - 5. Chain Policies End-to-End in Block Validation
// ============================================================================

@MainActor
final class ChainPolicyBlockTests: XCTestCase {

    func testAcceptingTransactionPolicyAllowsBlockValidation() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let acceptingPolicy = try storeWasmPolicy(accepts: true, scope: .transaction, fetcher: fetcher)
        let policySpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
            premine: 0, targetBlockTime: 1_000, initialReward: 1024, halvingInterval: 10_000,
            retargetWindow: 5,
            wasmPolicies: [acceptingPolicy]
        )

        let genesis = try await BlockBuilder.buildGenesis(
            spec: policySpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let reward = policySpec.rewardAtBlock(0)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(body, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)
    }

    func testRejectingTransactionPolicyFailsBlockValidation() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let rejectingPolicy = try storeWasmPolicy(accepts: false, scope: .transaction, fetcher: fetcher)
        let filteredSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
            premine: 0, targetBlockTime: 1_000, initialReward: 1024, halvingInterval: 10_000,
            retargetWindow: 5,
            wasmPolicies: [rejectingPolicy]
        )

        let genesis = try await BlockBuilder.buildGenesis(
            spec: filteredSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let reward = filteredSpec.rewardAtBlock(0)

        // Block rejected by the chain's transaction policy.
        let lowFeeBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let lowFeeBlock = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(lowFeeBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let lowFeeValid = try await lowFeeBlock.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(lowFeeValid, "Block rejected by chain policy should fail validation")
    }

    func testRejectingActionPolicyFailsBlockValidation() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let rejectingPolicy = try storeWasmPolicy(accepts: false, scope: .action, fetcher: fetcher)
        let policySpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
            premine: 0, targetBlockTime: 1_000, initialReward: 1024, halvingInterval: 10_000,
            retargetWindow: 5,
            wasmPolicies: [rejectingPolicy]
        )

        let genesis = try await BlockBuilder.buildGenesis(
            spec: policySpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let reward = policySpec.rewardAtBlock(0)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [Action(key: "policy/test", oldValue: nil, newValue: "value")],
            depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(body, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "Block rejected by action-scoped chain policy should fail validation")
    }
}

// ============================================================================
// MARK: - 6. General State (Action) Mutations Through Block Lifecycle
// ============================================================================

@MainActor
final class GeneralStateBlockTests: XCTestCase {

    func testInsertReadUpdateDeleteGeneralState() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let spec = s(premine: 0)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        // Block 1: Insert key-value pair
        let insertBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [Action(key: "greeting", oldValue: nil, newValue: "hello")],
            depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(insertBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let v1 = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(v1)
        XCTAssertNotEqual(block1.postState.rawCID, block1.prevState.rawCID)

        // Block 2: Update the value
        let updateBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward + reward) - Int64(reward))],
            actions: [Action(key: "greeting", oldValue: "hello", newValue: "world")],
            depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [tx(updateBody, kp)],
            timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let v2 = try await block2.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(v2)

        // Block 3: Delete the key
        let deleteBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward * 3) - Int64(reward * 2))],
            actions: [Action(key: "greeting", oldValue: "world", newValue: nil)],
            depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 2, chainPath: ["Nexus"]
        )
        let block3 = try await BlockBuilder.buildBlock(
            previous: block2, transactions: [tx(deleteBody, kp)],
            timestamp: base + 3000, target: UInt256(1000), nonce: 3, fetcher: fetcher
        )
        let v3 = try await block3.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(v3)
    }

    func testInsertWithWrongOldValueFails() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let spec = s(premine: 0)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let insertBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [Action(key: "key1", oldValue: nil, newValue: "value1")],
            depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(insertBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Update with wrong oldValue
        let wrongBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward + reward) - Int64(reward))],
            actions: [Action(key: "key1", oldValue: "WRONG", newValue: "value2")],
            depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 1
        )

        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: block1, transactions: [tx(wrongBody, kp)],
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            XCTFail("Update with wrong oldValue should throw")
        } catch {
            // GeneralState.updateState checks oldValue matches actual
        }
    }
}
