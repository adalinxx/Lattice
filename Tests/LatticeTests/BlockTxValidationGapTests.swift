import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

// MARK: - Bucket-A block-tx validation gaps test phase)
//
// BTV-A1: missing-data DEFER vs permanent-reject at acceptance.
//   processBlockHeader must return `.deferred` when block content cannot be
//   resolved because of a *transient* fetch failure (the data is re-requestable
//   and a later attempt succeeds), while a genuinely-invalid but fully-resolvable
//   block must be permanently `.rejected` and stay rejected on reprocessing.
//   Exercised through the real Lattice.processBlockHeader entry point with an
//   injectable resolution-failing Fetcher.
//
// BTV-A2: a leaf-chain withdrawal whose deposit exists (so block building /
//   mempool accounting succeeds) but which has NO corresponding receipt in the
//   parent-chain frontier at apply must be REJECTED by withdrawalsAreValid —
//   the check deferred to block validation actually fires. Exercised through the
//   real Block.validateNexus entry point (the per-process child validation path).

// MARK: - Shared infrastructure

private func gapSpec(_ dir: String = "Nexus") -> ChainSpec {
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

private func gapHeader(_ block: Block) -> BlockHeader {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    return try! VolumeImpl<Block>(node: block)
}

private func gapAddr(_ publicKey: String) -> String {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    try! HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
}

private func gapSignTx(
    body: TransactionBody,
    keypair: (privateKey: String, publicKey: String)
) -> Transaction {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
    let sig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: keypair.privateKey)!
    return Transaction(signatures: [keypair.publicKey: sig], body: bodyHeader)
}

private func gapNow() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

private func storeBlock(_ block: Block, fetcher: StorableFetcher) async throws {
    let storer = CollectingStorer()
    try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
    await storer.flush(to: fetcher)
}

/// Fetcher that wraps a fully-populated `StorableFetcher` but can be told to
/// fail (throw) on specific CIDs, simulating a transient resolution failure
/// where the data is genuinely available but momentarily un-fetchable (peer
/// withholding / inflight re-request). Toggling `failing` to empty simulates
/// the data arriving after a re-request.
private final class TransientFailingFetcher: Fetcher, @unchecked Sendable {
    private let backing: StorableFetcher
    private let lock = NSLock()
    private var failing: Set<String>

    init(backing: StorableFetcher, failing: Set<String> = []) {
        self.backing = backing
        self.failing = failing
    }

    func setFailing(_ cids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        failing = cids
    }

    func fetch(rawCid: String) async throws -> Data {
        let shouldFail: Bool = {
            lock.lock(); defer { lock.unlock() }
            return failing.contains(rawCid)
        }()
        if shouldFail { throw FetcherError.notFound(rawCid) }
        return try await backing.fetch(rawCid: rawCid)
    }
}

// MARK: - BTV-A1

@MainActor
final class BlockHeaderDeferVsRejectGapTests: XCTestCase {

    /// A transient resolution failure for an *ancestor* (the parent block body,
    /// fetched by CID during validation) yields `.deferred` (not `.rejected`),
    /// and reprocessing the SAME header through the SAME fetcher once the data
    /// resolves yields `.accepted`. This proves the defer outcome is transient +
    /// re-requestable rather than poisoning the block.
    func testTransientAncestorFetchFailureDefersThenAcceptsOnReRequest() async throws {
        let backing = StorableFetcher()
        let t = gapNow()
        let easyDifficulty = UInt256.max

        let g = try await BlockBuilder.buildGenesis(
            spec: gapSpec(), timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: backing
        )
        let block = try await BlockBuilder.buildBlock(
            previous: g, timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: backing
        )
        try await storeBlock(g, fetcher: backing)
        try await storeBlock(block, fetcher: backing)

        // Fail resolution of the parent (genesis) block — the block header itself
        // carries its node inline, but its ancestor data is fetched by CID and is
        // transiently unavailable. A re-request would recover it.
        let parentCID = gapHeader(g).rawCID
        let fetcher = TransientFailingFetcher(backing: backing, failing: [parentCID])

        let level = ChainLevel(chain: ChainState.fromGenesis(block: g), children: [:])
        let lattice = Lattice(nexus: level)

        let deferred = await lattice.processBlockHeader(gapHeader(block), fetcher: fetcher)
        XCTAssertTrue(deferred.isDeferred, "Transient ancestor-resolution failure must DEFER, not reject")
        XCTAssertFalse(deferred.isRejected, "A transient fetch failure must not be a permanent rejection")
        let heightWhileDeferred = await level.chain.getHighestBlockHeight()
        XCTAssertEqual(heightWhileDeferred, 0, "Deferred blocks must not be submitted")

        // Simulate the re-request succeeding: clear the failure and reprocess
        // the SAME header through the SAME fetcher instance.
        fetcher.setFailing([])
        let accepted = await lattice.processBlockHeader(gapHeader(block), fetcher: fetcher)
        XCTAssertTrue(accepted.isAccepted, "A deferred block must become acceptable once a re-request resolves its data")
        let heightAfterAccept = await level.chain.getHighestBlockHeight()
        XCTAssertEqual(heightAfterAccept, 1, "Block must extend the chain after the re-request resolves")
    }

