import Foundation
import XCTest
@testable import Lattice
import UInt256
import cashew

private func chainLocalSpec() -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1_024,
        halvingInterval: 10_000,
        retargetWindow: 5
    )
}

private enum ChainLocalTestError: Error, Sendable {
    case unexpectedFailure
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

private struct ResolutionCase {
    let name: String
    let fetcher: any Fetcher
    let expectedFailure: ChainAdmissionFailure
}

private actor PreparationBarrier {
    private var arrivals = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrivals += 1
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
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

private actor PreparedStateReceipt {
    private var receivedMaterializedState = false

    func record(_ state: LatticeState?) {
        receivedMaterializedState = state != nil
    }

    func receivedState() -> Bool {
        receivedMaterializedState
    }
}

final class ChainLocalAdmissionTests: XCTestCase {
    private let easy = UInt256.max

    private func makeGenesis(
        fetcher: StorableFetcher,
        timestamp: Int64,
        nonce: UInt64 = 0
    ) async throws -> Block {
        try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
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
        ChainLevel(chain: ChainState.fromGenesis(block: genesis))
    }

    private func makeChildProofFixture() async throws -> (
        fetcher: StorableFetcher,
        childLevel: ChainLevel,
        candidate: Block,
        proof: ChildBlockProof
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
        let carrierWithChild = try await buildAndStoreBlock(
            previous: parentGenesis,
            children: ["Child": candidate],
            timestamp: 3_000,
            target: easy,
            nonce: 2,
            fetcher: fetcher
        )

        let rootLevel = ChainLevel(chain: ChainState.fromGenesis(block: parentGenesis))
        let childLevel = try await rootLevel.attachRestoredChildForTesting(
            to: "Child",
            genesisBlock: childGenesis
        )

        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrierWithChild),
            childDirectory: "Child",
            fetcher: fetcher
        )
        return (fetcher, childLevel, candidate, proof)
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
            let result = await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
                header,
                fetcher: testCase.fetcher,
                prepare: { _, _, _ in .ready }
            )
            XCTAssertEqual(result.failure, testCase.expectedFailure, testCase.name)
        }
    }

    func testProtocolInvalidCandidateIsRejected() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let valid = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let invalid = Block(
            version: valid.version,
            parent: valid.parent,
            transactions: valid.transactions,
            target: .zero,
            nextTarget: valid.nextTarget,
            spec: valid.spec,
            parentState: valid.parentState,
            prevState: valid.prevState,
            postState: valid.postState,
            children: valid.children,
            height: valid.height,
            timestamp: valid.timestamp,
            nonce: valid.nonce
        )
        try await storeBuiltBlock(invalid, in: fetcher)

        let result = await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            try BlockHeader(node: invalid),
            fetcher: fetcher,
            prepare: { _, _, _ in .ready }
        )

        XCTAssertEqual(result.failure, .protocolInvalid)
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

        let result = await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            try BlockHeader(node: future),
            fetcher: fetcher,
            prepare: { _, _, _ in .ready }
        )

        XCTAssertEqual(result.failure, .notYetAdmissible)
    }

    func testDurablePreparationFailureLeavesNoVisibleMutation() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let level = makeLevel(genesis: genesis)
        let beforeTip = await level.chain.getMainChainTip()
        let candidateHash = try BlockHeader(node: candidate).rawCID

        let result = await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: fetcher,
            prepare: { _, _, _ in .storageFailed }
        )

        XCTAssertEqual(result.failure, .durablePreparationFailed)
        let afterTip = await level.chain.getMainChainTip()
        let containsCandidate = await level.chain.contains(blockHash: candidateHash)
        XCTAssertEqual(afterTip, beforeTip)
        XCTAssertFalse(containsCandidate)
    }

    func testChildAdmissionRequiresVerifiedProofAndThenAcceptsIt() async throws {
        let fixture = try await makeChildProofFixture()
        let header = try BlockHeader(node: fixture.candidate)

        let missingProof = await fixture.childLevel.admitBlockHeaderChainLocal(
            header,
            fetcher: fixture.fetcher,
            prepare: { _, _, _ in .ready }
        )
        XCTAssertEqual(missingProof.failure, .missingChildProof)

        let admitted = await fixture.childLevel.admitBlockHeaderChainLocal(
            header,
            fetcher: fixture.fetcher,
            childProof: fixture.proof,
            prepare: { _, _, _ in .ready }
        )
        if case .rejected(let failure) = admitted {
            return XCTFail("expected child admission, got \(failure)")
        }
        XCTAssertNotNil(admitted.materializedPostState)
        let childChain = await fixture.childLevel.chain
        let containsCandidate = await childChain.contains(blockHash: header.rawCID)
        XCTAssertTrue(containsCandidate)
    }

    func testSecondChildRootPreparationReceivesMaterializedState() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 500)
        let firstRoot = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let secondRoot = try await makeGenesis(fetcher: fetcher, timestamp: 2_000, nonce: 2)
        let carrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": secondRoot],
            timestamp: 3_000,
            target: easy,
            nonce: 3,
            fetcher: fetcher
        )
        let rootLevel = ChainLevel(chain: ChainState.fromGenesis(block: parentGenesis))
        let childLevel = try await rootLevel.attachRestoredChildForTesting(
            to: "Child",
            genesisBlock: firstRoot
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let receipt = PreparedStateReceipt()
        let secondHeader = try BlockHeader(node: secondRoot)

        let result = await childLevel.admitBlockHeaderChainLocal(
            secondHeader,
            fetcher: fetcher,
            childProof: proof,
            prepare: { _, _, state in
                await receipt.record(state)
                return .ready
            }
        )

        if case .rejected(let failure) = result {
            return XCTFail("expected second child root admission, got \(failure)")
        }
        XCTAssertNotNil(result.materializedPostState)
        let receivedState = await receipt.receivedState()
        let childChain = await childLevel.chain
        let containsSecondRoot = await childChain.contains(blockHash: secondHeader.rawCID)
        XCTAssertTrue(receivedState)
        XCTAssertTrue(containsSecondRoot)
    }

    func testSecondRootMustUseVerifiedAdmissionRatherThanBootstrap() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 500)
        let firstRoot = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let secondRoot = try await makeGenesis(fetcher: fetcher, timestamp: 2_000, nonce: 2)
        let carrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": secondRoot],
            timestamp: 3_000,
            target: easy,
            nonce: 3,
            fetcher: fetcher
        )
        let rootLevel = ChainLevel(chain: ChainState.fromGenesis(block: parentGenesis))
        let childLevel = try await rootLevel.attachRestoredChildForTesting(
            to: "Child",
            genesisBlock: firstRoot
        )

        do {
            _ = try await rootLevel.attachRestoredChildForTesting(to: "Child", genesisBlock: secondRoot)
            XCTFail("a second root must not enter through bootstrap")
        } catch let error as ChainLevelTopologyError {
            XCTAssertEqual(error, .directoryAlreadyAttached)
        }

        let secondRootHash = try BlockHeader(node: secondRoot).rawCID
        let childChain = await childLevel.chain
        let attachedChild = await rootLevel.childLevel(directory: "Child")
        XCTAssertTrue(attachedChild === childLevel)
        let containsSecondBeforeAdmission = await childChain.contains(blockHash: secondRootHash)
        XCTAssertFalse(containsSecondBeforeAdmission)

        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let result = await childLevel.admitBlockHeaderChainLocal(
            try BlockHeader(node: secondRoot),
            fetcher: fetcher,
            childProof: proof,
            prepare: { _, _, _ in .ready }
        )

        if case .rejected(let failure) = result {
            return XCTFail("expected verified second root admission, got \(failure)")
        }
        let containsSecondRoot = await childChain.contains(blockHash: secondRootHash)
        XCTAssertTrue(containsSecondRoot)
    }

    func testPublicBootstrapRequiresVerifiedGenesisAndDurablePreparation() async throws {
        let fetcher = StorableFetcher()
        let childGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let parentGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": childGenesis],
            timestamp: 500,
            target: easy,
            fetcher: fetcher
        )
        let parent = ChainLevel(chain: ChainState.fromGenesis(block: parentGenesis))
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: parentGenesis),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let header = try BlockHeader(node: childGenesis)

        do {
            _ = try await parent.bootstrapChild(
                to: "Child",
                genesisHeader: header,
                fetcher: fetcher,
                childProof: proof,
                prepare: { _, _, _ in .storageFailed }
            )
            XCTFail("durable preparation must gate first-root visibility")
        } catch let failure as ChainAdmissionFailure {
            XCTAssertEqual(failure, .durablePreparationFailed)
        }
        let beforeSuccess = await parent.childLevel(directory: "Child")
        XCTAssertNil(beforeSuccess)

        let child = try await parent.bootstrapChild(
            to: "Child",
            genesisHeader: header,
            fetcher: fetcher,
            childProof: proof,
            prepare: { _, _, _ in .ready }
        )
        let childPolicy = await child.chain.getRootPolicy()
        XCTAssertEqual(childPolicy, .childRootForest)

        let nonGenesis = try await makeChild(
            of: childGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2
        )
        do {
            _ = try await parent.bootstrapChild(
                to: "Other",
                genesisHeader: try BlockHeader(node: nonGenesis),
                fetcher: fetcher,
                childProof: proof,
                prepare: { _, _, _ in .ready }
            )
            XCTFail("a non-genesis block cannot create a child runtime")
        } catch let failure as ChainAdmissionFailure {
            XCTAssertEqual(failure, .protocolInvalid)
        }
        let other = await parent.childLevel(directory: "Other")
        XCTAssertNil(other)
    }

    func testVerifiedBootstrapAndSecondRootAdmissionShareOneForest() async throws {
        let fetcher = StorableFetcher()
        let firstRoot = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let secondRoot = try await makeGenesis(fetcher: fetcher, timestamp: 2_000, nonce: 2)
        let parentGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": firstRoot],
            timestamp: 500,
            target: easy,
            fetcher: fetcher
        )
        let secondCarrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": secondRoot],
            timestamp: 3_000,
            target: easy,
            nonce: 3,
            fetcher: fetcher
        )
        let parent = ChainLevel(chain: ChainState.fromGenesis(block: parentGenesis))
        let firstProof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: parentGenesis),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let child = try await parent.bootstrapChild(
            to: "Child",
            genesisHeader: try BlockHeader(node: firstRoot),
            fetcher: fetcher,
            childProof: firstProof,
            prepare: { _, _, _ in .ready }
        )
        let secondProof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: secondCarrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let secondHeader = try BlockHeader(node: secondRoot)
        let result = await child.admitBlockHeaderChainLocal(
            secondHeader,
            fetcher: fetcher,
            childProof: secondProof,
            prepare: { _, _, _ in .ready }
        )

        guard case .rejected(let failure) = result else {
            let firstHash = try BlockHeader(node: firstRoot).rawCID
            let expectedTip = min(firstHash, secondHeader.rawCID)
            let childChain = await child.chain
            let secondStored = await childChain.contains(blockHash: secondHeader.rawCID)
            let tip = await childChain.getMainChainTip()
            XCTAssertTrue(secondStored)
            XCTAssertEqual(tip, expectedTip)
            return
        }
        XCTFail("verified second root was rejected: \(failure)")
    }

    func testChildProofRejectsAnUnminedRootCarrier() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 500)
        let childGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let candidate = try await makeChild(
            of: childGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2,
            parentChainBlock: parentGenesis
        )
        let unminedCarrier = try await buildAndStoreBlock(
            previous: parentGenesis,
            children: ["Child": candidate],
            timestamp: 3_000,
            target: .zero,
            nextTarget: .zero,
            nonce: 3,
            fetcher: fetcher
        )
        let parent = ChainLevel(chain: ChainState.fromGenesis(block: parentGenesis))
        let child = try await parent.restoreChildChain(
            directory: "Child",
            chain: ChainState.fromGenesis(block: childGenesis, rootPolicy: .childRootForest)
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: unminedCarrier),
            childDirectory: "Child",
            fetcher: fetcher
        )

        let result = await child.admitBlockHeaderChainLocal(
            try BlockHeader(node: candidate),
            fetcher: fetcher,
            childProof: proof,
            prepare: { _, _, _ in .ready }
        )

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
    }

    func testRestoreDerivesChildContextAndRejectsInvalidTopology() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 500)
        let childGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let rootLevel = ChainLevel(chain: ChainState.fromGenesis(block: parentGenesis))
        let forest = ChainState.fromGenesis(
            block: childGenesis,
            retentionDepth: RECENT_BLOCK_DISTANCE,
            rootPolicy: .childRootForest
        )

        let childLevel = try await rootLevel.restoreChildChain(directory: "Child", chain: forest)
        let context = childLevel.admissionContext
        XCTAssertEqual(context.chainPath, [DEFAULT_ROOT_DIRECTORY, "Child"])
        XCTAssertTrue(context.requiresChildProof)

        do {
            _ = try await rootLevel.restoreChildChain(directory: "Child", chain: forest)
            XCTFail("a directory cannot be attached twice")
        } catch let error as ChainLevelTopologyError {
            XCTAssertEqual(error, .directoryAlreadyAttached)
        }

        let singleRoot = ChainState.fromGenesis(block: childGenesis)
        do {
            _ = try await rootLevel.restoreChildChain(directory: "Other", chain: singleRoot)
            XCTFail("a child restore must use a root forest")
        } catch let error as ChainLevelTopologyError {
            XCTAssertEqual(error, .childChainRequiresRootForest)
        }
    }

    func testAcceptedOrphanReturnsItsMissingParentAsFollowUp() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let missingParent = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let orphan = try await makeChild(of: missingParent, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let orphanHeader = try BlockHeader(node: orphan)

        let result = await makeLevel(genesis: genesis).admitBlockHeaderChainLocal(
            orphanHeader,
            fetcher: fetcher,
            prepare: { _, _, _ in .ready }
        )

        guard case .acceptedSide(_, _, _) = result else {
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

    func testConcurrentAdmissionReachesDurablePreparationTogether() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let first = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let sibling = try await makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 2)
        let level = makeLevel(genesis: genesis)
        let barrier = PreparationBarrier()
        let firstHeader = try BlockHeader(node: first)
        let siblingHeader = try BlockHeader(node: sibling)
        let prepare: ChainCommitPreparer = { _, _, _ in
            await barrier.wait()
            return .ready
        }

        async let firstResult: ChainLocalBlockResult = level.admitBlockHeaderChainLocal(
            firstHeader,
            fetcher: fetcher,
            prepare: prepare
        )
        async let siblingResult: ChainLocalBlockResult = level.admitBlockHeaderChainLocal(
            siblingHeader,
            fetcher: fetcher,
            prepare: prepare
        )

        for _ in 0..<100 {
            if await barrier.arrivalCount() == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let arrivals = await barrier.arrivalCount()
        await barrier.release()
        let results = await (firstResult, siblingResult)

        XCTAssertEqual(arrivals, 2, "independent verification should not wait behind a global gate")
        if case .rejected(let failure) = results.0 {
            return XCTFail("first sibling was rejected: \(failure)")
        }
        if case .rejected(let failure) = results.1 {
            return XCTFail("second sibling was rejected: \(failure)")
        }
        let containsFirst = await level.chain.contains(blockHash: firstHeader.rawCID)
        let containsSibling = await level.chain.contains(blockHash: siblingHeader.rawCID)
        XCTAssertTrue(containsFirst)
        XCTAssertTrue(containsSibling)
    }
}
