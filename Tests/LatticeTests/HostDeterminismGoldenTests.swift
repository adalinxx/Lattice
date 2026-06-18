import XCTest
@testable import Lattice
import DeterminismGoldens

/// — host-determinism golden vectors.
///
/// These goldens pin canonical state-root–relevant bytes (the WasmPolicy
/// canonical context encoding), the content ids of the policy modules, and the
/// real `WasmPolicyEvaluator` verdicts. They are asserted byte-for-byte and run
/// on BOTH macOS (this XCTest) and Linux (the `lattice-determinism-check`
/// executable, see `.github/workflows/test.yml`'s `test-linux` lane), so any
/// host-dependent divergence in the canonical encoder, the CAS hashing, or the
/// Wasm execution profile is caught by construction.
///
/// Both hosts compute their checks from the shared `DeterminismGoldens` source
/// of truth, so the pinned constants and the computation cannot drift apart.
final class HostDeterminismGoldenTests: XCTestCase {
    /// Drives the shared determinism checks and asserts every one passes. This is
    /// the exact set the Linux executable runs, against the exact same goldens.
    func testWasmPolicyGoldenVectorsAreHostDeterministic() throws {
        let results = try DeterminismGoldens.runChecks()
        XCTAssertFalse(results.isEmpty, "expected at least one determinism check")
        for result in results {
            XCTAssertTrue(result.passed, "\(result.name) — \(result.detail)")
        }
    }
}
