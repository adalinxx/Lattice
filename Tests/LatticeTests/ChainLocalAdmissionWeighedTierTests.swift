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

final class ChainLocalAdmissionWeighedTierTests: XCTestCase {
    func testWeighedAdmissionMatchesEagerForkChoiceWithoutMaterializedState() async throws {
        // Deferred execution (weight-first-acquisition): a `.header` admission
        // possesses the block and verifies its PoW, so its work enters fork
        // choice with exactly the eager path's weight — the consensus graph
        // never reads `stateDiff` — while it executes no state transition and
        // materializes no post-state. The eager path stays byte-for-byte the
        // default and is exercised here as the control.
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

        // A second, independent level seeded from an identical genesis so the
        // two fork-choice graphs are directly comparable. The same candidate
        // header is admitted into both.
        let weighedFetcher = StorableFetcher()
        let weighedGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: weighedFetcher, timestamp: genesisTimestamp
        )
        _ = try await AdmissionFixture.makeChild(
            of: weighedGenesis, fetcher: weighedFetcher, timestamp: 2_000, nonce: 1
        )
        XCTAssertEqual(try BlockHeader(node: weighedGenesis).rawCID, genesisHash)

        let eagerLevel = AdmissionFixture.makeLevel(genesis: eagerGenesis)
        let eager = try await eagerLevel.admit(candidate, fetcher: eagerFetcher)

        let weighedLevel = AdmissionFixture.makeLevel(genesis: weighedGenesis)
        let weighed = try await weighedLevel.admit(
            candidate,
            mode: .header,
            fetcher: weighedFetcher
        )

        guard case .accepted(let eagerAcceptance) = eager else {
            return XCTFail("eager admission must accept, got \(eager)")
        }
        guard case .accepted(let weighedAcceptance) = weighed else {
            return XCTFail("weighed admission must accept, got \(weighed)")
        }

        // Fork choice is identical: the weighed block contributes the same work
        // to the same tip over the same main-chain set.
        let eagerSnapshotValue = await eagerLevel.chain
            .forkChoiceSnapshot(startingAt: genesisHash)
        let weighedSnapshotValue = await weighedLevel.chain
            .forkChoiceSnapshot(startingAt: genesisHash)
        let eagerSnapshot = try XCTUnwrap(eagerSnapshotValue)
        let weighedSnapshot = try XCTUnwrap(weighedSnapshotValue)
        XCTAssertEqual(weighedSnapshot, eagerSnapshot)
        XCTAssertEqual(weighedSnapshot.tipHash, candidateHash)

        // The discriminator between the tiers: the eager tier executes the
        // transition and materializes the post-state; the weighed tier executes
        // nothing and materializes nothing. (This candidate happens to carry no
        // state-changing transactions, so both diffs are empty — the observable
        // difference is that eager still computed and materialized the state.)
        XCTAssertNil(weighed.materializedPostState)
        XCTAssertNotNil(eager.materializedPostState)
        XCTAssertEqual(weighedAcceptance.stateDiff, StateDiff.empty)

