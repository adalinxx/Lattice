import XCTest
import UInt256
@testable import Lattice

/// Parent-attributed run work (§9.10).
///
/// A parent partitions its connected graph into RUNS, one per commitment into
/// each child directory: a block belongs to the run of the nearest block at or
/// above it — by parent pointer — that commits into that directory. Runs
/// partition the graph, so every grind lands in exactly one run: no double
/// count under a parent fork, nothing missed. This is the property the earlier
/// "report the raw subtree" design lacked, and the fork test below is the one
/// that would have exposed it.
///
/// Two build paths, one truth: graphs are built both through `makeChain` (the
/// `init` rebuild) and through `replay` (the `insertBlock` reducer restore
/// uses), and every report must agree between them.
final class ParentRunAttributionTests: XCTestCase {

    private let d = "Payments"

    // MARK: - Fixtures

    /// Every hash the chain sees must be a canonical CID: the reducer and the
    /// accessors canonicalize and refuse anything else. Tests speak in names.
    private func h(_ name: String) -> String { testCID("block:\(name)") }
    private func grind(_ name: String) -> String { testCID("work:\(name)") }

    private func meta(
        _ hash: String, parent: String?, height: UInt64,
        children: [String] = [], work: UInt64,
        commits: [String: String] = [:]
    ) -> BlockMeta {
        BlockMeta(
            blockHash: h(hash), parentBlockHash: parent.map(h), blockHeight: height,
            childHashes: children.map(h),
            workContributions: [VerifiedWorkContribution(id: grind(hash), work: UInt256(work))],
            childCommitments: commits
        )
    }

    /// A child block credited under a PARENT grind (the grind its carrier was
    /// mined with), holding `work` at the child's own price.
    private func childMeta(_ hash: String, parent: String?, height: UInt64,
                           children: [String] = [], grind: String, work: UInt256) -> BlockMeta {
        BlockMeta(
            blockHash: h(hash), parentBlockHash: parent.map(h), blockHeight: height,
            childHashes: children.map(h),
            workContributions: [VerifiedWorkContribution(id: grind, work: work)]
        )
    }

    /// A block+work batch built by hand, so the replay path can be driven one
    /// batch at a time in an arrival order of the test's choosing.
    private func batch(
        _ hash: String, parent: String?, height: UInt64, work: UInt64,
        commits: [String: String] = [:]
    ) -> ChainAdmissionBatch {
        let fact = ChainBlockFact(
            blockHash: h(hash), parentBlockHash: parent.map(h), blockHeight: height,
            postStateCID: testCID("post:\(hash)"),
            prevStateCID: testCID("prev:\(hash)"),
            specCID: testCID("spec"),
            target: "1", nextTarget: "1",
            timestamp: Int64(1_000 + height),
            stateDiff: .empty,
            childCommitments: commits
        )
        return ChainAdmissionBatch(facts: [
            .block(fact),
            .work(ChainWorkFact(
                blockHash: h(hash),
                contribution: VerifiedWorkContribution(id: grind(hash), work: UInt256(work))
            )),
        ])
    }

    private func sum(_ values: UInt64...) -> WorkSum {
        WorkSum(UInt256(values.reduce(0, +)))
    }

    private func report(_ run: WorkSum, own: WorkSum, revision: UInt64 = 1) -> ParentRunReport {
        ParentRunReport(blockHash: h("p1"), directory: d, runWork: run, ownWork: own, revision: revision)
    }

    /// The worked example: parent P1 ← P2 ← P3, P1 commits child C, P2 and P3
    /// commit nothing. Both build paths.
    private func linearByInit() -> ChainState {
        makeChain(blocks: [
            meta("g", parent: nil, height: 0, children: ["p1"], work: 1),
            meta("p1", parent: "g", height: 1, children: ["p2"], work: 5, commits: [d: testCID("c")]),
            meta("p2", parent: "p1", height: 2, children: ["p3"], work: 3),
            meta("p3", parent: "p2", height: 3, work: 7),
        ])
    }

