import Foundation
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
import WAT

final class ChainLocalAdmissionValidateTierTests: XCTestCase {
    func testValidateTierExecutesLikeEagerAndMaterializesState() async throws {
        // Validated tier (deferred execution): `.execution` executes a block and
        // records the validity verdict. On a valid block it does exactly what
        // eager does — runs the transition, materializes the post-state, emits
        // the block fact carrying the real `stateDiff` — the durable "validated"
        // marker that upgrades a weighed claim. Proven here against the eager
        // control on an identical, independent level.
        let genesisTimestamp: Int64 = 1_000

        let eagerFetcher = StorableFetcher()
        let eagerGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: eagerFetcher, timestamp: genesisTimestamp
        )
        let candidate = try await AdmissionFixture.makeChild(
            of: eagerGenesis, fetcher: eagerFetcher, timestamp: 2_000, nonce: 1
        )
        let genesisHash = try BlockHeader(node: eagerGenesis).rawCID
        let candidateHash = try BlockHeader(node: candidate).rawCID

        let validateFetcher = StorableFetcher()
        let validateGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: validateFetcher, timestamp: genesisTimestamp
        )
        _ = try await AdmissionFixture.makeChild(
            of: validateGenesis, fetcher: validateFetcher, timestamp: 2_000, nonce: 1
        )
        XCTAssertEqual(try BlockHeader(node: validateGenesis).rawCID, genesisHash)

        let eagerLevel = AdmissionFixture.makeLevel(genesis: eagerGenesis)
        let eager = try await eagerLevel.admit(candidate, fetcher: eagerFetcher)

        let validateLevel = AdmissionFixture.makeLevel(genesis: validateGenesis)
        let validated = try await validateLevel.admit(
            candidate,
            mode: .execution,
            fetcher: validateFetcher
        )

        guard case .accepted(let eagerAcceptance) = eager else {
            return XCTFail("eager admission must accept, got \(eager)")
        }
        guard case .accepted(let validatedAcceptance) = validated else {
            return XCTFail("validate admission must accept, got \(validated)")
        }

        let eagerSnapshotValue = await eagerLevel.chain
            .forkChoiceSnapshot(startingAt: genesisHash)
        let validatedSnapshotValue = await validateLevel.chain
            .forkChoiceSnapshot(startingAt: genesisHash)
        let eagerSnapshot = try XCTUnwrap(eagerSnapshotValue)
        let validatedSnapshot = try XCTUnwrap(validatedSnapshotValue)
        XCTAssertEqual(validatedSnapshot, eagerSnapshot)
        XCTAssertEqual(validatedSnapshot.tipHash, candidateHash)

        // Unlike the weighed tier, validation executes: it materializes the
        // post-state exactly as eager does.
        XCTAssertNotNil(validated.materializedPostState)
        XCTAssertNotNil(eager.materializedPostState)

        func blockFact(_ acceptance: ChainAcceptance) -> ChainBlockFact? {
            for case .block(let fact) in acceptance.facts.facts { return fact }
            return nil
        }
        let eagerBlockFact = try XCTUnwrap(blockFact(eagerAcceptance))
        let validatedBlockFact = try XCTUnwrap(blockFact(validatedAcceptance))
        XCTAssertEqual(validatedBlockFact, eagerBlockFact)
    }

    /// The validate tier promotes an already-possessed block and reads the map
    /// RECORDED for it rather than walking the trie again. Pinned with a
    /// recorded map that differs from the trie: a re-enumeration would carry
    /// the trie's map and be rejected by `matchesGraph` as a conflict, so only
    /// the recorded path promotes.
    func testValidateTierPromotesAPossessedBlockFromItsRecordedCommitments() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let candidateHash = try BlockHeader(node: candidate).rawCID
        let level = AdmissionFixture.makeLevel(genesis: genesis)
        // Possess the block through a fact whose recorded map is not what the
        // (empty) trie would enumerate.
        let recordedMap = ["Alpha": testCID("recorded-alpha")]
        let seed = try testAdmissionBatch(for: candidate)
        let facts: [ChainFact] = seed.facts.map { fact in
            guard case .block(let b) = fact else { return fact }
            return .block(ChainBlockFact(
                blockHash: b.blockHash, parentBlockHash: b.parentBlockHash, blockHeight: b.blockHeight,
                postStateCID: b.postStateCID, prevStateCID: b.prevStateCID, specCID: b.specCID,
                target: b.target, nextTarget: b.nextTarget, timestamp: b.timestamp,
                stateDiff: b.stateDiff, childCommitments: recordedMap
            ))
        }
        _ = try await level.chain.replay(BlockImportBatch(facts: facts))
        let recordedBefore = await level.chain.recordedChildCommitments(of: candidateHash)
        XCTAssertEqual(recordedBefore, recordedMap)
        let executedBefore = await level.chain.hasExecutedAncestry(blockHash: candidateHash)
        XCTAssertFalse(executedBefore, "possessed, not yet executed")

        let validated = try await level.admit(candidate, mode: .execution, fetcher: fetcher)
        guard case .duplicate = validated else {
            return XCTFail("validating a possessed block is a promotion, got \(validated)")
        }
        let executedAfter = await level.chain.hasExecutedAncestry(blockHash: candidateHash)
        XCTAssertTrue(executedAfter, "promotion executed the block")
        let recordedAfter = await level.chain.recordedChildCommitments(of: candidateHash)
        XCTAssertEqual(recordedAfter, recordedMap, "the recorded map is what the validate tier carried")
    }

    /// An executed root is never excluded (§9.9: execution is never revoked).
    /// The validate tier's invalid verdict on the executed root is refused at
    /// the PRODUCER as a local fault: nothing is staged, nothing is excluded,
    /// and recovery has no fact whose replay could depend on order.
    func testValidateTierParksARootExclusionWithNoOtherExecutedRoot() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let genesisHash = try BlockHeader(node: genesis).rawCID
        actor StageCounter { var count = 0; func bump() { count += 1 } }
        let stagedCounter = StageCounter()
        let result = try await level.admit(
            genesis,
            mode: .execution,
            fetcher: fetcher,
            stage: { _ in await stagedCounter.bump() }
        )
        let staged = await stagedCounter.count
        guard case .rejected(let failure, _) = result else {
            return XCTFail("a root exclusion with nothing to stand on must be parked, got \(result)")
        }
        XCTAssertEqual(failure, .executedVerdictContradiction, "a local fault — never a written fact")
        XCTAssertEqual(staged, 0, "nothing is made durable")
        let roots = await level.chain.excludedRootsForTesting
        XCTAssertTrue(roots.isEmpty)
        let tip = await level.chain.canonicalTip
        XCTAssertEqual(tip, genesisHash, "the only root stays selectable")
    }
}
