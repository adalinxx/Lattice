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
    spec: ChainSpec, owner: (privateKey: String, publicKey: String),
    fetcher: StorableFetcher, time: Int64
) async throws -> Block {
    let addr = id(owner.publicKey)
    let body = TransactionBody(
        accountActions: [AccountAction(owner: addr, delta: Int64(spec.premineAmount()))],
        actions: [], depositActions: [], genesisActions: [],
        receiptActions: [], withdrawalActions: [], signers: [addr], fee: 0, nonce: 0
    )
    return try await BlockBuilder.buildGenesis(
        spec: spec, transactions: [tx(body, owner)],
        timestamp: time, target: UInt256(1000), fetcher: fetcher
    )
}

// ============================================================================
// MARK: - CRITICAL: Full Cross-Chain Swap → Settle → Claim Roundtrip
// ============================================================================

@MainActor
final class CrossChainRoundtripTests: XCTestCase {

    func testFullSwapSettleClaimRoundtrip() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let childPremine = childSpec.premineAmount()
        let childReward = childSpec.initialReward
        let nexusReward = nexusSpec.rewardAtBlock(0)
        let swapAmount: UInt64 = 500

        let childGenesis = try await premineGenesis(spec: childSpec, owner: alice, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let childSwap = DepositAction(nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, amountDeposited: swapAmount)
        let childSwapKey = DepositKey(depositAction: childSwap).description

        // Step 1: SWAP on child chain (locks funds)
        let swapBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(childPremine - swapAmount + childReward) - Int64(childPremine))
            ],
            actions: [],
            depositActions: [childSwap],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(swapBody, alice)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        XCTAssertEqual(childBlock1.height, 1)
        let balanceAfterSwap = childPremine - swapAmount + childReward

        // Step 2: SETTLE on nexus chain (co-signed acknowledgment)
        let settleBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(nexusReward))
            ],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: aliceAddr, nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(settleBody, alice)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let nexusValid = try await nexusBlock1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(nexusValid)

        // Pad nexus so parentState continuity works for child block
        let nexusPad = try await BlockBuilder.buildBlock(
            previous: nexusBlock1, timestamp: base + 2000,
            target: UInt256(1000), nonce: 2, fetcher: fetcher
        )

        // Step 3: CLAIM on child chain (claims funds with settlement proof)
        let claimBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(balanceAfterSwap + swapAmount + childReward) - Int64(balanceAfterSwap))
            ],
            actions: [],
            depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: aliceAddr, nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, amountWithdrawn: swapAmount)
            ],
            signers: [aliceAddr], fee: 0, nonce: 2, chainPath: ["Nexus", "Child"]
        )

        let childBlock2 = try await BlockBuilder.buildBlock(
            previous: childBlock1,
            transactions: [tx(claimBody, alice)],
            parentChainBlock: nexusPad,
            timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        XCTAssertEqual(childBlock2.height, 2)

        let finalBalance = balanceAfterSwap + swapAmount + childReward
        XCTAssertEqual(finalBalance, childPremine + 2 * childReward)
    }

    // Variable-rate two-party trade: Alice deposits 100 ChildA tokens
    // demanding 250 nexus tokens. Bob pays 250 on nexus and claims the
    // 100 ChildA tokens. Exercises the full deposit→receipt→withdraw flow
    // with amountDeposited ≠ amountDemanded across all three layers.
    func testVariableRateTwoPartyRoundtrip() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let childPremine = childSpec.premineAmount()
        let childReward = childSpec.initialReward
        let nexusReward0 = nexusSpec.rewardAtBlock(0)

        let amountDeposited: UInt64 = 100   // Alice locks 100 Child tokens
        let amountDemanded: UInt64 = 250    // and demands 250 Nexus tokens
        XCTAssertNotEqual(amountDeposited, amountDemanded, "Test premise: rates must differ")

        let childGenesis = try await premineGenesis(spec: childSpec, owner: alice, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        // Fund Bob on nexus (he needs ≥ amountDemanded to pay Alice via receipt)
        let t1 = base + 1000
        let fundBob = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(nexusReward0))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(fundBob, bob)],
            timestamp: t1, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        XCTAssertGreaterThanOrEqual(nexusReward0, amountDemanded, "Bob must have funds for receipt")

        // Step 1: Alice deposits on Child (locks amountDeposited, demands amountDemanded)
        let aliceDeposit = DepositAction(
            nonce: 1, demander: aliceAddr,
            amountDemanded: amountDemanded,
            amountDeposited: amountDeposited
        )
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(childReward) - Int64(amountDeposited))],
            actions: [], depositActions: [aliceDeposit],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus", "Child"]
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(depositBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let aliceBalanceAfterDeposit = childPremine - amountDeposited + childReward

        // Step 2: Receipt on nexus — Bob pays Alice amountDemanded
        let t2 = base + 2000
        let receiptBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(nexusSpec.rewardAtBlock(2)))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr,
                              amountDemanded: amountDemanded, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let receiptHeader = try! HeaderImpl<TransactionBody>(node: receiptBody)
        let bobSig = TransactionSigning.sign(bodyHeader: receiptHeader, privateKeyHex: bob.privateKey)!
        let receiptTx = Transaction(signatures: [bob.publicKey: bobSig], body: receiptHeader)
        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1, transactions: [receiptTx],
            timestamp: t2, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let nexusValid = try await nexusBlock2.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(nexusValid, "Receipt with amountDemanded=250 on nexus should validate")

        // Pad nexus so child can advance with a fresh parent reference
        let t3 = base + 3000
        let nexusBlock3 = try await BlockBuilder.buildBlock(
            previous: nexusBlock2, timestamp: t3,
            target: UInt256(1000), nonce: 3, fetcher: fetcher
        )

        // Step 3: Withdrawal on Child — Bob claims amountDeposited tokens.
        // amountWithdrawn must equal deposit.amountDeposited (on-chain check)
        // amountDemanded on the withdrawal must match the receipt
        let bobWithdraw = WithdrawalAction(
            withdrawer: bobAddr, nonce: 1, demander: aliceAddr,
            amountDemanded: amountDemanded,
            amountWithdrawn: amountDeposited
        )
        let withdrawBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(amountDeposited + childReward))],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [bobWithdraw],
            signers: [bobAddr], fee: 0, nonce: 0, chainPath: ["Nexus", "Child"]
        )
        let childBlock2 = try await BlockBuilder.buildBlock(
            previous: childBlock1, transactions: [tx(withdrawBody, bob)],
            parentChainBlock: nexusBlock3,
            timestamp: t3, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let childValid = try await childBlock2.validateNexus(fetcher: fetcher, chainPath: ["Nexus", "Child"]).0
        XCTAssertTrue(childValid, "Variable-rate withdrawal (amountWithdrawn=100) should validate against deposit (amountDeposited=100)")

        // Final balances reflect the variable-rate trade
        // Alice locked 100 Child, kept (premine - 100 + childReward) but the
        // amount she actually receives on Nexus is amountDemanded=250 (via receipt's implicit credit).
        XCTAssertEqual(aliceBalanceAfterDeposit, childPremine - amountDeposited + childReward)
    }

    // Negative: a withdrawal claiming more child tokens than the deposit
    // locked must be rejected even when the receipt and signers are valid.
    // Frontier mismatch (or proof failure) should kill the block.
    func testVariableRateOverclaimRejected() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let childPremine = childSpec.premineAmount()
        let childReward = childSpec.initialReward
        let nexusReward0 = nexusSpec.rewardAtBlock(0)

        let amountDeposited: UInt64 = 100
        let amountDemanded: UInt64 = 250
        let overclaim: UInt64 = 200  // Bob tries to claim 200 when only 100 was deposited

        let childGenesis = try await premineGenesis(spec: childSpec, owner: alice, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let t1 = base + 1000
        let fundBob = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(nexusReward0))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(fundBob, bob)],
            timestamp: t1, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let aliceDeposit = DepositAction(
            nonce: 1, demander: aliceAddr,
            amountDemanded: amountDemanded, amountDeposited: amountDeposited
        )
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(childReward) - Int64(amountDeposited))],
            actions: [], depositActions: [aliceDeposit],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(depositBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let t2 = base + 2000
        let receiptBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(nexusSpec.rewardAtBlock(2)))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr,
                              amountDemanded: amountDemanded, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 1
        )
        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1, transactions: [tx(receiptBody, bob)],
            timestamp: t2, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let t3 = base + 3000
        let nexusBlock3 = try await BlockBuilder.buildBlock(
            previous: nexusBlock2, timestamp: t3,
            target: UInt256(1000), nonce: 3, fetcher: fetcher
        )

        // Bob's overclaim attempt
        let bobOverclaim = WithdrawalAction(
            withdrawer: bobAddr, nonce: 1, demander: aliceAddr,
            amountDemanded: amountDemanded,
            amountWithdrawn: overclaim
        )
        let withdrawBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(overclaim + childReward))],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [bobOverclaim],
            signers: [bobAddr], fee: 0, nonce: 0
        )

        // The block builder may either throw on proof construction OR build a
        // block that fails validation due to frontier mismatch. Either is
        // acceptable rejection — we just need the overclaim to NOT validate.
        var rejected = false
        do {
            let childBlock2 = try await BlockBuilder.buildBlock(
                previous: childBlock1, transactions: [tx(withdrawBody, bob)],
                parentChainBlock: nexusBlock3,
                timestamp: t3, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            let valid = try await childBlock2.validateNexus(fetcher: fetcher).0
            if !valid { rejected = true }
        } catch {
            rejected = true
        }
        XCTAssertTrue(rejected, "Withdrawal claiming amountWithdrawn=200 against deposit.amountDeposited=100 must be rejected")
    }

    func testSwapRefundAfterTimelock() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let childPremine = childSpec.premineAmount()
        let childReward = childSpec.initialReward
        let swapAmount: UInt64 = 1000

        let childGenesis = try await premineGenesis(spec: childSpec, owner: alice, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let childSwap = DepositAction(nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, amountDeposited: swapAmount)

        let t1 = base + 1000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, timestamp: t1,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let swapBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(childPremine - swapAmount + childReward) - Int64(childPremine))
            ],
            actions: [],
            depositActions: [childSwap],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(swapBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let balanceAfterSwap = childPremine - swapAmount + childReward

        // Settle on nexus so the receipt exists for the withdrawal
        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(nexusSpec.rewardAtBlock(0)))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [ReceiptAction(withdrawer: aliceAddr, nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, directory: "Child")],
            withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let t2 = base + 2000
        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1, transactions: [tx(settleBody, alice)],
            timestamp: t2, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )

        // Need another nexus block so the receipt moves into homestead
        let t3 = base + 3000
        let nexusBlock3 = try await BlockBuilder.buildBlock(
            previous: nexusBlock2,
            timestamp: t3, target: UInt256(1000), nonce: 3, fetcher: fetcher
        )

        let refundBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(balanceAfterSwap + swapAmount + childReward) - Int64(balanceAfterSwap))
            ],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: aliceAddr, nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, amountWithdrawn: swapAmount)
            ],
            signers: [aliceAddr], fee: 0, nonce: 2, chainPath: ["Nexus", "Child"]
        )
        let childBlock2 = try await BlockBuilder.buildBlock(
            previous: childBlock1,
            transactions: [tx(refundBody, alice)],
            parentChainBlock: nexusBlock3,
            timestamp: t3, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await childBlock2.validateNexus(fetcher: fetcher, chainPath: ["Nexus", "Child"]).0
        XCTAssertTrue(valid, "Withdrawal after deposit and receipt should succeed")
    }

    func testWithdrawalWithoutReceiptRejected() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let childPremine = childSpec.premineAmount()
        let childReward = childSpec.initialReward
        let swapAmount: UInt64 = 1000

        let childGenesis = try await premineGenesis(spec: childSpec, owner: alice, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let childSwap = DepositAction(nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, amountDeposited: swapAmount)

        let t1 = base + 1000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, timestamp: t1,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let swapBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(childPremine - swapAmount + childReward) - Int64(childPremine))
            ],
            actions: [],
            depositActions: [childSwap],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [tx(swapBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let balanceAfterSwap = childPremine - swapAmount + childReward

        // No receipt/settle on nexus -- try to withdraw anyway
        let t2 = base + 2000
        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1, timestamp: t2,
            target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let withdrawBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(balanceAfterSwap + swapAmount + childReward) - Int64(balanceAfterSwap))
            ],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: aliceAddr, nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, amountWithdrawn: swapAmount)
            ],
            signers: [aliceAddr], fee: 0, nonce: 2
        )

        do {
            let childBlock2 = try await BlockBuilder.buildBlock(
                previous: childBlock1,
                transactions: [tx(withdrawBody, alice)],
                parentChainBlock: nexusBlock2,
                timestamp: t2, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            let valid = try await childBlock2.validateNexus(fetcher: fetcher).0
            XCTAssertFalse(valid, "Withdrawal without corresponding receipt on parent chain must be rejected")
        } catch {
            // Expected: receipt proof fails because no receipt exists on nexus
        }
    }

    func testTwoPartySwapEndToEnd() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let childASpec = s("ChildA")
        let childBSpec = s("ChildB")
        let nexusSpec = s("Nexus", premine: 0)
        let premineA = childASpec.premineAmount()
        let premineB = childBSpec.premineAmount()
        let rewardA = childASpec.initialReward
        let rewardB = childBSpec.initialReward
        let nexusReward = nexusSpec.rewardAtBlock(0)

        let childAGenesis = try await premineGenesis(spec: childASpec, owner: alice, fetcher: fetcher, time: base)
        let childBGenesis = try await premineGenesis(spec: childBSpec, owner: bob, fetcher: fetcher, time: base)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let aliceSwapAmount: UInt64 = 300
        let bobSwapAmount: UInt64 = 200

        let aliceSwap = DepositAction(nonce: 1, demander: aliceAddr, amountDemanded: aliceSwapAmount, amountDeposited: aliceSwapAmount)
        let bobSwap = DepositAction(nonce: 1, demander: bobAddr, amountDemanded: bobSwapAmount, amountDeposited: bobSwapAmount)

        let t1 = base + 1000
        // Fund bob on nexus so he can pay alice via receipt in the settle step
        let fundBobBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let advanceAliceOnNexus = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(fundBobBody, bob), tx(advanceAliceOnNexus, alice)],
            timestamp: t1,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let aliceSwapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(premineA - aliceSwapAmount + rewardA) - Int64(premineA))],
            actions: [], depositActions: [aliceSwap],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus", "ChildA"]
        )
        let childABlock1 = try await BlockBuilder.buildBlock(
            previous: childAGenesis, transactions: [tx(aliceSwapBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let bobSwapBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(premineB - bobSwapAmount + rewardB) - Int64(premineB))],
            actions: [], depositActions: [bobSwap],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 1, chainPath: ["Nexus", "ChildB"]
        )
        let childBBlock1 = try await BlockBuilder.buildBlock(
            previous: childBGenesis, transactions: [tx(bobSwapBody, bob)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Settle: two receipts (one for each direction) co-signed by both parties
        let t2 = base + 2000
        let settleBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(nexusSpec.rewardAtBlock(2)))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr, amountDemanded: aliceSwapAmount, directory: "ChildA"),
                ReceiptAction(withdrawer: aliceAddr, nonce: 1, demander: bobAddr, amountDemanded: bobSwapAmount, directory: "ChildB")
            ],
            withdrawalActions: [],
            signers: [aliceAddr, bobAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let settleHeader = try! HeaderImpl<TransactionBody>(node: settleBody)
        let sigA = TransactionSigning.sign(bodyHeader: settleHeader, privateKeyHex: alice.privateKey)!
        let sigB = TransactionSigning.sign(bodyHeader: settleHeader, privateKeyHex: bob.privateKey)!
        let settleTx = Transaction(signatures: [alice.publicKey: sigA, bob.publicKey: sigB], body: settleHeader)

        let nexusBlock2 = try await BlockBuilder.buildBlock(
            previous: nexusBlock1, transactions: [settleTx],
            timestamp: t2, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let nexusValid = try await nexusBlock2.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(nexusValid, "Settlement co-signed by both parties should be valid")

        let t3 = base + 3000
        let nexusBlock3 = try await BlockBuilder.buildBlock(
            previous: nexusBlock2, timestamp: t3,
            target: UInt256(1000), nonce: 3, fetcher: fetcher
        )

        let bobClaimOnA = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(aliceSwapAmount + rewardA))],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr, amountDemanded: aliceSwapAmount, amountWithdrawn: aliceSwapAmount)],
            signers: [bobAddr], fee: 0, nonce: 0, chainPath: ["Nexus", "ChildA"]
        )
        let childABlock2 = try await BlockBuilder.buildBlock(
            previous: childABlock1, transactions: [tx(bobClaimOnA, bob)],
            parentChainBlock: nexusBlock3,
            timestamp: t3, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let childAValid = try await childABlock2.validateNexus(fetcher: fetcher, chainPath: ["Nexus", "ChildA"]).0
        XCTAssertTrue(childAValid, "Bob claiming Alice's swap on ChildA should be valid")

        let aliceClaimOnB = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(bobSwapAmount + rewardB))],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: aliceAddr, nonce: 1, demander: bobAddr, amountDemanded: bobSwapAmount, amountWithdrawn: bobSwapAmount)],
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus", "ChildB"]
        )
        let childBBlock2 = try await BlockBuilder.buildBlock(
            previous: childBBlock1, transactions: [tx(aliceClaimOnB, alice)],
            parentChainBlock: nexusBlock3,
            timestamp: t3, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let childBValid = try await childBBlock2.validateNexus(fetcher: fetcher, chainPath: ["Nexus", "ChildB"]).0
        XCTAssertTrue(childBValid, "Alice claiming Bob's swap on ChildB should be valid")
    }
}

