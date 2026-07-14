import XCTest
@testable import Lattice
import UInt256
import cashew
import Foundation

/// Regression guard for the sum→max, per-grind inherited-work fix.
///
/// A single grind (one PoW hash) graded against multiple levels is ONE unit of work:
/// clearing the hardest target it meets clears every easier level for free. Its
/// securing contribution must be the MAX cleared difficulty, counted ONCE (keyed by the
/// grind's identity, `rootCID`), never the per-level SUM. Genuinely independent grinds
/// (distinct roots) keep distinct ids and still SUM downstream.
final class SecuringWorkPerGrindTests: XCTestCase {

    private let childDir = "ChildA"

    /// Block committing `child` at directory `dir` (or empty children when nil).
    private func blockCommitting(
        _ child: VolumeImpl<Block>?, at dir: String, target: UInt256, nonce: UInt64
    ) -> Block {
        let children: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Block>>>
        if let child {
            children = try! HeaderImpl(node: try! MerkleDictionaryImpl<VolumeImpl<Block>>()
                .inserting(key: dir, value: child))
        } else {
            children = emptyChildBlocks()
        }
        return Block(
            parent: nil, transactions: emptyTransactions(),
            target: target, nextTarget: target,
            spec: try! VolumeImpl<ChainSpec>(node: testChainSpec()),
            parentState: emptyLatticeState().removingNode(), prevState: emptyLatticeState().removingNode(),
            postState: emptyLatticeState(), children: children,
            height: 0, timestamp: 1_000_000, nonce: nonce
        )
    }

    /// Root committing `child` at `childDir`.
    private func rootCommitting(
        _ child: VolumeImpl<Block>?, target: UInt256, nonce: UInt64
    ) -> Block {
        blockCommitting(child, at: childDir, target: target, nonce: nonce)
    }

    /// Find a nonce whose hash clears `clearing` (≤) and, if given, does NOT clear
    /// `notClearing` (>). The preimage prefix is nonce-independent, so we vary only the nonce.
    private func mine(
        clearing: UInt256, notClearing: UInt256? = nil, build: (UInt64) -> Block
    ) -> UInt64? {
        let template = build(0)
        var nonce: UInt64 = 0
        while nonce < 2_000_000 {
            let h = UInt256.hash(Block.makeProofOfWorkPreimage(block: template, nonce: nonce))
            if h <= clearing, notClearing.map({ h > $0 }) ?? true { return nonce }
            nonce += 1
        }
        return nil
    }

    private func entries(_ headers: VolumeImpl<Block>...) async throws -> [(cid: String, data: Data)] {
        let storer = _CollectingStorer()
        for h in headers { try await h.storeBlockContent(storer: storer) }
        return dedupedEntries(storer.entries)
    }

    // MARK: - One grind, two levels → MAX once, not the per-level sum

    func test_singleGrind_clearingTwoLevels_countsMaxOnce_notSum() async throws {
        let hard = UInt256.max / UInt256(16)   // root level → workForTarget = 16
        let easy = UInt256.max / UInt256(2)    // intermediate level → workForTarget = 2

        let x = makeGenesisBlock(target: easy)
        let xHeader = try VolumeImpl<Block>(node: x)
        let nonce = try XCTUnwrap(mine(clearing: hard) { rootCommitting(xHeader, target: hard, nonce: $0) },
                                  "mining did not converge")
        let root = rootCommitting(xHeader, target: hard, nonce: nonce)
        let rootHeader = try VolumeImpl<Block>(node: root)
        let powHash = root.proofOfWorkHash()
        XCTAssertTrue(root.validateProofOfWork(nexusHash: powHash), "root must clear its own hard target")
        XCTAssertTrue(x.validateProofOfWork(nexusHash: powHash), "same hash must clear the easier level free")

        let proof = ChildBlockProof(rootCID: rootHeader.rawCID,
                                    directoryPath: [childDir, "leaf"],
                                    entries: try await entries(rootHeader, xHeader))
        let contributions = await proof.securingWorkContributions()
        let work = await proof.securingWork()

        XCTAssertEqual(contributions.count, 1, "one grind → ONE contribution, not one per level")
        XCTAssertEqual(contributions.first?.id, rootHeader.rawCID, "keyed by the grind identity (rootCID)")
        XCTAssertEqual(work, workForTarget(hard), "credits the MAX cleared difficulty, once")
        XCTAssertNotEqual(work, saturatingWorkSum(workForTarget(hard), workForTarget(easy)),
                          "must NOT sum per-level (the old double-count)")
    }

    // MARK: - Depth 1 is unchanged (the live-network safety property)

