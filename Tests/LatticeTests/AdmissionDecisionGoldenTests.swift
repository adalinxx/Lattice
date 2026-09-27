import Foundation
import XCTest
import Crypto
import Multikey
import UInt256
import cashew
@testable import Lattice

// MARK: - The observable

/// Everything one `admitBlockHeaderChainLocal` call observably produced, with
/// every content id rendered by fixture name so the file reads as a decision
/// table. The `fixtures` map pins the names to their hashes.
struct AdmissionDecisionGolden: Codable, Equatable {
    struct Fact: Codable, Equatable {
        let kind: String
        let block: String
        let grind: String?
        let work: String?
    }

    struct Staged: Codable, Equatable {
        let facts: [Fact]
        let issuedCarrier: String?
        let issuedRoot: String?
        let parentGenesisLinks: Int
    }

    struct Step: Codable, Equatable {
        let scenario: String
        let mode: String
        let step: Int
        let candidate: String
        /// `accepted`, `carrier`, `duplicate` or `rejected`.
        let result: String
        /// A stable classification of the failure (`kind.subkind`), produced by
        /// an exhaustive switch — never a runtime description of the enum.
        let failure: String?
        /// Chain path named by the failure, when it names one.
        let failurePath: [String]?
        /// Content ids named by the failure, rendered by fixture name.
        let failureCIDs: [String]?
        let predecessorOf: String?
        let predecessor: String?
        let carrier: String?
        let carrierRoot: String?
        let materializedPostState: Bool
        let commitTip: String?
        let commitRevision: UInt64?
        let commitAdded: [String]
        let commitRemoved: [String]
        let staged: [Staged]
        let possessedAfter: Bool
        let executedAfter: Bool
        let excludedAfter: Bool
    }

    let fixtures: [String: String]
    let steps: [Step]

    static func diff(expected: AdmissionDecisionGolden, actual: AdmissionDecisionGolden) -> [String] {
        var lines: [String] = []
        for name in Set(expected.fixtures.keys).union(actual.fixtures.keys).sorted()
        where expected.fixtures[name] != actual.fixtures[name] {
            lines.append("fixture \(name): expected \(expected.fixtures[name] ?? "absent"), actual \(actual.fixtures[name] ?? "absent")")
        }
        func key(_ step: Step) -> String { "\(step.scenario)/\(step.mode)/\(step.step)" }
        let actualSteps = Dictionary(uniqueKeysWithValues: actual.steps.map { (key($0), $0) })
        for step in expected.steps {
            guard let other = actualSteps[key(step)] else {
                lines.append("\(key(step)): missing from actual")
                continue
            }
            lines += GoldenFile.fieldDiff(key(step), [
                ("candidate", step.candidate, other.candidate),
                ("result", step.result, other.result),
                ("failure", step.failure ?? "nil", other.failure ?? "nil"),
                ("failurePath", "\(step.failurePath ?? [])", "\(other.failurePath ?? [])"),
                ("failureCIDs", "\(step.failureCIDs ?? [])", "\(other.failureCIDs ?? [])"),
                ("predecessorOf", step.predecessorOf ?? "nil", other.predecessorOf ?? "nil"),
                ("predecessor", step.predecessor ?? "nil", other.predecessor ?? "nil"),
                ("carrier", step.carrier ?? "nil", other.carrier ?? "nil"),
                ("carrierRoot", step.carrierRoot ?? "nil", other.carrierRoot ?? "nil"),
                ("materializedPostState", "\(step.materializedPostState)", "\(other.materializedPostState)"),
                ("commitTip", step.commitTip ?? "nil", other.commitTip ?? "nil"),
                ("commitRevision", step.commitRevision.map(String.init) ?? "nil", other.commitRevision.map(String.init) ?? "nil"),
                ("commitAdded", "\(step.commitAdded)", "\(other.commitAdded)"),
                ("commitRemoved", "\(step.commitRemoved)", "\(other.commitRemoved)"),
                ("staged", "\(step.staged)", "\(other.staged)"),
                ("possessedAfter", "\(step.possessedAfter)", "\(other.possessedAfter)"),
                ("executedAfter", "\(step.executedAfter)", "\(other.executedAfter)"),
                ("excludedAfter", "\(step.excludedAfter)", "\(other.excludedAfter)"),
            ])
        }
        for key in Set(actualSteps.keys).subtracting(expected.steps.map(key)).sorted() {
            lines.append("\(key): unexpected in actual")
        }
        return lines
    }
}

