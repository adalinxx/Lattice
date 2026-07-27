import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

// Forward same-chain subtree weight,
// subtreeWeight(B) = work(B) + Σ subtreeWeight(children) — the descendant dual of
// the backward cumulativeWork prefix sum (design consensus-fork-choice.md §3/§6).
// These pin: a tip weighs its own work; an interior block weighs its whole
// descendant subtree across forks (count once); out-of-order delivery converges;
// and a persistence round-trip rebuilds it.

private func f() -> StorableFetcher { StorableFetcher() }
private func s(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: 0, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
}
private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
private func cid(_ b: Block) -> String { try! VolumeImpl<Block>(node: b).rawCID }

final class ForwardSubtreeWeightTests: XCTestCase {

    /// Linear chain G→A→B→C: each block's subtree weight = work from it to the tip
    /// (inclusive) — the single-path case where forward subtree == suffix sum.
    func testLinearChainSubtreeIsSuffixSum() async throws {
        let fetcher = f()
        let diff = UInt256(1000)
        let w = workForTarget(diff)
        let base = now() - 50_000
        let genesis = try await buildAndStoreGenesis(spec: s(), timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        var prev = genesis
        var blocks = [genesis]
        for i in 1...3 {
            let b = try await buildAndStoreBlock(previous: prev, timestamp: base + Int64(i) * 1000, target: diff, nonce: UInt64(i), fetcher: fetcher)
            _ = await chain.submitTestBlock(blockHeader: try! VolumeImpl<Block>(node: b), block: b)
            blocks.append(b); prev = b
        }
        // G,A,B,C (4 blocks). subtreeWeight(G)=4w, A=3w, B=2w, C(tip)=1w.
        let expected = [4, 3, 2, 1]
        for (i, b) in blocks.enumerated() {
            let sw = await chain.subtreeWeight(forHash: cid(b))
            var want = WorkSum.zero
            for _ in 0..<expected[i] { want = want + w }
            XCTAssertEqual(sw, want, "subtreeWeight(block \(i)) = \(expected[i])w")
        }
    }

    /// A fork off A: G→A→B(tip1) and A→X→Y(tip2). subtreeWeight(A) must count BOTH
    /// branches' work (count once over the descendant subtree), not just one path.
    func testForkSubtreeCountsAllBranches() async throws {
        let fetcher = f()
        let diff = UInt256(1000)
        let w = workForTarget(diff)
        let base = now() - 50_000
        let genesis = try await buildAndStoreGenesis(spec: s(), timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        let a = try await buildAndStoreBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        let b = try await buildAndStoreBlock(previous: a, timestamp: base + 2000, target: diff, nonce: 2, fetcher: fetcher)
        // Sibling fork off A.
        let x = try await buildAndStoreBlock(previous: a, timestamp: base + 2500, target: diff, nonce: 99, fetcher: fetcher)
        let y = try await buildAndStoreBlock(previous: x, timestamp: base + 3500, target: diff, nonce: 100, fetcher: fetcher)
        for blk in [a, b, x, y] {
            _ = await chain.submitTestBlock(blockHeader: try! VolumeImpl<Block>(node: blk), block: blk)
        }
        // Subtree of A = {A, B, X, Y} = 4w (both branches), NOT 2w (one path).
        let swA = await chain.subtreeWeight(forHash: cid(a))
        var fourW = WorkSum.zero; for _ in 0..<4 { fourW = fourW + w }
        XCTAssertEqual(swA, fourW, "A's subtree counts BOTH forks (B and X→Y): 4w")
        // Genesis subtree = everything = 5w (G,A,B,X,Y).
        let swG = await chain.subtreeWeight(forHash: cid(genesis))
        var fiveW = WorkSum.zero; for _ in 0..<5 { fiveW = fiveW + w }
        XCTAssertEqual(swG, fiveW, "genesis subtree = all 5 blocks")
        // Tips weigh their own work.
        let swB = await chain.subtreeWeight(forHash: cid(b))
        XCTAssertEqual(swB, WorkSum(w), "tip B weighs its own work")
        let swY = await chain.subtreeWeight(forHash: cid(y))
        XCTAssertEqual(swY, WorkSum(w), "tip Y weighs its own work")
        // X's subtree = {X, Y} = 2w.
        let swX = await chain.subtreeWeight(forHash: cid(x))
        XCTAssertEqual(swX, WorkSum(w) + w, "X's subtree = X,Y = 2w")
    }

    /// Out-of-order: deliver C (grandchild) and B before A. Once A arrives, A's
    /// subtree weight must fold in the already-present descendants.
    func testOutOfOrderConverges() async throws {
        let fetcher = f()
        let diff = UInt256(1000)
        let w = workForTarget(diff)
        let base = now() - 50_000
        let genesis = try await buildAndStoreGenesis(spec: s(), timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        let a = try await buildAndStoreBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        let b = try await buildAndStoreBlock(previous: a, timestamp: base + 2000, target: diff, nonce: 2, fetcher: fetcher)
        let c = try await buildAndStoreBlock(previous: b, timestamp: base + 3000, target: diff, nonce: 3, fetcher: fetcher)
        // Deliver C, then B, then A (children before parents).
        for blk in [c, b, a] {
            _ = await chain.submitTestBlock(blockHeader: try! VolumeImpl<Block>(node: blk), block: blk)
        }
        let swA = await chain.subtreeWeight(forHash: cid(a))
        var threeW = WorkSum.zero; for _ in 0..<3 { threeW = threeW + w }
        XCTAssertEqual(swA, threeW, "A folds in out-of-order descendants B,C: 3w")
        let swG = await chain.subtreeWeight(forHash: cid(genesis))
        var fourW = WorkSum.zero; for _ in 0..<4 { fourW = fourW + w }
        XCTAssertEqual(swG, fourW, "genesis subtree = G,A,B,C = 4w after out-of-order")
    }

    /// Fact replay rebuilds subtree weights from durable consensus inputs.
    func testFactReplayRebuildsSubtreeWeights() async throws {
        let fetcher = f()
        let diff = UInt256(1000)
        let w = workForTarget(diff)
        let base = now() - 50_000
        let genesis = try await buildAndStoreGenesis(spec: s(), timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        let a = try await buildAndStoreBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        let b = try await buildAndStoreBlock(previous: a, timestamp: base + 2000, target: diff, nonce: 2, fetcher: fetcher)
        for blk in [a, b] {
            _ = await chain.submitTestBlock(blockHeader: try! VolumeImpl<Block>(node: blk), block: blk)
        }
        let restored = try await ChainState.restore(replaying: [
            testAdmissionBatch(for: genesis),
            testAdmissionBatch(for: a),
            testAdmissionBatch(for: b),
        ])
        let swG = await restored.subtreeWeight(forHash: cid(genesis))
        var threeW = WorkSum.zero; for _ in 0..<3 { threeW = threeW + w }
        XCTAssertEqual(swG, threeW, "replay rebuilds genesis subtree = 3w")
        let swTip = await restored.subtreeWeight(forHash: cid(b))
        XCTAssertEqual(swTip, WorkSum(w), "replay: tip weighs own work")
    }
}