    /// A genuinely-invalid block (tampered postState) that is FULLY resolvable
    /// must be permanently `.rejected` — never `.deferred` — and must stay
    /// rejected when reprocessed, so a bad block cannot masquerade as missing
    /// data to be re-requested forever.
    func testGenuinelyInvalidBlockRejectsPermanentlyEvenWhenResolvable() async throws {
        let f = StorableFetcher()
        let t = gapNow()
        let easyDifficulty = UInt256.max

        let g = try await BlockBuilder.buildGenesis(
            spec: gapSpec(), timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        let validBlock = try await BlockBuilder.buildBlock(
            previous: g, timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: f
        )

        let fakePostState = VolumeImpl<LatticeState>(rawCID: "bafyfaketamperedpoststate000000000000000000000000000000000000")
        let tampered = validBlock.set(properties: [POST_STATE_PROPERTY: fakePostState])
        guard let minedTampered = BlockBuilder.mine(block: tampered, target: easyDifficulty, maxAttempts: 10) else {
            XCTFail("Could not mine tampered block"); return
        }
        try await storeBlock(g, fetcher: f)
        try await storeBlock(minedTampered, fetcher: f)

        let level = ChainLevel(chain: ChainState.fromGenesis(block: g), children: [:])
        let lattice = Lattice(nexus: level)

        let rejected = await lattice.processBlockHeader(gapHeader(minedTampered), fetcher: f)
        XCTAssertTrue(rejected.isRejected, "A fully-resolvable invalid block must be rejected")
        XCTAssertFalse(rejected.isDeferred, "A genuinely-invalid block must not be reported as deferred")

        let rejectedAgain = await lattice.processBlockHeader(gapHeader(minedTampered), fetcher: f)
        XCTAssertTrue(rejectedAgain.isRejected, "Reprocessing a fully-resolvable invalid block must stay rejected")
        let finalHeight = await level.chain.getHighestBlockHeight()
        XCTAssertEqual(finalHeight, 0)
    }
}

// MARK: - BTV-A2

@MainActor
final class WithdrawalReceiptDeferredCheckGapTests: XCTestCase {

    // Difficulty kept constant so the windowed-target recompute against a
    // genesis parent is stable (proven height-1 child validation topology).
    private let target = UInt256(1000)

    private func childSpecWithDeposit(_ depositAmount: UInt64) -> ChainSpec {
        // Premine funds the genesis deposit; nexus chain is the parent ["Nexus"].
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 1_000_000,
            premine: depositAmount,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            retargetWindow: 5
        )
    }

