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

/// Serves a store, but while `fault` is set every fetch other than the
/// block's own CID throws it: the block resolves, and its execution hits the
/// fault on its first read.
private actor FaultingFetcher: Fetcher {
    private let backing: StorableFetcher
    private let blockHash: String
    private var fault: (any Error)?

    init(backing: StorableFetcher, blockHash: String, fault: any Error) {
        self.backing = backing
        self.blockHash = blockHash
        self.fault = fault
    }

    func heal() { fault = nil }

    func fetch(rawCid: String) async throws -> Data {
        if let fault, rawCid != blockHash { throw fault }
        return try await backing.fetch(rawCid: rawCid)
    }
}

/// A node-local encoder or cipher fault is no verdict on the block: it is
/// retried and never excluded. A failure the content itself causes stays a
/// verdict.
final class LocalVerificationFailureTests: XCTestCase {
    private static let localFaults: [DataErrors] = [
        .serializationFailed, .encryptionFailed, .decryptionFailed, .invalidIV,
    ]

    func testDataErrorsSplitIntoLocalFaultsAndContentVerdicts() {
        for error in Self.localFaults {
            let classified = ChainLevel.classifyValidationFailureForTesting(error)
            XCTAssertEqual(classified, .localVerificationFailure, "\(error)")
            XCTAssertFalse(ChainLevel.isDeterministicInvalidityForTesting(classified), "\(error)")
            XCTAssertEqual(
                ChainLevel.classifyResolutionFailureForTesting(error),
                .localVerificationFailure,
                "\(error)"
            )
        }
        // A CID the content names with no usable multihash, and a policy
        // input the content makes unencodable, are properties of the content.
        for error in [DataErrors.cidCreationFailed, DataErrors.missingDeclaredChild("x")] {
            let classified = ChainLevel.classifyValidationFailureForTesting(error)
            XCTAssertEqual(classified, .protocolInvalid, "\(error)")
            XCTAssertTrue(ChainLevel.isDeterministicInvalidityForTesting(classified), "\(error)")
        }
        let policy = ChainLevel.classifyValidationFailureForTesting(
            WasmPolicyError.contextEncodingFailed
        )
        XCTAssertEqual(policy, .protocolInvalid)
        XCTAssertTrue(ChainLevel.isDeterministicInvalidityForTesting(policy))
    }

    private struct Fixture {
        let fetcher: StorableFetcher
        let genesis: Block
        let block: Block
        let blockHash: String
        var tree: ChainTree
    }

    private func fixture() async throws -> Fixture {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let block = try await AdmissionFixture.makeChild(
            of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1
        )
        var tree = try await TreeDriver.tree(
            genesis: genesis, context: testChainContext(), fetcher: fetcher
        )
        let inserted = try await TreeDriver.insert(block, into: &tree, fetcher: fetcher)
        XCTAssertNotNil(inserted.update, "\(inserted)")
        return Fixture(
            fetcher: fetcher, genesis: genesis, block: block,
            blockHash: try BlockHeader(node: block).rawCID, tree: tree
        )
    }

    func testConnectRetriesALocalFaultWithoutExcludingAndLaterValidates() async throws {
        for fault in Self.localFaults {
            var fixture = try await fixture()
            let faulting = FaultingFetcher(
                backing: fixture.fetcher, blockHash: fixture.blockHash, fault: fault
            )
            let job = try XCTUnwrap(fixture.tree.connectJob(for: fixture.blockHash, grind: nil))
            let verdict = await ChainTree.connect(job, fetcher: faulting)
            XCTAssertFalse(verdict.provesInvalid, "\(fault)")
            XCTAssertEqual(verdict.retryFailure, .localVerificationFailure, "\(fault)")

            let applied = fixture.tree.applyConnect(verdict)
            XCTAssertNil(applied.update, "\(fault): a retry emits no exclusion fact")
            XCTAssertEqual(applied.failure, .localVerificationFailure, "\(fault)")
            XCTAssertFalse(fixture.tree.hasExecutedAncestry(blockHash: fixture.blockHash))

            // The fault clears; the retry validates the block.
            await faulting.heal()
            let retried = try await TreeDriver.connect(
                fixture.blockHash, on: &fixture.tree, fetcher: faulting
            )
            let update = try XCTUnwrap(retried.update, "\(fault): \(retried)")
            XCTAssertFalse(update.excluded, "\(fault)")
            XCTAssertTrue(fixture.tree.hasExecutedAncestry(blockHash: fixture.blockHash))
        }
    }

    func testConnectStillExcludesAContentCausedFailure() async throws {
        var fixture = try await fixture()
        let faulting = FaultingFetcher(
            backing: fixture.fetcher, blockHash: fixture.blockHash,
            fault: DataErrors.cidCreationFailed
        )
        let connected = try await TreeDriver.connect(
            fixture.blockHash, on: &fixture.tree, fetcher: faulting
        )
        let update = try XCTUnwrap(connected.update, "\(connected)")
        XCTAssertTrue(update.excluded)
        XCTAssertFalse(fixture.tree.hasExecutedAncestry(blockHash: fixture.blockHash))
    }

    func testActorPathRetriesALocalFaultAndStillExcludesContentFailures() async throws {
        for fault in Self.localFaults {
            let fixture = try await fixture()
            let level = AdmissionFixture.makeLevel(genesis: fixture.genesis)
            let faulting = FaultingFetcher(
                backing: fixture.fetcher, blockHash: fixture.blockHash, fault: fault
            )
            let header = try BlockHeader(node: fixture.block)
            for mode in [ImportMode.full, .execution] {
                let result = try await level.admit(
                    header, mode: mode, fetcher: faulting, storer: fixture.fetcher
                )
                XCTAssertEqual(result.failure, .localVerificationFailure, "\(fault) \(mode)")
            }
            await faulting.heal()
            let healed = try await level.admit(
                header, mode: .execution, fetcher: faulting, storer: fixture.fetcher
            )
            guard case .accepted = healed else {
                return XCTFail("\(fault): the retry must validate, got \(healed)")
            }
        }

        // The validated tier excludes a content-caused failure of a weighed
        // block: accepted with an exclusion, not a retryable rejection.
        let fixture = try await fixture()
        let level = AdmissionFixture.makeLevel(genesis: fixture.genesis)
        let header = try BlockHeader(node: fixture.block)
        let weighed = try await level.admit(header, mode: .header, fetcher: fixture.fetcher)
        guard case .accepted = weighed else {
            return XCTFail("the header must weigh, got \(weighed)")
        }
        let faulting = FaultingFetcher(
            backing: fixture.fetcher, blockHash: fixture.blockHash,
            fault: DataErrors.cidCreationFailed
        )
        let excluded = try await level.admit(
            header, mode: .execution, fetcher: faulting, storer: fixture.fetcher
        )
        guard case .accepted(let acceptance) = excluded else {
            return XCTFail("a content-caused failure must exclude, got \(excluded)")
        }
        XCTAssertTrue(acceptance.facts.facts.contains {
            if case .exclusion = $0 { return true }
            return false
        })
    }
}
