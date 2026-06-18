import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

// MARK: - Shared Test Infrastructure

private func makeFetcher() -> StorableFetcher { StorableFetcher() }

private func childSpec(_ dir: String = "Child") -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1024,
        halvingInterval: 10_000,
        retargetWindow: 5
    )
}

private func nexusSpec(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1024,
        halvingInterval: 10_000,
        retargetWindow: 5
    )
}

private func signTx(
    body: TransactionBody,
    keypairs: [(privateKey: String, publicKey: String)]
) -> Transaction {
    let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
    var sigs = [String: String]()
    for kp in keypairs {
        sigs[kp.publicKey] = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: kp.privateKey)!
    }
    return Transaction(signatures: sigs, body: bodyHeader)
}

private func signTx(
    body: TransactionBody,
    keypair: (privateKey: String, publicKey: String)
) -> Transaction {
    signTx(body: body, keypairs: [keypair])
}

private func addr(_ publicKey: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
}

private func now() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

// MARK: - Deposit State Tests

@MainActor
final class DepositStateTests: XCTestCase {

    func testDepositInsertsIntoState() async throws {
        let fetcher = makeFetcher()
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let spec = childSpec()
        let reward = spec.rewardAtBlock(0)
        let t = now()

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        let depositAmount: UInt64 = 100
        let depositNonce: UInt128 = 42

        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: kpAddr, delta: Int64(reward) - Int64(depositAmount))
            ],
            actions: [], depositActions: [
                DepositAction(nonce: depositNonce, demander: kpAddr, amountDemanded: depositAmount, amountDeposited: depositAmount)
            ],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let tx = signTx(body: body, keypair: kp)

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx],
            timestamp: t - 10_000, target: UInt256(1000), fetcher: fetcher
        )

        // Verify frontier state contains the deposit
        guard let frontierNode = block.postState.node else {
            XCTFail("Frontier should be resolved"); return
        }
        let depositKey = DepositKey(nonce: depositNonce, demander: kpAddr, amountDemanded: depositAmount).description
        let stored: UInt64? = try? frontierNode.depositState.node?.get(key: depositKey)
        XCTAssertEqual(stored, depositAmount, "Deposit should be stored in state")
    }

    func testDepositVariableRateAccepted() {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)

        let body = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [
                DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 100, amountDeposited: 50)
            ],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        XCTAssertTrue(body.depositActionsAreValid(), "amountDeposited may differ from amountDemanded for variable-rate swaps")
    }

    func testDepositZeroAmountRejected() {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)

        let body = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [
                DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 0, amountDeposited: 0)
            ],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        XCTAssertFalse(body.depositActionsAreValid(), "Zero deposit should be rejected")
    }

    func testDepositRequiresDemandInSigners() {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let other = CryptoUtils.generateKeyPair()
        let otherAddr = addr(other.publicKey)

        let body = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [
                DepositAction(nonce: 1, demander: otherAddr, amountDemanded: 100, amountDeposited: 100)
            ],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        XCTAssertFalse(body.depositActionsAreValid(), "Demander not in signers should be rejected")
    }

    func testDuplicateDepositKeysInBlockRejected() async throws {
        let fetcher = makeFetcher()

        let emptyState = LatticeState.emptyState()
        let depositAction = DepositAction(nonce: 1, demander: "alice", amountDemanded: 100, amountDeposited: 100)

        do {
            let _ = try await emptyState.depositState.proveAndUpdateState(
                allDepositActions: [depositAction, depositAction], fetcher: fetcher
            )
            XCTFail("Duplicate deposit keys in same block should throw")
        } catch {
            // Expected: conflicting actions
        }
    }
}

// MARK: - Receipt State Tests

@MainActor
final class ReceiptStateTests: XCTestCase {

    func testReceiptRequiresWithdrawerInSigners() {
        let demander = CryptoUtils.generateKeyPair()
        let demanderAddr = addr(demander.publicKey)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddr = addr(withdrawer.publicKey)
        let thirdParty = CryptoUtils.generateKeyPair()
        let thirdPartyAddr = addr(thirdParty.publicKey)

        // Receipt signed by a third party (not the withdrawer) — should be rejected
        // because the receipt debits the withdrawer's nexus funds
        let bodyMissing = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: withdrawerAddr, nonce: 1, demander: demanderAddr, amountDemanded: 100, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [thirdPartyAddr], fee: 0, nonce: 0
        )
        XCTAssertFalse(bodyMissing.receiptActionsAreValid(),
            "Withdrawer must be in signers — their funds are debited by the receipt")

