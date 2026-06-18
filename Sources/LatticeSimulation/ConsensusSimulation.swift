import Foundation
import Lattice
import UInt256

public struct ConsensusSimEvent: Codable, Equatable, Sendable {
    public let step: Int
    public let label: String
    public let tip: String
    public let candidate: String?
    public let candidateTip: String?
    public let candidateTrueCumWork: String?
    public let mainTrueCumWork: String?
    public let reorged: Bool?

    public init(
        step: Int,
        label: String,
        tip: String,
        candidate: String? = nil,
        candidateTip: String? = nil,
        candidateTrueCumWork: String? = nil,
        mainTrueCumWork: String? = nil,
        reorged: Bool? = nil
    ) {
        self.step = step
        self.label = label
        self.tip = tip
        self.candidate = candidate
        self.candidateTip = candidateTip
        self.candidateTrueCumWork = candidateTrueCumWork
        self.mainTrueCumWork = mainTrueCumWork
        self.reorged = reorged
    }
}

public struct ConsensusSimTrace: Codable, Equatable, Sendable {
    public let scenario: String
    public let seed: UInt64
    public let finalTip: String
    /// The real main-chain block set after the last release, as resolved by the
    /// REAL `ChainState` fork choice across every released block. Empty for the
    /// hand-checked fixtures that report only a single evaluated candidate; the
    /// discrete-event runner populates it so adversarial scenarios can derive
    /// accepted revenue / convergence from real fork choice rather than a model.
    public let finalMainChain: [String]
    public let events: [ConsensusSimEvent]

    public init(
        scenario: String,
        seed: UInt64,
        finalTip: String,
        finalMainChain: [String] = [],
        events: [ConsensusSimEvent]
    ) {
        self.scenario = scenario
        self.seed = seed
        self.finalTip = finalTip
        self.finalMainChain = finalMainChain
        self.events = events
    }
}

public struct ConsensusSimBlockSpec: Codable, Equatable, Sendable {
    public let hash: String
    public let parent: String?
    public let height: UInt64
    public let work: UInt256

    public init(hash: String, parent: String? = nil, height: UInt64, work: UInt256 = UInt256(1)) {
        self.hash = hash
        self.parent = parent
        self.height = height
        self.work = work
    }
}

public struct ConsensusSimRelease: Codable, Equatable, Sendable {
    public let atMillis: UInt64
    public let blockHash: String

    public init(atMillis: UInt64, blockHash: String) {
        self.atMillis = atMillis
        self.blockHash = blockHash
    }
}

public struct ConsensusSimScenarioSpec: Codable, Equatable, Sendable {
    public let scenario: String
    public let seed: UInt64
    public let blocks: [ConsensusSimBlockSpec]
    public let initiallyVisible: [String]
    public let initialMain: [String]
    public let releases: [ConsensusSimRelease]

    public init(
        scenario: String,
        seed: UInt64,
        blocks: [ConsensusSimBlockSpec],
        initiallyVisible: [String],
        initialMain: [String],
        releases: [ConsensusSimRelease]
    ) {
        self.scenario = scenario
        self.seed = seed
        self.blocks = blocks
        self.initiallyVisible = initiallyVisible
        self.initialMain = initialMain
        self.releases = releases
    }
}

public enum LatticeConsensusSimulator {
    public static let defaultSeed: UInt64 = 0x4c41545449434533

    public static func runDefaultScenarios(seed: UInt64 = defaultSeed) async -> [ConsensusSimTrace] {
        [
            await equalWorkTie(seed: seed),
            await precomputedInheritedWeightReorg(seed: seed),
            await parentReorgChildReride(seed: seed),
            await deterministicWithholdRelease(seed: seed),
            await proportionalRetarget(seed: seed)
        ]
    }

    public static func encodeJSON(_ traces: [ConsensusSimTrace]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(traces)
    }

