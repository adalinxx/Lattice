import UInt256

public enum ChainRuntimeContextError: Error, Sendable, Equatable {
    case emptyPath
    case emptyDirectory
    case zeroMinimumRootWork
}

/// Immutable identity and setup-wide proof floor for one chain process.
public struct ChainRuntimeContext: Sendable, Equatable {
    public let path: [String]
    public let minimumRootWork: UInt256

    public init(path: [String], minimumRootWork: UInt256) throws {
        guard !path.isEmpty else { throw ChainRuntimeContextError.emptyPath }
        guard path.allSatisfy({ !$0.isEmpty }) else {
            throw ChainRuntimeContextError.emptyDirectory
        }
        guard minimumRootWork > .zero else {
            throw ChainRuntimeContextError.zeroMinimumRootWork
        }
        self.path = path
        self.minimumRootWork = minimumRootWork
    }

    public var isRoot: Bool { path.count == 1 }
    var proofPath: [String] { Array(path.dropFirst()) }
}

/// Consensus runtime for exactly one chain. Other chains are evidence sources,
/// never recursively-owned runtimes.
public actor ChainLevel {
    public let chain: ChainState
    public nonisolated let context: ChainRuntimeContext

    public init(chain: ChainState, context: ChainRuntimeContext) {
        self.chain = chain
        self.context = context
    }
}