// MARK: - Fixtures

private enum AdmissionFixtureError: Error, CustomStringConvertible {
    /// The pinned signature no longer verifies over the fixed transfer body.
    case stalePinnedSignature(fresh: String)
    /// The target-miss fixture's carrier happened to beat the hard target.
    case carrierHitsTheHardTarget

    var description: String {
        switch self {
        case .stalePinnedSignature(let fresh):
            "the transfer body changed; pin the fresh signature "
                + "in AdmissionFixtures.transferSignature: \(fresh)"
        case .carrierHitsTheHardTarget:
            "missCarrier must miss the child's target of 1; change its nonce"
        }
    }
}

/// Blocks built once through `BlockBuilder` with fixed timestamps, nonces, a
/// fixed signing key and a PINNED signature, so every content id is stable
/// across runs and hosts. The signature is pinned rather than recomputed
/// because CryptoKit's Ed25519 signing is randomized (verification is not):
/// a fresh signature per run would move `valid`'s CID and flip the
/// `valid`/`side` CID tie-break.
private struct AdmissionFixtures {
    static let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 1_000,
        targetBlockTime: 1_000,
        initialReward: 1_024,
        halvingInterval: 10_000,
        halfLife: 5
    )
    static let easy = UInt256.max
    static let childDirectory = "Child"

    /// Any 32 bytes are a valid Ed25519 seed, so no host RNG is involved.
    static let signerSeed = Data(repeating: 0x41, count: 32)
    static let recipientSeed = Data(repeating: 0x42, count: 32)
    /// Signature of `signerSeed`'s key over the fixed transfer body. `build()`
    /// fails with the replacement value if the body ever changes.
    static let transferSignature = "100b23f8087d38114e8cf1ac895a8835988d5acc7d908b3260f9ecb19119f7ff5d8740069e145189737ed5429203186c4a5ed061a2fa0c808064a9bc5e3a9802"

    let fetcher = StorableFetcher()
    /// Block boundaries and the spec only — what a node holds after weighing —
    /// so a validate-tier execution finds no body to run.
    let bodyless = StorableFetcher()
    private(set) var names: [String: String] = [:]
    private(set) var blocks: [String: Block] = [:]
    private(set) var packages: [String: ChildValidationPackage] = [:]

    static func fixedKey(_ seed: Data) throws -> (privateKey: String, publicKey: String, address: String) {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let publicKey = Multikey(keyType: .ed25519, keyBytes: key.publicKey.rawRepresentation).hexEncoded
        return (seed.hexString, publicKey, testAddress(publicKey: publicKey))
    }

    private mutating func register(_ name: String, _ block: Block) throws -> Block {
        names[try BlockHeader(node: block).rawCID] = name
        blocks[name] = block
        return block
    }

    private mutating func variant(
        _ name: String,
        of valid: Block,
        height: UInt64? = nil,
        nextTarget: UInt256? = nil,
        prevState: LatticeStateHeader? = nil,
        postState: LatticeStateHeader? = nil
    ) async throws -> Block {
        try register(name, try await storeBuiltBlock(Block(
            version: valid.version,
            parent: valid.parent,
            transactions: valid.transactions,
            target: valid.target,
            nextTarget: nextTarget ?? valid.nextTarget,
            spec: valid.spec,
            parentState: valid.parentState,
            prevState: prevState ?? valid.prevState,
            postState: postState ?? valid.postState,
            children: valid.children,
            height: height ?? valid.height,
            timestamp: valid.timestamp,
            nonce: valid.nonce
        ), in: fetcher))
    }

    static func build() async throws -> AdmissionFixtures {
        var fixtures = AdmissionFixtures()
        let signer = try fixedKey(signerSeed)
        let recipient = try fixedKey(recipientSeed)
        let genesis = try fixtures.register("genesis", try await buildPremineGenesis(
            spec: spec, owner: (signer.privateKey, signer.publicKey),
            fetcher: fixtures.fetcher, timestamp: 1_000, target: easy
        ))
        // A real state change: a transfer that also mints block 1's reward.
        let body = try HeaderImpl<TransactionBody>(node: TransactionBody(
            accountActions: [
                AccountAction(owner: signer.address, delta: -10),
                AccountAction(owner: recipient.address, delta: 10 + Int64(spec.rewardAtBlock(1))),
            ],
            actions: [], depositActions: [], genesisActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [signer.address], fee: 0, nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        ))
        guard TransactionSigning.verify(
            bodyHeader: body, signature: transferSignature, publicKeyHex: signer.publicKey
        ) else {
            throw AdmissionFixtureError.stalePinnedSignature(
                fresh: TransactionSigning.sign(bodyHeader: body, privateKeyHex: signer.privateKey) ?? "<signing failed>"
            )
        }
        let transfer = Transaction(signatures: [signer.publicKey: transferSignature], body: body)
        let valid = try fixtures.register("valid", try await buildAndStoreBlock(
            previous: genesis, transactions: [transfer],
            timestamp: 2_000, target: easy, nonce: 1, fetcher: fixtures.fetcher
        ))
        _ = try fixtures.register("side", try await buildAndStoreBlock(
            previous: genesis, timestamp: 2_500, target: easy, nonce: 2, fetcher: fixtures.fetcher
        ))
        _ = try fixtures.register("grandchild", try await buildAndStoreBlock(
            previous: valid, timestamp: 3_000, target: easy, nonce: 3, fetcher: fixtures.fetcher
        ))
        _ = try await fixtures.variant("badPrevState", of: valid, prevState: valid.postState)
        _ = try await fixtures.variant("wrongNextTarget", of: valid, nextTarget: valid.nextTarget - UInt256(1))
        _ = try await fixtures.variant("wrongHeight", of: valid, height: valid.height + 1)
        _ = try await fixtures.variant("forgedPostState", of: valid, postState: genesis.postState)

        let hardGenesis = try fixtures.register("hardGenesis", try await buildAndStoreGenesis(
            spec: spec, timestamp: 1_000, target: easy / UInt256(2), nonce: 7, fetcher: fixtures.fetcher
        ))
        _ = try fixtures.register("tooEasy", try await buildAndStoreBlock(
            previous: hardGenesis, timestamp: 2_000, target: easy, nonce: 1, fetcher: fixtures.fetcher
        ))

        // A child chain block co-mined into a carrier on the parent chain.
        let childGenesis = try fixtures.register("childGenesis", try await buildAndStoreGenesis(
            spec: spec, timestamp: 1_000, target: easy, nonce: 1, fetcher: fixtures.fetcher
        ))
        let childCandidate = try fixtures.register("childCandidate", try await buildAndStoreBlock(
            previous: childGenesis, parentChainBlock: genesis,
            timestamp: 2_000, target: easy, nonce: 1, fetcher: fixtures.fetcher
        ))
        let carrier = try fixtures.register("carrier", try await buildAndStoreGenesis(
            spec: spec, children: [childDirectory: childCandidate],
            timestamp: 3_000, target: easy, nonce: 2, fetcher: fixtures.fetcher
        ))
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: childDirectory,
            fetcher: fixtures.fetcher
        )
        fixtures.packages["childCandidate"] = ChildValidationPackage(proof: proof)

        // A child block whose own target the carrier's hash MISSES: the proof
        // still relays work for descendants, but at this level the block is a
        // carrier, never admitted.
        let hardTarget = UInt256(1)
        let hardChildGenesis = try fixtures.register("hardChildGenesis", try await buildAndStoreGenesis(
            spec: spec, timestamp: 1_000, target: hardTarget, nonce: 1, fetcher: fixtures.fetcher
        ))
        let missedChild = try fixtures.register("missedChild", try await buildAndStoreBlock(
            previous: hardChildGenesis, parentChainBlock: genesis,
            timestamp: 2_000, target: hardTarget, nextTarget: easy, nonce: 2, fetcher: fixtures.fetcher
        ))
        let missCarrier = try fixtures.register("missCarrier", try await buildAndStoreGenesis(
            spec: spec, children: [childDirectory: missedChild],
            timestamp: 3_000, target: easy, nonce: 3, fetcher: fixtures.fetcher
        ))
        guard missCarrier.proofOfWorkHash() > hardTarget else {
            throw AdmissionFixtureError.carrierHitsTheHardTarget
        }
        fixtures.packages["missedChild"] = ChildValidationPackage(proof: try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: missCarrier),
            childDirectory: childDirectory,
            fetcher: fixtures.fetcher
        ))

        try await BlockHeader(node: valid).storeBlockBoundary(fetcher: fixtures.fetcher, storer: fixtures.bodyless)
        try await BlockHeader(node: genesis).storeBlockBoundary(fetcher: fixtures.fetcher, storer: fixtures.bodyless)
        fixtures.bodyless.store(
            rawCid: genesis.spec.rawCID,
            data: try await fixtures.fetcher.fetch(rawCid: genesis.spec.rawCID)
        )
        return fixtures
    }

    func name(_ hash: String) -> String { names[hash] ?? hash }

    func hash(named name: String) throws -> String {
        try BlockHeader(node: try XCTUnwrap(blocks[name], "no fixture named \(name)")).rawCID
    }

    func level(genesis: String, path: [String] = [DEFAULT_ROOT_DIRECTORY]) throws -> ChainLevel {
        ChainLevel(
            chain: ChainState.fromGenesis(block: try XCTUnwrap(blocks[genesis], "no fixture named \(genesis)")),
            context: testChainContext(path: path)
        )
    }

    /// The stable classification the golden records for a failure.
    func classify(_ failure: ChainAdmissionFailure) -> (kind: String, path: [String]?, cids: [String]?) {
        switch failure {
        case .unavailableEvidence: return ("unavailableEvidence", nil, nil)
        case .providerMalformedEvidence: return ("providerMalformedEvidence", nil, nil)
        case .protocolInvalid: return ("protocolInvalid", nil, nil)
        case .localVerificationFailure: return ("localVerificationFailure", nil, nil)
        case .notYetAdmissible: return ("notYetAdmissible", nil, nil)
        case .notAcceptedAtCurrentChain: return ("notAcceptedAtCurrentChain", nil, nil)
        case .revisionExhausted: return ("revisionExhausted", nil, nil)
        case .crossChainEvidenceRequired(let requirement):
            switch requirement {
            case .childProof(let chainPath, let childCID):
                return ("crossChainEvidenceRequired.childProof", chainPath, [name(childCID)])
            case .parentGenesis(let parentPath, let directory, let childGenesisCID, let parentStateCID):
                return (
                    "crossChainEvidenceRequired.parentGenesis",
                    parentPath + [directory],
                    [name(childGenesisCID), name(parentStateCID)]
                )
            case .parentStateContinuity(let parentPath, let fromStateCID, let toStateCID):
                return (
                    "crossChainEvidenceRequired.parentStateContinuity",
                    parentPath,
                    [name(fromStateCID), name(toStateCID)]
                )
            }
        }
    }
}

