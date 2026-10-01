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

/// Several genesis roots per chain in one weighed graph (§9.9 genesis
/// admission, §9.4 across roots), tested against the "Lattice architecture
/// preserved" checklist: the weighed graph with the executed set inside it,
/// validity selects, continuity, genesis links from any executed parent
/// block, hierarchical GHOST with grinds deduped, weighed-only blocks issue
/// no facts, and the root-exclusion rule.
final class MultiRootGenesisTests: XCTestCase {
    private let rootContext = testChainContext()
    private let childContext = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])

    private func cid(_ block: Block) throws -> String {
        try BlockHeader(node: block).rawCID
    }

    private func link(_ genesis: Block) throws -> ParentGenesisLink {
        ParentGenesisLink(
            parentPath: [DEFAULT_ROOT_DIRECTORY],
            directory: "Child",
            childGenesisCID: try cid(genesis),
            parentStateCID: LatticeState.emptyHeader.rawCID
        )
    }

    private func granting(_ genesis: Block...) throws -> GrantedGenesisFacts {
        GrantedGenesisFacts(links: Set(try genesis.map(link)))
    }

    /// A child tree bootstrapped from `genesis` through the one genesis path.
    private func childTree(
        _ genesis: Block,
        fetcher: StorableFetcher
    ) async throws -> (tree: ChainTree, batches: [BlockImportBatch]) {
        let bootstrapped = try await ChainTree.bootstrap(
            genesis: try BlockHeader(node: genesis), fetcher: fetcher,
            context: childContext, parentFacts: try granting(genesis)
        ).get()
        return (bootstrapped.tree, bootstrapped.batches)
    }

    private func work(_ seed: String, _ amount: UInt64 = 1) -> VerifiedWorkContribution {
        VerifiedWorkContribution(id: testCID("grind-\(seed)"), work: UInt256(amount))
    }

    /// Every block the tree holds that it executed.
    private func executedSet(_ tree: ChainTree, among blocks: [Block]) throws -> Set<String> {
        Set(try blocks.map(cid).filter { tree.hasExecutedAncestry(blockHash: $0) })
    }

    // MARK: - Weighed graph; executed set inside it

    /// An unauthorized root weighs — its descendants' work included — and
    /// is selected by weight, but it is never executed until authorized:
    /// the executed set stays inside the weighed graph.
    func testAnUnauthorizedRootWeighsButExecutesOnlyOnceAuthorized() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let rival = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 2)
        let rivalChild = try await AdmissionFixture.makeChild(of: rival, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        var (tree, _) = try await childTree(genesis, fetcher: fetcher)

        let inserted = try XCTUnwrap(tree.insertGenesis(rival, spec: chainLocalSpec()).update)
        XCTAssertEqual(inserted.batches.map { $0.facts.count }, [1], "a genesis fact alone: no work of its own")
        XCTAssertEqual(tree.subtreeWeight(forHash: try cid(rival)), .zero)
        let weighed = try await TreeDriver.insert(rivalChild, into: &tree, fetcher: fetcher, work: work("rival-child"))
        XCTAssertNotNil(weighed.update)
        XCTAssertEqual(tree.subtreeWeight(forHash: try cid(rival)), WorkSum(UInt256(1)))
        XCTAssertEqual(tree.canonicalTip, try cid(rivalChild), "the heavier root wins, executed or not")

        // Unauthorized: no verdict, and nothing recorded.
        let refused = try await TreeDriver.connect(try cid(rival), on: &tree, fetcher: fetcher)
        guard case .crossChainEvidenceRequired(.parentGenesis(_, "Child", let genesisCID, _))? = refused.failure else {
            return XCTFail("an unauthorized root asks for its parent's genesis fact, got \(refused)")
        }
        XCTAssertEqual(genesisCID, try cid(rival))
        let all = [genesis, rival, rivalChild]
        XCTAssertEqual(try executedSet(tree, among: all), [try cid(genesis)])

        // Authorized: it executes, and so can its block.
        let executed = try await TreeDriver.connect(
            try cid(rival), on: &tree, fetcher: fetcher, parentFacts: try granting(rival)
        )
        XCTAssertNotNil(executed.update)
        XCTAssertEqual(executed.update?.parentGenesisLinks, [])
        XCTAssertTrue(tree.hasExecutedAncestry(blockHash: try cid(rival)))
        for hash in try executedSet(tree, among: all) {
            XCTAssertTrue(tree.contains(blockHash: hash), "executed ⊆ weighed")
        }
    }

    // MARK: - Validity selects; root exclusion

    /// An authorized but invalid root is excluded while another executed
    /// root stands: never executed, never selected, its subtree still weighs.
    func testAnInvalidAuthorizedRootIsExcludedAndStillWeighs() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let template = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 3)
        let invalid = try await TreeDriver.forgedPostState(of: template, seed: "invalid-root", fetcher: fetcher)
        let below = try await AdmissionFixture.makeChild(of: invalid, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        var (tree, _) = try await childTree(genesis, fetcher: fetcher)

        XCTAssertNotNil(tree.insertGenesis(invalid, spec: chainLocalSpec()).update)
        let weighedBelow = try await TreeDriver.insert(below, into: &tree, fetcher: fetcher, work: work("below", 5))
        XCTAssertNotNil(weighedBelow.update)
        XCTAssertEqual(tree.canonicalTip, try cid(below))

        let verdict = try await TreeDriver.connect(
            try cid(invalid), on: &tree, fetcher: fetcher, parentFacts: try granting(invalid)
        )
        XCTAssertEqual(verdict.update?.excluded, true)
        XCTAssertTrue(tree.isExcludedRoot(try cid(invalid)))
        XCTAssertFalse(tree.hasExecutedAncestry(blockHash: try cid(invalid)))
        XCTAssertEqual(tree.subtreeWeight(forHash: try cid(invalid)), WorkSum(UInt256(5)), "work weighs")
        XCTAssertEqual(tree.canonicalTip, try cid(genesis), "validity selects")
    }

    /// The root-exclusion rule holds with several roots: the only executed
    /// root is never excluded (irrevocable), and an unexecuted root is
    /// excluded only while an executed one stands.
    func testTheRootExclusionRuleHoldsAcrossRoots() async throws {
        let fetcher = StorableFetcher()
        let template = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 4)
        let invalid = try await TreeDriver.forgedPostState(of: template, seed: "lone-root", fetcher: fetcher)
        var lone = ChainTree.empty(context: childContext)
        XCTAssertNotNil(lone.insertGenesis(invalid, spec: chainLocalSpec()).update)
        let refused = try await TreeDriver.connect(
            try cid(invalid), on: &lone, fetcher: fetcher, parentFacts: try granting(invalid)
        )
        XCTAssertEqual(refused.failure, .notYetValid, "no executed root to stand on")
        XCTAssertFalse(lone.isExcludedRoot(try cid(invalid)))

        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        var (tree, _) = try await childTree(genesis, fetcher: fetcher)
        let contradiction = tree.applyConnect(ConnectVerdict(
            blockHash: try cid(genesis), outcome: .invalid(isGenesis: true)
        ))
        XCTAssertEqual(contradiction.failure, .localVerificationFailure, "execution is never revoked")
        XCTAssertFalse(tree.isExcludedRoot(try cid(genesis)))
    }

    // MARK: - Continuity; weighed-only blocks issue no facts

    /// An unexecuted root's declared states are claims: no continuity, no
    /// genesis link, until it executes.
    func testAWeighedOnlyRootIssuesNoFactsAndAttestsNoState() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 9)
        let keyPair = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            genesisActions: [GenesisAction(directory: "Child", blockCID: try cid(childGenesis))],
            receiptActions: [], withdrawalActions: [],
            signers: [testAddress(publicKey: keyPair.publicKey)], nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        // A rival ROOT of the parent chain whose genesis transaction issues
        // the child's genesis link.
        let issuer = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher, timestamp: 1_000, nonce: 5,
            transactions: [signedTestTransaction(body, by: keyPair)]
        )
        var parent = try await ChainTree.bootstrap(
            genesis: try BlockHeader(node: genesis), fetcher: fetcher, context: rootContext
        ).get().tree
        let weighed = try XCTUnwrap(parent.insertGenesis(issuer, spec: chainLocalSpec()).update)
        XCTAssertEqual(weighed.parentGenesisLinks, [], "a weighed-only root issues no facts")
        XCTAssertFalse(parent.executedSetProduced(stateCID: issuer.postState.rawCID))

        var facts = ParentLevelFacts(tree: parent)
        facts.record(weighed)
        XCTAssertFalse(facts.recordsGenesis(try link(childGenesis)), "no executed issuer")

        let childLink = try link(childGenesis)
        let executed = try await TreeDriver.connect(try cid(issuer), on: &parent, fetcher: fetcher)
        let update = try XCTUnwrap(executed.update)
        XCTAssertEqual(update.parentGenesisLinks, [childLink])
        XCTAssertTrue(parent.executedSetProduced(stateCID: issuer.postState.rawCID), "continuity from any executed root")

        // Genesis links from ANY executed parent block: the issuer is a
        // losing root, and still authorizes the child.
        facts.record(update)
        facts.tree = parent
        XCTAssertTrue(facts.recordsGenesis(childLink))
        let child = try await ChainTree.bootstrap(
            genesis: try BlockHeader(node: childGenesis), fetcher: fetcher,
            context: childContext, parentFacts: facts
        ).get()
        XCTAssertTrue(child.tree.hasExecutedAncestry(blockHash: try cid(childGenesis)))
    }

    // MARK: - Hierarchical GHOST, grinds deduped

    /// GHOST runs across roots on subtree weight; a grind has one location
    /// in the chain, so it cannot weigh under two roots.
    func testGhostAcrossRootsDedupesGrinds() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let rival = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 2)
        let a = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let b = try await AdmissionFixture.makeChild(of: rival, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        var (tree, _) = try await childTree(genesis, fetcher: fetcher)
        XCTAssertNotNil(tree.insertGenesis(rival, spec: chainLocalSpec()).update)

        let shared = work("shared", 2)
        let weighedA = try await TreeDriver.insert(a, into: &tree, fetcher: fetcher, work: shared)
        XCTAssertNotNil(weighedA.update)
        let elsewhere = try await TreeDriver.insert(b, into: &tree, fetcher: fetcher, work: shared)
        XCTAssertEqual(elsewhere.failure, .providerMalformedEvidence, "one grind, one location per chain")
        let weighedB = try await TreeDriver.insert(b, into: &tree, fetcher: fetcher, work: work("b", 1))
        XCTAssertNotNil(weighedB.update)
        XCTAssertEqual(tree.canonicalTip, try cid(a))

        // Two more grinds under the rival outweigh the shared one.
        XCTAssertNotNil(tree.addWork(work("b2", 2), to: try cid(b)).update)
        XCTAssertEqual(tree.canonicalTip, try cid(b))
        // A repeated observation of a held grind counts once.
        guard case .duplicate = tree.addWork(work("b2", 2), to: try cid(b)) else {
            return XCTFail("a repeated observation adds nothing")
        }
        XCTAssertEqual(tree.subtreeWeight(forHash: try cid(rival)), WorkSum(UInt256(3)))
    }

    // MARK: - Spec per root

    /// Each root's spec is held by its CID, and a block under a spec
    /// mismatch is still scheduled by its ROOT's spec, held or not its own.
    func testEveryRootHoldsItsOwnSpecAndSchedulesItsSubtree() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let otherSpec = ChainSpec.test(premine: 7)
        let rival = try await buildAndStoreGenesis(
            spec: otherSpec, timestamp: 1_000, target: AdmissionFixture.easy, nonce: 2, fetcher: fetcher
        )
        var (tree, bootstrapBatches) = try await childTree(genesis, fetcher: fetcher)
        XCTAssertEqual(tree.insertGenesis(rival, spec: chainLocalSpec()).failure, .providerMalformedEvidence,
                       "a spec that is not the one the genesis names")
        let inserted = try XCTUnwrap(tree.insertGenesis(rival, spec: otherSpec).update)
        XCTAssertEqual(tree.specs.count, 2)

        // A block under the first root declaring the rival's spec: excluded,
        // and its own child is still scheduled by the first root's spec.
        let valid = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let offSpec = try await storeBuiltBlock(Block(
            version: valid.version, parent: valid.parent, transactions: valid.transactions,
            target: valid.target, nextTarget: valid.nextTarget,
            spec: try VolumeImpl<ChainSpec>(node: otherSpec),
            parentState: valid.parentState, prevState: valid.prevState, postState: valid.postState,
            children: valid.children, height: valid.height, timestamp: valid.timestamp,
            rewardRecipient: valid.rewardRecipient, nonce: valid.nonce
        ), in: fetcher)
        let underOffSpec = try await AdmissionFixture.makeChild(of: offSpec, fetcher: fetcher, timestamp: 3_000, nonce: 1)
        let offSpecInsert = try await TreeDriver.insert(offSpec, into: &tree, fetcher: fetcher, work: work("off"))
        let excluded = try XCTUnwrap(offSpecInsert.update)
        XCTAssertTrue(excluded.excluded)
        let belowInsert = try await TreeDriver.insert(underOffSpec, into: &tree, fetcher: fetcher, work: work("under"))
        let below = try XCTUnwrap(belowInsert.update)
        XCTAssertFalse(below.excluded, "linked to its parent; never selected, as it sits under an exclusion")

        // Restore needs every root's spec.
        let batches = bootstrapBatches + inserted.batches + excluded.batches + below.batches
        XCTAssertThrowsError(try ChainTree.restore(replaying: batches, context: childContext, specs: [chainLocalSpec()]))
        let restored = try ChainTree.restore(
            replaying: batches, context: childContext, specs: [chainLocalSpec(), otherSpec]
        )
        XCTAssertEqual(restored.specs.keys.sorted(), tree.specs.keys.sorted())
    }

    // MARK: - Restore

    /// Two roots, one executed and one excluded, with work under both:
    /// restore rebuilds the same selection, executed set and exclusions from
    /// the facts in any order.
    func testTwoRootRestoreIsIndependentOfReplayOrder() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let rival = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 2)
        let template = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 3)
        let invalid = try await TreeDriver.forgedPostState(of: template, seed: "restore", fetcher: fetcher)
        let a = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let b = try await AdmissionFixture.makeChild(of: rival, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let x = try await AdmissionFixture.makeChild(of: invalid, fetcher: fetcher, timestamp: 2_000, nonce: 1)

        var (tree, batches) = try await childTree(genesis, fetcher: fetcher)
        func keep(_ admission: ChainTreeAdmission) throws {
            batches += try XCTUnwrap(admission.update, "\(admission)").batches
        }
        try keep(tree.insertGenesis(rival, spec: chainLocalSpec()))
        try keep(tree.insertGenesis(invalid, spec: chainLocalSpec()))
        try keep(try await TreeDriver.insert(a, into: &tree, fetcher: fetcher, work: work("a", 1)))
        try keep(try await TreeDriver.insert(b, into: &tree, fetcher: fetcher, work: work("b", 2)))
        try keep(try await TreeDriver.insert(x, into: &tree, fetcher: fetcher, work: work("x", 9)))
        try keep(try await TreeDriver.connect(
            try cid(rival), on: &tree, fetcher: fetcher, parentFacts: try granting(rival)
        ))
        try keep(try await TreeDriver.connect(
            try cid(invalid), on: &tree, fetcher: fetcher, parentFacts: try granting(invalid)
        ))
        try keep(try await TreeDriver.connect(try cid(b), on: &tree, fetcher: fetcher))
        XCTAssertEqual(tree.canonicalTip, try cid(b))

        let all = [genesis, rival, invalid, a, b, x]
        let expectedExecuted = try executedSet(tree, among: all)
        XCTAssertEqual(expectedExecuted, Set(try [genesis, rival, b].map(cid)))
        var rng = SystemRandomNumberGenerator()
        for order in [batches, batches.reversed()] + (0..<8).map({ _ in batches.shuffled(using: &rng) }) {
            let restored = try ChainTree.restore(
                replaying: order, context: childContext, specs: [chainLocalSpec()]
            )
            XCTAssertEqual(restored.canonicalTip, tree.canonicalTip)
            XCTAssertEqual(try executedSet(restored, among: all), expectedExecuted)
            XCTAssertTrue(restored.isExcludedRoot(try cid(invalid)))
            XCTAssertEqual(restored.isExcludedRoot(try cid(rival)), false)
        }
    }
}