    private func linearByReplay() async throws -> ChainState {
        let chain = try await ChainState.restore(replaying: [
            batch("g", parent: nil, height: 0, work: 1),
        ])
        _ = try await chain.replay(batch("p1", parent: "g", height: 1, work: 5, commits: [d: testCID("c")]))
        _ = try await chain.replay(batch("p2", parent: "p1", height: 2, work: 3))
        _ = try await chain.replay(batch("p3", parent: "p2", height: 3, work: 7))
        return chain
    }

    /// Child chain: genesis cg ← c, where c was committed by parent block p1
    /// and so is credited under p1's grind at the child's own price.
    private func childChain(existing: UInt256) -> ChainState {
        makeChain(blocks: [
            meta("cg", parent: nil, height: 0, children: ["c"], work: 1),
            childMeta("c", parent: "cg", height: 1, grind: grind("p1"), work: existing),
        ])
    }

    private func run(_ chain: ChainState, at hash: String, in directory: String? = nil) async -> WorkSum? {
        await chain.parentRunReport(at: h(hash), directory: directory ?? d)?.runWork
    }

    private func credited(_ chain: ChainState) async -> UInt256? {
        await chain.workContribution(id: grind("p1"), at: h("c"))?.work
    }

    // MARK: - Partition

    func testLinearRunIsTheCommitterPlusEveryDescendant() async throws {
        for (label, chain) in [("init", linearByInit()), ("replay", try await linearByReplay())] {
            let report = await chain.parentRunReport(at: h("p1"), directory: d)
            XCTAssertEqual(report?.runWork, sum(5, 3, 7), "\(label): w(P1)+w(P2)+w(P3)")
            XCTAssertEqual(report?.ownWork, sum(5), label)
            XCTAssertEqual(report?.directory, d, label)
            XCTAssertEqual(report?.blockHash, h("p1"), label)
        }
    }

    func testInitAndReplayBuildsAgree() async throws {
        let a = linearByInit()
        let b = try await linearByReplay()
        for hash in ["g", "p1", "p2", "p3"] {
            let ra = await a.parentRunReport(at: h(hash), directory: d)
            let rb = await b.parentRunReport(at: h(hash), directory: d)
            XCTAssertEqual(ra?.runWork, rb?.runWork, hash)
            XCTAssertEqual(ra?.ownWork, rb?.ownWork, hash)
            XCTAssertEqual(ra == nil, rb == nil, hash)
        }
    }

    /// The case that broke the raw-subtree design: a parent fork below the
    /// committer, with one branch re-committing into the same directory. Runs
    /// must partition — each grind in exactly one run, both branches present.
    func testParentForkPartitionsWithoutDoubleCountOrMiss() async throws {
        //        g
        //        |
        //       p1  (commits c1)
        //      /  \
        //    p2    x        p2 commits c2; x commits nothing
        //    |
        //    q              q commits nothing
        let byInit = makeChain(blocks: [
            meta("g", parent: nil, height: 0, children: ["p1"], work: 1),
            meta("p1", parent: "g", height: 1, children: ["p2", "x"], work: 5, commits: [d: testCID("c1")]),
            meta("p2", parent: "p1", height: 2, children: ["q"], work: 3, commits: [d: testCID("c2")]),
            meta("x", parent: "p1", height: 2, work: 11),
            meta("q", parent: "p2", height: 3, work: 7),
        ])
        let byReplay = try await ChainState.restore(replaying: [batch("g", parent: nil, height: 0, work: 1)])
        _ = try await byReplay.replay(batch("p1", parent: "g", height: 1, work: 5, commits: [d: testCID("c1")]))
        _ = try await byReplay.replay(batch("p2", parent: "p1", height: 2, work: 3, commits: [d: testCID("c2")]))
        _ = try await byReplay.replay(batch("x", parent: "p1", height: 2, work: 11))
        _ = try await byReplay.replay(batch("q", parent: "p2", height: 3, work: 7))

        for (label, chain) in [("init", byInit), ("replay", byReplay)] {
            let r1 = await run(chain, at: "p1")
            let r2 = await run(chain, at: "p2")
            XCTAssertEqual(r1, sum(5, 11), "\(label): p1's run is itself and the x branch, NOT p2's subtree")
            XCTAssertEqual(r2, sum(3, 7), "\(label): p2's run is itself and q")
            // Partition: the two runs together are exactly every non-genesis grind.
            XCTAssertEqual((r1 ?? .zero) + (r2 ?? .zero), sum(5, 11, 3, 7),
                           "\(label): runs partition the parent work — a raw subtree would count 3+7 twice")
            let rx = await run(chain, at: "x")
            let rq = await run(chain, at: "q")
            XCTAssertNil(rx, label)
            XCTAssertNil(rq, label)
        }
    }

