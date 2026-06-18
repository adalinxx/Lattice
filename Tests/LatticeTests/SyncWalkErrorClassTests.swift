import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

// Invalid ≠ unavailable on the sync walk. A fetch that FAILS (peer pruned the
// body, transport timed out) or returns undecodable bytes has NOT proven the
// block bad — `walkChain` must classify it `SyncError.bodyUnavailable`, exactly
// as its twin `backfillSubtree` does, never `invalidBlock`. These tests pin the
// walk path's error class so the two pipelines cannot drift again.

private func spec(_ dir: String = "Nexus") -> ChainSpec {
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

/// Serves everything from the base CAS except one denied CID, whose fetch
/// throws — simulating a peer that pruned (or cannot serve) that body.
private struct DenyingFetcher: Fetcher {
    let base: StorableFetcher
    let denied: String

    func fetch(rawCid: String) async throws -> Data {
        if rawCid == denied { throw FetcherError.notFound(rawCid) }
        return try await base.fetch(rawCid: rawCid)
    }
}

final class SyncWalkErrorClassTests: XCTestCase {

    // target = max ⇒ PoW trivially valid, so the tests isolate error
    // classification from PoW feasibility.
    private let easy = UInt256.max

    /// genesis + one extending block, both fully stored. Returns the CIDs.
    private func buildTwoBlockChain(into fetcher: StorableFetcher) async throws -> (genesis: String, tip: String) {
        let base = now() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(spec: spec(), timestamp: base, target: easy, fetcher: fetcher)
        try await storeBlock(genesis, to: fetcher)
        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: base + 1000, target: easy, nonce: 1, fetcher: fetcher)
        try await storeBlock(b1, to: fetcher)
        return (try! VolumeImpl<Block>(node: genesis).rawCID, try! VolumeImpl<Block>(node: b1).rawCID)
    }

    /// A failed fetch mid-walk is `bodyUnavailable` (carrying the walk depth),
    /// never `invalidBlock`: unavailability proves nothing about validity.
    func testWalkFetchFailureIsBodyUnavailableNotInvalidBlock() async throws {
        let cas = StorableFetcher()
        let (genesisCID, tipCID) = try await buildTwoBlockChain(into: cas)

        let fetcher = DenyingFetcher(base: cas, denied: genesisCID)
        let syncer = ChainSyncer(
            fetcher: fetcher, store: noopStore, genesisBlockHash: genesisCID,
            validateBlockConsensus: false)
        do {
            _ = try await syncer.syncFull(peerTipCID: tipCID)
            XCTFail("expected SyncError.bodyUnavailable")
        } catch SyncError.bodyUnavailable(let depth) {
            XCTAssertEqual(depth, 1, "the tip fetched fine; its parent was the unavailable body")
        } catch {
            XCTFail("fetch failure must classify as bodyUnavailable, got \(error)")
        }
    }

    /// Undecodable bytes are likewise unavailable (the requested body did not
    /// arrive intact), matching `backfillSubtree`'s classification.
    func testWalkUndecodableBytesAreBodyUnavailableNotInvalidBlock() async throws {
        let cas = StorableFetcher()
        let (genesisCID, tipCID) = try await buildTwoBlockChain(into: cas)
        cas.store(rawCid: genesisCID, data: Data([0xde, 0xad, 0xbe, 0xef]))

        let syncer = ChainSyncer(
            fetcher: cas, store: noopStore, genesisBlockHash: genesisCID,
            validateBlockConsensus: false)
        do {
            _ = try await syncer.syncFull(peerTipCID: tipCID)
            XCTFail("expected SyncError.bodyUnavailable")
        } catch SyncError.bodyUnavailable(let depth) {
            XCTAssertEqual(depth, 1)
        } catch {
            XCTFail("undecodable bytes must classify as bodyUnavailable, got \(error)")
        }
    }
}

// syncStateOnly fetches the TIP the peer itself advertised, so its error
// classes differ from the walk's interior bodies in one place:
// - a FAILED fetch (peer unreachable, transport timeout) is transient →
//   `bodyUnavailable(0)`, retryable, exactly like the walk;
// - bytes that ARRIVE but are undecodable → `invalidBlock(0)`: a peer cannot
//   claim "pruned" for the tip it just advertised — garbled bytes for your own
//   advertised tip are peer fault, not unavailability;
// - bytes that decode to a DIFFERENT block → `contentMismatch(0)`.
final class SyncStateOnlyErrorClassTests: XCTestCase {

    private let easy = UInt256.max

    private func buildStoredGenesis(into fetcher: StorableFetcher) async throws -> String {
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec(), timestamp: now() - 50_000, target: easy, fetcher: fetcher)
        try await storeBlock(genesis, to: fetcher)
        return try! VolumeImpl<Block>(node: genesis).rawCID
    }

    func testStateOnlyFetchFailureIsBodyUnavailableNotRawError() async throws {
        let cas = StorableFetcher()
        let genesisCID = try await buildStoredGenesis(into: cas)

        let fetcher = DenyingFetcher(base: cas, denied: genesisCID)
        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesisCID)
        do {
            _ = try await syncer.syncStateOnly(peerTipCID: genesisCID)
            XCTFail("expected SyncError.bodyUnavailable")
        } catch SyncError.bodyUnavailable(let depth) {
            XCTAssertEqual(depth, 0, "the advertised tip itself was unavailable")
        } catch {
            XCTFail("tip fetch failure must classify as bodyUnavailable, got \(error)")
        }
    }

    func testStateOnlyUndecodableTipIsInvalidBlock() async throws {
        let cas = StorableFetcher()
        let genesisCID = try await buildStoredGenesis(into: cas)
        cas.store(rawCid: genesisCID, data: Data([0xde, 0xad, 0xbe, 0xef]))

        let syncer = ChainSyncer(fetcher: cas, store: noopStore, genesisBlockHash: genesisCID)
        do {
            _ = try await syncer.syncStateOnly(peerTipCID: genesisCID)
            XCTFail("expected SyncError.invalidBlock")
        } catch SyncError.invalidBlock(let depth) {
            XCTAssertEqual(depth, 0)
        } catch {
            XCTFail("undecodable advertised-tip bytes must classify as invalidBlock, got \(error)")
        }
    }

    func testStateOnlyMislabeledTipIsContentMismatch() async throws {
        let cas = StorableFetcher()
        let genesisCID = try await buildStoredGenesis(into: cas)
        // Serve a DIFFERENT valid block's canonical bytes under the advertised CID.
        let other = try await BlockBuilder.buildGenesis(
            spec: spec(), timestamp: now() - 40_000, target: easy, fetcher: cas)
        cas.store(rawCid: genesisCID, data: other.toData()!)

        let syncer = ChainSyncer(fetcher: cas, store: noopStore, genesisBlockHash: genesisCID)
        do {
            _ = try await syncer.syncStateOnly(peerTipCID: genesisCID)
            XCTFail("expected SyncError.contentMismatch")
        } catch SyncError.contentMismatch(let depth) {
            XCTAssertEqual(depth, 0)
        } catch {
            XCTFail("mislabeled tip bytes must classify as contentMismatch, got \(error)")
        }
    }
}
