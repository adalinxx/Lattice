import DeterminismGoldens
import Foundation

// — Linux-side host-determinism gate.
//
// The full `LatticeTests` XCTest suite is not Linux-portable (pre-existing,
// out of scope). This executable asserts the SAME golden vectors that
// `HostDeterminismGoldenTests` pins on macOS, using the shared
// `DeterminismGoldens` source of truth — so cross-host determinism is enforced
// without porting the entire suite. Exit 0 iff every check matches; exit 1 on
// any mismatch.

do {
    let results = try DeterminismGoldens.runChecks()
    var allPassed = true
    for result in results {
        let status = result.passed ? "PASS" : "FAIL"
        if !result.passed { allPassed = false }
        print("[\(status)] \(result.name) — \(result.detail)")
    }
    if allPassed {
        print("lattice-determinism-check: all \(results.count) golden checks passed")
        exit(0)
    } else {
        FileHandle.standardError.write(Data("lattice-determinism-check: golden mismatch detected\n".utf8))
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("lattice-determinism-check: error: \(error)\n".utf8))
    exit(1)
}
