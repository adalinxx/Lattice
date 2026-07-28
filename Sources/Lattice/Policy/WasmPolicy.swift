import Foundation
import cashew
@_spi(Fuzzing)
import WasmKit
import WasmParser

public typealias WasmPolicyModuleHeader = VolumeImpl<WasmPolicyModule>

public struct WasmPolicyModule: Scalar {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }
}

public struct WasmPolicyRef: Codable, Hashable, Sendable {
    public enum Scope: String, Codable, Hashable, Sendable {
        case transaction
        case action
    }

    public static let currentABIVersion: UInt16 = 1

    public let moduleCID: String
    public let sourceCID: String?
    public let abiVersion: UInt16
    public let scope: Scope
    public let entrypoint: String

    enum CodingKeys: String, CodingKey {
        case moduleCID
        case sourceCID
        case abiVersion
        case scope
        case entrypoint
    }

    public init(
        moduleCID: String,
        sourceCID: String? = nil,
        abiVersion: UInt16 = WasmPolicyRef.currentABIVersion,
        scope: Scope,
        entrypoint: String? = nil
    ) {
        self.moduleCID = moduleCID
        self.sourceCID = sourceCID
        self.abiVersion = abiVersion
        self.scope = scope
        self.entrypoint = entrypoint ?? scope.defaultEntrypoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        moduleCID = try container.decode(String.self, forKey: .moduleCID)
        sourceCID = try container.decodeIfPresent(String.self, forKey: .sourceCID)
        abiVersion = try container.decodeIfPresent(UInt16.self, forKey: .abiVersion) ?? WasmPolicyRef.currentABIVersion
        scope = try container.decode(Scope.self, forKey: .scope)
        entrypoint = try container.decodeIfPresent(String.self, forKey: .entrypoint) ?? scope.defaultEntrypoint
    }
}

public extension WasmPolicyRef.Scope {
    var defaultEntrypoint: String {
        switch self {
        case .transaction: return "lattice_validate_transaction"
        case .action: return "lattice_validate_action"
        }
    }
}

public struct WasmPolicyContext: Codable, Sendable {
    public static let canonicalEncodingVersion: UInt16 = 1

    public let abiVersion: UInt16
    public let scope: WasmPolicyRef.Scope
    public let chainSpec: ChainSpec
    public let chainPath: [String]
    public let transaction: TransactionBody?
    public let action: Action?
    public let actionIndex: Int?

    public init(
        scope: WasmPolicyRef.Scope,
        chainSpec: ChainSpec,
        chainPath: [String],
        transaction: TransactionBody?,
        action: Action?,
        actionIndex: Int?
    ) {
        self.abiVersion = WasmPolicyRef.currentABIVersion
        self.scope = scope
        self.chainSpec = chainSpec
        self.chainPath = chainPath
        self.transaction = transaction
        self.action = action
        self.actionIndex = actionIndex
    }

    public func canonicalData() throws -> Data {
        var encoder = WasmPolicyContextCanonicalEncoder()
        try encoder.appendContext(self)
        return encoder.data
    }
}

public enum WasmPolicyError: Error, Sendable {
    case unsupportedABI(UInt16)
    case missingModule(String)
    case invalidModule
    case missingMemory
    case missingAllocator
    case missingEntrypoint(String)
    case invalidFunctionSignature(String)
    case invalidAllocation
    case invalidReturn
    case contextEncodingFailed
    /// A node-local resource guard (module size, declared memory, or table)
    /// tripped, so this node cannot produce a verdict for the policy. This is NOT
    /// a consensus verdict: another node with a higher bound may verify the same
    /// module. Admission classifies it as unavailable (the verdict is unavailable
    /// here, retryable if the evidence or the node's limits change), never
    /// `protocolInvalid` and never a hard local drop.
    case resourceUnavailable
    case nondeterministicConstruct(String)
}

private struct WasmPolicyContextCanonicalEncoder {
    private static let magic = Array("LWPCTX".utf8)

