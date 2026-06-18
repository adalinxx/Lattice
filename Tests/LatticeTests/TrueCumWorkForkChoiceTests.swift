import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

// F5-4 (Hierarchical GHOST): fork choice is the max of trueCumWork = own-chain
// subtreeWeight + inherited parent weight (design §4/§6.2). These pin the new
// single-metric rule:
//  - within a chain (no inheritance) the heaviest *subtree* wins (GHOST), not the
//    longest path;
//  - a fork with heavier *inherited* weight beats a longer-but-lighter-inherited
//    fork — "anchored to the heavier parent fork wins", replacing the old
//    positional parentIndex key.
// inheritedWeight is supplied directly here (the node refreshes it on parent
// extension; that wiring is separate).

private func f() -> StorableFetcher { StorableFetcher() }
private func s(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: 0, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
}
private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
private func cid(_ b: Block) -> String { try! VolumeImpl<Block>(node: b).rawCID }

final class TrueCumWorkForkChoiceTests: XCTestCase {

    /// Two sibling forks off A. The shorter fork carries a large inherited weight;
    /// the longer fork carries none. trueCumWork (own subtree + inherited) makes the
    /// shorter-but-anchored fork canonical — the §4 rule the old parentIndex key
    /// approximated, now the real number.
    func testHeavierInheritedForkBeatsLongerLighterFork() async throws {
        let fetcher = f()
        let diff = UInt256(1000)
        let w = workForTarget(diff)
        let base = now() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(spec: s(), timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        let a = try await BlockBuilder.buildBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: a), block: a)

        // Longer, self-mined fork off A: A→L1→L2 (own work 2w, no inheritance).
        let l1 = try await BlockBuilder.buildBlock(previous: a, timestamp: base + 2000, target: diff, nonce: 2, fetcher: fetcher)
        let l2 = try await BlockBuilder.buildBlock(previous: l1, timestamp: base + 3000, target: diff, nonce: 3, fetcher: fetcher)
        for blk in [l1, l2] {
            _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: blk), block: blk)
        }
        // Shorter, anchored fork off A: A→S1, with a big inherited parent weight
        // supplied live by the node's provider (no value stored on the block).
        let s1 = try await BlockBuilder.buildBlock(previous: a, timestamp: base + 2500, target: diff, nonce: 99, fetcher: fetcher)
        let s1hash = try! VolumeImpl<Block>(node: s1).rawCID
        let bigInherited = w &* UInt256(100)   // parent chain work far exceeds 2w
        await chain.setInheritedWeightProvider { $0 == s1hash ? bigInherited : .zero }
        _ = await chain.submitBlock(parentBlockHeaderAndIndex: ("P", 5), blockHeader: try! VolumeImpl<Block>(node: s1), block: s1)

        // trueCumWork(S1) = w + 100w ≫ trueCumWork(L1) = subtree(L1)=2w. S1 wins.
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, cid(s1), "anchored short fork (heavy inherited) is canonical over the longer self-mined fork")
    }

    /// No inheritance anywhere ⇒ pure same-chain GHOST: the heavier *subtree* wins.
    func testNoInheritanceFallsBackToSubtreeGHOST() async throws {
        let fetcher = f()
        let diff = UInt256(1000)
        let base = now() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(spec: s(), timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        let a = try await BlockBuilder.buildBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: a), block: a)
        // Fork 1: A→B (1 block).
        let b = try await BlockBuilder.buildBlock(previous: a, timestamp: base + 2000, target: diff, nonce: 2, fetcher: fetcher)
        _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: b), block: b)
        // Fork 2: A→X→Y (2 blocks, heavier subtree).
        let x = try await BlockBuilder.buildBlock(previous: a, timestamp: base + 2500, target: diff, nonce: 99, fetcher: fetcher)
        let y = try await BlockBuilder.buildBlock(previous: x, timestamp: base + 3500, target: diff, nonce: 100, fetcher: fetcher)
        for blk in [x, y] {
            _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: blk), block: blk)
        }
        let tip = await chain.getMainChainTip()
        XCTAssertEqual(tip, cid(y), "heavier subtree (X→Y) wins under pure same-chain GHOST")
    }

    ///: the public `effectiveWeight(forBlockHash:)` serves the exact canonical
    /// GHOST metric — `subtreeWeight + inherited` — that fork choice compares, so the
    /// trusted consensus provider can hand a descendant the authoritative value rather
    /// than have it re-derive (and risk diverging from this metric).
    func testEffectiveWeightForBlockHashServesCanonicalSubtreePlusInherited() async throws {
        let fetcher = f()
        let diff = UInt256(1000)
        let w = workForTarget(diff)
        let base = now() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(spec: s(), timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        let a = try await BlockBuilder.buildBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        let aHash = cid(a)
        let inherited = w &* UInt256(7)
        await chain.setInheritedWeightProvider { $0 == aHash ? inherited : .zero }
        _ = await chain.submitBlock(parentBlockHeaderAndIndex: ("P", 1), blockHeader: try! VolumeImpl<Block>(node: a), block: a)

        let subtree = await chain.subtreeWeight(forHash: aHash)
        XCTAssertNotNil(subtree)
        let served = await chain.effectiveWeight(forBlockHash: aHash)
        XCTAssertEqual(served, saturatingWorkSum(subtree!, inherited),
                       "served weight = subtreeWeight + inherited (the canonical trueCumWork)")
        let unknown = await chain.effectiveWeight(forBlockHash: "does-not-exist")
        XCTAssertNil(unknown, "unknown block ⇒ nil")
    }
}
