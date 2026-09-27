import XCTest
import UInt256
@testable import Lattice

// MARK: - Fixture: a seeded fact-batch script

/// One scripted arrival: a durable fact batch and what it is about, so a
/// failure can name the event and the oracle can rebuild its model from the
/// same facts.
struct ForkChoiceGoldenEvent {
    enum Kind: String {
        case block, secondGrind, strengthen, attributedRun, exclusion, validation
    }

    let index: Int
    let kind: Kind
    /// The block the batch is about, by fixture name (`b<n>`).
    let subject: String
    let batch: ChainAdmissionBatch
}

/// A seeded single-chain graph of ~300 blocks: two competing genesis roots,
/// several competing branches (siblings near the tip and deep forks), blocks
/// arriving before their parents, second grinds and stronger observations on
/// blocks already held, parent-attributed runs (§9.10) credited at this chain,
/// exclusions (§9.9), validations, and commitments into one child directory so
/// this chain also SERVES run reports.
///
/// Every hash is a content id of a fixed seed string, every choice comes from
/// `GoldenRandom`, and nothing reads a clock — so the script, and therefore the
/// golden, is reproducible on any host.
struct ForkChoiceGoldenGraph {
    struct Block {
        let index: Int
        let name: String
        let hash: String
        let parentName: String?
        let parentHash: String?
        let height: UInt64
        let grind: String
        let commitsChild: Bool
    }

    static let directory = "Child"

    let seed: UInt64
    let blocks: [Block]
    let events: [ForkChoiceGoldenEvent]

    var blocksByName: [String: Block] {
        Dictionary(uniqueKeysWithValues: blocks.map { ($0.name, $0) })
    }

    var nameByHash: [String: String] {
        Dictionary(uniqueKeysWithValues: blocks.map { ($0.hash, $0.name) })
    }

    private static func cid(_ seed: UInt64, _ role: String, _ index: Int) -> String {
        testCID("fork-choice-golden/\(seed)/\(role)/\(index)")
    }

    /// A second LIVE arrival order for the same facts: the seed root first,
    /// then a full seeded shuffle of the block arrivals — so most blocks are
    /// deep orphans grafted later — with each block's other facts (work,
    /// exclusion, validation) following its arrival in their shuffled order,
    /// since a node never applies a fact about a block it does not hold.
    func alternateArrivalOrder(seed: UInt64 = 0xA17E_0DE5) -> [ForkChoiceGoldenEvent] {
        var random = GoldenRandom(seed: seed)
        var shuffled = Array(events.dropFirst())
        random.shuffle(&shuffled)
        var ordered = [events[0]]
        var arrived: Set<String> = [events[0].subject]
        var waiting: [String: [ForkChoiceGoldenEvent]] = [:]
        for event in shuffled {
            if event.kind == .block {
                ordered.append(event)
                arrived.insert(event.subject)
                ordered += waiting.removeValue(forKey: event.subject) ?? []
            } else if arrived.contains(event.subject) {
                ordered.append(event)
            } else {
                waiting[event.subject, default: []].append(event)
            }
        }
        precondition(waiting.isEmpty && ordered.count == events.count)
        return ordered
    }

