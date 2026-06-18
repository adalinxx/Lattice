import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation
#if canImport(os)
import os
#endif

// F5-2: the sync walk must bind each fetched block to the CID it was requested
// under. A peer that serves a block whose canonical hash is not the claimed CID
// is rejected with `SyncError.contentMismatch` — BEFORE its PoW, height, or
// parent linkage are trusted, and before anything is stored. Accepted blocks are
// persisted in canonical form, so the stored bytes always byte-hash to their
// CID. The normal resolve path does not verify in the pinned cashew, so the sync
// walk asserts the binding itself; this makes the engine trustless regardless of
// whether the underlying fetcher re-verifies.

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

/// Records everything the syncer asks to store, so a test can assert that
/// rejected (mislabeled) bytes are never written to the local store.
private final class StoreRecorder: Sendable {
    private let stored = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])
    func count() -> Int { stored.withLock { $0.count } }
    func data(_ cid: String) -> Data? { stored.withLock { $0[cid] } }
    var store: @Sendable (String, Data) async -> Void {
        { cid, data in self.stored.withLock { $0[cid] = data } }
    }
}

final class SyncContentBindingTests: XCTestCase {

    // target = max ⇒ target = max ⇒ PoW (`target >= hash`) trivially
    // holds, so these tests isolate the content-binding check from PoW
    // feasibility (the binding check runs first regardless).
    private let easy = UInt256.max

    /// Build an honest genesis plus a distinct "evil" block, then serve the evil
    /// block's bytes under the honest genesis CID. Returns (genesisCID, fetcher).
    private func fetcherServingEvilUnderGenesis() async throws -> (String, StorableFetcher) {
        let fetcher = StorableFetcher()
        let base = now() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(spec: spec(), timestamp: base, target: easy, fetcher: fetcher)
        let evil = try await BlockBuilder.buildGenesis(spec: spec(), timestamp: base + 5_000, target: easy, fetcher: fetcher)
        let genesisCID = try! VolumeImpl<Block>(node: genesis).rawCID
        let evilCID = try! VolumeImpl<Block>(node: evil).rawCID
        XCTAssertNotEqual(genesisCID, evilCID, "distinct content must yield distinct CIDs")

        try await storeBlock(evil, to: fetcher)
        let evilData = try await fetcher.fetch(rawCid: evilCID)
        fetcher.store(rawCid: genesisCID, data: evilData) // mislabel: evil bytes under genesis CID
        return (genesisCID, fetcher)
    }

    func testSyncStateOnlyRejectsContentNotMatchingCID() async throws {
        let (genesisCID, fetcher) = try await fetcherServingEvilUnderGenesis()
        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesisCID)
        do {
            _ = try await syncer.syncStateOnly(peerTipCID: genesisCID)
            XCTFail("expected SyncError.contentMismatch")
        } catch SyncError.contentMismatch {
            // expected: tip bytes did not hash to the advertised CID
        }
    }

    func testSyncFullWalkRejectsContentNotMatchingCID() async throws {
        let (genesisCID, fetcher) = try await fetcherServingEvilUnderGenesis()
        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesisCID)
        do {
            _ = try await syncer.syncFull(peerTipCID: genesisCID)
            XCTFail("expected SyncError.contentMismatch")
        } catch SyncError.contentMismatch {
            // expected: walk rejects mislabeled bytes before trusting links/PoW
        }
    }

    /// The content check must run even when PoW validation is skipped
    /// (`syncSnapshot(skipPoWValidation: true)`, used after a prior verifying
    /// pass). Otherwise skipping PoW would also silently skip content binding.
    func testSyncSnapshotRejectsContentWhenPoWSkipped() async throws {
        let (genesisCID, fetcher) = try await fetcherServingEvilUnderGenesis()
        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesisCID)
        do {
            _ = try await syncer.syncSnapshot(peerTipCID: genesisCID, skipPoWValidation: true)
            XCTFail("expected SyncError.contentMismatch")
        } catch SyncError.contentMismatch {
            // expected: binding is independent of PoW and still enforced
        }
    }

    /// Mislabeled bytes must never reach the local store — the guard precedes
    /// `storeFn`. A recording store proves nothing was written on rejection.
    func testMismatchedBytesAreNotStored() async throws {
        let (genesisCID, fetcher) = try await fetcherServingEvilUnderGenesis()
        let recorder = StoreRecorder()
        let syncer = ChainSyncer(fetcher: fetcher, store: recorder.store, genesisBlockHash: genesisCID)
        do {
            _ = try await syncer.syncStateOnly(peerTipCID: genesisCID)
            XCTFail("expected SyncError.contentMismatch")
        } catch SyncError.contentMismatch {}
        let stored = await recorder.count()
        XCTAssertEqual(stored, 0, "rejected bytes must not be stored locally")
    }

    func testHonestContentPassesBindingAndSyncs() async throws {
        let fetcher = StorableFetcher()
        let base = now() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(spec: spec(), timestamp: base, target: easy, fetcher: fetcher)
        let genesisCID = try! VolumeImpl<Block>(node: genesis).rawCID
        try await storeBlock(genesis, to: fetcher)

        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesisCID)
        let result = try await syncer.syncStateOnly(peerTipCID: genesisCID)
        XCTAssertEqual(result.tipBlockHash, genesisCID, "honest tip syncs and is recorded under its true hash")
        XCTAssertEqual(result.tipBlockHeight, 0)
    }

    /// Accepted blocks are persisted in canonical form (block.toData()) under
    /// their CID, so the stored bytes always byte-hash to the CID — asserted for
    /// both the state-only path and the walk path (via snapshot).
    func testAcceptedSyncStoresCanonicalBytes() async throws {
        let fetcher = StorableFetcher()
        let base = now() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(spec: spec(), timestamp: base, target: easy, fetcher: fetcher)
        let genesisCID = try! VolumeImpl<Block>(node: genesis).rawCID
        let canonical = genesis.toData()
        XCTAssertNotNil(canonical)
        try await storeBlock(genesis, to: fetcher)

        let stateRec = StoreRecorder()
        _ = try await ChainSyncer(fetcher: fetcher, store: stateRec.store, genesisBlockHash: genesisCID)
            .syncStateOnly(peerTipCID: genesisCID)
        XCTAssertEqual(stateRec.data(genesisCID), canonical, "state-only stores canonical bytes under the CID")

        let walkRec = StoreRecorder()
        _ = try await ChainSyncer(fetcher: fetcher, store: walkRec.store, genesisBlockHash: genesisCID)
            .syncSnapshot(peerTipCID: genesisCID)
        XCTAssertEqual(walkRec.data(genesisCID), canonical, "walk stores canonical bytes under the CID")
    }
}