// MARK: - Scenarios

private struct AdmissionScenario {
    struct Step {
        let candidate: String
        var package: Bool = false
        var missing: String? = nil
        /// Resolve against the boundary-only fetcher.
        var bodyless: Bool = false
        /// Overrides the sweep mode for sequence scenarios.
        var mode: AdmissionMode? = nil
    }

    let name: String
    let genesis: String
    var path: [String] = [DEFAULT_ROOT_DIRECTORY]
    let steps: [Step]
    /// Sequence scenarios fix their own modes and run once.
    var sequence: Bool = false

    static let all: [AdmissionScenario] = [
        AdmissionScenario(name: "valid", genesis: "genesis", steps: [Step(candidate: "valid")]),
        AdmissionScenario(name: "duplicate", genesis: "genesis", steps: [Step(candidate: "valid"), Step(candidate: "valid")]),
        AdmissionScenario(name: "sideBlock", genesis: "genesis", steps: [Step(candidate: "valid"), Step(candidate: "side")]),
        AdmissionScenario(name: "unavailableParent", genesis: "genesis", steps: [Step(candidate: "grandchild", missing: "valid")]),
        AdmissionScenario(name: "badPrevState", genesis: "genesis", steps: [Step(candidate: "badPrevState")]),
        AdmissionScenario(name: "wrongNextTarget", genesis: "genesis", steps: [Step(candidate: "wrongNextTarget")]),
        AdmissionScenario(name: "wrongHeight", genesis: "genesis", steps: [Step(candidate: "wrongHeight")]),
        AdmissionScenario(name: "forgedPostState", genesis: "genesis", steps: [Step(candidate: "forgedPostState")]),
        AdmissionScenario(name: "targetEasierThanSchedule", genesis: "hardGenesis", steps: [Step(candidate: "tooEasy")]),
        AdmissionScenario(name: "rivalGenesis", genesis: "genesis", steps: [Step(candidate: "hardGenesis")]),
        AdmissionScenario(
            name: "carriedChild", genesis: "childGenesis",
            path: [DEFAULT_ROOT_DIRECTORY, AdmissionFixtures.childDirectory],
            steps: [Step(candidate: "childCandidate", package: true)]
        ),
        AdmissionScenario(
            name: "carriedChildWithoutProof", genesis: "childGenesis",
            path: [DEFAULT_ROOT_DIRECTORY, AdmissionFixtures.childDirectory],
            steps: [Step(candidate: "childCandidate")]
        ),
        AdmissionScenario(
            name: "targetMissCarrier", genesis: "hardChildGenesis",
            path: [DEFAULT_ROOT_DIRECTORY, AdmissionFixtures.childDirectory],
            steps: [Step(candidate: "missedChild", package: true)]
        ),
        AdmissionScenario(
            name: "weighedThenValidateWithoutBody", genesis: "genesis",
            steps: [
                Step(candidate: "valid", bodyless: true, mode: .weighed),
                Step(candidate: "valid", bodyless: true, mode: .validate),
            ],
            sequence: true
        ),
        AdmissionScenario(
            name: "weighedThenValidate", genesis: "genesis",
            steps: [Step(candidate: "valid", mode: .weighed), Step(candidate: "valid", mode: .validate)],
            sequence: true
        ),
        AdmissionScenario(
            name: "weighedThenValidateForged", genesis: "genesis",
            steps: [Step(candidate: "forgedPostState", mode: .weighed), Step(candidate: "forgedPostState", mode: .validate)],
            sequence: true
        ),
        AdmissionScenario(
            name: "weighedThenExtend", genesis: "genesis",
            steps: [Step(candidate: "valid", mode: .weighed), Step(candidate: "grandchild", mode: .weighed)],
            sequence: true
        ),
    ]
}