        // Both tiers record the same declared block fact — same block hash, the
        // same declared `postStateCID` claim, height, and target — differing
        // only in the (materialized) stateDiff. Header claim identical; only
        // execution is deferred.
        func blockFact(_ acceptance: ChainAcceptance) -> ChainBlockFact? {
            for case .block(let fact) in acceptance.facts.facts { return fact }
            return nil
        }
        let eagerBlockFact = try XCTUnwrap(blockFact(eagerAcceptance))
        let weighedBlockFact = try XCTUnwrap(blockFact(weighedAcceptance))
        XCTAssertEqual(weighedBlockFact.blockHash, eagerBlockFact.blockHash)
        XCTAssertEqual(weighedBlockFact.postStateCID, eagerBlockFact.postStateCID)
        XCTAssertEqual(weighedBlockFact.blockHeight, eagerBlockFact.blockHeight)
        XCTAssertEqual(weighedBlockFact.target, eagerBlockFact.target)
        XCTAssertEqual(weighedBlockFact.prevStateCID, eagerBlockFact.prevStateCID)
        XCTAssertEqual(weighedBlockFact.stateDiff, StateDiff.empty)
    }

    func testWeighedAdmissionStoresOnlyBlockBoundaryNotBody() async throws {
        // Tier-2 body deferral: a `.header` admission stores the block BOUNDARY
        // (root node + tx/children tries — so the block is servable and locally
        // present for fork choice) but MUST NOT resolve or store tier-3 (tx
        // bodies, validation-path states, WASM modules, genesis empty-state).
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [AdmissionFixture.signedStateChangingGenesisTransaction(
                key: "boundary-tx",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )],
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: fetcher
        )
        // The transaction changes state, so the post-state is a distinct, real
        // tier-3 Volume — not the empty state.
        XCTAssertNotEqual(candidate.postState.rawCID, candidate.prevState.rawCID)
        let candidateHash = try BlockHeader(node: candidate).rawCID

        // A fresh store receives ONLY what the weighed admission chooses to store.
        let boundaryStore = StorableFetcher()
        let weighed = try await AdmissionFixture.makeLevel(genesis: genesis).admit(
            candidate,
            mode: .header,
            fetcher: fetcher,
            storer: boundaryStore,
            materialized: NoopStorer()
        )
        guard case .accepted = weighed else {
            return XCTFail("weighed admission must accept, got \(weighed)")
        }

        // The block boundary is present (servable/possessable at tier-2)...
        XCTAssertTrue(boundaryStore.contains(rawCid: candidateHash))
        // ...while every tier-3 body Volume is absent: chain spec, and both the
        // prev and post validation-path states.
        XCTAssertFalse(boundaryStore.contains(rawCid: candidate.spec.rawCID))
        XCTAssertFalse(boundaryStore.contains(rawCid: candidate.prevState.rawCID))
        XCTAssertFalse(boundaryStore.contains(rawCid: candidate.postState.rawCID))

        // The stored boundary is complete: reading it back over the boundary
        // store alone succeeds (a body-less store still serves the boundary).
        try await BlockHeader(node: candidate).storeBlockBoundary(
            fetcher: boundaryStore,
            storer: NoopStorer()
        )
    }

    func testWeighedCompletesWithBodylessFetcherWhileEagerFails() async throws {
        // The bandwidth payoff, proven as a differential: a fetcher that serves
        // ONLY the block boundary (root + tries) and has NO tx bodies / states /
        // spec lets a weighed admission COMPLETE, but makes the same block's
        // eager admission FAIL — the weighed path genuinely never touched tier-3.
        let full = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: full, timestamp: 1_000)
        let candidate = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [AdmissionFixture.signedStateChangingGenesisTransaction(
                key: "bodyless-tx",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )],
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: full
        )
        let header = try BlockHeader(node: candidate)

        // A fetcher holding ONLY block boundaries and the chain spec — what any
        // node holds after weighing the parent and bootstrapping its genesis —
        // and no body.
        let bodyless = StorableFetcher()
        try await header.storeBlockBoundary(fetcher: full, storer: bodyless)
        try await BlockHeader(node: genesis).storeBlockBoundary(fetcher: full, storer: bodyless)
        bodyless.store(
            rawCid: genesis.spec.rawCID,
            data: try await full.fetch(rawCid: genesis.spec.rawCID)
        )

        // Weighed admission succeeds against the body-less fetcher.
        let weighed = try await AdmissionFixture.makeLevel(genesis: genesis).admit(
            header,
            mode: .header,
            fetcher: bodyless,
            storer: NoopStorer()
        )
        guard case .accepted = weighed else {
            return XCTFail("weighed admission must accept with a body-less fetcher, got \(weighed)")
        }

        // The SAME block admitted eager against the SAME body-less fetcher fails:
        // eager resolves and executes tier-3, which the fetcher cannot serve.
        let eager = try await AdmissionFixture.makeLevel(genesis: genesis).admit(
            header,
            fetcher: bodyless,
            storer: NoopStorer()
        )
        guard case .rejected = eager else {
            return XCTFail("eager admission must fail with a body-less fetcher, got \(eager)")
        }
        XCTAssertEqual(eager.failure, .unavailableEvidence)
    }

    /// A PoW-valid (easy target) re-header of `valid` with one linkage field
    /// changed, stored so admission can resolve it.
    private func storeVariant(
        of valid: Block,
        fetcher: StorableFetcher,
        height: UInt64? = nil,
        nextTarget: UInt256? = nil,
        spec: VolumeImpl<ChainSpec>? = nil,
        prevState: LatticeStateHeader? = nil
    ) async throws -> Block {
        try await storeBuiltBlock(Block(
            version: valid.version,
            parent: valid.parent,
            transactions: valid.transactions,
            target: valid.target,
            nextTarget: nextTarget ?? valid.nextTarget,
            spec: spec ?? valid.spec,
            parentState: valid.parentState,
            prevState: prevState ?? valid.prevState,
            postState: valid.postState,
            children: valid.children,
            height: height ?? valid.height,
            timestamp: valid.timestamp,
            nonce: valid.nonce
        ), in: fetcher)
    }

    func testWeighedAdmissionRejectsHeadersThatDoNotLinkToTheirParent() async throws {
        // Weighed = possess + structurally verify. Work alone binds nothing to
        // the parent: a peer can grind one trivial hash over the tip with any
        // height, prevState, spec or nextTarget. Each is a completed
        // deterministic check the weighed tier must reject exactly like the
        // eager path — never admitted, never indexed, never in fork choice.
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let valid = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [AdmissionFixture.signedStateChangingGenesisTransaction(
                key: "linkage-tx",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )],
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: fetcher
        )
        XCTAssertNotEqual(valid.prevState.rawCID, valid.postState.rawCID)
        let foreignSpec = ChainSpec.test(halfLife: 6)

        let variants: [(String, Block)] = [
            ("height tip+2", try await storeVariant(
                of: valid, fetcher: fetcher, height: valid.height + 1
            )),
            ("height UInt64.max", try await storeVariant(
                of: valid, fetcher: fetcher, height: UInt64.max
            )),
            ("prevState != parent.postState", try await storeVariant(
                of: valid, fetcher: fetcher, prevState: valid.postState
            )),
            ("spec differs from parent", try await storeVariant(
                of: valid, fetcher: fetcher,
                spec: try VolumeImpl<ChainSpec>(node: foreignSpec)
            )),
            ("nextTarget off schedule", try await storeVariant(
                of: valid, fetcher: fetcher, nextTarget: valid.nextTarget - UInt256(1)
            )),
        ]
        for (name, variant) in variants {
            let header = try BlockHeader(node: variant)
            XCTAssertTrue(variant.validateProofOfWork(nexusHash: variant.proofOfWorkHash()), name)
            for mode in [ImportMode.header, .full] {
                let level = AdmissionFixture.makeLevel(genesis: genesis)
                let result = try await level.admit(header, mode: mode, fetcher: fetcher)
                XCTAssertEqual(result.failure, .protocolInvalid, "\(name) \(mode)")
                let inserted = await level.chain.contains(blockHash: header.rawCID)
                XCTAssertFalse(inserted, "\(name) \(mode)")
            }
        }

        // The control: the correctly linked block is still weighed in without
        // being executed.
        let accepted = try await AdmissionFixture.makeLevel(genesis: genesis).admit(
            valid,
            mode: .header,
            fetcher: fetcher
        )
        guard case .accepted = accepted else {
            return XCTFail("linked block must be weighed in, got \(accepted)")
        }
        XCTAssertNil(accepted.materializedPostState)
    }

    func testWeighedAdmissionRejectsATargetEasierThanTheSchedule() async throws {
        // A target easier than the parent's schedule is trivially satisfied by
        // one hash; the weighed tier must reject it like the eager path does.
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 1_000,
            target: AdmissionFixture.easy / UInt256(2),
            fetcher: fetcher
        )
        let tooEasy = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(tooEasy.target, genesis.nextTarget)
        let header = try BlockHeader(node: tooEasy)

        for mode in [ImportMode.header, .full] {
            let level = AdmissionFixture.makeLevel(genesis: genesis)
            let result = try await level.admit(header, mode: mode, fetcher: fetcher)
            XCTAssertEqual(result.failure, .protocolInvalid, "\(mode)")
            let inserted = await level.chain.contains(blockHash: header.rawCID)
            XCTAssertFalse(inserted, "\(mode)")
        }
    }

    func testWeighedNotYetAdmissibleCandidateIsDeferredNotRejected() async throws {
        // The timestamp rule is node-local and retriable: a weighed block from
        // the near future defers exactly as it does eagerly, never excludes.
        let fetcher = StorableFetcher()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: now - 100_000)
        let future = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: now + 60_000,
            nonce: 1
        )
        let header = try BlockHeader(node: future)

        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let result = try await level.admit(header, mode: .header, fetcher: fetcher)

        XCTAssertEqual(result.failure, .notYetValid)
        let inserted = await level.chain.contains(blockHash: header.rawCID)
        XCTAssertFalse(inserted)
    }

    func testWeighedAdmissionNeverAcceptsAGenesis() async throws {
        // A genesis is only ever admitted eagerly via bootstrap (self/pinned);
        // a network-weighed parentless header has nothing to link to.
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let rival = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let header = try BlockHeader(node: rival)

        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let result = try await level.admit(header, mode: .header, fetcher: fetcher)

        XCTAssertEqual(result.failure, .protocolInvalid)
        let inserted = await level.chain.contains(blockHash: header.rawCID)
        XCTAssertFalse(inserted)
    }

    func testWeighedChildAdmissionRunsTheSameHeaderLinkage() async throws {
        // A child block's securing proof binds it to a parent grind, not to its
        // own predecessor: the weighed tier must run the same same-chain header
        // linkage for children as for roots.
        let fetcher = StorableFetcher()
        let parentGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let childPath = [DEFAULT_ROOT_DIRECTORY, "Child"]
        let valid = try await buildAndStoreBlock(
            previous: childGenesis,
            transactions: [AdmissionFixture.signedStateChangingGenesisTransaction(
                key: "child-linkage-tx",
                chainPath: childPath
            )],
            parentChainBlock: parentGenesis,
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: fetcher
        )
        XCTAssertNotEqual(valid.prevState.rawCID, valid.postState.rawCID)

        // Each variant is co-mined into its own carrier so its securing proof
        // verifies; only the same-chain linkage is wrong.
        func packaged(_ child: Block, nonce: UInt64) async throws -> ChildValidationPackage {
            let carrier = try await buildAndStoreGenesis(
                spec: chainLocalSpec(),
                children: ["Child": child],
                timestamp: 3_000,
                target: AdmissionFixture.easy,
                nonce: nonce,
                fetcher: fetcher
            )
            return try await childValidationPackage(
                proof: try await ChildBlockProof.generate(
                    rootHeader: try BlockHeader(node: carrier),
                    childDirectory: "Child",
                    fetcher: fetcher
                ),
                fetcher: fetcher
            )
        }
        func childLevel() -> ChainLevel {
            ChainLevel(
                chain: ChainState.fromGenesis(block: childGenesis),
                context: testChainContext(path: childPath)
            )
        }

        let variants: [(String, Block)] = [
            ("height tip+2", try await storeVariant(
                of: valid, fetcher: fetcher, height: valid.height + 1
            )),
            ("prevState != parent.postState", try await storeVariant(
                of: valid, fetcher: fetcher, prevState: valid.postState
            )),
        ]
        for (index, (name, variant)) in variants.enumerated() {
            let header = try BlockHeader(node: variant)
            let level = childLevel()
            let result = try await level.admit(
                header,
                mode: .header,
                fetcher: fetcher,
                childPackage: try await packaged(variant, nonce: UInt64(10 + index))
            )
            XCTAssertEqual(result.failure, .protocolInvalid, name)
            let inserted = await level.chain.contains(blockHash: header.rawCID)
            XCTAssertFalse(inserted, name)
        }

        let accepted = try await childLevel().admit(
            valid,
            mode: .header,
            fetcher: fetcher,
            childPackage: try await packaged(valid, nonce: 20)
        )
        guard case .accepted = accepted else {
            return XCTFail("linked child must be weighed in, got \(accepted)")
        }
        XCTAssertNil(accepted.materializedPostState)
    }

    func testProvenInvalidBlockRequestsNoPredecessor() async throws {
        // A completed deterministic verdict must not ask the node to acquire
        // the block's predecessor: the node tests `.predecessor` before
        // `.terminal`, so a proven-invalid block over an unheld parent would
        // otherwise be parked and its attacker-served predecessor seeded —
        // recursing down a fabricated chain one park slot per junk block.
        // The carrier relay stays: the grind may still carry descendant work.
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let unheld = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let valid = try await AdmissionFixture.makeChild(of: unheld, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let invalid = try await storeVariant(
            of: valid, fetcher: fetcher, height: valid.height + 1
        )
        let header = try BlockHeader(node: invalid)

        for mode in [ImportMode.header, .full] {
            let result = try await AdmissionFixture.makeLevel(genesis: genesis).admit(
                header,
                mode: mode,
                fetcher: fetcher
            )
            XCTAssertEqual(result.failure, .protocolInvalid, "\(mode)")
            XCTAssertNil(result.sameChainPredecessor, "\(mode)")
            XCTAssertEqual(result.parentCarrierLink?.carrierCID, header.rawCID, "\(mode)")
        }
    }

    func testWeighedMissingParentIsUnavailableWithPredecessorRequirement() async throws {
        // The parent's root node is the one thing header linkage needs that a
        // boundary-only possession may lack. Its absence is availability, not
        // a verdict: retry, and name the exact predecessor to acquire.
        let full = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: full, timestamp: 1_000)
        let parent = try await AdmissionFixture.makeChild(of: genesis, fetcher: full, timestamp: 2_000, nonce: 1)
        let candidate = try await AdmissionFixture.makeChild(of: parent, fetcher: full, timestamp: 3_000, nonce: 2)
        let header = try BlockHeader(node: candidate)

        // Candidate boundary + chain spec only; the parent root is absent.
        let parentless = StorableFetcher()
        try await header.storeBlockBoundary(fetcher: full, storer: parentless)
        parentless.store(
            rawCid: genesis.spec.rawCID,
            data: try await full.fetch(rawCid: genesis.spec.rawCID)
        )

        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let result = try await level.admit(header, mode: .header, fetcher: parentless)

        XCTAssertEqual(result.failure, .unavailableEvidence)
        XCTAssertEqual(result.sameChainPredecessor, SameChainPredecessorRequirement(
            descendantCID: header.rawCID,
            predecessorCID: try BlockHeader(node: parent).rawCID
        ))
        let inserted = await level.chain.contains(blockHash: header.rawCID)
        XCTAssertFalse(inserted)
    }

    func testWeighedCandidateOverAnUnknownParentParksWithoutWalkingItsAncestry() async throws {
        // Genesis -> B1...B5 are all held, but the level knows only genesis.
        // B5's anchor is not answerable from the graph (neither B4 nor B3 is
        // in it), so admission parks on B4 rather than walking B3, B2, B1
        // through the fetcher: each hop would be one network request per
        // out-of-order block, and none of those hops is checked for work.
        let full = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: full, timestamp: 1_000)
        var blocks: [Block] = []
        var previous = genesis
        for i in 1...5 {
            let block = try await AdmissionFixture.makeChild(
                of: previous, fetcher: full, timestamp: 1_000 + Int64(i) * 1_000, nonce: UInt64(i)
            )
            blocks.append(block)
            previous = block
        }
        let cids = try blocks.map { try BlockHeader(node: $0).rawCID }
        let recording = RecordingFetcher(backing: full)

        let result = try await AdmissionFixture.makeLevel(genesis: genesis).admit(
            BlockHeader(rawCID: cids[4]), mode: .header, fetcher: recording, storer: full
        )

        XCTAssertEqual(result.failure, .unavailableEvidence)
        XCTAssertEqual(result.sameChainPredecessor, SameChainPredecessorRequirement(
            descendantCID: cids[4], predecessorCID: cids[3]
        ))
        let fetched = await recording.fetched
        XCTAssertEqual(
            Set(fetched), [cids[4], cids[3], genesis.spec.rawCID],
            "B5's boundary, B4's root and the spec, and nothing below B4"
        )
        XCTAssertEqual(fetched.count, 3, "\(fetched)")
    }

    func testForgedAncestryUnderATriviallyMinedCandidateParksAtBoundedCost() async throws {
        // A forged ancestry: blocks that carry no proof of work, each
        // committing `nextTarget = max`, so the candidate on top declares the
        // maximum target and its own PoW is free. Admitting it must cost the
        // same few fetches however long the forged chain is -- nothing walks
        // attacker-served links.
        func admitOverForgedAncestry(length: Int) async throws -> (BlockImportResult, predecessor: String, fetches: Int) {
            let full = StorableFetcher()
            let genesis = try await AdmissionFixture.makeGenesis(fetcher: full, timestamp: 1_000)
            var previous = genesis
            for i in 1...length {
                previous = try await buildAndStoreBlock(
                    previous: previous, timestamp: 1_000 + Int64(i) * 1_000,
                    target: UInt256(1), nextTarget: .max, nonce: UInt64(i), fetcher: full
                )
                XCTAssertFalse(previous.validateProofOfWork(nexusHash: previous.proofOfWorkHash()))
            }
            let candidate = try await buildAndStoreBlock(
                previous: previous, timestamp: previous.timestamp + 1_000,
                target: .max, nextTarget: .max, nonce: 0, fetcher: full
            )
            XCTAssertTrue(candidate.validateProofOfWork(nexusHash: candidate.proofOfWorkHash()))
            let recording = RecordingFetcher(backing: full)
            let result = try await AdmissionFixture.makeLevel(genesis: genesis).admit(
                BlockHeader(rawCID: try BlockHeader(node: candidate).rawCID),
                mode: .header, fetcher: recording, storer: full
            )
            return (result, try BlockHeader(node: previous).rawCID, await recording.fetched.count)
        }

        let short = try await admitOverForgedAncestry(length: 4)
        let long = try await admitOverForgedAncestry(length: 32)
        for (outcome, label) in [(short, "4"), (long, "32")] {
            XCTAssertEqual(outcome.0.failure, .unavailableEvidence, label)
            XCTAssertEqual(outcome.0.sameChainPredecessor?.predecessorCID, outcome.predecessor, label)
            XCTAssertLessThanOrEqual(outcome.fetches, 3, label)
        }
        XCTAssertEqual(short.fetches, long.fetches, "the cost must not depend on the forged depth")
    }

    func testWeighedCandidateOverAHeightOneParentAnchorsOnIt() async throws {
        // B2 over a B1 the level does not hold: B1, already fetched for
        // linkage, is itself the anchor, so B2 is weighed in as a side block
        // awaiting B1 -- the out-of-order carried shape.
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let blockOne = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let blockTwo = try await AdmissionFixture.makeChild(of: blockOne, fetcher: fetcher, timestamp: 3_000, nonce: 2)

        let result = try await AdmissionFixture.makeLevel(genesis: genesis).admit(
            blockTwo, mode: .header, fetcher: fetcher
        )

        guard case .accepted = result else {
            return XCTFail("a height-1 parent anchors its child, got \(result)")
        }
        XCTAssertEqual(
            result.sameChainPredecessor?.predecessorCID,
            try BlockHeader(node: blockOne).rawCID
        )
    }

    // MARK: - Liveness: a parked anchor resolves once the ancestry connects

    /// Builds genesis -> B1...B(count), all held in `fetcher`, with timestamps
    /// 1_000 apart, and the anchor every one of them must resolve to.
    private func heldChain(
        count: Int, fetcher: StorableFetcher
    ) async throws -> (genesis: Block, blocks: [Block], cids: [String], anchor: DifficultyAnchor) {
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        var blocks: [Block] = []
        var previous = genesis
        for i in 1...count {
            previous = try await AdmissionFixture.makeChild(
                of: previous, fetcher: fetcher, timestamp: 1_000 + Int64(i) * 1_000, nonce: UInt64(i)
            )
            blocks.append(previous)
        }
        let cids = try blocks.map { try BlockHeader(node: $0).rawCID }
        let anchor = DifficultyAnchor(
            blockHeight: 1, timestamp: blocks[0].timestamp, target: blocks[0].target
        )
        return (genesis, blocks, cids, anchor)
    }

    func testParkedCandidateIsAdmittedOnceItsAncestryConnects() async throws {
        // B5 parks while only genesis is known. After B1...B4 are admitted in
        // order, re-admitting the same B5 must be accepted and inherit block
        // one's anchor. Parking is only safe if it is never permanent.
        let fetcher = StorableFetcher()
        let held = try await heldChain(count: 5, fetcher: fetcher)
        let level = AdmissionFixture.makeLevel(genesis: held.genesis)

        let parked = try await level.admit(held.blocks[4], mode: .header, fetcher: fetcher)
        XCTAssertEqual(parked.failure, .unavailableEvidence)
        XCTAssertEqual(parked.sameChainPredecessor?.predecessorCID, held.cids[3])

        for (block, cid) in zip(held.blocks.prefix(4), held.cids) {
            let result = try await level.admit(block, mode: .header, fetcher: fetcher)
            guard case .accepted = result else {
                return XCTFail("B\(block.height) extends the chain, got \(result)")
            }
            XCTAssertNil(result.sameChainPredecessor, "B\(block.height) \(cid) is connected")
        }

        let readmitted = try await level.admit(held.blocks[4], mode: .header, fetcher: fetcher)
        guard case .accepted = readmitted else {
            return XCTFail("B5 must be admitted once B4 connects, got \(readmitted)")
        }
        XCTAssertNil(readmitted.sameChainPredecessor)
        let anchor = await level.chain.difficultyAnchor(forBlockHash: held.cids[4])
        XCTAssertEqual(anchor, held.anchor, "B5 inherits block one's anchor")
    }

    func testCandidateOverAHeldButDisconnectedParentIsAdmittedOnceThatParentConnects() async throws {
        // B2 is weighed in over a missing B1 (its height-1 parent anchors it),
        // so B2 is HELD but DISCONNECTED and carries no anchor. B3 over B2
        // cannot resolve one (B2 has none, B1 is not in the graph) and parks
        // on B2. Once B1 arrives, the lazy backfill in
        // `ChainState.difficultyAnchor` answers for B2, and B3 is accepted.
        let fetcher = StorableFetcher()
        let held = try await heldChain(count: 3, fetcher: fetcher)
        let level = AdmissionFixture.makeLevel(genesis: held.genesis)

        let blockTwo = try await level.admit(held.blocks[1], mode: .header, fetcher: fetcher)
        guard case .accepted = blockTwo else {
            return XCTFail("B2 over a height-1 parent is weighed in, got \(blockTwo)")
        }
        XCTAssertEqual(blockTwo.sameChainPredecessor?.predecessorCID, held.cids[0])
        let disconnectedAnchor = await level.chain.difficultyAnchor(forBlockHash: held.cids[1])
        XCTAssertNil(disconnectedAnchor, "a disconnected B2 has no anchor to inherit")

        let parked = try await level.admit(held.blocks[2], mode: .header, fetcher: fetcher)
        XCTAssertEqual(parked.failure, .unavailableEvidence)
        XCTAssertEqual(parked.sameChainPredecessor?.predecessorCID, held.cids[1])

        let blockOne = try await level.admit(held.blocks[0], mode: .header, fetcher: fetcher)
        guard case .accepted = blockOne else {
            return XCTFail("B1 extends genesis, got \(blockOne)")
        }

        let readmitted = try await level.admit(held.blocks[2], mode: .header, fetcher: fetcher)
        guard case .accepted = readmitted else {
            return XCTFail("B3 must be admitted once B2 connects, got \(readmitted)")
        }
        XCTAssertNil(readmitted.sameChainPredecessor)
        let backfilled = await level.chain.difficultyAnchor(forBlockHash: held.cids[1])
        XCTAssertEqual(backfilled, held.anchor, "B2's anchor is backfilled from B1")
        let inherited = await level.chain.difficultyAnchor(forBlockHash: held.cids[2])
        XCTAssertEqual(inherited, held.anchor, "B3 inherits block one's anchor")
    }

    func testRestoredOrphanResolvesItsAnchorOnceItsAncestryIsReplayed() async throws {
        // Restore replays facts in the order they were written, so an orphan
        // (B2 recorded before B1) comes back without an anchor. Replaying B1
        // after it connects the orphan: the anchor lookup resolves and B3 over
        // B2 is accepted. The control restore without B1 parks B3 on B2.
        let fetcher = StorableFetcher()
        let held = try await heldChain(count: 3, fetcher: fetcher)
        let genesisBatch = try testAdmissionBatch(for: held.genesis)
        let orphanBatch = try testAdmissionBatch(for: held.blocks[1])
        let connectingBatch = try testAdmissionBatch(for: held.blocks[0])

        let orphaned = ChainLevel(testChain: try await ChainState.restore(
            replaying: [genesisBatch, orphanBatch]
        ))
        let orphanAnchor = await orphaned.chain.difficultyAnchor(forBlockHash: held.cids[1])
        XCTAssertNil(orphanAnchor, "control: the replayed orphan has no anchor")
        let parked = try await orphaned.admit(held.blocks[2], mode: .header, fetcher: fetcher)
        XCTAssertEqual(parked.failure, .unavailableEvidence)
        XCTAssertEqual(parked.sameChainPredecessor?.predecessorCID, held.cids[1])

        let connected = ChainLevel(testChain: try await ChainState.restore(
            replaying: [genesisBatch, orphanBatch, connectingBatch]
        ))
        let resolved = await connected.chain.difficultyAnchor(forBlockHash: held.cids[1])
        XCTAssertEqual(resolved, held.anchor, "the replayed B1 connects the orphan B2")
        let accepted = try await connected.admit(held.blocks[2], mode: .header, fetcher: fetcher)
        guard case .accepted = accepted else {
            return XCTFail("B3 over the connected B2 is accepted, got \(accepted)")
        }
        XCTAssertNil(accepted.sameChainPredecessor)
    }

    func testWeighedAdmissionIssuesNoCrossChainFacts() async throws {
        // Deferred-execution safety: a weighed (not-yet-executed) child block
        // must issue NO carrier link and NO parent-genesis link, because a child
        // consuming such a fact would bind to unvalidated — possibly invalid or
        // soon-reorged — parent state. The identical EAGER admission issues both
        // (see testPreflightCommitPromotesCarrierLinkAfterPredecessorConnects),
        // so this pins the suppression that gates issuance to the validated tier.
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let predecessor = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let descendant = try await AdmissionFixture.makeChild(
            of: predecessor,
            fetcher: fetcher,
            timestamp: 3_000,
            nonce: 2
        )
        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let predecessorHeader = try BlockHeader(node: predecessor)
        let descendantHeader = try BlockHeader(node: descendant)

        let preflightResult = try await level.preflightBlockImport(
            descendantHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            mode: .header
        )
        guard case .ready(let preflight) = preflightResult else {
            return XCTFail("valid weighed descendant must produce a commit token")
        }

        _ = try await level.admit(predecessorHeader, fetcher: fetcher)
        let recorder = AdmissionStageRecorder()
        let committed = try await level.commitPreflight(
            preflight,
            materializedVolumeStorer: fetcher,
            stage: { context in await recorder.stage(context) }
        )

        XCTAssertNotNil(committed.commit)
        let stagedContexts = await recorder.recordedContexts()
        let stagedContext = try XCTUnwrap(stagedContexts.first)
        XCTAssertNil(
            stagedContext.issuedCarrierLink,
            "weighed admission must not issue a carrier link"
        )
        XCTAssertTrue(
            stagedContext.parentGenesisLinks.isEmpty,
            "weighed admission must not issue parent-genesis links"
        )
    }
}

/// Records every CID fetched, in order, so a test can name exactly which
/// objects an admission read.
private actor RecordingFetcher: Fetcher {
    let backing: StorableFetcher
    private(set) var fetched: [String] = []

    init(backing: StorableFetcher) {
        self.backing = backing
    }

    func fetch(rawCid: String) async throws -> Data {
        fetched.append(rawCid)
        return try await backing.fetch(rawCid: rawCid)
    }
}
