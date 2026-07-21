import XCTest
import UInt256
@testable import Lattice

struct InheritedWorkOracleFact: Sendable {
    let block: String
    let grind: String
    let work: UInt64
}

struct InheritedWorkOracleInput: Sendable {
    let revision: UInt64
    let facts: [InheritedWorkOracleFact]

    var snapshot: InheritedWorkSnapshot {
        var contributionsByBlock: [String: [VerifiedWorkContribution]] = [:]
        for fact in facts {
            contributionsByBlock[fact.block, default: []].append(
                VerifiedWorkContribution(id: fact.grind, work: UInt256(fact.work))
            )
        }
        return InheritedWorkSnapshot(
            revision: revision,
            workByBlock: contributionsByBlock.mapValues { WorkMeasure($0) }
        )
    }
}

struct InheritedWorkOracle {
    private(set) var revision: UInt64 = 0
    private(set) var coverage: [String: Set<String>] = [:]
    private(set) var strongest: [String: UInt64] = [:]

    init(_ inputs: [InheritedWorkOracleInput] = []) {
        for input in inputs { observe(input) }
    }

    mutating func observe(_ input: InheritedWorkOracleInput) {
        revision = max(revision, input.revision)
        for fact in input.facts {
            coverage[fact.block, default: []].insert(fact.grind)
            strongest[fact.grind] = max(strongest[fact.grind] ?? 0, fact.work)
        }
    }

    func measure(for block: String) -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: (coverage[block] ?? []).map {
            ($0, strongest[$0]!)
        })
    }
}

struct InheritedWorkOracleBlock {
    let hash: String
    let parent: String?
    let children: [String]
    let localFacts: [InheritedWorkOracleFact]
}

struct InheritedWorkOracleProjection {
    let tip: String
    let path: Set<String>
    let subtreeMeasures: [String: [String: UInt64]]
}

func inheritedWorkOracleProjection(
    blocks: [InheritedWorkOracleBlock],
    inherited: InheritedWorkOracle
) -> InheritedWorkOracleProjection {
    let blocksByHash = Dictionary(uniqueKeysWithValues: blocks.map { ($0.hash, $0) })
    var strongest = inherited.strongest
    var directCoverage = inherited.coverage
    for block in blocks {
        for fact in block.localFacts {
            directCoverage[block.hash, default: []].insert(fact.grind)
            strongest[fact.grind] = max(strongest[fact.grind] ?? 0, fact.work)
        }
    }

    var subtreeCoverage: [String: Set<String>] = [:]
    func coveredGrinds(_ hash: String) -> Set<String> {
        if let cached = subtreeCoverage[hash] { return cached }
        var covered = directCoverage[hash] ?? []
        for child in blocksByHash[hash]?.children ?? [] {
            covered.formUnion(coveredGrinds(child))
        }
        subtreeCoverage[hash] = covered
        return covered
    }

    for block in blocks { _ = coveredGrinds(block.hash) }
    let measures = subtreeCoverage.mapValues { covered in
        Dictionary(uniqueKeysWithValues: covered.map { ($0, strongest[$0]!) })
    }
    func weight(_ hash: String) -> UInt64 {
        measures[hash, default: [:]].values.reduce(0, +)
    }
    func preferred(_ candidates: [String]) -> String {
        precondition(!candidates.isEmpty)
        return candidates.dropFirst().reduce(candidates[0]) { selected, candidate in
            precondition(weight(candidate) != weight(selected), "oracle fixture has a tie")
            return weight(candidate) > weight(selected) ? candidate : selected
        }
    }

    let roots = blocks.filter { $0.parent == nil }.map(\.hash)
    var current = preferred(roots)
    var path: Set<String> = [current]
    while let children = blocksByHash[current]?.children, !children.isEmpty {
        current = preferred(children)
        precondition(path.insert(current).inserted)
    }
    return InheritedWorkOracleProjection(
        tip: current,
        path: path,
        subtreeMeasures: measures
    )
}

func assertInheritedWorkMeasure(
    _ actual: WorkMeasure,
    equals expected: [String: UInt64],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.grindIDs, Set(expected.keys), file: file, line: line)
    for (grind, work) in expected {
        XCTAssertEqual(
            actual.work(forGrind: grind),
            UInt256(work),
            file: file,
            line: line
        )
    }
    XCTAssertEqual(
        actual.total,
        WorkSum(UInt256(expected.values.reduce(0, +))),
        file: file,
        line: line
    )
}

private func permutations<T>(_ values: [T]) -> [[T]] {
    guard !values.isEmpty else { return [[]] }
    return values.indices.flatMap { index -> [[T]] in
        var remainder = values
        let first = remainder.remove(at: index)
        return permutations(remainder).map { [first] + $0 }
    }
}

