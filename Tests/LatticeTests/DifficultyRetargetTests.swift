import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256
import cashew

/// The anchor a height-1 block provides for itself: the schedule starts at the
/// first real block, so a block built directly on genesis IS its own origin.
func selfDifficultyAnchor(_ block: Block) -> DifficultyAnchor {
    DifficultyAnchor(
        blockHeight: 1,
        timestamp: block.timestamp, target: block.target
    )
}

/// The scheduled `nextTarget` at the edges validation checks: block 1 is its
/// own anchor, so its schedule starts at its own target, and a `nextTarget`
/// on either side of the schedule is a forgery.
@MainActor
final class DifficultyRetargetTests: XCTestCase {
    private func spec(halfLife: UInt64 = 120, target: UInt64 = 3_600_000) -> ChainSpec {
        ChainSpec.test(
            targetBlockTime: target,
            halfLife: halfLife
        )
    }

    private func makeGenesis(spec: ChainSpec, timestamp: Int64, target: UInt256, fetcher: StorableFetcher) async throws -> Block {
        try await buildAndStoreGenesis(
            spec: spec,
            timestamp: timestamp,
            target: target,
            fetcher: fetcher
        )
    }

    private func makeNext(previous: Block, timestamp: Int64, target: UInt256, nextTarget: UInt256, fetcher: StorableFetcher) async throws -> Block {
        try await buildAndStoreBlock(
            previous: previous,
            timestamp: timestamp,
            target: target,
            nextTarget: nextTarget,
            fetcher: fetcher
        )
    }

    private func storeBlock(_ block: Block, to fetcher: StorableFetcher) async throws {
        try await VolumeImpl<Block>(node: block).storeBlock(storer: fetcher)
    }

    func testValidateNextDifficultyRejectsScheduleNearMisses() async throws {
        let s = spec(target: 1_000)
        let fetcher = StorableFetcher()
        let parent = try await makeGenesis(spec: s, timestamp: 1_000, target: UInt256(10_000), fetcher: fetcher)
        let blockTimestamp: Int64 = 2_000
        // Block 1 anchors itself: its schedule starts at its own target.
        let expected = parent.nextTarget

        let valid = try await makeNext(
            previous: parent,
            timestamp: blockTimestamp,
            target: parent.nextTarget,
            nextTarget: expected,
            fetcher: fetcher
        )
        XCTAssertTrue(valid.validateNextTarget(spec: s, parent: parent, difficultyAnchor: selfDifficultyAnchor(valid)))

        let tooEasy = try await makeNext(
            previous: parent,
            timestamp: blockTimestamp,
            target: parent.nextTarget,
            nextTarget: expected * UInt256(2),
            fetcher: fetcher
        )
        XCTAssertFalse(tooEasy.validateNextTarget(spec: s, parent: parent, difficultyAnchor: selfDifficultyAnchor(tooEasy)))

        let tooHard = try await makeNext(
            previous: parent,
            timestamp: blockTimestamp,
            target: parent.nextTarget,
            nextTarget: expected / UInt256(2),
            fetcher: fetcher
        )
        XCTAssertFalse(tooHard.validateNextTarget(spec: s, parent: parent, difficultyAnchor: selfDifficultyAnchor(tooHard)))
    }

    func testEasierThanScheduledTargetRejected() async throws {
        let s = spec(target: 1_000)
        let fetcher = StorableFetcher()
        let parent = try await makeGenesis(spec: s, timestamp: 1_000, target: UInt256(10_000), fetcher: fetcher)
        // A larger target is easier than the scheduled parent.nextTarget → rejected.
        let easier = parent.nextTarget + UInt256(1)
        let block = try await makeNext(
            previous: parent,
            timestamp: 2_000,
            target: easier,
            nextTarget: easier,
            fetcher: fetcher
        )

        XCTAssertFalse(block.validateNextTarget(spec: s, parent: parent, difficultyAnchor: selfDifficultyAnchor(block)))
    }

    func testHarderThanScheduledTargetAccepted() async throws {
        let s = spec(target: 1_000)
        let fetcher = StorableFetcher()
        let parent = try await makeGenesis(spec: s, timestamp: 1_000, target: UInt256(10_000), fetcher: fetcher)
        // A smaller target is HARDER than the scheduled parent.nextTarget → allowed;
        // the schedule then starts from the actual (harder) target.
        let harder = parent.nextTarget / UInt256(2)
        let block = try await makeNext(
            previous: parent,
            timestamp: 2_000,
            target: harder,
            nextTarget: harder,
            fetcher: fetcher
        )

        XCTAssertTrue(block.validateNextTarget(spec: s, parent: parent, difficultyAnchor: selfDifficultyAnchor(block)))
    }

    func testMissingAncestorIsUnavailableInsteadOfAFallback() async throws {
        let s = spec(target: 1_000)
        let fullFetcher = StorableFetcher()
        let genesis = try await makeGenesis(spec: s, timestamp: 1_000, target: UInt256(10_000), fetcher: fullFetcher)
        let block1 = try await makeNext(
            previous: genesis,
            timestamp: 2_000,
            target: genesis.nextTarget,
            nextTarget: UInt256(10_000),
            fetcher: fullFetcher
        )
        let scheduled = s.calculateAsertTarget(
            anchorTarget: block1.target,
            anchorTimestamp: block1.timestamp,
            anchorHeight: 1,
            blockTimestamp: 3_000,
            blockHeight: 2
        )
        let block2 = try await makeNext(
            previous: block1,
            timestamp: 3_000,
            target: block1.nextTarget,
            nextTarget: scheduled,
            fetcher: fullFetcher
        )

        let partialFetcher = StorableFetcher()
        let block1CID = try! VolumeImpl<Block>(node: block1).rawCID
        guard let block1Data = block1.toData() else {
            return XCTFail("block1 serialization failed")
        }
        partialFetcher.store(rawCid: block1CID, data: block1Data)

        do {
            _ = try await block2.validateNexus(fetcher: partialFetcher)
            XCTFail("missing ancestors must be unavailable instead of using a fallback schedule")
        } catch is FetcherError {
            // Admission maps this to retriable unavailable evidence.
        }
    }

    func testGeneratedChainPassesValidateNexus() async throws {
        let s = spec(target: 1_000)
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(spec: s, timestamp: 1_000, target: UInt256.max, fetcher: fetcher)
        try await storeBlock(genesis, to: fetcher)

        var blocks = [genesis]
        for offset in 1...5 {
            let block = try await buildAndStoreBlock(
                previous: blocks.last!,
                timestamp: 1_000 + Int64(offset * 1_000),
                fetcher: fetcher
            )
            try await storeBlock(block, to: fetcher)
            let valid = try await block.validateNexus(fetcher: fetcher).0
            XCTAssertTrue(valid, "honest generated block \(offset) must validate")
            blocks.append(block)
        }

        XCTAssertEqual(blocks.count, 6)
    }

    func testForgedNextDifficultyRejectedByValidateNexus() async throws {
        let s = spec(target: 1_000)
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(spec: s, timestamp: 1_000, target: UInt256.max, fetcher: fetcher)
        try await storeBlock(genesis, to: fetcher)

        // Block 1 anchors itself, so its scheduled nextTarget is its own target.
        let forged = try await makeNext(
            previous: genesis,
            timestamp: 2_000,
            target: genesis.nextTarget,
            nextTarget: genesis.nextTarget - UInt256(1),
            fetcher: fetcher
        )
        try await storeBlock(forged, to: fetcher)
        let directValid = try await forged.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(directValid)
    }
}
