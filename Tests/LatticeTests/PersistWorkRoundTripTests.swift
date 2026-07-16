import Foundation
import XCTest
@testable import Lattice
import UInt256
import cashew

private func persistedContribution(
    _ id: String,
    work: UInt256
) -> VerifiedWorkContribution {
    VerifiedWorkContribution(id: id, work: work)
}

private func persistedCID(_ seed: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
}

private func persistedWorkSpec() -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1024,
        halvingInterval: 10_000,
        retargetWindow: 5
    )
}

private func persistedMeta(
    hash: String,
    parent: String? = nil,
    height: UInt64,
    children: [String] = [],
    contributions: [VerifiedWorkContribution],
    cumulativeWork: UInt256
) -> PersistedBlockMeta {
    PersistedBlockMeta(
        blockHash: hash,
        parentBlockHash: parent,
        blockHeight: height,
        childHashes: children,
        workContributions: contributions,
        cumulativeWork: cumulativeWork.toHexString()
    )
}

private func persistedState(
    revision: UInt64 = 0,
    tip: String,
    main: [String],
    blocks: [PersistedBlockMeta]
) -> PersistedChainState {
    PersistedChainState(
        revision: revision,
        chainTip: tip,
        mainChainHashes: main,
        blocks: blocks
    )
}

final class PersistWorkRoundTripTests: XCTestCase {
    private let adversarialWorks: [UInt256] = [
        UInt256.max / UInt256(3) + UInt256(1),
        UInt256.max / UInt256(7) + UInt256(5),
        UInt256(3),
        UInt256(0x1_0000_0000) + UInt256(7),
        UInt256.max - UInt256(1),
    ]

    func testContributionWorkIsBitIdenticalAcrossRestart() async throws {
        for (index, work) in adversarialWorks.enumerated() {
            let genesisHash = persistedCID("genesis-\(index)")
            let parentHash = persistedCID("parent-\(index)")
            let tipHash = persistedCID("tip-\(index)")
            let blocks = [
                makeBlockMeta(
                    hash: genesisHash,
                    height: 0,
                    childHashes: [parentHash],
                    work: UInt256(1),
                    cumulativeWork: UInt256(1)
                ),
                makeBlockMeta(
                    hash: parentHash,
                    previousHash: genesisHash,
                    height: 1,
                    childHashes: [tipHash],
                    work: work,
                    cumulativeWork: WorkSum(UInt256(1)) + work
                ),
                makeBlockMeta(
                    hash: tipHash,
                    previousHash: parentHash,
                    height: 2,
                    work: work,
                    cumulativeWork: WorkSum(UInt256(1)) + work + work
                ),
            ]
            let mainChain = Set([genesisHash, parentHash, tipHash])
            let oracle = makeChain(blocks: blocks, mainChainHashes: mainChain)
            let restored = try ChainState.restore(
                from: await makeChain(blocks: blocks, mainChainHashes: mainChain).persist()
            )

            let restoredRoot = await restored.subtreeWeight(forHash: genesisHash)
            let oracleRoot = await oracle.subtreeWeight(forHash: genesisHash)
            let restoredTip = await restored.subtreeWeight(forHash: tipHash)
            let oracleTip = await oracle.subtreeWeight(forHash: tipHash)
            XCTAssertEqual(restoredRoot, oracleRoot)
            XCTAssertEqual(restoredTip, oracleTip)
        }
    }

