import Foundation
import UInt256

public enum ChainRuntimeContextError: Error, Sendable, Equatable {
    case emptyPath
    case emptyDirectory
    case rootMustBeNexus
    case directoryContainsSeparator
    case invalidDirectory
    case directoryTooLong
    case pathTooDeep
}

/// Immutable Nexus-rooted identity for one chain process.
public struct ChainRuntimeContext: Sendable, Equatable {
    public let path: [String]

    public init(path: [String]) throws {
        guard !path.isEmpty else { throw ChainRuntimeContextError.emptyPath }
        guard path.allSatisfy({ !$0.isEmpty }) else {
            throw ChainRuntimeContextError.emptyDirectory
        }
        guard path.first == DEFAULT_ROOT_DIRECTORY else {
            throw ChainRuntimeContextError.rootMustBeNexus
        }
        guard path.dropFirst().count <= ChildProofWireLimits.maximumDepth else {
            throw ChainRuntimeContextError.pathTooDeep
        }
        guard path.allSatisfy({
            $0.utf8.count <= StateAtomLimits.maximumDirectoryBytes
        }) else {
            throw ChainRuntimeContextError.directoryTooLong
        }
        guard path.allSatisfy({ !$0.contains(DIRECTORY_KEY_SEPARATOR) }) else {
            throw ChainRuntimeContextError.directoryContainsSeparator
        }
        guard path.allSatisfy(StateAtomLimits.isDirectory) else {
            throw ChainRuntimeContextError.invalidDirectory
        }
        self.path = path
    }

    public var isRoot: Bool { path.count == 1 }
    var proofPath: [String] { Array(path.dropFirst()) }
}

/// Consensus runtime for exactly one chain. Other chains are evidence sources,
/// never recursively-owned runtimes.
public actor ChainLevel {
    public let chain: ChainState
    public nonisolated let context: ChainRuntimeContext
    let admissionIdentity = UUID()

    public init(chain: ChainState, context: ChainRuntimeContext) {
        self.chain = chain
        self.context = context
    }
}
