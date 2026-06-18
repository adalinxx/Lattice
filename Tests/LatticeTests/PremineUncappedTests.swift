import XCTest
@testable import Lattice
import UInt256
import cashew

/// Coverage for the removal of the `premine < halvingInterval` cap
/// (`ChainSpec.isValid`). Premine is a block-count offset into the emission
/// schedule, so a premine spanning one or more full halving epochs — up to a
/// fully-premined, zero-ongoing-emission chain — is now valid. These tests
/// prove the emission math (`premineAmount`/`rewardAtBlock`/`totalRewards`) and
/// genesis conservation stay correct across that range.
@MainActor
final class PremineUncappedTests: XCTestCase {

    private let initialReward: UInt64 = 1024      // 2^10 → 11 nonzero halvings (1024…1)
    private let halvingInterval: UInt64 = 10_000

    private func spec(premine: UInt64, directory: String = "Nexus") -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 1000,
            maxStateGrowth: 1_000_000,
            maxBlockSize: 1_000_000,
            premine: premine,
            targetBlockTime: 10_000,
            initialReward: initialReward,
            halvingInterval: halvingInterval,
            retargetWindow: 5
        )
    }

    /// Σ over all halvings of `(initialReward >> h) * halvingInterval`, the fixed
    /// lifetime supply of the UNSHIFTED schedule. For 1024 / 10_000 that is
    /// 10_000 × (1024 + 512 + … + 1) = 10_000 × 2047 = 20_470_000.
    private var unshiftedTotalSupply: UInt64 {
        spec(premine: 0).totalRewards(upToBlock: 1_000_000)
    }

    // MARK: - isValid

    func testPremineAtAndBeyondHalvingIntervalIsValid() {
        XCTAssertTrue(spec(premine: halvingInterval).isValid, "premine == halvingInterval must be valid (cap removed)")
        XCTAssertTrue(spec(premine: halvingInterval * 3 + 1234).isValid, "premine spanning multiple halvings must be valid")
        XCTAssertTrue(spec(premine: halvingInterval * 64).isValid, "a fully-premined chain must be valid")
        XCTAssertTrue(spec(premine: UInt64.max).isValid, "an extreme premine must not be rejected by isValid")
    }

    // MARK: - premineAmount across halving boundaries

    func testPremineAmountSumsAcrossHalvingPeriods() {
        // premine = 1.5 halving intervals:
        //   blocks      0..10_000 at reward 1024 → 10_240_000
        //   blocks 10_000..15_000 at reward  512 →  2_560_000
        let s = spec(premine: 15_000)
        XCTAssertEqual(s.premineAmount(), 10_240_000 + 2_560_000)
    }

    func testFullyPreminedChainCapturesEntireSupplyAndMinesNothing() {
        // premine large enough to consume every nonzero-reward block.
        let s = spec(premine: halvingInterval * 64)
        XCTAssertEqual(s.premineAmount(), unshiftedTotalSupply, "a fully-premined chain's genesis credit is the whole supply")
        XCTAssertEqual(s.rewardAtBlock(0), 0, "no block reward remains to mine")
        XCTAssertEqual(s.rewardAtBlock(100_000), 0)
        // Conservation still holds (genesis credit + zero mining == total).
        XCTAssertEqual(s.premineAmount() + s.totalRewards(upToBlock: 1_000_000), unshiftedTotalSupply)
    }

    func testPremineAmountBoundedByTotalSupplyAtExtreme() {
        // Emission terminates once reward hits 0 (initialReward = 2^10 ⇒ 11 nonzero
        // halvings), so premineAmount can never exceed total supply no matter how
        // absurd the premine — and never traps/overflows. You cannot premine more
        // coins than the chain will ever emit.
        XCTAssertEqual(spec(premine: UInt64.max).premineAmount(), unshiftedTotalSupply)
    }

    func testPremineAmountDoesNotTrapOnLargeHalvingInterval() {
        let s = ChainSpec(
            maxNumberOfTransactionsPerBlock: 1000,
            maxStateGrowth: 1_000_000,
            maxBlockSize: 1_000_000,
            premine: UInt64.max - 1,
            targetBlockTime: 10_000,
            initialReward: 1024,
            halvingInterval: UInt64.max / 2,
            retargetWindow: 5
        )

        XCTAssertEqual(s.premineAmount(), UInt64.max)
    }

    func testTotalRewardsDoesNotTrapOnLargeHalvingInterval() {
        let s = ChainSpec(
            maxNumberOfTransactionsPerBlock: 1000,
            maxStateGrowth: 1_000_000,
            maxBlockSize: 1_000_000,
            premine: UInt64.max - 1,
            targetBlockTime: 10_000,
            initialReward: 1024,
            halvingInterval: UInt64.max / 2,
            retargetWindow: 5
        )

        XCTAssertEqual(s.totalRewards(upToBlock: UInt64.max), UInt64.max)
    }

    func testEmissionTotalsRemainPinnedForValidSpecs() {
        let cases: [(premine: UInt64, premineAmount: UInt64, totalRewards: UInt64)] = [
            (0, 0, 20_470_000),
            (1, 1_024, 20_468_976),
            (9_999, 10_238_976, 10_231_024),
            (halvingInterval, 10_240_000, 10_230_000),
            (15_000, 12_800_000, 7_670_000),
            (halvingInterval * 5, 19_840_000, 630_000),
            (halvingInterval * 64, 20_470_000, 0),
        ]

        for expected in cases {
            let s = spec(premine: expected.premine)
            XCTAssertEqual(s.premineAmount(), expected.premineAmount, "premineAmount drift for premine \(expected.premine)")
            XCTAssertEqual(s.totalRewards(upToBlock: 1_000_000), expected.totalRewards, "totalRewards drift for premine \(expected.premine)")
        }

        XCTAssertEqual(ChainSpec.bitcoin.premineAmount(), 0)
        XCTAssertEqual(ChainSpec.bitcoin.totalRewards(upToBlock: 1_000_000), 2_018_750_000_000_000)
        XCTAssertEqual(ChainSpec.ethereum.premineAmount(), UInt64.max)
        XCTAssertEqual(ChainSpec.ethereum.totalRewards(upToBlock: 1_000_000), UInt64.max)
        XCTAssertEqual(ChainSpec.development.premineAmount(), 1_024_000)
        XCTAssertEqual(ChainSpec.development.totalRewards(upToBlock: 1_000_000), 19_446_000)
    }

    func testExtremePremineRewardHelpersStayTotalAndDoNotTrap() {
        // Regression: an uncapped premine makes `blockHeight + premine` overflow in
        // rewardAtBlock/totalRewards. Validation must stay total (no trap) over any
        // valid ChainSpec — overflow ⇒ astronomically past every halving ⇒ 0 reward.
        let s = spec(premine: UInt64.max)
        XCTAssertEqual(s.rewardAtBlock(1), 0)
        XCTAssertEqual(s.rewardAtBlock(UInt64.max), 0)
        XCTAssertEqual(s.totalRewards(upToBlock: 10), 0)
        // A near-max premine whose first offset is in-range but later blocks overflow
        // must also not trap (loop breaks on the overflowing offset).
        let nearMax = spec(premine: UInt64.max - 5)
        XCTAssertEqual(nearMax.totalRewards(upToBlock: 100), nearMax.rewardAtBlock(0))
    }

    /// A height-1 block mined on a UInt64.max-premine genesis must validate without
    /// trapping the validator (drives the real `validateNexus` reward path the
    /// reviewer flagged, not just the helper).
    func testHeightOneBlockOnExtremePreminedGenesisDoesNotTrapValidator() async throws {
        let owner = CryptoUtils.generateKeyPair()
        let addr = try! HeaderImpl<PublicKey>(node: PublicKey(key: owner.publicKey)).rawCID
        let s = spec(premine: UInt64.max)
        let fetcher = StorableFetcher()
        let premine = s.premineAmount()
        let body = TransactionBody(
            accountActions: [AccountAction(owner: addr, delta: Int64(premine > UInt64(Int64.max) ? UInt64(Int64.max) : premine))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [addr], fee: 0, nonce: 0
        )
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
        let sig = try XCTUnwrap(TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: owner.privateKey))
        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, transactions: [Transaction(signatures: [owner.publicKey: sig], body: bodyHeader)],
            timestamp: Int64(Date().timeIntervalSince1970 * 1000) - 20_000,
            target: UInt256(1000), fetcher: fetcher
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [],
            timestamp: genesis.timestamp + 1_000,
            target: genesis.nextTarget, fetcher: fetcher
        )
        // The reward path (rewardAtBlock(height: 1)) is reached here; the assertion
        // is simply that this does not trap. Reward at height 1 is 0 (premine past
        // all halvings), so the empty block validates against conservation.
        _ = try await block.validateNexus(fetcher: fetcher)
    }

    // MARK: - rewardAtBlock curve shift

    func testRewardCurveShiftsForwardByPremineAcrossHalvings() {
        // premine == one full halving interval ⇒ block 0 starts in the SECOND
        // halving epoch, so the first mined reward is initialReward/2.
        let s = spec(premine: halvingInterval)
        XCTAssertEqual(s.rewardAtBlock(0), initialReward / 2)
        // premine == 2 intervals ⇒ first mined reward is initialReward/4.
        XCTAssertEqual(spec(premine: halvingInterval * 2).rewardAtBlock(0), initialReward / 4)
    }

    // MARK: - Supply conservation invariant (the core "tokenomics still work" check)

    func testTotalSupplyIsConservedRegardlessOfPremineSize() {
        // For ANY premine P, the genesis credit (premineAmount) plus all
        // subsequently mined emission equals the fixed unshifted lifetime supply.
        // Premine only redistributes a fixed pie between genesis and mining.
        let total = unshiftedTotalSupply
        for premine: UInt64 in [0, 1, 9_999, halvingInterval, 15_000, halvingInterval * 5, halvingInterval * 64] {
            let s = spec(premine: premine)
            XCTAssertEqual(
                s.premineAmount() + s.totalRewards(upToBlock: 1_000_000),
                total,
                "supply must be conserved for premine \(premine)"
            )
        }
    }

    // MARK: - Genesis validates + conserves through the real entry point

    func testLargePremineGenesisValidatesAndConserves() async throws {
        // premine spanning two halving epochs, credited at genesis, must pass the
        // real `validateGenesis` conservation/PoW pipeline.
        let owner = CryptoUtils.generateKeyPair()
        let addr = try! HeaderImpl<PublicKey>(node: PublicKey(key: owner.publicKey)).rawCID
        let s = spec(premine: 15_000)
        let premine = s.premineAmount()
        XCTAssertGreaterThan(premine, 0)

        let fetcher = StorableFetcher()
        let body = TransactionBody(
            accountActions: [AccountAction(owner: addr, delta: Int64(premine))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [addr], fee: 0, nonce: 0
        )
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
        let sig = try XCTUnwrap(TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: owner.privateKey))
        let genesisTx = Transaction(signatures: [owner.publicKey: sig], body: bodyHeader)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: s, transactions: [genesisTx],
            timestamp: Int64(Date().timeIntervalSince1970 * 1000) - 20_000,
            target: UInt256(1000), fetcher: fetcher
        )
        let (valid, _) = try await genesis.validateGenesis(fetcher: fetcher, directory: "Nexus")
        XCTAssertTrue(valid, "a genesis crediting a multi-halving premine must validate (conservation holds)")

        // Over-crediting beyond premineAmount must still be rejected — the cap
        // removal does not relax the conservation invariant.
        let overBody = TransactionBody(
            accountActions: [AccountAction(owner: addr, delta: Int64(premine + 1))],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [], signers: [addr], fee: 0, nonce: 0
        )
        let overHeader = try! HeaderImpl<TransactionBody>(node: overBody)
        let overSig = try XCTUnwrap(TransactionSigning.sign(bodyHeader: overHeader, privateKeyHex: owner.privateKey))
        let overTx = Transaction(signatures: [owner.publicKey: overSig], body: overHeader)
        let overGenesis = try await BlockBuilder.buildGenesis(
            spec: s, transactions: [overTx],
            timestamp: Int64(Date().timeIntervalSince1970 * 1000) - 20_000,
            target: UInt256(1000), fetcher: fetcher
        )
        let (overValid, _) = try await overGenesis.validateGenesis(fetcher: fetcher, directory: "Nexus")
        XCTAssertFalse(overValid, "crediting more than premineAmount must still fail conservation")
    }
}