private struct MissingCIDFetcher: Fetcher {
    let backing: StorableFetcher
    let missingCID: String

    func fetch(rawCid: String) async throws -> Data {
        if rawCid == missingCID { throw FetcherError.notFound(rawCid) }
        return try await backing.fetch(rawCid: rawCid)
    }
}

private actor StagingRecorder {
    private(set) var contexts: [ChainAdmissionStagingContext] = []

    func record(_ context: ChainAdmissionStagingContext) {
        contexts.append(context)
    }
}

// MARK: - Tests

/// Pins the admission decision table: for every fixture block and every
/// `AdmissionMode`, the result case, failure, predecessor requirement, carrier
/// link, materialization, emitted commit, and the exact staged fact batch.
final class AdmissionDecisionGoldenTests: XCTestCase {
    static let goldenName = "admission-decisions.json"

    private func modeName(_ mode: AdmissionMode) -> String {
        switch mode {
        case .eager: "eager"
        case .weighed: "weighed"
        case .validate: "validate"
        }
    }

    private func run(
        _ scenario: AdmissionScenario,
        sweep: AdmissionMode?,
        fixtures: AdmissionFixtures
    ) async throws -> [AdmissionDecisionGolden.Step] {
        let level = try fixtures.level(genesis: scenario.genesis, path: scenario.path)
        var steps: [AdmissionDecisionGolden.Step] = []
        for (index, step) in scenario.steps.enumerated() {
            let mode = step.mode ?? sweep ?? .eager
            let block = try XCTUnwrap(fixtures.blocks[step.candidate])
            let header = try BlockHeader(node: block)
            let recorder = StagingRecorder()
            let fetcher: any Fetcher
            if let missing = step.missing {
                fetcher = MissingCIDFetcher(
                    backing: fixtures.fetcher, missingCID: try fixtures.hash(named: missing)
                )
            } else if step.bodyless {
                fetcher = fixtures.bodyless
            } else {
                fetcher = fixtures.fetcher
            }
            let result = try await level.admitBlockHeaderChainLocal(
                header,
                fetcher: fetcher,
                childPackage: step.package ? fixtures.packages[step.candidate] : nil,
                validationContentStorer: fixtures.fetcher,
                materializedVolumeStorer: fixtures.fetcher,
                mode: mode,
                stage: { context in await recorder.record(context) }
            )
            let resultName: String
            switch result {
            case .accepted: resultName = "accepted"
            case .carrier: resultName = "carrier"
            case .duplicate: resultName = "duplicate"
            case .rejected: resultName = "rejected"
            }
            let staged = await recorder.contexts.map { context in
                AdmissionDecisionGolden.Staged(
                    facts: context.batch.facts.map { fact in
                        switch fact {
                        case .block(let value):
                            AdmissionDecisionGolden.Fact(kind: "block", block: fixtures.name(value.blockHash), grind: nil, work: nil)
                        case .work(let value):
                            AdmissionDecisionGolden.Fact(
                                kind: value.attributedRun == nil ? "work" : "attributedRun",
                                block: fixtures.name(value.blockHash),
                                grind: fixtures.name(value.contribution.id),
                                work: value.contribution.work.toHexString()
                            )
                        case .exclusion(let value):
                            AdmissionDecisionGolden.Fact(kind: "exclusion", block: fixtures.name(value.blockHash), grind: nil, work: nil)
                        case .validation(let value):
                            AdmissionDecisionGolden.Fact(kind: "validation", block: fixtures.name(value.blockHash), grind: nil, work: nil)
                        }
                    },
                    issuedCarrier: context.issuedCarrierLink.map { fixtures.name($0.carrierCID) },
                    issuedRoot: context.issuedCarrierLink.map { fixtures.name($0.rootCID) },
                    parentGenesisLinks: context.parentGenesisLinks.count
                )
            }
            let possessed = await level.chain.contains(blockHash: header.rawCID)
            let executed = await level.chain.hasExecutedAncestry(blockHash: header.rawCID)
            let excluded = await level.chain.excludedRootsForTesting.contains(header.rawCID)
            let failure = result.failure.map(fixtures.classify)
            steps.append(AdmissionDecisionGolden.Step(
                scenario: scenario.name,
                mode: scenario.sequence ? "sequence" : modeName(mode),
                step: index,
                candidate: step.candidate,
                result: resultName,
                failure: failure?.kind,
                failurePath: failure?.path,
                failureCIDs: failure?.cids,
                predecessorOf: result.sameChainPredecessor.map { fixtures.name($0.descendantCID) },
                predecessor: result.sameChainPredecessor.map { fixtures.name($0.predecessorCID) },
                carrier: result.parentCarrierLink.map { fixtures.name($0.carrierCID) },
                carrierRoot: result.parentCarrierLink.map { fixtures.name($0.rootCID) },
                materializedPostState: result.materializedPostState != nil,
                commitTip: result.commit.map { fixtures.name($0.tipHash) },
                commitRevision: result.commit?.revision,
                commitAdded: result.commit.map { $0.mainChainBlocksAdded.keys.map(fixtures.name).sorted() } ?? [],
                commitRemoved: result.commit.map { $0.mainChainBlocksRemoved.map(fixtures.name).sorted() } ?? [],
                staged: staged,
                possessedAfter: possessed,
                executedAfter: executed,
                excludedAfter: excluded
            ))
        }
        return steps
    }

    func testAdmissionDecisionsMatchGolden() async throws {
        let fixtures = try await AdmissionFixtures.build()
        var steps: [AdmissionDecisionGolden.Step] = []
        for scenario in AdmissionScenario.all {
            if scenario.sequence {
                steps += try await run(scenario, sweep: nil, fixtures: fixtures)
            } else {
                for mode in [AdmissionMode.eager, .weighed, .validate] {
                    steps += try await run(scenario, sweep: mode, fixtures: fixtures)
                }
            }
        }
        let golden = AdmissionDecisionGolden(
            fixtures: Dictionary(uniqueKeysWithValues: fixtures.names.map { ($0.value, $0.key) }),
            steps: steps
        )
        try GoldenFile.assert(golden, matches: Self.goldenName, diff: AdmissionDecisionGolden.diff)
    }
}