        // Receipt signed by withdrawer — should pass
        let bodyValid = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: withdrawerAddr, nonce: 1, demander: demanderAddr, amountDemanded: 100, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [withdrawerAddr], fee: 0, nonce: 0
        )
        XCTAssertTrue(bodyValid.receiptActionsAreValid(),
            "Receipt with withdrawer in signers should be valid")
    }

    func testReceiptInsertsIntoState() async throws {
        let fetcher = makeFetcher()
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddr = addr(withdrawer.publicKey)

        let emptyState = LatticeState.emptyState()

        let receiptAction = ReceiptAction(
            withdrawer: withdrawerAddr, nonce: 42, demander: kpAddr,
            amountDemanded: 100, directory: "Child"
        )

        let (updatedReceiptState, _) = try await emptyState.receiptState.proveAndUpdateState(
            allReceiptActions: [receiptAction], fetcher: fetcher
        )

        let receiptKey = ReceiptKey(receiptAction: receiptAction).description
        let stored: HeaderImpl<PublicKey>? = try? updatedReceiptState.node?.get(key: receiptKey)
        XCTAssertNotNil(stored, "Receipt should be stored in state")
        XCTAssertEqual(stored?.rawCID, withdrawerAddr, "Stored withdrawer should match")
    }

    func testDuplicateReceiptKeysInBlockRejected() async throws {
        let fetcher = makeFetcher()
        let kpAddr = "demanderAddr"
        let withdrawerAddr = "withdrawerAddr"

        let emptyState = LatticeState.emptyState()
        let receiptAction = ReceiptAction(
            withdrawer: withdrawerAddr, nonce: 1, demander: kpAddr,
            amountDemanded: 100, directory: "Child"
        )

        do {
            let _ = try await emptyState.receiptState.proveAndUpdateState(
                allReceiptActions: [receiptAction, receiptAction], fetcher: fetcher
            )
            XCTFail("Duplicate receipt keys in same block should throw")
        } catch {
            // Expected
        }
    }
}

// MARK: - Withdrawal Validation Tests

@MainActor
final class WithdrawalValidationTests: XCTestCase {

    func testWithdrawalVariableRateAccepted() {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)

        let body = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: "someone", amountDemanded: 100, amountWithdrawn: 50)
            ],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        XCTAssertTrue(body.withdrawalActionsAreValid(), "amountWithdrawn may differ from amountDemanded; storage check happens at state-application time")
    }

    func testWithdrawalZeroAmountRejected() {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)

        let body = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: "someone", amountDemanded: 0, amountWithdrawn: 0)
            ],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        XCTAssertFalse(body.withdrawalActionsAreValid(), "Zero withdrawal should be rejected")
    }

    func testWithdrawalRequiresWithdrawerInSigners() {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let other = CryptoUtils.generateKeyPair()
        let otherAddr = addr(other.publicKey)

        let body = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: otherAddr, nonce: 1, demander: kpAddr, amountDemanded: 100, amountWithdrawn: 100)
            ],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        XCTAssertFalse(body.withdrawalActionsAreValid(), "Withdrawer not in signers should be rejected")
    }

    func testDuplicateWithdrawalKeysInBlockRejected() async throws {
        let fetcher = makeFetcher()
        let emptyState = LatticeState.emptyState()

        // First insert a deposit to withdraw from
        let depositAction = DepositAction(nonce: 1, demander: "alice", amountDemanded: 100, amountDeposited: 100)
        let (withDeposit, _) = try await emptyState.depositState.proveAndUpdateState(
            allDepositActions: [depositAction], fetcher: fetcher
        )

        // Try to withdraw twice with the same key
        let wa = WithdrawalAction(withdrawer: "bob", nonce: 1, demander: "alice", amountDemanded: 100, amountWithdrawn: 100)
        do {
            let _ = try await withDeposit.proveAndDeleteForWithdrawals(
                allWithdrawalActions: [wa, wa], fetcher: fetcher
            )
            XCTFail("Duplicate withdrawal keys should throw")
        } catch {
            // Expected: conflicting actions from duplicate key check
        }
    }
}

