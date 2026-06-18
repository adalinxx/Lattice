import WasmKit
import WasmParser

/// — the policy opcode surface is an explicit ALLOW-LIST.
///
///: WasmKit executes f32/f64 arithmetic with native Swift operators
/// and does not canonicalize NaN payload/sign bits, which the WASM spec leaves
/// implementation-defined. A policy that materializes a NaN, reinterprets it
/// to an integer, and branches on the payload would return different verdicts
/// on different hosts — a consensus fork. Validity policies are integer/byte
/// logic, so float (f32/f64) and vector (v128) constructs are rejected
/// outright at parse time: in function signatures, locals, globals, block
/// types, and every instruction.
///
///: the pinned `executionFeatureSet` is NOT a decode gate — WasmKit
/// 0.2.x decodes and executes bulk-memory (0xFC), atomics (0xFE), and
/// tail-call opcodes regardless of the feature set. The scan therefore
/// enumerates the permitted deterministic subset explicitly (exhaustive
/// switch, no default-allow) and rejects everything else:
/// - ALLOWED: the integer MVP (control flow, locals/globals, integer
///   loads/stores/arithmetic/comparisons, sign-extension), reference-types
///   basics (ref.null/ref.is_null/ref.func, call_indirect with element
///   segments), and bulk MEMORY ops (memory.copy/fill/init, data.drop) —
///   their trap/bounds semantics are fully specified and deterministic, and
///   LLVM/Rust emit memory.copy/fill by default for wasm32 targets.
/// - REJECTED: floats, atomics, tail calls, function-references
///   ops, and all table.* instructions — outside the intended policy subset.
/// - SIMD instruction opcodes (0xFD) have no decoder in WasmKit 0.2.x and
///   fail closed in the parser as unknown opcodes; the v128 STORAGE type does
///   decode and is rejected here. Unknown opcodes fail closed via
///   `visitUnknown` returning false.
enum WasmPolicyDeterminismScan {
    /// Walks every section of the module and throws
    /// `WasmPolicyError.nondeterministicConstruct` on the first construct
    /// outside the allow-list. Must be called on the exact bytes that will be
    /// handed to `parseWasm` for execution.
    static func scan(moduleBytes: [UInt8], features: WasmFeatureSet) throws {
        var parser = WasmParser.Parser(bytes: moduleBytes, features: features)
        while let payload = try parser.parseNext() {
            switch payload {
            case .typeSection(let types):
                for type in types {
                    try reject(valueTypes: type.parameters, where: "function parameter")
                    try reject(valueTypes: type.results, where: "function result")
                }
            case .importSection(let imports):
                for item in imports {
                    if case .global(let globalType) = item.descriptor {
                        try reject(valueType: globalType.valueType, where: "imported global")
                    }
                }
            case .globalSection(let globals):
                for global in globals {
                    try reject(valueType: global.type.valueType, where: "global")
                    try scan(expression: global.initializer)
                }
            case .elementSection(let segments):
                for segment in segments {
                    if case .active(_, let offset) = segment.mode {
                        try scan(expression: offset)
                    }
                    for initializer in segment.initializer {
                        try scan(expression: initializer)
                    }
                }
            case .codeSection(let codes):
                for code in codes {
                    try reject(valueTypes: code.locals, where: "local")
                    var visitor = OpcodeAllowListVisitor()
                    try code.parseExpression(visitor: &visitor)
                }
            case .dataSection(let segments):
                for segment in segments {
                    if case .active(let active) = segment {
                        try scan(expression: active.offset)
                    }
                }
            default:
                break
            }
        }
    }

    private static func scan(expression: ConstExpression) throws {
        var visitor = OpcodeAllowListVisitor()
        for instruction in expression {
            try visitor.visit(instruction)
        }
    }

    private static func reject(valueTypes: [ValueType], where context: String) throws {
        for valueType in valueTypes {
            try reject(valueType: valueType, where: context)
        }
    }

    fileprivate static func reject(valueType: ValueType, where context: String) throws {
        switch valueType {
        case .f32, .f64, .v128:
            throw WasmPolicyError.nondeterministicConstruct("\(valueType) \(context)")
        case .i32, .i64, .ref:
            break
        }
    }

