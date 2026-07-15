import Foundation
import XCTest
@testable import Lattice
import UInt256
import cashew

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

    func store(entries: [String: Data]) async throws {
        await backing.store(entries: entries)
    }

    func store(volume: SerializedVolume) async throws {
        roots.insert(volume.root)
        await backing.store(volume: volume)
    }

    func volumeRoots() -> Set<String> { roots }
}

private actor AdmissionStageRecorder {
    private var counts: [String: Int] = [:]

    func stage(_ record: ChainAdmissionRecord) {
        counts[record.blockHash, default: 0] += 1
    }

    func count(for blockHash: String) -> Int {
        counts[blockHash, default: 0]
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
        try await buildAndStoreGenesis(
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

    private func stateChangingGenesisTransaction(
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
                name: "unknown local verifier failure",
                fetcher: UnknownFailingAdmissionFetcher(),
                expectedFailure: .localVerificationFailure
            )
        ]
        let header = try BlockHeader(node: candidate)

        for testCase in cases {
            let result = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
                header,
                fetcher: testCase.fetcher,
                storer: NoopStorer(),
                stage: testAdmissionStage
            )
            XCTAssertEqual(result.failure, testCase.expectedFailure, testCase.name)
        }
    }

    func testMissingTimestampAncestorIsUnavailableEvidence() async throws {
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
        let missingGenesis = MissingCIDAdmissionFetcher(
            backing: fetcher,
            missingCID: try BlockHeader(node: genesis).rawCID
        )

        let result = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: missingGenesis,
            storer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .unavailableEvidence)
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
            storer: fetcher,
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
            storer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .protocolInvalid)
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
            storer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .protocolInvalid)
        let containsSecond = await level.chain.contains(blockHash: secondHeader.rawCID)
        XCTAssertFalse(containsSecond)
    }

    func testNotYetAdmissibleCandidateIsDeferredByTypedOutcome() async throws {
        let fetcher = StorableFetcher()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: now - 100_000)
        let future = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: now + Block.maxFutureDriftMilliseconds + 60_000,
            nonce: 1
        )

        let result = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            try BlockHeader(node: future),
            fetcher: fetcher,
            storer: fetcher,
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
                storer: FailingAdmissionStorer(),
                stage: testAdmissionStage
            )
            XCTFail("storage failure must abort admission")
        } catch ChainLocalTestError.storageFailure {}

        do {
            _ = try await level.admitBlockHeaderChainLocal(
                try BlockHeader(node: candidate),
                fetcher: fetcher,
                storer: FailingVolumeAdmissionStorer(),
                stage: testAdmissionStage
            )
            XCTFail("Volume storage failure must abort admission")
        } catch ChainLocalTestError.storageFailure {}

        do {
            _ = try await level.admitBlockHeaderChainLocal(
                try BlockHeader(node: candidate),
                fetcher: fetcher,
                storer: fetcher,
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
            storer: fixture.fetcher,
            stage: testAdmissionStage
        )
        XCTAssertEqual(missingProof.failure, .missingChildProof)

        let admitted = try await fixture.childLevel.admitBlockHeaderChainLocal(
            header,
            fetcher: fixture.fetcher,
            childPackage: fixture.package,
            storer: fixture.fetcher,
            stage: testAdmissionStage
        )
        if case .rejected(let failure) = admitted {
            return XCTFail("expected child admission, got \(failure)")
        }
        XCTAssertNotNil(admitted.materializedPostState)
        let childChain = await fixture.childLevel.chain
        let containsCandidate = await childChain.contains(blockHash: header.rawCID)
        XCTAssertTrue(containsCandidate)
    }

    func testChildProofRequiresItsRootInTheProof() async throws {
        let fixture = try await makeChildProofFixture()
        let originalProof = fixture.package.proof
        let proofWithoutRoot = ChildBlockProof(
            rootCID: originalProof.rootCID,
            directoryPath: originalProof.directoryPath,
            entries: originalProof.entries.filter { $0.cid != originalProof.rootCID }
        )
        let package = ChildValidationPackage(
            proof: proofWithoutRoot,
            parentContinuityLinks: fixture.package.parentContinuityLinks
        )

        let result = try await fixture.childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: fixture.candidate),
            fetcher: fixture.fetcher,
            childPackage: package,
            storer: fixture.fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
    }

    func testChildProofRejectsDuplicateContinuityLinks() async throws {
        let fixture = try await makeChildProofFixture()
        let duplicate = ParentContinuityLink(
            parentPath: [DEFAULT_ROOT_DIRECTORY],
            successorCID: fixture.package.proof.rootCID
        )
        let package = ChildValidationPackage(
            proof: fixture.package.proof,
            parentContinuityLinks: [duplicate, duplicate]
        )

        let result = try await fixture.childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: fixture.candidate),
            fetcher: fixture.fetcher,
            childPackage: package,
            storer: fixture.fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
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
        let package = ChildValidationPackage(
            proof: conflictingProof,
            parentContinuityLinks: fixture.package.parentContinuityLinks
        )

        let result = try await fixture.childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: fixture.candidate),
            fetcher: fixture.fetcher,
            childPackage: package,
            storer: fixture.fetcher,
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
        let package = ChildValidationPackage(
            proof: duplicateProof,
            parentContinuityLinks: fixture.package.parentContinuityLinks
        )

        let result = try await fixture.childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: fixture.candidate),
            fetcher: fixture.fetcher,
            childPackage: package,
            storer: fixture.fetcher,
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
            childPackage: ChildValidationPackage(
                proof: paddedProof,
                parentContinuityLinks: fixture.package.parentContinuityLinks
            ),
            storer: fixture.fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
    }

    func testChildConsumesContinuityFactIssuedByParentProcess() async throws {
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
        let missing = try await childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: proof),
            storer: fetcher,
            stage: testAdmissionStage
        )
        XCTAssertEqual(missing.failure, .unavailableEvidence)

        let parentLevel = makeLevel(genesis: parentGenesis)
        let link: ParentContinuityLink
        switch await parentLevel.continuityLink(
            for: try BlockHeader(node: parentCarrier),
            fetcher: fetcher
        ) {
        case .success(let issued): link = issued
        case .failure(let failure):
            return XCTFail("parent process should issue continuity: \(failure)")
        }
        XCTAssertEqual(link.parentPath, [DEFAULT_ROOT_DIRECTORY])
        XCTAssertEqual(link.successorCID, proof.rootCID)

        let admitted = try await childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: fetcher,
            childPackage: ChildValidationPackage(
                proof: proof,
                parentContinuityLinks: [link]
            ),
            storer: fetcher,
            stage: testAdmissionStage
        )
        if case .rejected(let failure) = admitted {
            XCTFail("authenticated continuity fact should admit child: \(failure)")
        }
    }

    func testParentProcessIssuesGenesisFactFromValidatedState() async throws {
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
            genesisActions: [GenesisAction(directory: "Child", blockCID: childCID)],
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
            storer: fetcher,
            stage: testAdmissionStage
        )
        if case .rejected(let failure) = admission {
            return XCTFail("parent anchor should validate: \(failure)")
        }

        switch await parentLevel.genesisLink(
            parentBlockHeader: try BlockHeader(node: anchor),
            directory: "Child",
            childGenesisCID: childCID,
            fetcher: fetcher
        ) {
        case .success(let link):
            XCTAssertEqual(link.parentPath, [DEFAULT_ROOT_DIRECTORY])
            XCTAssertEqual(link.childGenesisCID, childCID)
        case .failure(let failure):
            XCTFail("validated parent state should issue genesis fact: \(failure)")
        }
    }

    func testSecondChildRootPinsItsMaterializedVolumes() async throws {
        let fetcher = StorableFetcher()
        let durable = RecordingAdmissionStorer()
        let firstRoot = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let transaction = stateChangingGenesisTransaction(
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
                childGenesisCID: secondHeader.rawCID
            )
        )

        let result = try await childLevel.admitBlockHeaderChainLocal(
            secondHeader,
            fetcher: fetcher,
            childPackage: package,
            storer: durable,
            stage: testAdmissionStage
        )

        let diff: StateDiff
        switch result {
        case .canonicalized(let stateDiff, _, _, _, _), .acceptedSide(let stateDiff, _, _, _):
            diff = stateDiff
        case .duplicate:
            return XCTFail("second root must not be a duplicate")
        case .acceptedEvidence, .carrier:
            return XCTFail("second root must execute its genesis transition")
        case .rejected(let failure):
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
        let transaction = stateChangingGenesisTransaction(
            key: "bootstrap",
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
        )
        let childGenesis = try await makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 1,
            transactions: [transaction]
        )
        let rootCarrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": childGenesis],
            timestamp: 500,
            target: easy,
            fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: rootCarrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let context = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        let header = try BlockHeader(node: childGenesis)
        let package = try await childValidationPackage(
            proof: proof,
            fetcher: fetcher,
            parentGenesisLink: testParentGenesisLink(
                directory: "Child",
                childGenesisCID: header.rawCID
            )
        )

        do {
            _ = try await ChainLevel.bootstrap(
                context: context,
                genesisHeader: header,
                fetcher: fetcher,
                childPackage: ChildValidationPackage(proof: proof),
                storer: fetcher,
                stage: testAdmissionStage
            )
            XCTFail("child genesis must wait for its parent-issued fact")
        } catch let failure as ChainAdmissionFailure {
            XCTAssertEqual(failure, .unavailableEvidence)
        }

        do {
            _ = try await ChainLevel.bootstrap(
                context: context,
                genesisHeader: header,
                fetcher: fetcher,
                childPackage: package,
                storer: FailingAdmissionStorer(),
                stage: testAdmissionStage
            )
            XCTFail("storage must gate first-root visibility")
        } catch ChainLocalTestError.storageFailure {}

        let bootstrap = try await ChainLevel.bootstrap(
            context: context,
            genesisHeader: header,
            fetcher: fetcher,
            childPackage: package,
            storer: fetcher,
            stage: testAdmissionStage
        )
        let child = bootstrap.level
        XCTAssertFalse(bootstrap.stateDiff.created.isEmpty)
        XCTAssertNotNil(bootstrap.materializedPostState)
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
                childPackage: package,
                storer: fetcher,
                stage: testAdmissionStage
            )
            XCTFail("a non-genesis block cannot create a child runtime")
        } catch let failure as ChainAdmissionFailure {
            XCTAssertEqual(failure, .protocolInvalid)
        }
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
            storer: fetcher,
            stage: testAdmissionStage
        )

        if case .rejected(let failure) = result {
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
            ancestorTimestamps: [childGenesis.timestamp]
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
        let candidateHeader = try BlockHeader(node: candidate)

        let result = try await level.admitBlockHeaderChainLocal(
            candidateHeader,
            fetcher: fetcher,
            childPackage: package,
            storer: fetcher,
            stage: { record in await recorder.stage(record) }
        )

        guard case .carrier = result else {
            return XCTFail("a current-level target miss must remain a descendant carrier")
        }
        let stageCount = await recorder.count(for: candidateHeader.rawCID)
        let containsCarrier = await level.chain.contains(blockHash: candidateHeader.rawCID)
        XCTAssertEqual(stageCount, 1)
        XCTAssertFalse(containsCarrier)
    }

    func testBootstrapStagesValidCarrierBeforeCurrentChainTargetMiss() async throws {
        let fetcher = StorableFetcher()
        let childGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 1_000,
            target: UInt256(1),
            nonce: 1,
            fetcher: fetcher
        )
        let rootCarrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": childGenesis],
            timestamp: 2_000,
            target: easy,
            nonce: 2,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(rootCarrier.proofOfWorkHash(), childGenesis.target)
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: rootCarrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let header = try BlockHeader(node: childGenesis)
        let package = try await childValidationPackage(
            proof: proof,
            fetcher: fetcher,
            parentGenesisLink: testParentGenesisLink(
                directory: "Child",
                childGenesisCID: header.rawCID
            )
        )
        let recorder = AdmissionStageRecorder()

        do {
            _ = try await ChainLevel.bootstrap(
                context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"]),
                genesisHeader: header,
                fetcher: fetcher,
                childPackage: package,
                storer: fetcher,
                stage: { record in await recorder.stage(record) }
            )
            XCTFail("a target miss cannot bootstrap this chain")
        } catch let failure as ChainAdmissionFailure {
            XCTAssertEqual(failure, .notAcceptedAtCurrentChain)
        }
        let stageCount = await recorder.count(for: header.rawCID)
        XCTAssertEqual(stageCount, 1)
    }

    func testTargetMissStillRejectsBrokenCarrierContinuity() async throws {
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
            storer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .protocolInvalid)
    }

    func testHeightOverflowFailsClosedInCarrierAndBuilder() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let child = try await makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
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

        XCTAssertFalse(child.hasCarrierContinuity(parent: overflowParent))
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
        let package = try await childValidationPackage(
            proof: rootHop.composing(hop: leafHop),
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
            storer: fetcher,
            stage: testAdmissionStage
        )
        XCTAssertEqual(rejected.failure, .providerMalformedEvidence)

        let exactPath = ChainLevel(
            chain: ChainState.fromGenesis(block: leafGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"])
        )
        let accepted = try await exactPath.admitBlockHeaderChainLocal(
            candidateHeader,
            fetcher: fetcher,
            childPackage: package,
            storer: fetcher,
            stage: testAdmissionStage
        )
        if case .rejected(let failure) = accepted {
            return XCTFail("the complete path should verify: \(failure)")
        }
        let containsCandidate = await exactPath.chain.contains(blockHash: candidateHeader.rawCID)
        XCTAssertTrue(containsCandidate)
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
            storer: fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .protocolInvalid)
    }

    func testChildProofClassifiesRootFloorMissAsProtocolInvalid() async throws {
        let fixture = try await makeChildProofFixture()
        let chain = await fixture.childLevel.chain
        let strictLevel = ChainLevel(
            chain: chain,
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Child"],
                minimumRootWork: .max
            )
        )

        let result = try await strictLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: fixture.candidate),
            fetcher: fixture.fetcher,
            childPackage: fixture.package,
            storer: fixture.fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .protocolInvalid)
    }

    func testRootFloorIsCheckedBeforeNonRootWitnessCanonicality() async throws {
        let fixture = try await makeChildProofFixture()
        let proof = fixture.package.proof
        let nonRoot = try XCTUnwrap(proof.entries.first { $0.cid != proof.rootCID })
        let malformedProof = ChildBlockProof(
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entries: proof.entries + [(nonRoot.cid, nonRoot.data + Data([0]))]
        )
        let chain = await fixture.childLevel.chain
        let strictLevel = ChainLevel(
            chain: chain,
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Child"],
                minimumRootWork: .max
            )
        )

        let result = try await strictLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: fixture.candidate),
            fetcher: fixture.fetcher,
            childPackage: ChildValidationPackage(
                proof: malformedProof,
                parentContinuityLinks: fixture.package.parentContinuityLinks
            ),
            storer: fixture.fetcher,
            stage: testAdmissionStage
        )

        XCTAssertEqual(result.failure, .protocolInvalid)
    }

    func testReplayAfterLifecyclePruningIsDuplicateAndDoesNotRestage() async throws {
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
            storer: fetcher,
            stage: { record in await recorder.stage(record) }
        )
        await level.chain.pruneBlocksAtIndex(1)

        let replay = try await level.admitBlockHeaderChainLocal(
            header,
            fetcher: fetcher,
            storer: fetcher,
            stage: { record in await recorder.stage(record) }
        )

        guard case .duplicate = replay else {
            return XCTFail("known consensus facts must remain duplicate after lifecycle pruning")
        }
        let stageCount = await recorder.count(for: header.rawCID)
        let lifecycle = (await level.chain.getConsensusBlock(hash: header.rawCID))?.stateDiff
        XCTAssertEqual(stageCount, 1)
        XCTAssertNil(lifecycle)
    }

    func testAcceptedOrphanReturnsItsMissingParentAsFollowUp() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let missingParent = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let orphan = try await makeChild(of: missingParent, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let orphanHeader = try BlockHeader(node: orphan)

        let result = try await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            orphanHeader,
            fetcher: fetcher,
            storer: fetcher,
            stage: testAdmissionStage
        )

        guard case .acceptedSide(_, _, _, _) = result else {
            return XCTFail("expected valid orphan side admission, got \(result)")
        }
        let missingParentHash = try BlockHeader(node: missingParent).rawCID
        XCTAssertEqual(
            result.followUps,
            [MissingBodyRequest(
                tipHash: orphanHeader.rawCID,
                missingBodies: [missingParentHash]
            )]
        )
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
                storer: fetcher,
                stage: testAdmissionStage
            )
        }
        _ = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: fork1),
            fetcher: fetcher,
            storer: fetcher,
            stage: testAdmissionStage
        )
        let fork2Result = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: fork2),
            fetcher: fetcher,
            storer: fetcher,
            stage: testAdmissionStage
        )
        let fork3Result = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: fork3),
            fetcher: fetcher,
            storer: fetcher,
            stage: testAdmissionStage
        )

        let main1Hash = try BlockHeader(node: main1).rawCID
        let fork1Hash = try BlockHeader(node: fork1).rawCID
        let forkWinsTie = forkChoicePrefersSegmentBase(
            fork1Hash,
            candidateNextTarget: fork1.nextTarget,
            over: main1Hash,
            currentNextTarget: main1.nextTarget
        )
        let reorganization = try XCTUnwrap(
            forkWinsTie ? fork2Result.reorganization : fork3Result.reorganization
        )
        let winningPrefix = forkWinsTie ? [fork1, fork2] : [fork1, fork2, fork3]
        let forkHashes = try Set(winningPrefix.map { try BlockHeader(node: $0).rawCID })
        let mainHashes = try Set([main1, main2].map { try BlockHeader(node: $0).rawCID })
        XCTAssertEqual(
            reorganization.newTipHash,
            try BlockHeader(node: forkWinsTie ? fork2 : fork3).rawCID
        )
        XCTAssertEqual(Set(reorganization.mainChainBlocksAdded.keys), forkHashes)
        XCTAssertEqual(reorganization.mainChainBlocksRemoved, mainHashes)
        let finalTip = await level.chain.getMainChainTip()
        XCTAssertEqual(finalTip, try BlockHeader(node: fork3).rawCID)
    }

    func testConcurrentAdmissionReachesStorageTogether() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let first = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let sibling = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 2)
        let level = makeLevel(genesis: genesis)
        let barrier = StorageBarrier(backing: fetcher)
        let recorder = AdmissionStageRecorder()
        let firstHeader = try BlockHeader(node: first)
        let siblingHeader = try BlockHeader(node: sibling)
        async let firstResult: ChainLocalBlockResult = level.admitBlockHeaderChainLocal(
            firstHeader,
            fetcher: fetcher,
            storer: barrier,
            stage: { record in await recorder.stage(record) }
        )
        async let siblingResult: ChainLocalBlockResult = level.admitBlockHeaderChainLocal(
            siblingHeader,
            fetcher: fetcher,
            storer: barrier,
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
        if case .rejected(let failure) = results.0 {
            return XCTFail("first sibling was rejected: \(failure)")
        }
        if case .rejected(let failure) = results.1 {
            return XCTFail("second sibling was rejected: \(failure)")
        }
        let containsFirst = await level.chain.contains(blockHash: firstHeader.rawCID)
        let containsSibling = await level.chain.contains(blockHash: siblingHeader.rawCID)
        let stagedFirst = await recorder.count(for: firstHeader.rawCID)
        let stagedSibling = await recorder.count(for: siblingHeader.rawCID)
        XCTAssertTrue(containsFirst)
        XCTAssertTrue(containsSibling)
        XCTAssertGreaterThanOrEqual(
            stagedFirst + stagedSibling,
            3,
            "the stale candidate must be durably restaged before its retry commits"
        )
    }
}