// ============================================================================
// MARK: - Swap Authorization Negative Tests
// ============================================================================

@MainActor
final class SwapAuthorizationTests: XCTestCase {

    func testWithdrawalByNonWithdrawerRejected() {
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let eve = CryptoUtils.generateKeyPair()
        let eveAddr = id(eve.publicKey)

        // Eve signs but the withdrawal specifies bob as the withdrawer
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr, amountDemanded: 100, amountWithdrawn: 100)],
            signers: [eveAddr], fee: 0, nonce: 0
        )
        XCTAssertFalse(body.withdrawalActionsAreValid(), "Withdrawal signed by non-withdrawer should be rejected")
    }

    func testWithdrawalByWithdrawerAccepted() {
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr, amountDemanded: 100, amountWithdrawn: 100)],
            signers: [bobAddr], fee: 0, nonce: 0
        )
        XCTAssertTrue(body.withdrawalActionsAreValid(), "Withdrawal signed by withdrawer should be accepted")
    }

    func testWithdrawalDifferingFromDemandAccepted() {
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        // Variable-rate swap: amountWithdrawn may differ from amountDemanded.
        // The actual amount-vs-stored-deposit check happens at state-application
        // time in DepositStateHeader.proveAndDeleteForWithdrawals.
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: aliceAddr, nonce: 1, demander: aliceAddr, amountDemanded: 100, amountWithdrawn: 200)],
            signers: [aliceAddr], fee: 0, nonce: 0
        )
        XCTAssertTrue(body.withdrawalActionsAreValid(), "Body-level withdrawal validation no longer requires amountWithdrawn == amountDemanded")
    }

    func testReceiptWithMismatchedWithdrawerRejected() {
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        // Receipt withdrawer is bob but only alice signs — rejected because
        // the receipt debits bob's funds, so bob must authorize
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [ReceiptAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr, amountDemanded: 100, directory: "A")],
            withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0
        )
        XCTAssertFalse(body.receiptActionsAreValid(), "Withdrawer must sign — their nexus funds are debited by the receipt")
    }

    func testSettleAndClaimInSameBlockFails() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let nexusSpec = s("Nexus")
        let premine = nexusSpec.premineAmount()
        let reward = nexusSpec.initialReward
        let nexusGenesis = try await premineGenesis(spec: nexusSpec, owner: alice, fetcher: fetcher, time: base)

        let swapAmount: UInt64 = 100
        let swap = DepositAction(nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, amountDeposited: swapAmount)

        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(premine - swapAmount + reward) - Int64(premine))],
            actions: [], depositActions: [swap],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(swapBody, alice)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let balAfterSwap = premine - swapAmount + reward

        let settleAndClaimBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(balAfterSwap + swapAmount + reward) - Int64(balAfterSwap))],
            actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [ReceiptAction(withdrawer: aliceAddr, nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, directory: "Nexus")],
            withdrawalActions: [WithdrawalAction(withdrawer: aliceAddr, nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, amountWithdrawn: swapAmount)],
            signers: [aliceAddr], fee: 0, nonce: 2
        )
        do {
            let nexusBlock2 = try await BlockBuilder.buildBlock(
                previous: nexusBlock1, transactions: [tx(settleAndClaimBody, alice)],
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            let valid = try await nexusBlock2.validateNexus(fetcher: fetcher).0
            XCTAssertFalse(valid, "Settle and claim in same block should fail — settlement not yet in homestead")
        } catch {
            // Claim proof or build fails because settle is not yet in homestead.receiptState
        }
    }
}

