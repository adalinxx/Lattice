import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

// MARK: - Helpers

private let target = UInt256(1000)

private func makeSpec(_ dir: String = "Nexus", premine: UInt64 = 0) -> ChainSpec {
    ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
}

private func addr(_ publicKey: String) -> String {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    try! HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
}

private func sign(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    let h = try! HeaderImpl<TransactionBody>(node: body)
    let s = TransactionSigning.sign(bodyHeader: h, privateKeyHex: kp.privateKey)!
    return Transaction(signatures: [kp.publicKey: s], body: h)
}

private func storeBlock(_ block: Block, to fetcher: StorableFetcher) async throws {
    let storer = CollectingStorer()
    try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
    await storer.flush(to: fetcher)
}

/// Pins the prevState (homestead) continuity invariants at the PRODUCTION
/// validation entry points — `validateGenesis` and `validateNexus` — the rules
/// every admitted block passes through `processBlockHeader`:
///   - genesis: height == 0 and prevState == the empty state root
///   - non-genesis: prevState == parent.postState (state-chain continuity)
/// (Formerly asserted against the deleted embedded-child helper
/// `validatePrevStateContinuity`.)
@MainActor
final class HomesteadContinuityTests: XCTestCase {

    // MARK: - Genesis (validateGenesis)

    func testGenesisWithNonZeroHeightRejected() async throws {
        let spec = makeSpec("Payments")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        let forged = Block(
            parent: nil,
            transactions: try BlockBuilder.buildTransactionsDictionary([]),
            target: target,
            nextTarget: target,
            spec: try! VolumeImpl<ChainSpec>(node: spec),
            parentState: Reference(LatticeState.emptyHeader),
            prevState: Reference(LatticeState.emptyHeader),
            postState: LatticeState.emptyHeader,
            children: try BlockBuilder.buildChildrenDictionary([:]),
            height: 7, // WRONG: genesis must be height 0
            timestamp: now,
            nonce: 0
        )
        try await storeBlock(forged, to: fetcher)

        let (valid, _) = try await forged.validateGenesis(fetcher: fetcher, directory: "Payments")
        XCTAssertFalse(valid, "Genesis with non-zero height must be rejected by validateGenesis")
    }

    func testGenesisWithNonEmptyPrevStateRejected() async throws {
        let nexusSpec = makeSpec("Nexus")
        let childSpec = makeSpec("Payments")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        // Build a real non-empty state root to use as a fake prevState.
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: now - 30_000, target: target, fetcher: fetcher
        )
        let ts1 = now - 20_000
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(nexusSpec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0
            ), kp)],
            timestamp: ts1, target: target, fetcher: fetcher
        )

        let forged = Block(
            parent: nil,
            transactions: try BlockBuilder.buildTransactionsDictionary([]),
            target: target,
            nextTarget: target,
            spec: try! VolumeImpl<ChainSpec>(node: childSpec),
            parentState: Reference(LatticeState.emptyHeader),
            prevState: Reference(nexusBlock1.postState), // WRONG: genesis must start from the empty state
            postState: nexusBlock1.postState,
            children: try BlockBuilder.buildChildrenDictionary([:]),
            height: 0,
            timestamp: now,
            nonce: 0
        )
        try await storeBlock(nexusGenesis, to: fetcher)
        try await storeBlock(nexusBlock1, to: fetcher)
        try await storeBlock(forged, to: fetcher)

        let (valid, _) = try await forged.validateGenesis(fetcher: fetcher, directory: "Payments")
        XCTAssertFalse(valid, "Genesis with non-empty prevState must be rejected by validateGenesis")
    }

    // MARK: - Non-genesis (validateNexus)

    func testForgedPrevStateRejectedByValidateNexus() async throws {
        // Block claims a prevState that doesn't match its parent's postState —
        // the critical continuity break: accepting it would let a forged state
        // root enter the chain and downstream proofs anchor against it.
        let spec = makeSpec("Nexus")
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = addr(kp.publicKey)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let fetcher = StorableFetcher()

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: now - 50_000, target: target, fetcher: fetcher
        )
        // Block 1 carries a coinbase so block1.postState != genesis.postState.
        let ts1 = now - 40_000
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis,
            transactions: [sign(TransactionBody(
                accountActions: [AccountAction(owner: ownerAddr, delta: Int64(spec.rewardAtBlock(1)))],
                actions: [], depositActions: [], genesisActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [ownerAddr], fee: 0, nonce: 0, chainPath: ["Nexus"]
            ), kp)],
            timestamp: ts1, target: target, fetcher: fetcher
        )

        let forged = Block(
            parent: Reference(try! VolumeImpl<Block>(node: block1)),
            transactions: try BlockBuilder.buildTransactionsDictionary([]),
            target: target,
            nextTarget: target,
            spec: try! VolumeImpl<ChainSpec>(node: spec),
            parentState: Reference(LatticeState.emptyHeader),
            prevState: Reference(genesis.postState), // WRONG: should equal block1.postState
            postState: genesis.postState,
            children: try BlockBuilder.buildChildrenDictionary([:]),
            height: 2,
            timestamp: now - 30_000,
            nonce: 0
        )

        try await storeBlock(genesis, to: fetcher)
        try await storeBlock(block1, to: fetcher)
        try await storeBlock(forged, to: fetcher)

        let (valid, _, _) = try await forged.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid, "prevState != parent.postState must be rejected by validateNexus")
    }
}
