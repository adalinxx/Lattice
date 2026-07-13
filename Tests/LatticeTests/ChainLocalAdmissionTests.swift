import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation

private func chainLocalSpec() -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1_024,
        halvingInterval: 10_000,
        retargetWindow: 5
    )
}

private func chainLocalStore(_ block: Block, to fetcher: StorableFetcher) async throws {
    let storer = CollectingStorer()
    try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
    await storer.flush(to: fetcher)
}

final class ChainLocalAdmissionTests: XCTestCase {
    private let easy = UInt256.max

    private func makeGenesis(
        fetcher: StorableFetcher,
        timestamp: Int64
    ) async throws -> Block {
        let genesis = try await BlockBuilder.buildGenesis(
            spec: chainLocalSpec(),
            timestamp: timestamp,
            target: easy,
            fetcher: fetcher
        )
        try await chainLocalStore(genesis, to: fetcher)
        return genesis
    }

    private func child(
        of previous: Block,
        fetcher: StorableFetcher,
        timestamp: Int64,
        nonce: UInt64
    ) async throws -> Block {
        let block = try await BlockBuilder.buildBlock(
            previous: previous,
            timestamp: timestamp,
            target: easy,
            nonce: nonce,
            fetcher: fetcher
        )
        try await chainLocalStore(block, to: fetcher)
        return block
    }

    private func makeLattice(genesis: Block, children: [String: ChainLevel] = [:]) -> Lattice {
        Lattice(
            nexus: ChainLevel(
                chain: ChainState.fromGenesis(block: genesis),
                children: children
            )
        )
    }

    func testDuplicateIsNotReportedInvalid() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let lattice = makeLattice(genesis: genesis)
        let header = try VolumeImpl<Block>(node: genesis)

        let result = await lattice.admitBlockHeaderChainLocal(header, fetcher: fetcher)

        guard case .duplicate = result else {
            return XCTFail("expected duplicate, got \(result)")
        }
    }

    func testUnavailableContentIsNotReportedInvalid() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let lattice = makeLattice(genesis: genesis)
        let missing = VolumeImpl<Block>(rawCID: "not-present", node: nil, encryptionInfo: nil)

        let result = await lattice.admitBlockHeaderChainLocal(missing, fetcher: fetcher)

        guard case .unavailable = result else {
            return XCTFail("expected unavailable, got \(result)")
        }
    }

    func testValidEqualWorkSiblingIsAcceptedAsSideBlock() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let first = try await child(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let sibling = try await child(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 2)
        let lattice = makeLattice(genesis: genesis)

        let firstResult = await lattice.admitBlockHeaderChainLocal(
            try VolumeImpl<Block>(node: first),
            fetcher: fetcher
        )
        guard case .canonicalized = firstResult else {
            return XCTFail("first child should canonicalize, got \(firstResult)")
        }

        let siblingResult = await lattice.admitBlockHeaderChainLocal(
            try VolumeImpl<Block>(node: sibling),
            fetcher: fetcher
        )
        guard case .acceptedSide = siblingResult else {
            return XCTFail("equal-work sibling should be accepted as side, got \(siblingResult)")
        }

        let siblingCID = try VolumeImpl<Block>(node: sibling).rawCID
        XCTAssertTrue(await lattice.nexus.chain.contains(blockHash: siblingCID))
    }

    func testStorageFailurePreventsVisibleConsensusMutation() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let block = try await child(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let lattice = makeLattice(genesis: genesis)
        let beforeTip = await lattice.nexus.chain.getMainChainTip()
        let blockCID = try VolumeImpl<Block>(node: block).rawCID

        let result = await lattice.admitBlockHeaderChainLocal(
            try VolumeImpl<Block>(node: block),
            fetcher: fetcher,
            beforeCommit: { _, _, _ in .storageFailed }
        )

        guard case .storageFailed = result else {
            return XCTFail("expected storage failure, got \(result)")
        }
        XCTAssertEqual(await lattice.nexus.chain.getMainChainTip(), beforeTip)
        XCTAssertFalse(await lattice.nexus.chain.contains(blockHash: blockCID))
    }

    func testParentReorganizationDoesNotMutateChildChain() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 10_000)
        let childLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            children: [:]
        )
        let lattice = makeLattice(genesis: parentGenesis, children: ["child": childLevel])
        let childTipBefore = await childLevel.chain.getMainChainTip()

        let incumbent = try await child(
            of: parentGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let forkOne = try await child(
            of: parentGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2
        )
        let forkTwo = try await child(
            of: forkOne,
            fetcher: fetcher,
            timestamp: 3_000,
            nonce: 3
        )

        guard case .canonicalized = await lattice.admitBlockHeaderChainLocal(
            try VolumeImpl<Block>(node: incumbent), fetcher: fetcher
        ) else {
            return XCTFail("incumbent did not canonicalize")
        }
        guard case .acceptedSide = await lattice.admitBlockHeaderChainLocal(
            try VolumeImpl<Block>(node: forkOne), fetcher: fetcher
        ) else {
            return XCTFail("fork root did not enter side graph")
        }
        guard case .canonicalized = await lattice.admitBlockHeaderChainLocal(
            try VolumeImpl<Block>(node: forkTwo), fetcher: fetcher
        ) else {
            return XCTFail("longer parent fork did not canonicalize")
        }

        XCTAssertEqual(
            await childLevel.chain.getMainChainTip(),
            childTipBefore,
            "a parent reorganization must not directly mutate child canonicity"
        )
    }
}
