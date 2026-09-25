import Foundation
import XCTest
@testable import Lattice
import UInt256
import cashew
import WAT

private func chainLocalSpec(wasmPolicies: [WasmPolicyRef] = []) -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1_024,
        halvingInterval: 10_000,
        retargetWindow: 5,
        wasmPolicies: wasmPolicies
    )
}

private enum ChainLocalTestError: Error, Sendable {
    case unexpectedFailure
    case storageFailure
    case stageFailure
}

private struct MismatchingAdmissionFetcher: Fetcher {
    let data: Data

    func fetch(rawCid: String) async throws -> Data {
        data
    }
}

private struct UnknownFailingAdmissionFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw ChainLocalTestError.unexpectedFailure
    }
}

private struct MissingCIDAdmissionFetcher: Fetcher {
    let backing: StorableFetcher
    let missingCID: String

    func fetch(rawCid: String) async throws -> Data {
        if rawCid == missingCID { throw FetcherError.notFound(rawCid) }
        return try await backing.fetch(rawCid: rawCid)
    }
}

private struct ResolutionCase {
    let name: String
    let fetcher: any Fetcher
    let expectedFailure: ChainAdmissionFailure
}

private struct FailingAdmissionStorer: Storer, VolumeStorer {
    func store(entries: [String: Data]) async throws {
        throw ChainLocalTestError.storageFailure
    }

    func store(volume: SerializedVolume) async throws {
        throw ChainLocalTestError.storageFailure
    }
}

private struct FailingVolumeAdmissionStorer: Storer, VolumeStorer {
    func store(entries: [String: Data]) async throws {}

    func store(volume: SerializedVolume) async throws {
        throw ChainLocalTestError.storageFailure
    }
}

private actor RecordingAdmissionStorer: Storer, VolumeStorer {
    private let backing = StorableFetcher()
    private var roots = Set<String>()
    private var calls = 0

    func store(entries: [String: Data]) async throws {
        calls += 1
        await backing.store(entries: entries)
    }

    func store(volume: SerializedVolume) async throws {
        calls += 1
        roots.insert(volume.root)
        await backing.store(volume: volume)
    }

    func volumeRoots() -> Set<String> { roots }
    func storeCallCount() -> Int { calls }
}

private actor AdmissionStageRecorder {
    private var batches: [ChainAdmissionBatch] = []
    private var contexts: [ChainAdmissionStagingContext] = []

    func stage(_ batch: ChainAdmissionBatch) {
        batches.append(batch)
    }

    func stage(_ context: ChainAdmissionStagingContext) {
        contexts.append(context)
        batches.append(context.batch)
    }

    func count(for blockHash: String) -> Int {
        batches.count { batch in
            batch.facts.contains { fact in
                switch fact {
                case .block(let block): block.blockHash == blockHash
                case .work(let work): work.blockHash == blockHash
                case .exclusion(let exclusion): exclusion.blockHash == blockHash
                case .validation(let validation): validation.blockHash == blockHash
                }
            }
        }
    }

    func recordedBatches() -> [ChainAdmissionBatch] { batches }
    func recordedContexts() -> [ChainAdmissionStagingContext] { contexts }
}

private actor FetchCountingAdmissionFetcher: Fetcher {
    private var count = 0

    func fetch(rawCid: String) async throws -> Data {
        count += 1
        throw FetcherError.notFound(rawCid)
    }

    func fetchCount() -> Int { count }
}