    func testDirectoriesAreIndependentPartitions() async throws {
        let e = "Markets"
        let chain = makeChain(blocks: [
            meta("g", parent: nil, height: 0, children: ["p1"], work: 1),
            meta("p1", parent: "g", height: 1, children: ["p2"], work: 5,
                 commits: [d: testCID("a"), e: testCID("b")]),
            meta("p2", parent: "p1", height: 2, work: 3, commits: [d: testCID("a2")]),
        ])
        let p1d = await run(chain, at: "p1", in: d)
        let p2d = await run(chain, at: "p2", in: d)
        let p1e = await run(chain, at: "p1", in: e)
        let p2e = await run(chain, at: "p2", in: e)
        XCTAssertEqual(p1d, sum(5), "p2 re-commits into d, so p1's d-run stops at p1")
        XCTAssertEqual(p2d, sum(3))
        XCTAssertEqual(p1e, sum(5, 3), "p2 commits nothing into e, so p1's e-run keeps it")
        XCTAssertNil(p2e, "p2 is not a committer into e")
    }

    func testReportIsNilForNonCommitterUnknownOrWrongDirectory() async throws {
        let chain = linearByInit()
        let p2 = await run(chain, at: "p2")
        let g = await run(chain, at: "g")
        let unknown = await run(chain, at: "nope")
        let wrongDirectory = await run(chain, at: "p1", in: "Other")
        XCTAssertNil(p2, "p2 commits nothing")
        XCTAssertNil(g, "genesis commits nothing")
        XCTAssertNil(unknown, "unknown block")
        XCTAssertNil(wrongDirectory, "wrong directory")
    }

    /// A committer's run always contains its own work: the report's two
    /// numbers are ordered, which is what lets the child subtract.
    func testOwnWorkNeverExceedsRunWork() async throws {
        let chain = try await linearByReplay()
        let report = await chain.parentRunReport(at: h("p1"), directory: d)
        XCTAssertEqual(report?.ownWork, sum(5))
        XCTAssertNotNil(report?.runWork.subtracting(report?.ownWork ?? .zero))
    }

    // MARK: - Maintenance

    func testStrengtheningARunMemberRaisesTheRunByExactlyTheDelta() async throws {
        let chain = try await linearByReplay()
        let before = await run(chain, at: "p1")
        // p2's grind observed stronger: 3 -> 10, delta 7.
        let result = await chain.addWorkContribution(
            VerifiedWorkContribution(id: grind("p2"), work: UInt256(10)), to: h("p2")
        )
        XCTAssertTrue(result.addedContribution, "fixture must actually strengthen")
        let after = await run(chain, at: "p1")
        XCTAssertEqual(after, (before ?? .zero) + sum(7))
        XCTAssertEqual(after, sum(5, 10, 7), "the run reflects the block's NEW work, once")
    }

