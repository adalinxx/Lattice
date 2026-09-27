import XCTest
import CID
import UInt256
@testable import Lattice

/// The spec-derived oracle (`ForkChoiceOracle.swift`) checked two ways: on its
/// own against hand-computed spec examples, and against `ChainState` on the
/// golden graph and on the graphs the existing differential tests drive.
@MainActor
final class ForkChoiceOracleTests: XCTestCase {
    // MARK: - Hand-built fixtures

    private func cid(_ seed: String) -> String { testCID("oracle-tests/\(seed)") }

    private func block(
        _ name: String, parent: String?, height: UInt64, grind: String? = nil, work: UInt64
    ) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
            .block(ChainBlockFact(
                blockHash: cid(name),
                parentBlockHash: parent.map(cid),
                blockHeight: height,
                postStateCID: cid("post/\(name)"),
                prevStateCID: cid("prev/\(name)"),
                specCID: cid("spec"),
                target: "1",
                nextTarget: "1",
                timestamp: Int64(height),
                stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: cid(name),
                contribution: VerifiedWorkContribution(id: cid(grind ?? "grind/\(name)"), work: UInt256(work))
            )),
        ])
    }

    private func work(_ name: String, grind: String, work: UInt64) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [
            .work(ChainWorkFact(
                blockHash: cid(name),
                contribution: VerifiedWorkContribution(id: cid(grind), work: UInt256(work))
            )),
        ])
    }

    private func exclusion(_ name: String) -> ChainAdmissionBatch {
        ChainAdmissionBatch(facts: [.exclusion(ChainExclusionFact(blockHash: cid(name)))])
    }

    // MARK: - The oracle against the spec

    /// §9.1/§9.2: repeated observations of one grind at its location count
    /// once, at the strongest quantity; distinct grinds sum.
    func testOracleDeduplicatesRepeatedObservationsOfOneGrind() {
        var oracle = ForkChoiceOracle()
        oracle.apply(block("g", parent: nil, height: 0, work: 1))
        oracle.apply(block("a", parent: "g", height: 1, work: 3))
        oracle.apply(work("a", grind: "grind/a", work: 5))   // stronger observation
        oracle.apply(work("a", grind: "grind/a", work: 2))   // weaker: ignored
        oracle.apply(work("a", grind: "extra", work: 4))     // a second grind
        let view = oracle.view()
        XCTAssertEqual(view.trueCumWork(of: cid("a")), OracleWork(UInt256(9)), "5 (strongest) + 4")
        XCTAssertEqual(view.trueCumWork(of: cid("g")), OracleWork(UInt256(10)), "1 + 5 + 4")
        XCTAssertEqual(view.cumulativeWork(of: cid("a")), OracleWork(UInt256(10)))
    }

    /// §9.4: equal `trueCumWork` prefers the lexicographically smaller
    /// canonical CID bytes — decided here with the CID library alone.
    func testOracleBreaksEqualWorkTiesBySmallerCanonicalCIDBytes() throws {
        var oracle = ForkChoiceOracle()
        oracle.apply(block("g", parent: nil, height: 0, work: 1))
        oracle.apply(block("left", parent: "g", height: 1, work: 2))
        oracle.apply(block("right", parent: "g", height: 1, work: 2))
        let projection = try XCTUnwrap(oracle.view().canonicalProjection())
        let leftBytes = try CID(cid("left")).rawBuffer
        let rightBytes = try CID(cid("right")).rawBuffer
        XCTAssertNotEqual(leftBytes, rightBytes)
        let expected = leftBytes.lexicographicallyPrecedes(rightBytes) ? cid("left") : cid("right")
        XCTAssertEqual(projection.tip, expected)
        XCTAssertEqual(projection.path, [cid("g"), expected])
    }

    /// §9.9: an excluded block's work still weighs its ancestors, but the
    /// descent never steps into it — however heavy its subtree grows.
    func testOracleNeverStepsIntoAnExcludedBlockButStillWeighsIt() throws {
        var oracle = ForkChoiceOracle()
        oracle.apply(block("g", parent: nil, height: 0, work: 1))
        oracle.apply(block("bad", parent: "g", height: 1, work: 50))
        oracle.apply(block("bad-child", parent: "bad", height: 2, work: 50))
        oracle.apply(block("good", parent: "g", height: 1, work: 2))
        oracle.apply(exclusion("bad"))
        let view = oracle.view()
        XCTAssertEqual(view.trueCumWork(of: cid("g")), OracleWork(UInt256(103)), "exclusion removes no weight")
        let projection = try XCTUnwrap(view.canonicalProjection())
        XCTAssertEqual(projection.tip, cid("good"))
        XCTAssertEqual(projection.path, [cid("g"), cid("good")])
    }

    /// §9.4: competing genesis roots are compared by the same rule.
    func testOracleSelectsTheHeavierGenesisRoot() throws {
        var oracle = ForkChoiceOracle()
        oracle.apply(block("g1", parent: nil, height: 0, work: 1))
        oracle.apply(block("g2", parent: nil, height: 0, work: 1))
        oracle.apply(block("g2-child", parent: "g2", height: 1, work: 1))
        let projection = try XCTUnwrap(oracle.view().canonicalProjection())
        XCTAssertEqual(projection.path, [cid("g2"), cid("g2-child")])
    }

    // MARK: - The oracle against ChainState

    /// Tip, canonical path, and every present block's subtree and prefix
    /// totals must agree between the live chain and the oracle's model of the
    /// same facts.
    private func assertAgreement(
        _ chain: ChainState,
        _ oracle: ForkChoiceOracle,
        _ event: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let view = oracle.view()
        let projection = try XCTUnwrap(view.canonicalProjection(), "\(event): no selectable root", file: file, line: line)
        let liveTip = await chain.getMainChainTip()
        XCTAssertEqual(liveTip, projection.tip, "\(event): tip", file: file, line: line)

        var livePath: [String] = []
        let tipHeight = await chain.getHighestBlockHeight()
        for height in 0...tipHeight {
            let hash = await chain.getMainChainBlockHash(atIndex: height)
            livePath.append(try XCTUnwrap(
                hash, "\(event): canonical index has a hole at height \(height)", file: file, line: line
            ))
        }
        XCTAssertEqual(livePath, projection.path, "\(event): canonical path", file: file, line: line)

        for hash in view.blocks.keys.sorted() {
            let subtree = await chain.subtreeWeight(forHash: hash)
            XCTAssertEqual(
                subtree?.toHexString(), view.trueCumWork(of: hash).hex,
                "\(event): trueCumWork of \(hash)", file: file, line: line
            )
            let prefix = await chain.getCumulativeWork(forHash: hash)
            XCTAssertEqual(
                prefix?.toHexString(), view.cumulativeWork(of: hash).hex,
                "\(event): cumulativeWork of \(hash)", file: file, line: line
            )
        }
    }

    func testOracleAgreesWithChainStateOnTheGoldenGraph() async throws {
        let graph = ForkChoiceGoldenGraph.generate()
        let chain = try await ChainState.restore(replaying: [graph.events[0].batch])
        var oracle = ForkChoiceOracle()
        oracle.apply(graph.events[0].batch)
        for event in graph.events.dropFirst() {
            _ = try await chain.replay(event.batch)
            oracle.apply(event.batch)
            if event.index % 25 == 0 {
                try await assertAgreement(chain, oracle, "event \(event.index)")
            }
        }
        try await assertAgreement(chain, oracle, "final")
        let restored = try await ChainState.restore(replaying: graph.events.map(\.batch).reversed())
        try await assertAgreement(restored, oracle, "reversed restore")
    }

    func testOracleAgreesWithChainStateOnSegmentBaseDifferentialFixtures() async throws {
        for seed: UInt64 in [
            0xC0FFEE, 0xD1FF_EA5E, 0xFACE_FEED, 0xBADC_0DE,
            0x1234_5678, 0x8765_4321, 0x0DDC_0FFE, 0x51DE_CAFE,
        ] {
            let planned = SegmentBaseDifferentialFixtures.planned(seed: seed)
            let chain = try await ChainState.restore(replaying: [planned[0].batch])
            var oracle = ForkChoiceOracle()
            oracle.apply(planned[0].batch)
            // Descendants before ancestors, as the differential test delivers
            // them, then the rest in index order.
            let order = [4, 3, 1, 2, 5] + Array(6..<planned.count)
            for index in order {
                _ = try await chain.replay(planned[index].batch)
                oracle.apply(planned[index].batch)
                try await assertAgreement(chain, oracle, "seed \(seed) block \(index)")
            }
            let shared = testCID("oracle-differential-\(seed)-shared")
            for (step, strength) in [3, 7, 11].enumerated() {
                let batch = SegmentBaseDifferentialFixtures.work(
                    blockHash: planned[4].hash, id: shared, work: UInt64(strength)
                )
                _ = try await chain.replay(batch)
                oracle.apply(batch)
                try await assertAgreement(chain, oracle, "seed \(seed) strengthening \(step)")
            }
            for index in stride(from: 2, to: planned.count, by: 3) where planned[index].parentHash != nil {
                let batch = SegmentBaseDifferentialFixtures.exclusion(of: planned[index].hash)
                _ = try await chain.replay(batch)
                oracle.apply(batch)
                try await assertAgreement(chain, oracle, "seed \(seed) exclusion \(index)")
            }
        }
    }

    func testOracleAgreesWithChainStateOnTheBushyReplayFixture() async throws {
        let (batches, _) = ReplayProjectionDeferralTests.bushyBatches()
        var oracle = ForkChoiceOracle()
        for batch in batches { oracle.apply(batch) }
        let restored = try await ChainState.restore(replaying: Array(batches.reversed()))
        try await assertAgreement(restored, oracle, "bushy reversed restore")
    }
}