    public static func runDiscreteEventScenario(_ spec: ConsensusSimScenarioSpec) async -> ConsensusSimTrace {
        let blocksByHash = Dictionary(uniqueKeysWithValues: spec.blocks.map { ($0.hash, $0) })
        let allBlocks = Dictionary(uniqueKeysWithValues: spec.blocks.map {
            ($0.hash, simBlock($0.hash, previous: $0.parent, height: $0.height, work: $0.work))
        })
        var visibleHashes = Set(spec.initiallyVisible)
        var currentMain = Set(spec.initialMain)
        var events: [ConsensusSimEvent] = []

        let releases = spec.releases.sorted {
            if $0.atMillis != $1.atMillis { return $0.atMillis < $1.atMillis }
            return $0.blockHash < $1.blockHash
        }

        for (idx, release) in releases.enumerated() {
            visibleHashes.insert(release.blockHash)
            let visibleBlocks = spec.blocks.compactMap { visibleHashes.contains($0.hash) ? allBlocks[$0.hash] : nil }
            let chain = simChain(blocks: visibleBlocks, main: currentMain)
            let releasedBlock = await chain.getConsensusBlock(hash: release.blockHash)
            let candidateRoot = forkRoot(for: release.blockHash, visible: visibleHashes, currentMain: currentMain, blocksByHash: blocksByHash)
            let reorg: Reorganization?
            if let releasedBlock {
                reorg = await chain.evaluateForkChoice(forReleasedBlock: releasedBlock)
            } else {
                reorg = nil
            }
            if let reorg {
                currentMain.subtract(reorg.mainChainBlocksRemoved)
                currentMain.formUnion(reorg.mainChainBlocksAdded.keys)
            }

            let tip = await chain.getMainChainTip()
            let snapshot = await chain.forkChoiceSnapshot(startingAt: candidateRoot)
            events.append(event(
                idx,
                "t=\(release.atMillis)ms release \(release.blockHash)",
                tip: tip,
                candidate: snapshot,
                main: nil,
                reorged: reorg != nil
            ))
        }

        let finalTip = currentMain
            .compactMap { blocksByHash[$0] }
            .max { $0.height < $1.height }?
            .hash ?? spec.initialMain.last ?? ""
        let finalMainChain = currentMain.sorted {
            let lh = blocksByHash[$0]?.height ?? 0
            let rh = blocksByHash[$1]?.height ?? 0
            if lh != rh { return lh < rh }
            return $0 < $1
        }
        return ConsensusSimTrace(
            scenario: spec.scenario,
            seed: spec.seed,
            finalTip: finalTip,
            finalMainChain: finalMainChain,
            events: events
        )
    }

    private static func equalWorkTie(seed: UInt64) async -> ConsensusSimTrace {
        let g = simBlock("G", height: 0, children: ["M1", "F1"])
        let m1 = simBlock("M1", previous: "G", height: 1)
        let f1 = simBlock("F1", previous: "G", height: 1)
        let chain = simChain(blocks: [g, m1, f1], main: Set(["G", "M1"]))

        let candidate = await chain.forkChoiceSnapshot(startingAt: "F1")
        let main = await chain.forkChoiceSnapshot(startingAt: "M1")
        let f1Block = await chain.getConsensusBlock(hash: "F1")!
        let reorg = await chain.evaluateForkChoice(forReleasedBlock: f1Block)
        let tip = await chain.getMainChainTip()

        return ConsensusSimTrace(
            scenario: "equal-work-tie-incumbent-holds",
            seed: seed,
            finalTip: tip,
            events: [
                event(
                    0, "equal work candidate evaluated", tip: "M1",
                    candidate: candidate, main: main, reorged: reorg != nil
                )
            ]
        )
    }

    private static func precomputedInheritedWeightReorg(seed: UInt64) async -> ConsensusSimTrace {
        let g = simBlock("CG", height: 0, children: ["C1", "C2"])
        let c1 = simBlock("C1", previous: "CG", height: 1)
        let c2 = simBlock("C2", previous: "CG", height: 1)
        let chain = simChain(
            blocks: [g, c1, c2],
            main: Set(["CG", "C1"]),
            inherited: ["C2": UInt256(3)]
        )
        let candidate = await chain.forkChoiceSnapshot(startingAt: "C2")
        let main = await chain.forkChoiceSnapshot(startingAt: "C1")
        let c2Block = await chain.getConsensusBlock(hash: "C2")!
        let reorg = await chain.evaluateForkChoice(forReleasedBlock: c2Block)
        let tip = await chain.getMainChainTip()

        return ConsensusSimTrace(
            scenario: "precomputed-inherited-weight-reorg",
            seed: seed,
            finalTip: tip,
            events: [
                ConsensusSimEvent(
                    step: 0,
                    label: "precomputed inherited=3 beats main=1",
                    tip: tip,
                    candidate: "C2",
                    candidateTip: candidate?.tipHash,
                    candidateTrueCumWork: candidate?.trueCumWork.toHexString(),
                    mainTrueCumWork: main?.trueCumWork.toHexString(),
                    reorged: reorg != nil
                )
            ]
        )
    }