// MARK: - Nexus Action Restrictions

@MainActor
final class NexusActionRestrictionTests: XCTestCase {

    func testNexusRejectsDepositActions() async throws {
        let fetcher = makeFetcher()
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let spec = nexusSpec()

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: now() - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        //: chainPath is the correct ["Nexus"] so the empty-chainPath
        // rejection cannot mask the deposit rule — the rejection must come from
        // the deposit-on-root consensus check itself.
        let body = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [
                DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 100, amountDeposited: 100)
            ],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let tx = signTx(body: body, keypair: kp)

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx],
            timestamp: now() - 10_000, target: UInt256(1000), fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "Nexus must reject transactions with deposit actions")
    }

    func testNexusRejectsWithdrawalActions() async throws {
        let fetcher = makeFetcher()
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let spec = nexusSpec()

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: now() - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        let body = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: 100, amountWithdrawn: 100)
            ],
            signers: [kpAddr], fee: 0, nonce: 0
        )
        let tx = signTx(body: body, keypair: kp)

        do {
            _ = try await BlockBuilder.buildBlock(
                previous: genesis, transactions: [tx],
                timestamp: now() - 10_000, target: UInt256(1000), fetcher: fetcher
            )
            XCTFail("Nexus withdrawal actions must fail closed during block construction")
        } catch StateErrors.conflictingActions {
            // expected
        }
    }

    func testNexusAcceptsReceiptActions() async throws {
        let fetcher = makeFetcher()
        let demander = CryptoUtils.generateKeyPair()
        let demanderAddr = addr(demander.publicKey)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddr = addr(withdrawer.publicKey)
        let spec = nexusSpec()
        let reward = spec.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: now() - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        // Withdrawer gets the block reward (funds the receipt payment to demander)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddr, delta: Int64(reward))],
            actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: withdrawerAddr, nonce: 1, demander: demanderAddr, amountDemanded: 100, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [withdrawerAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let tx = signTx(body: body, keypair: withdrawer)

        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [tx],
            timestamp: now() - 10_000, target: UInt256(1000), fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid, "Nexus should accept receipt actions")
    }
}

// MARK: - Atomic Swap Auto-Claim Tests

@MainActor
final class AtomicSwapCycleTests: XCTestCase {