    func testOneBlockRoundTripsEveryGrindAndDuplicateIsIdempotent() async throws {
        let fetcher = StorableFetcher()
        let target = UInt256(1_000)
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 20_000
        let genesis = try await buildAndStoreGenesis(
            spec: persistedWorkSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let block = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 1_000,
            target: target,
            nonce: 1,
            fetcher: fetcher
        )
        let header = try BlockHeader(node: block)
        let firstGrind = VerifiedWorkContribution(id: "grind:first", work: workForTarget(target))
        let secondGrind = VerifiedWorkContribution(id: "grind:second", work: UInt256(7))
        let chain = ChainState.fromGenesis(block: genesis)

        let inserted = await chain.submitBlock(
            blockHeader: header,
            block: block,
            contribution: firstGrind
        )
        let added = await chain.submitBlock(
            blockHeader: header,
            block: block,
            contribution: secondGrind
        )
        let duplicate = await chain.submitBlock(
            blockHeader: header,
            block: block,
            contribution: secondGrind
        )

        XCTAssertTrue(inserted.addedBlock)
        XCTAssertTrue(added.addedContribution)
        XCTAssertFalse(duplicate.addedContribution)
        XCTAssertNil(duplicate.commit)

        let snapshot = await chain.persist()
        XCTAssertEqual(snapshot.revision, added.commit?.revision)
        let persistedBlock = try XCTUnwrap(snapshot.blocks.first { $0.blockHash == header.rawCID })
        XCTAssertEqual(Set(persistedBlock.workContributions.map(\.id)), [firstGrind.id, secondGrind.id])

        let restored = try ChainState.restore(from: snapshot)
        let restoredSnapshot = await restored.persist()
        XCTAssertEqual(restoredSnapshot.revision, snapshot.revision)
        let restoredBlock = try XCTUnwrap(
            restoredSnapshot.blocks.first { $0.blockHash == header.rawCID }
        )
        XCTAssertEqual(restoredBlock.workContributions, persistedBlock.workContributions)

        let replay = await restored.submitBlock(
            blockHeader: header,
            block: block,
            contribution: secondGrind
        )
        XCTAssertFalse(replay.addedContribution)
        let replayedSnapshot = await restored.persist()
        XCTAssertEqual(replayedSnapshot.revision, snapshot.revision)
    }

    func testRecoveryReplaysStagedFactsAcrossSnapshotAndKeepsEveryGrind() async throws {
        let fetcher = StorableFetcher()
        let target = UInt256(1_000)
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 20_000
        let genesis = try await buildAndStoreGenesis(
            spec: persistedWorkSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let block1 = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 1_000,
            target: target,
            nonce: 1,
            fetcher: fetcher
        )
        let block2 = try await buildAndStoreBlock(
            previous: block1,
            timestamp: base + 2_000,
            target: target,
            nonce: 2,
            fetcher: fetcher
        )
        let block1Header = try BlockHeader(node: block1)
        let block2Header = try BlockHeader(node: block2)
        let work1 = VerifiedWorkContribution(
            id: block1Header.rawCID,
            work: workForTarget(target)
        )
        let work2 = VerifiedWorkContribution(
            id: block2Header.rawCID,
            work: workForTarget(target)
        )
        let secondWork2 = VerifiedWorkContribution(
            id: persistedCID("recovery-second-grind"),
            work: UInt256(17)
        )
        let block1Batch = try testAdmissionBatch(block: block1, contribution: work1)
        let block2Batch = try testAdmissionBatch(block: block2, contribution: work2)
        let secondWorkBatch = testWorkBatch(
            blockHash: block2Header.rawCID,
            contribution: secondWork2
        )

        let live = ChainState.fromGenesis(block: genesis)
        let inserted1 = await live.submitBlock(
            blockHeader: block1Header,
            block: block1,
            contribution: work1
        )
        XCTAssertTrue(inserted1.addedBlock)
        let snapshot = await live.persist()

        let inserted2 = await live.submitBlock(
            blockHeader: block2Header,
            block: block2,
            contribution: work2
        )
        XCTAssertTrue(inserted2.addedBlock)
        let addedSecondWork = await live.submitBlock(
            blockHeader: block2Header,
            block: block2,
            contribution: secondWork2
        )
        XCTAssertTrue(addedSecondWork.addedContribution)
        let expected = await live.persist()

        let restored = try await ChainState.restore(
            from: snapshot,
            replaying: [
                block1Batch,
                block2Batch,
                secondWorkBatch,
                block2Batch,
                secondWorkBatch,
            ]
        )
        let recovered = await restored.persist()
        XCTAssertEqual(recovered.revision, expected.revision)
        XCTAssertEqual(recovered.chainTip, expected.chainTip)
        XCTAssertEqual(recovered.mainChainHashes, expected.mainChainHashes)
        XCTAssertEqual(recovered.blocks.count, expected.blocks.count)
        for (actual, expected) in zip(recovered.blocks, expected.blocks) {
            XCTAssertEqual(actual, expected, "replayed block \(actual.blockHash) differs from its live counterpart")
        }
    }

