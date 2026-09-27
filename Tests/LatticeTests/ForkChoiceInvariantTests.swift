import XCTest
@testable import Lattice

/// Evidence that the reference fallback family in `ChainState` is unreachable.
///
/// `blockGhostDescent` returns nil in exactly two cases: a block visited twice
/// (a cycle in `childHashes`) or a fork at which no non-excluded child is
/// routed. Neither can happen from a routed start point if the routed set is
/// closed under child edges and every child edge is parent-consistent and one
/// height down — a routed block's children are then routed, and no routed
/// block can be its own descendant. This asserts exactly that, after every
/// event of the golden orders and (through the differential helpers) after
/// every step of the differential seeds, and pins `descentFallbackCount` — a
/// temporary counter on every entry into the fallback family — at zero.

/// Every routed block's children are all routed, parent-consistent and one
/// height above it, and its parent, when it has one, is routed.
func assertRoutedClosedUnderChildren(
    _ chain: ChainState,
    _ event: String,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let blocks = await chain.hashToBlock
    var routed = Set<String>()
    for hash in blocks.keys {
        if await chain.hasConnectedAncestry(blockHash: hash) { routed.insert(hash) }
    }
    // A restored chain always routes its genesis, so an empty set here would
    // make everything below vacuous.
    XCTAssertFalse(routed.isEmpty, "\(event): nothing is routed", file: file, line: line)
    for hash in routed {
        guard let meta = blocks[hash] else {
            XCTFail("\(event): routed \(hash) is not held", file: file, line: line)
            continue
        }
        for child in meta.childHashes {
            XCTAssertTrue(
                routed.contains(child),
                "\(event): routed \(hash) has an unrouted child \(child)", file: file, line: line
            )
            XCTAssertEqual(
                blocks[child]?.parentBlockHash, hash,
                "\(event): child edge \(hash) -> \(child) is not parent-consistent", file: file, line: line
            )
            XCTAssertEqual(
                blocks[child]?.blockHeight, meta.blockHeight + 1,
                "\(event): child edge \(hash) -> \(child) does not step one height", file: file, line: line
            )
        }
        if let parent = meta.parentBlockHash {
            XCTAssertTrue(
                routed.contains(parent),
                "\(event): routed \(hash) has an unrouted parent \(parent)", file: file, line: line
            )
        } else {
            XCTAssertEqual(meta.blockHeight, 0, "\(event): a parentless routed block above height 0", file: file, line: line)
        }
    }
}

@MainActor
final class ForkChoiceInvariantTests: XCTestCase {
    private let graph = ForkChoiceGoldenGraph.generate()

    /// `chainWithMostWork` from every routed block — the descent every
    /// `forkChoiceSnapshot` takes, excluded starts included — then the counter.
    private func assertNoFallback(_ chain: ChainState, _ label: String) async {
        let blocks = await chain.hashToBlock
        for hash in blocks.keys.sorted() where await chain.hasConnectedAncestry(blockHash: hash) {
            let snapshot = await chain.forkChoiceSnapshot(startingAt: hash)
            XCTAssertNotNil(snapshot, "\(label): no snapshot from routed \(hash)")
        }
        let fallbacks = await chain.descentFallbackCount
        XCTAssertEqual(fallbacks, 0, "\(label): the reference fallback was entered")
    }

    private func admitCheckingInvariants(_ order: [ForkChoiceGoldenEvent], _ label: String) async throws {
        let chain = try await ChainState.restore(replaying: [order[0].batch])
        await chain.serveRuns(for: ForkChoiceGoldenGraph.directory)
        await assertRoutedClosedUnderChildren(chain, "\(label): genesis")
        for event in order.dropFirst() {
            _ = try await chain.replay(event.batch)
            await assertRoutedClosedUnderChildren(chain, "\(label): event \(event.index)")
        }
        await assertNoFallback(chain, label)
    }

    func testGoldenArrivalOrderKeepsTheRoutedSetClosedAndNeverFallsBack() async throws {
        try await admitCheckingInvariants(graph.events, "arrival")
    }

    func testGoldenAlternateOrderKeepsTheRoutedSetClosedAndNeverFallsBack() async throws {
        try await admitCheckingInvariants(graph.alternateArrivalOrder(), "alternate")
    }

    func testGoldenShuffledRestoreKeepsTheRoutedSetClosedAndNeverFallsBack() async throws {
        var batches = graph.events.map(\.batch)
        var random = GoldenRandom(seed: 0x5EED_5EED)
        random.shuffle(&batches)
        let chain = try await ChainState.restore(replaying: batches)
        await chain.serveRuns(for: ForkChoiceGoldenGraph.directory)
        await assertRoutedClosedUnderChildren(chain, "shuffled restore")
        await assertNoFallback(chain, "shuffled restore")
    }

    /// The differential fixtures in the order the oracle tests deliver them:
    /// descendants before ancestors, strengthenings, then exclusions.
    func testDifferentialSeedsKeepTheRoutedSetClosedAndNeverFallBack() async throws {
        for seed: UInt64 in [
            0xC0FFEE, 0xD1FF_EA5E, 0xFACE_FEED, 0xBADC_0DE,
            0x1234_5678, 0x8765_4321, 0x0DDC_0FFE, 0x51DE_CAFE,
        ] {
            let planned = SegmentBaseDifferentialFixtures.planned(seed: seed)
            let chain = try await ChainState.restore(replaying: [planned[0].batch])
            let order = [4, 3, 1, 2, 5] + Array(6..<planned.count)
            for index in order {
                _ = try await chain.replay(planned[index].batch)
                await assertRoutedClosedUnderChildren(chain, "seed \(seed) block \(index)")
            }
            let shared = testCID("invariant-differential-\(seed)-shared")
            for strength in [3, 7, 11] {
                _ = try await chain.replay(SegmentBaseDifferentialFixtures.work(
                    blockHash: planned[4].hash, id: shared, work: UInt64(strength)
                ))
                await assertRoutedClosedUnderChildren(chain, "seed \(seed) strengthening \(strength)")
            }
            for index in stride(from: 2, to: planned.count, by: 3) where planned[index].parentHash != nil {
                _ = try await chain.replay(SegmentBaseDifferentialFixtures.exclusion(of: planned[index].hash))
                await assertRoutedClosedUnderChildren(chain, "seed \(seed) exclusion \(index)")
            }
            await assertNoFallback(chain, "seed \(seed)")
        }
    }
}