    /// Verifies the seller receives nexus payment automatically when the receipt is mined,
    /// without any explicit claim transaction. This is the "auto-claim" for sellers.
    func testSellerAutoReceivesNexusPaymentViaReceipt() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let seller = CryptoUtils.generateKeyPair()
        let sellerAddr = addr(seller.publicKey)
        let buyer = CryptoUtils.generateKeyPair()
        let buyerAddr = addr(buyer.publicKey)
        let nSpec = nexusSpec()
        let nexusReward = nSpec.rewardAtBlock(1)
        let swapNonce: UInt128 = 77
        let swapAmount: UInt64 = 500

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nSpec, timestamp: t - 30_000, target: UInt256(1000), fetcher: fetcher
        )

        // Seller has 0 nexus balance initially
        let sellerBefore: UInt64 = (try? nexusGenesis.postState.node?.accountState.node?.get(key: sellerAddr)) ?? 0
        XCTAssertEqual(sellerBefore, 0, "Seller should have 0 nexus balance before receipt")

        // Block 1: buyer gets block reward and submits receipt → seller auto-credited
        let receiptBody = TransactionBody(
            accountActions: [
                AccountAction(owner: buyerAddr, delta: Int64(nexusReward))
            ],
            actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: buyerAddr, nonce: swapNonce,
                              demander: sellerAddr, amountDemanded: swapAmount, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [buyerAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let nexusBlock = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [signTx(body: receiptBody, keypair: buyer)],
            timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        let frontier = nexusBlock.postState.node!

        // Seller auto-credited via implicit receipt transfer (no claim tx needed)
        let sellerAfter: UInt64 = (try? frontier.accountState.node?.get(key: sellerAddr)) ?? 0
        XCTAssertEqual(sellerAfter, swapAmount,
                       "Seller should auto-receive nexus payment when receipt is mined — no separate claim needed")

        // Buyer: explicit +nexusReward, implicit -swapAmount from receipt
        let buyerAfter: UInt64 = (try? frontier.accountState.node?.get(key: buyerAddr)) ?? 0
        XCTAssertEqual(buyerAfter, nexusReward - swapAmount,
                       "Buyer balance: block reward minus implicit receipt transfer")

        let valid = try await nexusBlock.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid, "Nexus block with receipt should be valid")
    }

    /// Verifies a second withdrawal on the same deposit key is rejected (replay protection).
    func testDoubleWithdrawalRejected() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let seller = CryptoUtils.generateKeyPair()
        let sellerAddr = addr(seller.publicKey)
        let buyer = CryptoUtils.generateKeyPair()
        let buyerAddr = addr(buyer.publicKey)
        let cSpec = childSpec()
        let childReward1 = cSpec.rewardAtBlock(1)
        let childReward2 = cSpec.rewardAtBlock(2)
        let childReward3 = cSpec.rewardAtBlock(3)
        let swapNonce: UInt128 = 42
        let swapAmount: UInt64 = 100

        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: cSpec, timestamp: t - 40_000, target: UInt256(1000), fetcher: fetcher
        )

        // Block 1: seller deposits (funded by block reward)
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: sellerAddr, delta: Int64(childReward1) - Int64(swapAmount))],
            actions: [],
            depositActions: [
                DepositAction(nonce: swapNonce, demander: sellerAddr,
                              amountDemanded: swapAmount, amountDeposited: swapAmount)
            ],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [sellerAddr], fee: 0, nonce: 0
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [signTx(body: depositBody, keypair: seller)],
            timestamp: t - 30_000, target: UInt256(1000), fetcher: fetcher
        )

        // Block 2: first withdrawal (valid — buyer claims deposit)
        let withdrawBody1 = TransactionBody(
            accountActions: [AccountAction(owner: buyerAddr, delta: Int64(childReward2 + swapAmount))],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: buyerAddr, nonce: swapNonce,
                                 demander: sellerAddr, amountDemanded: swapAmount, amountWithdrawn: swapAmount)
            ],
            signers: [buyerAddr], fee: 0, nonce: 0
        )
        let childBlock2 = try await BlockBuilder.buildBlock(
            previous: childBlock1, transactions: [signTx(body: withdrawBody1, keypair: buyer)],
            timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        // Deposit should be consumed
        let depositKey = DepositKey(nonce: swapNonce, demander: sellerAddr, amountDemanded: swapAmount).description
        let depositAfter: UInt64? = try? childBlock2.postState.node?.depositState.node?.get(key: depositKey)
        XCTAssertNil(depositAfter, "Deposit should be consumed after first withdrawal")

        // Block 3: second withdrawal on same key — should be invalid
        let withdrawBody2 = TransactionBody(
            accountActions: [AccountAction(owner: buyerAddr, delta: Int64(childReward3 + swapAmount))],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: buyerAddr, nonce: swapNonce,
                                 demander: sellerAddr, amountDemanded: swapAmount, amountWithdrawn: swapAmount)
            ],
            signers: [buyerAddr], fee: 0, nonce: 1
        )
        do {
            _ = try await BlockBuilder.buildBlock(
                previous: childBlock2, transactions: [signTx(body: withdrawBody2, keypair: buyer)],
                timestamp: t - 10_000, target: UInt256(1000), fetcher: fetcher
            )
            XCTFail("Double withdrawal from same deposit should fail closed")
        } catch StateErrors.conflictingActions {
            // expected
        }
    }

}

// MARK: - Full Cross-Chain Flow: Deposit → Receipt → Withdrawal

@MainActor
final class CrossChainFlowTests: XCTestCase {