    func testStrengtheningTheCommitterItselfRaisesItsOwnRun() async throws {
        let chain = try await linearByReplay()
        let result = await chain.addWorkContribution(
            VerifiedWorkContribution(id: grind("p1"), work: UInt256(50)), to: h("p1")
        )
        XCTAssertTrue(result.addedContribution)
        let report = await chain.parentRunReport(at: h("p1"), directory: d)
        XCTAssertEqual(report?.ownWork, sum(50))
        XCTAssertEqual(report?.runWork, sum(50, 3, 7))
    }

    func testWeakerObservationChangesNothing() async throws {
        let chain = try await linearByReplay()
        let before = await run(chain, at: "p1")
        let result = await chain.addWorkContribution(
            VerifiedWorkContribution(id: grind("p2"), work: UInt256(2)), to: h("p2")
        )
        XCTAssertFalse(result.addedContribution)
        let after = await run(chain, at: "p1")
        XCTAssertEqual(after, before)
    }

    func testOrphanIsCreditedWhenItConnectsNotBefore() async throws {
        let chain = try await ChainState.restore(replaying: [batch("g", parent: nil, height: 0, work: 1)])
        _ = try await chain.replay(batch("p1", parent: "g", height: 1, work: 5, commits: [d: testCID("c")]))
        // p3 arrives before its parent p2, and so does a strengthening of it.
        _ = try await chain.replay(batch("p3", parent: "p2", height: 3, work: 7))
        let strengthened = await chain.addWorkContribution(
            VerifiedWorkContribution(id: grind("p3"), work: UInt256(9)), to: h("p3")
        )
        XCTAssertTrue(strengthened.addedContribution)
        let orphaned = await run(chain, at: "p1")
        XCTAssertEqual(orphaned, sum(5), "an orphan's work must not be credited before it is connected")
        _ = try await chain.replay(batch("p2", parent: "p1", height: 2, work: 3))
        let connected = await run(chain, at: "p1")
        XCTAssertEqual(connected, sum(5, 3, 9),
                       "connecting p2 connects p3 too, and credits p3 at its CURRENT work, once")
    }

    /// A committer that arrives as an orphan is not a committer yet: its run
    /// exists only once it is connected, and then holds its whole subtree.
    func testOrphanCommitterReportsNothingUntilConnected() async throws {
        let chain = try await ChainState.restore(replaying: [batch("g", parent: nil, height: 0, work: 1)])
        _ = try await chain.replay(batch("p2", parent: "p1", height: 2, work: 3, commits: [d: testCID("c")]))
        _ = try await chain.replay(batch("p3", parent: "p2", height: 3, work: 7))
        let orphaned = await chain.parentRunReport(at: h("p2"), directory: d)
        XCTAssertNil(orphaned, "an unconnected committer must not be served")
        _ = try await chain.replay(batch("p1", parent: "g", height: 1, work: 5))
        let connected = await run(chain, at: "p2")
        XCTAssertEqual(connected, sum(3, 7))
    }

    /// Never revoked (§9.10): excluding a run member on this chain leaves its
    /// run untouched, and a block descending from an excluded block is still
    /// connected and still credited.
    func testExclusionNeitherRevokesNorBlocksRunCredit() async throws {
        let chain = try await linearByReplay()
        let before = await run(chain, at: "p1")
        _ = try await chain.replay(ChainAdmissionBatch(facts: [
            .exclusion(ChainExclusionFact(blockHash: h("p2"))),
        ]))
        // Fixture guard: the exclusion really removed p2 from THIS chain's
        // fork choice, or the invariant below is not being exercised.
        let p2Weight = await chain.subtreeWeight(forHash: h("p2"))
        XCTAssertEqual(p2Weight, WorkSum.zero, "p2 must be excluded from fork choice")
        let afterExclusion = await run(chain, at: "p1")
        XCTAssertEqual(afterExclusion, before, "a run is never revoked by exclusion")
        // A new block under the excluded p2 is still connected and credited.
        _ = try await chain.replay(batch("p4", parent: "p2", height: 3, work: 13))
        let afterInsert = await run(chain, at: "p1")
        XCTAssertEqual(afterInsert, (before ?? .zero) + sum(13), "run credit is independent of exclusion")
        // And so is a strengthening of the excluded block itself.
        let strengthened = await chain.addWorkContribution(
            VerifiedWorkContribution(id: grind("p2"), work: UInt256(4)), to: h("p2")
        )
        XCTAssertTrue(strengthened.addedContribution)
        let afterStrengthen = await run(chain, at: "p1")
        XCTAssertEqual(afterStrengthen, (before ?? .zero) + sum(13, 1))
    }