final class InheritedWorkAlgebraTests: XCTestCase {
    func testSnapshotPreservesSourceFactsAcrossCodableUnionAndRestriction() throws {
        let left = testCID("recovered-facts:left")
        let right = testCID("recovered-facts:right")
        let shared = testCID("recovered-facts:shared")
        let weak = try XCTUnwrap(InheritedWorkFact(
            blockCID: left,
            grindID: shared,
            work: UInt256(2)
        ))
        let strong = try XCTUnwrap(InheritedWorkFact(
            blockCID: right,
            grindID: shared,
            work: UInt256(7)
        ))

        let snapshot = InheritedWorkSnapshot(revision: 9, facts: [weak, strong])
        let decoded = try JSONDecoder().decode(
            InheritedWorkSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        let leftOnly = snapshot.restricted(to: [left])
        let rejoined = leftOnly.union(snapshot.restricted(to: [right]))
        let additions = snapshot.additions(since: InheritedWorkSnapshot(
            revision: 8,
            facts: [strong]
        ))

        XCTAssertNil(InheritedWorkFact(
            blockCID: left,
            grindID: shared,
            work: .zero
        ))
        XCTAssertEqual(snapshot.revision, 9)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(
            snapshot.sourceWork(forBlock: left).work(forGrind: shared),
            UInt256(2)
        )
        XCTAssertEqual(snapshot.work(forBlock: left).work(forGrind: shared), UInt256(7))
        XCTAssertEqual(snapshot.work(forBlock: right).work(forGrind: shared), UInt256(7))
        XCTAssertEqual(leftOnly.sourceWork(forBlock: left).work(forGrind: shared), UInt256(2))
        XCTAssertEqual(leftOnly.work(forBlock: left).work(forGrind: shared), UInt256(2))
        XCTAssertEqual(rejoined, snapshot)
        XCTAssertEqual(additions.sourceWork(forBlock: left).work(forGrind: shared), UInt256(2))
    }

    func testWorkMeasureUnionIsAssociativeCommutativeAndIdempotent() {
        let block = testCID("algebra:block")
        let first = InheritedWorkOracleInput(
            revision: 0,
            facts: [
                .init(block: block, grind: testCID("algebra:g1"), work: 2),
                .init(block: block, grind: testCID("algebra:g2"), work: 5),
            ]
        )
        let second = InheritedWorkOracleInput(
            revision: 0,
            facts: [
                .init(block: block, grind: testCID("algebra:g1"), work: 7),
                .init(block: block, grind: testCID("algebra:g3"), work: 1),
            ]
        )
        let third = InheritedWorkOracleInput(
            revision: 0,
            facts: [
                .init(block: block, grind: testCID("algebra:g2"), work: 3),
                .init(block: block, grind: testCID("algebra:g4"), work: 4),
            ]
        )
        let a = first.snapshot.work(forBlock: block)
        let b = second.snapshot.work(forBlock: block)
        let c = third.snapshot.work(forBlock: block)
        let expected = InheritedWorkOracle([first, second, third]).measure(for: block)

        XCTAssertEqual(a.union(a), a)
        XCTAssertEqual(a.union(b), b.union(a))
        XCTAssertEqual(a.union(b).union(c), a.union(b.union(c)))
        assertInheritedWorkMeasure(a.union(b).union(c), equals: expected)
    }

    func testSnapshotUnionIsAJoinAndRevisionIsOnlyAWatermark() {
        let left = testCID("snapshot:left")
        let right = testCID("snapshot:right")
        let shared = testCID("snapshot:shared-grind")
        let first = InheritedWorkOracleInput(
            revision: 5,
            facts: [
                .init(block: left, grind: shared, work: 2),
                .init(block: left, grind: testCID("snapshot:left-base"), work: 1),
            ]
        )
        let older = InheritedWorkOracleInput(
            revision: 4,
            facts: [.init(block: right, grind: shared, work: 9)]
        )
        let equal = InheritedWorkOracleInput(
            revision: 5,
            facts: [.init(block: left, grind: testCID("snapshot:equal-addition"), work: 4)]
        )
        let a = first.snapshot
        let b = older.snapshot
        let c = equal.snapshot
        let olderJoin = a.union(b)
        let completeJoin = olderJoin.union(c)
        let expected = InheritedWorkOracle([first, older, equal])

        XCTAssertEqual(a.union(a), a)
        XCTAssertEqual(a.union(b), b.union(a))
        XCTAssertEqual(a.union(b).union(c), a.union(b.union(c)))
        XCTAssertEqual(olderJoin.revision, 5)
        XCTAssertEqual(completeJoin.revision, 5)
        assertInheritedWorkMeasure(olderJoin.work(forBlock: right), equals: [shared: 9])
        assertInheritedWorkMeasure(completeJoin.work(forBlock: left), equals: expected.measure(for: left))
        assertInheritedWorkMeasure(completeJoin.work(forBlock: right), equals: expected.measure(for: right))
        XCTAssertEqual(completeJoin.work(forBlock: left).work(forGrind: shared), UInt256(9))
    }

    func testSnapshotOperationPermutationsConvergeToOracleGhostProjection() async throws {
        let root = testCID("permutation:root")
        let left = testCID("permutation:left")
        let right = testCID("permutation:right")
        let exported = testCID("permutation:exported-child")
        let shared = testCID("permutation:shared")
        let rootFact = InheritedWorkOracleFact(
            block: root,
            grind: testCID("permutation:root-local"),
            work: 1
        )
        let leftFacts = [
            InheritedWorkOracleFact(block: left, grind: shared, work: 1),
            InheritedWorkOracleFact(block: left, grind: testCID("permutation:left-local"), work: 2),
        ]
        let rightFacts = [
            InheritedWorkOracleFact(block: right, grind: testCID("permutation:right-local"), work: 3),
        ]
        let inputs = [
            InheritedWorkOracleInput(
                revision: 10,
                facts: [.init(block: left, grind: shared, work: 2)]
            ),
            InheritedWorkOracleInput(
                revision: 9,
                facts: [.init(block: right, grind: shared, work: 7)]
            ),
            InheritedWorkOracleInput(
                revision: 10,
                facts: [.init(block: left, grind: testCID("permutation:left-inherited"), work: 5)]
            ),
            InheritedWorkOracleInput(
                revision: 8,
                facts: [.init(block: right, grind: testCID("permutation:right-inherited"), work: 6)]
            ),
        ]
        let inheritedOracle = InheritedWorkOracle(inputs)
        let oracleBlocks = [
            InheritedWorkOracleBlock(hash: root, parent: nil, children: [left, right], localFacts: [rootFact]),
            InheritedWorkOracleBlock(hash: left, parent: root, children: [], localFacts: leftFacts),
            InheritedWorkOracleBlock(hash: right, parent: root, children: [], localFacts: rightFacts),
        ]
        let expected = inheritedWorkOracleProjection(
            blocks: oracleBlocks,
            inherited: inheritedOracle
        )

        for order in permutations(inputs) {
            let joined = order.reduce(InheritedWorkSnapshot.zero) { $0.union($1.snapshot) }
            XCTAssertEqual(joined.revision, inheritedOracle.revision)
            assertInheritedWorkMeasure(joined.work(forBlock: left), equals: inheritedOracle.measure(for: left))
            assertInheritedWorkMeasure(joined.work(forBlock: right), equals: inheritedOracle.measure(for: right))

            let chain = makeChain(
                blocks: [
                    BlockMeta(
                        blockHash: root,
                        parentBlockHash: nil,
                        blockHeight: 0,
                        childHashes: [left, right],
                        workContributions: [
                            VerifiedWorkContribution(id: rootFact.grind, work: UInt256(rootFact.work)),
                        ]
                    ),
                    BlockMeta(
                        blockHash: left,
                        parentBlockHash: root,
                        blockHeight: 1,
                        childHashes: [],
                        workContributions: leftFacts.map {
                            VerifiedWorkContribution(id: $0.grind, work: UInt256($0.work))
                        }
                    ),
                    BlockMeta(
                        blockHash: right,
                        parentBlockHash: root,
                        blockHeight: 1,
                        childHashes: [],
                        workContributions: rightFacts.map {
                            VerifiedWorkContribution(id: $0.grind, work: UInt256($0.work))
                        }
                    ),
                ],
                mainChainHashes: [root, left]
            )
            for input in order {
                let snapshot = input.snapshot
                _ = await chain.setInheritedWorkProvider { snapshot }
            }

            let tip = await chain.getMainChainTip()
            XCTAssertEqual(tip, expected.tip)
            for hash in [root, left, right] {
                let isCanonical = await chain.isOnMainChain(hash: hash)
                XCTAssertEqual(isCanonical, expected.path.contains(hash))
                let forkChoiceValue = await chain.forkChoiceSnapshot(startingAt: hash)
                let forkChoice = try XCTUnwrap(forkChoiceValue)
                XCTAssertEqual(
                    forkChoice.subtreeWork,
                    WorkSum(UInt256(
                        expected.subtreeMeasures[hash]!.values.reduce(UInt64.zero, +)
                    ))
                )
            }
            let export = await chain.inheritedWorkSnapshot(
                forChildCoverage: [exported: [root]]
            )
            let exportedWork = try XCTUnwrap(export).work(forBlock: exported)
            assertInheritedWorkMeasure(
                exportedWork,
                equals: expected.subtreeMeasures[root]!
            )
        }
    }
}
