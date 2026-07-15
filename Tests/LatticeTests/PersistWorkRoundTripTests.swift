import Foundation
import XCTest
@testable import Lattice
import UInt256

private func persistedContribution(
    _ id: String,
    work: UInt256
) -> VerifiedWorkContribution {
    VerifiedWorkContribution(id: id, work: work)
}

private func persistedMeta(
    hash: String,
    parent: String? = nil,
    height: UInt64,
    children: [String] = [],
    contributions: [VerifiedWorkContribution],
    cumulativeWork: UInt256,
    subtreeWeight: UInt256? = nil
) -> PersistedBlockMeta {
    PersistedBlockMeta(
        blockHash: hash,
        parentBlockHash: parent,
        blockHeight: height,
        childHashes: children,
        workContributions: contributions,
        cumulativeWork: cumulativeWork.toHexString(),
        subtreeWeight: subtreeWeight?.toHexString()
    )
}

private func persistedState(
    tip: String,
    main: [String],
    blocks: [PersistedBlockMeta],
    pruned: [PersistedBlockMeta] = []
) -> PersistedChainState {
    PersistedChainState(
        chainTip: tip,
        mainChainHashes: main,
        blocks: blocks,
        prunedBlocks: pruned
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
        for work in adversarialWorks {
            let blocks = [
                makeBlockMeta(
                    hash: "G",
                    height: 0,
                    childHashes: ["A"],
                    work: UInt256(1),
                    cumulativeWork: UInt256(1)
                ),
                makeBlockMeta(
                    hash: "A",
                    previousHash: "G",
                    height: 1,
                    childHashes: ["B"],
                    work: work,
                    cumulativeWork: saturatingWorkSum(UInt256(1), work)
                ),
                makeBlockMeta(
                    hash: "B",
                    previousHash: "A",
                    height: 2,
                    work: work,
                    cumulativeWork: saturatingWorkSum(saturatingWorkSum(UInt256(1), work), work)
                ),
            ]
            let oracle = makeChain(blocks: blocks, mainChainHashes: ["G", "A", "B"])
            let restored = try ChainState.restore(
                from: await makeChain(blocks: blocks, mainChainHashes: ["G", "A", "B"]).persist()
            )

            let oracleRoot = await oracle.subtreeWeight(forHash: "G")
            let restoredRoot = await restored.subtreeWeight(forHash: "G")
            let oracleLeaf = await oracle.subtreeWeight(forHash: "B")
            let restoredLeaf = await restored.subtreeWeight(forHash: "B")
            XCTAssertEqual(restoredRoot, oracleRoot)
            XCTAssertEqual(restoredLeaf, oracleLeaf)
        }
    }

    func testPersistedRecordCarriesVerifiedContributionInsteadOfReconstructedTargetWork() async throws {
        let work = UInt256.max / UInt256(3) + UInt256(1)
        XCTAssertNotEqual(workForTarget(UInt256.max / work), work)
        let chain = makeChain(
            blocks: [
                makeBlockMeta(
                    hash: "G",
                    height: 0,
                    childHashes: ["A"],
                    work: UInt256(1),
                    cumulativeWork: UInt256(1)
                ),
                makeBlockMeta(
                    hash: "A",
                    previousHash: "G",
                    height: 1,
                    work: work,
                    cumulativeWork: saturatingWorkSum(UInt256(1), work)
                ),
            ],
            mainChainHashes: ["G", "A"]
        )
        let bytes = try JSONEncoder().encode(await chain.persist())
        let decoded = try JSONDecoder().decode(PersistedChainState.self, from: bytes)
        let block = try XCTUnwrap(decoded.blocks.first { $0.blockHash == "A" })

        XCTAssertEqual(block.workContributions.count, 1)
        XCTAssertEqual(block.workContributions.first?.work, work)
    }

    func testRestoreRejectsMissingOrZeroContribution() {
        let missing = persistedMeta(
            hash: "G",
            height: 0,
            contributions: [],
            cumulativeWork: UInt256(1)
        )
        let zero = persistedMeta(
            hash: "G",
            height: 0,
            contributions: [persistedContribution("grind:G", work: .zero)],
            cumulativeWork: UInt256(1)
        )

        for block in [missing, zero] {
            XCTAssertThrowsError(
                try ChainState.restore(from: persistedState(tip: "G", main: ["G"], blocks: [block]))
            ) { error in
                XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
            }
        }
    }

    func testRestoreRejectsDuplicateContributionWithinBlock() {
        let contribution = persistedContribution("same-grind", work: UInt256(1))
        let block = persistedMeta(
            hash: "G",
            height: 0,
            contributions: [contribution, contribution],
            cumulativeWork: UInt256(1)
        )

        XCTAssertThrowsError(
            try ChainState.restore(from: persistedState(tip: "G", main: ["G"], blocks: [block]))
        ) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreRejectsDuplicateChildEdges() {
        let root = persistedMeta(
            hash: "G",
            height: 0,
            children: ["A", "A"],
            contributions: [persistedContribution("grind:G", work: UInt256(1))],
            cumulativeWork: UInt256(1)
        )
        let child = persistedMeta(
            hash: "A",
            parent: "G",
            height: 1,
            contributions: [persistedContribution("grind:A", work: UInt256(1))],
            cumulativeWork: UInt256(2)
        )

        XCTAssertThrowsError(
            try ChainState.restore(
                from: persistedState(tip: "A", main: ["G", "A"], blocks: [root, child])
            )
        ) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreRejectsFullyRetainedStaleForkChoice() {
        let snapshot = staleForkChoiceSnapshot(pruneWinningTip: false)

        XCTAssertThrowsError(try ChainState.restore(from: snapshot)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreRejectsStaleForkChoiceWhenWinningBodyIsPruned() {
        let snapshot = staleForkChoiceSnapshot(pruneWinningTip: true)

        XCTAssertThrowsError(try ChainState.restore(from: snapshot)) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreRejectsFullyRetainedHeavierCompetingRoot() {
        let canonical = persistedMeta(
            hash: "G",
            height: 0,
            contributions: [persistedContribution("grind:G", work: UInt256(1))],
            cumulativeWork: UInt256(1)
        )
        let competing = persistedMeta(
            hash: "R",
            height: 0,
            contributions: [persistedContribution("grind:R", work: UInt256(2))],
            cumulativeWork: UInt256(2)
        )

        XCTAssertThrowsError(
            try ChainState.restore(
                from: persistedState(tip: "G", main: ["G"], blocks: [canonical, competing])
            )
        ) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreRejectsContributionReplayedAcrossBlocks() {
        let repeated = persistedContribution("same-grind", work: UInt256(1))
        let root = persistedMeta(
            hash: "G",
            height: 0,
            children: ["A"],
            contributions: [repeated],
            cumulativeWork: UInt256(1)
        )
        let child = persistedMeta(
            hash: "A",
            parent: "G",
            height: 1,
            contributions: [repeated],
            cumulativeWork: UInt256(2)
        )

        XCTAssertThrowsError(
            try ChainState.restore(
                from: persistedState(tip: "A", main: ["G", "A"], blocks: [root, child])
            )
        ) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testRestoreRejectsPrunedEntryWithoutContribution() {
        let root = persistedMeta(
            hash: "G",
            height: 0,
            children: ["P"],
            contributions: [persistedContribution("grind:G", work: UInt256(1))],
            cumulativeWork: UInt256(1)
        )
        let pruned = persistedMeta(
            hash: "P",
            parent: "G",
            height: 1,
            contributions: [],
            cumulativeWork: UInt256(2),
            subtreeWeight: UInt256(1)
        )

        XCTAssertThrowsError(
            try ChainState.restore(
                from: persistedState(tip: "G", main: ["G"], blocks: [root], pruned: [pruned])
            )
        ) { error in
            XCTAssertEqual(error as? ChainStateRestoreError, .corruptConsensusGraph)
        }
    }

    func testDecodeRejectsMissingPrunedBlocksKey() async throws {
        let chain = makeChain(
            blocks: [makeBlockMeta(hash: "G", height: 0, work: UInt256(1), cumulativeWork: UInt256(1))],
            mainChainHashes: ["G"]
        )
        let encoded = try JSONEncoder().encode(await chain.persist())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "prunedBlocks"))
        let stripped = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try JSONDecoder().decode(PersistedChainState.self, from: stripped))
    }

    private func staleForkChoiceSnapshot(pruneWinningTip: Bool) -> PersistedChainState {
        let root = persistedMeta(
            hash: "G",
            height: 0,
            children: ["M", "F1"],
            contributions: [persistedContribution("grind:G", work: UInt256(1))],
            cumulativeWork: UInt256(1)
        )
        let incumbent = persistedMeta(
            hash: "M",
            parent: "G",
            height: 1,
            contributions: [persistedContribution("grind:M", work: UInt256(2))],
            cumulativeWork: UInt256(3)
        )
        let fork = persistedMeta(
            hash: "F1",
            parent: "G",
            height: 1,
            children: ["F2"],
            contributions: [persistedContribution("grind:F1", work: UInt256(1))],
            cumulativeWork: UInt256(2)
        )
        let winningTip = persistedMeta(
            hash: "F2",
            parent: "F1",
            height: 2,
            contributions: [persistedContribution("grind:F2", work: UInt256(2))],
            cumulativeWork: UInt256(4),
            subtreeWeight: UInt256(2)
        )
        return persistedState(
            tip: "M",
            main: ["G", "M"],
            blocks: pruneWinningTip ? [root, incumbent, fork] : [root, incumbent, fork, winningTip],
            pruned: pruneWinningTip ? [winningTip] : []
        )
    }
}