    private(set) var data = Data()

    mutating func appendContext(_ context: WasmPolicyContext) throws {
        data.append(contentsOf: Self.magic)
        appendUInt16(WasmPolicyContext.canonicalEncodingVersion)
        appendUInt16(context.abiVersion)
        appendUInt8(context.scope.canonicalTag)
        try appendNode(context.chainSpec)
        try appendStringArray(context.chainPath)
        try appendOptionalNode(context.transaction)
        try appendOptionalAction(context.action)
        if let actionIndex = context.actionIndex {
            guard actionIndex >= 0 else { throw WasmPolicyError.contextEncodingFailed }
            appendUInt8(1)
            appendUInt64(UInt64(actionIndex))
        } else {
            appendUInt8(0)
        }
    }

    private mutating func appendOptionalNode<T: Node>(_ node: T?) throws {
        guard let node else {
            appendUInt8(0)
            return
        }
        appendUInt8(1)
        try appendNode(node)
    }

    private mutating func appendOptionalAction(_ action: Action?) throws {
        guard let action else {
            appendUInt8(0)
            return
        }
        appendUInt8(1)
        let actionData = try DagCBOR.encode(action)
        try appendLengthPrefixed(actionData)
    }

    private mutating func appendNode<T: Node>(_ node: T) throws {
        guard let nodeData = node.toData() else { throw WasmPolicyError.contextEncodingFailed }
        try appendLengthPrefixed(nodeData)
    }

    private mutating func appendStringArray(_ values: [String]) throws {
        guard values.count <= Int(UInt32.max) else { throw WasmPolicyError.contextEncodingFailed }
        appendUInt32(UInt32(values.count))
        for value in values {
            try appendLengthPrefixed(Data(value.utf8))
        }
    }

    private mutating func appendLengthPrefixed(_ bytes: Data) throws {
        guard bytes.count <= Int(UInt32.max) else { throw WasmPolicyError.contextEncodingFailed }
        appendUInt32(UInt32(bytes.count))
        data.append(bytes)
    }

    private mutating func appendUInt8(_ value: UInt8) {
        data.append(value)
    }

    private mutating func appendUInt16(_ value: UInt16) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: MemoryLayout<UInt16>.size))
    }

    private mutating func appendUInt32(_ value: UInt32) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: MemoryLayout<UInt32>.size))
    }

    private mutating func appendUInt64(_ value: UInt64) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: MemoryLayout<UInt64>.size))
    }
}

private extension WasmPolicyRef.Scope {
    var canonicalTag: UInt8 {
        switch self {
        case .transaction: return 0
        case .action: return 1
        }
    }
}

/// Node-local guard on how much memory/table a policy module may allocate at
/// instantiation. This is NOT a protocol consensus limit — the protocol imposes
/// no module-size ceiling, and verdict determinism comes from
/// `WasmPolicyDeterminismScan` (no floats/NaN) plus WASM integer semantics, not
/// from these bounds. It exists purely to stop a module whose DECLARED initial
/// memory (valid WASM can declare up to 4 GiB) or table would OOM-kill the
/// validator: WasmKit allocates that at instantiation, before any execution, so
/// the bound must be applied there. An operator may inject different bounds; at
/// the shared default all nodes trap at the same point, so the verdict stays
/// uniform.
public struct WasmPolicyResourceLimits: Sendable, Equatable {
    public let maxMemoryBytes: Int
    public let maxTableElements: Int
    /// Ceiling on the raw module bytes this node will copy and parse. Enforced
    /// before the O(bytes) copy/parse so an oversized module cannot exhaust
    /// memory/CPU before the declared-memory guard above ever runs.
    public let maxModuleBytes: Int

    public init(
        maxMemoryBytes: Int = 2 * 1024 * 1024,
        maxTableElements: Int = 1024,
        maxModuleBytes: Int = 16 * 1024 * 1024
    ) {
        self.maxMemoryBytes = maxMemoryBytes
        self.maxTableElements = maxTableElements
        self.maxModuleBytes = maxModuleBytes
    }