    static func generate(seed: UInt64 = 0x600D_F0C5, blockCount: Int = 300) -> ForkChoiceGoldenGraph {
        precondition(blockCount >= 16)
        var random = GoldenRandom(seed: seed)

        // 1. The graph: two roots, then every block picks a parent.
        var blocks: [Block] = []
        func append(index: Int, parent: Block?) {
            blocks.append(Block(
                index: index,
                name: "b\(index)",
                hash: cid(seed, "block", index),
                parentName: parent?.name,
                parentHash: parent?.hash,
                height: parent.map { $0.height + 1 } ?? 0,
                grind: cid(seed, "grind", index),
                // Every ninth block commits into the served directory.
                commitsChild: index >= 2 && index % 9 == 0
            ))
        }
        append(index: 0, parent: nil)
        append(index: 1, parent: nil)
        var primarySubtree = [0]
        var secondarySubtree = [1]
        for index in 2..<blockCount {
            let parentIndex: Int
            if random.chance(6) {
                // The rival root's subtree stays small but keeps growing.
                parentIndex = secondarySubtree[random.nextInt(secondarySubtree.count)]
                secondarySubtree.append(index)
            } else {
                let roll = random.nextInt(100)
                if roll < 15 {
                    // A deep fork anywhere in history.
                    parentIndex = primarySubtree[random.nextInt(primarySubtree.count)]
                } else if roll < 25 {
                    // Continue whatever was just built, so side branches grow.
                    parentIndex = primarySubtree[primarySubtree.count - 1]
                } else {
                    // Extend one of the highest blocks: competing tips at the top.
                    let highest = primarySubtree
                        .sorted { blocks[$0].height != blocks[$1].height
                            ? blocks[$0].height > blocks[$1].height : $0 < $1 }
                    parentIndex = highest[random.nextInt(min(5, highest.count))]
                }
                primarySubtree.append(index)
            }
            append(index: index, parent: blocks[parentIndex])
        }

        // 2. Arrival order: mostly ascending, with local swaps so some blocks
        // arrive before their (recent) parents. The seed root arrives first.
        var order = Array(1..<blockCount)
        var position = 0
        while position + 3 < order.count {
            if random.chance(50) { order.swapAt(position, position + 2) }
            if random.chance(30) { order.swapAt(position + 1, position + 3) }
            position += 4
        }

        // 3. The scripted facts, interleaved with the arrivals.
        let byIndex = Dictionary(uniqueKeysWithValues: blocks.map { ($0.name, $0.index) })
        var events: [ForkChoiceGoldenEvent] = []
        var arrived: [Int] = []
        var excluded = Set<Int>()
        var decisiveExclusions = 0
        var validated = Set<Int>()
        // The spec oracle follows the script so exclusion targets can be
        // chosen against the CURRENT canonical selection, not a guess at it.
        var oracle = ForkChoiceOracle()
        let indexByHash = Dictionary(uniqueKeysWithValues: blocks.map { ($0.hash, $0.index) })
        var strength: [Int: UInt64] = [:]
        var extraCounter = 0
        func blockBatch(_ block: Block) -> ChainAdmissionBatch {
            let work = UInt64(1 + random.nextInt(5))
            strength[block.index] = work
            return ChainAdmissionBatch(facts: [
                .block(ChainBlockFact(
                    blockHash: block.hash,
                    parentBlockHash: block.parentHash,
                    blockHeight: block.height,
                    postStateCID: cid(seed, "post", block.index),
                    prevStateCID: cid(seed, "prev", block.index),
                    specCID: cid(seed, "spec", 0),
                    target: UInt256(UInt64(1_000 + block.index)).toHexString(),
                    nextTarget: UInt256(UInt64(1_000 + block.index)).toHexString(),
                    timestamp: Int64(block.index) * 1_000,
                    stateDiff: .empty,
                    childCommitments: block.commitsChild
                        ? [directory: cid(seed, "child-block", block.index)]
                        : [:]
                )),
                .work(ChainWorkFact(
                    blockHash: block.hash,
                    contribution: VerifiedWorkContribution(id: block.grind, work: UInt256(work))
                )),
            ])
        }
        func add(_ kind: ForkChoiceGoldenEvent.Kind, _ block: Block, _ batch: ChainAdmissionBatch) {
            events.append(ForkChoiceGoldenEvent(
                index: events.count, kind: kind, subject: block.name, batch: batch
            ))
            oracle.apply(batch)
        }
        func arrive(_ index: Int) {
            let block = blocks[index]
            add(.block, block, blockBatch(block))
            arrived.append(index)
            if block.parentHash == nil {
                // Both roots are executed explicitly so the executed frontier
                // does not depend on which root seeded the restore.
                validated.insert(index)
                add(.validation, block, ChainAdmissionBatch.validation(blockHash: block.hash))
            }
        }
        arrive(0)
        for index in order {
            arrive(index)
            while random.chance(30) {
                let target = blocks[arrived[random.nextInt(arrived.count)]]
                let roll = random.nextInt(100)
                if roll < 30 {
                    extraCounter += 1
                    add(.secondGrind, target, ChainAdmissionBatch(facts: [
                        .work(ChainWorkFact(
                            blockHash: target.hash,
                            contribution: VerifiedWorkContribution(
                                id: cid(seed, "second-grind", extraCounter),
                                work: UInt256(UInt64(1 + random.nextInt(6)))
                            )
                        )),
                    ]))
                } else if roll < 40 {
                    // A run this chain's own parent attributed at `target`:
                    // credited like a grind, but no grind of the block (§9.10).
                    extraCounter += 1
                    let identity = AttributedRunIdentity(
                        committerBlockHash: cid(seed, "committer", extraCounter),
                        directory: directory
                    )
                    add(.attributedRun, target, ChainAdmissionBatch(facts: [
                        .work(ChainWorkFact(
                            blockHash: target.hash,
                            contribution: VerifiedWorkContribution(
                                id: identity.contributionID!,
                                work: UInt256(UInt64(2 + random.nextInt(8)))
                            ),
                            attributedRun: identity
                        )),
                    ]))
                } else if roll < 65 {
                    let stronger = strength[target.index, default: 1] + UInt64(1 + random.nextInt(3))
                    strength[target.index] = stronger
                    add(.strengthen, target, ChainAdmissionBatch(facts: [
                        .work(ChainWorkFact(
                            blockHash: target.hash,
                            contribution: VerifiedWorkContribution(
                                id: target.grind, work: UInt256(stronger)
                            )
                        )),
                    ]))
                } else if roll < 75 {
                    // Mostly exclude a recent LOSING block — one off the current
                    // canonical selection — so the verdicts prune side branches
                    // rather than decapitate the tree (the generator keeps
                    // extending the highest blocks, exclusion or not, exactly as
                    // miners that have not executed a block keep extending it).
                    // Twice, past the halfway and the nine-tenths marks, a block
                    // ON the canonical selection is excluded: a DECISIVE
                    // exclusion, which must move the tip, so the golden pins a
                    // canonical retreat onto the heaviest selectable branch.
                    let canonical = Set(
                        (oracle.view().canonicalProjection()?.path ?? []).compactMap { indexByHash[$0] }
                    )
                    let window = arrived.suffix(20)
                    let decisive = (decisiveExclusions == 0 && arrived.count > blockCount / 2)
                        || (decisiveExclusions == 1 && arrived.count > blockCount * 9 / 10)
                    let candidates = window.filter {
                        blocks[$0].parentHash != nil && !excluded.contains($0)
                            && (decisive ? canonical.contains($0) : !canonical.contains($0))
                    }
                    guard !candidates.isEmpty else { continue }
                    let chosen = blocks[candidates[random.nextInt(candidates.count)]]
                    if decisive { decisiveExclusions += 1 }
                    excluded.insert(chosen.index)
                    add(.exclusion, chosen, ChainAdmissionBatch(facts: [
                        .exclusion(ChainExclusionFact(blockHash: chosen.hash)),
                    ]))
                } else {
                    // Mostly extend the executed frontier (a block whose parent
                    // is executed); sometimes validate out of order, which the
                    // frontier must absorb when the parent's turn comes.
                    let frontier = arrived.filter { candidate in
                        !validated.contains(candidate)
                            && blocks[candidate].parentName.map { name in
                                validated.contains(byIndex[name]!) && !excluded.contains(byIndex[name]!)
                            } == true
                    }
                    let chosen = !frontier.isEmpty && random.chance(80)
                        ? blocks[frontier[random.nextInt(frontier.count)]]
                        : target
                    validated.insert(chosen.index)
                    add(.validation, chosen, ChainAdmissionBatch.validation(blockHash: chosen.hash))
                }
            }
        }
        return ForkChoiceGoldenGraph(seed: seed, blocks: blocks, events: events)
    }
}