    func test_depth1_directChild_singleRootContribution() async throws {
        let hard = UInt256.max / UInt256(16)
        let c = makeGenesisBlock(target: UInt256.max / UInt256(2))
        let cHeader = try VolumeImpl<Block>(node: c)
        let nonce = try XCTUnwrap(mine(clearing: hard) { rootCommitting(cHeader, target: hard, nonce: $0) })
        let root = rootCommitting(cHeader, target: hard, nonce: nonce)
        let rootHeader = try VolumeImpl<Block>(node: root)

        // Direct child: directoryPath length 1, only the root above the leaf.
        let proof = ChildBlockProof(rootCID: rootHeader.rawCID,
                                    directoryPath: [childDir],
                                    entries: try await entries(rootHeader, cHeader))
        let contributions = await proof.securingWorkContributions()

        XCTAssertEqual(contributions.count, 1, "depth-1 has exactly the root above the leaf")
        XCTAssertEqual(contributions.first?.id, rootHeader.rawCID)
        XCTAssertEqual(contributions.first?.work, workForTarget(hard),
                       "depth-1 credit == the root's own work — byte-identical to the pre-fix output")
    }

    // MARK: - Child-only carrier (#13): root fails its OWN target, clears an intermediate

    func test_childOnlyCarrier_rootFailsOwnTarget_creditsIntermediateMaxKeyedByRoot() async throws {
        let hardUncleared = UInt256.max / UInt256(256)  // root's own target — will NOT be cleared
        let easy = UInt256.max / UInt256(4)             // intermediate target — WILL be cleared

        let x = makeGenesisBlock(target: easy)
        let xHeader = try VolumeImpl<Block>(node: x)
        // Mine a hash in (hardUncleared, easy]: clears the intermediate, not the root's own target.
        let nonce = try XCTUnwrap(
            mine(clearing: easy, notClearing: hardUncleared) { rootCommitting(xHeader, target: hardUncleared, nonce: $0) },
            "mining did not converge")
        let root = rootCommitting(xHeader, target: hardUncleared, nonce: nonce)
        let rootHeader = try VolumeImpl<Block>(node: root)
        let powHash = root.proofOfWorkHash()
        XCTAssertFalse(root.validateProofOfWork(nexusHash: powHash),
                       "carrier must FAIL its own target (that's what makes it child-only)")
        XCTAssertTrue(x.validateProofOfWork(nexusHash: powHash), "but its hash clears the intermediate")

        let proof = ChildBlockProof(rootCID: rootHeader.rawCID,
                                    directoryPath: [childDir, "leaf"],
                                    entries: try await entries(rootHeader, xHeader))
        let contributions = await proof.securingWorkContributions()

        XCTAssertEqual(contributions.count, 1, "still ONE contribution")
        XCTAssertEqual(contributions.first?.id, rootHeader.rawCID,
                       "keyed by rootCID (the grind) even though the root failed its own target")
        XCTAssertEqual(contributions.first?.work, workForTarget(easy),
                       "credits the MAX cleared level (the intermediate), not the uncleared root target")
    }

    // MARK: - Independent grinds (distinct roots, same child) still SUM

    func test_distinctRoots_sameChild_sum_viaRealProofs() async throws {
        let t1 = UInt256.max / UInt256(16)   // work 16
        let t2 = UInt256.max / UInt256(64)   // work 64  (distinct target ⇒ distinct root CID)

        let c = makeGenesisBlock(target: UInt256.max / UInt256(2))
        let cHeader = try VolumeImpl<Block>(node: c)
        let childHash = cHeader.rawCID

        let n1 = try XCTUnwrap(mine(clearing: t1) { rootCommitting(cHeader, target: t1, nonce: $0) })
        let n2 = try XCTUnwrap(mine(clearing: t2) { rootCommitting(cHeader, target: t2, nonce: $0) })
        let r1 = rootCommitting(cHeader, target: t1, nonce: n1)
        let r2 = rootCommitting(cHeader, target: t2, nonce: n2)
        let r1Header = try VolumeImpl<Block>(node: r1)
        let r2Header = try VolumeImpl<Block>(node: r2)
        XCTAssertNotEqual(r1Header.rawCID, r2Header.rawCID, "distinct grinds must have distinct root CIDs")

        let p1 = ChildBlockProof(rootCID: r1Header.rawCID, directoryPath: [childDir],
                                 entries: try await entries(r1Header, cHeader))
        let p2 = ChildBlockProof(rootCID: r2Header.rawCID, directoryPath: [childDir],
                                 entries: try await entries(r2Header, cHeader))

        let store = InheritedWeightStore()
        store.recordVerifiedWorkContributions(await p1.securingWorkContributions(), committingChild: childHash)
        store.recordVerifiedWorkContributions(await p2.securingWorkContributions(), committingChild: childHash)

        let expected = saturatingWorkSum(workForTarget(t1), workForTarget(t2))
        XCTAssertEqual(store.inheritedWeight(forChild: childHash), expected,
                       "two independent grinds committing the same child must SUM")
        XCTAssertNotEqual(store.inheritedWeight(forChild: childHash),
                          max(workForTarget(t1), workForTarget(t2)),
                          "distinct grinds must not collapse to a max")
    }