    /// Restart equivalence: the run table a live sequence built equals the one
    /// a cold restore rebuilds from the same durable facts in ANY order.
    func testColdRestoreRebuildsTheSameRunsRegardlessOfOrder() async throws {
        let facts = [
            batch("g", parent: nil, height: 0, work: 1),
            batch("p1", parent: "g", height: 1, work: 5, commits: [d: testCID("c1")]),
            batch("p2", parent: "p1", height: 2, work: 3, commits: [d: testCID("c2")]),
            batch("x", parent: "p1", height: 2, work: 11),
            batch("q", parent: "p2", height: 3, work: 7),
            ChainAdmissionBatch(facts: [.work(ChainWorkFact(
                blockHash: h("x"),
                contribution: VerifiedWorkContribution(id: grind("x"), work: UInt256(20))
            ))]),
        ]
        let live = try await ChainState.restore(replaying: [facts[0]])
        for fact in facts.dropFirst() { _ = try await live.replay(fact) }
        let liveP1 = await run(live, at: "p1")
        let liveP2 = await run(live, at: "p2")
        XCTAssertEqual(liveP1, sum(5, 20))
        XCTAssertEqual(liveP2, sum(3, 7))

        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5 {
            let cold = try await ChainState.restore(replaying: facts.shuffled(using: &generator))
            let coldP1 = await run(cold, at: "p1")
            let coldP2 = await run(cold, at: "p2")
            XCTAssertEqual(coldP1, liveP1)
            XCTAssertEqual(coldP2, liveP2)
        }
    }

    // MARK: - The child's side: mint

    private func attributed(_ chain: ChainState) async -> UInt256? {
        let id = AttributedRunIdentity(grindID: grind("p1")).contributionID!
        return await chain.workContribution(id: id, at: h("c"))?.work
    }

    /// Child chain holds C under grind G = P1's grind at its own price. The
    /// run's OTHER blocks are credited under the attributed identity:
    /// attributed = run − own; the grind's own credit is untouched.
    func testMintCreditsRunMinusOwnBesideTheGrind() async throws {
        let child = childChain(existing: UInt256(5))
        let outcome = await child.strengthenFromParentReport(
            child: h("c"), grindID: grind("p1"), report: report(sum(5, 3, 7), own: sum(5), revision: 9)
        )
        guard case .strengthened(let batch) = outcome else { return XCTFail("must strengthen: \(outcome)") }
        let commit = try await child.replay(batch)
        XCTAssertNotNil(commit, "the batch must apply")
        let base = await credited(child)
        let extra = await attributed(child)
        XCTAssertEqual(base, UInt256(5), "the committer's own grind stays at the child's price, once")
        XCTAssertEqual(extra, UInt256(10), "3 + 7: the run minus the committer")
        let weight = await child.subtreeWeight(forHash: h("cg"))
        XCTAssertEqual(weight, sum(1, 5, 10), "the child's fork choice sees own + attributed")
    }

