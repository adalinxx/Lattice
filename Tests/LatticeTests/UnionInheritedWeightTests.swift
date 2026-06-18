import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

// Hierarchical-GHOST faithfulness of the parent-served per-child inherited weight
// (`ChainState.unionInheritedWeight(committerHashes:)`): the UNION of the
// committers' securing cones, every grinding block counted exactly once
// (docs/consensus-fork-choice.md §3, §6.2). Single committer reduces to
// trueCumWork(committer); multiple committers sum disjoint forks and dedup the
// shared cone — never a sum of trueCumWorks (double-count), never a max (drops a
// fork = the longest-chain reduction).

private func f() -> StorableFetcher { StorableFetcher() }
private func s(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: 0, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
}
private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
private func cid(_ b: Block) -> String { try! VolumeImpl<Block>(node: b).rawCID }

final class UnionInheritedWeightTests: XCTestCase {

    /// Single committer is the norm: the served value is exactly that committer's
    /// trueCumWork (`effectiveWeight`), inherited cone included.
    func testSingleCommitterEqualsTrueCumWork() async throws {
        let fetcher = f()
        let diff = UInt256(1000)
        let base = now() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(spec: s(), timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        let p = try await BlockBuilder.buildBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: p), block: p)
        let inh = UInt256(100)
        await chain.setInheritedWeightProvider { $0 == cid(p) ? inh : .zero }

        let eff = await chain.effectiveWeight(forBlockHash: cid(p))
        let union = await chain.unionInheritedWeight(committerHashes: [cid(p)])
        XCTAssertEqual(union, eff)
    }

    /// Cross-fork carriers (the discriminating case). Child C is committed by P1
    /// (fork A, subtree {P1}) and P2 (fork B, subtree {P2,P2b}), both sharing the
    /// same cross-chain inherited cone `inh`. Faithful union =
    /// subtree(P1) + subtree(P2) + inh (each block + the shared cone once). It must
    /// be NEITHER (sub(P1)+inh)+(sub(P2)+inh) — double-counts `inh` — NOR
    /// max(sub(P1)+inh, sub(P2)+inh) — drops the lighter fork.
    func testCrossForkCarriersUnionDisjointForksPlusSharedConeOnce() async throws {
        let fetcher = f()
        let diff = UInt256(1000)
        let w = workForTarget(diff)
        let base = now() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(spec: s(), timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        let b0 = try await BlockBuilder.buildBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        // Fork A committer P1 — a tip, subtree = {P1} = 1w.
        let p1 = try await BlockBuilder.buildBlock(previous: b0, timestamp: base + 2000, target: diff, nonce: 10, fetcher: fetcher)
        // Fork B committer P2 + a descendant P2b — subtree = {P2,P2b} = 2w.
        let p2 = try await BlockBuilder.buildBlock(previous: b0, timestamp: base + 2500, target: diff, nonce: 20, fetcher: fetcher)
        let p2b = try await BlockBuilder.buildBlock(previous: p2, timestamp: base + 3500, target: diff, nonce: 21, fetcher: fetcher)
        for blk in [b0, p1, p2, p2b] {
            _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: blk), block: blk)
        }
        let inh = UInt256(100)
        // P1 and P2 share the same securing inherited cone.
        await chain.setInheritedWeightProvider { ($0 == cid(p1) || $0 == cid(p2)) ? inh : .zero }

        let subP1 = await chain.subtreeWeight(forHash: cid(p1)) ?? .zero   // 1w
        let subP2 = await chain.subtreeWeight(forHash: cid(p2)) ?? .zero   // 2w
        let union = await chain.unionInheritedWeight(committerHashes: [cid(p1), cid(p2)])

        let faithful = subP1 &+ subP2 &+ inh
        let sumOfTrueCumWorks = (subP1 &+ inh) &+ (subP2 &+ inh)           // double-counts inh
        let effP1 = subP1 &+ inh, effP2 = subP2 &+ inh
        let maxReduction = effP1 > effP2 ? effP1 : effP2                   // drops a fork

        XCTAssertEqual(subP1, w)
        XCTAssertEqual(subP2, w &+ w)
        XCTAssertEqual(union, faithful, "union = disjoint forks summed + shared inherited cone once")
        XCTAssertNotEqual(union, sumOfTrueCumWorks, "must NOT double-count the shared inherited cone")
        XCTAssertNotEqual(union, maxReduction, "must NOT drop a disjoint fork (longest-chain reduction)")
    }

    /// Nested re-commits. The same child C is committed by P1 and its own-chain
    /// descendant P2 (P2 ∈ subtree(P1)). The union must collapse to the EARLIEST
    /// committer's cone (= trueCumWork(P1)), not sum the two carriers' trueCumWorks.
    func testNestedRecommitsCollapseToEarliestCommitterCone() async throws {
        let fetcher = f()
        let diff = UInt256(1000)
        let base = now() - 50_000
        let genesis = try await BlockBuilder.buildGenesis(spec: s(), timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        let p1 = try await BlockBuilder.buildBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        let p2 = try await BlockBuilder.buildBlock(previous: p1, timestamp: base + 2000, target: diff, nonce: 2, fetcher: fetcher)
        for blk in [p1, p2] {
            _ = await chain.submitBlock(parentBlockHeaderAndIndex: nil, blockHeader: try! VolumeImpl<Block>(node: blk), block: blk)
        }
        let inh = UInt256(100)
        await chain.setInheritedWeightProvider { ($0 == cid(p1) || $0 == cid(p2)) ? inh : .zero }

        let effP1 = await chain.effectiveWeight(forBlockHash: cid(p1)) ?? .zero   // subtree{P1,P2}+inh
        let effP2 = await chain.effectiveWeight(forBlockHash: cid(p2)) ?? .zero   // subtree{P2}+inh
        let union = await chain.unionInheritedWeight(committerHashes: [cid(p1), cid(p2)])

        XCTAssertEqual(union, effP1, "nested re-commits collapse to the earliest committer's cone")
        XCTAssertNotEqual(union, effP1 &+ effP2, "must NOT sum the two carriers' trueCumWorks")
    }
}
