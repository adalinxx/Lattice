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

/// The "Lattice architecture preserved" checklist, one test per item, driven
/// only through the `ChainTree` value API: `insertRootHeader`/`insertChildHeader`, `addWork`,
/// `connectJob`/`connect`/`applyConnect`, `bootstrap` and `replay`.
final class ChainTreeArchitectureTests: XCTestCase {
    private let easy = AdmissionFixture.easy
    private let rootContext = testChainContext()
    private let childContext = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])

    private func cid(_ block: Block) throws -> String {
        try BlockHeader(node: block).rawCID
    }

    /// A block on `forgedParent` that copies `template`'s linkage fields, so
    /// it links to a forged parent exactly as `template` links to its own.
    private func forgedChild(
        of forgedParent: Block,
        like template: Block,
        fetcher: StorableFetcher
    ) async throws -> Block {
        try await storeBuiltBlock(Block(
            version: template.version,
            parent: try BlockHeader(node: forgedParent),
            transactions: template.transactions,
            target: template.target,
            nextTarget: template.nextTarget,
            spec: template.spec,
            parentState: template.parentState,
            prevState: forgedParent.postState,
            postState: forgedParent.postState,
            children: template.children,
            height: template.height,
            timestamp: template.timestamp,
            rewardRecipient: nil,
            nonce: template.nonce + 1_000
        ), in: fetcher)
    }

    private func kinds(_ batches: [BlockImportBatch]?) -> [String] {
        (batches ?? []).flatMap(\.facts).map { fact in
            switch fact {
            case .block: "block"
            case .work: "work"
            case .validation: "validation"
            case .exclusion: "exclusion"
            }
        }
    }

    /// G → A → A2 (valid) against a heavier G → X → X1 → X2 whose root X is
    /// proven invalid, all weighed from headers.
    private struct ForkedRoot {
        let fetcher: StorableFetcher
        let genesis: Block
        let a: Block
        let a2: Block
        let x: Block
        let x1: Block
        let x2: Block
        var tree: ChainTree
        var emitted: [BlockImportBatch] = []
    }

    private func forkedRoot() async throws -> ForkedRoot {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let a = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let a2 = try await AdmissionFixture.makeChild(of: a, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let t1 = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_100, nonce: 3)
        let t2 = try await AdmissionFixture.makeChild(of: t1, fetcher: fetcher, timestamp: 3_100, nonce: 4)
        let t3 = try await AdmissionFixture.makeChild(of: t2, fetcher: fetcher, timestamp: 4_100, nonce: 5)
        let x = try await TreeDriver.forgedPostState(of: t1, seed: "x", fetcher: fetcher)
        let x1 = try await forgedChild(of: x, like: t2, fetcher: fetcher)
        let x2 = try await forgedChild(of: x1, like: t3, fetcher: fetcher)
        var fixture = ForkedRoot(
            fetcher: fetcher, genesis: genesis, a: a, a2: a2, x: x, x1: x1, x2: x2,
            tree: try await TreeDriver.tree(genesis: genesis, context: rootContext, fetcher: fetcher)
        )
        for block in [a, a2, x, x1, x2] {
            let inserted = try await TreeDriver.insert(block, into: &fixture.tree, fetcher: fetcher)
            let update = try XCTUnwrap(inserted.update, "\(inserted)")
            XCTAssertEqual(kinds(update.batches), ["block", "work"])
            fixture.emitted += update.batches
        }
        return fixture
    }

    /// Execution on candidacy: execute the first unexecuted block on the
    /// path to the selected tip, until the tip is executed.
    private func executeCandidates(_ fixture: inout ForkedRoot) async throws {
        for _ in 0..<16 {
            var block = fixture.tree.canonicalTip
            guard !fixture.tree.hasExecutedAncestry(blockHash: block) else { return }
            while let parent = fixture.tree.getConsensusBlock(hash: block)?.parentBlockHash,
                  !fixture.tree.hasExecutedAncestry(blockHash: parent) {
                block = parent
            }
            let connected = try await TreeDriver.connect(block, on: &fixture.tree, fetcher: fixture.fetcher)
            let update = try XCTUnwrap(connected.update, "\(connected)")
            fixture.emitted += update.batches
        }
        XCTFail("candidacy did not settle")
    }

    // MARK: - Weighed graph

    /// Every block with verified work weighs, an invalid subtree included,
    /// and proving it invalid revokes none of its work.
    func testWeighedGraphWeighsInvalidSubtreesAndNeverRevokesWork() async throws {
        var fixture = try await forkedRoot()
        let genesis = try cid(fixture.genesis)
        let weightBefore = try XCTUnwrap(fixture.tree.subtreeWeight(forHash: genesis))
        let xWeightBefore = try XCTUnwrap(fixture.tree.subtreeWeight(forHash: try cid(fixture.x)))
        XCTAssertEqual(weightBefore, WorkSum(UInt256(6)), "genesis + five weighed blocks")
        XCTAssertEqual(xWeightBefore, WorkSum(UInt256(3)))

        let excluded = try await TreeDriver.connect(try cid(fixture.x), on: &fixture.tree, fetcher: fixture.fetcher)
        XCTAssertEqual(kinds(excluded.update?.batches), ["exclusion"])
        XCTAssertTrue(fixture.tree.isExcludedRoot(try cid(fixture.x)))

        XCTAssertEqual(fixture.tree.subtreeWeight(forHash: genesis), weightBefore, "work is never revoked")
        XCTAssertEqual(fixture.tree.subtreeWeight(forHash: try cid(fixture.x)), xWeightBefore)
        for block in [fixture.x, fixture.x1, fixture.x2] {
            XCTAssertTrue(fixture.tree.contains(blockHash: try cid(block)), "the invalid subtree stays in the graph")
        }
    }

    // MARK: - Executed set

    /// The executed set is a subset of the weighed graph and a SET: every
    /// branch executed from genesis is in it, canonical or not, and nothing
    /// weighed-only or under an excluded root is.
    func testExecutedSetIsASubsetOfTheWeighedGraphAndNotATip() async throws {
        var fixture = try await forkedRoot()
        try await executeCandidates(&fixture)
        let side = try await AdmissionFixture.makeChild(
            of: fixture.genesis, fetcher: fixture.fetcher, timestamp: 2_200, nonce: 6
        )
        _ = try await TreeDriver.insert(side, into: &fixture.tree, fetcher: fixture.fetcher)
        let connected = try await TreeDriver.connect(try cid(side), on: &fixture.tree, fetcher: fixture.fetcher)
        XCTAssertEqual(kinds(connected.update?.batches), ["block", "work", "validation"])

        let executed = try [fixture.genesis, fixture.a, fixture.a2, side].map(cid)
        let weighedOnly = try [fixture.x, fixture.x1, fixture.x2].map(cid)
        for hash in executed {
            XCTAssertTrue(fixture.tree.contains(blockHash: hash), "subset of the weighed graph")
            XCTAssertTrue(fixture.tree.hasExecutedAncestry(blockHash: hash))
        }
        for hash in weighedOnly {
            XCTAssertFalse(fixture.tree.hasExecutedAncestry(blockHash: hash))
        }
        XCTAssertEqual(fixture.tree.canonicalTip, try cid(fixture.a2))
        XCTAssertFalse(fixture.tree.isCanonical(hash: try cid(side)), "an executed side branch is still executed")
    }

    // MARK: - Validity selects

    /// Fork choice descends to the heaviest VALID child; execution happens on
    /// candidacy, and an excluded block's work still weighs.
    func testValiditySelectsTheHeaviestValidChildExecutedOnCandidacy() async throws {
        var fixture = try await forkedRoot()
        XCTAssertEqual(fixture.tree.canonicalTip, try cid(fixture.x2), "weighed-only blocks are candidates")
        let weightBefore = fixture.tree.subtreeWeight(forHash: try cid(fixture.genesis))

        try await executeCandidates(&fixture)

        XCTAssertEqual(fixture.tree.canonicalTip, try cid(fixture.a2), "the heaviest valid child wins")
        XCTAssertTrue(fixture.tree.isExcludedRoot(try cid(fixture.x)))
        XCTAssertEqual(
            fixture.tree.forkChoiceSnapshot(startingAt: try cid(fixture.genesis))?.subtreeWork,
            weightBefore,
            "the excluded subtree still weighs for its ancestor"
        )
        XCTAssertEqual(
            fixture.emitted.suffix(3).map { kinds([$0]) },
            [["exclusion"], ["block", "work", "validation"], ["block", "work", "validation"]]
        )
    }

    // MARK: - Parent-chain continuity

    /// A child's `parentState` must be produced by some block in the
    /// parent's EXECUTED set, on any branch: a side-branch state counts once
    /// executed, and a weighed-only one never does.
    func testParentContinuityReadsTheParentExecutedSetOnAnyBranch() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let mainRecipient = testAddress(publicKey: CryptoUtils.generateKeyPair().publicKey)
        let sideRecipient = testAddress(publicKey: CryptoUtils.generateKeyPair().publicKey)
        let a = try await buildAndStoreBlock(
            previous: parentGenesis, timestamp: 2_000, target: easy, nonce: 1,
            rewardRecipient: mainRecipient, fetcher: fetcher
        )
        let a2 = try await AdmissionFixture.makeChild(of: a, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let side = try await buildAndStoreBlock(
            previous: parentGenesis, timestamp: 2_100, target: easy, nonce: 3,
            rewardRecipient: sideRecipient, fetcher: fetcher
        )
        XCTAssertNotEqual(side.postState.rawCID, a.postState.rawCID)
        let onSide = try await AdmissionFixture.makeChild(of: side, fetcher: fetcher, timestamp: 3_100, nonce: 4)

        var parent = try await TreeDriver.tree(genesis: parentGenesis, context: rootContext, fetcher: fetcher)
        for block in [a, a2, side] {
            let inserted = try await TreeDriver.insert(block, into: &parent, fetcher: fetcher)
            XCTAssertNotNil(inserted.update)
        }
        _ = try await TreeDriver.connect(try cid(a), on: &parent, fetcher: fetcher)
        _ = try await TreeDriver.connect(try cid(a2), on: &parent, fetcher: fetcher)

        let childGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let childBlock = try await AdmissionFixture.makeChild(
            of: childGenesis, fetcher: fetcher, timestamp: 2_000, nonce: 1, parentChainBlock: onSide
        )
        XCTAssertEqual(childBlock.parentState.rawCID, side.postState.rawCID)
        var child = try await TreeDriver.tree(genesis: childGenesis, context: childContext, fetcher: fetcher)
        let childWork = VerifiedWorkContribution(id: testCID("child-grind"), work: UInt256(1))
        let childInserted = try await TreeDriver.insert(childBlock, into: &child, fetcher: fetcher, work: childWork)
        XCTAssertNotNil(childInserted.update)

        // The side branch is weighed, not executed: no continuity.
        let unanchored = try await TreeDriver.connect(
            try cid(childBlock), on: &child, fetcher: fetcher,
            parentFacts: ParentLevelFacts(tree: parent)
        )
        guard case .rejected(.crossChainEvidenceRequired(.parentStateContinuity(_, _, let toState))) = unanchored else {
            return XCTFail("a weighed-only parent state anchors nothing, got \(unanchored)")
        }
        XCTAssertEqual(toState, side.postState.rawCID)
        XCTAssertFalse(child.hasExecutedAncestry(blockHash: try cid(childBlock)))

        // Executing the side branch puts its state in the executed set while
        // the main branch stays canonical.
        _ = try await TreeDriver.connect(try cid(side), on: &parent, fetcher: fetcher)
        XCTAssertEqual(parent.canonicalTip, try cid(a2))
        XCTAssertFalse(parent.isCanonical(hash: try cid(side)))
        XCTAssertTrue(parent.executedSetProduced(stateCID: side.postState.rawCID))

        // Facts answer only for the parent chain the link names.
        let wrongPath = try await TreeDriver.connect(
            try cid(childBlock), on: &child, fetcher: fetcher,
            parentFacts: ParentLevelFacts(tree: parent, path: [DEFAULT_ROOT_DIRECTORY, "Other"])
        )
        guard case .rejected(.crossChainEvidenceRequired(.parentStateContinuity)) = wrongPath else {
            return XCTFail("another chain's facts answer nothing, got \(wrongPath)")
        }

        let anchored = try await TreeDriver.connect(
            try cid(childBlock), on: &child, fetcher: fetcher,
            parentFacts: ParentLevelFacts(tree: parent)
        )
        XCTAssertEqual(kinds(anchored.update?.batches), ["block", "work", "validation"])
        XCTAssertTrue(child.hasExecutedAncestry(blockHash: try cid(childBlock)))
    }

    // MARK: - Genesis links and weighed-only blocks

    /// A genesis link comes from a `GenesisAction` in any EXECUTED parent
    /// block — here a side branch — and a weighed-only block issues none.
    func testGenesisLinksComeFromExecutedParentBlocksAndWeighedOnlyIssuesNone() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let childCID = try cid(childGenesis)
        let keyPair = CryptoUtils.generateKeyPair()
        let owner = testAddress(publicKey: keyPair.publicKey)
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [GenesisAction(directory: "Child", blockCID: childCID)],
            receiptActions: [], withdrawalActions: [],
            signers: [owner], nonce: 0, chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let a = try await AdmissionFixture.makeChild(of: parentGenesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let a2 = try await AdmissionFixture.makeChild(of: a, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let side = try await buildAndStoreBlock(
            previous: parentGenesis, transactions: [signedTestTransaction(body, by: keyPair)],
            timestamp: 2_100, target: easy, nonce: 3, rewardRecipient: owner, fetcher: fetcher
        )
        var parent = try await TreeDriver.tree(genesis: parentGenesis, context: rootContext, fetcher: fetcher)
        for block in [a, a2] {
            _ = try await TreeDriver.insert(block, into: &parent, fetcher: fetcher)
        }
        let weighed = try await TreeDriver.insert(side, into: &parent, fetcher: fetcher)
        let weighedUpdate = try XCTUnwrap(weighed.update)
        XCTAssertEqual(kinds(weighedUpdate.batches), ["block", "work"], "no validation for a weighed-only block")
        XCTAssertEqual(weighedUpdate.parentGenesisLinks, [], "a weighed-only block issues no facts")
        XCTAssertFalse(parent.executedSetProduced(stateCID: side.postState.rawCID))

        let refused = await ChainTree.bootstrap(
            genesis: try BlockHeader(node: childGenesis), fetcher: fetcher, context: childContext,
            parentFacts: ParentLevelFacts(tree: parent)
        )
        guard case .failure(.providerMalformedEvidence) = refused else {
            return XCTFail("no executed parent block recorded the genesis, got \(refused)")
        }

        let connected = try await TreeDriver.connect(try cid(side), on: &parent, fetcher: fetcher)
        let connectedUpdate = try XCTUnwrap(connected.update)
        let links = connectedUpdate.parentGenesisLinks
        var parentFacts = ParentLevelFacts(tree: parent)
        parentFacts.record(connectedUpdate)
        let expected = ParentGenesisLink(
            parentPath: [DEFAULT_ROOT_DIRECTORY], directory: "Child",
            childGenesisCID: childCID, parentStateCID: LatticeState.emptyHeader.rawCID
        )
        XCTAssertEqual(links, [expected])
        XCTAssertFalse(parent.isCanonical(hash: try cid(side)), "issued from a side branch")

        let bootstrapped = await ChainTree.bootstrap(
            genesis: try BlockHeader(node: childGenesis), fetcher: fetcher, context: childContext,
            parentFacts: parentFacts
        )
        let child = try bootstrapped.get()
        XCTAssertEqual(child.tree.canonicalTip, childCID)
        XCTAssertTrue(child.tree.hasExecutedAncestry(blockHash: childCID))
        XCTAssertEqual(kinds([child.facts]), ["block", "work", "validation"])
    }

    // MARK: - Hierarchical GHOST

    /// A child block weighs its parent's attributed run, and one grind is
    /// counted once however often it is observed: a stronger observation
    /// replaces it, and it can hold only one location.
    func testHierarchicalGhostCreditsAttributedRunsAndDedupsGrindsByRoot() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let childBlock = try await AdmissionFixture.makeChild(of: childGenesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let committer = try await buildAndStoreBlock(
            previous: parentGenesis, children: ["Child": childBlock],
            timestamp: 2_000, target: easy, nonce: 1, fetcher: fetcher
        )
        let runBlock = try await AdmissionFixture.makeChild(of: committer, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        var parent = try await TreeDriver.tree(genesis: parentGenesis, context: rootContext, fetcher: fetcher)
        for block in [committer, runBlock] {
            let inserted = try await TreeDriver.insert(block, into: &parent, fetcher: fetcher)
            XCTAssertNotNil(inserted.update)
        }
        let committerCID = try cid(committer)
        XCTAssertEqual(parent.recordedChildCommitments(of: committerCID), ["Child": try cid(childBlock)])
        parent.serveRuns(for: "Child")
        let report = try XCTUnwrap(parent.parentRunReport(at: committerCID, directory: "Child"))

        // The committer's grind secures the child block.
        let grind = VerifiedWorkContribution(id: committerCID, work: UInt256(1))
        var child = try await TreeDriver.tree(genesis: childGenesis, context: childContext, fetcher: fetcher)
        let childCID = try cid(childBlock)
        let childInserted = try await TreeDriver.insert(childBlock, into: &child, fetcher: fetcher, work: grind)
        XCTAssertNotNil(childInserted.update)
        let before = try XCTUnwrap(child.subtreeWeight(forHash: childCID))

        guard case .strengthened(let batch) = child.strengthenFromParentReport(
            child: childCID, directory: "Child", report: report
        ) else {
            return XCTFail("the committer's run must strengthen the child block")
        }
        _ = try child.replay(batch)
        let attributed = try XCTUnwrap(report.runWork.subtracting(report.ownWork))
        XCTAssertEqual(child.subtreeWeight(forHash: childCID), before + attributed)
        XCTAssertGreaterThan(attributed, .zero, "the run beyond the committer weighs in the child")

        // Grind dedup: a stronger observation of the same grind replaces it.
        let afterRun = try XCTUnwrap(child.subtreeWeight(forHash: childCID))
        let stronger = VerifiedWorkContribution(id: committerCID, work: UInt256(3))
        XCTAssertEqual(kinds(child.addWork(stronger, to: childCID).update?.batches), ["work"])
        XCTAssertEqual(child.subtreeWeight(forHash: childCID), afterRun + WorkSum(UInt256(2)), "counted once, at its strongest")
        guard case .duplicate = child.addWork(grind, to: childCID) else {
            return XCTFail("a weaker observation of a held grind adds nothing")
        }
        XCTAssertEqual(
            child.addWork(stronger, to: try cid(childGenesis)).failure,
            .providerMalformedEvidence,
            "a grind has one location"
        )
    }

    // MARK: - Unchanged rules

    /// The root-exclusion rule: a root may be excluded only while another
    /// executed root stands.
    func testRootExclusionRuleIsUnchanged() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        var tree = try await TreeDriver.tree(genesis: genesis, context: rootContext, fetcher: fetcher)
        let result = try await TreeDriver.connect(try cid(genesis), on: &tree, fetcher: fetcher)
        XCTAssertEqual(result.failure, .notYetValid)
        XCTAssertFalse(tree.isExcludedRoot(try cid(genesis)))
        XCTAssertEqual(tree.canonicalTip, try cid(genesis))
    }

    /// The four fact kinds and their encoding: everything the value API
    /// emitted is one of the four, round-trips through the durable encoding,
    /// and replays into the same tree.
    func testFourFactKindsReplayIntoTheSameTree() async throws {
        var fixture = try await forkedRoot()
        try await executeCandidates(&fixture)
        let emittedKinds = Set(kinds(fixture.emitted))
        XCTAssertEqual(emittedKinds, ["block", "work", "validation", "exclusion"])

        let decoded = try fixture.emitted.map {
            try JSONDecoder().decode(BlockImportBatch.self, from: try JSONEncoder().encode($0))
        }
        XCTAssertEqual(decoded, fixture.emitted)

        var replayed = try ChainTree.restore(
            replaying: [try testAdmissionBatch(for: fixture.genesis)] + decoded.reversed()
        )
        XCTAssertEqual(replayed.canonicalTip, fixture.tree.canonicalTip)
        let all = try [fixture.genesis, fixture.a, fixture.a2, fixture.x, fixture.x1, fixture.x2].map(cid)
        for hash in all {
            XCTAssertEqual(replayed.hasExecutedAncestry(blockHash: hash), fixture.tree.hasExecutedAncestry(blockHash: hash))
            XCTAssertEqual(replayed.isExcludedRoot(hash), fixture.tree.isExcludedRoot(hash))
            XCTAssertEqual(replayed.subtreeWeight(forHash: hash), fixture.tree.subtreeWeight(forHash: hash))
        }
    }
    // MARK: - Genesis links only from the executed set

    /// G → P1 → P2, where P1 declares a real post-state it does not produce
    /// and P2 carries a `GenesisAction`. P2 executes cleanly on P1's declared
    /// state, ahead of P1.
    private struct GenesisAttack {
        let fetcher: StorableFetcher
        let genesis: Block
        let p1: Block
        let p2: Block
        let childGenesis: Block
    }

    private func genesisAttack() async throws -> GenesisAttack {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let rewarded = try await buildAndStoreBlock(
            previous: genesis, timestamp: 2_000, target: easy, nonce: 1,
            rewardRecipient: testAddress(publicKey: "attack-reward"), fetcher: fetcher
        )
        let empty = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_100, nonce: 2)
        let p1 = try await storeBuiltBlock(Block(
            version: empty.version, parent: empty.parent, transactions: empty.transactions,
            target: empty.target, nextTarget: empty.nextTarget, spec: empty.spec,
            parentState: empty.parentState, prevState: empty.prevState,
            postState: rewarded.postState, children: empty.children,
            height: empty.height, timestamp: empty.timestamp,
            rewardRecipient: empty.rewardRecipient, nonce: empty.nonce
        ), in: fetcher)
        let keyPair = CryptoUtils.generateKeyPair()
        let owner = testAddress(publicKey: keyPair.publicKey)
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [GenesisAction(directory: "Child", blockCID: try cid(childGenesis))],
            receiptActions: [], withdrawalActions: [],
            signers: [owner], nonce: 0, chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let p2 = try await buildAndStoreBlock(
            previous: p1, transactions: [signedTestTransaction(body, by: keyPair)],
            timestamp: 3_000, target: easy, nonce: 3, rewardRecipient: owner, fetcher: fetcher
        )
        return GenesisAttack(fetcher: fetcher, genesis: genesis, p1: p1, p2: p2, childGenesis: childGenesis)
    }

    /// Executing P2 before P1, then excluding P1, must not authorize the
    /// child genesis: P2 never joins the executed set.
    func testGenesisLinkFromABlockExecutedAheadOfAnExcludedAncestryAuthorizesNothing() async throws {
        let attack = try await genesisAttack()
        var parent = try await TreeDriver.tree(genesis: attack.genesis, context: rootContext, fetcher: attack.fetcher)
        for block in [attack.p1, attack.p2] {
            let inserted = try await TreeDriver.insert(block, into: &parent, fetcher: attack.fetcher)
            XCTAssertNotNil(inserted.update)
        }
        var facts = ParentLevelFacts(tree: parent)
        let ahead = try await TreeDriver.connect(try cid(attack.p2), on: &parent, fetcher: attack.fetcher)
        let aheadUpdate = try XCTUnwrap(ahead.update, "\(ahead)")
        XCTAssertFalse(aheadUpdate.parentGenesisLinks.isEmpty, "P2's execution reports its link")
        facts.record(aheadUpdate)
        XCTAssertFalse(parent.hasExecutedAncestry(blockHash: try cid(attack.p2)))

        let excluded = try await TreeDriver.connect(try cid(attack.p1), on: &parent, fetcher: attack.fetcher)
        XCTAssertEqual(kinds(excluded.update?.batches), ["exclusion"])
        facts.tree = parent

        let link = try XCTUnwrap(aheadUpdate.parentGenesisLinks.first)
        XCTAssertFalse(facts.recordsGenesis(link))
        let bootstrapped = await ChainTree.bootstrap(
            genesis: try BlockHeader(node: attack.childGenesis), fetcher: attack.fetcher,
            context: childContext, parentFacts: facts
        )
        guard case .failure(.providerMalformedEvidence) = bootstrapped else {
            return XCTFail("a link from outside the executed set authorizes nothing, got \(bootstrapped)")
        }
    }

    // MARK: - Work and context bound to the tree

    /// Work is bound to its block, and the tree's own chain decides which
    /// kind of work it takes: a child tree takes only a child proof of the
    /// same block, a root tree only root work.
    func testWorkIsBoundToTheBlockAndTheTreeContext() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let block = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let other = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_100, nonce: 2)
        let inputs = try await TreeDriver.headerInputs(block, fetcher: fetcher)
        let work = VerifiedWorkContribution(id: testCID("grind"), work: UInt256(1))

        var child = try await TreeDriver.tree(genesis: genesis, context: childContext, fetcher: fetcher)
        let wrongBlock = child.insertChildHeader(
            block, childIndex: inputs.childIndex,
            evidence: try TreeDriver.evidence(for: other, work: work)
        )
        XCTAssertEqual(wrongBlock.failure, .proofOfWorkInvalid, "another block's work is refused, and blames")
        guard case .crossChainEvidenceRequired(.childProof) = child.insertRootHeader(
            block, childIndex: inputs.childIndex
        ).failure else {
            return XCTFail("a child tree takes no root work")
        }
        XCTAssertFalse(child.contains(blockHash: try cid(block)))

        var root = try await TreeDriver.tree(genesis: genesis, context: rootContext, fetcher: fetcher)
        XCTAssertEqual(root.insertChildHeader(
            block, childIndex: inputs.childIndex,
            evidence: try TreeDriver.evidence(for: block, work: work)
        ).failure, .protocolInvalid, "a root tree takes no child proof")
        XCTAssertNotNil(root.insertRootHeader(block, childIndex: inputs.childIndex).update)

        var unbound = ChainTree.fromGenesis(block: genesis)
        XCTAssertNil(unbound.connectJob(for: try cid(genesis)), "no context, no execution")
    }
}