    private static func parentReorgChildReride(seed: UInt64) async -> ConsensusSimTrace {
        let weights = MutableSimWeights(["CA": UInt256(5), "CB": UInt256(20)])
        let g = simBlock("CG", height: 0, children: ["CA", "CB"])
        let ca = simBlock("CA", previous: "CG", height: 1)
        let cb = simBlock("CB", previous: "CG", height: 1)
        let chain = simChain(blocks: [g, ca, cb], main: Set(["CG", "CA"]), provider: { weights[$0] })

        let cbBlock = await chain.getConsensusBlock(hash: "CB")!
        let firstReorg = await chain.evaluateForkChoice(forReleasedBlock: cbBlock)
        let firstTip = await chain.getMainChainTip()

        weights.replace(["CA": UInt256(30), "CB": UInt256(20)])
        let secondReorg = await chain.reevaluateForkChoice(blockHash: "CA")
        let finalTip = await chain.getMainChainTip()

        return ConsensusSimTrace(
            scenario: "parent-reorg-child-reride",
            seed: seed,
            finalTip: finalTip,
            events: [
                ConsensusSimEvent(step: 0, label: "CB rides heavier parent fork", tip: firstTip, candidate: "CB", reorged: firstReorg != nil),
                ConsensusSimEvent(step: 1, label: "parent fork flips; CA rerides", tip: finalTip, candidate: "CA", reorged: secondReorg != nil)
            ]
        )
    }

    private static func deterministicWithholdRelease(seed: UInt64) async -> ConsensusSimTrace {
        let order = seededOrder(seed: seed, values: ["F1", "F2", "F3"])
        let spec = ConsensusSimScenarioSpec(
            scenario: "seeded-withhold-release",
            seed: seed,
            blocks: [
                ConsensusSimBlockSpec(hash: "G", height: 0),
                ConsensusSimBlockSpec(hash: "M1", parent: "G", height: 1),
                ConsensusSimBlockSpec(hash: "M2", parent: "M1", height: 2),
                ConsensusSimBlockSpec(hash: "F1", parent: "G", height: 1),
                ConsensusSimBlockSpec(hash: "F2", parent: "F1", height: 2),
                ConsensusSimBlockSpec(hash: "F3", parent: "F2", height: 3)
            ],
            initiallyVisible: ["G", "M1", "M2"],
            initialMain: ["G", "M1", "M2"],
            releases: order.enumerated().map { idx, hash in
                ConsensusSimRelease(atMillis: UInt64(idx + 1) * 100, blockHash: hash)
            }
        )
        return await runDiscreteEventScenario(spec)
    }

