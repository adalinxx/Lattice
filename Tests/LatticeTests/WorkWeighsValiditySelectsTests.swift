import XCTest
import UInt256
@testable import Lattice

/// Work weighs; validity selects (§9.9).
///
/// Weights are pure verified work: an excluded (proven-invalid) block and its
/// descendants keep weighing for every ancestor, exactly as any other work
/// does, and no weight is ever removed. Validity acts on SELECTION only: the
/// canonical descent never steps into an excluded root, so the tip is the
/// heaviest selectable path through pure-work weights.
///
/// Every scenario — hand-drawn and random — is checked against an oracle
/// written from that definition alone, at every block (weights) and at the
/// tip (selection), live and after a cold restore in shuffled fact order.
final class WorkWeighsValiditySelectsTests: XCTestCase {

    // MARK: - Fixtures

    private struct Planned {
        let name: String
        let parent: String?
        let work: UInt64
    }

    private func h(_ name: String) -> String { testCID("wv:\(name)") }

    private func admission(_ b: Planned, height: UInt64) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
            .block(ChainBlockFact(
                blockHash: h(b.name), parentBlockHash: b.parent.map(h), blockHeight: height,
                postStateCID: testCID("wv-post:\(b.name)"), prevStateCID: testCID("wv-prev:\(b.name)"),
                specCID: testCID("wv-spec"), target: "1", nextTarget: "1",
                timestamp: Int64(1_000 + height), stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: h(b.name),
                contribution: VerifiedWorkContribution(id: testCID("wv-work:\(b.name)"), work: UInt256(b.work))
            )),
        ])
    }

    private func exclusion(_ name: String) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [.exclusion(ChainExclusionFact(blockHash: h(name)))])
    }

    private func heights(_ blocks: [Planned]) -> [String: UInt64] {
        let byName = Dictionary(uniqueKeysWithValues: blocks.map { ($0.name, $0) })
        func height(_ n: String) -> UInt64 {
            guard let p = byName[n]?.parent else { return 0 }
            return height(p) + 1
        }
        return Dictionary(uniqueKeysWithValues: blocks.map { ($0.name, height($0.name)) })
    }

    // MARK: - Oracle (from the definition, independent of Chain.swift)

    private struct Oracle {
        let weights: [String: WorkSum]   // pure work, by name
        let tip: String
        let path: Set<String>
    }

    private func oracle(_ blocks: [Planned], excluded: Set<String>) -> Oracle {
        var childrenOf: [String: [String]] = [:]
        for b in blocks { if let p = b.parent { childrenOf[p, default: []].append(b.name) } }
        let workOf = Dictionary(uniqueKeysWithValues: blocks.map { ($0.name, $0.work) })
        func total(_ n: String) -> UInt64 {
            workOf[n]! + (childrenOf[n] ?? []).map(total).reduce(0, +)
        }
        var weights: [String: WorkSum] = [:]
        for b in blocks { weights[b.name] = WorkSum(UInt256(total(b.name))) }
        // Selection: from the genesis, step into the heaviest child that is not
        // an excluded root (ties: lexicographically smaller CID); stop when no
        // child is selectable.
        var current = blocks.first { $0.parent == nil }!.name
        var path: Set<String> = [current]
        while true {
            let candidates = (childrenOf[current] ?? []).filter { !excluded.contains($0) }
            guard let next = candidates.max(by: { a, b in
                let wa = total(a), wb = total(b)
                if wa != wb { return wa < wb }
                return h(a) > h(b) // max picks the smaller CID on a tie
            }) else { break }
            current = next
            path.insert(current)
        }
        return Oracle(weights: weights, tip: current, path: path)
    }

    private func assertMatches(_ chain: ChainState, _ blocks: [Planned], excluded: Set<String>,
                               _ label: String, file: StaticString = #filePath, line: UInt = #line) async {
        let expected = oracle(blocks, excluded: excluded)
        for b in blocks {
            let weight = await chain.subtreeWeight(forHash: h(b.name))
            XCTAssertEqual(weight, expected.weights[b.name], "\(label): weight of \(b.name) is pure work",
                           file: file, line: line)
        }
        let tip = await chain.getMainChainTip()
        let path = await chain.mainChainHashes
        XCTAssertEqual(tip, h(expected.tip), "\(label): tip is the heaviest selectable path", file: file, line: line)
        XCTAssertEqual(path, Set(expected.path.map(h)), "\(label): canonical path", file: file, line: line)
        let genesis = blocks.first { $0.parent == nil }!.name
        let snapshot = await chain.forkChoiceSnapshot(startingAt: h(genesis))
        XCTAssertEqual(snapshot?.subtreeWork, expected.weights[genesis], "\(label): whole-graph weight", file: file, line: line)
        XCTAssertEqual(snapshot?.tipHash, h(expected.tip), "\(label): descent from genesis", file: file, line: line)
        // The differential reference agrees with the definition too.
        let live = await chain.hashToBlock
        let roots = await chain.excludedRootsForTesting
        let reference = ChainState.referenceCanonicalProjection(in: live, excluding: roots)
        XCTAssertEqual(reference?.chainTip, h(expected.tip), "\(label): reference oracle", file: file, line: line)
    }

    /// Build live in `order` (exclusions interleaved once their block exists),
    /// then cold-restore from the same facts shuffled by `rng`.
    private func build(_ blocks: [Planned], excluded: [String], order: [Int],
                       rng: inout SeededRNG) async throws -> (live: ChainState, cold: ChainState) {
        let hs = heights(blocks)
        let facts = blocks.map { admission($0, height: hs[$0.name]!) }
        let genesis = blocks.firstIndex { $0.parent == nil }!
        let live = try await ChainState.restore(replaying: [facts[genesis]])
        var pendingExclusions = Set(excluded)
        var present: Set<String> = [blocks[genesis].name]
        for i in order where i != genesis {
            _ = try await live.replay(facts[i])
            present.insert(blocks[i].name)
            for name in pendingExclusions where present.contains(name) {
                _ = try await live.replay(exclusion(name))
                pendingExclusions.remove(name)
            }
        }
        for name in pendingExclusions { _ = try await live.replay(exclusion(name)) }
        let all = facts + excluded.map(exclusion)
        let cold = try await ChainState.restore(replaying: all.shuffled(using: &rng))
        return (live, cold)
    }

    // MARK: - The worked example

    /// V has children I (invalid, 30 below it) and W (valid, 5 below it); V's
    /// sibling U has 20 below it. V weighs 36 and beats U; the descent then
    /// steps into W, never I. Under the old rule V weighed 6 and U won.
    func testInvalidWorkVotesForAncestorsAndValidityPicksTheStep() async throws {
        let blocks = [
            Planned(name: "g", parent: nil, work: 1),
            Planned(name: "v", parent: "g", work: 1),
            Planned(name: "i", parent: "v", work: 10),
            Planned(name: "i2", parent: "i", work: 20),
            Planned(name: "w", parent: "v", work: 5),
            Planned(name: "u", parent: "g", work: 20),
        ]
        var rng = SeededRNG(seed: 1)
        let (live, cold) = try await build(blocks, excluded: ["i"], order: Array(blocks.indices), rng: &rng)
        await assertMatches(live, blocks, excluded: ["i"], "live")
        await assertMatches(cold, blocks, excluded: ["i"], "cold")
        // Pin the numbers, so the oracle is not the only thing trusted.
        let v = await live.subtreeWeight(forHash: h("v"))
        XCTAssertEqual(v, WorkSum(UInt256(36)), "1 + 10 + 20 + 5: the invalid subtree weighs")
        let tip = await live.getMainChainTip()
        XCTAssertEqual(tip, h("w"))
    }

    /// V's only child is invalid: the tip is V itself, and it stays there
    /// however much work lands below I. When a valid child W appears it is
    /// chosen regardless of I's weight — validity is not compared, it selects.
    func testDescentStopsAboveAnInvalidOnlyChildAndTakesAValidSiblingWhenOneAppears() async throws {
        var blocks = [
            Planned(name: "g", parent: nil, work: 1),
            Planned(name: "v", parent: "g", work: 1),
            Planned(name: "i", parent: "v", work: 50),
        ]
        var rng = SeededRNG(seed: 2)
        let (live, _) = try await build(blocks, excluded: ["i"], order: Array(blocks.indices), rng: &rng)
        var tip = await live.getMainChainTip()
        XCTAssertEqual(tip, h("v"), "nothing below V is selectable")
        // More work under I: V's weight rises, the tip does not move.
        let heavier = Planned(name: "i2", parent: "i", work: 500)
        _ = try await live.replay(admission(heavier, height: 3))
        blocks.append(heavier)
        tip = await live.getMainChainTip()
        XCTAssertEqual(tip, h("v"))
        let v = await live.subtreeWeight(forHash: h("v"))
        XCTAssertEqual(v, WorkSum(UInt256(551)))
        // A valid child W with work 1 is chosen over I with 550 below it.
        let w = Planned(name: "w", parent: "v", work: 1)
        _ = try await live.replay(admission(w, height: 2))
        blocks.append(w)
        tip = await live.getMainChainTip()
        XCTAssertEqual(tip, h("w"), "validity selects; weight only ranks selectable children")
        await assertMatches(live, blocks, excluded: ["i"], "after W")
    }

    /// Excluding a block that was never canonical changes nothing — no weight
    /// moves and the descent never reached it — so no projection runs and no
    /// index is rebuilt. Excluding the canonical tip's ancestor re-selects.
    func testExclusionCostsAProjectionOnlyWhenItWasCanonical() async throws {
        let blocks = [
            Planned(name: "g", parent: nil, work: 1),
            Planned(name: "a", parent: "g", work: 10),
            Planned(name: "a2", parent: "a", work: 10),
            Planned(name: "b", parent: "g", work: 3),
        ]
        var rng = SeededRNG(seed: 3)
        let (live, _) = try await build(blocks, excluded: [], order: Array(blocks.indices), rng: &rng)
        await live.resetFullCanonicalProjectionCount()
        let rebuildsBefore = await live.segmentCacheRebuildCount
        _ = try await live.replay(exclusion("b"))
        let fullAfterSide = await live.fullCanonicalProjectionCount
        XCTAssertEqual(fullAfterSide, 0, "a non-canonical exclusion projects nothing")
        var tip = await live.getMainChainTip()
        XCTAssertEqual(tip, h("a2"))
        _ = try await live.replay(exclusion("a"))
        let fullAfterCanonical = await live.fullCanonicalProjectionCount
        XCTAssertEqual(fullAfterCanonical, 1, "a canonical exclusion re-selects once")
        tip = await live.getMainChainTip()
        XCTAssertEqual(tip, h("g"), "both children excluded: the genesis is the last selectable block")
        let rebuildsAfter = await live.segmentCacheRebuildCount
        XCTAssertEqual(rebuildsAfter, rebuildsBefore, "no weight moved, so no index was rebuilt")
        await assertMatches(live, blocks, excluded: ["a", "b"], "both excluded")
    }

    /// Continuity: an excluded subtree that had been executed is un-anchored
    /// and nothing below it is attested, while the rest of the frontier stays.
    func testExclusionUnanchorsOnlyTheExcludedSubtree() async throws {
        let blocks = [
            Planned(name: "g", parent: nil, work: 1),
            Planned(name: "a", parent: "g", work: 2),
            Planned(name: "a2", parent: "a", work: 2),
            Planned(name: "b", parent: "g", work: 2),
        ]
        var rng = SeededRNG(seed: 4)
        let (live, _) = try await build(blocks, excluded: [], order: Array(blocks.indices), rng: &rng)
        for name in ["g", "a", "a2", "b"] {
            _ = try await live.replay(ChainAdmissionBatch.validation(blockHash: h(name)))
        }
        let before = await live.hasExecutedAncestry(blockHash: h("a2"))
        XCTAssertTrue(before)
        _ = try await live.replay(exclusion("a"))
        let a2 = await live.hasExecutedAncestry(blockHash: h("a2"))
        let a = await live.hasExecutedAncestry(blockHash: h("a"))
        let b = await live.hasExecutedAncestry(blockHash: h("b"))
        XCTAssertFalse(a, "an excluded block is not attested")
        XCTAssertFalse(a2, "nor anything below it")
        XCTAssertTrue(b, "the rest of the frontier is untouched")
        let weightA = await live.subtreeWeight(forHash: h("a"))
        XCTAssertEqual(weightA, WorkSum(UInt256(4)), "and its weight is untouched too")
    }

    // MARK: - Random shapes

    /// Random trees, random works, random excluded roots (possibly nested),
    /// random arrival order with exclusions interleaved, cold restore from the
    /// same facts shuffled. Weights equal pure work at every block; the tip is
    /// the heaviest selectable path; live and cold agree with the oracle.
    func testRandomTreesWithRandomInvalidBlocksMatchTheOracle() async throws {
        var rng = SeededRNG(seed: 0x5E1EC7)
        var selectedNonTrivially = 0
        for trial in 0..<40 {
            let count = 3 + Int(rng.next() % 28)
            var blocks = [Planned(name: "g", parent: nil, work: 1 + rng.next() % 9)]
            for i in 1..<count {
                let parent = blocks[Int(rng.next() % UInt64(blocks.count))].name
                blocks.append(Planned(name: "n\(i)", parent: parent, work: 1 + rng.next() % 9))
            }
            var excluded: Set<String> = []
            let exclusions = Int(rng.next() % 4)
            for _ in 0..<exclusions {
                // Never the genesis: a chain with no selectable root has no tip.
                excluded.insert(blocks[1 + Int(rng.next() % UInt64(blocks.count - 1))].name)
            }
            let order = Array(blocks.indices).shuffled(using: &rng)
            let (live, cold) = try await build(blocks, excluded: Array(excluded), order: order, rng: &rng)
            let label = "trial \(trial) (\(count) blocks, excluded \(excluded.sorted()))"
            await assertMatches(live, blocks, excluded: excluded, "\(label) live")
            await assertMatches(cold, blocks, excluded: excluded, "\(label) cold")
            // Count the trials where an exclusion actually changed the selection,
            // so the suite cannot pass on trials where exclusion was moot.
            if oracle(blocks, excluded: excluded).tip != oracle(blocks, excluded: []).tip {
                selectedNonTrivially += 1
            }
        }
        XCTAssertGreaterThan(selectedNonTrivially, 5, "exclusion must have moved the tip in a fair share of trials")
    }
}