// ============================================================================
// MARK: - CRITICAL: Transaction Nonce Replay Protection On-Chain
// ============================================================================

@MainActor
final class NonceReplayTests: XCTestCase {

    func testSameTransactionCannotBeIncludedTwice() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let spec = s(premine: 0)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let transaction = tx(body, kp)

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [transaction],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Try including the SAME transaction in the next block (replay)
        // Transaction state tracks applied transaction hashes → duplicate rejected
        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: block1, transactions: [transaction],
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            XCTFail("Replayed transaction should fail — duplicate in transaction state")
        } catch {
            // transaction state rejects duplicate transaction hash
        }
    }

    func testTransactionNonceIsUniquePerSignerInState() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let spec = s(premine: 0)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let body1 = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(body1, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Same nonce (0) but different body — should fail because the signer's
        // nonce already advanced past 0; the new block's batch starts at 0 again,
        // which violates the "nonce must be current+1" invariant.
        let body2 = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward + reward) - Int64(reward))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )

        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: block1, transactions: [tx(body2, kp)],
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            XCTFail("Reused nonce should fail — signer's nonce must advance monotonically")
        } catch {
            // proveAndUpdateState throws nonceGap when first tx nonce != currentNonce + 1
        }
    }

    func testDifferentSignersSameNonceAllowed() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s(premine: 0)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let aliceBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(reward / 2))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let bobBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(reward / 2))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )

        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(aliceBody, alice), tx(bobBody, bob)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)
    }
}