// MARK: - The observable

/// What the golden pins, per block and globally. Hashes appear once, in the
/// block table; everything else refers to blocks by fixture name.
struct ForkChoiceGolden: Codable, Equatable {
    struct BlockRecord: Codable, Equatable {
        let name: String
        let hash: String
        let parent: String?
        let height: UInt64
        /// On the canonical projection.
        let canonical: Bool
        /// On the executed-from-genesis frontier (`hasExecutedAncestry`).
        let executed: Bool
        /// Credited work located at this block, grinds and attributed runs.
        let work: String
        /// `trueCumWork`: the grind-deduplicated subtree total (§9.2).
        let subtreeWork: String
        /// Prefix total from the root through this block.
        let cumulativeWork: String
        /// Difficulty anchor inherited along the parent pointer (height 1).
        let anchorTimestamp: Int64?
    }

    struct RunReportRecord: Codable, Equatable {
        let committer: String
        let childBlock: String
        let grinds: [String]
        let runWork: String
        let ownWork: String
    }

    let seed: UInt64
    let eventCount: Int
    let tip: String
    let tipHeight: UInt64
    /// Canonical blocks by height, from the selected root to the tip.
    let canonicalChain: [String]
    let excludedRoots: [String]
    let blocks: [BlockRecord]
    /// Every §9.10 run report this chain serves for the fixture directory.
    let runReports: [RunReportRecord]

