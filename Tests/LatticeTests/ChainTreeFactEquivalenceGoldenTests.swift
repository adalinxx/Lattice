import Foundation
import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
@testable import LatticeSimulation
import UInt256
import cashew

/// The value API emits the actor path's fact bytes. Over the block topologies
/// of the Lattice simulation corpus (`LatticeConsensusSimulator`), realized as
/// real blocks, every block is admitted twice from the same content: through
/// `ChainLevel` with `.header` then `.execution`, and through a `ChainTree`
/// with `insertHeader` then `connect`/`applyConnect`. Each step's staged
/// batch must be byte-identical — including "no batch" — and the two chains
/// must end in the same selection and executed set. The bytes are pinned in
/// `Goldens/chain-tree-fact-equivalence.json`.
///
/// Headers are delivered headers-first — each after its parent, in the
/// corpus's release order otherwise — since `insertHeader` reads the parent
/// from the tree while `.header` may resolve it as content.
final class ChainTreeFactEquivalenceGoldenTests: XCTestCase {
    static let goldenName = "chain-tree-fact-equivalence.json"

    struct Golden: Codable, Equatable {
        struct Step: Codable, Equatable {
            let name: String
            /// Hex of the staged batch's canonical JSON; nil when none.
            let facts: String?
        }

        let steps: [Step]