    func testMintKeepsTheChildsOwnRaise() async throws {
        // C's existing credit (9) exceeds the parent's price for the same grind (5).
        let child = childChain(existing: UInt256(9))
        let outcome = await child.strengthenFromParentReport(
            child: h("c"), grindID: grind("p1"), report: report(sum(5, 3, 7), own: sum(5))
        )
        guard case .strengthened(let batch) = outcome else { return XCTFail("must strengthen: \(outcome)") }
        _ = try await child.replay(batch)
        let base = await credited(child)
        let extra = await attributed(child)
        XCTAssertEqual(base, UInt256(9), "the terminal-target raise survives")
        XCTAssertEqual(extra, UInt256(10))
        let weight = await child.subtreeWeight(forHash: h("cg"))
        XCTAssertEqual(weight, sum(1, 9, 10))
    }

    /// The committer's own grind is what the child ALREADY holds, priced by
    /// the child. A run with no other blocks attributes nothing.
    func testMintNeverCountsTheCommittersOwnGrindTwice() async throws {
        let child = childChain(existing: UInt256(5))
        let outcome = await child.strengthenFromParentReport(
            child: h("c"), grindID: grind("p1"), report: report(sum(5), own: sum(5))
        )
        XCTAssertEqual(outcome, .notStronger(existing: .zero, derived: .zero))
    }

    /// Idempotent: the same report twice is one credit, not two. (Crediting by
    /// strengthening the grind itself failed exactly this — the second
    /// application read the first as the child's own price.)
    func testRepeatedReportIsRefusedNotAddedAgain() async throws {
        let child = childChain(existing: UInt256(5))
        for _ in 0..<3 {
            let outcome = await child.strengthenFromParentReport(
                child: h("c"), grindID: grind("p1"), report: report(sum(5, 3, 7), own: sum(5))
            )
            if case .strengthened(let batch) = outcome { _ = try await child.replay(batch) }
        }
        let extra = await attributed(child)
        XCTAssertEqual(extra, UInt256(10))
        let weight = await child.subtreeWeight(forHash: h("cg"))
        XCTAssertEqual(weight, sum(1, 5, 10))
    }

    func testMintRefusalsAreTypedAndMutateNothing() async throws {
        let child = childChain(existing: UInt256(5))
        let unknownGrind = await child.strengthenFromParentReport(
            child: h("c"), grindID: grind("zz"), report: report(sum(9), own: sum(5))
        )
        XCTAssertEqual(unknownGrind, .unknownGrindAtChild)
        let unknownBlock = await child.strengthenFromParentReport(
            child: h("nope"), grindID: grind("p1"), report: report(sum(9), own: sum(5))
        )
        XCTAssertEqual(unknownBlock, .unknownGrindAtChild)
        let malformed = await child.strengthenFromParentReport(
            child: h("c"), grindID: grind("p1"), report: report(sum(4), own: sum(5))
        )
        XCTAssertEqual(malformed, .malformedReport, "own > run is impossible for an honest run")
        let base = await credited(child)
        let extra = await attributed(child)
        XCTAssertEqual(base, UInt256(5), "refusals mutate nothing")
        XCTAssertNil(extra)
        let weight = await child.subtreeWeight(forHash: h("cg"))
        XCTAssertEqual(weight, sum(1, 5))
    }

    func testMintRefusesRatherThanSaturates() async throws {
        let child = childChain(existing: UInt256(5))
        let run = WorkSum(UInt256.max) + WorkSum(UInt256(6)) // run − own = max + 1
        let outcome = await child.strengthenFromParentReport(
            child: h("c"), grindID: grind("p1"), report: report(run, own: sum(5))
        )
        guard case .unrepresentable(let derived) = outcome else {
            return XCTFail("a value one contribution cannot carry must be refused, never saturated: \(outcome)")
        }
        XCTAssertEqual(derived, WorkSum(UInt256.max) + WorkSum(UInt256(1)))
        let extra = await attributed(child)
        XCTAssertNil(extra)
    }

