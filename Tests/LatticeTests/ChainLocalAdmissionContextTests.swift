import Foundation
import XCTest
@testable import Lattice
import UInt256
import cashew
import WAT

final class ChainLocalAdmissionContextTests: XCTestCase {
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
}