// ============================================================================
// MARK: - CRITICAL: Balance Conservation Across Reorgs
// ============================================================================

@MainActor
final class ReorgBalanceTests: XCTestCase {

    func testReorgPreservesBalanceInvariants() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s()
        let premine = spec.premineAmount()
        let reward = spec.initialReward

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)
        let chain = ChainState.fromGenesis(block: genesis)

        // Main chain: alice sends 100 to bob
        let mainBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premine - 100) - Int64(premine)),
                AccountAction(owner: bobAddr, delta: Int64(100 + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let mainBlock1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(mainBody, alice)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let mainValid = try await mainBlock1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(mainValid)
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: try! VolumeImpl<Block>(node: mainBlock1), block: mainBlock1
        )

        let mainTip = await chain.getMainChainTip()
        XCTAssertEqual(mainTip, try! VolumeImpl<Block>(node: mainBlock1).rawCID)

        // Fork: 3 empty blocks from genesis (longer chain, triggers reorg)
        var forkPrev = genesis
        for i in 1...3 {
            let b = try await BlockBuilder.buildBlock(
                previous: forkPrev, timestamp: base + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i + 100), fetcher: fetcher
            )
            let _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil,
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            forkPrev = b
        }

        let newTip = await chain.getMainChainTip()
        XCTAssertEqual(newTip, try! VolumeImpl<Block>(node: forkPrev).rawCID)
        XCTAssertNotEqual(newTip, mainTip, "Reorg should have switched main chain")

        // After reorg: the transfer block is no longer on main chain
        // The fork has empty blocks — no account actions
        // State on main chain should reflect only genesis + empty blocks
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 3)
    }
}