    func testMintIsMonotoneAcrossSuccessiveReports() async throws {
        let child = childChain(existing: UInt256(5))
        func mint(_ run: UInt64) async -> ParentReportStrengthening {
            await child.strengthenFromParentReport(
                child: h("c"), grindID: grind("p1"), report: report(sum(run), own: sum(5))
            )
        }
        guard case .strengthened(let first) = await mint(12) else { return XCTFail("12 strengthens") }
        _ = try await child.replay(first)
        let same = await mint(12)
        XCTAssertEqual(same, .notStronger(existing: sum(7), derived: sum(7)), "a repeat report is refused")
        let lower = await mint(8)
        XCTAssertEqual(lower, .notStronger(existing: sum(7), derived: sum(3)), "a shrunken report is refused")
        guard case .strengthened(let second) = await mint(13) else { return XCTFail("13 strengthens") }
        _ = try await child.replay(second)
        let base = await credited(child)
        let extra = await attributed(child)
        XCTAssertEqual(base, UInt256(5))
        XCTAssertEqual(extra, UInt256(8))
    }

    func testStaleStrengtheningIsANoOpNotACorruption() async throws {
        let child = childChain(existing: UInt256(5))
        func mint(_ run: UInt64) async -> ChainAdmissionBatch? {
            if case .strengthened(let b) = await child.strengthenFromParentReport(
                child: h("c"), grindID: grind("p1"), report: report(sum(run), own: sum(5))
            ) { return b }
            return nil
        }
        let weaker = await mint(12)   // attributed 7
        let stronger = await mint(20) // attributed 15
        _ = try await child.replay(try XCTUnwrap(stronger))
        let late = try await child.replay(try XCTUnwrap(weaker)) // arrives after the stronger one
        XCTAssertNil(late, "a stale strengthening replays as a no-op, never a throw")
        let extra = await attributed(child)
        XCTAssertEqual(extra, UInt256(15))
    }

    /// The child's fork choice is what all of this is for: a child fork whose
    /// carrier gathered more parent descendants wins, even when the child
    /// blocks themselves are equal.
    func testAttributedWorkMovesChildForkChoice() async throws {
        //   cg
        //  /  \
        // a    b     equal own work, different parent runs behind them
        let child = makeChain(blocks: [
            meta("cg", parent: nil, height: 0, children: ["a", "b"], work: 1),
            childMeta("a", parent: "cg", height: 1, grind: grind("pa"), work: UInt256(5)),
            childMeta("b", parent: "cg", height: 1, grind: grind("pb"), work: UInt256(5)),
        ], mainChainHashes: [h("cg"), h("a")])
        let tipBefore = await child.chainTip
        XCTAssertEqual(tipBefore, h("a"))
        // b's carrier gathered 40 of descendant parent work; a's gathered 0.
        let outcome = await child.strengthenFromParentReport(
            child: h("b"), grindID: grind("pb"),
            report: ParentRunReport(blockHash: h("pb"), directory: d, runWork: sum(5, 40), ownWork: sum(5), revision: 1)
        )
        guard case .strengthened(let batch) = outcome else { return XCTFail("must strengthen: \(outcome)") }
        let commit = try await child.replay(batch)
        XCTAssertEqual(commit?.tipHash, h("b"))
        let tipAfter = await child.chainTip
        XCTAssertEqual(tipAfter, h("b"), "parent work behind b's carrier moved the child's fork choice")
        let wa = await child.subtreeWeight(forHash: h("a"))
        let wb = await child.subtreeWeight(forHash: h("b"))
        XCTAssertEqual(wa, sum(5))
        XCTAssertEqual(wb, sum(45))
    }

    // MARK: - Recursion: parent's own attributed work flows through