    public static let `default` = WasmPolicyResourceLimits()
}

/// Reference type so `instantiate` can read, after a thrown instantiation trap,
/// whether the trap was this limiter denying growth (→ `resourceUnavailable`,
/// an unavailable verdict) versus an unrelated module fault (→ propagated as-is).
private final class WasmPolicyResourceLimiter: ResourceLimiter {
    let limits: WasmPolicyResourceLimits
    private(set) var denied = false

    init(limits: WasmPolicyResourceLimits) {
        self.limits = limits
    }

    func limitMemoryGrowth(to desired: Int) throws -> Bool {
        if desired > limits.maxMemoryBytes { denied = true; return false }
        return true
    }

    func limitTableGrowth(to desired: Int) throws -> Bool {
        if desired > limits.maxTableElements { denied = true; return false }
        return true
    }
}

public enum WasmPolicyEvaluator {
    // A chain's WasmPolicy is its own committed, opt-in validity rule, not
    // permissionless metered code — so the protocol imposes no module-size ceiling
    // and no consensus memory/table limit. The only bound is a node-local resource
    // guard (`WasmPolicyResourceLimits`) applied before instantiation to keep a
    // module's declared initial memory/table from OOM-killing the validator.
    public static let executionFeatureSet: WasmFeatureSet = [.referenceTypes]

    public static func evaluate(
        policy: WasmPolicyRef,
        context: WasmPolicyContext,
        fetcher: Fetcher,
        resourceLimits: WasmPolicyResourceLimits = .default
    ) async throws -> Bool {
        guard policy.abiVersion == WasmPolicyRef.currentABIVersion else {
            throw WasmPolicyError.unsupportedABI(policy.abiVersion)
        }
        let moduleHeader = WasmPolicyModuleHeader(rawCID: policy.moduleCID)
        guard let moduleNode = try await moduleHeader.resolve(fetcher: fetcher).node else {
            throw WasmPolicyError.missingModule(policy.moduleCID)
        }
        return try evaluate(
            policy: policy,
            contextData: context.canonicalData(),
            moduleBytes: moduleNode.bytes,
            resourceLimits: resourceLimits)
    }

