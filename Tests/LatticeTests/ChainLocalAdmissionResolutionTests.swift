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
    let expectedFailure: BlockImportError
}

final class ChainLocalAdmissionResolutionTests: XCTestCase {
    func testResolutionFailuresHaveTypedOutcomes() async throws {
        let storage = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: storage, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(of: genesis, fetcher: storage, timestamp: 2_000, nonce: 1)
        let unrelated = try await AdmissionFixture.makeGenesis(fetcher: storage, timestamp: 3_000, nonce: 2)
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
            let result = try await AdmissionFixture.makeLevel(genesis: genesis).admit(
                header,
                fetcher: testCase.fetcher,
                storer: NoopStorer()
            )
            XCTAssertEqual(result.failure, testCase.expectedFailure, testCase.name)
        }
    }

    func testInlineBlockHeaderCIDMismatchIsProviderMalformedEvidence() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let unrelated = try await AdmissionFixture.makeChild(
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

        let result = try await AdmissionFixture.makeLevel(genesis: genesis).admit(forged, fetcher: fetcher)

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
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let blockOne = try await AdmissionFixture.makeChild(
            of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1
        )
        let blockTwo = try await AdmissionFixture.makeChild(
            of: blockOne, fetcher: fetcher, timestamp: 3_000, nonce: 2
        )
        let candidate = try await AdmissionFixture.makeChild(
            of: blockTwo, fetcher: fetcher, timestamp: 4_000, nonce: 3
        )
        let missingAnchor = DenyingFetcher(
            backing: fetcher,
            denied: [try BlockHeader(node: blockOne).rawCID]
        )

        let result = try await AdmissionFixture.makeLevel(genesis: genesis).admit(
            candidate,
            fetcher: missingAnchor,
            storer: fetcher
        )

        XCTAssertEqual(result.failure, .unavailableEvidence)
    }

    func testMissingImmediatePredecessorReturnsExactBackfillRequirement() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let parent = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let candidate = try await AdmissionFixture.makeChild(
            of: parent,
            fetcher: fetcher,
            timestamp: 3_000,
            nonce: 2
        )
        let parentCID = try BlockHeader(node: parent).rawCID
        let candidateCID = try BlockHeader(node: candidate).rawCID
        let missingParent = DenyingFetcher(
            backing: fetcher,
            denied: [parentCID]
        )

        let result = try await AdmissionFixture.makeLevel(genesis: genesis)
            .admit(candidate, fetcher: missingParent, storer: fetcher)

        XCTAssertEqual(result.failure, .unavailableEvidence)
        XCTAssertEqual(result.sameChainPredecessor, SameChainPredecessorRequirement(
            descendantCID: candidateCID,
            predecessorCID: parentCID
        ))
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
            target: AdmissionFixture.easy,
            fetcher: fetcher
        )
        let candidate = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: fetcher
        )
        let missingModule = DenyingFetcher(
            backing: fetcher,
            denied: [policy.moduleCID]
        )

        let result = try await AdmissionFixture.makeLevel(genesis: genesis).admit(
            candidate,
            fetcher: missingModule,
            storer: fetcher
        )

        XCTAssertEqual(result.failure, .unavailableEvidence)
    }

    func testProtocolInvalidCandidateIsRejected() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let valid = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
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
            rewardRecipient: valid.rewardRecipient,
            nonce: valid.nonce
        )
        try await storeBuiltBlock(invalid, in: fetcher)

        let result = try await AdmissionFixture.makeLevel(genesis: genesis).admit(invalid, fetcher: fetcher)

        XCTAssertEqual(result.failure, .protocolInvalid)
    }

    func testUnboundedHalfLifeNeitherTrapsNorOverWalks() async throws {
        // `halfLife` is an unbounded UInt64 from the spec — attacker-supplied
        // when the parent is disconnected. Nothing may size a walk or a
        // reservation by it (`Int(UInt64.max)` traps); the schedule saturates.
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: ChainSpec.test(halfLife: UInt64.max),
            timestamp: 1_000,
            target: AdmissionFixture.easy,
            fetcher: fetcher
        )
        let first = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let second = try await AdmissionFixture.makeChild(of: first, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let level = AdmissionFixture.makeLevel(genesis: genesis)

        let eager = try await level.admit(first, fetcher: fetcher)
        guard case .accepted = eager else {
            return XCTFail("eager admission must accept, got \(eager)")
        }
        let weighed = try await level.admit(second, mode: .header, fetcher: fetcher)
        guard case .accepted = weighed else {
            return XCTFail("weighed admission must accept, got \(weighed)")
        }
    }

    func testSideCandidateAdmitsWithoutAncestorFetches() async throws {
        // Every frontier leaf and losing fork has an off-main-chain parent. A
        // side candidate validates from the held graph alone, so no candidate
        // pays a sequential fetcher walk for ancestors the node already holds.
        let full = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: full, timestamp: 1_000)
        let mainOne = try await AdmissionFixture.makeChild(of: genesis, fetcher: full, timestamp: 2_000, nonce: 1)
        let mainTwo = try await AdmissionFixture.makeChild(of: mainOne, fetcher: full, timestamp: 3_000, nonce: 2)
        let sideOne = try await AdmissionFixture.makeChild(of: genesis, fetcher: full, timestamp: 2_500, nonce: 3)
        let sideTwo = try await AdmissionFixture.makeChild(of: sideOne, fetcher: full, timestamp: 3_500, nonce: 4)
        let genesisHash = try BlockHeader(node: genesis).rawCID
        let sideOneHash = try BlockHeader(node: sideOne).rawCID

        let level = AdmissionFixture.makeLevel(genesis: genesis)
        for block in [mainOne, mainTwo, sideOne] {
            let result = try await level.admit(block, fetcher: full)
            guard case .accepted = result else {
                return XCTFail("fixture block must be accepted, got \(result)")
            }
        }
        let tip = await level.chain.canonicalTip
        XCTAssertEqual(tip, try BlockHeader(node: mainTwo).rawCID)
        let sideOnMain = await level.chain.canonicalBlockHash(atHeight: 1)
        XCTAssertNotEqual(sideOnMain, sideOneHash)

        // A fetcher that cannot serve any ancestor beyond the parent still
        // validates the side candidate: the window came from the held graph.
        let noAncestors = DenyingFetcher(backing: full, denied: [genesisHash])
        let result = try await level.admit(
            sideTwo,
            mode: .header,
            fetcher: noAncestors,
            storer: full
        )
        guard case .accepted = result else {
            return XCTFail("side candidate must validate from the held graph, got \(result)")
        }
    }

    func testNotYetAdmissibleCandidateIsDeferredByTypedOutcome() async throws {
        let fetcher = StorableFetcher()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: now - 100_000)
        let future = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: now + 60_000,
            nonce: 1
        )

        let result = try await AdmissionFixture.makeLevel(genesis: genesis).admit(future, fetcher: fetcher)

        XCTAssertEqual(result.failure, .notYetValid)
    }
}