    /// The recursive shape (Nexus → A → B): a strengthening A received FROM
    /// ITS parent raises the run A serves to B, because the run is over A's
    /// own `work`, which that strengthening raised.
    func testWorkAttributedToTheParentFlowsIntoTheRunItServes() async throws {
        let a = try await linearByReplay() // A: g ← p1(commits into B's dir) ← p2 ← p3
        // A's own block p3 was strengthened by A's parent (grind of p3 raised).
        let up = await a.addWorkContribution(
            VerifiedWorkContribution(id: grind("p3"), work: UInt256(107)), to: h("p3")
        )
        XCTAssertTrue(up.addedContribution)
        let served = await a.parentRunReport(at: h("p1"), directory: d)
        XCTAssertEqual(served?.runWork, sum(5, 3, 107), "B sees, through A, the work Nexus attributed to A")
    }

    // MARK: - Cost, as counters

    /// Run bookkeeping is O(#directories with a nearest committer) per
    /// connected block — never O(height). Asserted exactly, and by ratio.
    func testRunUpdatesArePerDirectoryNotPerHeight() async throws {
        func build(depth: Int, directories: [String]) async throws -> UInt64 {
            let chain = try await ChainState.restore(replaying: [batch("g", parent: nil, height: 0, work: 1)])
            let commits = Dictionary(uniqueKeysWithValues: directories.map { ($0, testCID("c-\($0)")) })
            _ = try await chain.replay(batch("p1", parent: "g", height: 1, work: 2, commits: commits))
            let start = await chain.runAttributionUpdateCount
            var parent = "p1"
            for i in 2...depth {
                let h = "p\(i)"
                _ = try await chain.replay(batch(h, parent: parent, height: UInt64(i), work: 2))
                parent = h
            }
            let end = await chain.runAttributionUpdateCount
            return end - start
        }
        let oneDir64 = try await build(depth: 64, directories: [d])
        let oneDir512 = try await build(depth: 512, directories: [d])
        let threeDir64 = try await build(depth: 64, directories: [d, "A", "B"])
        XCTAssertEqual(oneDir64, 63, "one update per block after the committer")
        XCTAssertEqual(oneDir512, 511, "flat per block as height grows")
        XCTAssertEqual(threeDir64, 63 * 3, "three directories: three updates per block")
        XCTAssertEqual(Double(oneDir512) / Double(oneDir64), 511.0 / 63.0, accuracy: 0.001,
                       "the per-block cost does not depend on height")
    }

    /// The parent's report is a dictionary read: serving it writes nothing.
    func testServingAReportCostsNoBookkeeping() async throws {
        let chain = try await linearByReplay()
        let before = await chain.runAttributionUpdateCount
        for _ in 0..<1_000 { _ = await chain.parentRunReport(at: h("p1"), directory: d) }
        let after = await chain.runAttributionUpdateCount
        XCTAssertEqual(after, before)
    }

    /// The Euler subtree query the child's fork choice reads: visits bounded
    /// by the sequence tree's height, asserted at two sizes so a
    /// slow-but-constant implementation cannot pass.
    func testEulerSubtreeQueryVisitsAreLogarithmic() {
        func visits(n: Int) -> Int {
            var events: [EulerWorkIndex.Event] = []
            for i in 0..<n { events.append(.open("b\(i)", WorkSum(UInt256(1)))) }
            for i in (0..<n).reversed() { events.append(.close("b\(i)")) }
            let index = EulerWorkIndex.build(events: events)
            let query = index.subtreeWorkVisiting("b0")
            XCTAssertEqual(query?.work, WorkSum(UInt256(UInt64(n))))
            return query?.visits ?? .max
        }
        let small = visits(n: 64), large = visits(n: 4_096)
        // Two prefix walks, each ≤ AVL height ≤ 1.45·log2(2n) + 2.
        XCTAssertLessThanOrEqual(small, 2 * 13)
        XCTAssertLessThanOrEqual(large, 2 * 22)
        XCTAssertLessThan(Double(large) / Double(small), 4.0,
                          "64× the blocks must cost far less than 4× the visits")
    }
}