    func testRecoveryCanCreateAChainFromUnorderedStagedBatches() async throws {
        let fetcher = StorableFetcher()
        let target = UInt256(1_000)
        let genesis = try await buildAndStoreGenesis(
            spec: persistedWorkSpec(),
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000) - 20_000,
            target: target,
            fetcher: fetcher
        )
        let child = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 1_000,
            target: target,
            nonce: 1,
            fetcher: fetcher
        )
        let genesisHeader = try BlockHeader(node: genesis)
        let childHeader = try BlockHeader(node: child)
        let genesisContribution = VerifiedWorkContribution(
            id: genesisHeader.rawCID,
            work: workForTarget(target)
        )
        let childContribution = VerifiedWorkContribution(
            id: childHeader.rawCID,
            work: workForTarget(target)
        )
        let genesisBatch = try testAdmissionBatch(
            block: genesis,
            contribution: genesisContribution
        )
        let childBatch = try testAdmissionBatch(
            block: child,
            contribution: childContribution
        )

        let restored = try await ChainState.restore(replaying: [
            childBatch,
            genesisBatch,
            childBatch,
            genesisBatch,
        ])
        let live = ChainState.fromGenesis(block: genesis)
        _ = await live.submitBlock(
            blockHeader: childHeader,
            block: child,
            contribution: childContribution
        )
        let expected = await live.persist()
        let recovered = await restored.persist()
        XCTAssertEqual(recovered.revision, expected.revision)
        XCTAssertEqual(recovered.chainTip, expected.chainTip)
        XCTAssertEqual(recovered.mainChainHashes, expected.mainChainHashes)
        XCTAssertEqual(recovered.blocks.count, expected.blocks.count)
        for (actual, expected) in zip(recovered.blocks, expected.blocks) {
            XCTAssertEqual(actual, expected)
        }
    }

    func testRestartRetainsDetachedDescendantGrindsUntilItsParentCanReorg() async throws {
        let fetcher = StorableFetcher()
        let target = UInt256(1_000)
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 20_000
        let genesis = try await buildAndStoreGenesis(
            spec: persistedWorkSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let main1 = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 1_000,
            target: target,
            nonce: 1,
            fetcher: fetcher
        )
        let main2 = try await buildAndStoreBlock(
            previous: main1,
            timestamp: base + 2_000,
            target: target,
            nonce: 2,
            fetcher: fetcher
        )
        let fork1 = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 1_000,
            target: target,
            nonce: 3,
            fetcher: fetcher
        )
        let fork2 = try await buildAndStoreBlock(
            previous: fork1,
            timestamp: base + 2_000,
            target: target,
            nonce: 4,
            fetcher: fetcher
        )
        let main1Header = try BlockHeader(node: main1)
        let main2Header = try BlockHeader(node: main2)
        let fork1Header = try BlockHeader(node: fork1)
        let fork2Header = try BlockHeader(node: fork2)
        let ordinaryWork = workForTarget(target)
        let main1Work = VerifiedWorkContribution(id: main1Header.rawCID, work: ordinaryWork)
        let main2Work = VerifiedWorkContribution(id: main2Header.rawCID, work: ordinaryWork)
        let fork1Work = VerifiedWorkContribution(id: fork1Header.rawCID, work: ordinaryWork)
        let fork2Work = VerifiedWorkContribution(id: fork2Header.rawCID, work: ordinaryWork)
        let fork2ExtraWork = VerifiedWorkContribution(
            id: persistedCID("detached-extra-grind"),
            work: UInt256.max
        )

        let live = ChainState.fromGenesis(block: genesis)
        _ = await live.submitBlock(blockHeader: main1Header, block: main1, contribution: main1Work)
        _ = await live.submitBlock(blockHeader: main2Header, block: main2, contribution: main2Work)
        let detached = await live.submitBlock(
            blockHeader: fork2Header,
            block: fork2,
            contribution: fork2Work
        )
        let extraGrind = await live.submitBlock(
            blockHeader: fork2Header,
            block: fork2,
            contribution: fork2ExtraWork
        )
        XCTAssertTrue(detached.needsParentBlock)
        XCTAssertTrue(extraGrind.addedContribution)
        let snapshot = await live.persist()

        let parentArrival = await live.submitBlock(
            blockHeader: fork1Header,
            block: fork1,
            contribution: fork1Work
        )
        XCTAssertTrue(parentArrival.commit?.canonicalChanged ?? false)
        let expectedTip = await live.getMainChainTip()
        let expected = await live.persist()

        let restored = try ChainState.restore(from: snapshot)
        let restoredParentArrival = await restored.submitBlock(
            blockHeader: fork1Header,
            block: fork1,
            contribution: fork1Work
        )
        let restoredTip = await restored.getMainChainTip()
        let recovered = await restored.persist()
        let restoredFork2 = try XCTUnwrap(
            recovered.blocks.first { $0.blockHash == fork2Header.rawCID }
        )

        XCTAssertTrue(restoredParentArrival.commit?.canonicalChanged ?? false)
        XCTAssertEqual(restoredTip, expectedTip)
        XCTAssertEqual(recovered.revision, expected.revision)
        XCTAssertEqual(
            Set(restoredFork2.workContributions.map(\.id)),
            Set([fork2Work.id, fork2ExtraWork.id])
        )
    }

    func testPersistedRecordCarriesVerifiedContributionInsteadOfReconstructedTargetWork() async throws {
        let work = UInt256.max / UInt256(3) + UInt256(1)
        let genesisHash = persistedCID("exact-genesis")
        let blockHash = persistedCID("exact-block")
        XCTAssertNotEqual(workForTarget(UInt256.max / work), work)
        let chain = makeChain(
            blocks: [
                makeBlockMeta(
                    hash: genesisHash,
                    height: 0,
                    childHashes: [blockHash],
                    work: UInt256(1),
                    cumulativeWork: UInt256(1)
                ),
                makeBlockMeta(
                    hash: blockHash,
                    previousHash: genesisHash,
                    height: 1,
                    work: work,
                    cumulativeWork: WorkSum(UInt256(1)) + work
                ),
            ],
            mainChainHashes: [genesisHash, blockHash]
        )
        let bytes = try JSONEncoder().encode(await chain.persist())
        let decoded = try JSONDecoder().decode(PersistedChainState.self, from: bytes)
        let block = try XCTUnwrap(decoded.blocks.first { $0.blockHash == blockHash })

        XCTAssertEqual(block.workContributions.count, 1)
        XCTAssertEqual(block.workContributions.first?.work, work)
    }

    func testRestoreRejectsMissingOrZeroContribution() {
        let hash = persistedCID("invalid-work")
        let missing = persistedMeta(
            hash: hash,
            height: 0,
            contributions: [],
            cumulativeWork: UInt256(1)
        )
        let zero = persistedMeta(
            hash: hash,
            height: 0,
            contributions: [persistedContribution("grind:zero", work: .zero)],
            cumulativeWork: UInt256(1)
        )

        for block in [missing, zero] {
            XCTAssertThrowsError(
                try ChainState.restore(from: persistedState(tip: hash, main: [hash], blocks: [block]))
            ) { error in
                XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
            }
        }
    }

    func testRestoreRejectsDuplicateContributionWithinBlock() {
        let hash = persistedCID("duplicate-work")
        let contribution = persistedContribution("same-grind", work: UInt256(1))
        let block = persistedMeta(
            hash: hash,
            height: 0,
            contributions: [contribution, contribution],
            cumulativeWork: UInt256(1)
        )

        XCTAssertThrowsError(
            try ChainState.restore(from: persistedState(tip: hash, main: [hash], blocks: [block]))
        ) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreRejectsDuplicateChildEdges() {
        let rootHash = persistedCID("duplicate-edge-root")
        let childHash = persistedCID("duplicate-edge-child")
        let root = persistedMeta(
            hash: rootHash,
            height: 0,
            children: [childHash, childHash],
            contributions: [persistedContribution("grind:root", work: UInt256(1))],
            cumulativeWork: UInt256(1)
        )
        let child = persistedMeta(
            hash: childHash,
            parent: rootHash,
            height: 1,
            contributions: [persistedContribution("grind:child", work: UInt256(1))],
            cumulativeWork: UInt256(2)
        )

        XCTAssertThrowsError(
            try ChainState.restore(
                from: persistedState(tip: childHash, main: [rootHash, childHash], blocks: [root, child])
            )
        ) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreRejectsStaleForkChoice() {
        XCTAssertThrowsError(try ChainState.restore(from: staleForkChoiceSnapshot())) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreRejectsHeavierCompetingRoot() {
        let canonicalHash = persistedCID("canonical-root")
        let competingHash = persistedCID("competing-root")
        let canonical = persistedMeta(
            hash: canonicalHash,
            height: 0,
            contributions: [persistedContribution("grind:canonical", work: UInt256(1))],
            cumulativeWork: UInt256(1)
        )
        let competing = persistedMeta(
            hash: competingHash,
            height: 0,
            contributions: [persistedContribution("grind:competing", work: UInt256(2))],
            cumulativeWork: UInt256(2)
        )

        XCTAssertThrowsError(
            try ChainState.restore(
                from: persistedState(
                    tip: canonicalHash,
                    main: [canonicalHash],
                    blocks: [canonical, competing]
                )
            )
        ) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreRejectsContributionReplayedAcrossBlocks() {
        let rootHash = persistedCID("replay-root")
        let childHash = persistedCID("replay-child")
        let repeated = persistedContribution("same-grind", work: UInt256(1))
        let root = persistedMeta(
            hash: rootHash,
            height: 0,
            children: [childHash],
            contributions: [repeated],
            cumulativeWork: UInt256(1)
        )
        let child = persistedMeta(
            hash: childHash,
            parent: rootHash,
            height: 1,
            contributions: [repeated],
            cumulativeWork: UInt256(2)
        )

        XCTAssertThrowsError(
            try ChainState.restore(
                from: persistedState(tip: childHash, main: [rootHash, childHash], blocks: [root, child])
            )
        ) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    private func staleForkChoiceSnapshot() -> PersistedChainState {
        let rootHash = persistedCID("stale-root")
        let incumbentHash = persistedCID("stale-incumbent")
        let forkHash = persistedCID("stale-fork")
        let winningTipHash = persistedCID("stale-winning-tip")
        let root = persistedMeta(
            hash: rootHash,
            height: 0,
            children: [incumbentHash, forkHash],
            contributions: [persistedContribution("grind:stale-root", work: UInt256(1))],
            cumulativeWork: UInt256(1)
        )
        let incumbent = persistedMeta(
            hash: incumbentHash,
            parent: rootHash,
            height: 1,
            contributions: [persistedContribution("grind:stale-incumbent", work: UInt256(2))],
            cumulativeWork: UInt256(3)
        )
        let fork = persistedMeta(
            hash: forkHash,
            parent: rootHash,
            height: 1,
            children: [winningTipHash],
            contributions: [persistedContribution("grind:stale-fork", work: UInt256(1))],
            cumulativeWork: UInt256(2)
        )
        let winningTip = persistedMeta(
            hash: winningTipHash,
            parent: forkHash,
            height: 2,
            contributions: [persistedContribution("grind:stale-tip", work: UInt256(2))],
            cumulativeWork: UInt256(4)
        )
        return persistedState(
            tip: incumbentHash,
            main: [rootHash, incumbentHash],
            blocks: [root, incumbent, fork, winningTip]
        )
    }
}
