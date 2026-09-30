import Foundation
import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256
import cashew

/// Drives a `ChainTree` through its value API the way a core would: the
/// block's own spec and child index resolved first, then one synchronous
/// `insertHeader`; `connectJob` → `connect` → `applyConnect` for execution.
enum TreeDriver {
    static func headerInputs(
        _ block: Block,
        fetcher: any Fetcher
    ) async throws -> (spec: ChainSpec, childIndex: ChildIndex) {
        let spec = try await block.spec.resolve(fetcher: fetcher).node
        let childIndex = try await block.children.resolve(fetcher: fetcher).node
        return (try XCTUnwrap(spec), try XCTUnwrap(childIndex))
    }

    /// `insertHeader` with the block's own root work unless `work` is given.
    static func insert(
        _ block: Block,
        into tree: inout ChainTree,
        fetcher: any Fetcher,
        work: VerifiedWorkContribution? = nil
    ) async throws -> ChainTreeAdmission {
        let inputs = try await headerInputs(block, fetcher: fetcher)
        let contribution = try XCTUnwrap(work ?? ChainTree.rootWork(of: block))
        return tree.insertHeader(
            block,
            spec: inputs.spec,
            childIndex: inputs.childIndex,
            work: contribution
        )
    }

    static func connect(
        _ blockHash: String,
        on tree: inout ChainTree,
        context: ChainRuntimeContext = testChainContext(),
        fetcher: any Fetcher,
        parentFacts: (any ParentChainFacts)? = nil
    ) async throws -> ChainTreeAdmission {
        let job = try XCTUnwrap(tree.connectJob(for: blockHash, context: context))
        let verdict = await ChainTree.connect(
            job, fetcher: fetcher, parentFacts: parentFacts
        )
        return tree.applyConnect(verdict)
    }

    /// A block linked to `valid`'s parent exactly as `valid` is, whose
    /// declared post-state no execution produces: it weighs, and its
    /// execution proves it invalid.
    static func forgedPostState(
        of valid: Block,
        seed: String,
        fetcher: StorableFetcher
    ) async throws -> Block {
        try await storeBuiltBlock(Block(
            version: valid.version,
            parent: valid.parent,
            transactions: valid.transactions,
            target: valid.target,
            nextTarget: valid.nextTarget,
            spec: valid.spec,
            parentState: valid.parentState,
            prevState: valid.prevState,
            postState: LatticeStateHeader(rawCID: testCID("forged-post-\(seed)")),
            children: valid.children,
            height: valid.height,
            timestamp: valid.timestamp,
            rewardRecipient: valid.rewardRecipient,
            nonce: valid.nonce
        ), in: fetcher)
    }
}