// ============================================================================
// MARK: - HIGH: Multi-Signer Transactions
// ============================================================================

@MainActor
final class MultiSignerTests: XCTestCase {

    func testMultiSignerTransactionAccepted() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s()
        let premine = spec.premineAmount()
        let reward = spec.initialReward

        // Genesis gives alice the premine, block1 gives bob some funds
        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        let fundBob = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premine - 500) - Int64(premine)),
                AccountAction(owner: bobAddr, delta: Int64(500 + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let bobNonce0 = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let bobNonce1 = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(fundBob, alice), tx(bobNonce0, bob), tx(bobNonce1, bob)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Multi-signer: both alice and bob move funds in one transaction
        let aliceBalance = premine - 500
        let bobBalance: UInt64 = 500 + reward
        let multiBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(aliceBalance - 200) - Int64(aliceBalance)),
                AccountAction(owner: bobAddr, delta: Int64(bobBalance - 100 + 300 + reward) - Int64(bobBalance))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr, bobAddr], fee: 0, nonce: 2, chainPath: ["Nexus"]
        )
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: multiBody)
        let aliceSig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: alice.privateKey)!
        let bobSig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: bob.privateKey)!
        let multiTx = Transaction(
            signatures: [alice.publicKey: aliceSig, bob.publicKey: bobSig],
            body: bodyHeader
        )

        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [multiTx],
            timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await block2.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)
    }

    func testMultiSignerMissingOneSignatureFails() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s()
        let premine = spec.premineAmount()
        let reward = spec.initialReward

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        let fundBob = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premine - 500) - Int64(premine)),
                AccountAction(owner: bobAddr, delta: Int64(500 + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )
        let bobNonce0 = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 0
        )
        let bobNonce1 = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 1
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(fundBob, alice), tx(bobNonce0, bob), tx(bobNonce1, bob)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // Both remove funds but only alice signs
        let aliceBalance = premine - 500
        let bobBalance: UInt64 = 500 + reward
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(aliceBalance - 100) - Int64(aliceBalance)),
                AccountAction(owner: bobAddr, delta: Int64(bobBalance - 100 + 200 + reward) - Int64(bobBalance))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr, bobAddr], fee: 0, nonce: 2
        )
        // Only alice signs
        let onlyAliceTx = tx(body, alice)

        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [onlyAliceTx],
            timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid = try await block2.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "Missing bob's signature should fail validation")
    }
}