    /// End-to-end: deposit on child chain, receipt on nexus, withdrawal on child chain
    func testFullDepositReceiptWithdrawalFlow() async throws {
        let fetcher = makeFetcher()
        let t = now()

        let demander = CryptoUtils.generateKeyPair()
        let demanderAddr = addr(demander.publicKey)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddr = addr(withdrawer.publicKey)

        let nSpec = nexusSpec()
        let cSpec = childSpec()
        let childReward = cSpec.rewardAtBlock(0)
        let nexusReward = nSpec.rewardAtBlock(0)
        let depositAmount: UInt64 = 200
        let swapNonce: UInt128 = 999

        // --- Step 1: Build child chain genesis ---
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: cSpec, timestamp: t - 30_000, target: UInt256(1000), fetcher: fetcher
        )

        // --- Step 2: Deposit on child chain (demander deposits, locking funds) ---
        let depositBody = TransactionBody(
            accountActions: [
                AccountAction(owner: demanderAddr, delta: Int64(childReward) - Int64(depositAmount))
            ],
            actions: [],
            depositActions: [
                DepositAction(nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, amountDeposited: depositAmount)
            ],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [demanderAddr], fee: 0, nonce: 0
        )
        let depositTx = signTx(body: depositBody, keypair: demander)

        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [depositTx],
            timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        // Verify deposit is in child chain state
        guard let childFrontier1 = childBlock1.postState.node else {
            XCTFail("Child frontier should be resolved"); return
        }
        let depositKey = DepositKey(nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount).description
        let depositStored: UInt64? = try? childFrontier1.depositState.node?.get(key: depositKey)
        XCTAssertEqual(depositStored, depositAmount, "Deposit should exist in child state")