    /// Builds a leaf chain whose genesis already holds a deposit, plus a nexus
    /// chain whose block-1 frontier optionally holds the matching receipt, then
    /// validates the leaf withdrawal block (height 1, genesis parent) through the
    /// real Block.validateNexus entry point (per-process child validation).
    ///
    /// The withdrawal block (cb1) anchors to nexus block n2 as its parent chain
    /// block, so cb1.parentState == n2.prevState == n1.postState. The deferred
    /// withdrawalsAreValid check therefore inspects n1.postState.receiptState —
    /// present when `includeReceipt` is true, absent when false.
    private func runWithdrawalValidation(includeReceipt: Bool) async throws -> Bool {
        let fetcher = StorableFetcher()
        let t = gapNow()

        let demander = CryptoUtils.generateKeyPair()
        let demanderAddr = gapAddr(demander.publicKey)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddr = gapAddr(withdrawer.publicKey)

        let depositAmount: UInt64 = 200
        let swapNonce: UInt128 = 4242
        let cSpec = childSpecWithDeposit(depositAmount)
        let nSpec = gapSpec("Nexus")
        let nexusReward = nSpec.rewardAtBlock(1)

        let genesisTs: Int64 = t - 40_000
        let block1Ts: Int64 = t - 30_000

        // --- Leaf genesis already holds the deposit (funded by premine) ---
        let depositGenesisBody = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [
                DepositAction(nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, amountDeposited: depositAmount)
            ],
            genesisActions: [], receiptActions: [], withdrawalActions: [],
            signers: [demanderAddr], fee: 0, nonce: 0, chainPath: ["Nexus", "Payments"]
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: cSpec, transactions: [gapSignTx(body: depositGenesisBody, keypair: demander)],
            timestamp: genesisTs, target: target, fetcher: fetcher
        )

        // --- Nexus genesis + block 1; receipt (when present) lives in n1's frontier ---
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nSpec, timestamp: genesisTs, target: target, fetcher: fetcher
        )
        let n1Transactions: [Transaction]
        if includeReceipt {
            let receiptBody = TransactionBody(
                accountActions: [AccountAction(owner: withdrawerAddr, delta: Int64(nexusReward))],
                actions: [], depositActions: [],
                genesisActions: [],
                receiptActions: [
                    ReceiptAction(withdrawer: withdrawerAddr, nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, directory: "Payments")
                ],
                withdrawalActions: [],
                signers: [withdrawerAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
            )
            n1Transactions = [gapSignTx(body: receiptBody, keypair: withdrawer)]
        } else {
            n1Transactions = []
        }
        let n1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: n1Transactions,
            timestamp: block1Ts, target: target, fetcher: fetcher
        )

        // n2: built on n1 at cb1's timestamp. Under parent-homestead anchoring a
        // child's parentState is its anchor block's PREV state, so the child must
        // anchor to n2 (n2.prevState == n1.postState, which holds the receipt) to
        // see a receipt that n1 created. n2.timestamp == cb1.timestamp.
        let n2 = try await BlockBuilder.buildBlock(
            previous: n1, timestamp: block1Ts, target: target, fetcher: fetcher
        )

        // --- Leaf withdrawal block (height 1, genesis parent), anchored to n2 ---
        let childReward = cSpec.rewardAtBlock(1)
        let withdrawalBody = TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddr, delta: Int64(childReward) + Int64(depositAmount))],
            actions: [], depositActions: [],
            genesisActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: withdrawerAddr, nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, amountWithdrawn: depositAmount)
            ],
            signers: [withdrawerAddr], fee: 0, nonce: 0, chainPath: ["Nexus", "Payments"]
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [gapSignTx(body: withdrawalBody, keypair: withdrawer)],
            parentChainBlock: n2,
            timestamp: block1Ts, target: target, fetcher: fetcher
        )

        // The withdrawal-correspondence proofs THROW on a missing receipt;
        // validateNexus surfaces that as a thrown error (processBlockHeader
        // treats it as not-accepted). Either signal means "did not validate".
        do {
            let (valid, _, _) = try await childBlock1.validateNexus(
                fetcher: fetcher, chainPath: ["Nexus", "Payments"]
            )
            return valid
        } catch {
            return false
        }
    }

    /// A withdrawal claiming a real deposit but with NO matching receipt in the
    /// parent-chain frontier must be REJECTED by validateNexus — the
    /// withdrawalsAreValid check deferred to block validation actually fires.
    func testChildWithdrawalWithoutParentReceiptRejectedAtValidation() async throws {
        let valid = try await runWithdrawalValidation(includeReceipt: false)
        XCTAssertFalse(valid, "Withdrawal with no parent-chain receipt must be rejected by validateNexus")
    }

    /// Positive control: the same withdrawal anchored to a nexus frontier that
    /// DOES contain the matching receipt validates. Proves the negative-case
    /// rejection is caused by the missing receipt, not an unrelated failure.
    func testChildWithdrawalWithParentReceiptValidates() async throws {
        let valid = try await runWithdrawalValidation(includeReceipt: true)
        XCTAssertTrue(valid, "Withdrawal with a matching parent-chain receipt must validate")
    }
}