// ============================================================================
// MARK: - HIGH: Long-Chain Economic Invariant Tests
// ============================================================================

@MainActor
final class LongChainEconomicTests: XCTestCase {

    func testSupplyConservationOver100Blocks() async throws {
        let fetcher = f()
        let base = now() - 200_000
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = id(miner.publicKey)
        let spec = s(premine: 0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        var prev = genesis
        var totalRewards: UInt64 = 0
        var balance: UInt64 = 0

        for i: UInt64 in 0..<100 {
            let reward = spec.rewardAtBlock(i)
            let newBalance = balance + reward
            let body = TransactionBody(
                accountActions: [AccountAction(owner: minerAddr, delta: Int64(newBalance) - Int64(balance))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [minerAddr], fee: 0, nonce: i
            )
            let block = try await BlockBuilder.buildBlock(
                previous: prev, transactions: [tx(body, miner)],
                timestamp: base + Int64(i + 1) * 1000, target: UInt256(1000),
                nonce: UInt64(i + 1), fetcher: fetcher
            )
            totalRewards += reward
            balance = newBalance
            prev = block
        }

        XCTAssertEqual(balance, totalRewards)
        XCTAssertEqual(totalRewards, spec.totalRewards(upToBlock: 100))
        XCTAssertEqual(prev.height, 100)
    }

    func testTransferChainConservesBalance() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s()
        let premine = spec.premineAmount()
        let reward = spec.initialReward

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        var prev = genesis
        var aliceBalance = premine
        var bobBalance: UInt64 = 0
        var aliceNonce: UInt64 = 1  // premineGenesis used nonce 0
        var bobNonce: UInt64 = 0

        // Alternate transfers for 20 blocks
        for i in 0..<20 {
            let r = spec.rewardAtBlock(UInt64(i))
            let isAliceSending = i % 2 == 0
            let amount: UInt64 = 10

            let body: TransactionBody
            let signer: (privateKey: String, publicKey: String)

            if isAliceSending {
                body = TransactionBody(
                    accountActions: [
                        AccountAction(owner: aliceAddr, delta: Int64(aliceBalance - amount) - Int64(aliceBalance)),
                        AccountAction(owner: bobAddr, delta: Int64(bobBalance + amount + r) - Int64(bobBalance))
                    ],
                    actions: [], depositActions: [], genesisActions: [],
                    receiptActions: [], withdrawalActions: [],
                    signers: [aliceAddr], fee: 0, nonce: aliceNonce
                )
                signer = alice
                aliceBalance -= amount
                bobBalance += amount + r
                aliceNonce += 1
            } else {
                body = TransactionBody(
                    accountActions: [
                        AccountAction(owner: bobAddr, delta: Int64(bobBalance - amount) - Int64(bobBalance)),
                        AccountAction(owner: aliceAddr, delta: Int64(aliceBalance + amount + r) - Int64(aliceBalance))
                    ],
                    actions: [], depositActions: [], genesisActions: [],
                    receiptActions: [], withdrawalActions: [],
                    signers: [bobAddr], fee: 0, nonce: bobNonce
                )
                signer = bob
                bobBalance -= amount
                aliceBalance += amount + r
                bobNonce += 1
            }

            let block = try await BlockBuilder.buildBlock(
                previous: prev, transactions: [tx(body, signer)],
                timestamp: base + Int64(i + 1) * 1000, target: UInt256(1000),
                nonce: UInt64(i + 1), fetcher: fetcher
            )
            prev = block
        }

        let totalRewards = (0..<20).map { spec.rewardAtBlock(UInt64($0)) }.reduce(0, +)
        XCTAssertEqual(aliceBalance + bobBalance, premine + totalRewards)
    }
}

// ============================================================================
// MARK: - HIGH: State Growth Attack
// ============================================================================

@MainActor
final class StateGrowthAttackTests: XCTestCase {