    static func capture(
        _ chain: ChainState,
        graph: ForkChoiceGoldenGraph
    ) async throws -> ForkChoiceGolden {
        let names = graph.nameByHash
        func name(_ hash: String) -> String { names[hash] ?? hash }

        var records: [BlockRecord] = []
        for block in graph.blocks {
            let metaValue = await chain.getConsensusBlock(hash: block.hash)
            let meta = try XCTUnwrap(metaValue, "\(block.name) missing")
            let subtreeValue = await chain.subtreeWeight(forHash: block.hash)
            let subtree = try XCTUnwrap(subtreeValue)
            let cumulativeValue = await chain.getCumulativeWork(forHash: block.hash)
            let cumulative = try XCTUnwrap(cumulativeValue)
            let canonical = await chain.isOnMainChain(hash: block.hash)
            let executed = await chain.hasExecutedAncestry(blockHash: block.hash)
            let anchor = await chain.difficultyAnchor(forBlockHash: block.hash)
            records.append(BlockRecord(
                name: block.name,
                hash: block.hash,
                parent: block.parentName,
                height: block.height,
                canonical: canonical,
                executed: executed,
                work: meta.work.toHexString(),
                subtreeWork: subtree.toHexString(),
                cumulativeWork: cumulative.toHexString(),
                anchorTimestamp: anchor?.timestamp
            ))
        }

        let tipHeight = await chain.getHighestBlockHeight()
        var canonical: [String] = []
        for height in 0...tipHeight {
            let hash = await chain.getMainChainBlockHash(atIndex: height)
            canonical.append(try XCTUnwrap(
                hash.map(name), "canonical index has a hole at \(height)"
            ))
        }

        var reports: [RunReportRecord] = []
        for block in graph.blocks where block.commitsChild {
            let reportValue = await chain.parentRunReport(
                at: block.hash, directory: ForkChoiceGoldenGraph.directory
            )
            let report = try XCTUnwrap(
                reportValue,
                "\(block.name) commits into \(ForkChoiceGoldenGraph.directory) but serves no report"
            )
            reports.append(RunReportRecord(
                committer: block.name,
                childBlock: report.childBlock,
                grinds: report.grinds.sorted(),
                runWork: report.runWork.toHexString(),
                ownWork: report.ownWork.toHexString()
            ))
        }

        let tip = await chain.getMainChainTip()
        let excluded = await chain.excludedRootsForTesting
        return ForkChoiceGolden(
            seed: graph.seed,
            eventCount: graph.events.count,
            tip: name(tip),
            tipHeight: tipHeight,
            canonicalChain: canonical,
            excludedRoots: excluded.map(name).sorted(),
            blocks: records,
            runReports: reports
        )
    }