    // MARK: - The named inflation vector: EQUAL targets across levels

    func test_equalTargets_lockstep_creditsOneGrindNotNTimes() async throws {
        // Both levels share the SAME target — a lockstep path that adds no independent
        // security. One grind must count ONCE (work T), never N×T (the old inflation).
        let t = UInt256.max / UInt256(16)   // workForTarget = 16 at BOTH levels
        let x = makeGenesisBlock(target: t)
        let xHeader = try VolumeImpl<Block>(node: x)
        let nonce = try XCTUnwrap(mine(clearing: t) { rootCommitting(xHeader, target: t, nonce: $0) })
        let root = rootCommitting(xHeader, target: t, nonce: nonce)
        let rootHeader = try VolumeImpl<Block>(node: root)
        XCTAssertTrue(x.validateProofOfWork(nexusHash: root.proofOfWorkHash()),
                      "one hash clears both equal-target levels")

        let proof = ChildBlockProof(rootCID: rootHeader.rawCID,
                                    directoryPath: [childDir, "leaf"],
                                    entries: try await entries(rootHeader, xHeader))
        let contributions = await proof.securingWorkContributions()
        let work = await proof.securingWork()
        XCTAssertEqual(contributions.count, 1)
        XCTAssertEqual(work, workForTarget(t), "credits ONE grind at T")
        XCTAssertNotEqual(work, saturatingWorkSum(workForTarget(t), workForTarget(t)),
                          "must NOT credit 2×T for two equal lockstep levels")
    }

    // MARK: - Depth 3: the MAX-accumulation loop iterates more than once

    func test_depth3_singleGrind_creditsMaxOnce_acrossTwoIntermediates() async throws {
        let midDir = "Mid"
        let hard = UInt256.max / UInt256(64)   // root → 64
        let med = UInt256.max / UInt256(8)     // first intermediate → 8
        let easy = UInt256.max / UInt256(2)    // second intermediate → 2

        let y = makeGenesisBlock(target: easy)
        let yHeader = try VolumeImpl<Block>(node: y)
        let x = blockCommitting(yHeader, at: midDir, target: med, nonce: 0)
        let xHeader = try VolumeImpl<Block>(node: x)
        let nonce = try XCTUnwrap(mine(clearing: hard) { rootCommitting(xHeader, target: hard, nonce: $0) })
        let root = rootCommitting(xHeader, target: hard, nonce: nonce)
        let rootHeader = try VolumeImpl<Block>(node: root)
        let powHash = root.proofOfWorkHash()
        XCTAssertTrue(x.validateProofOfWork(nexusHash: powHash) && y.validateProofOfWork(nexusHash: powHash),
                      "the single hash clears all three levels")

        // directoryPath [childDir, midDir, leaf]: walk grades root + X + Y (leaf excluded).
        let proof = ChildBlockProof(rootCID: rootHeader.rawCID,
                                    directoryPath: [childDir, midDir, "leaf"],
                                    entries: try await entries(rootHeader, xHeader, yHeader))
        let contributions = await proof.securingWorkContributions()
        let work = await proof.securingWork()
        XCTAssertEqual(contributions.count, 1, "one grind → one contribution across three levels")
        XCTAssertEqual(contributions.first?.id, rootHeader.rawCID)
        XCTAssertEqual(work, workForTarget(hard), "MAX (root) once, not 64+8+2")
        XCTAssertNotEqual(work, saturatingWorkSum(saturatingWorkSum(workForTarget(hard), workForTarget(med)),
                                                  workForTarget(easy)))
    }

    // MARK: - Clears no level → no contribution

    func test_grindClearsNoLevel_yieldsNoContribution() async throws {
        // target 1 is effectively unclearable (hash must be <= 1); no level credits.
        let unclearable = UInt256(1)
        let x = makeGenesisBlock(target: unclearable)
        let xHeader = try VolumeImpl<Block>(node: x)
        let root = rootCommitting(xHeader, target: unclearable, nonce: 0)
        let rootHeader = try VolumeImpl<Block>(node: root)
        XCTAssertFalse(root.validateProofOfWork(nexusHash: root.proofOfWorkHash()),
                       "sanity: root does not clear the unclearable target")

        let proof = ChildBlockProof(rootCID: rootHeader.rawCID,
                                    directoryPath: [childDir, "leaf"],
                                    entries: try await entries(rootHeader, xHeader))
        let contributions = await proof.securingWorkContributions()
        let work = await proof.securingWork()
        XCTAssertEqual(contributions.count, 0, "no cleared level → no contribution")
        XCTAssertEqual(work, .zero)
    }
}
