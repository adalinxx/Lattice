import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

// Segment-anchored catch-up sync: a follower whose peers serve only their
// retained window (never a full genesis walk) must be able to validate and
// adopt a header segment that attaches to a block the follower already holds
// on its main chain. Historically syncFromHeaders accepted only genesis-
// anchored segments and threw genesisMismatch for everything else — once a
// chain outgrew every peer's served window, every follower froze in a
// genesisMismatch retry loop (the July-4 toy freeze). These tests pin the
// anchored acceptance path AND the fail-closed rejections around it.

private func spec() -> ChainSpec {
    ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: 0, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
}
private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

private func storeBlock(_ block: Block, to fetcher: StorableFetcher) async throws {
    try await VolumeImpl<Block>(node: block).storeBlock(storer: fetcher)
}

private let noopStore: @Sendable (String, Data) async -> Void = { _, _ in }

final class SyncSegmentAnchorTests: XCTestCase {

    // target = max ⇒ PoW trivially valid, work = 1 per block.
    private let easy = UInt256.max

    private func header(for block: Block) throws -> SyncBlockHeader {
        SyncBlockHeader(cid: try VolumeImpl<Block>(node: block).rawCID,
                        height: block.height,
                        previousBlockCID: block.parent?.rawCID,
                        target: block.target,
                        nextTarget: block.nextTarget,
                        timestamp: block.timestamp,
                        specCID: block.spec.rawCID,
                        spec: block.spec.node)
    }

    /// Build genesis + `count` blocks; return all blocks oldest-first.
    private func buildBlocks(count: Int, into fetcher: StorableFetcher) async throws -> [Block] {
        let base = now() - 100_000
        let genesis = try await buildAndStoreGenesis(spec: spec(), timestamp: base, target: easy, fetcher: fetcher)
        try await storeBlock(genesis, to: fetcher)
        var blocks = [genesis]
        var prev = genesis
        for i in 1...count {
            let b = try await buildAndStoreBlock(
                previous: prev, timestamp: base + Int64(i) * 1000,
                target: easy, nonce: UInt64(i), fetcher: fetcher)
            try await storeBlock(b, to: fetcher)
            blocks.append(b)
            prev = b
        }
        return blocks
    }

