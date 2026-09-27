import Foundation
import UInt256
import LatticePrimitives
import LatticeBlockTree

/// Consensus runtime for exactly one chain. Other chains are evidence sources,
/// never recursively-owned runtimes.
public actor ChainLevel {
    public let chain: ChainState
    public nonisolated let context: ChainRuntimeContext
    let importIdentity = UUID()

    public init(chain: ChainState, context: ChainRuntimeContext) {
        self.chain = chain
        self.context = context
    }
}
