import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

// F5 (security): a child chain's sync must validate each block's PoW against its
// anchored proof to the root — NOT the block's own hash. Otherwise a peer could
// feed a syncing node an unanchored, self-mined child chain (the "self-hash child
// PoW on sync" gap). The ChainSyncer exposes an `anchoredPoWValidator` seam: when
// set (child chains), a block that fails it is rejected (`invalidPoW`) and can't be
// adopted self-hashed; when nil (root chain) the self-hash gate is unchanged.

private func spec(_ dir: String = "Mid") -> ChainSpec {
    ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: 0, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
}
private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

private func storeBlock(_ block: Block, to fetcher: StorableFetcher) async throws {
    let storer = CollectingStorer()
    try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
    await storer.flush(to: fetcher)
}

private let noopStore: @Sendable (String, Data) async -> Void = { _, _ in }

final class SyncAnchoredPoWTests: XCTestCase {

    // target = max ⇒ the block trivially passes the SELF-hash gate, so these
    // tests isolate the anchored check: a self-valid block is still rejected when
    // the node's anchored validator (no valid proof to the root) says no.
    private let easy = UInt256.max

    private func makeGenesis() async throws -> (String, StorableFetcher) {
        let fetcher = StorableFetcher()
        let genesis = try await BlockBuilder.buildGenesis(spec: spec(), timestamp: now() - 50_000, target: easy, fetcher: fetcher)
        let cid = try! VolumeImpl<Block>(node: genesis).rawCID
        try await storeBlock(genesis, to: fetcher)
        return (cid, fetcher)
    }

    /// A block that passes its own self-hash gate is STILL rejected on a child
    /// chain when the node's anchored validator can't verify a proof to the root.
    func testAnchoredValidatorRejectsUnanchoredBlock() async throws {
        let (cid, fetcher) = try await makeGenesis()
        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: cid,
                                 anchoredPoWValidator: { _ in false })
        do {
            _ = try await syncer.syncStateOnly(peerTipCID: cid)
            XCTFail("expected invalidPoW — an unanchored child block must be rejected, not adopted self-hashed")
        } catch SyncError.invalidPoW {
            // expected
        }
    }

    /// The walk path enforces the anchored check per block too (not just the tip).
    func testAnchoredValidatorRejectsOnWalkPath() async throws {
        let (cid, fetcher) = try await makeGenesis()
        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: cid,
                                 anchoredPoWValidator: { _ in false })
        do {
            _ = try await syncer.syncFull(peerTipCID: cid)
            XCTFail("expected invalidPoW on the full walk")
        } catch SyncError.invalidPoW {
            // expected
        }
    }

    /// skipPoWValidation (the snapshot second pass) must NOT bypass the anchored
    /// validator — that optimization only ever applied to the cheap self-hash gate,
    /// so a child chain can never skip its anchored verification.
    func testSkipPoWDoesNotBypassAnchoredValidator() async throws {
        let (cid, fetcher) = try await makeGenesis()
        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: cid,
                                 anchoredPoWValidator: { _ in false })
        do {
            _ = try await syncer.syncSnapshot(peerTipCID: cid, skipPoWValidation: true)
            XCTFail("anchored validation must run even when skipPoWValidation is true")
        } catch SyncError.invalidPoW {
            // expected
        }
    }

    /// When the anchored validator accepts (a valid proof to the root), the block
    /// is adopted normally.
    func testAnchoredValidatorAcceptsValidProof() async throws {
        let (cid, fetcher) = try await makeGenesis()
        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: cid,
                                 anchoredPoWValidator: { _ in true })
        let result = try await syncer.syncStateOnly(peerTipCID: cid)
        XCTAssertEqual(result.tipBlockHash, cid, "a valid anchored proof ⇒ the block is adopted")
    }

    /// Default (nil validator) keeps the root-chain self-hash gate — unchanged.
    func testNilValidatorKeepsSelfHashGate() async throws {
        let (cid, fetcher) = try await makeGenesis()
        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: cid)
        let result = try await syncer.syncStateOnly(peerTipCID: cid)
        XCTAssertEqual(result.tipBlockHash, cid, "root chain self-hash gate unchanged when no anchored validator")
    }
}