        // --- Step 3: Receipt on nexus (withdrawer pays demander) ---
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nSpec, timestamp: t - 30_000, target: UInt256(1000), fetcher: fetcher
        )

        // Withdrawer gets the block reward and pays demander via receipt
        let receiptBody = TransactionBody(
            accountActions: [
                AccountAction(owner: withdrawerAddr, delta: Int64(nexusReward))
            ],
            actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: withdrawerAddr, nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [withdrawerAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
        )
        let receiptTx = signTx(body: receiptBody, keypair: withdrawer)

        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [receiptTx],
            timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )
        let nexusValid = try await nexusBlock1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(nexusValid, "Nexus block with receipt should validate")

        // Verify receipt is in nexus state
        guard let nexusFrontier1 = nexusBlock1.postState.node else {
            XCTFail("Nexus frontier should be resolved"); return
        }
        let receiptKey = ReceiptKey(
            withdrawalAction: WithdrawalAction(
                withdrawer: withdrawerAddr, nonce: swapNonce,
                demander: demanderAddr, amountDemanded: depositAmount, amountWithdrawn: depositAmount
            ),
            directory: "Child"
        ).description
        let receiptStored: HeaderImpl<PublicKey>? = try? nexusFrontier1.receiptState.node?.get(key: receiptKey)
        XCTAssertNotNil(receiptStored, "Receipt should exist in nexus state")
        XCTAssertEqual(receiptStored?.rawCID, withdrawerAddr, "Receipt withdrawer should match")

        // --- Step 4: Withdrawal on child chain (withdrawer claims deposit) ---
        let withdrawalBody = TransactionBody(
            accountActions: [
                AccountAction(owner: withdrawerAddr, delta: Int64(childReward) + Int64(depositAmount))
            ],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: withdrawerAddr, nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, amountWithdrawn: depositAmount)
            ],
            signers: [withdrawerAddr], fee: 0, nonce: 0
        )
        let withdrawalTx = signTx(body: withdrawalBody, keypair: withdrawer)

        // Build child block 2 that includes the withdrawal
        // parentHomestead must be the nexus frontier (contains the receipt)
        let childBlock2 = try await BlockBuilder.buildBlock(
            previous: childBlock1, transactions: [withdrawalTx],
            parentChainBlock: nexusBlock1,
            timestamp: t - 10_000, target: UInt256(1000), fetcher: fetcher
        )

        // Verify withdrawal: deposit should be deleted from child state
        guard let childFrontier2 = childBlock2.postState.node else {
            XCTFail("Child frontier 2 should be resolved"); return
        }

        // Deposit should be gone
        let depositStored2: UInt64? = try? childFrontier2.depositState.node?.get(key: depositKey)
        XCTAssertNil(depositStored2, "Deposit should be deleted after withdrawal")

        // Withdrawer should have the credited amount
        let withdrawerBalance: UInt64? = try? childFrontier2.accountState.node?.get(key: withdrawerAddr)
        XCTAssertEqual(withdrawerBalance, childReward + depositAmount,
            "Withdrawer should receive reward + withdrawn amount")
    }

    /// Withdrawal by wrong person should fail — receipt stores the authorized withdrawer
    func testWithdrawalByWrongPersonFails() async throws {
        let fetcher = makeFetcher()
        let t = now()

        let demander = CryptoUtils.generateKeyPair()
        let demanderAddr = addr(demander.publicKey)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddr = addr(withdrawer.publicKey)
        let attacker = CryptoUtils.generateKeyPair()
        let attackerAddr = addr(attacker.publicKey)

        let cSpec = childSpec()
        let nSpec = nexusSpec()
        let childReward = cSpec.rewardAtBlock(0)
        let nexusReward = nSpec.rewardAtBlock(0)
        let depositAmount: UInt64 = 200
        let swapNonce: UInt128 = 888

        // Deposit on child
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: cSpec, timestamp: t - 30_000, target: UInt256(1000), fetcher: fetcher
        )
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: demanderAddr, delta: Int64(childReward) - Int64(depositAmount))],
            actions: [], depositActions: [
                DepositAction(nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, amountDeposited: depositAmount)
            ],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [demanderAddr], fee: 0, nonce: 0
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [signTx(body: depositBody, keypair: demander)],
            timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        // Receipt on nexus — authorized to `withdrawer`, not `attacker`
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nSpec, timestamp: t - 30_000, target: UInt256(1000), fetcher: fetcher
        )
        // Withdrawer pays demander via receipt (funded by block reward)
        let receiptBody = TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddr, delta: Int64(nexusReward))],
            actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: withdrawerAddr, nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [withdrawerAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [signTx(body: receiptBody, keypair: withdrawer)],
            timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        // Attacker tries to withdraw — should fail because receipt.withdrawer != attacker
        let attackBody = TransactionBody(
            accountActions: [AccountAction(owner: attackerAddr, delta: Int64(childReward) + Int64(depositAmount))],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: attackerAddr, nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, amountWithdrawn: depositAmount)
            ],
            signers: [attackerAddr], fee: 0, nonce: 0
        )
        let attackTx = signTx(body: attackBody, keypair: attacker)

        // Block builds (frontier computation doesn't check withdrawer identity),
        // but validation rejects: proveExistenceAndVerifyWithdrawers checks stored.rawCID != wa.withdrawer
        let _ = try await BlockBuilder.buildBlock(
            previous: childBlock1, transactions: [attackTx],
            parentChainBlock: nexusBlock1,
            timestamp: t - 10_000, target: UInt256(1000), fetcher: fetcher
        )

        // Verify the receipt stores the legitimate withdrawer, not the attacker
        guard let nexusFrontier = nexusBlock1.postState.node else {
            XCTFail("Nexus frontier should be resolved"); return
        }
        let receiptKey = ReceiptKey(
            withdrawalAction: WithdrawalAction(
                withdrawer: attackerAddr, nonce: swapNonce,
                demander: demanderAddr, amountDemanded: depositAmount, amountWithdrawn: depositAmount
            ),
            directory: "Child"
        ).description
        let storedReceipt: HeaderImpl<PublicKey>? = try? nexusFrontier.receiptState.node?.get(key: receiptKey)
        XCTAssertNotNil(storedReceipt, "Receipt should exist in nexus state")
        XCTAssertNotEqual(storedReceipt?.rawCID, attackerAddr,
            "Receipt withdrawer doesn't match attacker — proveExistenceAndVerifyWithdrawers rejects this at validation time")
    }

    /// Receipt requires withdrawer authorization since their funds are debited
    func testReceiptWithdrawerMustSign() {
        let attacker = CryptoUtils.generateKeyPair()
        let attackerAddr = addr(attacker.publicKey)
        let legitimate = CryptoUtils.generateKeyPair()
        let legitimateAddr = addr(legitimate.publicKey)

        // Withdrawer signs — valid
        let body = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: attackerAddr, nonce: 1, demander: legitimateAddr, amountDemanded: 100, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [attackerAddr], fee: 0, nonce: 0
        )
        XCTAssertTrue(body.receiptActionsAreValid(),
            "Receipt with withdrawer in signers should be valid")
    }

    func testWithdrawalWithoutDepositFails() async throws {
        let fetcher = makeFetcher()
        let t = now()

        let demander = CryptoUtils.generateKeyPair()
        let demanderAddr = addr(demander.publicKey)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddr = addr(withdrawer.publicKey)

        let cSpec = childSpec()
        let nSpec = nexusSpec()
        let nexusReward = nSpec.rewardAtBlock(0)
        let childReward = cSpec.rewardAtBlock(0)
        let depositAmount: UInt64 = 200
        let swapNonce: UInt128 = 777

        // Create child genesis without any deposit
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: cSpec, timestamp: t - 30_000, target: UInt256(1000), fetcher: fetcher
        )

        // Create receipt on nexus (no corresponding deposit exists on child)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nSpec, timestamp: t - 30_000, target: UInt256(1000), fetcher: fetcher
        )
        // Withdrawer pays demander via receipt (funded by block reward)
        let receiptBody = TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddr, delta: Int64(nexusReward))],
            actions: [], depositActions: [],
            genesisActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: withdrawerAddr, nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [withdrawerAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [signTx(body: receiptBody, keypair: withdrawer)],
            timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        // Attempt withdrawal without deposit — should fail
        let withdrawalBody = TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddr, delta: Int64(childReward) + Int64(depositAmount))],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: withdrawerAddr, nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, amountWithdrawn: depositAmount)
            ],
            signers: [withdrawerAddr], fee: 0, nonce: 0
        )
        let tx = signTx(body: withdrawalBody, keypair: withdrawer)

        do {
            _ = try await BlockBuilder.buildBlock(
                previous: childGenesis, transactions: [tx],
                parentChainBlock: nexusBlock1,
                timestamp: t - 10_000, target: UInt256(1000), fetcher: fetcher
            )
            XCTFail("Withdrawal without a deposit must fail closed during accounting")
        } catch StateErrors.conflictingActions {
            // expected
        }

        guard let homesteadNode = childGenesis.postState.node else {
            XCTFail("Homestead should be resolved"); return
        }
        let depositKey = DepositKey(withdrawalAction: WithdrawalAction(
            withdrawer: withdrawerAddr, nonce: swapNonce,
            demander: demanderAddr, amountDemanded: depositAmount, amountWithdrawn: depositAmount
        )).description
        let depositExists: UInt64? = try? homesteadNode.depositState.node?.get(key: depositKey)
        XCTAssertNil(depositExists,
            "Deposit does not exist, so accounting rejects the withdrawal")
    }
}