    static func diff(expected: ForkChoiceGolden, actual: ForkChoiceGolden) -> [String] {
        var lines = GoldenFile.fieldDiff("global", [
            ("seed", "\(expected.seed)", "\(actual.seed)"),
            ("eventCount", "\(expected.eventCount)", "\(actual.eventCount)"),
            ("tip", expected.tip, actual.tip),
            ("tipHeight", "\(expected.tipHeight)", "\(actual.tipHeight)"),
            ("canonicalChain", "\(expected.canonicalChain)", "\(actual.canonicalChain)"),
            ("excludedRoots", "\(expected.excludedRoots)", "\(actual.excludedRoots)"),
        ])
        let actualBlocks = Dictionary(uniqueKeysWithValues: actual.blocks.map { ($0.name, $0) })
        for block in expected.blocks {
            guard let other = actualBlocks[block.name] else {
                lines.append("\(block.name): missing from actual")
                continue
            }
            lines += GoldenFile.fieldDiff(block.name, [
                ("hash", block.hash, other.hash),
                ("parent", block.parent ?? "nil", other.parent ?? "nil"),
                ("height", "\(block.height)", "\(other.height)"),
                ("canonical", "\(block.canonical)", "\(other.canonical)"),
                ("executed", "\(block.executed)", "\(other.executed)"),
                ("work", block.work, other.work),
                ("subtreeWork", block.subtreeWork, other.subtreeWork),
                ("cumulativeWork", block.cumulativeWork, other.cumulativeWork),
                ("anchorTimestamp", "\(block.anchorTimestamp.map(String.init) ?? "nil")",
                 "\(other.anchorTimestamp.map(String.init) ?? "nil")"),
            ])
        }
        for name in Set(actualBlocks.keys).subtracting(expected.blocks.map(\.name)).sorted() {
            lines.append("\(name): unexpected in actual")
        }
        let actualReports = Dictionary(uniqueKeysWithValues: actual.runReports.map { ($0.committer, $0) })
        for report in expected.runReports {
            guard let other = actualReports[report.committer] else {
                lines.append("run \(report.committer): missing from actual")
                continue
            }
            lines += GoldenFile.fieldDiff("run \(report.committer)", [
                ("childBlock", report.childBlock, other.childBlock),
                ("grinds", "\(report.grinds)", "\(other.grinds)"),
                ("runWork", report.runWork, other.runWork),
                ("ownWork", report.ownWork, other.ownWork),
            ])
        }
        for name in Set(actualReports.keys).subtracting(expected.runReports.map(\.committer)).sorted() {
            lines.append("run \(name): unexpected in actual")
        }
        return lines
    }
}

/// What only a LIVE order can show: the tip after each checkpoint and after
/// each exclusion, how many commits removed canonical blocks (reorgs), and
/// how many exclusions moved the tip (decisive, §9.9). Order-specific, so it
/// is pinned per arrival order in its own file; the final state is in
/// `fork-choice-replay.json`.
struct ForkChoiceTraceGolden: Codable, Equatable {
    struct Checkpoint: Codable, Equatable {
        let event: Int
        let kind: String
        let subject: String
        let tip: String
        let tipHeight: UInt64
        /// Canonical blocks the event's commit removed.
        let removed: [String]
    }

    struct OrderTrace: Codable, Equatable {
        let reorgCommits: Int
        let decisiveExclusions: Int
        let checkpoints: [Checkpoint]
    }

    let arrival: OrderTrace
    let alternate: OrderTrace

    static func diff(expected: ForkChoiceTraceGolden, actual: ForkChoiceTraceGolden) -> [String] {
        var lines: [String] = []
        for (order, expectedTrace, actualTrace) in [
            ("arrival", expected.arrival, actual.arrival),
            ("alternate", expected.alternate, actual.alternate),
        ] {
            lines += GoldenFile.fieldDiff(order, [
                ("reorgCommits", "\(expectedTrace.reorgCommits)", "\(actualTrace.reorgCommits)"),
                ("decisiveExclusions", "\(expectedTrace.decisiveExclusions)", "\(actualTrace.decisiveExclusions)"),
                ("checkpointCount", "\(expectedTrace.checkpoints.count)", "\(actualTrace.checkpoints.count)"),
            ])
            let actualByEvent = Dictionary(uniqueKeysWithValues: actualTrace.checkpoints.map { ($0.event, $0) })
            for checkpoint in expectedTrace.checkpoints {
                guard let other = actualByEvent[checkpoint.event] else {
                    lines.append("\(order) event \(checkpoint.event): missing from actual")
                    continue
                }
                lines += GoldenFile.fieldDiff("\(order) event \(checkpoint.event)", [
                    ("kind", checkpoint.kind, other.kind),
                    ("subject", checkpoint.subject, other.subject),
                    ("tip", checkpoint.tip, other.tip),
                    ("tipHeight", "\(checkpoint.tipHeight)", "\(other.tipHeight)"),
                    ("removed", "\(checkpoint.removed)", "\(other.removed)"),
                ])
            }
        }
        return lines
    }
}