    public static func evaluate(
        policy: WasmPolicyRef,
        contextData: Data,
        moduleBytes: Data,
        resourceLimits: WasmPolicyResourceLimits = .default
    ) throws -> Bool {
        let (memory, alloc, entrypoint) = try instantiate(
            policy: policy, moduleBytes: moduleBytes, resourceLimits: resourceLimits)

        let contextBytes = Array(contextData)
        // Only the WASM32 address-space bound applies; the module's actual memory
        // capacity is checked against `memorySize` below.
        guard contextBytes.count <= Int(Int32.max) else {
            throw WasmPolicyError.invalidAllocation
        }
        let contextLength = Int32(contextBytes.count)
        let ptrValue = try alloc([Value(signed: contextLength)])
        guard let ptr = ptrValue.first?.i32 else {
            throw WasmPolicyError.invalidReturn
        }
        let signedPtr = Int32(bitPattern: ptr)
        let memorySize = memory.data.count
        guard signedPtr >= 0 else {
            throw WasmPolicyError.invalidAllocation
        }
        let ptrOffset = Int(signedPtr)
        guard ptrOffset <= memorySize,
              contextBytes.count <= memorySize - ptrOffset else {
            throw WasmPolicyError.invalidAllocation
        }
        if !contextBytes.isEmpty {
            memory.withUnsafeMutableBufferPointer(offset: UInt(ptrOffset), count: contextBytes.count) { buffer in
                contextBytes.withUnsafeBytes { source in
                    buffer.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
            }
        }
        let result = try entrypoint([
            Value(signed: Int32(bitPattern: ptr)),
            Value(signed: contextLength),
        ])
        guard let raw = result.first?.i32 else {
            throw WasmPolicyError.invalidReturn
        }
        return raw == 1
    }

    public static func validate(
        policy: WasmPolicyRef,
        moduleBytes: Data,
        resourceLimits: WasmPolicyResourceLimits = .default
    ) throws {
        _ = try instantiate(policy: policy, moduleBytes: moduleBytes, resourceLimits: resourceLimits)
    }

    /// Process-wide cache of parsed/compiled modules, keyed by module content id.
    static let moduleCache = WasmModuleCache.shared

    private static func instantiate(
        policy: WasmPolicyRef,
        moduleBytes: Data,
        resourceLimits: WasmPolicyResourceLimits
    ) throws -> (
        memory: WasmKit.Memory,
        alloc: Function,
        entrypoint: Function
    ) {
        guard policy.abiVersion == WasmPolicyRef.currentABIVersion else {
            throw WasmPolicyError.unsupportedABI(policy.abiVersion)
        }
        // Node-local bound applied BEFORE the O(bytes) copy/parse below: an
        // oversized module is a memory/CPU DoS on the copy and parser themselves,
        // which the declared-memory limiter (post-parse) cannot prevent. Reject
        // here (never truncate — parsing a prefix would parse different, invalid
        // WASM); a node that stops here has only run out of its own budget, so the
        // verdict is unavailable, not a consensus verdict on the module.
        guard moduleBytes.count <= resourceLimits.maxModuleBytes else {
            throw WasmPolicyError.resourceUnavailable
        }
        // Cache key is the module's content id (CID of the immutable bytes).
        // Reusing the parsed `Module` across evaluations is safe: `instantiate`
        // below is non-mutating and allocates a fresh per-evaluation Store/Instance.
        let moduleCID = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: moduleBytes)).rawCID
        let module = try moduleCache.module(forKey: moduleCID) {
            let bytes = Array(moduleBytes)
            //: float/vector constructs are nondeterministic across hosts
            // (NaN payloads) and must never reach execution.
            try WasmPolicyDeterminismScan.scan(moduleBytes: bytes, features: Self.executionFeatureSet)
            return try parseWasm(bytes: bytes, features: Self.executionFeatureSet)
        }
        let engine = Engine(configuration: EngineConfiguration(features: Self.executionFeatureSet))
        let store = Store(engine: engine)
        // Node-local guard applied BEFORE instantiation: WasmKit allocates a
        // module's declared initial memory/table here, and valid WASM can declare
        // gigabytes — without this the validator could be OOM-killed. Growth beyond
        // the limit fails as a WasmKit trap (a thrown error, handled by the caller),
        // never an uncaught allocation crash. Not a protocol consensus limit.
        let limiter = WasmPolicyResourceLimiter(limits: resourceLimits)
        store.resourceLimiter = limiter
        let instance: Instance
        do {
            instance = try module.instantiate(store: store)
        } catch {
            // A trap caused by our own limiter denying declared memory/table
            // growth is a node-local resource shortfall, not module invalidity.
            if limiter.denied { throw WasmPolicyError.resourceUnavailable }
            throw error
        }
        guard let memory = instance.exports[memory: "memory"] else {
            throw WasmPolicyError.missingMemory
        }
        guard let alloc = instance.exports[function: "lattice_alloc"] else {
            throw WasmPolicyError.missingAllocator
        }
        guard let entrypoint = instance.exports[function: policy.entrypoint] else {
            throw WasmPolicyError.missingEntrypoint(policy.entrypoint)
        }
        let allocType = FunctionType(parameters: [.i32], results: [.i32])
        guard alloc.type == allocType else {
            throw WasmPolicyError.invalidFunctionSignature("lattice_alloc")
        }
        let entrypointType = FunctionType(parameters: [.i32, .i32], results: [.i32])
        guard entrypoint.type == entrypointType else {
            throw WasmPolicyError.invalidFunctionSignature(policy.entrypoint)
        }
        return (memory, alloc, entrypoint)
    }
}
