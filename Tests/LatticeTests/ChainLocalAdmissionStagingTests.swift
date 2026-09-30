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

private struct FailingVolumeAdmissionStorer: Storer, VolumeStorer {
    func store(entries: [String: Data]) async throws {}

    func store(volume: SerializedVolume) async throws {
        throw ChainLocalTestError.storageFailure
    }
}

private actor StorageBarrier: Storer, VolumeStorer {
    private let backing: StorableFetcher
    private var arrivals = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(backing: StorableFetcher) {
        self.backing = backing
    }

    func store(entries: [String: Data]) async throws {
        arrivals += 1
        if !released {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        await backing.store(entries: entries)
    }

    func store(volume: SerializedVolume) async throws {
        arrivals += 1
        if !released {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        await backing.store(volume: volume)
    }

    func arrivalCount() -> Int {
        arrivals
    }

    func release() {
        released = true
        let waiting = waiters
        waiters.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

final class ChainLocalAdmissionStagingTests: XCTestCase {
    func testStorageAndStageFailuresLeaveNoVisibleMutation() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let beforeTip = await level.chain.canonicalTip
        let candidateHash = try BlockHeader(node: candidate).rawCID

        do {
            _ = try await level.admit(
                candidate,
                fetcher: fetcher,
                storer: FailingAdmissionStorer()
            )
            XCTFail("storage failure must abort admission")
        } catch ChainLocalTestError.storageFailure {}

        do {
            _ = try await level.admit(
                candidate,
                fetcher: fetcher,
                storer: FailingVolumeAdmissionStorer()
            )
            XCTFail("Volume storage failure must abort admission")
        } catch ChainLocalTestError.storageFailure {}

        do {
            _ = try await level.admit(
                candidate,
                fetcher: fetcher,
                stage: { _ in throw ChainLocalTestError.stageFailure }
            )
            XCTFail("node durability failure must abort admission")
        } catch ChainLocalTestError.stageFailure {}

        let afterTip = await level.chain.canonicalTip
        let containsCandidate = await level.chain.contains(blockHash: candidateHash)
        XCTAssertEqual(afterTip, beforeTip)
        XCTAssertFalse(containsCandidate)
    }

    func testAdmissionStagesBlockWithInitialWorkThenOnlyNewGrind() async throws {
        let fixture = try await AdmissionFixture.makeChildProofFixture()
        let alternateCarrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": fixture.candidate],
            timestamp: 4_000,
            target: AdmissionFixture.easy,
            nonce: 4,
            fetcher: fixture.fetcher
        )
        let alternateProof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: alternateCarrier),
            childDirectory: "Child",
            fetcher: fixture.fetcher
        )
        let recorder = AdmissionStageRecorder()
        let header = try BlockHeader(node: fixture.candidate)

        let initial = try await fixture.childLevel.admit(
            header,
            fetcher: fixture.fetcher,
            childPackage: fixture.package,
            stage: { context in await recorder.stage(context) }
        )
        let later = try await fixture.childLevel.admit(
            header,
            fetcher: fixture.fetcher,
            childPackage: try await childValidationPackage(
                proof: alternateProof,
                fetcher: fixture.fetcher
            ),
            stage: { context in await recorder.stage(context) }
        )

        guard case .accepted = initial, case .accepted = later else {
            return XCTFail("both distinct grinds should be accepted")
        }
        let batches = await recorder.recordedBatches()
        XCTAssertEqual(batches.count, 2)
        guard batches.count == 2,
              // block + work + validation from the eager tier; the later grind
              // stages work alone.
              batches[0].facts.count == 3,
              case .block(let blockFact) = batches[0].facts[0],
              case .work(let initialWork) = batches[0].facts[1],
              case .validation = batches[0].facts[2],
              batches[1].facts.count == 1,
              case .work(let laterWork) = batches[1].facts[0] else {
            return XCTFail("expected one atomic block/work batch and one work-only batch")
        }
        XCTAssertEqual(blockFact.blockHash, header.rawCID)
        XCTAssertEqual(initialWork.blockHash, header.rawCID)
        XCTAssertEqual(initialWork.contribution.id, fixture.package.proof.rootCID)
        XCTAssertEqual(
            batches[0].facts[1].id,
            .work(
                blockHash: header.rawCID,
                grindID: fixture.package.proof.rootCID,
                work: initialWork.contribution.work.toHexString()
            )
        )
        XCTAssertEqual(laterWork.blockHash, header.rawCID)
        XCTAssertEqual(laterWork.contribution.id, alternateProof.rootCID)
        XCTAssertEqual(
            batches[1].facts[0].id,
            .work(
                blockHash: header.rawCID,
                grindID: alternateProof.rootCID,
                work: laterWork.contribution.work.toHexString()
            )
        )
        let contexts = await recorder.recordedContexts()
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(contexts[1].batch, batches[1])
        XCTAssertEqual(
            contexts[1].issuedCarrierLink?.parentPath,
            [DEFAULT_ROOT_DIRECTORY, "Child"]
        )
        XCTAssertEqual(contexts[1].issuedCarrierLink?.carrierCID, header.rawCID)
        XCTAssertEqual(contexts[1].issuedCarrierLink?.rootCID, alternateProof.rootCID)
        XCTAssertTrue(contexts[1].parentGenesisLinks.isEmpty)
    }

    func testReplayIsDuplicateAndDoesNotRestage() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let recorder = AdmissionStageRecorder()
        let header = try BlockHeader(node: candidate)

        _ = try await level.admit(
            header,
            fetcher: fetcher,
            stage: { record in await recorder.stage(record) }
        )

        let replay = try await level.admit(
            header,
            fetcher: fetcher,
            stage: { record in await recorder.stage(record) }
        )

        guard case .duplicate = replay else {
            return XCTFail("known consensus facts must remain duplicate")
        }
        let stageCount = await recorder.count(for: header.rawCID)
        XCTAssertEqual(stageCount, 1)
    }

    func testAcceptedOrphanReportsItsSameChainPredecessor() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let missingParent = try await AdmissionFixture.makeChild(
            of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1
        )
        let childGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 9
        )
        let childCID = try BlockHeader(node: childGenesis).rawCID
        let keyPair = CryptoUtils.generateKeyPair()
        let owner = testAddress(publicKey: keyPair.publicKey)
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [GenesisAction(
                directory: "Child",
                blockCID: childCID
            )],
            receiptActions: [],
            withdrawalActions: [],
            signers: [owner],
            nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let orphan = try await buildAndStoreBlock(
            previous: missingParent,
            transactions: [signedTestTransaction(body, by: keyPair)],
            timestamp: 3_000,
            target: AdmissionFixture.easy,
            nonce: 2,
            rewardRecipient: owner,
            fetcher: fetcher
        )
        let orphanHeader = try BlockHeader(node: orphan)
        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let recorder = AdmissionStageRecorder()

        let result = try await level.admit(
            orphanHeader,
            fetcher: fetcher,
            stage: { context in await recorder.stage(context) }
        )

        guard case .accepted = result else {
            return XCTFail("expected valid orphan side admission, got \(result)")
        }
        let missingPredecessorCID = try BlockHeader(node: missingParent).rawCID
        XCTAssertEqual(
            result.sameChainPredecessor,
            SameChainPredecessorRequirement(
                descendantCID: orphanHeader.rawCID,
                predecessorCID: missingPredecessorCID
            )
        )
        XCTAssertNil(result.crossChainEvidenceRequirement)
        XCTAssertEqual(result.parentCarrierLink?.carrierCID, orphanHeader.rawCID)
        let orphanContexts = await recorder.recordedContexts()
        let orphanContext = try XCTUnwrap(orphanContexts.first)
        XCTAssertNil(orphanContext.issuedCarrierLink)
        // Executed ahead of its ancestry, the orphan is not in the executed
        // set, so it issues no genesis link yet; the duplicate below issues it
        // once the ancestry connects and executes.
        XCTAssertEqual(orphanContext.parentGenesisLinks.count, 0)

        _ = try await level.admit(missingParent, fetcher: fetcher)
        let replay = try await level.preflightBlockImport(
            orphanHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher
        )
        guard case .duplicate(let preflight) = replay else {
            return XCTFail("replayed connected orphan must remain duplicate")
        }
        let promoted = try await level.resolveDuplicatePreflight(preflight)
        XCTAssertNil(promoted.result.sameChainPredecessor)
        XCTAssertEqual(
            promoted.result.parentCarrierLink?.carrierCID,
            orphanHeader.rawCID
        )
        XCTAssertEqual(
            promoted.parentGenesisLinks.first?.childGenesisCID,
            childCID
        )
    }

    func testDuplicateReadmissionPromotesSideBlockThatBecomesHeaviest() async throws {
        // A cold-syncing host can accept a block into the graph a moment before
        // the fork-choice landscape that makes it canonical is complete, so it is
        // stored as a weightless side block. When the completing evidence lands,
        // the block is re-admitted; because it carries no stronger work it is
        // classified a duplicate. The duplicate seam must still re-run the
        // existing fork choice, or the now-heaviest side block is never promoted.
        //
        // Pure sequential admission self-heals (a connecting mutation re-projects),
        // so the stranded landscape is reconstructed directly: a real, heavier
        // fork present in the durable graph while the canonical projection still
        // points at a lighter fork — exactly the state the node reaches when the
        // connecting mutation reaches the graph through the duplicate seam.
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let incumbent = try await AdmissionFixture.makeChild(
            of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1
        )
        let heavier1 = try await AdmissionFixture.makeChild(
            of: genesis, fetcher: fetcher, timestamp: 2_500, nonce: 2
        )
        let heavier2 = try await AdmissionFixture.makeChild(
            of: heavier1, fetcher: fetcher, timestamp: 3_500, nonce: 3
        )
        let genesisCID = try BlockHeader(node: genesis).rawCID
        let incumbentCID = try BlockHeader(node: incumbent).rawCID
        let heavier1CID = try BlockHeader(node: heavier1).rawCID
        let heavier2CID = try BlockHeader(node: heavier2).rawCID

        // Admit every block through the normal path so the graph records their
        // real, self-consistent work facts. This level self-heals to the heavier
        // fork; it is only a source of authentic block metadata.
        let source = AdmissionFixture.makeLevel(genesis: genesis)
        for block in [incumbent, heavier1, heavier2] {
            _ = try await source.admit(block, fetcher: fetcher)
        }
        func meta(_ hash: String) async throws -> BlockMeta {
            let stored = await source.chain.getConsensusBlock(hash: hash)
            return try XCTUnwrap(stored)
        }
        let metas = [
            try await meta(genesisCID),
            try await meta(incumbentCID),
            try await meta(heavier1CID),
            try await meta(heavier2CID)
        ]

        // Reconstruct the stranded landscape: the heavier fork is fully present in
        // the durable graph, but the canonical projection still points at the
        // lighter incumbent tip.
        let stranded = ChainLevel(testChain: makeChain(
            blocks: metas,
            canonicalHashes: [genesisCID, incumbentCID]
        ))
        let strandedTip = await stranded.chain.canonicalTip
        XCTAssertEqual(
            strandedTip, incumbentCID,
            "the stranded projection must start on the lighter fork"
        )

        // Re-admit the heaviest tip. It is already known with equal work, so it is
        // classified a duplicate. The seam re-runs fork choice and surfaces the
        // promotion. Pre-fix this returned `.duplicate` with a nil commit.
        let replay = try await stranded.preflightBlockImport(
            try BlockHeader(node: heavier2),
            fetcher: fetcher,
            validationContentStorer: fetcher
        )
        guard case .duplicate(let token) = replay else {
            return XCTFail("the known heavier tip must re-admit as a duplicate")
        }
        let promoted = try await stranded.resolveDuplicatePreflight(token)
        let commit = try XCTUnwrap(
            promoted.result.commit,
            "the duplicate seam must surface the fork-choice promotion"
        )
        XCTAssertTrue(commit.canonicalChanged)
        XCTAssertEqual(commit.tipHash, heavier2CID)
        let finalTip = await stranded.chain.canonicalTip
        XCTAssertEqual(finalTip, heavier2CID)
    }

    func testAdmissionReturnsExactChainLocalReorganization() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let main1 = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let main2 = try await AdmissionFixture.makeChild(of: main1, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let fork1 = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_500, nonce: 3)
        let fork2 = try await AdmissionFixture.makeChild(of: fork1, fetcher: fetcher, timestamp: 3_500, nonce: 4)
        let fork3 = try await AdmissionFixture.makeChild(of: fork2, fetcher: fetcher, timestamp: 4_500, nonce: 5)
        let level = AdmissionFixture.makeLevel(genesis: genesis)

        for block in [main1, main2] {
            _ = try await level.admit(block, fetcher: fetcher)
        }
        _ = try await level.admit(fork1, fetcher: fetcher)
        let fork2Result = try await level.admit(fork2, fetcher: fetcher)
        let fork3Result = try await level.admit(fork3, fetcher: fetcher)

        let main1Hash = try BlockHeader(node: main1).rawCID
        let fork1Hash = try BlockHeader(node: fork1).rawCID
        let forkWinsTie = forkChoicePrefersBlock(
            fork1Hash,
            over: main1Hash
        )
        let commit = try XCTUnwrap(
            forkWinsTie ? fork2Result.commit : fork3Result.commit
        )
        let winningPrefix = forkWinsTie ? [fork1, fork2] : [fork1, fork2, fork3]
        let forkHashes = try Set(winningPrefix.map { try BlockHeader(node: $0).rawCID })
        let mainHashes = try Set([main1, main2].map { try BlockHeader(node: $0).rawCID })
        XCTAssertEqual(
            commit.tipHash,
            try BlockHeader(node: forkWinsTie ? fork2 : fork3).rawCID
        )
        XCTAssertTrue(commit.canonicalChanged)
        XCTAssertEqual(Set(commit.canonicalBlocksAdded.keys), forkHashes)
        XCTAssertEqual(commit.canonicalBlocksRemoved, mainHashes)
        let finalTip = await level.chain.canonicalTip
        XCTAssertEqual(finalTip, try BlockHeader(node: fork3).rawCID)
    }

    func testStagedAdmissionSurvivesConcurrentMutationAndSourceLoss() async throws {
        let backing = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: backing, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: backing,
            timestamp: 2_000,
            nonce: 1
        )
        let sibling = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: backing,
            timestamp: 2_000,
            nonce: 2
        )
        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let genesisBatch = try testAdmissionBatch(for: genesis)
        let source = DenyingFetcher(backing: backing)
        let recorder = AdmissionStageRecorder()
        let candidateHeader = try BlockHeader(node: candidate)
        let unresolvedCandidate = BlockHeader(rawCID: candidateHeader.rawCID)
        let siblingHeader = try BlockHeader(node: sibling)

        let result = try await level.admit(
            unresolvedCandidate,
            fetcher: source,
            storer: backing,
            stage: { batch in
                await recorder.stage(batch)
                _ = await level.chain.submitTestBlock(
                    blockHeader: siblingHeader,
                    block: sibling
                )
                await source.denyAll()
            }
        )

        guard case .accepted = result else {
            return XCTFail("a staged fact must not reacquire its source")
        }
        let chain = await level.chain
        let containsCandidate = await chain.contains(blockHash: candidateHeader.rawCID)
        let stageCount = await recorder.count(for: candidateHeader.rawCID)
        XCTAssertTrue(containsCandidate)
        XCTAssertEqual(stageCount, 1)

        let restored = try await ChainState.restore(replaying:
            [genesisBatch] + (await recorder.recordedBatches())
        )
        let restoredCandidate = await restored.contains(blockHash: candidateHeader.rawCID)
        XCTAssertTrue(restoredCandidate)
    }

    func testStagedAdmissionReservesTheFinalCommitRevision() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let sibling = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2
        )
        let fixture = try await AdmissionFixture.makeLevel(genesis: genesis, revision: .max - 1)
        let recorder = AdmissionStageRecorder()
        let candidateHeader = try BlockHeader(node: candidate)
        let siblingHeader = try BlockHeader(node: sibling)

        let accepted = try await fixture.level.admit(
            candidateHeader,
            fetcher: fetcher,
            stage: { batch in
                await recorder.stage(batch)
                _ = await fixture.level.chain.submitTestBlock(
                    blockHeader: siblingHeader,
                    block: sibling
                )
            }
        )

        XCTAssertEqual(accepted.commit?.revision, .max)
        let containsCandidate = await fixture.level.chain.contains(
            blockHash: candidateHeader.rawCID
        )
        let containsSibling = await fixture.level.chain.contains(
            blockHash: siblingHeader.rawCID
        )
        XCTAssertTrue(containsCandidate)
        XCTAssertFalse(containsSibling)
        let batches = await recorder.recordedBatches()
        XCTAssertEqual(batches.count, 1)
        let restored = try await ChainState.restore(
            replaying: [fixture.seedBatch] + batches,
            revisionFloor: .max
        )
        let restoredTip = await restored.canonicalTip
        let liveTip = await fixture.level.chain.canonicalTip
        let restoredRevision = await restored.currentRevision()
        let liveRevision = await fixture.level.chain.currentRevision()
        XCTAssertEqual(restoredTip, liveTip)
        XCTAssertEqual(restoredRevision, liveRevision)

        let exhausted = try await fixture.level.admit(
            siblingHeader,
            fetcher: fetcher,
            stage: { batch in await recorder.stage(batch) }
        )
        XCTAssertEqual(exhausted.failure, .revisionExhausted)
        let exhaustedLink = try XCTUnwrap(exhausted.parentCarrierLink)
        XCTAssertEqual(exhaustedLink.carrierCID, siblingHeader.rawCID)
        XCTAssertNil(exhausted.sameChainPredecessor)
        let siblingStageCount = await recorder.count(for: siblingHeader.rawCID)
        XCTAssertEqual(siblingStageCount, 0)

        let missingParent = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_500,
            nonce: 3
        )
        let orphan = try await AdmissionFixture.makeChild(
            of: missingParent,
            fetcher: fetcher,
            timestamp: 3_500,
            nonce: 4
        )
        let orphanHeader = try BlockHeader(node: orphan)
        let missingParentHeader = try BlockHeader(node: missingParent)
        let orphanExhausted = try await fixture.level.admit(
            orphanHeader,
            fetcher: fetcher,
            stage: { batch in await recorder.stage(batch) }
        )
        XCTAssertEqual(orphanExhausted.failure, .revisionExhausted)
        XCTAssertEqual(
            orphanExhausted.parentCarrierLink?.carrierCID,
            orphanHeader.rawCID
        )
        XCTAssertEqual(
            orphanExhausted.sameChainPredecessor,
            SameChainPredecessorRequirement(
                descendantCID: orphanHeader.rawCID,
                predecessorCID: missingParentHeader.rawCID
            )
        )
        let orphanStageCount = await recorder.count(for: orphanHeader.rawCID)
        XCTAssertEqual(orphanStageCount, 0)
    }

    func testFailedStageReleasesTheFinalCommitRevision() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let fixture = try await AdmissionFixture.makeLevel(genesis: genesis, revision: .max - 1)
        let header = try BlockHeader(node: candidate)

        do {
            _ = try await fixture.level.admit(
                header,
                fetcher: fetcher,
                stage: { _ in throw ChainLocalTestError.stageFailure }
            )
            XCTFail("a failed atomic stage must fail admission")
        } catch ChainLocalTestError.stageFailure {}
        let revisionAfterFailure = await fixture.level.chain.currentRevision()
        XCTAssertEqual(revisionAfterFailure, .max - 1)

        let accepted = try await fixture.level.admit(header, fetcher: fetcher)
        XCTAssertEqual(accepted.commit?.revision, .max)
    }

    func testPreflightCommitUsesNoRemoteFetchAfterPreflight() async throws {
        let backing = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: backing, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: backing,
            timestamp: 2_000,
            nonce: 1
        )
        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let source = DenyingFetcher(backing: backing)
        let validationCache = StorableFetcher()
        let materialized = RecordingAdmissionStorer()
        let recorder = AdmissionStageRecorder()
        let header = try BlockHeader(node: candidate)

        let result = try await level.preflightBlockImport(
            header,
            fetcher: source,
            validationContentStorer: validationCache
        )
        guard case .ready(let preflight) = result else {
            return XCTFail("valid candidate must produce a commit token")
        }

        await source.denyAll()
        let committed = try await level.commitPreflight(
            preflight,
            materializedVolumeStorer: materialized,
            stage: { context in await recorder.stage(context) }
        )

        let containsCandidate = await level.chain.contains(blockHash: header.rawCID)
        let stagedCandidate = await recorder.count(for: header.rawCID)
        XCTAssertNotNil(committed.commit)
        XCTAssertTrue(containsCandidate)
        XCTAssertEqual(stagedCandidate, 1)
    }

    func testPreflightTokenIsLevelBoundAndOneUse() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let otherLevel = AdmissionFixture.makeLevel(genesis: genesis)
        let header = try BlockHeader(node: candidate)

        let result = try await level.preflightBlockImport(
            header,
            fetcher: fetcher,
            validationContentStorer: fetcher
        )
        guard case .ready(let preflight) = result else {
            return XCTFail("valid candidate must produce a commit token")
        }

        do {
            _ = try await otherLevel.commitPreflight(
                preflight,
                materializedVolumeStorer: fetcher,
                stage: { context in
                    try await testAdmissionStage(context)
                }
            )
            XCTFail("a token must not commit on a different level")
        } catch {
            XCTAssertEqual(
                error as? BlockImportPreflightError,
                .invalidToken
            )
        }

        let committed = try await level.commitPreflight(
            preflight,
            materializedVolumeStorer: fetcher,
            stage: { context in
                try await testAdmissionStage(context)
            }
        )
        XCTAssertNotNil(committed.commit)

        do {
            _ = try await level.commitPreflight(
                preflight,
                materializedVolumeStorer: fetcher,
                stage: { context in
                    try await testAdmissionStage(context)
                }
            )
            XCTFail("a token must not commit twice")
        } catch {
            XCTAssertEqual(
                error as? BlockImportPreflightError,
                .invalidToken
            )
        }
    }

    func testPreflightRemainsValidAfterAnotherAdmissionCommits() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let first = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let sibling = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2
        )
        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let firstHeader = try BlockHeader(node: first)
        let siblingHeader = try BlockHeader(node: sibling)

        let preflightResult = try await level.preflightBlockImport(
            firstHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher
        )
        guard case .ready(let preflight) = preflightResult else {
            return XCTFail("valid candidate must produce a commit token")
        }

        let siblingResult = try await level.admit(siblingHeader, fetcher: fetcher)
        let firstResult = try await level.commitPreflight(
            preflight,
            materializedVolumeStorer: fetcher,
            stage: { context in
                try await testAdmissionStage(context)
            }
        )

        XCTAssertEqual(
            [siblingResult, firstResult].compactMap(\.commit?.revision).sorted(),
            [1, 2]
        )
        let containsFirst = await level.chain.contains(blockHash: firstHeader.rawCID)
        let containsSibling = await level.chain.contains(blockHash: siblingHeader.rawCID)
        XCTAssertTrue(containsFirst)
        XCTAssertTrue(containsSibling)
    }

    func testPreflightCommitPromotesCarrierLinkAfterPredecessorConnects() async throws {
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
            validationContentStorer: fetcher
        )
        guard case .ready(let preflight) = preflightResult else {
            return XCTFail("valid descendant must produce a commit token")
        }

        _ = try await level.admit(predecessorHeader, fetcher: fetcher)
        let recorder = AdmissionStageRecorder()
        let committed = try await level.commitPreflight(
            preflight,
            materializedVolumeStorer: fetcher,
            stage: { context in await recorder.stage(context) }
        )

        XCTAssertNotNil(committed.commit)
        XCTAssertNotNil(committed.parentCarrierLink)
        XCTAssertNil(committed.sameChainPredecessor)
        let stagedContexts = await recorder.recordedContexts()
        let stagedContext = try XCTUnwrap(stagedContexts.first)
        XCTAssertEqual(
            stagedContext.issuedCarrierLink,
            committed.parentCarrierLink
        )
    }

    func testDuplicatePreflightPromotesCarrierLinkAfterPredecessorConnectsWithoutStaging() async throws {
        let backing = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: backing, timestamp: 1_000)
        let predecessor = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: backing,
            timestamp: 2_000,
            nonce: 1
        )
        let orphan = try await AdmissionFixture.makeChild(
            of: predecessor,
            fetcher: backing,
            timestamp: 3_000,
            nonce: 2
        )
        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let recorder = AdmissionStageRecorder()
        let predecessorHeader = try BlockHeader(node: predecessor)
        let orphanHeader = try BlockHeader(node: orphan)

        _ = try await level.admit(
            orphanHeader,
            fetcher: backing,
            stage: { context in await recorder.stage(context) }
        )
        let source = DenyingFetcher(backing: backing)
        let preflight = try await level.preflightBlockImport(
            orphanHeader,
            fetcher: source,
            validationContentStorer: backing
        )
        guard case .duplicate(let duplicate) = preflight else {
            return XCTFail("known orphan must produce a duplicate token")
        }

        _ = try await level.admit(
            predecessorHeader,
            fetcher: backing,
            stage: { context in await recorder.stage(context) }
        )
        await source.denyAll()
        let resolved = try await level.resolveDuplicatePreflight(duplicate)

        guard case .duplicate(let link, let predecessor, _) = resolved.result else {
            return XCTFail("resolved token must remain duplicate")
        }
        XCTAssertEqual(link?.carrierCID, orphanHeader.rawCID)
        XCTAssertNil(predecessor)
        XCTAssertEqual(resolved.parentGenesisLinks, [])
        let orphanStageCount = await recorder.count(for: orphanHeader.rawCID)
        let predecessorStageCount = await recorder.count(
            for: predecessorHeader.rawCID
        )
        XCTAssertEqual(orphanStageCount, 1)
        XCTAssertEqual(predecessorStageCount, 1)

        do {
            _ = try await level.resolveDuplicatePreflight(duplicate)
            XCTFail("a duplicate token must not resolve twice")
        } catch {
            XCTAssertEqual(
                error as? BlockImportPreflightError,
                .invalidToken
            )
        }
    }

    func testConcurrentAdmissionReachesStorageTogetherWithOneValidationContext() async throws {
        let fetcher = StorableFetcher()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: now)
        // Candidates sit after genesis but within the validation context's clock
        // (set below to now + 2h), so the timestamp rule admits them and the test
        // exercises only the concurrent-admission path.
        let candidateTimestamp = now + 60 * 60 * 1_000
        let first = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: candidateTimestamp,
            nonce: 1
        )
        let sibling = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: candidateTimestamp,
            nonce: 2
        )
        let validationContext = ValidationContext(
            nowMilliseconds: now + 2 * 60 * 60 * 1_000
        )
        let level = AdmissionFixture.makeLevel(genesis: genesis)
        let barrier = StorageBarrier(backing: fetcher)
        let recorder = AdmissionStageRecorder()
        let firstHeader = try BlockHeader(node: first)
        let siblingHeader = try BlockHeader(node: sibling)
        async let firstResult: BlockImportResult = level.admit(
            firstHeader,
            fetcher: fetcher,
            storer: barrier,
            validationContext: validationContext,
            stage: { record in await recorder.stage(record) }
        )
        async let siblingResult: BlockImportResult = level.admit(
            siblingHeader,
            fetcher: fetcher,
            storer: barrier,
            validationContext: validationContext,
            stage: { record in await recorder.stage(record) }
        )

        for _ in 0..<100 {
            if await barrier.arrivalCount() == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let arrivals = await barrier.arrivalCount()
        await barrier.release()
        let results = try await (firstResult, siblingResult)

        XCTAssertEqual(arrivals, 2, "independent verification should not wait behind a global gate")
        if case .rejected(let failure, _, _) = results.0 {
            return XCTFail("first sibling was rejected: \(failure)")
        }
        if case .rejected(let failure, _, _) = results.1 {
            return XCTFail("second sibling was rejected: \(failure)")
        }
        let containsFirst = await level.chain.contains(blockHash: firstHeader.rawCID)
        let containsSibling = await level.chain.contains(blockHash: siblingHeader.rawCID)
        let stagedFirst = await recorder.count(for: firstHeader.rawCID)
        let stagedSibling = await recorder.count(for: siblingHeader.rawCID)
        let revisions = [results.0, results.1].compactMap(\.commit?.revision).sorted()
        let persistedRevision = await level.chain.currentRevision()
        XCTAssertTrue(containsFirst)
        XCTAssertTrue(containsSibling)
        XCTAssertEqual(revisions, [1, 2], "actor commits totally order concurrent admissions")
        XCTAssertEqual(persistedRevision, revisions.last)
        XCTAssertEqual(stagedFirst, 1)
        XCTAssertEqual(stagedSibling, 1)
    }
}