        static func diff(expected: Golden, actual: Golden) -> [String] {
            var lines: [String] = []
            if expected.steps.map(\.name) != actual.steps.map(\.name) {
                lines.append("step names: expected \(expected.steps.map(\.name)), actual \(actual.steps.map(\.name))")
            }
            for (left, right) in zip(expected.steps, actual.steps) where left != right {
                lines.append("\(left.name): expected \(left.facts ?? "none"), actual \(right.facts ?? "none")")
            }
            return lines
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func hex(_ batch: BlockImportBatch?) throws -> String? {
        try batch.map { try encoder().encode($0).map { String(format: "%02x", $0) }.joined() }
    }

    /// One admission step on both paths.
    private final class Pair {
        let level: ChainLevel
        var tree: ChainTree
        let fetcher: StorableFetcher
        let context: ChainRuntimeContext
        let recorder = AdmissionStageRecorder()
        var steps: [Golden.Step] = []

        init(level: ChainLevel, tree: ChainTree, fetcher: StorableFetcher) {
            self.level = level
            self.tree = tree
            self.fetcher = fetcher
            self.context = level.context
        }

        func stagedSince(_ count: Int) async -> BlockImportBatch? {
            let batches = await recorder.recordedBatches()
            XCTAssertLessThanOrEqual(batches.count, count + 1, "one admission stages at most one batch")
            return batches.count > count ? batches.last : nil
        }

        func record(
            _ name: String,
            old: BlockImportBatch?,
            new: BlockImportBatch?,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let oldHex = try hex(old)
            XCTAssertEqual(oldHex, try hex(new), "\(name): value API facts differ from the actor path", file: file, line: line)
            steps.append(Golden.Step(name: name, facts: oldHex))
        }

        func header(_ name: String, _ block: Block, package: ChildValidationPackage? = nil, work: VerifiedWorkContribution? = nil) async throws {
            let before = await recorder.recordedBatches().count
            let recorder = self.recorder
            _ = try await level.admit(
                block, mode: .header, fetcher: fetcher, childPackage: package,
                stage: { await recorder.stage($0) }
            )
            let old = await stagedSince(before)
            let new = try await TreeDriver.insert(block, into: &tree, fetcher: fetcher, work: work)
            try record("\(name)/header", old: old, new: new.update?.facts)
        }

        func execute(_ name: String, _ block: Block, package: ChildValidationPackage? = nil, parentFacts: (any ParentChainFacts)? = nil) async throws {
            let before = await recorder.recordedBatches().count
            let recorder = self.recorder
            _ = try await level.admit(
                block, mode: .execution, fetcher: fetcher, childPackage: package,
                stage: { await recorder.stage($0) }
            )
            let old = await stagedSince(before)
            let new = try await TreeDriver.connect(
                try BlockHeader(node: block).rawCID, on: &tree, context: context,
                fetcher: fetcher, parentFacts: parentFacts
            )
            try record("\(name)/execution", old: old, new: new.update?.facts)
        }

        func assertSameEnd(_ hashes: [String], file: StaticString = #filePath, line: UInt = #line) async {
            let tip = await level.chain.canonicalTip
            XCTAssertEqual(tree.canonicalTip, tip, "same selection", file: file, line: line)
            for hash in hashes {
                let executed = await level.chain.hasExecutedAncestry(blockHash: hash)
                XCTAssertEqual(tree.hasExecutedAncestry(blockHash: hash), executed, "same executed set at \(hash)", file: file, line: line)
            }
        }
    }

    /// The simulation corpus's discrete-event topologies: every scenario that
    /// releases blocks, with its release order read from the simulator's own
    /// trace.
    private func corpus() async -> [(scenario: String, blocks: [(String, String)], initial: [String], releases: [String])] {
        let traces = await LatticeConsensusSimulator.runDefaultScenarios()
        func releases(_ scenario: String) -> [String] {
            let trace = traces.first { $0.scenario == scenario }
            return (trace?.events ?? []).compactMap { $0.label.split(separator: " ").last.map(String.init) }
        }
        return [
            (
                "equal-work-tie-stable-base",
                [("M1", "G"), ("F1", "G")],
                ["M1"],
                ["F1"]
            ),
            (
                "seeded-withhold-release",
                [("M1", "G"), ("M2", "M1"), ("F1", "G"), ("F2", "F1"), ("F3", "F2")],
                ["M1", "M2"],
                releases("seeded-withhold-release")
            ),
        ]
    }

    func testInsertHeaderAndConnectEmitTheActorPathFactBytes() async throws {
        var steps: [Golden.Step] = []
        for entry in await corpus() {
            XCTAssertFalse(entry.releases.isEmpty, "\(entry.scenario) releases blocks")
            let fetcher = StorableFetcher()
            let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
            var blocks: [String: Block] = ["G": genesis]
            for (index, (name, parent)) in entry.blocks.enumerated() {
                let previous = try XCTUnwrap(blocks[parent])
                blocks[name] = try await AdmissionFixture.makeChild(
                    of: previous, fetcher: fetcher,
                    timestamp: 1_000 * Int64(previous.height + 2) + Int64(index),
                    nonce: UInt64(index + 1)
                )
            }
            // A proven-invalid sibling of the first main block's child: it
            // weighs, and its execution emits an exclusion on both paths.
            let invalidValid = try await AdmissionFixture.makeChild(
                of: try XCTUnwrap(blocks["M1"]), fetcher: fetcher, timestamp: 5_500, nonce: 99
            )
            blocks["X"] = try await TreeDriver.forgedPostState(of: invalidValid, seed: entry.scenario, fetcher: fetcher)

            let pair = Pair(
                level: AdmissionFixture.makeLevel(genesis: genesis),
                tree: ChainTree.fromGenesis(block: genesis),
                fetcher: fetcher
            )
            // Headers-first: each header after its parent.
            var held: Set<String> = ["G"]
            var queue = entry.initial + entry.releases + ["X"]
            let parentOf = Dictionary(uniqueKeysWithValues: entry.blocks + [("X", "M1")])
            while !queue.isEmpty {
                let index = try XCTUnwrap(queue.firstIndex { held.contains(parentOf[$0] ?? "") })
                let name = queue.remove(at: index)
                try await pair.header("\(entry.scenario)/\(name)", try XCTUnwrap(blocks[name]))
                held.insert(name)
            }
            // A re-offered header is a duplicate on both paths: no facts.
            try await pair.header("\(entry.scenario)/M1-again", try XCTUnwrap(blocks["M1"]))
            // Execution in height order, then the root genesis, whose
            // exclusion the root-exclusion rule refuses on both paths.
            let byHeight = blocks.filter { $0.key != "G" }.sorted {
                ($0.value.height, $0.key) < ($1.value.height, $1.key)
            }
            for (name, block) in byHeight {
                try await pair.execute("\(entry.scenario)/\(name)", block)
            }
            try await pair.execute("\(entry.scenario)/G", genesis)
            await pair.assertSameEnd(try blocks.values.map { try BlockHeader(node: $0).rawCID })
            steps += pair.steps
        }

        // A child chain: work from a verified child proof, execution against
        // the parent's facts (package on the actor path, the parent tree on
        // the value path).
        let fixture = try await AdmissionFixture.makeChildProofFixture()
        let evidence = await fixture.package.proof.verifySecuringWork(
            child: fixture.candidate, chainPath: fixture.childLevel.context.path
        )
        let childWork = try XCTUnwrap(try evidence.get().contribution)
        let childGenesis = await fixture.childLevel.chain.tree
        let parentGenesis = try await AdmissionFixture.makeGenesis(fetcher: fixture.fetcher, timestamp: 1_000)
        let child = Pair(level: fixture.childLevel, tree: childGenesis, fetcher: fixture.fetcher)
        try await child.header("child/C1", fixture.candidate, package: fixture.package, work: childWork)
        try await child.execute(
            "child/C1", fixture.candidate, package: fixture.package,
            parentFacts: ParentLevelFacts(tree: ChainTree.fromGenesis(block: parentGenesis))
        )
        await child.assertSameEnd([try BlockHeader(node: fixture.candidate).rawCID])
        steps += child.steps

        XCTAssertTrue(steps.contains { $0.facts == nil }, "the corpus covers a no-fact step")
        try GoldenFile.assert(
            Golden(steps: steps),
            matches: Self.goldenName,
            diff: Golden.diff
        )
    }
}
