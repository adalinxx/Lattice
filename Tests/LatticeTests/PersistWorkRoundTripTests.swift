import Foundation
import XCTest
@testable import Lattice
import UInt256
import cashew

private func persistedContribution(
    _ id: String,
    work: UInt256
) -> VerifiedWorkContribution {
    VerifiedWorkContribution(id: persistedCID(id), work: work)
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
    cumulativeWork _: UInt256
) -> PersistedBlockMeta {
    PersistedBlockMeta(
        blockHash: hash,
        parentBlockHash: parent,
        blockHeight: height,
        childHashes: children,
        workContributions: contributions
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

private func inheritedForkState(
    revision: UInt64 = 19
) -> (
    state: PersistedChainState,
    rootHash: String,
    incumbentHash: String,
    forkHash: String,
    inherited: InheritedWorkSnapshot
) {
    let rootHash = persistedCID("restart-inherited-root")
    let incumbentHash = persistedCID("restart-inherited-incumbent")
    let forkHash = persistedCID("restart-inherited-fork")
    let root = persistedMeta(
        hash: rootHash,
        height: 0,
        children: [incumbentHash, forkHash],
        contributions: [persistedContribution("restart-root-work", work: UInt256(1))],
        cumulativeWork: UInt256(1)
    )
    let incumbent = persistedMeta(
        hash: incumbentHash,
        parent: rootHash,
        height: 1,
        contributions: [persistedContribution("restart-incumbent-work", work: UInt256(4))],
        cumulativeWork: UInt256(5)
    )
    let fork = persistedMeta(
        hash: forkHash,
        parent: rootHash,
        height: 1,
        contributions: [persistedContribution("restart-fork-work", work: UInt256(1))],
        cumulativeWork: UInt256(2)
    )
    let inherited = InheritedWorkSnapshot(
        revision: 7,
        workByBlock: [
            forkHash: WorkMeasure(
                persistedContribution("restart-parent-work", work: UInt256(7))
            ),
        ]
    )
    return (
        PersistedChainState(
            revision: revision,
            inheritedWorkRevision: inherited.revision,
            inheritedWorkSnapshot: inherited,
            chainTip: forkHash,
            mainChainHashes: [rootHash, forkHash].sorted(),
            blocks: [root, incumbent, fork].sorted { $0.blockHash < $1.blockHash }
        ),
        rootHash,
        incumbentHash,
        forkHash,
        inherited
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
        let firstGrind = VerifiedWorkContribution(
            id: persistedCID("grind:first"),
            work: workForTarget(target)
        )
        let secondGrind = VerifiedWorkContribution(
            id: persistedCID("grind:second"),
            work: UInt256(7)
        )
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
        let weakerSharedWork = VerifiedWorkContribution(
            id: persistedCID("recovery-upgraded-grind"),
            work: UInt256(5)
        )
        let strongerSharedWork = VerifiedWorkContribution(
            id: weakerSharedWork.id,
            work: UInt256(23)
        )
        let block1Batch = try testAdmissionBatch(block: block1, contribution: work1)
        let block2Batch = try testAdmissionBatch(block: block2, contribution: work2)
        let secondWorkBatch = testWorkBatch(
            blockHash: block2Header.rawCID,
            contribution: secondWork2
        )
        let weakerSharedWorkBatch = testWorkBatch(
            blockHash: block2Header.rawCID,
            contribution: weakerSharedWork
        )
        let strongerSharedWorkBatch = testWorkBatch(
            blockHash: block2Header.rawCID,
            contribution: strongerSharedWork
        )
        XCTAssertNotEqual(weakerSharedWorkBatch.facts[0].id, strongerSharedWorkBatch.facts[0].id)

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
        let addedWeakerSharedWork = await live.submitBlock(
            blockHeader: block2Header,
            block: block2,
            contribution: weakerSharedWork
        )
        XCTAssertTrue(addedWeakerSharedWork.addedContribution)
        let upgradedSharedWork = await live.submitBlock(
            blockHeader: block2Header,
            block: block2,
            contribution: strongerSharedWork
        )
        XCTAssertTrue(upgradedSharedWork.addedContribution)
        let expected = await live.persist()

        let restored = try await ChainState.restore(
            from: snapshot,
            replaying: [
                block1Batch,
                block2Batch,
                secondWorkBatch,
                strongerSharedWorkBatch,
                weakerSharedWorkBatch,
                block2Batch,
                secondWorkBatch,
                strongerSharedWorkBatch,
            ]
        )
        let recovered = await restored.persist()
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

        let floored = try await ChainState.restore(
            replaying: [childBatch, genesisBatch],
            revisionFloor: 40
        )
        let flooredSnapshot = await floored.persist()
        XCTAssertEqual(flooredSnapshot.revision, 41)
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
        _ = await live.submitBlock(
            blockHeader: fork2Header,
            block: fork2,
            contribution: fork2Work
        )
        let extraGrind = await live.submitBlock(
            blockHeader: fork2Header,
            block: fork2,
            contribution: fork2ExtraWork
        )
        let liveRequirements = await live.unresolvedSameChainPredecessors()
        XCTAssertEqual(
            liveRequirements,
            [SameChainPredecessorRequirement(
                descendantCID: fork2Header.rawCID,
                predecessorCID: fork1Header.rawCID
            )]
        )
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
        let restoredRequirements = await restored.unresolvedSameChainPredecessors()
        XCTAssertEqual(
            restoredRequirements,
            [SameChainPredecessorRequirement(
                descendantCID: fork2Header.rawCID,
                predecessorCID: fork1Header.rawCID
            )]
        )
        let restoredParentArrival = await restored.submitBlock(
            blockHeader: fork1Header,
            block: fork1,
            contribution: fork1Work
        )
        let restoredTip = await restored.getMainChainTip()
        let recovered = await restored.persist()
        let remainingRequirements = await restored.unresolvedSameChainPredecessors()
        let restoredFork2 = try XCTUnwrap(
            recovered.blocks.first { $0.blockHash == fork2Header.rawCID }
        )

        XCTAssertTrue(restoredParentArrival.commit?.canonicalChanged ?? false)
        XCTAssertEqual(restoredTip, expectedTip)
        XCTAssertTrue(remainingRequirements.isEmpty)
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

    func testRestoreRejectsMissingZeroOrMalformedContribution() {
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
        let malformed = persistedMeta(
            hash: hash,
            height: 0,
            contributions: [
                VerifiedWorkContribution(id: "not-a-cid", work: UInt256(1)),
            ],
            cumulativeWork: UInt256(1)
        )

        for block in [missing, zero, malformed] {
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

    func testRestoreReprojectsStaleForkChoice() async throws {
        let snapshot = staleForkChoiceSnapshot()
        let restored = try ChainState.restore(from: snapshot)
        let tip = await restored.getMainChainTip()

        XCTAssertEqual(
            tip,
            persistedCID("stale-winning-tip")
        )
    }

    func testRestoreReprojectsToHeavierCompetingRoot() async throws {
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

        let restored = try ChainState.restore(
            from: persistedState(
                tip: canonicalHash,
                main: [canonicalHash],
                blocks: [canonical, competing]
            )
        )
        let tip = await restored.getMainChainTip()

        XCTAssertEqual(tip, competingHash)
    }

    func testRestoreReprojectsUsingCurrentInheritedWork() async throws {
        let rootHash = persistedCID("inherited-root")
        let incumbentHash = persistedCID("inherited-incumbent")
        let forkHash = persistedCID("inherited-fork")
        let root = persistedMeta(
            hash: rootHash,
            height: 0,
            children: [incumbentHash, forkHash],
            contributions: [persistedContribution("grind:inherited-root", work: UInt256(1))],
            cumulativeWork: UInt256(1)
        )
        let incumbent = persistedMeta(
            hash: incumbentHash,
            parent: rootHash,
            height: 1,
            contributions: [persistedContribution("grind:inherited-incumbent", work: UInt256(3))],
            cumulativeWork: UInt256(4)
        )
        let fork = persistedMeta(
            hash: forkHash,
            parent: rootHash,
            height: 1,
            contributions: [persistedContribution("grind:inherited-fork", work: UInt256(1))],
            cumulativeWork: UInt256(2)
        )
        let inherited = InheritedWorkSnapshot(
            revision: 7,
            workByBlock: [
                forkHash: WorkMeasure(
                    VerifiedWorkContribution(
                        id: persistedCID("inherited-parent-grind"),
                        work: UInt256(5)
                    )
                ),
            ]
        )

        let restored = try ChainState.restore(
            from: persistedState(
                tip: incumbentHash,
                main: [rootHash, incumbentHash],
                blocks: [root, incumbent, fork]
            ),
            inheritedWorkProvider: { inherited }
        )
        let tip = await restored.getMainChainTip()

        XCTAssertEqual(tip, forkHash)
    }

    func testRestoreNormalizesOneGrindAcrossLocalAndInheritedCoverage() async throws {
        let rootHash = persistedCID("cross-source-root")
        let firstHash = persistedCID("cross-source-first")
        let secondHash = persistedCID("cross-source-second")
        let preferredHash = forkChoicePrefersSegmentBase(firstHash, over: secondHash)
            ? firstHash : secondHash
        let otherHash = preferredHash == firstHash ? secondHash : firstHash
        let shared = persistedContribution("cross-source-shared", work: UInt256(1))
        let root = persistedMeta(
            hash: rootHash,
            height: 0,
            children: [firstHash, secondHash],
            contributions: [persistedContribution("cross-source-root-work", work: UInt256(1))],
            cumulativeWork: UInt256(1)
        )
        let preferred = persistedMeta(
            hash: preferredHash,
            parent: rootHash,
            height: 1,
            contributions: [
                persistedContribution("cross-source-preferred", work: UInt256(1)),
                shared,
            ],
            cumulativeWork: UInt256(3)
        )
        let other = persistedMeta(
            hash: otherHash,
            parent: rootHash,
            height: 1,
            contributions: [persistedContribution("cross-source-other", work: UInt256(1))],
            cumulativeWork: UInt256(2)
        )
        let inherited = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                otherHash: WorkMeasure(
                    VerifiedWorkContribution(id: shared.id, work: UInt256(100))
                ),
            ]
        )

        let restored = try ChainState.restore(
            from: persistedState(
                tip: preferredHash,
                main: [rootHash, preferredHash],
                blocks: [root, preferred, other]
            ),
            inheritedWorkProvider: { inherited }
        )
        let tip = await restored.getMainChainTip()

        XCTAssertEqual(tip, preferredHash)
    }

    func testRestoreRetainsInheritedSnapshotAndRequiresProviderWhenCacheIsOmitted() async throws {
        let rootHash = persistedCID("retained-inherited-root")
        let local = VerifiedWorkContribution(
            id: persistedCID("retained-inherited-local"),
            work: UInt256(1)
        )
        let root = BlockMeta(
            blockHash: rootHash,
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            workContributions: [local]
        )
        let chain = makeChain(blocks: [root])
        let inherited = InheritedWorkSnapshot(
            revision: 3,
            workByBlock: [
                rootHash: WorkMeasure(
                    VerifiedWorkContribution(
                        id: persistedCID("retained-inherited-parent"),
                        work: UInt256(5)
                    )
                ),
            ]
        )
        _ = await chain.setInheritedWorkProvider { inherited }
        let snapshot = await chain.persist()
        XCTAssertEqual(snapshot.inheritedWorkRevision, 3)
        XCTAssertEqual(snapshot.inheritedWorkSnapshot, inherited)

        let cachedRestore = try ChainState.restore(from: snapshot)
        let cachedRoundTrip = await cachedRestore.persist()
        XCTAssertEqual(cachedRoundTrip.inheritedWorkSnapshot, inherited)

        let uncached = PersistedChainState(
            schemaVersion: snapshot.schemaVersion,
            revision: snapshot.revision,
            inheritedWorkRevision: snapshot.inheritedWorkRevision,
            inheritedWorkSnapshot: nil,
            chainTip: snapshot.chainTip,
            mainChainHashes: snapshot.mainChainHashes,
            blocks: snapshot.blocks
        )
        XCTAssertThrowsError(try ChainState.restore(from: uncached)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .missingInheritedWorkSnapshot)
        }
        XCTAssertThrowsError(
            try ChainState.restore(
                from: uncached,
                inheritedWorkProvider: {
                    InheritedWorkSnapshot(revision: 2, workByBlock: [:])
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? ChainStateRestoreError,
                .missingInheritedWorkSnapshot
            )
        }

        let restored = try ChainState.restore(
            from: snapshot,
            inheritedWorkProvider: {
                InheritedWorkSnapshot(revision: 4, workByBlock: [:])
            }
        )
        let restoredSnapshot = await restored.persist()
        XCTAssertEqual(restoredSnapshot.inheritedWorkRevision, 4)
        XCTAssertEqual(
            restoredSnapshot.inheritedWorkSnapshot?.work(forBlock: rootHash),
            inherited.work(forBlock: rootHash)
        )
    }

    func testJSONRoundTripRetainsInheritedForkChoiceDuringProviderOutage() async throws {
        let fixture = inheritedForkState()
        let source = try ChainState.restore(from: fixture.state)
        let sourceChoiceValue = await source.forkChoiceSnapshot(startingAt: fixture.rootHash)
        let sourceChoice = try XCTUnwrap(sourceChoiceValue)
        let sourceSnapshot = await source.persist()

        XCTAssertEqual(sourceChoice.tipHash, fixture.forkHash)
        XCTAssertEqual(sourceChoice.mainChainPath, [fixture.rootHash, fixture.forkHash])
        XCTAssertEqual(sourceChoice.subtreeWork, WorkSum(UInt256(13)))
        XCTAssertEqual(sourceSnapshot.revision, fixture.state.revision)

        let bytes = try JSONEncoder().encode(sourceSnapshot)
        let decoded = try JSONDecoder().decode(PersistedChainState.self, from: bytes)
        let restored = try ChainState.restore(from: decoded)
        let restoredChoiceValue = await restored.forkChoiceSnapshot(
            startingAt: fixture.rootHash
        )
        let restoredChoice = try XCTUnwrap(restoredChoiceValue)
        let restoredSnapshot = await restored.persist()
        let restoredTip = await restored.getMainChainTip()

        XCTAssertEqual(decoded, sourceSnapshot)
        XCTAssertEqual(restoredTip, fixture.forkHash)
        XCTAssertEqual(restoredChoice.tipHash, sourceChoice.tipHash)
        XCTAssertEqual(restoredChoice.mainChainPath, sourceChoice.mainChainPath)
        XCTAssertEqual(restoredChoice.subtreeWork, sourceChoice.subtreeWork)
        XCTAssertEqual(restoredSnapshot.revision, sourceSnapshot.revision)
        XCTAssertEqual(restoredSnapshot.inheritedWorkRevision, fixture.inherited.revision)
        XCTAssertEqual(restoredSnapshot.inheritedWorkSnapshot, fixture.inherited)
        XCTAssertEqual(restoredSnapshot, sourceSnapshot)
    }

    func testCachelessRestoreRejectsUnverifiableProviderCompleteness() async throws {
        let fixture = inheritedForkState()
        let source = try ChainState.restore(from: fixture.state)
        let sourceSnapshot = await source.persist()
        let uncached = PersistedChainState(
            schemaVersion: sourceSnapshot.schemaVersion,
            revision: sourceSnapshot.revision,
            inheritedWorkRevision: sourceSnapshot.inheritedWorkRevision,
            inheritedWorkSnapshot: nil,
            chainTip: sourceSnapshot.chainTip,
            mainChainHashes: sourceSnapshot.mainChainHashes,
            blocks: sourceSnapshot.blocks
        )

        let newer = InheritedWorkSnapshot(
            revision: fixture.inherited.revision + 1,
            workByBlock: [
                fixture.forkHash: fixture.inherited.work(forBlock: fixture.forkHash),
            ]
        )
        for provider in [fixture.inherited, newer] {
            XCTAssertThrowsError(
                try ChainState.restore(
                    from: uncached,
                    inheritedWorkProvider: { provider }
                )
            ) { error in
                XCTAssertEqual(
                    error as? ChainStateRestoreError,
                    .missingInheritedWorkSnapshot
                )
            }
        }
    }

    func testRestoreRejectsInvalidInheritedBoundariesAndCachedPartialCannotRetract() async throws {
        let fixture = inheritedForkState()
        let uncached = PersistedChainState(
            schemaVersion: fixture.state.schemaVersion,
            revision: fixture.state.revision,
            inheritedWorkRevision: fixture.state.inheritedWorkRevision,
            inheritedWorkSnapshot: nil,
            chainTip: fixture.state.chainTip,
            mainChainHashes: fixture.state.mainChainHashes,
            blocks: fixture.state.blocks
        )
        let stale = InheritedWorkSnapshot(
            revision: fixture.inherited.revision - 1,
            workByBlock: [
                fixture.forkHash: fixture.inherited.work(forBlock: fixture.forkHash),
            ]
        )
        XCTAssertThrowsError(
            try ChainState.restore(from: uncached, inheritedWorkProvider: { stale })
        ) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .missingInheritedWorkSnapshot)
        }

        let unmarked = PersistedChainState(
            schemaVersion: fixture.state.schemaVersion,
            revision: fixture.state.revision,
            inheritedWorkRevision: nil,
            inheritedWorkSnapshot: nil,
            chainTip: fixture.state.chainTip,
            mainChainHashes: fixture.state.mainChainHashes,
            blocks: fixture.state.blocks
        )

        let malformedBlock = InheritedWorkSnapshot(
            revision: fixture.inherited.revision,
            workByBlock: [
                "not-a-cid": WorkMeasure(
                    persistedContribution("valid-malformed-boundary-work", work: UInt256(1))
                ),
            ]
        )
        XCTAssertThrowsError(
            try ChainState.restore(from: unmarked, inheritedWorkProvider: { malformedBlock })
        ) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }

        let malformedGrind = InheritedWorkSnapshot(
            revision: fixture.inherited.revision,
            workByBlock: [
                fixture.forkHash: WorkMeasure(
                    VerifiedWorkContribution(id: "not-a-cid", work: UInt256(1))
                ),
            ]
        )
        XCTAssertThrowsError(
            try ChainState.restore(from: unmarked, inheritedWorkProvider: { malformedGrind })
        ) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }

        let mismatchedMarker = PersistedChainState(
            schemaVersion: fixture.state.schemaVersion,
            revision: fixture.state.revision,
            inheritedWorkRevision: fixture.inherited.revision + 1,
            inheritedWorkSnapshot: fixture.inherited,
            chainTip: fixture.state.chainTip,
            mainChainHashes: fixture.state.mainChainHashes,
            blocks: fixture.state.blocks
        )
        XCTAssertThrowsError(try ChainState.restore(from: mismatchedMarker)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }

        let partialUpdate = InheritedWorkSnapshot(
            revision: fixture.inherited.revision + 1,
            workByBlock: [
                fixture.incumbentHash: WorkMeasure(
                    persistedContribution("partial-provider-addition", work: UInt256(1))
                ),
            ]
        )
        let retained = try ChainState.restore(
            from: fixture.state,
            inheritedWorkProvider: { partialUpdate }
        )
        let retainedSnapshot = await retained.persist()
        let merged = try XCTUnwrap(retainedSnapshot.inheritedWorkSnapshot)
        XCTAssertEqual(
            merged.work(forBlock: fixture.forkHash),
            fixture.inherited.work(forBlock: fixture.forkHash)
        )
        XCTAssertEqual(
            merged.work(forBlock: fixture.incumbentHash),
            partialUpdate.work(forBlock: fixture.incumbentHash)
        )
        let retainedTip = await retained.getMainChainTip()
        XCTAssertEqual(retainedTip, fixture.forkHash)
    }

    func testUnknownInheritedCoverageActivatesAfterAdmissionAndSurvivesReplay() async throws {
        let fetcher = StorableFetcher()
        let target = UInt256(1_000)
        let localWork = workForTarget(target)
        let inheritedWork = UInt256.max
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 20_000
        let genesis = try await buildAndStoreGenesis(
            spec: persistedWorkSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let incumbent = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 1_000,
            target: target,
            nonce: 1,
            fetcher: fetcher
        )
        let futureFork = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 1_000,
            target: target,
            nonce: 2,
            fetcher: fetcher
        )
        let genesisHeader = try BlockHeader(node: genesis)
        let incumbentHeader = try BlockHeader(node: incumbent)
        let futureHeader = try BlockHeader(node: futureFork)
        let incumbentContribution = VerifiedWorkContribution(
            id: incumbentHeader.rawCID,
            work: localWork
        )
        let futureContribution = VerifiedWorkContribution(
            id: futureHeader.rawCID,
            work: localWork
        )
        let futureBatch = try testAdmissionBatch(
            block: futureFork,
            contribution: futureContribution
        )
        let inherited = InheritedWorkSnapshot(
            revision: 40,
            workByBlock: [
                futureHeader.rawCID: WorkMeasure(
                    persistedContribution("future-inherited-work", work: inheritedWork)
                ),
            ]
        )

        let live = ChainState.fromGenesis(block: genesis)
        let incumbentResult = await live.submitTestBlock(
            blockHeader: incumbentHeader,
            block: incumbent,
            contribution: incumbentContribution
        )
        XCTAssertTrue(incumbentResult.addedBlock)
        let inheritedCommit = await live.setInheritedWorkProvider { inherited }
        let containsFutureBeforeAdmission = await live.contains(blockHash: futureHeader.rawCID)
        let tipBeforeAdmission = await live.getMainChainTip()
        XCTAssertEqual(inheritedCommit?.revision, 2)
        XCTAssertFalse(containsFutureBeforeAdmission)
        XCTAssertEqual(tipBeforeAdmission, incumbentHeader.rawCID)
        let beforeChoiceValue = await live.forkChoiceSnapshot(
            startingAt: genesisHeader.rawCID
        )
        let beforeChoice = try XCTUnwrap(beforeChoiceValue)
        XCTAssertEqual(beforeChoice.subtreeWork, WorkSum(localWork) + localWork)
        let beforeAdmission = await live.persist()

        let admitted = await live.submitTestBlock(
            blockHeader: futureHeader,
            block: futureFork,
            contribution: futureContribution
        )
        XCTAssertTrue(admitted.addedBlock)
        XCTAssertTrue(admitted.commit?.canonicalChanged ?? false)
        let liveTip = await live.getMainChainTip()
        XCTAssertEqual(liveTip, futureHeader.rawCID)
        let expectedChoiceValue = await live.forkChoiceSnapshot(
            startingAt: genesisHeader.rawCID
        )
        let expectedChoice = try XCTUnwrap(expectedChoiceValue)
        XCTAssertEqual(
            expectedChoice.subtreeWork,
            WorkSum(localWork) + localWork + localWork + inheritedWork
        )
        let expected = await live.persist()

        let beforeBytes = try JSONEncoder().encode(beforeAdmission)
        let decodedBefore = try JSONDecoder().decode(
            PersistedChainState.self,
            from: beforeBytes
        )
        let replayed = try await ChainState.restore(
            from: decodedBefore,
            replaying: [futureBatch]
        )
        let recovered = await replayed.persist()
        let replayedTip = await replayed.getMainChainTip()
        XCTAssertEqual(replayedTip, futureHeader.rawCID)
        XCTAssertEqual(recovered, expected)

        let recoveredBytes = try JSONEncoder().encode(recovered)
        let decodedRecovered = try JSONDecoder().decode(
            PersistedChainState.self,
            from: recoveredBytes
        )
        let outageRestart = try ChainState.restore(from: decodedRecovered)
        let restartedChoiceValue = await outageRestart.forkChoiceSnapshot(
            startingAt: genesisHeader.rawCID
        )
        let restartedChoice = try XCTUnwrap(restartedChoiceValue)
        let restartedTip = await outageRestart.getMainChainTip()
        let restartedSnapshot = await outageRestart.persist()
        XCTAssertEqual(restartedTip, futureHeader.rawCID)
        XCTAssertEqual(restartedChoice.tipHash, expectedChoice.tipHash)
        XCTAssertEqual(restartedChoice.subtreeWork, expectedChoice.subtreeWork)
        XCTAssertEqual(restartedSnapshot.revision, expected.revision)
    }

    func testRestoreFailsClosedWhenRevisionWouldOverflow() {
        let fixture = inheritedForkState(revision: .max)
        let newer = InheritedWorkSnapshot(
            revision: fixture.inherited.revision + 1,
            workByBlock: [
                fixture.forkHash: fixture.inherited.work(forBlock: fixture.forkHash),
            ]
        )
        XCTAssertThrowsError(
            try ChainState.restore(
                from: fixture.state,
                inheritedWorkProvider: { newer }
            )
        ) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }

        let staleProjection = staleForkChoiceSnapshot()
        let exhaustedProjection = PersistedChainState(
            schemaVersion: staleProjection.schemaVersion,
            revision: .max,
            inheritedWorkRevision: staleProjection.inheritedWorkRevision,
            inheritedWorkSnapshot: staleProjection.inheritedWorkSnapshot,
            chainTip: staleProjection.chainTip,
            mainChainHashes: staleProjection.mainChainHashes,
            blocks: staleProjection.blocks
        )
        XCTAssertThrowsError(try ChainState.restore(from: exhaustedProjection)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testNewBlockAtMaximumRevisionIsDiscardedWithoutMutation() async throws {
        let fetcher = StorableFetcher()
        let target = UInt256(1_000)
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 20_000
        let genesis = try await buildAndStoreGenesis(
            spec: persistedWorkSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let child = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 1_000,
            target: target,
            nonce: 1,
            fetcher: fetcher
        )
        let childHeader = try BlockHeader(node: child)
        let genesisSnapshot = await ChainState.fromGenesis(block: genesis).persist()
        let exhaustedSnapshot = PersistedChainState(
            schemaVersion: genesisSnapshot.schemaVersion,
            revision: .max,
            inheritedWorkRevision: genesisSnapshot.inheritedWorkRevision,
            inheritedWorkSnapshot: genesisSnapshot.inheritedWorkSnapshot,
            chainTip: genesisSnapshot.chainTip,
            mainChainHashes: genesisSnapshot.mainChainHashes,
            blocks: genesisSnapshot.blocks
        )
        let exhausted = try ChainState.restore(from: exhaustedSnapshot)
        let before = await exhausted.persist()

        let result = await exhausted.submitTestBlock(
            blockHeader: childHeader,
            block: child
        )

        XCTAssertFalse(result.addedBlock)
        XCTAssertFalse(result.addedContribution)
        XCTAssertNil(result.commit)
        let containsChild = await exhausted.contains(blockHash: childHeader.rawCID)
        let after = await exhausted.persist()
        XCTAssertFalse(containsChild)
        XCTAssertEqual(after, before)
    }

    func testDurableReplayHydratesSparseSnapshotMetadataWithoutRecountingWork() async throws {
        let fetcher = StorableFetcher()
        let target = UInt256.max
        let genesis = try await buildAndStoreGenesis(
            spec: persistedWorkSpec(),
            timestamp: 1_000,
            target: target,
            fetcher: fetcher
        )
        let child = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2_000,
            target: target,
            nonce: 1,
            fetcher: fetcher
        )
        let childHeader = try BlockHeader(node: child)
        let contribution = VerifiedWorkContribution(
            id: childHeader.rawCID,
            work: workForTarget(target)
        )
        let live = ChainState.fromGenesis(block: genesis)
        _ = await live.submitBlock(
            blockHeader: childHeader,
            block: child,
            contribution: contribution
        )
        let complete = await live.persist()
        let sparseBlocks = complete.blocks.map { block in
            guard block.blockHash == childHeader.rawCID else { return block }
            return PersistedBlockMeta(
                blockHash: block.blockHash,
                parentBlockHash: block.parentBlockHash,
                blockHeight: block.blockHeight,
                childHashes: block.childHashes,
                workContributions: block.workContributions,
                timestamp: block.timestamp
            )
        }
        let sparse = PersistedChainState(
            schemaVersion: complete.schemaVersion,
            revision: complete.revision,
            inheritedWorkRevision: complete.inheritedWorkRevision,
            inheritedWorkSnapshot: complete.inheritedWorkSnapshot,
            chainTip: complete.chainTip,
            mainChainHashes: complete.mainChainHashes,
            blocks: sparseBlocks
        )
        let batch = try testAdmissionBatch(
            block: child,
            contribution: contribution
        )

        let restored = try await ChainState.restore(
            from: sparse,
            replaying: [batch]
        )

        let hydrated = await restored.persist()
        XCTAssertEqual(hydrated, complete)
        let duplicate = try await restored.replay(batch)
        XCTAssertNil(duplicate)

        let conflictingBlocks = sparseBlocks.map { block in
            guard block.blockHash == childHeader.rawCID else { return block }
            return PersistedBlockMeta(
                blockHash: block.blockHash,
                parentBlockHash: block.parentBlockHash,
                blockHeight: block.blockHeight,
                childHashes: block.childHashes,
                workContributions: block.workContributions,
                timestamp: child.timestamp + 1
            )
        }
        let conflicting = PersistedChainState(
            schemaVersion: sparse.schemaVersion,
            revision: sparse.revision,
            inheritedWorkRevision: sparse.inheritedWorkRevision,
            inheritedWorkSnapshot: sparse.inheritedWorkSnapshot,
            chainTip: sparse.chainTip,
            mainChainHashes: sparse.mainChainHashes,
            blocks: conflictingBlocks
        )
        let conflictingRestore = try ChainState.restore(from: conflicting)
        let beforeConflict = await conflictingRestore.persist()
        do {
            _ = try await conflictingRestore.replay(batch)
            XCTFail("durable replay must not overwrite conflicting metadata")
        } catch let error as ChainStateRestoreError {
            XCTAssertEqual(error, .corruptConsensusGraph)
        }
        let afterConflict = await conflictingRestore.persist()
        XCTAssertEqual(afterConflict, beforeConflict)

        let partialBlocks = sparseBlocks.map { block in
            guard block.blockHash == childHeader.rawCID else { return block }
            return PersistedBlockMeta(
                blockHash: block.blockHash,
                parentBlockHash: block.parentBlockHash,
                blockHeight: block.blockHeight,
                childHashes: block.childHashes,
                workContributions: block.workContributions,
                target: target.toHexString(),
                timestamp: block.timestamp
            )
        }
        let partial = PersistedChainState(
            schemaVersion: sparse.schemaVersion,
            revision: sparse.revision,
            inheritedWorkRevision: sparse.inheritedWorkRevision,
            inheritedWorkSnapshot: sparse.inheritedWorkSnapshot,
            chainTip: sparse.chainTip,
            mainChainHashes: sparse.mainChainHashes,
            blocks: partialBlocks
        )
        XCTAssertThrowsError(try ChainState.restore(from: partial)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreAllowsOneGrindToCoverMultipleBlocksWithoutDoubleCounting() async throws {
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
            cumulativeWork: UInt256(1)
        )

        let restored = try ChainState.restore(
            from: persistedState(tip: childHash, main: [rootHash, childHash], blocks: [root, child])
        )
        let cumulative = await restored.getCumulativeWork(forHash: childHash)
        XCTAssertEqual(cumulative, WorkSum(UInt256(1)))
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