// MARK: - Tests

/// Pins the consensus outcome of one scripted graph as data: subtree work,
/// canonical membership and executed status per block; tip, canonical chain,
/// excluded roots and served run reports globally. Both the live incremental
/// path and restore-replay in a shuffled order must reproduce the file.
@MainActor
final class ForkChoiceReplayGoldenTests: XCTestCase {
    static let goldenName = "fork-choice-replay.json"
    static let traceGoldenName = "fork-choice-replay-trace.json"

    private let graph = ForkChoiceGoldenGraph.generate()

    /// Live admission through `replay` in the given order, run attribution
    /// served from the start so the per-block live path settles it. Returns
    /// the chain and the order's trace.
    private func admitLive(
        _ order: [ForkChoiceGoldenEvent]
    ) async throws -> (chain: ChainState, trace: ForkChoiceTraceGolden.OrderTrace) {
        let names = graph.nameByHash
        func name(_ hash: String) -> String { names[hash] ?? hash }
        let chain = try await ChainState.restore(replaying: [order[0].batch])
        await chain.serveRuns(for: ForkChoiceGoldenGraph.directory)
        var reorgCommits = 0
        var decisiveExclusions = 0
        var checkpoints: [ForkChoiceTraceGolden.Checkpoint] = []
        for (position, event) in order.enumerated().dropFirst() {
            let commit: ChainCommit?
            do {
                commit = try await chain.replay(event.batch)
            } catch {
                XCTFail("position \(position), event \(event.index) (\(event.kind.rawValue) \(event.subject)) threw \(error)")
                throw error
            }
            let removed = commit?.mainChainBlocksRemoved ?? []
            if !removed.isEmpty { reorgCommits += 1 }
            if event.kind == .exclusion, !removed.isEmpty { decisiveExclusions += 1 }
            if position % 25 == 0 || event.kind == .exclusion {
                let tip = await chain.getMainChainTip()
                let tipHeight = await chain.getHighestBlockHeight()
                checkpoints.append(ForkChoiceTraceGolden.Checkpoint(
                    event: event.index,
                    kind: event.kind.rawValue,
                    subject: event.subject,
                    tip: name(tip),
                    tipHeight: tipHeight,
                    removed: removed.map(name).sorted()
                ))
            }
        }
        let unresolved = await chain.unresolvedSameChainPredecessors()
        XCTAssertTrue(unresolved.isEmpty, "every block must connect once all have arrived")
        return (chain, ForkChoiceTraceGolden.OrderTrace(
            reorgCommits: reorgCommits,
            decisiveExclusions: decisiveExclusions,
            checkpoints: checkpoints
        ))
    }

    /// Live admission in the scripted arrival order.
    func testIncrementalAdmissionInArrivalOrderMatchesGolden() async throws {
        let (chain, _) = try await admitLive(graph.events)
        let golden = try await ForkChoiceGolden.capture(chain, graph: graph)
        try GoldenFile.assert(golden, matches: Self.goldenName, diff: ForkChoiceGolden.diff)
    }

    /// Live admission in a second, fully shuffled arrival order — the live
    /// path (not restore's sorted replay) must reach the same final state.
    func testAlternateArrivalOrderMatchesGolden() async throws {
        let order = graph.alternateArrivalOrder()
        XCTAssertNotEqual(order.map(\.index), graph.events.map(\.index), "the alternate order must differ")
        let (chain, _) = try await admitLive(order)
        let golden = try await ForkChoiceGolden.capture(chain, graph: graph)
        try GoldenFile.assert(golden, matches: Self.goldenName, diff: ForkChoiceGolden.diff)
    }