private actor DisableableAdmissionFetcher: Fetcher {
    private let backing: StorableFetcher
    private var enabled = true

    init(backing: StorableFetcher) {
        self.backing = backing
    }

    func fetch(rawCid: String) async throws -> Data {
        guard enabled else { throw FetcherError.notFound(rawCid) }
        return try await backing.fetch(rawCid: rawCid)
    }

    func disable() {
        enabled = false
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

final class ChainLocalAdmissionTests: XCTestCase {
    private let easy = UInt256.max

    private func makeGenesis(
        fetcher: StorableFetcher,
        timestamp: Int64,
        nonce: UInt64 = 0,
        transactions: [Transaction] = []
    ) async throws -> Block {
        return try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            transactions: transactions,
            timestamp: timestamp,
            target: easy,
            nonce: nonce,
            fetcher: fetcher
        )
    }

    private func makeChild(
        of previous: Block,
        fetcher: StorableFetcher,
        timestamp: Int64,
        nonce: UInt64,
        parentChainBlock: Block? = nil
    ) async throws -> Block {
        try await buildAndStoreBlock(
            previous: previous,
            parentChainBlock: parentChainBlock,
            timestamp: timestamp,
            target: easy,
            nonce: nonce,
            fetcher: fetcher
        )
    }

    private func makeLevel(genesis: Block) -> ChainLevel {
        ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
    }

    private func makeLevel(
        genesis: Block,
        revision: UInt64
    ) async throws -> (level: ChainLevel, seedBatch: ChainAdmissionBatch) {
        let seedBatch = try testAdmissionBatch(for: genesis)
        return (
            ChainLevel(testChain: try await ChainState.restore(
                replaying: [seedBatch],
                revisionFloor: revision
            )),
            seedBatch
        )
    }

    func testRuntimeContextRequiresAbsoluteSeparatorFreeNexusPath() throws {
        XCTAssertNoThrow(try ChainRuntimeContext(
            path: [DEFAULT_ROOT_DIRECTORY, "Payments"]
        ))
        for (path, expected) in [
            (["Payments"], ChainRuntimeContextError.rootMustBeNexus),
            (["Other", "Payments"], .rootMustBeNexus),
            ([DEFAULT_ROOT_DIRECTORY, "Pay/ments"], .directoryContainsSeparator)
        ] {
            XCTAssertThrowsError(try ChainRuntimeContext(
                path: path
            )) { error in
                XCTAssertEqual(error as? ChainRuntimeContextError, expected)
            }
        }
    }

    func testRuntimeContextEnforcesProofWireDirectoryAndDepthBounds() throws {
        let maximumDirectory = String(
            repeating: "x",
            count: ChildProofWireLimits.maximumDirectoryBytes
        )
        XCTAssertNoThrow(try ChainRuntimeContext(
            path: [DEFAULT_ROOT_DIRECTORY, maximumDirectory]
        ))
        XCTAssertThrowsError(try ChainRuntimeContext(
            path: [DEFAULT_ROOT_DIRECTORY, maximumDirectory + "x"]
        )) { error in
            XCTAssertEqual(error as? ChainRuntimeContextError, .directoryTooLong)
        }

        XCTAssertNoThrow(try ChainRuntimeContext(
            path: [DEFAULT_ROOT_DIRECTORY] + Array(
                repeating: "Child",
                count: ChildProofWireLimits.maximumDepth
            )
        ))
        XCTAssertThrowsError(try ChainRuntimeContext(
            path: [DEFAULT_ROOT_DIRECTORY] + Array(
                repeating: "Child",
                count: ChildProofWireLimits.maximumDepth + 1
            )
        )) { error in
            XCTAssertEqual(error as? ChainRuntimeContextError, .pathTooDeep)
        }
    }

    private func signedStateChangingGenesisTransaction(
        key: String,
        chainPath: [String]
    ) -> Transaction {
        let keyPair = CryptoUtils.generateKeyPair()
        let signer = testAddress(publicKey: keyPair.publicKey)
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(key: key, oldValue: nil, newValue: "value")],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [signer],
            fee: 0,
            nonce: 0,
            chainPath: chainPath
        )
        return signedTestTransaction(body, by: keyPair)
    }

    private func unsignedStateChangingGenesisTransaction(
        key: String,
        chainPath: [String]
    ) -> Transaction {
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(key: key, oldValue: nil, newValue: "value")],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            fee: 0,
            nonce: 0,
            chainPath: chainPath
        )
        return Transaction(
            signatures: [:],
            body: try! HeaderImpl<TransactionBody>(node: body)
        )
    }

    private func makeChildProofFixture() async throws -> (
        fetcher: StorableFetcher,
        childLevel: ChainLevel,
        candidate: Block,
        package: ChildValidationPackage
    ) {
        let fetcher = StorableFetcher()
        let parentGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let candidate = try await makeChild(
            of: childGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1,
            parentChainBlock: parentGenesis
        )
        let carrierWithChild = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": candidate],
            timestamp: 3_000,
            target: easy,
            nonce: 2,
            fetcher: fetcher
        )
        let childLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )

        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrierWithChild),
            childDirectory: "Child",
            fetcher: fetcher
        )
        return (
            fetcher,
            childLevel,
            candidate,
            try await childValidationPackage(proof: proof, fetcher: fetcher)
        )
    }

    private func verifiedMultiHopContribution(
        outerTarget: UInt256,
        middleTarget: UInt256,
        leafTarget: UInt256,
        miningTarget: UInt256
    ) async throws -> (
        fetcher: StorableFetcher,
        leafGenesis: Block,
        candidate: Block,
        package: ChildValidationPackage,
        downstreamCID: String,
        contribution: VerifiedWorkContribution,
        rootHash: UInt256,
        rootCID: String
    ) {
        let fetcher = StorableFetcher()
        let parentTemplate = try await makeGenesis(fetcher: fetcher, timestamp: 500)
        let leafGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 1_000,
            target: leafTarget,
            nonce: 1,
            fetcher: fetcher
        )
        let downstream = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 1_500,
            target: leafTarget,
            nonce: 5,
            fetcher: fetcher
        )
        let leaf = try await buildAndStoreBlock(
            previous: leafGenesis,
            children: ["Downstream": downstream],
            parentChainBlock: parentTemplate,
            timestamp: 2_000,
            target: leafTarget,
            nextTarget: leafTarget,
            nonce: 2,
            fetcher: fetcher
        )
        let middle = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Leaf": leaf],
            timestamp: 3_000,
            target: middleTarget,
            nonce: 3,
            fetcher: fetcher
        )
        let rootTemplate = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Middle": middle],
            timestamp: 4_000,
            target: outerTarget,
            nonce: 4,
            fetcher: fetcher
        )
        let root = try XCTUnwrap(
            BlockBuilder.mine(
                block: rootTemplate,
                target: miningTarget,
                maxAttempts: 1_000_000
            ),
            "the fixture must find a root grind under its hardest accepted target"
        )
        try await storeBuiltBlock(root, in: fetcher)

        let rootHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Middle",
            fetcher: fetcher
        )
        let leafHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: middle),
            childDirectory: "Leaf",
            fetcher: fetcher
        )
        let proof = rootHop.composing(hop: leafHop)
        let package = try await childValidationPackage(
            proof: proof,
            fetcher: fetcher
        )
        let verification = await proof.verifySecuringWork(
            child: leaf,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"]
        )
        guard case .success(let evidence) = verification else {
            throw ChainLocalTestError.unexpectedFailure
        }
        return (
            fetcher: fetcher,
            leafGenesis: leafGenesis,
            candidate: leaf,
            package: package,
            downstreamCID: try BlockHeader(node: downstream).rawCID,
            contribution: try XCTUnwrap(evidence.contribution),
            rootHash: root.proofOfWorkHash(),
            rootCID: proof.rootCID
        )
    }

    func testResolutionFailuresHaveTypedOutcomes() async throws {
        let storage = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: storage, timestamp: 1_000)
        let candidate = try await makeChild(of: genesis, fetcher: storage, timestamp: 2_000, nonce: 1)
        let unrelated = try await makeGenesis(fetcher: storage, timestamp: 3_000, nonce: 2)
        let cases = [
            ResolutionCase(
                name: "unavailable provider evidence",
                fetcher: InMemoryContentSource([:]),
                expectedFailure: .unavailableEvidence
            ),
            ResolutionCase(
                name: "provider bytes for a different CID",
                fetcher: MismatchingAdmissionFetcher(data: try XCTUnwrap(unrelated.toData())),
                expectedFailure: .providerMalformedEvidence
            ),
            ResolutionCase(
                // Fail-safe: an unrecognized error is not a completed
                // deterministic check, so it classifies as retryable, never as
                // an excluding verdict (validated-tier invalidity-exclusion).
                name: "unknown failure classifies as retryable, not a verdict",
                fetcher: UnknownFailingAdmissionFetcher(),
                expectedFailure: .unavailableEvidence
            )
        ]
        let header = try BlockHeader(node: candidate)

        for testCase in cases {
            let result = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
                header,
                fetcher: testCase.fetcher,
                validationContentStorer: NoopStorer(),
                materializedVolumeStorer: NoopStorer(),
                stage: testAdmissionStage
            )
            XCTAssertEqual(result.failure, testCase.expectedFailure, testCase.name)
        }
    }

    func testInlineBlockHeaderCIDMismatchIsProviderMalformedEvidence() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let unrelated = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 3_000,
            nonce: 2
        )
        let expectedCID = try BlockHeader(node: candidate).rawCID
        let forged = BlockHeader(
            rawCID: expectedCID,
            node: unrelated,
            encryptionInfo: nil
        )

        let result = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            forged,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
    }

    /// An ancestor the difficulty schedule depends on being unreachable is
    /// UNAVAILABLE evidence, never a verdict of invalid: the block may be
    /// perfectly good and the content merely not here yet, so it has to stay
    /// retriable rather than be discarded.
    ///
    /// The ancestor that matters is the chain's height-1 block — the schedule's
    /// anchor — not genesis, which the schedule never reads. So this hides block
    /// 1 and builds deep enough that reaching it is a real fetch: the anchor for
    /// a height-2 block is its own parent, already in hand, and nothing is
    /// fetched at all.
    func testMissingAnchorAncestorIsUnavailableEvidence() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let blockOne = try await makeChild(
            of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1
        )
        let blockTwo = try await makeChild(
            of: blockOne, fetcher: fetcher, timestamp: 3_000, nonce: 2
        )
        let candidate = try await makeChild(
            of: blockTwo, fetcher: fetcher, timestamp: 4_000, nonce: 3
        )
        let missingAnchor = MissingCIDAdmissionFetcher(
            backing: fetcher,
            missingCID: try BlockHeader(node: blockOne).rawCID
        )

        let result = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: missingAnchor,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .unavailableEvidence)
    }

    func testMissingImmediatePredecessorReturnsExactBackfillRequirement() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let parent = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let candidate = try await makeChild(
            of: parent,
            fetcher: fetcher,
            timestamp: 3_000,
            nonce: 2
        )
        let parentCID = try BlockHeader(node: parent).rawCID
        let candidateCID = try BlockHeader(node: candidate).rawCID
        let missingParent = MissingCIDAdmissionFetcher(
            backing: fetcher,
            missingCID: parentCID
        )

        let result = try await makeLevel(genesis: genesis)
            .admitBlockHeaderChainLocal(
                try BlockHeader(node: candidate),
                fetcher: missingParent,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: testAdmissionStage
            )

        XCTAssertEqual(result.failure, .unavailableEvidence)
        XCTAssertEqual(result.sameChainPredecessor, SameChainPredecessorRequirement(
            descendantCID: candidateCID,
            predecessorCID: parentCID
        ))
        XCTAssertEqual(
            result.parentCarrierLink?.carrierCID,
            candidateCID
        )
    }

    func testMissingPolicyModuleIsUnavailableEvidence() async throws {
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(
            requiringSubstring: "",
            scope: .transaction,
            fetcher: fetcher
        )
        let spec = chainLocalSpec(wasmPolicies: [policy])
        let genesis = try await buildAndStoreGenesis(
            spec: spec,
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let candidate = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2_000,
            target: easy,
            nonce: 1,
            fetcher: fetcher
        )
        let missingModule = MissingCIDAdmissionFetcher(
            backing: fetcher,
            missingCID: policy.moduleCID
        )

        let result = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: missingModule,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .unavailableEvidence)
    }

    func testProtocolInvalidCandidateIsRejected() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let valid = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let invalid = Block(
            version: valid.version,
            parent: valid.parent,
            transactions: valid.transactions,
            target: valid.target,
            nextTarget: valid.nextTarget,
            spec: valid.spec,
            parentState: valid.parentState,
            prevState: valid.prevState,
            postState: valid.postState,
            children: valid.children,
            height: valid.height + 1,
            timestamp: valid.timestamp,
            nonce: valid.nonce
        )
        try await storeBuiltBlock(invalid, in: fetcher)

        let result = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            try BlockHeader(node: invalid),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .protocolInvalid)
    }

    func testWeighedAdmissionMatchesEagerForkChoiceWithoutMaterializedState() async throws {
        // Deferred execution (weight-first-acquisition): a `.weighed` admission
        // possesses the block and verifies its PoW, so its work enters fork
        // choice with exactly the eager path's weight — the consensus graph
        // never reads `stateDiff` — while it executes no state transition and
        // materializes no post-state. The eager path stays byte-for-byte the
        // default and is exercised here as the control.
        let genesisTimestamp: Int64 = 1_000

        let eagerFetcher = StorableFetcher()
        let eagerGenesis = try await makeGenesis(
            fetcher: eagerFetcher, timestamp: genesisTimestamp
        )
        let candidate = try await makeChild(
            of: eagerGenesis, fetcher: eagerFetcher, timestamp: 2_000, nonce: 1
        )
        let genesisHash = try BlockHeader(node: eagerGenesis).rawCID
        let candidateHash = try BlockHeader(node: candidate).rawCID

        // A second, independent level seeded from an identical genesis so the
        // two fork-choice graphs are directly comparable. The same candidate
        // header is admitted into both.
        let weighedFetcher = StorableFetcher()
        let weighedGenesis = try await makeGenesis(
            fetcher: weighedFetcher, timestamp: genesisTimestamp
        )
        _ = try await makeChild(
            of: weighedGenesis, fetcher: weighedFetcher, timestamp: 2_000, nonce: 1
        )
        XCTAssertEqual(try BlockHeader(node: weighedGenesis).rawCID, genesisHash)

        let eagerLevel = makeLevel(genesis: eagerGenesis)
        let eager = try await eagerLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: eagerFetcher,
            validationContentStorer: eagerFetcher,
            materializedVolumeStorer: eagerFetcher,
            stage: testAdmissionStage
        )

        let weighedLevel = makeLevel(genesis: weighedGenesis)
        let weighed = try await weighedLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: weighedFetcher,
            validationContentStorer: weighedFetcher,
            materializedVolumeStorer: weighedFetcher,
            mode: .weighed,
            stage: testAdmissionStage
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
        // Tier-2 body deferral: a `.weighed` admission stores the block BOUNDARY
        // (root node + tx/children tries — so the block is servable and locally
        // present for fork choice) but MUST NOT resolve or store tier-3 (tx
        // bodies, validation-path states, WASM modules, genesis empty-state).
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [signedStateChangingGenesisTransaction(
                key: "boundary-tx",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )],
            timestamp: 2_000,
            target: easy,
            nonce: 1,
            fetcher: fetcher
        )
        // The transaction changes state, so the post-state is a distinct, real
        // tier-3 Volume — not the empty state.
        XCTAssertNotEqual(candidate.postState.rawCID, candidate.prevState.rawCID)
        let candidateHash = try BlockHeader(node: candidate).rawCID

        // A fresh store receives ONLY what the weighed admission chooses to store.
        let boundaryStore = StorableFetcher()
        let weighed = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: fetcher,
            validationContentStorer: boundaryStore,
            materializedVolumeStorer: NoopStorer(),
            mode: .weighed,
            stage: testAdmissionStage
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
        let genesis = try await makeGenesis(fetcher: full, timestamp: 1_000)
        let candidate = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [signedStateChangingGenesisTransaction(
                key: "bodyless-tx",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )],
            timestamp: 2_000,
            target: easy,
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
        let weighed = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            header,
            fetcher: bodyless,
            validationContentStorer: NoopStorer(),
            materializedVolumeStorer: NoopStorer(),
            mode: .weighed,
            stage: testAdmissionStage
        )
        guard case .accepted = weighed else {
            return XCTFail("weighed admission must accept with a body-less fetcher, got \(weighed)")
        }

        // The SAME block admitted eager against the SAME body-less fetcher fails:
        // eager resolves and executes tier-3, which the fetcher cannot serve.
        let eager = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            header,
            fetcher: bodyless,
            validationContentStorer: NoopStorer(),
            materializedVolumeStorer: NoopStorer(),
            stage: testAdmissionStage
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
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let valid = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [signedStateChangingGenesisTransaction(
                key: "linkage-tx",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )],
            timestamp: 2_000,
            target: easy,
            nonce: 1,
            fetcher: fetcher
        )
        XCTAssertNotEqual(valid.prevState.rawCID, valid.postState.rawCID)
        let foreignSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 1_000_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1_024,
            halvingInterval: 10_000,
            retargetWindow: 6
        )

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
            for mode in [AdmissionMode.weighed, .eager] {
                let level = makeLevel(genesis: genesis)
                let result = try await level.admitBlockHeaderChainLocal(
                    header,
                    fetcher: fetcher,
                    validationContentStorer: fetcher,
                    materializedVolumeStorer: fetcher,
                    mode: mode,
                    stage: testAdmissionStage
                )
                XCTAssertEqual(result.failure, .protocolInvalid, "\(name) \(mode)")
                let inserted = await level.chain.contains(blockHash: header.rawCID)
                XCTAssertFalse(inserted, "\(name) \(mode)")
            }
        }

        // The control: the correctly linked block is still weighed in without
        // being executed.
        let accepted = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            try BlockHeader(node: valid),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            mode: .weighed,
            stage: testAdmissionStage
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
            target: easy / UInt256(2),
            fetcher: fetcher
        )
        let tooEasy = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2_000,
            target: easy,
            nonce: 1,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(tooEasy.target, genesis.nextTarget)
        let header = try BlockHeader(node: tooEasy)

        for mode in [AdmissionMode.weighed, .eager] {
            let level = makeLevel(genesis: genesis)
            let result = try await level.admitBlockHeaderChainLocal(
                header,
                fetcher: fetcher,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                mode: mode,
                stage: testAdmissionStage
            )
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
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: now - 100_000)
        let future = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: now + 60_000,
            nonce: 1
        )
        let header = try BlockHeader(node: future)

        let level = makeLevel(genesis: genesis)
        let result = try await level.admitBlockHeaderChainLocal(
            header,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            mode: .weighed,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .notYetAdmissible)
        let inserted = await level.chain.contains(blockHash: header.rawCID)
        XCTAssertFalse(inserted)
    }

    func testWeighedAdmissionNeverAcceptsAGenesis() async throws {
        // A genesis is only ever admitted eagerly via bootstrap (self/pinned);
        // a network-weighed parentless header has nothing to link to.
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let rival = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let header = try BlockHeader(node: rival)

        let level = makeLevel(genesis: genesis)
        let result = try await level.admitBlockHeaderChainLocal(
            header,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            mode: .weighed,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .protocolInvalid)
        let inserted = await level.chain.contains(blockHash: header.rawCID)
        XCTAssertFalse(inserted)
    }

    func testWeighedChildAdmissionRunsTheSameHeaderLinkage() async throws {
        // A child block's securing proof binds it to a parent grind, not to its
        // own predecessor: the weighed tier must run the same same-chain header
        // linkage for children as for roots.
        let fetcher = StorableFetcher()
        let parentGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let childPath = [DEFAULT_ROOT_DIRECTORY, "Child"]
        let valid = try await buildAndStoreBlock(
            previous: childGenesis,
            transactions: [signedStateChangingGenesisTransaction(
                key: "child-linkage-tx",
                chainPath: childPath
            )],
            parentChainBlock: parentGenesis,
            timestamp: 2_000,
            target: easy,
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
                target: easy,
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
            let result = try await level.admitBlockHeaderChainLocal(
                header,
                fetcher: fetcher,
                childPackage: try await packaged(variant, nonce: UInt64(10 + index)),
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                mode: .weighed,
                stage: testAdmissionStage
            )
            XCTAssertEqual(result.failure, .protocolInvalid, name)
            let inserted = await level.chain.contains(blockHash: header.rawCID)
            XCTAssertFalse(inserted, name)
        }

        let accepted = try await childLevel().admitBlockHeaderChainLocal(
            try BlockHeader(node: valid),
            fetcher: fetcher,
            childPackage: try await packaged(valid, nonce: 20),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            mode: .weighed,
            stage: testAdmissionStage
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
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let unheld = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let valid = try await makeChild(of: unheld, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let invalid = try await storeVariant(
            of: valid, fetcher: fetcher, height: valid.height + 1
        )
        let header = try BlockHeader(node: invalid)

        for mode in [AdmissionMode.weighed, .eager] {
            let result = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
                header,
                fetcher: fetcher,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                mode: mode,
                stage: testAdmissionStage
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
        let genesis = try await makeGenesis(fetcher: full, timestamp: 1_000)
        let parent = try await makeChild(of: genesis, fetcher: full, timestamp: 2_000, nonce: 1)
        let candidate = try await makeChild(of: parent, fetcher: full, timestamp: 3_000, nonce: 2)
        let header = try BlockHeader(node: candidate)

        // Candidate boundary + chain spec only; the parent root is absent.
        let parentless = StorableFetcher()
        try await header.storeBlockBoundary(fetcher: full, storer: parentless)
        parentless.store(
            rawCid: genesis.spec.rawCID,
            data: try await full.fetch(rawCid: genesis.spec.rawCID)
        )

        let level = makeLevel(genesis: genesis)
        let result = try await level.admitBlockHeaderChainLocal(
            header,
            fetcher: parentless,
            validationContentStorer: parentless,
            materializedVolumeStorer: parentless,
            mode: .weighed,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .unavailableEvidence)
        XCTAssertEqual(result.sameChainPredecessor, SameChainPredecessorRequirement(
            descendantCID: header.rawCID,
            predecessorCID: try BlockHeader(node: parent).rawCID
        ))
        let inserted = await level.chain.contains(blockHash: header.rawCID)
        XCTAssertFalse(inserted)
    }

    func testUnboundedRetargetWindowNeitherTrapsNorOverWalks() async throws {
        // `retargetWindow` is an unbounded UInt64 from the spec — attacker-
        // supplied when the parent is disconnected. The ancestor walk must be
        // bounded by the chain's actual depth: never reserve or walk the raw
        // window (`Int(UInt64.max)` traps), and serve exactly parentDepth
        // timestamps on a short chain.
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 100_000,
                maxBlockSize: 1_000_000,
                premine: 0,
                targetBlockTime: 1_000,
                initialReward: 1_024,
                halvingInterval: 10_000,
                retargetWindow: UInt64.max
            ),
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let first = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let second = try await makeChild(of: first, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let firstHash = try BlockHeader(node: first).rawCID
        let level = makeLevel(genesis: genesis)

        let eager = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: first),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        guard case .accepted = eager else {
            return XCTFail("eager admission must accept, got \(eager)")
        }
        let weighed = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: second),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            mode: .weighed,
            stage: testAdmissionStage
        )
        guard case .accepted = weighed else {
            return XCTFail("weighed admission must accept, got \(weighed)")
        }

        let served = await level.chain.getMainChainTimestamps(
            forParentHash: firstHash, count: UInt64.max
        )
        XCTAssertEqual(served, [2_000, 1_000])
    }

    func testOffMainChainParentServesTimestampsFromTheHeldGraph() async throws {
        // Every frontier leaf and losing fork has an off-main-chain parent. The
        // held graph (parent links + timestamps of every accepted block, weighed
        // included) serves its retarget window exactly as the fetcher walk
        // would — same order, same count — so no candidate pays a sequential
        // fetcher walk for ancestors the node already holds.
        let full = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: full, timestamp: 1_000)
        let mainOne = try await makeChild(of: genesis, fetcher: full, timestamp: 2_000, nonce: 1)
        let mainTwo = try await makeChild(of: mainOne, fetcher: full, timestamp: 3_000, nonce: 2)
        let sideOne = try await makeChild(of: genesis, fetcher: full, timestamp: 2_500, nonce: 3)
        let sideTwo = try await makeChild(of: sideOne, fetcher: full, timestamp: 3_500, nonce: 4)
        let genesisHash = try BlockHeader(node: genesis).rawCID
        let sideOneHash = try BlockHeader(node: sideOne).rawCID

        let level = makeLevel(genesis: genesis)
        for block in [mainOne, mainTwo, sideOne] {
            let result = try await level.admitBlockHeaderChainLocal(
                try BlockHeader(node: block),
                fetcher: full,
                validationContentStorer: full,
                materializedVolumeStorer: full,
                stage: testAdmissionStage
            )
            guard case .accepted = result else {
                return XCTFail("fixture block must be accepted, got \(result)")
            }
        }
        let tip = await level.chain.getMainChainTip()
        XCTAssertEqual(tip, try BlockHeader(node: mainTwo).rawCID)
        let sideOnMain = await level.chain.getMainChainBlockHash(atIndex: 1)
        XCTAssertNotEqual(sideOnMain, sideOneHash)

        let served = await level.chain.getMainChainTimestamps(
            forParentHash: sideOneHash, count: 5
        )
        let walked = try await sideTwo.collectAncestorTimestamps(
            parent: sideOne, count: 5, fetcher: full
        )
        XCTAssertEqual(served, walked)
        XCTAssertEqual(walked, [2_500, 1_000])

        // A fetcher that cannot serve any ancestor beyond the parent still
        // validates the side candidate: the window came from the held graph.
        let noAncestors = MissingCIDAdmissionFetcher(backing: full, missingCID: genesisHash)
        let result = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: sideTwo),
            fetcher: noAncestors,
            validationContentStorer: full,
            materializedVolumeStorer: full,
            mode: .weighed,
            stage: testAdmissionStage
        )
        guard case .accepted = result else {
            return XCTFail("side candidate must validate from the held graph, got \(result)")
        }
    }

    func testValidateTierExecutesLikeEagerAndMaterializesState() async throws {
        // Validated tier (deferred execution): `.validate` executes a block and
        // records the validity verdict. On a valid block it does exactly what
        // eager does — runs the transition, materializes the post-state, emits
        // the block fact carrying the real `stateDiff` — the durable "validated"
        // marker that upgrades a weighed claim. Proven here against the eager
        // control on an identical, independent level.
        let genesisTimestamp: Int64 = 1_000

        let eagerFetcher = StorableFetcher()
        let eagerGenesis = try await makeGenesis(
            fetcher: eagerFetcher, timestamp: genesisTimestamp
        )
        let candidate = try await makeChild(
            of: eagerGenesis, fetcher: eagerFetcher, timestamp: 2_000, nonce: 1
        )
        let genesisHash = try BlockHeader(node: eagerGenesis).rawCID
        let candidateHash = try BlockHeader(node: candidate).rawCID

        let validateFetcher = StorableFetcher()
        let validateGenesis = try await makeGenesis(
            fetcher: validateFetcher, timestamp: genesisTimestamp
        )
        _ = try await makeChild(
            of: validateGenesis, fetcher: validateFetcher, timestamp: 2_000, nonce: 1
        )
        XCTAssertEqual(try BlockHeader(node: validateGenesis).rawCID, genesisHash)

        let eagerLevel = makeLevel(genesis: eagerGenesis)
        let eager = try await eagerLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: eagerFetcher,
            validationContentStorer: eagerFetcher,
            materializedVolumeStorer: eagerFetcher,
            stage: testAdmissionStage
        )

        let validateLevel = makeLevel(genesis: validateGenesis)
        let validated = try await validateLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: validateFetcher,
            validationContentStorer: validateFetcher,
            materializedVolumeStorer: validateFetcher,
            mode: .validate,
            stage: testAdmissionStage
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

    /// A root exclusion may stand only on another EXECUTED root (§9.9). On the
    /// only deployed shape — one root — the validate tier's verdict on a
    /// parentless block is therefore parked as a non-verdict at the PRODUCER:
    /// nothing is staged, nothing is excluded, and recovery has no fact whose
    /// replay could depend on order.
    func testValidateTierParksARootExclusionWithNoOtherExecutedRoot() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let level = makeLevel(genesis: genesis)
        let genesisHash = try BlockHeader(node: genesis).rawCID
        actor StageCounter { var count = 0; func bump() { count += 1 } }
        let stagedCounter = StageCounter()
        let result = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: genesis),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            mode: .validate,
            stage: { _ in await stagedCounter.bump() }
        )
        let staged = await stagedCounter.count
        guard case .rejected(let failure, _, _) = result else {
            return XCTFail("a root exclusion with nothing to stand on must be parked, got \(result)")
        }
        XCTAssertEqual(failure, .notYetAdmissible, "a non-verdict, retried — never a written fact")
        XCTAssertEqual(staged, 0, "nothing is made durable")
        let roots = await level.chain.excludedRootsForTesting
        XCTAssertTrue(roots.isEmpty)
        let tip = await level.chain.getMainChainTip()
        XCTAssertEqual(tip, genesisHash, "the only root stays selectable")
    }

    func testUnknownErrorClassifiesAsRetryableNotExcluding() {
        // Fail-safe: an unenumerated error type is not a completed deterministic
        // check, so both classifier catch-alls must route it to retryable
        // `.unavailableEvidence`, never to an excluding verdict. Otherwise a new
        // error type on any fetch/IO path becomes a silent consensus split.
        struct UnrecognizedError: Error {}
        let unknown = UnrecognizedError()

        let validation = ChainLevel.classifyValidationFailureForTesting(unknown)
        XCTAssertEqual(validation, .unavailableEvidence)
        XCTAssertFalse(ChainLevel.isDeterministicInvalidityForTesting(validation))

        let resolution = ChainLevel.classifyResolutionFailureForTesting(unknown)
        XCTAssertEqual(resolution, .unavailableEvidence)
        XCTAssertFalse(ChainLevel.isDeterministicInvalidityForTesting(resolution))
    }

    func testDeterministicInvalidityPartitionsAvailabilityFromVerdict() {
        // The data-availability linchpin: only a COMPLETED deterministic check
        // is a verdict that may exclude. Availability, ordering and capacity
        // failures are transient and must never record an exclusion.
        for failure in [
            ChainAdmissionFailure.protocolInvalid,
            .localVerificationFailure,
        ] {
            XCTAssertTrue(
                ChainLevel.isDeterministicInvalidityForTesting(failure),
                "\(failure) is a completed invalidity verdict"
            )
        }
        for failure in [
            ChainAdmissionFailure.unavailableEvidence,
            .providerMalformedEvidence,
            .crossChainEvidenceRequired(.childProof(chainPath: [], childCID: "x")),
            .notYetAdmissible,
            .notAcceptedAtCurrentChain,
            .revisionExhausted,
        ] {
            XCTAssertFalse(
                ChainLevel.isDeterministicInvalidityForTesting(failure),
                "\(failure) is transient and never excludes"
            )
        }
    }

    func testTargetHitInvalidTransitionStillIssuesCarrierLink() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [unsignedStateChangingGenesisTransaction(
                key: "carrier-parent",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        let valid = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        XCTAssertNotEqual(valid.postState.rawCID, LatticeState.emptyHeader.rawCID)
        let invalid = Block(
            version: valid.version,
            parent: valid.parent,
            transactions: valid.transactions,
            target: valid.target,
            nextTarget: valid.nextTarget,
            spec: valid.spec,
            parentState: valid.parentState,
            prevState: valid.prevState,
            postState: LatticeState.emptyHeader,
            children: valid.children,
            height: valid.height,
            timestamp: valid.timestamp,
            nonce: valid.nonce
        )
        try await storeBuiltBlock(invalid, in: fetcher)
        let header = try BlockHeader(node: invalid)
        let recorder = AdmissionStageRecorder()

        let result = try await makeLevel(genesis: genesis)
            .admitBlockHeaderChainLocal(
                header,
                fetcher: fetcher,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: { batch in await recorder.stage(batch) }
            )

        guard case .rejected(let failure, let link, _) = result else {
            return XCTFail("local invalidity must remain visible")
        }
        XCTAssertEqual(failure, .protocolInvalid)
        let issued = try XCTUnwrap(link)
        XCTAssertEqual(issued.parentPath, [DEFAULT_ROOT_DIRECTORY])
        XCTAssertEqual(issued.carrierCID, header.rawCID)
        XCTAssertEqual(issued.rootCID, header.rawCID)
        let stageCount = await recorder.count(for: header.rawCID)
        XCTAssertEqual(stageCount, 0)

        let otherGenesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 500,
            nonce: 99
        )
        let disconnected = try await makeLevel(genesis: otherGenesis)
            .admitBlockHeaderChainLocal(
                header,
                fetcher: fetcher,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: testAdmissionStage
        )
        XCTAssertEqual(disconnected.failure, .protocolInvalid)
        XCTAssertEqual(disconnected.parentCarrierLink?.carrierCID, header.rawCID)
        // The carrier relay survives a proven invalidity; a predecessor
        // requirement does not — a verdict asks the node to acquire nothing
        // (see testProvenInvalidBlockRequestsNoPredecessor).
        XCTAssertNil(disconnected.sameChainPredecessor)
    }

    func testRootLevelRejectsASecondParentlessRoot() async throws {
        let fetcher = StorableFetcher()
        let first = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let second = try await makeGenesis(fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let level = makeLevel(genesis: first)
        let secondHeader = try BlockHeader(node: second)

        let result = try await level.admitBlockHeaderChainLocal(
            secondHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .protocolInvalid)
        let containsSecond = await level.chain.contains(blockHash: secondHeader.rawCID)
        XCTAssertFalse(containsSecond)

        let targetMiss = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 3_000,
            target: UInt256(1),
            nonce: 2,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(targetMiss.proofOfWorkHash(), targetMiss.target)
        let missResult = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: targetMiss),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        guard case .carrier = missResult else {
            return XCTFail("a parentless target miss is carrier data only")
        }
        XCTAssertEqual(
            missResult.parentCarrierLink?.carrierCID,
            try BlockHeader(node: targetMiss).rawCID
        )
    }

    func testNotYetAdmissibleCandidateIsDeferredByTypedOutcome() async throws {
        let fetcher = StorableFetcher()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: now - 100_000)
        let future = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: now + 60_000,
            nonce: 1
        )

        let result = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            try BlockHeader(node: future),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .notYetAdmissible)
    }

    func testStorageAndStageFailuresLeaveNoVisibleMutation() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let level = makeLevel(genesis: genesis)
        let beforeTip = await level.chain.getMainChainTip()
        let candidateHash = try BlockHeader(node: candidate).rawCID

        do {
            _ = try await level.admitBlockHeaderChainLocal(
                try BlockHeader(node: candidate),
                fetcher: fetcher,
                validationContentStorer: FailingAdmissionStorer(),
                materializedVolumeStorer: FailingAdmissionStorer(),
                stage: testAdmissionStage
            )
            XCTFail("storage failure must abort admission")
        } catch ChainLocalTestError.storageFailure {}

        do {
            _ = try await level.admitBlockHeaderChainLocal(
                try BlockHeader(node: candidate),
                fetcher: fetcher,
                validationContentStorer: FailingVolumeAdmissionStorer(),
                materializedVolumeStorer: FailingVolumeAdmissionStorer(),
                stage: testAdmissionStage
            )
            XCTFail("Volume storage failure must abort admission")
        } catch ChainLocalTestError.storageFailure {}

        do {
            _ = try await level.admitBlockHeaderChainLocal(
                try BlockHeader(node: candidate),
                fetcher: fetcher,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: { _ in throw ChainLocalTestError.stageFailure }
            )
            XCTFail("node durability failure must abort admission")
        } catch ChainLocalTestError.stageFailure {}

        let afterTip = await level.chain.getMainChainTip()
        let containsCandidate = await level.chain.contains(blockHash: candidateHash)
        XCTAssertEqual(afterTip, beforeTip)
        XCTAssertFalse(containsCandidate)
    }

    func testChildAdmissionRequiresVerifiedProofAndThenAcceptsIt() async throws {
        let fixture = try await makeChildProofFixture()
        let header = try BlockHeader(node: fixture.candidate)

        let missingProof = try await fixture.childLevel.admitBlockHeaderChainLocal(
            header,
            fetcher: fixture.fetcher,
            validationContentStorer: fixture.fetcher,
            materializedVolumeStorer: fixture.fetcher,
            stage: testAdmissionStage
        )
        XCTAssertEqual(
            missingProof.crossChainEvidenceRequirement,
            .childProof(
                chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"],
                childCID: header.rawCID
            )
        )
        XCTAssertNil(missingProof.sameChainPredecessor)

        let admitted = try await fixture.childLevel.admitBlockHeaderChainLocal(
            header,
            fetcher: fixture.fetcher,
            childPackage: fixture.package,
            validationContentStorer: fixture.fetcher,
            materializedVolumeStorer: fixture.fetcher,
            stage: testAdmissionStage
        )
        if case .rejected(let failure, _, _) = admitted {
            return XCTFail("expected child admission, got \(failure)")
        }
        XCTAssertNotNil(admitted.materializedPostState)
        let childChain = await fixture.childLevel.chain
        let containsCandidate = await childChain.contains(blockHash: header.rawCID)
        XCTAssertTrue(containsCandidate)
    }

    func testAdmissionStagesBlockWithInitialWorkThenOnlyNewGrind() async throws {
        let fixture = try await makeChildProofFixture()
        let alternateCarrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": fixture.candidate],
            timestamp: 4_000,
            target: easy,
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

        let initial = try await fixture.childLevel.admitBlockHeaderChainLocal(
            header,
            fetcher: fixture.fetcher,
            childPackage: fixture.package,
            validationContentStorer: fixture.fetcher,
            materializedVolumeStorer: fixture.fetcher,
            stage: { context in await recorder.stage(context) }
        )
        let later = try await fixture.childLevel.admitBlockHeaderChainLocal(
            header,
            fetcher: fixture.fetcher,
            childPackage: try await childValidationPackage(
                proof: alternateProof,
                fetcher: fixture.fetcher
            ),
            validationContentStorer: fixture.fetcher,
            materializedVolumeStorer: fixture.fetcher,
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

    func testChildProofRequiresItsRootInTheProof() async throws {
        let fixture = try await makeChildProofFixture()
        let originalProof = fixture.package.proof
        let proofWithoutRoot = ChildBlockProof(
            rootCID: originalProof.rootCID,
            directoryPath: originalProof.directoryPath,
            entries: originalProof.entries.filter { $0.cid != originalProof.rootCID }
        )
        let package = ChildValidationPackage(proof: proofWithoutRoot)

        let result = try await fixture.childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: fixture.candidate),
            fetcher: fixture.fetcher,
            childPackage: package,
            validationContentStorer: fixture.fetcher,
            materializedVolumeStorer: fixture.fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
    }

    func testChildProofAcceptsAnyRootThatCommitsToTheChild() async throws {
        let fixture = try await makeChildProofFixture()
        let alternateCarrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": fixture.candidate],
            timestamp: 4_000,
            target: easy,
            nonce: 9,
            fetcher: fixture.fetcher
        )
        let alternateProof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: alternateCarrier),
            childDirectory: "Child",
            fetcher: fixture.fetcher
        )
        let package = ChildValidationPackage(proof: alternateProof)

        let result = try await fixture.childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: fixture.candidate),
            fetcher: fixture.fetcher,
            childPackage: package,
            validationContentStorer: fixture.fetcher,
            materializedVolumeStorer: fixture.fetcher,
            stage: testAdmissionStage
        )

        XCTAssertNil(result.failure)
    }

    func testChildProofRejectsConflictingPathEntries() async throws {
        let fixture = try await makeChildProofFixture()
        let proof = fixture.package.proof
        let first = try XCTUnwrap(proof.entries.first)
        let conflictingProof = ChildBlockProof(
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entries: proof.entries + [(first.cid, first.data + Data([0]))]
        )
        let package = ChildValidationPackage(proof: conflictingProof)

        let result = try await fixture.childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: fixture.candidate),
            fetcher: fixture.fetcher,
            childPackage: package,
            validationContentStorer: fixture.fetcher,
            materializedVolumeStorer: fixture.fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
    }

    func testChildProofRejectsDuplicatePathEntries() async throws {
        let fixture = try await makeChildProofFixture()
        let proof = fixture.package.proof
        let first = try XCTUnwrap(proof.entries.first)
        let duplicateProof = ChildBlockProof(
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entries: proof.entries + [first]
        )
        let package = ChildValidationPackage(proof: duplicateProof)

        let result = try await fixture.childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: fixture.candidate),
            fetcher: fixture.fetcher,
            childPackage: package,
            validationContentStorer: fixture.fetcher,
            materializedVolumeStorer: fixture.fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
    }

    func testChildProofRejectsUnrelatedPathEntries() async throws {
        let fixture = try await makeChildProofFixture()
        let proof = fixture.package.proof
        let paddedProof = ChildBlockProof(
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entries: proof.entries + [("unused", Data([0]))]
        )

        let result = try await fixture.childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: fixture.candidate),
            fetcher: fixture.fetcher,
            childPackage: ChildValidationPackage(proof: paddedProof),
            validationContentStorer: fixture.fetcher,
            materializedVolumeStorer: fixture.fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
    }

    func testChildWorkProofDoesNotRequireParentCarrierFact() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let candidate = try await makeChild(
            of: childGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2,
            parentChainBlock: parentGenesis
        )
        let parentCarrier = try await buildAndStoreBlock(
            previous: parentGenesis,
            children: ["Child": candidate],
            timestamp: 3_000,
            target: easy,
            nonce: 3,
            fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: parentCarrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let childLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let paddedProof = ChildBlockProof(
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entries: proof.entries + [("unused", Data([0]))]
        )
        let malformedBeforeAcquisition = try await childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: paddedProof),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        XCTAssertEqual(
            malformedBeforeAcquisition.failure,
            .providerMalformedEvidence
        )

        let surplusBeforeAcquisition = try await childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: fetcher,
            childPackage: ChildValidationPackage(
                proof: proof,
                parentGenesisLink: testParentGenesisLink(
                    directory: "Other",
                    childGenesisCID: try BlockHeader(node: childGenesis).rawCID,
                    parentStateCID: childGenesis.parentState.rawCID
                )
            ),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        XCTAssertEqual(surplusBeforeAcquisition.failure, .providerMalformedEvidence)

        let missing = try await childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: proof),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        guard case .accepted = missing else {
            return XCTFail("proof-derived work should admit without a carrier fact")
        }
        XCTAssertNil(missing.sameChainPredecessor)
    }

    func testTargetMissIntermediateStillRelaysDescendantWork() async throws {
        let fetcher = StorableFetcher()
        let nexusGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let middleGenesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 1
        )
        let forgedTarget = easy / UInt256(16)
        let forgedMiddle = try await buildAndStoreBlock(
            previous: middleGenesis,
            parentChainBlock: nexusGenesis,
            timestamp: 2_000,
            target: forgedTarget,
            nextTarget: forgedTarget,
            nonce: 2,
            fetcher: fetcher
        )
        let root = try await buildAndStoreBlock(
            previous: nexusGenesis,
            children: ["Middle": forgedMiddle],
            timestamp: 3_000,
            target: easy,
            nonce: 3,
            fetcher: fetcher
        )

        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Middle",
            fetcher: fetcher
        )
        let middleLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: middleGenesis),
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Middle"]
            )
        )
        let result = try await middleLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: forgedMiddle),
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: proof),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertNil(result.failure)
        XCTAssertEqual(
            result.parentCarrierLink?.carrierCID,
            try BlockHeader(node: forgedMiddle).rawCID
        )
    }

    func testValidatedGenesisActionUpdatesParentState() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let childCID = try BlockHeader(node: childGenesis).rawCID
        let keyPair = CryptoUtils.generateKeyPair()
        let owner = testAddress(publicKey: keyPair.publicKey)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: owner, delta: Int64(chainLocalSpec().initialReward))],
            actions: [],
            depositActions: [],
            genesisActions: [GenesisAction(
                directory: "Child",
                blockCID: childCID
            )],
            receiptActions: [],
            withdrawalActions: [],
            signers: [owner],
            fee: 0,
            nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let anchor = try await buildAndStoreBlock(
            previous: parentGenesis,
            transactions: [signedTestTransaction(body, by: keyPair)],
            timestamp: 2_000,
            target: easy,
            nonce: 2,
            fetcher: fetcher
        )
        let parentLevel = makeLevel(genesis: parentGenesis)
        let admission = try await parentLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: anchor),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        if case .rejected(let failure, _, _) = admission {
            return XCTFail("parent anchor should validate: \(failure)")
        }

        let resolvedState = try await anchor.postState.resolve(
            paths: [[GENESIS_STATE_PROPERTY, "Child"]: .targeted],
            fetcher: fetcher
        )
        let storedChildCID = try XCTUnwrap(
            resolvedState.node?.genesisState.node?.get(key: "Child")
        )
        XCTAssertEqual(storedChildCID, childCID)

    }

    func testSecondChildRootPinsItsMaterializedVolumes() async throws {
        let fetcher = StorableFetcher()
        let durable = RecordingAdmissionStorer()
        let firstRoot = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 1
        )
        let transaction = unsignedStateChangingGenesisTransaction(
            key: "materialized",
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
        )
        let secondRoot = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2,
            transactions: [transaction]
        )
        let carrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": secondRoot],
            timestamp: 3_000,
            target: easy,
            nonce: 3,
            fetcher: fetcher
        )
        let childLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: firstRoot),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let secondHeader = try BlockHeader(node: secondRoot)
        let package = try await childValidationPackage(
            proof: proof,
            fetcher: fetcher,
            parentGenesisLink: testParentGenesisLink(
                directory: "Child",
                childGenesisCID: secondHeader.rawCID,
                parentStateCID: secondRoot.parentState.rawCID
            )
        )

        let result = try await childLevel.admitBlockHeaderChainLocal(
            secondHeader,
            fetcher: fetcher,
            childPackage: package,
            validationContentStorer: durable,
            materializedVolumeStorer: durable,
            stage: testAdmissionStage
        )

        let diff: StateDiff
        switch result {
        case .accepted(let acceptance):
            diff = try XCTUnwrap(acceptance.stateDiff)
        case .duplicate:
            return XCTFail("second root must not be a duplicate")
        case .carrier:
            return XCTFail("second root must execute its genesis transition")
        case .rejected(let failure, _, _):
            return XCTFail("expected second child root admission, got \(failure)")
        }
        XCTAssertNotNil(result.materializedPostState)
        XCTAssertFalse(diff.created.isEmpty)
        let roots = await durable.volumeRoots()
        XCTAssertTrue(roots.contains(secondRoot.postState.rawCID))
        for (cid, createdCount) in diff.created
        where createdCount > diff.replaced[cid, default: 0] {
            XCTAssertTrue(roots.contains(cid), "materialized Volume \(cid) was not pinned")
        }
        let childChain = await childLevel.chain
        let containsSecondRoot = await childChain.contains(blockHash: secondHeader.rawCID)
        XCTAssertTrue(containsSecondRoot)
    }

    func testPublicBootstrapRequiresVerifiedGenesisAndStorage() async throws {
        let fetcher = StorableFetcher()
        let transaction = unsignedStateChangingGenesisTransaction(
            key: "bootstrap",
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
        )
        let childGenesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 1,
            transactions: [transaction]
        )
        let context = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        let header = try BlockHeader(node: childGenesis)
        // The self-contained genesis is authorized solely by the parent's record
        // (ParentGenesisLink), bound to the empty parent state. No carrier proof.
        let genesisLink = testParentGenesisLink(
            directory: "Child",
            childGenesisCID: header.rawCID,
            parentStateCID: childGenesis.parentState.rawCID
        )

        // A ParentGenesisLink that does not authorize this exact genesis (wrong
        // recorded state) is rejected — the record gate is the sole authorization.
        let wrongFact = try await ChainLevel.bootstrap(
            context: context,
            genesisHeader: header,
            fetcher: fetcher,
            parentGenesisLink: testParentGenesisLink(
                directory: "Child",
                childGenesisCID: header.rawCID,
                parentStateCID: testCID("wrong-deployment-state")
            ),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        XCTAssertEqual(wrongFact.failure, .providerMalformedEvidence)
        XCTAssertEqual(wrongFact.parentCarrierLink.carrierCID, header.rawCID)

        do {
            _ = try await ChainLevel.bootstrap(
                context: context,
                genesisHeader: header,
                fetcher: fetcher,
                parentGenesisLink: genesisLink,
                validationContentStorer: FailingAdmissionStorer(),
                materializedVolumeStorer: FailingAdmissionStorer(),
                stage: testAdmissionStage
            )
            XCTFail("storage must gate first-root visibility")
        } catch ChainLocalTestError.storageFailure {}

        let bootstrapResult = try await ChainLevel.bootstrap(
            context: context,
            genesisHeader: header,
            fetcher: fetcher,
            parentGenesisLink: genesisLink,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        guard case .accepted(let bootstrap) = bootstrapResult else {
            return XCTFail("the target-hit child genesis must bootstrap")
        }
        let child = bootstrap.level
        XCTAssertFalse(bootstrap.stateDiff.created.isEmpty)
        XCTAssertNotNil(bootstrap.materializedPostState)
        XCTAssertEqual(
            bootstrap.commit,
            ChainCommit(
                tipHash: header.rawCID,
                mainChainBlocksAdded: [header.rawCID: 0]
            )
        )
        let childTip = await child.chain.getMainChainTip()
        XCTAssertEqual(childTip, header.rawCID)

        let nonGenesis = try await makeChild(
            of: childGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2
        )
        do {
            _ = try await ChainLevel.bootstrap(
                context: context,
                genesisHeader: try BlockHeader(node: nonGenesis),
                fetcher: fetcher,
                parentGenesisLink: genesisLink,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: testAdmissionStage
            )
            XCTFail("a non-genesis block cannot create a child runtime")
        } catch let failure as ChainAdmissionFailure {
            XCTAssertEqual(failure, .protocolInvalid)
        }
    }

    func testPublicRootBootstrapStagesTransactionGenesisBeforeVisibility() async throws {
        let fetcher = StorableFetcher()
        let transaction = unsignedStateChangingGenesisTransaction(
            key: "root-bootstrap",
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let genesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [transaction]
        )
        let header = try BlockHeader(node: genesis)
        let context = testChainContext(path: [DEFAULT_ROOT_DIRECTORY])

        do {
            _ = try await ChainLevel.bootstrap(
                context: context,
                genesisHeader: header,
                fetcher: fetcher,
                validationContentStorer: FailingAdmissionStorer(),
                materializedVolumeStorer: FailingAdmissionStorer(),
                stage: testAdmissionStage
            )
            XCTFail("storage must gate root visibility")
        } catch ChainLocalTestError.storageFailure {}

        do {
            _ = try await ChainLevel.bootstrap(
                context: context,
                genesisHeader: header,
                fetcher: fetcher,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: { _ in throw ChainLocalTestError.stageFailure }
            )
            XCTFail("staging must gate root visibility")
        } catch ChainLocalTestError.stageFailure {}

        let recorder = AdmissionStageRecorder()
        let result = try await ChainLevel.bootstrap(
            context: context,
            genesisHeader: header,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: { batch in await recorder.stage(batch) }
        )

        XCTAssertFalse(result.stateDiff.created.isEmpty)
        XCTAssertNotNil(result.materializedPostState)
        let rootChain = await result.level.chain
        let rootTip = await rootChain.getMainChainTip()
        XCTAssertEqual(rootTip, header.rawCID)
        let batches = await recorder.recordedBatches()
        XCTAssertEqual(batches.count, 1)
        let restored = try await ChainState.restore(replaying: batches)
        let restoredTip = await restored.getMainChainTip()
        let restoredRevision = await restored.currentRevision()
        let liveRevision = await rootChain.currentRevision()
        XCTAssertEqual(restoredTip, rootTip)
        XCTAssertEqual(restoredRevision, liveRevision)
    }

    func testGenesisPolicyResourceLimitIsUnavailableNotConsensus() async throws {
        // A policy module declaring more initial memory than THIS node's limit
        // must yield an UNAVAILABLE verdict (this node cannot verify), never
        // protocolInvalid — otherwise two nodes with different limits fork on the
        // same genesis. Raising the node-local limit (injected via
        // ValidationContext) admits the very same block.
        let fetcher = StorableFetcher()
        let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: Data(try wat2wasm("""
        (module
          (memory (export "memory") 33)
          (func (export "lattice_alloc") (param $len i32) (result i32) i32.const 1024)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """))))
        try await module.storeRecursively(storer: fetcher)
        let policy = WasmPolicyRef(moduleCID: module.rawCID, scope: .transaction)
        let genesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(wasmPolicies: [policy]),
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let header = try BlockHeader(node: genesis)
        let context = testChainContext()

        // Default limit (2 MiB) < 33 pages (2.06 MiB): unavailable, not invalid.
        do {
            _ = try await ChainLevel.bootstrap(
                context: context, genesisHeader: header, fetcher: fetcher,
                validationContentStorer: fetcher, materializedVolumeStorer: fetcher,
                stage: testAdmissionStage)
            XCTFail("oversized policy must fail admission on the limited node")
        } catch let failure as ChainAdmissionFailure {
            XCTAssertEqual(failure, .unavailableEvidence)
        }

        // Same block, node with a raised limit injected via ValidationContext.
        let raised = ValidationContext(
            nowMilliseconds: 10_000,
            wasmResourceLimits: WasmPolicyResourceLimits(maxMemoryBytes: 4 * 1024 * 1024))
        let result = try await ChainLevel.bootstrap(
            context: context, genesisHeader: header, fetcher: fetcher,
            validationContext: raised,
            validationContentStorer: fetcher, materializedVolumeStorer: fetcher,
            stage: testAdmissionStage)
        let tip = await result.level.chain.getMainChainTip()
        XCTAssertEqual(tip, header.rawCID)
    }

    func testGenesisBootstrapRequiresUnsignedTransactions() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [unsignedStateChangingGenesisTransaction(
                key: "unsigned-root",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        let header = try BlockHeader(node: genesis)
        let context = testChainContext(path: [DEFAULT_ROOT_DIRECTORY])

        let direct = try await genesis.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        XCTAssertTrue(direct.0)

        let result = try await ChainLevel.bootstrap(
            context: context,
            genesisHeader: header,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        let rootTip = await result.level.chain.getMainChainTip()
        XCTAssertEqual(rootTip, header.rawCID)
        XCTAssertEqual(
            result.commit,
            ChainCommit(
                tipHash: header.rawCID,
                mainChainBlocksAdded: [header.rawCID: 0]
            )
        )
    }

    func testGenesisBootstrapDoesNotRelaxLaterTransactions() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [unsignedStateChangingGenesisTransaction(
                key: "unsigned-root",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        let genesisHeader = try BlockHeader(node: genesis)
        let bootstrap = try await ChainLevel.bootstrap(
            context: testChainContext(),
            genesisHeader: genesisHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        let unsignedBody = TransactionBody(
            accountActions: [],
            actions: [Action(key: "unsigned-height-one", oldValue: nil, newValue: "value")],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            fee: 0,
            nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let unsignedTransaction = Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: unsignedBody)
        )
        let candidate = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [unsignedTransaction],
            timestamp: 2_000,
            target: easy,
            nonce: 1,
            fetcher: fetcher
        )

        let result = try await bootstrap.level.admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        XCTAssertEqual(result.failure, .protocolInvalid)
    }

    func testGenesisBootstrapIgnoresSignatures() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [signedStateChangingGenesisTransaction(
                key: "signed-root",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        let header = try BlockHeader(node: genesis)

        _ = try await ChainLevel.bootstrap(
            context: testChainContext(),
            genesisHeader: header,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
    }

    func testGenesisBootstrapIgnoresEverySignatureShape() async throws {
        let keyPair = CryptoUtils.generateKeyPair()
        let signer = testAddress(publicKey: keyPair.publicKey)

        func body(signers: [String]) -> TransactionBody {
            TransactionBody(
                accountActions: [],
                actions: [Action(key: "malformed-pair", oldValue: nil, newValue: "value")],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: signers,
                fee: 0,
                nonce: 0,
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )
        }

        let declaredButUnsigned = Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: body(signers: [signer]))
        )
        let signedButUndeclared = signedTestTransaction(body(signers: []), by: keyPair)
        let invalidSignature = Transaction(
            signatures: [keyPair.publicKey: "not-a-signature"],
            body: try HeaderImpl<TransactionBody>(node: body(signers: [signer]))
        )

        for transaction in [declaredButUnsigned, signedButUndeclared, invalidSignature] {
            let fetcher = StorableFetcher()
            let genesis = try await makeGenesis(
                fetcher: fetcher,
                timestamp: 1_000,
                transactions: [transaction]
            )
            let header = try BlockHeader(node: genesis)
            _ = try await ChainLevel.bootstrap(
                context: testChainContext(),
                genesisHeader: header,
                fetcher: fetcher,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: testAdmissionStage
            )
        }
    }

    func testSameCarrierChildDeploymentBootstrapsFromParentIssuedFacts() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let parentLevel = makeLevel(genesis: parentGenesis)
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: chainLocalSpec(),
            parentState: LatticeState.emptyHeader,
            transactions: [unsignedStateChangingGenesisTransaction(
                key: "child-genesis",
                chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
            )],
            timestamp: 1_500,
            target: easy,
            fetcher: fetcher
        )
        try await storeBuiltBlock(childGenesis, in: fetcher)
        let childHeader = try BlockHeader(node: childGenesis)

        let keyPair = CryptoUtils.generateKeyPair()
        let owner = testAddress(publicKey: keyPair.publicKey)
        let anchorBody = TransactionBody(
            accountActions: [AccountAction(
                owner: owner,
                delta: Int64(chainLocalSpec().initialReward)
            )],
            actions: [],
            depositActions: [],
            genesisActions: [GenesisAction(
                directory: "Child",
                blockCID: childHeader.rawCID
            )],
            receiptActions: [],
            withdrawalActions: [],
            signers: [owner],
            fee: 0,
            nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let carrier = try await buildAndStoreBlock(
            previous: parentGenesis,
            transactions: [signedTestTransaction(anchorBody, by: keyPair)],
            timestamp: 2_000,
            target: easy,
            nonce: 2,
            fetcher: fetcher
        )
        let carrierHeader = try BlockHeader(node: carrier)

        let admission = try await parentLevel.admitBlockHeaderChainLocal(
            carrierHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        if case .rejected(let failure, _, _) = admission {
            return XCTFail("same-carrier parent candidate should admit: \(failure)")
        }

        let carrierLink = try XCTUnwrap(admission.parentCarrierLink)
        XCTAssertEqual(carrierLink.parentPath, [DEFAULT_ROOT_DIRECTORY])
        XCTAssertEqual(carrierLink.carrierCID, carrierHeader.rawCID)
        XCTAssertEqual(carrierLink.rootCID, carrierHeader.rawCID)

        let genesisLink = ParentGenesisLink(
            parentPath: [DEFAULT_ROOT_DIRECTORY],
            directory: "Child",
            childGenesisCID: childHeader.rawCID,
            parentStateCID: LatticeState.emptyHeader.rawCID
        )

        let childBootstrapResult = try await ChainLevel.bootstrap(
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"]),
            genesisHeader: childHeader,
            fetcher: fetcher,
            parentGenesisLink: genesisLink,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        guard case .accepted(let childBootstrap) = childBootstrapResult else {
            return XCTFail("same-carrier deployment must bootstrap the child")
        }
        let childTip = await childBootstrap.level.chain.getMainChainTip()
        XCTAssertEqual(childTip, childHeader.rawCID)
    }

    func testActiveChildRelaysAuthenticatedAlternateGenesisTargetMiss() async throws {
        let fetcher = StorableFetcher()
        let nexusGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let alternate = try await BlockBuilder.buildChildGenesis(
            spec: chainLocalSpec(),
            parentState: nexusGenesis.postState,
            timestamp: 1_500,
            target: UInt256(1),
            fetcher: fetcher
        )
        try await storeBuiltBlock(alternate, in: fetcher)
        let alternateHeader = try BlockHeader(node: alternate)
        let keyPair = CryptoUtils.generateKeyPair()
        let owner = testAddress(publicKey: keyPair.publicKey)
        let anchorBody = TransactionBody(
            accountActions: [AccountAction(
                owner: owner,
                delta: Int64(chainLocalSpec().initialReward)
            )],
            actions: [],
            depositActions: [],
            genesisActions: [GenesisAction(
                directory: "Child",
                blockCID: alternateHeader.rawCID
            )],
            receiptActions: [],
            withdrawalActions: [],
            signers: [owner],
            fee: 0,
            nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let root = try await buildAndStoreBlock(
            previous: nexusGenesis,
            transactions: [signedTestTransaction(anchorBody, by: keyPair)],
            children: ["Child": alternate],
            timestamp: 2_000,
            target: easy,
            nonce: 2,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(root.proofOfWorkHash(), alternate.target)

        let nexusLevel = makeLevel(genesis: nexusGenesis)
        let rootHeader = try BlockHeader(node: root)
        _ = try await nexusLevel.admitBlockHeaderChainLocal(
            rootHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        let genesisLink = ParentGenesisLink(
            parentPath: [DEFAULT_ROOT_DIRECTORY],
            directory: "Child",
            childGenesisCID: alternateHeader.rawCID,
            parentStateCID: root.prevState.rawCID
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: rootHeader,
            childDirectory: "Child",
            fetcher: fetcher
        )
        let activeGenesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 9,
        )
        let activeLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: activeGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let result = try await activeLevel.admitBlockHeaderChainLocal(
            alternateHeader,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(
                proof: proof,
                parentGenesisLink: genesisLink
            ),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        guard case .carrier(let link, _) = result else {
            return XCTFail("authenticated alternate root must remain a carrier")
        }
        let issued = try XCTUnwrap(link)
        XCTAssertEqual(issued.parentPath, [DEFAULT_ROOT_DIRECTORY, "Child"])
        XCTAssertEqual(issued.carrierCID, alternateHeader.rawCID)
        XCTAssertEqual(issued.rootCID, rootHeader.rawCID)
        let stored = await activeLevel.chain.contains(blockHash: alternateHeader.rawCID)
        XCTAssertFalse(stored)
    }

    func testChildBootstrapAcceptsUnsignedGenesisTransactions() async throws {
        let fetcher = StorableFetcher()
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: chainLocalSpec(),
            parentState: LatticeState.emptyHeader,
            transactions: [unsignedStateChangingGenesisTransaction(
                key: "unsigned-child",
                chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
            )],
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        try await storeBuiltBlock(childGenesis, in: fetcher)
        let childHeader = try BlockHeader(node: childGenesis)

        let result = try await ChainLevel.bootstrap(
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Child"]
            ),
            genesisHeader: childHeader,
            fetcher: fetcher,
            parentGenesisLink: testParentGenesisLink(
                directory: "Child",
                childGenesisCID: childHeader.rawCID,
                parentStateCID: childGenesis.parentState.rawCID
            ),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.parentCarrierLink.carrierCID, childHeader.rawCID)
    }

    func testGenesisDifficultySeedIsValidatedBeforeStorageOrStaging() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let forged = Block(
            version: genesis.version,
            parent: genesis.parent,
            transactions: genesis.transactions,
            target: genesis.target,
            nextTarget: genesis.target - UInt256(1),
            spec: genesis.spec,
            parentState: genesis.parentState,
            prevState: genesis.prevState,
            postState: genesis.postState,
            children: genesis.children,
            height: genesis.height,
            timestamp: genesis.timestamp,
            nonce: genesis.nonce
        )
        try await storeBuiltBlock(forged, in: fetcher)
        let direct = try await forged.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        XCTAssertFalse(direct.0)
        XCTAssertFalse(GenesisCeremony.verify(
            block: forged,
            config: GenesisConfig(
                spec: chainLocalSpec(),
                timestamp: forged.timestamp
            )
        ))

        let durable = RecordingAdmissionStorer()
        let recorder = AdmissionStageRecorder()
        do {
            _ = try await ChainLevel.bootstrap(
                context: testChainContext(),
                genesisHeader: try BlockHeader(node: forged),
                fetcher: fetcher,
                validationContentStorer: durable,
                materializedVolumeStorer: durable,
                stage: { batch in await recorder.stage(batch) }
            )
            XCTFail("genesis must seed its first successor with its own target")
        } catch let failure as ChainAdmissionFailure {
            XCTAssertEqual(failure, .protocolInvalid)
        }
        let storeCalls = await durable.storeCallCount()
        let staged = await recorder.recordedBatches()
        XCTAssertEqual(storeCalls, 0)
        XCTAssertTrue(staged.isEmpty)
    }

    func testRootBootstrapRejectsTargetMissWithoutStoring() async throws {
        let fetcher = StorableFetcher()
        let durable = RecordingAdmissionStorer()
        let recorder = AdmissionStageRecorder()

        let hardGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 2_000,
            target: UInt256(1),
            nonce: 1,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(hardGenesis.proofOfWorkHash(), hardGenesis.target)
        do {
            _ = try await ChainLevel.bootstrap(
                context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY]),
                genesisHeader: try BlockHeader(node: hardGenesis),
                fetcher: fetcher,
                validationContentStorer: durable,
                materializedVolumeStorer: durable,
                stage: { batch in await recorder.stage(batch) }
            )
            XCTFail("a target miss cannot bootstrap the root")
        } catch let failure as ChainAdmissionFailure {
            XCTAssertEqual(failure, .notAcceptedAtCurrentChain)
        }
        let targetMissStoreCalls = await durable.storeCallCount()
        let targetMissBatches = await recorder.recordedBatches()
        XCTAssertEqual(targetMissStoreCalls, 0)
        XCTAssertTrue(targetMissBatches.isEmpty)
    }

    func testChildAcceptsWhenAncestorCarrierMissesItsOwnTarget() async throws {
        let fetcher = StorableFetcher()
        let parentTemplate = try await makeGenesis(fetcher: fetcher, timestamp: 500)
        let childGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let candidate = try await makeChild(
            of: childGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2,
            parentChainBlock: parentTemplate
        )
        let carrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": candidate],
            timestamp: 3_000,
            target: .zero,
            nonce: 3,
            fetcher: fetcher
        )
        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let package = try await childValidationPackage(proof: proof, fetcher: fetcher)
        let candidateHeader = try BlockHeader(node: candidate)

        let result = try await level.admitBlockHeaderChainLocal(
            candidateHeader,
            fetcher: fetcher,
            childPackage: package,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        if case .rejected(let failure, _, _) = result {
            return XCTFail("an ancestor target miss must not invalidate its child: \(failure)")
        }
        let containsCandidate = await level.chain.contains(blockHash: candidateHeader.rawCID)
        XCTAssertTrue(containsCandidate)
    }

    func testCurrentChainTargetMissReturnsCarrierWithoutMutation() async throws {
        let fetcher = StorableFetcher()
        let hardTarget = UInt256(1)
        let parentTemplate = try await makeGenesis(fetcher: fetcher, timestamp: 500)
        let childGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 1_000,
            target: hardTarget,
            nonce: 1,
            fetcher: fetcher
        )
        let candidate = try await buildAndStoreBlock(
            previous: childGenesis,
            parentChainBlock: parentTemplate,
            timestamp: 2_000,
            target: hardTarget,
            nextTarget: easy,
            nonce: 2,
            fetcher: fetcher
        )
        let carrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": candidate],
            timestamp: 3_000,
            target: easy,
            nonce: 3,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(carrier.proofOfWorkHash(), hardTarget)
        XCTAssertFalse(candidate.validateNextTarget(
            spec: chainLocalSpec(),
            parent: childGenesis,
            difficultyAnchor: DifficultyAnchor(
                blockHeight: 1,
                timestamp: candidate.timestamp, target: candidate.target
            )
        ))
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let package = try await childValidationPackage(proof: proof, fetcher: fetcher)
        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let recorder = AdmissionStageRecorder()
        let durable = RecordingAdmissionStorer()
        let candidateHeader = try BlockHeader(node: candidate)

        let result = try await level.admitBlockHeaderChainLocal(
            candidateHeader,
            fetcher: fetcher,
            childPackage: package,
            validationContentStorer: durable,
            materializedVolumeStorer: durable,
            stage: { record in await recorder.stage(record) }
        )

        guard case .carrier = result else {
            return XCTFail("a current-level target miss must remain a descendant carrier")
        }
        let link = try XCTUnwrap(result.parentCarrierLink)
        XCTAssertEqual(link.parentPath, [DEFAULT_ROOT_DIRECTORY, "Child"])
        XCTAssertEqual(link.carrierCID, candidateHeader.rawCID)
        XCTAssertEqual(link.rootCID, proof.rootCID)
        let stageCount = await recorder.count(for: candidateHeader.rawCID)
        let containsCarrier = await level.chain.contains(blockHash: candidateHeader.rawCID)
        XCTAssertEqual(stageCount, 0)
        XCTAssertFalse(containsCarrier)
        let storeCalls = await durable.storeCallCount()
        XCTAssertEqual(storeCalls, 0)
    }

    func testDisconnectedTargetMissRelaysWithoutAcquiringPredecessor() async throws {
        let fetcher = StorableFetcher()
        let parentTemplate = try await makeGenesis(fetcher: fetcher, timestamp: 500)
        let childGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let missingPredecessor = try await buildAndStoreBlock(
            previous: childGenesis,
            parentChainBlock: parentTemplate,
            timestamp: 1_001,
            target: easy,
            nonce: 1,
            fetcher: fetcher
        )
        // An explicitly hard target, because this test needs a block the root's
        // proof of work MISSES. Inheriting the scheduled target no longer
        // produces one: the predecessor is height 1, so it anchors the schedule
        // at its own `easy` target rather than retargeting away from it, and
        // nothing can miss a maximum target. Committing harder than the schedule
        // is permitted — `target <= parent.nextTarget` — and it is the miss, not
        // its provenance, that this test is about.
        let candidate = try await buildAndStoreBlock(
            previous: missingPredecessor,
            parentChainBlock: parentTemplate,
            timestamp: 1_002,
            target: UInt256(1),
            nonce: 2,
            fetcher: fetcher
        )
        let root = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": candidate],
            timestamp: 4_000,
            target: easy,
            nonce: 3,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(root.proofOfWorkHash(), candidate.target)
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let candidateHeader = try BlockHeader(node: candidate)
        let candidatePackage = try await childValidationPackage(
            proof: proof,
            fetcher: fetcher
        )
        let result = try await level.admitBlockHeaderChainLocal(
            candidateHeader,
            fetcher: fetcher,
            childPackage: candidatePackage,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        guard case .carrier = result else {
            return XCTFail("a valid target miss remains a carrier")
        }
        XCTAssertEqual(
            result.parentCarrierLink?.carrierCID,
            candidateHeader.rawCID
        )
        XCTAssertNil(result.sameChainPredecessor)
    }

    func testBootstrapDoesNotStageCarrierOnCurrentChainTargetMiss() async throws {
        let fetcher = StorableFetcher()
        let childGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 1_000,
            target: UInt256(1),
            nonce: 1,
            fetcher: fetcher
        )
        let header = try BlockHeader(node: childGenesis)
        let recorder = AdmissionStageRecorder()

        let result = try await ChainLevel.bootstrap(
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"]),
            genesisHeader: header,
            fetcher: fetcher,
            parentGenesisLink: testParentGenesisLink(
                directory: "Child",
                childGenesisCID: header.rawCID,
                parentStateCID: childGenesis.parentState.rawCID
            ),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: { record in await recorder.stage(record) }
        )
        guard case .carrier(let link) = result else {
            return XCTFail("a target-miss child genesis must remain a carrier")
        }
        XCTAssertEqual(link.parentPath, [DEFAULT_ROOT_DIRECTORY, "Child"])
        XCTAssertEqual(link.carrierCID, header.rawCID)
        XCTAssertEqual(link.rootCID, header.rawCID)
        let stageCount = await recorder.count(for: header.rawCID)
        XCTAssertEqual(stageCount, 0)
    }

    func testUnbootstrappedIntermediateGenesisRelaysTargetMissToGrandchild() async throws {
        let fetcher = StorableFetcher()
        let parentTemplate = try await makeGenesis(fetcher: fetcher, timestamp: 500)
        let leafGenesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 1
        )
        let leaf = try await makeChild(
            of: leafGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2,
            parentChainBlock: parentTemplate
        )
        let middle = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Leaf": leaf],
            timestamp: 3_000,
            target: UInt256(1),
            nonce: 3,
            fetcher: fetcher
        )
        let root = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Middle": middle],
            timestamp: 4_000,
            target: easy,
            nonce: 4,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(root.proofOfWorkHash(), middle.target)

        let rootHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Middle",
            fetcher: fetcher
        )
        let middleResult = try await ChainLevel.bootstrap(
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Middle"]
            ),
            genesisHeader: try BlockHeader(node: middle),
            fetcher: fetcher,
            parentGenesisLink: testParentGenesisLink(
                directory: "Middle",
                childGenesisCID: try BlockHeader(node: middle).rawCID,
                parentStateCID: middle.parentState.rawCID
            ),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        guard case .carrier = middleResult else {
            return XCTFail("the target-miss intermediate must not require a runtime")
        }

        let leafHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: middle),
            childDirectory: "Leaf",
            fetcher: fetcher
        )
        let leafProof = rootHop.composing(hop: leafHop)
        let leafLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: leafGenesis),
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"]
            )
        )
        let admitted = try await leafLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: leaf),
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: leafProof),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        if case .rejected(let failure, _, _) = admitted {
            return XCTFail("grandchild must accept through target-miss parent: \(failure)")
        }
        let containsLeaf = await leafLevel.chain.contains(
            blockHash: try BlockHeader(node: leaf).rawCID
        )
        XCTAssertTrue(containsLeaf)
    }

    func testTargetHitInvalidIntermediateStillRelaysGrandchild() async throws {
        let fetcher = StorableFetcher()
        let leafGenesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 1
        )
        let middleTemplate = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_500,
            nonce: 2
        )
        let leaf = try await makeChild(
            of: leafGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 3,
            parentChainBlock: middleTemplate
        )
        let validMiddle = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            transactions: [unsignedStateChangingGenesisTransaction(
                key: "invalid-middle",
                chainPath: [DEFAULT_ROOT_DIRECTORY, "Middle"]
            )],
            children: ["Leaf": leaf],
            timestamp: 3_000,
            target: easy,
            nonce: 4,
            fetcher: fetcher
        )
        XCTAssertNotEqual(
            validMiddle.postState.rawCID,
            LatticeState.emptyHeader.rawCID
        )
        let invalidMiddle = Block(
            version: validMiddle.version,
            parent: validMiddle.parent,
            transactions: validMiddle.transactions,
            target: validMiddle.target,
            nextTarget: validMiddle.nextTarget,
            spec: validMiddle.spec,
            parentState: validMiddle.parentState,
            prevState: validMiddle.prevState,
            postState: LatticeState.emptyHeader,
            children: validMiddle.children,
            height: validMiddle.height,
            timestamp: validMiddle.timestamp,
            nonce: validMiddle.nonce
        )
        try await storeBuiltBlock(invalidMiddle, in: fetcher)
        let root = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Middle": invalidMiddle],
            timestamp: 4_000,
            target: easy,
            nonce: 5,
            fetcher: fetcher
        )
        let middleHeader = try BlockHeader(node: invalidMiddle)
        let rootHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Middle",
            fetcher: fetcher
        )
        let recorder = AdmissionStageRecorder()
        let middleResult = try await ChainLevel.bootstrap(
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Middle"]
            ),
            genesisHeader: middleHeader,
            fetcher: fetcher,
            parentGenesisLink: testParentGenesisLink(
                directory: "Middle",
                childGenesisCID: middleHeader.rawCID,
                parentStateCID: invalidMiddle.parentState.rawCID
            ),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: { batch in await recorder.stage(batch) }
        )
        guard case .rejected(let failure, let middleLink) = middleResult else {
            return XCTFail("the invalid intermediate must report local rejection")
        }
        XCTAssertEqual(failure, .protocolInvalid)
        XCTAssertEqual(middleLink.carrierCID, middleHeader.rawCID)
        let stagedMiddle = await recorder.count(for: middleHeader.rawCID)
        XCTAssertEqual(stagedMiddle, 0)

        let leafHop = try await ChildBlockProof.generate(
            rootHeader: middleHeader,
            childDirectory: "Leaf",
            fetcher: fetcher
        )
        let leafLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: leafGenesis),
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"]
            )
        )
        let admitted = try await leafLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: leaf),
            fetcher: fetcher,
            childPackage: ChildValidationPackage(
                proof: rootHop.composing(hop: leafHop)
            ),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertNil(admitted.failure)
        let containsLeaf = await leafLevel.chain.contains(
            blockHash: try BlockHeader(node: leaf).rawCID
        )
        XCTAssertTrue(containsLeaf)
    }

    func testMissingParentContinuityFactStillRelaysGrandchildWork() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 500,
            transactions: [unsignedStateChangingGenesisTransaction(
                key: "parent-state",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        XCTAssertNotEqual(
            parentGenesis.prevState.rawCID,
            parentGenesis.postState.rawCID
        )
        let middleGenesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 2
        )
        let middlePredecessor = try await makeChild(
            of: middleGenesis,
            fetcher: fetcher,
            timestamp: 1_100,
            nonce: 3,
            parentChainBlock: parentGenesis
        )
        let leafGenesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 4
        )
        let middleTemplate = try await makeChild(
            of: middlePredecessor,
            fetcher: fetcher,
            timestamp: 1_200,
            nonce: 5
        )
        let leaf = try await makeChild(
            of: leafGenesis,
            fetcher: fetcher,
            timestamp: 1_300,
            nonce: 6,
            parentChainBlock: middleTemplate
        )
        let validMiddle = try await buildAndStoreBlock(
            previous: middlePredecessor,
            children: ["Leaf": leaf],
            timestamp: 1_200,
            nonce: 5,
            fetcher: fetcher
        )
        let invalidMiddle = Block(
            version: validMiddle.version,
            parent: validMiddle.parent,
            transactions: validMiddle.transactions,
            target: validMiddle.target,
            nextTarget: validMiddle.nextTarget,
            spec: validMiddle.spec,
            parentState: parentGenesis.postState,
            prevState: validMiddle.prevState,
            postState: validMiddle.postState,
            children: validMiddle.children,
            height: validMiddle.height,
            timestamp: validMiddle.timestamp,
            nonce: validMiddle.nonce
        )
        try await storeBuiltBlock(invalidMiddle, in: fetcher)
        let middleLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: middleGenesis),
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Middle"]
            )
        )
        let predecessorRoot = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Middle": middlePredecessor],
            timestamp: 2_000,
            target: easy,
            nonce: 7,
            fetcher: fetcher
        )
        let predecessorProof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: predecessorRoot),
            childDirectory: "Middle",
            fetcher: fetcher
        )
        let predecessorResult = try await middleLevel
            .admitBlockHeaderChainLocal(
                try BlockHeader(node: middlePredecessor),
                fetcher: fetcher,
                childPackage: ChildValidationPackage(
                    proof: predecessorProof
                ),
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: testAdmissionStage
            )
        guard case .accepted = predecessorResult else {
            return XCTFail("middle predecessor must connect")
        }
        let validLocal = try await validMiddle.validateNexus(
            fetcher: fetcher,
            chain: middleLevel.chain,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Middle"],
            reportTemporalFailure: true
        )
        XCTAssertTrue(validLocal.0)

        let rootTemplate = try await buildAndStoreBlock(
            previous: parentGenesis,
            children: ["Middle": invalidMiddle],
            timestamp: 2_100,
            target: easy,
            nonce: 8,
            fetcher: fetcher
        )
        let root = try XCTUnwrap(BlockBuilder.mine(
            block: rootTemplate,
            target: invalidMiddle.target,
            maxAttempts: 1_000_000
        ))
        try await storeBuiltBlock(root, in: fetcher)
        let rootHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Middle",
            fetcher: fetcher
        )
        guard case .success = await rootHop.verifySecuringWork(
            child: invalidMiddle,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Middle"]
        ) else {
            return XCTFail("structural work proof must verify")
        }
        let localValidation = try await invalidMiddle.validateNexus(
            fetcher: fetcher,
            chain: middleLevel.chain,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Middle"],
            reportTemporalFailure: true
        )
        XCTAssertTrue(localValidation.0)
        let middleHeader = try BlockHeader(node: invalidMiddle)
        let middleResult = try await middleLevel.admitBlockHeaderChainLocal(
            middleHeader,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: rootHop),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        guard case .some(
            .crossChainEvidenceRequired(.parentStateContinuity)
        ) = middleResult.failure else {
            return XCTFail(
                "missing parent-state gate must not admit: "
                    + String(describing: middleResult.failure)
            )
        }
        XCTAssertEqual(
            middleResult.parentCarrierLink?.carrierCID,
            middleHeader.rawCID
        )

        let leafHop = try await ChildBlockProof.generate(
            rootHeader: middleHeader,
            childDirectory: "Leaf",
            fetcher: fetcher
        )
        let leafLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: leafGenesis),
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"]
            )
        )
        let leafResult = try await leafLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: leaf),
            fetcher: fetcher,
            childPackage: ChildValidationPackage(
                proof: rootHop.composing(hop: leafHop)
            ),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        XCTAssertNil(leafResult.failure)
    }

    func testBrokenCarrierContinuityStillRelaysRealWork() async throws {
        let fetcher = StorableFetcher()
        let hardTarget = UInt256(1)
        let genesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 1_000,
            target: hardTarget,
            fetcher: fetcher
        )
        let valid = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2_000,
            target: hardTarget,
            nextTarget: hardTarget,
            nonce: 1,
            fetcher: fetcher
        )
        let malformedCarrier = Block(
            version: valid.version,
            parent: valid.parent,
            transactions: valid.transactions,
            target: valid.target,
            nextTarget: valid.nextTarget,
            spec: valid.spec,
            parentState: valid.parentState,
            prevState: valid.prevState,
            postState: valid.postState,
            children: valid.children,
            height: valid.height + 1,
            timestamp: valid.timestamp,
            nonce: valid.nonce
        )
        try await storeBuiltBlock(malformedCarrier, in: fetcher)
        XCTAssertGreaterThan(malformedCarrier.proofOfWorkHash(), hardTarget)

        let result = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            try BlockHeader(node: malformedCarrier),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        guard case .carrier(let link, _) = result else {
            return XCTFail("invalid same-chain structure must not erase real work")
        }
        XCTAssertEqual(
            link?.carrierCID,
            try BlockHeader(node: malformedCarrier).rawCID
        )
    }

    func testHeightOverflowFailsClosedInBuilder() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let overflowParent = Block(
            version: genesis.version,
            parent: genesis.parent,
            transactions: genesis.transactions,
            target: genesis.target,
            nextTarget: genesis.nextTarget,
            spec: genesis.spec,
            parentState: genesis.parentState,
            prevState: genesis.prevState,
            postState: genesis.postState,
            children: genesis.children,
            height: UInt64.max,
            timestamp: genesis.timestamp,
            nonce: genesis.nonce
        )

        do {
            _ = try await BlockBuilder.buildBlock(
                previous: overflowParent,
                timestamp: 2_000,
                fetcher: fetcher
            )
            XCTFail("height overflow must reject construction")
        } catch BlockBuilderError.heightOverflow {
            // Expected.
        }
    }

    func testMultiHopProofRequiresTheExactFullPath() async throws {
        let fetcher = StorableFetcher()
        let parentTemplate = try await makeGenesis(fetcher: fetcher, timestamp: 500)
        let leafGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let candidate = try await makeChild(
            of: leafGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2,
            parentChainBlock: parentTemplate
        )
        let middleCarrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Leaf": candidate],
            timestamp: 3_000,
            target: easy,
            nonce: 3,
            fetcher: fetcher
        )
        let rootCarrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Middle": middleCarrier],
            timestamp: 4_000,
            target: easy,
            nonce: 4,
            fetcher: fetcher
        )
        let rootHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: rootCarrier),
            childDirectory: "Middle",
            fetcher: fetcher
        )
        let leafHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: middleCarrier),
            childDirectory: "Leaf",
            fetcher: fetcher
        )
        let proof = rootHop.composing(hop: leafHop)
        let package = try await childValidationPackage(
            proof: proof,
            fetcher: fetcher
        )
        let candidateHeader = try BlockHeader(node: candidate)
        let wrongPath = ChainLevel(
            chain: ChainState.fromGenesis(block: leafGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Other"])
        )

        let rejected = try await wrongPath.admitBlockHeaderChainLocal(
            candidateHeader,
            fetcher: fetcher,
            childPackage: package,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        XCTAssertEqual(rejected.failure, .providerMalformedEvidence)

        let exactPath = ChainLevel(
            chain: ChainState.fromGenesis(block: leafGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"])
        )
        let proofOnly = try await exactPath.admitBlockHeaderChainLocal(
            candidateHeader,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: proof),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        guard case .accepted = proofOnly else {
            return XCTFail("the exact proof path should need no carrier fact")
        }

        let surplusEvidence = try await childValidationPackage(
            proof: proof,
            fetcher: fetcher,
            parentGenesisLink: testParentGenesisLink(
                directory: "Leaf",
                childGenesisCID: candidateHeader.rawCID,
                parentStateCID: candidate.parentState.rawCID,
                parentPath: [DEFAULT_ROOT_DIRECTORY, "Middle"]
            )
        )
        let duplicateWithSurplusEvidence = try await exactPath.admitBlockHeaderChainLocal(
            candidateHeader,
            fetcher: fetcher,
            childPackage: surplusEvidence,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        guard case .duplicate = duplicateWithSurplusEvidence else {
            return XCTFail("known blocks must not re-request parent facts")
        }

        let accepted = try await exactPath.admitBlockHeaderChainLocal(
            candidateHeader,
            fetcher: fetcher,
            childPackage: package,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        if case .rejected(let failure, _, _) = accepted {
            return XCTFail("the complete path should verify: \(failure)")
        }
        let containsCandidate = await exactPath.chain.contains(blockHash: candidateHeader.rawCID)
        XCTAssertTrue(containsCandidate)
    }

    func testProofBindsEvidenceToTheSuppliedChild() async throws {
        let fixture = try await makeChildProofFixture()
        let candidate = fixture.candidate
        let proof = fixture.package.proof
        let valid = await proof.verifySecuringWork(
            child: candidate,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
        )
        guard case .success(let evidence) = valid else {
            return XCTFail("fixture proof must verify")
        }
        XCTAssertEqual(
            evidence.childCID,
            try BlockHeader(node: candidate).rawCID
        )
        let carrier = await fixture.package.verifiedCarrierLink(
            child: candidate,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
        )
        guard case .success(let carrierLink) = carrier else {
            return XCTFail("verified proof must expose its relay link")
        }
        XCTAssertEqual(
            carrierLink.parentPath,
            [DEFAULT_ROOT_DIRECTORY, "Child"]
        )
        XCTAssertEqual(carrierLink.carrierCID, evidence.childCID)
        XCTAssertEqual(carrierLink.rootCID, proof.rootCID)

        let alternateRoot = await proof.verifySecuringWork(
            child: candidate,
            chainPath: ["Other", "Child"]
        )
        guard case .failure(let alternateRootFailure) = alternateRoot else {
            return XCTFail("proof verification must reject a non-Nexus root")
        }
        XCTAssertEqual(alternateRootFailure, .malformedEvidence)

        let impostor = Block(
            version: candidate.version,
            parent: candidate.parent,
            transactions: candidate.transactions,
            target: candidate.target,
            nextTarget: candidate.nextTarget,
            spec: candidate.spec,
            parentState: candidate.parentState,
            prevState: candidate.prevState,
            postState: candidate.postState,
            children: candidate.children,
            height: candidate.height,
            timestamp: candidate.timestamp,
            nonce: candidate.nonce + 1
        )
        let mismatched = await proof.verifySecuringWork(
            child: impostor,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
        )
        guard case .failure(let failure) = mismatched else {
            return XCTFail("proof evidence must not transfer to another child")
        }
        XCTAssertEqual(failure, .malformedEvidence)
    }

    func testInvalidTerminalGenesisIsRejectedBeforeParentEvidenceRequest() async throws {
        let fetcher = StorableFetcher()
        let validChild = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let invalidChild = Block(
            version: validChild.version,
            parent: nil,
            transactions: validChild.transactions,
            target: validChild.target,
            nextTarget: validChild.nextTarget,
            spec: validChild.spec,
            parentState: validChild.parentState,
            prevState: validChild.prevState,
            postState: validChild.postState,
            children: validChild.children,
            height: 1,
            timestamp: validChild.timestamp,
            nonce: validChild.nonce
        )
        try await storeBuiltBlock(invalidChild, in: fetcher)
        let carrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": invalidChild],
            timestamp: 2_000,
            target: easy,
            fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Child",
            fetcher: fetcher
        )

        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: validChild),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let result = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: invalidChild),
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: proof),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        XCTAssertEqual(result.failure, .protocolInvalid)
    }

    func testCreditComesFromTheRootMostMetTargetWhenTargetsEaseDownward() async throws {
        let outerTarget = UInt256.max / UInt256(16)
        let middleTarget = UInt256.max / UInt256(8)
        let leafTarget = UInt256.max / UInt256(4)

        let verified = try await verifiedMultiHopContribution(
            outerTarget: outerTarget,
            middleTarget: middleTarget,
            leafTarget: leafTarget,
            miningTarget: outerTarget
        )

        XCTAssertLessThanOrEqual(verified.rootHash, outerTarget)
        XCTAssertEqual(verified.contribution.id, verified.rootCID)
        XCTAssertEqual(verified.contribution.work, UInt256(16))
    }

    func testCreditedWorkSurvivesAdmissionAndReplay() async throws {
        let fixture = try await verifiedMultiHopContribution(
            outerTarget: UInt256.max / UInt256(16),
            middleTarget: UInt256.max / UInt256(8),
            leafTarget: UInt256.max / UInt256(4),
            miningTarget: UInt256.max / UInt256(16)
        )
        let expectedWork = UInt256(16)
        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: fixture.leafGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"])
        )
        let genesisBatch = try testAdmissionBatch(for: fixture.leafGenesis)
        let recorder = AdmissionStageRecorder()
        let candidateHeader = try BlockHeader(node: fixture.candidate)

        let admitted = try await level.admitBlockHeaderChainLocal(
            candidateHeader,
            fetcher: fixture.fetcher,
            childPackage: fixture.package,
            validationContentStorer: fixture.fetcher,
            materializedVolumeStorer: fixture.fetcher,
            stage: { batch in await recorder.stage(batch) }
        )
        guard case .accepted = admitted else {
            return XCTFail("the real multi-hop proof should admit")
        }
        XCTAssertEqual(fixture.contribution.work, expectedWork)
        let liveRecord = await level.chain.workContribution(id: fixture.rootCID)
        XCTAssertEqual(try XCTUnwrap(liveRecord).contribution, fixture.contribution)

        let batches = await recorder.recordedBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(
            batches.flatMap(\.facts).compactMap { fact -> VerifiedWorkContribution? in
                guard case .work(let work) = fact else { return nil }
                return work.contribution
            },
            [fixture.contribution]
        )
        let snapshotData = try JSONEncoder().encode(genesisBatch)
        let batchData = try JSONEncoder().encode(batches)
        let decodedGenesis = try JSONDecoder().decode(ChainAdmissionBatch.self, from: snapshotData)
        let decodedBatches = try JSONDecoder().decode([ChainAdmissionBatch].self, from: batchData)
        let restored = try await ChainState.restore(replaying: [decodedGenesis] + decodedBatches)
        let restoredRecord = await restored.workContribution(id: fixture.rootCID)
        XCTAssertEqual(try XCTUnwrap(restoredRecord).contribution, fixture.contribution)
    }

    /// A grind is priced by the ROOT-MOST carrier whose target it beat, not by
    /// the hardest one. Here the hierarchy is inverted — the middle chain is
    /// harder (max/16) than the root above it (max/4) — so the two rules
    /// disagree, and this pins which one governs.
    ///
    /// The old rule took a max over every met target and credited the middle
    /// chain's 16. That let a DEEPER chain set the price of a grind, which is
    /// backwards: depth is further from the work that secures the hierarchy,
    /// not closer to it.
    func testMultiHopProofCreditsRootMostMetTargetNotTheHardest() async throws {
        let outerTarget = UInt256.max / UInt256(4)
        let middleTarget = UInt256.max / UInt256(16)
        let leafTarget = UInt256.max / UInt256(8)

        let verified = try await verifiedMultiHopContribution(
            outerTarget: outerTarget,
            middleTarget: middleTarget,
            leafTarget: leafTarget,
            miningTarget: middleTarget
        )

        // Fixture guard: the hash must actually beat the harder middle target,
        // or the two rules would agree here and this would test nothing.
        XCTAssertLessThanOrEqual(
            verified.rootHash, middleTarget,
            "fixture must beat the middle target for the rules to diverge"
        )
        XCTAssertEqual(verified.contribution.id, verified.rootCID)
        // Root-most met target is the outer chain's max/4 => 4. The leaf's own
        // max/8 => 8 then wins the final max, so the credit is 8 — NOT the
        // middle chain's 16.
        XCTAssertEqual(
            verified.contribution.work, UInt256(8),
            """
            Credit must come from the root-most met target (4), raised only by \
            the child's own target (8) — never from a deeper chain's harder \
            target (16).
            """
        )
    }

    /// The ORDINARY merged-mining case, and the branch the other tests miss: a
    /// grind that beats the child's target but NOT the root's own target.
    ///
    /// `carriers.first(where:)` does two things — take index 0, and SKIP
    /// carriers whose target was not met. Every other test here mines hard
    /// enough that the root is met, so they only ever pin the first behaviour.
    /// Without this test, dropping the predicate entirely
    /// (`carriers.first.map { workForTarget($0.block.target) }`) passes the
    /// whole suite while crediting an UNMET target — work the hash never did.
    func testUnmetRootIsSkippedRatherThanCredited() async throws {
        let outerTarget = UInt256.max / UInt256(1024)  // root: far too hard
        let middleTarget = UInt256.max / UInt256(16)
        let leafTarget = UInt256.max / UInt256(4)

        let verified = try await verifiedMultiHopContribution(
            outerTarget: outerTarget,
            middleTarget: middleTarget,
            leafTarget: leafTarget,
            miningTarget: middleTarget
        )

        // Fixture guard: the root's target must genuinely NOT be met, or this
        // exercises the take-index-0 path and proves nothing new.
        XCTAssertGreaterThan(
            verified.rootHash, outerTarget,
            "fixture must MISS the root target, or the skip branch is not reached"
        )
        XCTAssertLessThanOrEqual(
            verified.rootHash, middleTarget,
            "fixture must meet the middle target, or nothing is credited"
        )
        XCTAssertEqual(
            verified.contribution.work, UInt256(16),
            """
            Credit must come from the root-most target actually MET (16), never \
            from an unmet harder one (1024). Crediting an unmet target invents \
            work the hash did not do.
            """
        )
    }

    func testTerminalTargetRaisesCreditWhenItExceedsTheMetAncestor() async throws {
        let outerTarget = UInt256.max / UInt256(4)
        let middleTarget = UInt256.max / UInt256(8)
        let leafTarget = UInt256.max / UInt256(16)

        let verified = try await verifiedMultiHopContribution(
            outerTarget: outerTarget,
            middleTarget: middleTarget,
            leafTarget: leafTarget,
            miningTarget: leafTarget
        )

        XCTAssertLessThanOrEqual(verified.rootHash, leafTarget)
        XCTAssertEqual(verified.contribution.id, verified.rootCID)
        XCTAssertEqual(verified.contribution.work, UInt256(16))
    }

    func testMultiHopCarrierTargetMissDoesNotEraseStrongerAcceptedWork() async throws {
        let outerTarget = UInt256.max / UInt256(16)
        let leafTarget = UInt256.max / UInt256(4)

        let verified = try await verifiedMultiHopContribution(
            outerTarget: outerTarget,
            middleTarget: .zero,
            leafTarget: leafTarget,
            miningTarget: outerTarget
        )

        XCTAssertLessThanOrEqual(verified.rootHash, outerTarget)
        XCTAssertGreaterThan(verified.rootHash, .zero)
        XCTAssertEqual(verified.contribution.id, verified.rootCID)
        XCTAssertEqual(verified.contribution.work, UInt256(16))
    }

    func testChildProofRejectsBrokenVerticalStateContinuity() async throws {
        let fetcher = StorableFetcher()
        let parentTemplate = try await makeGenesis(fetcher: fetcher, timestamp: 500)
        let childGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let candidate = try await makeChild(
            of: childGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2,
            parentChainBlock: parentTemplate
        )
        let wrongParentState = VolumeImpl<LatticeState>(
            rawCID: "bafywrongparentstate000000000000000000000000000000000000000"
        )
        let tampered = candidate.set(properties: [PARENT_STATE_PROPERTY: wrongParentState])
        guard let mined = BlockBuilder.mine(block: tampered, target: easy, maxAttempts: 10) else {
            return XCTFail("easy target should mine")
        }
        try await storeBuiltBlock(mined, in: fetcher)
        let carrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": mined],
            timestamp: 3_000,
            target: easy,
            nonce: 3,
            fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let package = try await childValidationPackage(proof: proof, fetcher: fetcher)
        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )

        let result = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: mined),
            fetcher: fetcher,
            childPackage: package,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .protocolInvalid)
    }

    func testReplayIsDuplicateAndDoesNotRestage() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let level = makeLevel(genesis: genesis)
        let recorder = AdmissionStageRecorder()
        let header = try BlockHeader(node: candidate)

        _ = try await level.admitBlockHeaderChainLocal(
            header,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: { record in await recorder.stage(record) }
        )

        let replay = try await level.admitBlockHeaderChainLocal(
            header,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
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
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let missingParent = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let childGenesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 9
        )
        let childCID = try BlockHeader(node: childGenesis).rawCID
        let keyPair = CryptoUtils.generateKeyPair()
        let owner = testAddress(publicKey: keyPair.publicKey)
        let body = TransactionBody(
            accountActions: [AccountAction(
                owner: owner,
                delta: Int64(chainLocalSpec().initialReward)
            )],
            actions: [],
            depositActions: [],
            genesisActions: [GenesisAction(
                directory: "Child",
                blockCID: childCID
            )],
            receiptActions: [],
            withdrawalActions: [],
            signers: [owner],
            fee: 0,
            nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let orphan = try await buildAndStoreBlock(
            previous: missingParent,
            transactions: [signedTestTransaction(body, by: keyPair)],
            timestamp: 3_000,
            target: easy,
            nonce: 2,
            fetcher: fetcher
        )
        let orphanHeader = try BlockHeader(node: orphan)
        let level = makeLevel(genesis: genesis)
        let recorder = AdmissionStageRecorder()

        let result = try await level.admitBlockHeaderChainLocal(
            orphanHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
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
        XCTAssertEqual(orphanContext.parentGenesisLinks.count, 1)

        _ = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: missingParent),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        let replay = try await level.preflightBlockHeaderChainLocal(
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
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let incumbent = try await makeChild(
            of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1
        )
        let heavier1 = try await makeChild(
            of: genesis, fetcher: fetcher, timestamp: 2_500, nonce: 2
        )
        let heavier2 = try await makeChild(
            of: heavier1, fetcher: fetcher, timestamp: 3_500, nonce: 3
        )
        let genesisCID = try BlockHeader(node: genesis).rawCID
        let incumbentCID = try BlockHeader(node: incumbent).rawCID
        let heavier1CID = try BlockHeader(node: heavier1).rawCID
        let heavier2CID = try BlockHeader(node: heavier2).rawCID

        // Admit every block through the normal path so the graph records their
        // real, self-consistent work facts. This level self-heals to the heavier
        // fork; it is only a source of authentic block metadata.
        let source = makeLevel(genesis: genesis)
        for block in [incumbent, heavier1, heavier2] {
            _ = try await source.admitBlockHeaderChainLocal(
                try BlockHeader(node: block),
                fetcher: fetcher,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: testAdmissionStage
            )
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
            mainChainHashes: [genesisCID, incumbentCID]
        ))
        let strandedTip = await stranded.chain.getMainChainTip()
        XCTAssertEqual(
            strandedTip, incumbentCID,
            "the stranded projection must start on the lighter fork"
        )

        // Re-admit the heaviest tip. It is already known with equal work, so it is
        // classified a duplicate. The seam re-runs fork choice and surfaces the
        // promotion. Pre-fix this returned `.duplicate` with a nil commit.
        let replay = try await stranded.preflightBlockHeaderChainLocal(
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
        let finalTip = await stranded.chain.getMainChainTip()
        XCTAssertEqual(finalTip, heavier2CID)
    }

    func testAdmissionReturnsExactChainLocalReorganization() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let main1 = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let main2 = try await makeChild(of: main1, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let fork1 = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_500, nonce: 3)
        let fork2 = try await makeChild(of: fork1, fetcher: fetcher, timestamp: 3_500, nonce: 4)
        let fork3 = try await makeChild(of: fork2, fetcher: fetcher, timestamp: 4_500, nonce: 5)
        let level = makeLevel(genesis: genesis)

        for block in [main1, main2] {
            _ = try await level.admitBlockHeaderChainLocal(
                try BlockHeader(node: block),
                fetcher: fetcher,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: testAdmissionStage
            )
        }
        _ = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: fork1),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        let fork2Result = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: fork2),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        let fork3Result = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: fork3),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

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
        XCTAssertEqual(Set(commit.mainChainBlocksAdded.keys), forkHashes)
        XCTAssertEqual(commit.mainChainBlocksRemoved, mainHashes)
        let finalTip = await level.chain.getMainChainTip()
        XCTAssertEqual(finalTip, try BlockHeader(node: fork3).rawCID)
    }

    func testStagedAdmissionSurvivesConcurrentMutationAndSourceLoss() async throws {
        let backing = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: backing, timestamp: 1_000)
        let candidate = try await makeChild(
            of: genesis,
            fetcher: backing,
            timestamp: 2_000,
            nonce: 1
        )
        let sibling = try await makeChild(
            of: genesis,
            fetcher: backing,
            timestamp: 2_000,
            nonce: 2
        )
        let level = makeLevel(genesis: genesis)
        let genesisBatch = try testAdmissionBatch(for: genesis)
        let source = DisableableAdmissionFetcher(backing: backing)
        let recorder = AdmissionStageRecorder()
        let candidateHeader = try BlockHeader(node: candidate)
        let unresolvedCandidate = BlockHeader(rawCID: candidateHeader.rawCID)
        let siblingHeader = try BlockHeader(node: sibling)

        let result = try await level.admitBlockHeaderChainLocal(
            unresolvedCandidate,
            fetcher: source,
            validationContentStorer: backing,
            materializedVolumeStorer: backing,
            stage: { batch in
                await recorder.stage(batch)
                _ = await level.chain.submitTestBlock(
                    blockHeader: siblingHeader,
                    block: sibling
                )
                await source.disable()
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
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let sibling = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2
        )
        let fixture = try await makeLevel(genesis: genesis, revision: .max - 1)
        let recorder = AdmissionStageRecorder()
        let candidateHeader = try BlockHeader(node: candidate)
        let siblingHeader = try BlockHeader(node: sibling)

        let accepted = try await fixture.level.admitBlockHeaderChainLocal(
            candidateHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
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
        let restoredTip = await restored.getMainChainTip()
        let liveTip = await fixture.level.chain.getMainChainTip()
        let restoredRevision = await restored.currentRevision()
        let liveRevision = await fixture.level.chain.currentRevision()
        XCTAssertEqual(restoredTip, liveTip)
        XCTAssertEqual(restoredRevision, liveRevision)

        let exhausted = try await fixture.level.admitBlockHeaderChainLocal(
            siblingHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: { batch in await recorder.stage(batch) }
        )
        XCTAssertEqual(exhausted.failure, .revisionExhausted)
        let exhaustedLink = try XCTUnwrap(exhausted.parentCarrierLink)
        XCTAssertEqual(exhaustedLink.carrierCID, siblingHeader.rawCID)
        XCTAssertNil(exhausted.sameChainPredecessor)
        let siblingStageCount = await recorder.count(for: siblingHeader.rawCID)
        XCTAssertEqual(siblingStageCount, 0)

        let missingParent = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_500,
            nonce: 3
        )
        let orphan = try await makeChild(
            of: missingParent,
            fetcher: fetcher,
            timestamp: 3_500,
            nonce: 4
        )
        let orphanHeader = try BlockHeader(node: orphan)
        let missingParentHeader = try BlockHeader(node: missingParent)
        let orphanExhausted = try await fixture.level.admitBlockHeaderChainLocal(
            orphanHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
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
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let fixture = try await makeLevel(genesis: genesis, revision: .max - 1)
        let header = try BlockHeader(node: candidate)

        do {
            _ = try await fixture.level.admitBlockHeaderChainLocal(
                header,
                fetcher: fetcher,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: { _ in throw ChainLocalTestError.stageFailure }
            )
            XCTFail("a failed atomic stage must fail admission")
        } catch ChainLocalTestError.stageFailure {}
        let revisionAfterFailure = await fixture.level.chain.currentRevision()
        XCTAssertEqual(revisionAfterFailure, .max - 1)

        let accepted = try await fixture.level.admitBlockHeaderChainLocal(
            header,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        XCTAssertEqual(accepted.commit?.revision, .max)
    }

    func testPreflightCommitUsesNoRemoteFetchAfterPreflight() async throws {
        let backing = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: backing, timestamp: 1_000)
        let candidate = try await makeChild(
            of: genesis,
            fetcher: backing,
            timestamp: 2_000,
            nonce: 1
        )
        let level = makeLevel(genesis: genesis)
        let source = DisableableAdmissionFetcher(backing: backing)
        let validationCache = StorableFetcher()
        let materialized = RecordingAdmissionStorer()
        let recorder = AdmissionStageRecorder()
        let header = try BlockHeader(node: candidate)

        let result = try await level.preflightBlockHeaderChainLocal(
            header,
            fetcher: source,
            validationContentStorer: validationCache
        )
        guard case .ready(let preflight) = result else {
            return XCTFail("valid candidate must produce a commit token")
        }

        await source.disable()
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
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let level = makeLevel(genesis: genesis)
        let otherLevel = makeLevel(genesis: genesis)
        let header = try BlockHeader(node: candidate)

        let result = try await level.preflightBlockHeaderChainLocal(
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
                error as? ChainAdmissionPreflightError,
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
                error as? ChainAdmissionPreflightError,
                .invalidToken
            )
        }
    }

    func testPreflightRemainsValidAfterAnotherAdmissionCommits() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let first = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let sibling = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2
        )
        let level = makeLevel(genesis: genesis)
        let firstHeader = try BlockHeader(node: first)
        let siblingHeader = try BlockHeader(node: sibling)

        let preflightResult = try await level.preflightBlockHeaderChainLocal(
            firstHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher
        )
        guard case .ready(let preflight) = preflightResult else {
            return XCTFail("valid candidate must produce a commit token")
        }

        let siblingResult = try await level.admitBlockHeaderChainLocal(
            siblingHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
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
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let predecessor = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let descendant = try await makeChild(
            of: predecessor,
            fetcher: fetcher,
            timestamp: 3_000,
            nonce: 2
        )
        let level = makeLevel(genesis: genesis)
        let predecessorHeader = try BlockHeader(node: predecessor)
        let descendantHeader = try BlockHeader(node: descendant)

        let preflightResult = try await level.preflightBlockHeaderChainLocal(
            descendantHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher
        )
        guard case .ready(let preflight) = preflightResult else {
            return XCTFail("valid descendant must produce a commit token")
        }

        _ = try await level.admitBlockHeaderChainLocal(
            predecessorHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
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

    func testWeighedAdmissionIssuesNoCrossChainFacts() async throws {
        // Deferred-execution safety: a weighed (not-yet-executed) child block
        // must issue NO carrier link and NO parent-genesis link, because a child
        // consuming such a fact would bind to unvalidated — possibly invalid or
        // soon-reorged — parent state. The identical EAGER admission issues both
        // (see testPreflightCommitPromotesCarrierLinkAfterPredecessorConnects),
        // so this pins the suppression that gates issuance to the validated tier.
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let predecessor = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let descendant = try await makeChild(
            of: predecessor,
            fetcher: fetcher,
            timestamp: 3_000,
            nonce: 2
        )
        let level = makeLevel(genesis: genesis)
        let predecessorHeader = try BlockHeader(node: predecessor)
        let descendantHeader = try BlockHeader(node: descendant)

        let preflightResult = try await level.preflightBlockHeaderChainLocal(
            descendantHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            mode: .weighed
        )
        guard case .ready(let preflight) = preflightResult else {
            return XCTFail("valid weighed descendant must produce a commit token")
        }

        _ = try await level.admitBlockHeaderChainLocal(
            predecessorHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
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

    func testDuplicatePreflightPromotesCarrierLinkAfterPredecessorConnectsWithoutStaging() async throws {
        let backing = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: backing, timestamp: 1_000)
        let predecessor = try await makeChild(
            of: genesis,
            fetcher: backing,
            timestamp: 2_000,
            nonce: 1
        )
        let orphan = try await makeChild(
            of: predecessor,
            fetcher: backing,
            timestamp: 3_000,
            nonce: 2
        )
        let level = makeLevel(genesis: genesis)
        let recorder = AdmissionStageRecorder()
        let predecessorHeader = try BlockHeader(node: predecessor)
        let orphanHeader = try BlockHeader(node: orphan)

        _ = try await level.admitBlockHeaderChainLocal(
            orphanHeader,
            fetcher: backing,
            validationContentStorer: backing,
            materializedVolumeStorer: backing,
            stage: { context in await recorder.stage(context) }
        )
        let source = DisableableAdmissionFetcher(backing: backing)
        let preflight = try await level.preflightBlockHeaderChainLocal(
            orphanHeader,
            fetcher: source,
            validationContentStorer: backing
        )
        guard case .duplicate(let duplicate) = preflight else {
            return XCTFail("known orphan must produce a duplicate token")
        }

        _ = try await level.admitBlockHeaderChainLocal(
            predecessorHeader,
            fetcher: backing,
            validationContentStorer: backing,
            materializedVolumeStorer: backing,
            stage: { context in await recorder.stage(context) }
        )
        await source.disable()
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
                error as? ChainAdmissionPreflightError,
                .invalidToken
            )
        }
    }

    func testConcurrentAdmissionReachesStorageTogetherWithOneValidationContext() async throws {
        let fetcher = StorableFetcher()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: now)
        // Candidates sit after genesis but within the validation context's clock
        // (set below to now + 2h), so the timestamp rule admits them and the test
        // exercises only the concurrent-admission path.
        let candidateTimestamp = now + 60 * 60 * 1_000
        let first = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: candidateTimestamp,
            nonce: 1
        )
        let sibling = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: candidateTimestamp,
            nonce: 2
        )
        let validationContext = ValidationContext(
            nowMilliseconds: now + 2 * 60 * 60 * 1_000
        )
        let level = makeLevel(genesis: genesis)
        let barrier = StorageBarrier(backing: fetcher)
        let recorder = AdmissionStageRecorder()
        let firstHeader = try BlockHeader(node: first)
        let siblingHeader = try BlockHeader(node: sibling)
        async let firstResult: ChainLocalBlockResult = level.admitBlockHeaderChainLocal(
            firstHeader,
            fetcher: fetcher,
            validationContext: validationContext,
            validationContentStorer: barrier,
            materializedVolumeStorer: barrier,
            stage: { record in await recorder.stage(record) }
        )
        async let siblingResult: ChainLocalBlockResult = level.admitBlockHeaderChainLocal(
            siblingHeader,
            fetcher: fetcher,
            validationContext: validationContext,
            validationContentStorer: barrier,
            materializedVolumeStorer: barrier,
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