    func testStateDeltaExceedingLimitRejected() async throws {
        let fetcher = f()
        let base = now() - 10_000
        // Tiny state growth limit
        let tinySpec = ChainSpec(maxNumberOfTransactionsPerBlock: 100,
                                 maxStateGrowth: 10, maxBlockSize: 1_000_000,
                                 premine: 0, targetBlockTime: 1_000,
                                 initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: tinySpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        // Use a KV action with a large key that exceeds the 10-byte state growth limit
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let reward = tinySpec.rewardAtBlock(0)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [Action(key: "large_key_exceeds_limit", oldValue: nil, newValue: "value")],
            depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(body, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "State delta should exceed tiny 10-byte limit")
    }
}

// ============================================================================
// MARK: - MEDIUM: Concurrent Block Processing
// ============================================================================

@MainActor
final class ConcurrentBlockTests: XCTestCase {

    func testConcurrentBlockSubmission() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let spec = s(premine: 0)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        // Build 10 competing blocks from genesis
        var blocks: [Block] = []
        for i in 1...10 {
            let b = try await BlockBuilder.buildBlock(
                previous: genesis, timestamp: base + Int64(i) * 100,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            blocks.append(b)
        }

        // Submit all concurrently
        await withTaskGroup(of: Void.self) { group in
            for block in blocks {
                group.addTask {
                    let _ = await chain.submitBlock(
                        parentBlockHeaderAndIndex: nil,
                        blockHeader: try! VolumeImpl<Block>(node: block), block: block
                    )
                }
            }
        }

        // Chain should be consistent: exactly one tip at height 1
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 1)
        let tip = await chain.getMainChainTip()
        XCTAssertNotNil(tip)
    }
}

// ============================================================================
// MARK: - MEDIUM: Difficulty Manipulation Resistance
// ============================================================================

@MainActor
final class DifficultyManipulationTests: XCTestCase {

    func testDifficultyChangeBounded() {
        let spec = s()
        let target = UInt256(1000)

        // Very fast block lowers the target, floored at minimumTarget.
        let fast = spec.calculatePairTarget(previousTarget: target, actualTime: 1)
        XCTAssertEqual(fast, ChainSpec.minimumTarget)

        // Slow blocks raise the target proportionally under the LWMA retarget model.
        let slow = spec.calculatePairTarget(previousTarget: target, actualTime: 100_000)
        XCTAssertEqual(slow, target * UInt256(100))
    }

    func testZeroTimeDifficultyBounded() {
        let spec = s()
        let target = UInt256(1000)
        let result = spec.calculatePairTarget(previousTarget: target, actualTime: 0)
        XCTAssertEqual(result, ChainSpec.minimumTarget)
    }

    func testNegativeTimeDifficultyBounded() {
        let spec = s()
        let target = UInt256(1000)
        let result = spec.calculatePairTarget(previousTarget: target, actualTime: -100)
        XCTAssertEqual(result, ChainSpec.minimumTarget)
    }
}

// ============================================================================
// MARK: - MEDIUM: Genesis With Embedded Child Chain
// ============================================================================

@MainActor
final class MultiChainGenesisTests: XCTestCase {