    /// Recovery: the same durable facts handed to `restore` in a shuffled
    /// order (restore sorts them itself), run attribution served afterwards
    /// over the whole graph.
    func testShuffledRestoreReplayMatchesGolden() async throws {
        var batches = graph.events.map(\.batch)
        var random = GoldenRandom(seed: 0x5EED_5EED)
        random.shuffle(&batches)
        XCTAssertNotEqual(batches, graph.events.map(\.batch), "the shuffle must move something")

        let chain = try await ChainState.restore(replaying: batches)
        await chain.serveRuns(for: ForkChoiceGoldenGraph.directory)

        let golden = try await ForkChoiceGolden.capture(chain, graph: graph)
        try GoldenFile.assert(golden, matches: Self.goldenName, diff: ForkChoiceGolden.diff)
    }

    /// The order-specific observables of both live orders: checkpoint tips,
    /// reorg commits, and decisive exclusions. Reorgs and at least one
    /// decisive exclusion must occur in the scripted order — otherwise the
    /// golden pins a graph in which fork choice never had to choose.
    func testLiveAdmissionTracesMatchGolden() async throws {
        let (_, arrival) = try await admitLive(graph.events)
        let (_, alternate) = try await admitLive(graph.alternateArrivalOrder())
        XCTAssertGreaterThan(arrival.reorgCommits, 0, "the scripted order must reorg")
        XCTAssertGreaterThan(arrival.decisiveExclusions, 0, "some exclusion must move the tip")
        try GoldenFile.assert(
            ForkChoiceTraceGolden(arrival: arrival, alternate: alternate),
            matches: Self.traceGoldenName,
            diff: ForkChoiceTraceGolden.diff
        )
    }

    /// The generator's coverage claims, so a later edit to it cannot quietly
    /// drop one of the shapes the golden exists to pin.
    func testScriptCoversEveryClaimedShape() {
        let byName = graph.blocksByName
        let arrivalPosition = Dictionary(
            uniqueKeysWithValues: graph.events.filter { $0.kind == .block }
                .enumerated().map { ($0.element.subject, $0.offset) }
        )
        XCTAssertGreaterThanOrEqual(graph.blocks.count, 300)
        XCTAssertEqual(graph.blocks.filter { $0.parentHash == nil }.count, 2, "two competing roots")

        var childCounts: [String: Int] = [:]
        for block in graph.blocks {
            if let parent = block.parentName { childCounts[parent, default: 0] += 1 }
        }
        XCTAssertGreaterThan(childCounts.values.filter { $0 >= 2 }.count, 20, "many forks")

        let outOfOrder = graph.blocks.filter { block in
            guard let parent = block.parentName else { return false }
            return arrivalPosition[block.name]! < arrivalPosition[parent]!
        }
        XCTAssertGreaterThan(outOfOrder.count, 10, "children arriving before parents")

        var kinds: [ForkChoiceGoldenEvent.Kind: Int] = [:]
        for event in graph.events { kinds[event.kind, default: 0] += 1 }
        for kind in [ForkChoiceGoldenEvent.Kind.secondGrind, .strengthen, .attributedRun, .exclusion, .validation] {
            XCTAssertGreaterThan(kinds[kind, default: 0], 3, "\(kind.rawValue) events")
        }
        XCTAssertGreaterThan(graph.blocks.filter(\.commitsChild).count, 10, "committers")
        XCTAssertTrue(
            graph.events.contains { $0.kind == .strengthen && byName[$0.subject]?.commitsChild == true },
            "a committer is strengthened, so ownWork moves after settlement"
        )

        // Exclusions are decisive on the final graph too: selection on weight
        // alone lands somewhere the excluded set forbids (§9.9), judged by the
        // spec oracle, independent of the chain.
        var oracle = ForkChoiceOracle()
        for event in graph.events { oracle.apply(event.batch) }
        let selected = oracle.view().canonicalProjection()
        let unselected = oracle.view(ignoringExclusions: true).canonicalProjection()
        XCTAssertNotEqual(selected?.tip, unselected?.tip, "the excluded set must change the final selection")
        let excludedHashes = Set(graph.events.filter { $0.kind == .exclusion }.map { byName[$0.subject]!.hash })
        XCTAssertTrue(
            unselected?.path.contains { excludedHashes.contains($0) } == true,
            "weight alone must select through an excluded block"
        )
    }
}