    /// The core fix: a mid-chain segment (heights 3...5 of a 5-block chain)
    /// anchored at the locally-held block 2 validates and builds a result —
    /// no genesis walk required.
    func testAnchoredSegmentAccepted() async throws {
        let fetcher = StorableFetcher()
        let blocks = try await buildBlocks(count: 5, into: fetcher)
        let genesisCID = try VolumeImpl<Block>(node: blocks[0]).rawCID

        // Anchor CONTEXT: genesis..2, oldest-first, ending at the attach block —
        // deep enough for the retarget/MTP windows of the first segment headers.
        let anchors = try blocks[0...2].map { try header(for: $0) }
        let segment = try blocks[3...5].map { try header(for: $0) }

        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesisCID)
        let result = try await syncer.syncFromHeaders(
            segment,
            cumulativeWork: UInt256(3),           // segment work: 3 blocks × 1
            localCumulativeWork: UInt256.zero,    // local-beyond-fork: fast-forward
            knownAnchors: anchors
        )
        XCTAssertEqual(result.tipBlockHeight, 5)
        XCTAssertEqual(result.tipBlockHash, try VolumeImpl<Block>(node: blocks[5]).rawCID)
    }

    /// Fail closed: a segment whose oldest header does NOT attach to the
    /// provided anchor still throws genesisMismatch (an anchor the segment
    /// doesn't extend proves nothing).
    func testSegmentNotAttachedToAnchorRejected() async throws {
        let fetcher = StorableFetcher()
        let blocks = try await buildBlocks(count: 5, into: fetcher)
        let genesisCID = try VolumeImpl<Block>(node: blocks[0]).rawCID

        let wrongAnchor = try header(for: blocks[1])   // segment starts at 4, parent is 3 ≠ 1
        let segment = try blocks[4...5].map { try header(for: $0) }

        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesisCID)
        do {
            _ = try await syncer.syncFromHeaders(
                segment, cumulativeWork: UInt256(2), knownAnchors: [wrongAnchor])
            XCTFail("segment that does not attach to the anchor must be rejected")
        } catch let error as SyncError {
            guard case .genesisMismatch = error else {
                return XCTFail("expected genesisMismatch, got \(error)")
            }
        }
    }

    /// Fail closed: an anchor at the wrong height (CID matches, height lies)
    /// is rejected — continuity is height-checked against the anchor.
    func testAnchorHeightMismatchRejected() async throws {
        let fetcher = StorableFetcher()
        let blocks = try await buildBlocks(count: 5, into: fetcher)
        let genesisCID = try VolumeImpl<Block>(node: blocks[0]).rawCID

        let realAnchor = try header(for: blocks[2])
        let liedAnchor = SyncBlockHeader(cid: realAnchor.cid, height: realAnchor.height + 1,
                                         previousBlockCID: realAnchor.previousBlockCID,
                                         target: realAnchor.target, nextTarget: realAnchor.nextTarget,
                                         timestamp: realAnchor.timestamp,
                                         specCID: realAnchor.specCID, spec: realAnchor.spec)
        let segment = try blocks[3...5].map { try header(for: $0) }

        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesisCID)
        do {
            _ = try await syncer.syncFromHeaders(
                segment, cumulativeWork: UInt256(3), knownAnchors: [liedAnchor])
            XCTFail("anchor with a lying height must be rejected")
        } catch let error as SyncError {
            guard case .genesisMismatch = error else {
                return XCTFail("expected genesisMismatch, got \(error)")
            }
        }
    }

    /// No anchor ⇒ exactly the historical behavior: a mid-chain segment is
    /// rejected with genesisMismatch (segments must reach genesis).
    func testNoAnchorPreservesGenesisRequirement() async throws {
        let fetcher = StorableFetcher()
        let blocks = try await buildBlocks(count: 5, into: fetcher)
        let genesisCID = try VolumeImpl<Block>(node: blocks[0]).rawCID
        let segment = try blocks[3...5].map { try header(for: $0) }

        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesisCID)
        do {
            _ = try await syncer.syncFromHeaders(segment, cumulativeWork: UInt256(3))
            XCTFail("mid-chain segment without an anchor must still be rejected")
        } catch let error as SyncError {
            guard case .genesisMismatch = error else {
                return XCTFail("expected genesisMismatch, got \(error)")
            }
        }
    }

    /// The insufficientWork gate still applies with an anchor: segment work
    /// must be >= the caller's local-beyond-fork work.
    func testAnchoredSegmentInsufficientWorkRejected() async throws {
        let fetcher = StorableFetcher()
        let blocks = try await buildBlocks(count: 5, into: fetcher)
        let genesisCID = try VolumeImpl<Block>(node: blocks[0]).rawCID
        let anchor = try header(for: blocks[2])
        let segment = try blocks[3...5].map { try header(for: $0) }

        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesisCID)
        do {
            _ = try await syncer.syncFromHeaders(
                segment,
                cumulativeWork: UInt256(3),
                localCumulativeWork: UInt256(10),   // local fork is heavier beyond the anchor
                knownAnchors: [anchor])
            XCTFail("segment lighter than the local fork must be rejected")
        } catch let error as SyncError {
            guard case .insufficientWork = error else {
                return XCTFail("expected insufficientWork, got \(error)")
            }
        }
    }

    /// getCumulativeWork(aboveHeight:) sums exactly the main-chain blocks
    /// strictly above the given height.
    func testCumulativeWorkAboveHeight() async throws {
        let fetcher = StorableFetcher()
        let blocks = try await buildBlocks(count: 5, into: fetcher)
        let genesisCID = try VolumeImpl<Block>(node: blocks[0]).rawCID

        // Restore a chain holding all 6 blocks (work 1 each ⇒ heights 0-5).
        let syncer = ChainSyncer(fetcher: fetcher, store: noopStore, genesisBlockHash: genesisCID)
        let allHeaders = try blocks.map { try header(for: $0) }
        let result = try await syncer.syncFromHeaders(allHeaders, cumulativeWork: UInt256(6))
        let chain = try ChainState.restore(from: result.persisted)

        let above2 = await chain.getCumulativeWork(aboveHeight: 2)
        XCTAssertEqual(above2, UInt256(3), "heights 3,4,5 ⇒ work 3")
        let aboveTip = await chain.getCumulativeWork(aboveHeight: 5)
        XCTAssertEqual(aboveTip, UInt256.zero, "nothing above the tip")
        let aboveGenesis = await chain.getCumulativeWork(aboveHeight: 0)
        XCTAssertEqual(aboveGenesis, UInt256(5), "heights 1-5 ⇒ work 5")
    }
}