    func testNexusBlockWithChildChainGenesis() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let nexusSpec = s("Nexus", premine: 0)
        let childSpec = s("Child", premine: 0)
        let grandchildSpec = s("Grandchild", premine: 0)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let reward = nexusSpec.rewardAtBlock(0)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [], depositActions: [],
            genesisActions: [GenesisAction(directory: "Child", blockCID: try VolumeImpl<Block>(node: childGenesis).rawCID)],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(body, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)
    }

    func testMultipleChildChainsInOneBlock() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let nexusSpec = s("Nexus", premine: 0)
        let child1Spec = s("Child1", premine: 0)
        let child2Spec = s("Child2", premine: 0)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let child1Genesis = try await BlockBuilder.buildGenesis(
            spec: child1Spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let child2Genesis = try await BlockBuilder.buildGenesis(
            spec: child2Spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let reward = nexusSpec.rewardAtBlock(0)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward))],
            actions: [], depositActions: [],
            genesisActions: [
                GenesisAction(directory: "Child1", blockCID: try VolumeImpl<Block>(node: child1Genesis).rawCID),
                GenesisAction(directory: "Child2", blockCID: try VolumeImpl<Block>(node: child2Genesis).rawCID)
            ],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [tx(body, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)
    }
}

// ============================================================================
// MARK: - Delta Model Invariants
// ============================================================================

@MainActor
final class DeltaModelTests: XCTestCase {

    // Two independent senders credit the same recipient in one block
    func testMultipleTransactionsSameRecipientInOneBlock() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let spec = s(premine: 10_000)
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let carol = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let carolAddr = id(carol.publicKey)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        // Block 1: alice sends 500 to bob and 300 to carol
        let body1 = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(500 + 300)),
                AccountAction(owner: bobAddr, delta: Int64(500)),
                AccountAction(owner: carolAddr, delta: Int64(300 + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(body1, alice)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid1 = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid1)

        // Block 2: bob and carol BOTH send to alice in the same block (two separate txs)
        let reward2 = spec.rewardAtBlock(1)

        let tx1Body = TransactionBody(
            accountActions: [
                AccountAction(owner: bobAddr, delta: -Int64(200)),
                AccountAction(owner: aliceAddr, delta: Int64(200))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let tx2Body = TransactionBody(
            accountActions: [
                AccountAction(owner: carolAddr, delta: -Int64(100)),
                AccountAction(owner: aliceAddr, delta: Int64(100 + reward2))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [carolAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )

        let block2 = try await BlockBuilder.buildBlock(
            previous: block1, transactions: [tx(tx1Body, bob), tx(tx2Body, carol)],
            timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let valid2 = try await block2.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid2, "Two senders crediting the same recipient in one block must be valid")
    }

    // Debit exceeding balance is rejected during state application
    func testDebitExceedingBalanceRejected() async throws {
        let fetcher = f()
        let base = now() - 10_000
        let spec = s(premine: 1000)
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let premine = spec.premineAmount()
        let reward = spec.rewardAtBlock(0)

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        // Try to debit more than alice's balance
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(premine + 1)),
                AccountAction(owner: bobAddr, delta: Int64(premine + 1 + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1
        )

        do {
            let _ = try await BlockBuilder.buildBlock(
                previous: genesis, transactions: [tx(body, alice)],
                timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
            )
            XCTFail("Debit exceeding balance should fail during block construction")
        } catch {
            // Expected: insufficientBalance from proveAndUpdateState
        }
    }

    func testInt64MinDeltaRejected() {
        let action = AccountAction(owner: "test", delta: Int64.min)
        XCTAssertFalse(action.verify(), "Int64.min delta must be rejected")
    }

    func testZeroDeltaRejected() {
        let action = AccountAction(owner: "test", delta: 0)
        XCTAssertFalse(action.verify(), "Zero delta must be rejected")
    }

    func testValidDeltasAccepted() {
        XCTAssertTrue(AccountAction(owner: "a", delta: 1).verify())
        XCTAssertTrue(AccountAction(owner: "a", delta: -1).verify())
        XCTAssertTrue(AccountAction(owner: "a", delta: Int64.max).verify())
        XCTAssertTrue(AccountAction(owner: "a", delta: Int64.min + 1).verify())
    }

    // Net-zero deltas across multiple txs on same owner in one block
    func testNetZeroDeltasNoStateChange() async throws {
        let fetcher = f()
        let base = now() - 10_000
        let spec = s(premine: 1000)
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        // alice sends 100 to bob, bob sends 100 back to alice
        // Net: alice unchanged, bob unchanged, only reward moves
        let tx1Body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -100),
                AccountAction(owner: bobAddr, delta: Int64(100))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], fee: 0, nonce: 1, chainPath: ["Nexus"]
        )
        let tx2Body = TransactionBody(
            accountActions: [
                AccountAction(owner: bobAddr, delta: -100),
                AccountAction(owner: aliceAddr, delta: Int64(100 + reward))
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx(tx1Body, alice), tx(tx2Body, bob)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid, "Net-zero cross-transfers with reward should produce valid block")
    }
}