    private static func proportionalRetarget(seed: UInt64) async -> ConsensusSimTrace {
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 1_000_000,
            premine: 0,
            targetBlockTime: 3_600_000,
            initialReward: 1_048_576,
            halvingInterval: 876_600,
            retargetWindow: 120
        )
        let previous = UInt256(1000)
        let onTarget = spec.calculateWindowedTarget(
            previousTarget: previous,
            ancestorTimestamps: [7_200_000, 3_600_000, 0]
        )
        let slow = spec.calculateWindowedTarget(
            previousTarget: previous,
            ancestorTimestamps: [14_400_000, 7_200_000, 0]
        )
        return ConsensusSimTrace(
            scenario: "proportional-retarget-one-hour",
            seed: seed,
            finalTip: "retarget-only",
            events: [
                ConsensusSimEvent(
                    step: 0,
                    label: "target=3600000ms previous=\(previous.toHexString()) onTarget=\(onTarget.toHexString()) slow=\(slow.toHexString())",
                    tip: "retarget-only"
                )
            ]
        )
    }

    private static func simBlock(
        _ hash: String,
        previous: String? = nil,
        height: UInt64,
        children: [String] = [],
        work: UInt256 = UInt256(1)
    ) -> BlockMeta {
        BlockMeta(
            blockInfo: .make(
                blockHash: hash,
                parentBlockHash: previous,
                blockHeight: height,
                work: work
            ),
            parentChainBlocks: [:],
            childHashes: children
        )
    }

    private static func simChain(
        blocks: [BlockMeta],
        main: Set<String>,
        inherited: [String: UInt256] = [:],
        provider: (@Sendable (String) -> UInt256)? = nil
    ) -> ChainState {
        var index: [UInt64: Set<String>] = [:]
        var byHash: [String: BlockMeta] = [:]
        for block in blocks {
            var block = block
            block.childHashes.append(contentsOf: blocks.compactMap { candidate in
                candidate.parentBlockHash == block.blockHash ? candidate.blockHash : nil
            })
            block.childHashes = Array(Set(block.childHashes)).sorted()
            index[block.blockHeight, default: []].insert(block.blockHash)
            byHash[block.blockHash] = block
        }
        let tip = blocks
            .filter { main.contains($0.blockHash) }
            .max { $0.blockHeight < $1.blockHeight }?
            .blockHash ?? blocks[0].blockHash
        // The only `throws` path of `ChainState.init` is an undecodable pruned-entry
        // weight in `prunedWeightIndex`. Every sim fixture is built with an empty
        // pruned index, so that path is unreachable — assert it before the force
        // unwrap so a future non-empty fixture fails loudly with a clear message
        // instead of an opaque `try!` crash.
        do {
            return try ChainState(
                chainTip: tip,
                mainChainHashes: main,
                indexToBlockHash: index,
                hashToBlock: byHash,
                parentChainBlockHashToBlockHash: [:],
                inheritedWeightProvider: provider ?? inheritedWeightProvider(inherited)
            )
        } catch {
            fatalError("simChain expects an empty prunedWeightIndex; ChainState.init threw: \(error)")
        }
    }

    private static func inheritedWeightProvider(_ weights: [String: UInt256]) -> (@Sendable (String) -> UInt256)? {
        guard !weights.isEmpty else { return nil }
        return { weights[$0] ?? .zero }
    }

    private static func seededOrder(seed: UInt64, values: [String]) -> [String] {
        var rng = LCG(seed: seed)
        let scores = Dictionary(uniqueKeysWithValues: values.map { ($0, rng.score($0)) })
        return values.sorted { left, right in
            let l = scores[left] ?? 0
            let r = scores[right] ?? 0
            if l != r { return l < r }
            return left < right
        }
    }

    private static func event(
        _ step: Int,
        _ label: String,
        tip: String,
        candidate: ForkChoiceSnapshot?,
        main: ForkChoiceSnapshot?,
        reorged: Bool?
    ) -> ConsensusSimEvent {
        ConsensusSimEvent(
            step: step,
            label: label,
            tip: tip,
            candidate: candidate?.startingHash,
            candidateTip: candidate?.tipHash,
            candidateTrueCumWork: candidate?.trueCumWork.toHexString(),
            mainTrueCumWork: main?.trueCumWork.toHexString(),
            reorged: reorged
        )
    }

    private static func forkRoot(
        for hash: String,
        visible: Set<String>,
        currentMain: Set<String>,
        blocksByHash: [String: ConsensusSimBlockSpec]
    ) -> String {
        var current = hash
        while let parent = blocksByHash[current]?.parent,
              visible.contains(parent),
              !currentMain.contains(parent) {
            current = parent
        }
        return current
    }
}

private final class MutableSimWeights: @unchecked Sendable {
    private let lock = NSLock()
    private var weights: [String: UInt256]

    init(_ weights: [String: UInt256]) {
        self.weights = weights
    }

    subscript(hash: String) -> UInt256 {
        lock.lock()
        defer { lock.unlock() }
        return weights[hash] ?? .zero
    }

    func replace(_ newWeights: [String: UInt256]) {
        lock.lock()
        weights = newWeights
        lock.unlock()
    }
}

private struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func score(_ value: String) -> UInt64 {
        var hash = state
        for byte in value.utf8 {
            hash = hash &* 6364136223846793005 &+ UInt64(byte) &+ 1442695040888963407
        }
        return hash
    }
}