    fileprivate static func reject(blockType: BlockType, where context: String) throws {
        if case .type(let valueType) = blockType {
            try reject(valueType: valueType, where: context)
        }
    }
}

/// Exhaustive ALLOW-LIST over every instruction WasmKit 0.2.x can decode.
/// `AnyInstructionVisitor` routes all instructions through `visit(_:)`, and the
/// switches below have NO default case: if a future WasmKit adds opcodes, this
/// fails to compile rather than silently allowing them. Unknown opcodes keep
/// the default `visitUnknown` (returns `false`), so the parser fails closed on
/// them (this is what rejects 0xFD/SIMD, which has no decoder at all).
private struct OpcodeAllowListVisitor: AnyInstructionVisitor {
    var binaryOffset: Int = 0

    private func reject(_ opcode: String) throws {
        throw WasmPolicyError.nondeterministicConstruct("\(opcode) instruction")
    }

    mutating func visit(_ instruction: Instruction) throws {
        switch instruction {
        // Control flow, parametric, variable access, linear-memory size, and
        // integer constants: the deterministic MVP core.
        case .unreachable, .nop, .else, .end, .br, .brIf, .brTable, .return,
             .call, .callIndirect, .drop, .select,
             .localGet, .localSet, .localTee, .globalGet, .globalSet,
             .memorySize, .memoryGrow, .i32Const, .i64Const,
             .i32Eqz, .i64Eqz:
            break

        // Bulk MEMORY ops decision: ALLOWED). Deterministic — bounds
        // checks and trap behavior are fully specified — and LLVM/Rust emit
        // memory.copy/fill by default for wasm32 targets.
        case .memoryInit, .dataDrop, .memoryCopy, .memoryFill:
            break

        // Reference-types basics: needed for call_indirect tables and element
        // segment initializers; produce no observable nondeterminism.
        case .refNull, .refIsNull, .refFunc:
            break

        // Block types may carry a value type (e.g. f64) — reject float/v128.
        case .block(let blockType):
            try WasmPolicyDeterminismScan.reject(blockType: blockType, where: "block type")
        case .loop(let blockType):
            try WasmPolicyDeterminismScan.reject(blockType: blockType, where: "loop type")
        case .if(let blockType):
            try WasmPolicyDeterminismScan.reject(blockType: blockType, where: "if type")
        case .typedSelect(let type):
            try WasmPolicyDeterminismScan.reject(valueType: type, where: "select type")

        // Floats: implementation-defined NaN payload/sign bits.
        case .f32Const:
            try reject("f32.const")
        case .f64Const:
            try reject("f64.const")

        // Tail calls and function-references ops: decode with no feature gate
        // in WasmKit 0.2.x but are outside the pinned policy subset.
        case .returnCall, .returnCallIndirect:
            try reject("tail call")
        case .callRef, .returnCallRef, .refAsNonNull, .brOnNull, .brOnNonNull:
            try reject("function-references")

        // Table manipulation: outside the policy subset (toolchains emit
        // call_indirect + element segments, never table.* instructions).
        case .tableInit, .elemDrop, .tableCopy, .tableFill,
             .tableGet, .tableSet, .tableGrow, .tableSize:
            try reject("table")

        // Atomics: decode with no feature gate; imply shared-memory/threads
        // semantics that are outside the deterministic subset.
        case .atomicFence:
            try reject("atomic")

        case .load(let load, _):
            switch load {
            case .i32Load, .i64Load,
                 .i32Load8S, .i32Load8U, .i32Load16S, .i32Load16U,
                 .i64Load8S, .i64Load8U, .i64Load16S, .i64Load16U,
                 .i64Load32S, .i64Load32U:
                break
            case .f32Load, .f64Load:
                try reject("float load")
            case .i32AtomicLoad, .i64AtomicLoad,
                 .i32AtomicLoad8U, .i32AtomicLoad16U,
                 .i64AtomicLoad8U, .i64AtomicLoad16U, .i64AtomicLoad32U:
                try reject("atomic load")
            }

        case .store(let store, _):
            switch store {
            case .i32Store, .i64Store,
                 .i32Store8, .i32Store16,
                 .i64Store8, .i64Store16, .i64Store32:
                break
            case .f32Store, .f64Store:
                try reject("float store")
            case .i32AtomicStore, .i64AtomicStore,
                 .i32AtomicStore8, .i32AtomicStore16,
                 .i64AtomicStore8, .i64AtomicStore16, .i64AtomicStore32:
                try reject("atomic store")
            }

        case .cmp(let cmp):
            switch cmp {
            case .i32Eq, .i32Ne, .i32LtS, .i32LtU, .i32GtS, .i32GtU,
                 .i32LeS, .i32LeU, .i32GeS, .i32GeU,
                 .i64Eq, .i64Ne, .i64LtS, .i64LtU, .i64GtS, .i64GtU,
                 .i64LeS, .i64LeU, .i64GeS, .i64GeU:
                break
            case .f32Eq, .f32Ne, .f32Lt, .f32Gt, .f32Le, .f32Ge,
                 .f64Eq, .f64Ne, .f64Lt, .f64Gt, .f64Le, .f64Ge:
                try reject("float comparison")
            }

        case .unary(let unary):
            switch unary {
            case .i32Clz, .i32Ctz, .i32Popcnt, .i64Clz, .i64Ctz, .i64Popcnt,
                 .i32Extend8S, .i32Extend16S,
                 .i64Extend8S, .i64Extend16S, .i64Extend32S:
                break
            case .f32Abs, .f32Neg, .f32Ceil, .f32Floor, .f32Trunc, .f32Nearest, .f32Sqrt,
                 .f64Abs, .f64Neg, .f64Ceil, .f64Floor, .f64Trunc, .f64Nearest, .f64Sqrt:
                try reject("float unary")
            }

        case .binary(let binary):
            switch binary {
            case .i32Add, .i32Sub, .i32Mul, .i32DivS, .i32DivU, .i32RemS, .i32RemU,
                 .i32And, .i32Or, .i32Xor, .i32Shl, .i32ShrS, .i32ShrU, .i32Rotl, .i32Rotr,
                 .i64Add, .i64Sub, .i64Mul, .i64DivS, .i64DivU, .i64RemS, .i64RemU,
                 .i64And, .i64Or, .i64Xor, .i64Shl, .i64ShrS, .i64ShrU, .i64Rotl, .i64Rotr:
                break
            case .f32Add, .f32Sub, .f32Mul, .f32Div, .f32Min, .f32Max, .f32Copysign,
                 .f64Add, .f64Sub, .f64Mul, .f64Div, .f64Min, .f64Max, .f64Copysign:
                try reject("float binary")
            }

        case .conversion(let conversion):
            switch conversion {
            case .i32WrapI64, .i64ExtendI32S, .i64ExtendI32U:
                break
            // Every other conversion has an f32/f64 source or destination,
            // including the reinterpret family that exposes NaN payload bits
            // and the trunc_sat family (0xFC prefix).
            case .i32TruncF32S, .i32TruncF32U, .i32TruncF64S, .i32TruncF64U,
                 .i64TruncF32S, .i64TruncF32U, .i64TruncF64S, .i64TruncF64U,
                 .f32ConvertI32S, .f32ConvertI32U, .f32ConvertI64S, .f32ConvertI64U,
                 .f32DemoteF64,
                 .f64ConvertI32S, .f64ConvertI32U, .f64ConvertI64S, .f64ConvertI64U,
                 .f64PromoteF32,
                 .i32ReinterpretF32, .i64ReinterpretF64,
                 .f32ReinterpretI32, .f64ReinterpretI64,
                 .i32TruncSatF32S, .i32TruncSatF32U, .i32TruncSatF64S, .i32TruncSatF64U,
                 .i64TruncSatF32S, .i64TruncSatF32U, .i64TruncSatF64S, .i64TruncSatF64U:
                try reject("float conversion")
            }
        }
    }
}
