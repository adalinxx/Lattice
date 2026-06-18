import XCTest
@testable import Lattice
import DeterminismGoldens
import WAT

/// — float (f32/f64) constructs in policy modules are nondeterministic
/// across hosts (implementation-defined NaN payload/sign bits) and must be
/// rejected at parse time, both at deploy-time `validate` and at
/// block-validation-time `evaluate`.
final class WasmPolicyFloatRejectionTests: XCTestCase {
    private let policy = WasmPolicyRef(moduleCID: "tre246-policy-module", scope: .action)

    private func assertRejected(_ wat: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let module = Data(try wat2wasm(wat))
        XCTAssertThrowsError(
            try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: module),
            message, file: file, line: line
        ) { error in
            guard case WasmPolicyError.nondeterministicConstruct = error else {
                XCTFail("expected nondeterministicConstruct, got \(error)", file: file, line: line)
                return
            }
        }
    }

    /// Minimal valid policy scaffolding with a caller-supplied entrypoint body.
    private func policyModule(entrypointBody: String, locals: String = "") -> String {
        """
        (module
          (memory (export "memory") 1)
          (global $heap (mut i32) (i32.const 1024))
          (func (export "lattice_alloc") (param $len i32) (result i32)
            global.get $heap
            global.get $heap
            local.get $len
            i32.add
            global.set $heap)
          (func $entry (param $ptr i32) (param $len i32) (result i32)
            \(locals)
            \(entrypointBody))
          (export "lattice_validate_transaction" (func $entry))
          (export "lattice_validate_action" (func $entry))
        )
        """
    }

    func testFloatArithmeticInBodyIsRejected() throws {
        try assertRejected(
            policyModule(entrypointBody: """
            f64.const 0
            f64.const 0
            f64.div
            i64.reinterpret_f64
            i32.wrap_i64
            """),
            "f64 arithmetic must be rejected"
        )
    }

    func testFloatConstAloneIsRejected() throws {
        try assertRejected(
            policyModule(entrypointBody: """
            f32.const 1
            drop
            i32.const 1
            """),
            "f32.const must be rejected even without arithmetic"
        )
    }

    func testFloatLocalIsRejected() throws {
        try assertRejected(
            policyModule(entrypointBody: "i32.const 1", locals: "(local $tmp f64)"),
            "f64 local must be rejected"
        )
    }

    func testFloatFunctionSignatureIsRejected() throws {
        try assertRejected(
            policyModule(entrypointBody: "i32.const 1")
                .replacingOccurrences(
                    of: "(export \"lattice_validate_action\" (func $entry))",
                    with: """
                    (export "lattice_validate_action" (func $entry))
                      (func $helper (param f32) (result i32)
                        i32.const 0)
                    """
                ),
            "f32 parameter in any function type must be rejected"
        )
    }

    func testFloatGlobalIsRejected() throws {
        try assertRejected(
            policyModule(entrypointBody: "i32.const 1")
                .replacingOccurrences(
                    of: "(global $heap (mut i32) (i32.const 1024))",
                    with: """
                    (global $heap (mut i32) (i32.const 1024))
                      (global $f (mut f64) (f64.const 0))
                    """
                ),
            "f64 global must be rejected"
        )
    }

    func testFloatLoadStoreAreRejected() throws {
        try assertRejected(
            policyModule(entrypointBody: """
            i32.const 0
            f64.load
            drop
            i32.const 1
            """),
            "f64.load must be rejected"
        )
    }

    /// The integer/substring goldens module must still validate — the scan
    /// must not reject float-free policies.
    func testIntegerPolicyStillValidates() throws {
        let module = try DeterminismGoldens.wasmPolicyFixture(requiringSubstring: "policy-sentinel")
        XCTAssertNoThrow(try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: module))
    }

    /// Evaluate must reject too (fail closed for pre-existing deployments).
    func testEvaluateRejectsFloatModule() throws {
        let module = try DeterminismGoldens.wasmPolicyFloatNaNFixture()
        let contextData = try DeterminismGoldens.goldenContext().canonicalData()
        XCTAssertThrowsError(
            try WasmPolicyEvaluator.evaluate(policy: DeterminismGoldens.goldenPolicy(), contextData: contextData, moduleBytes: module)
        ) { error in
            guard case WasmPolicyError.nondeterministicConstruct = error else {
                XCTFail("expected nondeterministicConstruct, got \(error)")
                return
            }
        }
    }
}