// MARK: - Overflow Safety Tests

@MainActor
final class OverflowSafetyTests: XCTestCase {

    func testGetTotalDepositedOverflow() {
        let actions = [
            DepositAction(nonce: 1, demander: "a", amountDemanded: UInt64.max, amountDeposited: UInt64.max),
            DepositAction(nonce: 2, demander: "a", amountDemanded: 1, amountDeposited: 1),
        ]
        let (_, overflow) = Block.getTotalDeposited(actions)
        XCTAssertTrue(overflow, "Should detect overflow")
    }

    func testGetTotalWithdrawnOverflow() {
        let actions = [
            WithdrawalAction(withdrawer: "a", nonce: 1, demander: "b", amountDemanded: UInt64.max, amountWithdrawn: UInt64.max),
            WithdrawalAction(withdrawer: "a", nonce: 2, demander: "b", amountDemanded: 1, amountWithdrawn: 1),
        ]
        let (_, overflow) = Block.getTotalWithdrawn(actions)
        XCTAssertTrue(overflow, "Should detect overflow")
    }

    func testGetTotalDepositedNoOverflow() {
        let actions = [
            DepositAction(nonce: 1, demander: "a", amountDemanded: 100, amountDeposited: 100),
            DepositAction(nonce: 2, demander: "a", amountDemanded: 200, amountDeposited: 200),
        ]
        let (total, overflow) = Block.getTotalDeposited(actions)
        XCTAssertFalse(overflow)
        XCTAssertEqual(total, 300)
    }
}
