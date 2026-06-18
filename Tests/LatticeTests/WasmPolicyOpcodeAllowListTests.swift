import XCTest
@testable import Lattice
import DeterminismGoldens
import WAT

/// — the policy opcode surface is an explicit ALLOW-LIST, not a
/// feature-flag pin. WasmKit 0.2.x decodes and executes bulk-memory (0xFC),
/// atomics (0xFE), and tail-call opcodes with NO feature gate — the pinned
/// `executionFeatureSet` does not constrain them — so the determinism scan
/// must enumerate the permitted subset and fail closed on everything else.
///
/// Decisions pinned here:
/// - Bulk MEMORY ops (memory.copy/fill/init, data.drop) are ALLOWED: their
///   trap/bounds semantics are fully specified and deterministic, and LLVM/
///   Rust toolchains emit memory.copy/fill by default for wasm32 targets.
/// - Atomics, tail calls, function-references ops, and all table.*
///   instructions are REJECTED: outside the intended integer/byte policy
///   subset (atomics additionally imply shared-memory semantics).
/// - SIMD/v128: WasmKit 0.2.x has no SIMD decoder (0xFD is an unknown opcode,
///   parse fails closed) and the scan rejects the v128 STORAGE type, which the
///   parser does accept in locals. Both pinned by tests below.
final class WasmPolicyOpcodeAllowListTests: XCTestCase {
    private let policy = WasmPolicyRef(moduleCID: "tre254-policy-module", scope: .action)

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
    private func policyModule(entrypointBody: String, locals: String = "", extra: String = "") -> String {
        """
        (module
          (memory (export "memory") 1)
          \(extra)
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

    private func evaluateGolden(_ wat: String) throws -> Bool {
        let module = Data(try wat2wasm(wat))
        let contextData = try DeterminismGoldens.goldenContext().canonicalData()
        return try WasmPolicyEvaluator.evaluate(
            policy: DeterminismGoldens.goldenPolicy(), contextData: contextData, moduleBytes: module
        )
    }

    // MARK: - Bulk memory: allowed AND must actually execute correctly

    func testMemoryCopyAllowedAndExecutes() throws {
        // Copy the first 4 context bytes to offset 0, then compare against a
        // direct load — returns 1 only if memory.copy really executed.
        let verdict = try evaluateGolden(policyModule(entrypointBody: """
        i32.const 0
        local.get $ptr
        i32.const 4
        memory.copy
        i32.const 0
        i32.load
        local.get $ptr
        i32.load
        i32.eq
        """))
        XCTAssertTrue(verdict, "memory.copy must be allowed and execute correctly")
    }

    func testMemoryFillAllowedAndExecutes() throws {
        let verdict = try evaluateGolden(policyModule(entrypointBody: """
        i32.const 0
        i32.const 0xAA
        i32.const 4
        memory.fill
        i32.const 0
        i32.load
        i32.const 0xAAAAAAAA
        i32.eq
        """))
        XCTAssertTrue(verdict, "memory.fill must be allowed and execute correctly")
    }

    func testMemoryInitAndDataDropAllowedAndExecute() throws {
        // Passive data segment + memory.init + data.drop ("abcd" = 0x64636261 LE).
        let verdict = try evaluateGolden(policyModule(
            entrypointBody: """
            i32.const 0
            i32.const 0
            i32.const 4
            memory.init $seg
            data.drop $seg
            i32.const 0
            i32.load
            i32.const 0x64636261
            i32.eq
            """,
            extra: #"(data $seg "abcd")"#
        ))
        XCTAssertTrue(verdict, "memory.init/data.drop must be allowed and execute correctly")
    }

    // MARK: - Atomics: rejected (decode with NO feature gate in WasmKit 0.2.x)

    func testAtomicLoadIsRejected() throws {
        try assertRejected(
            policyModule(entrypointBody: """
            i32.const 0
            i32.atomic.load
            """),
            "i32.atomic.load must be rejected"
        )
    }

    func testAtomicFenceIsRejected() throws {
        try assertRejected(
            policyModule(entrypointBody: """
            atomic.fence
            i32.const 1
            """),
            "atomic.fence must be rejected"
        )
    }

    // MARK: - Tail calls: rejected (decode with NO feature gate)

    func testReturnCallIsRejected() throws {
        try assertRejected(
            policyModule(entrypointBody: "return_call $entry"),
            "return_call must be rejected"
        )
    }

    // MARK: - Table instructions: rejected (outside the policy subset)

    func testTableGrowIsRejected() throws {
        try assertRejected(
            policyModule(
                entrypointBody: """
                ref.null func
                i32.const 1
                table.grow $t
                """,
                extra: "(table $t 1 funcref)"
            ),
            "table.grow must be rejected"
        )
    }

    func testTableGetIsRejected() throws {
        try assertRejected(
            policyModule(
                entrypointBody: """
                i32.const 0
                table.get $t
                ref.is_null
                """,
                extra: "(table $t 1 funcref)"
            ),
            "table.get must be rejected"
        )
    }

    // MARK: - call_indirect with an active element segment stays allowed
    // (the call path real toolchains emit for indirect calls)

    func testCallIndirectWithActiveElementSegmentStillValidates() throws {
        let wat = policyModule(
            entrypointBody: """
            local.get $ptr
            local.get $len
            i32.const 0
            call_indirect (type $sig)
            """,
            extra: """
            (type $sig (func (param i32 i32) (result i32)))
              (table $t 1 funcref)
              (elem (table $t) (i32.const 0) func $entry2)
              (func $entry2 (param i32 i32) (result i32) i32.const 1)
            """
        )
        XCTAssertNoThrow(try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: Data(try wat2wasm(wat))))
        XCTAssertTrue(try evaluateGolden(wat), "call_indirect through an active element segment must keep working")
    }

    // MARK: - SIMD / v128: fail closed

    /// Hand-crafted binary (WAT has no SIMD support either): one function whose
    /// body starts with the 0xFD SIMD prefix (v128.const). WasmKit 0.2.x has no
    /// SIMD decoder, so this must fail closed at parse — never execute.
    func testSimdInstructionFailsClosed() {
        var module: [UInt8] = [
            0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,  // magic + version
            0x01, 0x04, 0x01, 0x60, 0x00, 0x00,  // type: () -> ()
            0x03, 0x02, 0x01, 0x00,  // function: 1 func, type 0
        ]
        var body: [UInt8] = [0x00, 0xFD, 0x0C]  // no locals, v128.const
        body.append(contentsOf: [UInt8](repeating: 0, count: 16))  // v128 immediate
        body.append(contentsOf: [0x1A, 0x0B])  // drop, end
        module.append(contentsOf: [0x0A, UInt8(body.count + 2), 0x01, UInt8(body.count)])
        module.append(contentsOf: body)
        XCTAssertThrowsError(
            try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: Data(module)),
            "0xFD-prefixed SIMD opcodes must fail closed"
        )
    }

    /// The v128 STORAGE type does decode in locals (no feature gate) — the
    /// scan's value-type rejection must catch it.
    func testV128LocalIsRejected() {
        var module: [UInt8] = [
            0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,  // magic + version
            0x01, 0x04, 0x01, 0x60, 0x00, 0x00,  // type: () -> ()
            0x03, 0x02, 0x01, 0x00,  // function: 1 func, type 0
        ]
        let body: [UInt8] = [0x01, 0x01, 0x7B, 0x0B]  // 1 local group: 1 x v128; end
        module.append(contentsOf: [0x0A, UInt8(body.count + 2), 0x01, UInt8(body.count)])
        module.append(contentsOf: body)
        XCTAssertThrowsError(
            try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: Data(module)),
            "v128 locals must be rejected"
        ) { error in
            guard case WasmPolicyError.nondeterministicConstruct = error else {
                XCTFail("expected nondeterministicConstruct, got \(error)")
                return
            }
        }
    }

    // MARK: - Positive control: the golden integer policy still validates

    func testGoldenIntegerPolicyStillValidates() throws {
        let module = try DeterminismGoldens.wasmPolicyFixture(requiringSubstring: "policy-sentinel")
        XCTAssertNoThrow(try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: module))
    }
}
