import XCTest
@testable import Lattice
@testable import LatticeSimulation
import UInt256

final class ConsensusSimulatorTests: XCTestCase {
    func testDefaultSimulatorTraceIsDeterministicForSeed() async throws {
        let first = await LatticeConsensusSimulator.runDefaultScenarios(seed: 42)
        let second = await LatticeConsensusSimulator.runDefaultScenarios(seed: 42)

        XCTAssertEqual(first, second)
        let firstJSON = try LatticeConsensusSimulator.encodeJSON(first)
        let secondJSON = try LatticeConsensusSimulator.encodeJSON(second)
        XCTAssertEqual(firstJSON, secondJSON)
    }

    func testSimulatorUsesProtocolNoFinalityDefault() async throws {
        XCTAssertEqual(RECENT_BLOCK_DISTANCE, UInt64.max)

        let traces = await LatticeConsensusSimulator.runDefaultScenarios(seed: 42)
        let reride = try XCTUnwrap(traces.first { $0.scenario == "parent-reorg-child-reride" })
        XCTAssertEqual(reride.events.map(\.reorged), [true, true])
    }

    func testSimulatorPinsHandCheckedForkChoiceFixtures() async throws {
        let traces = await LatticeConsensusSimulator.runDefaultScenarios(seed: 42)
        let byScenario = Dictionary(uniqueKeysWithValues: traces.map { ($0.scenario, $0) })

        let tie = try XCTUnwrap(byScenario["equal-work-tie-incumbent-holds"])
        XCTAssertEqual(tie.finalTip, "M1")
        XCTAssertEqual(tie.events.first?.reorged, false)
        XCTAssertEqual(tie.events.first?.candidateTrueCumWork, "0000000000000000000000000000000000000000000000000000000000000001")
        XCTAssertEqual(tie.events.first?.mainTrueCumWork, "0000000000000000000000000000000000000000000000000000000000000001")

        let inherited = try XCTUnwrap(byScenario["precomputed-inherited-weight-reorg"])
        XCTAssertEqual(inherited.finalTip, "C2")
        XCTAssertEqual(inherited.events.first?.label, "precomputed inherited=3 beats main=1")
        XCTAssertEqual(inherited.events.first?.candidateTrueCumWork, "0000000000000000000000000000000000000000000000000000000000000004")
        XCTAssertEqual(inherited.events.first?.mainTrueCumWork, "0000000000000000000000000000000000000000000000000000000000000001")
        XCTAssertEqual(inherited.events.first?.reorged, true)

        let reride = try XCTUnwrap(byScenario["parent-reorg-child-reride"])
        XCTAssertEqual(reride.finalTip, "CA")
        XCTAssertEqual(reride.events.map(\.tip), ["CB", "CA"])
        XCTAssertEqual(reride.events.map(\.reorged), [true, true])

        let withheld = try XCTUnwrap(byScenario["seeded-withhold-release"])
        XCTAssertEqual(withheld.events.map(\.candidateTip), ["F1", "F2", "F3"])
        XCTAssertEqual(withheld.events.map(\.tip), ["M2", "M2", "F3"])
        XCTAssertEqual(withheld.events.map(\.reorged), [false, false, true])

        let retarget = try XCTUnwrap(byScenario["proportional-retarget-one-hour"])
        XCTAssertTrue(retarget.events.first?.label.contains("target=3600000ms") ?? false)
        XCTAssertTrue(retarget.events.first?.label.contains("onTarget=00000000000000000000000000000000000000000000000000000000000003e8") ?? false)
        XCTAssertTrue(retarget.events.first?.label.contains("slow=00000000000000000000000000000000000000000000000000000000000007d0") ?? false)
    }

    func testSeededWithholdReleaseTraceIsStableAndConvergesToHeavierFork() async throws {
        let traces = await LatticeConsensusSimulator.runDefaultScenarios(seed: 0x1234)
        let withheld = try XCTUnwrap(traces.first { $0.scenario == "seeded-withhold-release" })

        XCTAssertEqual(withheld.finalTip, "F3")
        XCTAssertEqual(withheld.events.count, 3)
        XCTAssertEqual(withheld.events.last?.candidateTip, "F3")
        XCTAssertEqual(withheld.events.last?.candidateTrueCumWork, "0000000000000000000000000000000000000000000000000000000000000003")
    }

    // MARK: — no-finality adversarial scenarios

    func testAdversarialReportIsDeterministicForSeed() async throws {
        let first = await LatticeConsensusSimulator.runAdversarialReport(seed: 42)
        let second = await LatticeConsensusSimulator.runAdversarialReport(seed: 42)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            try LatticeConsensusSimulator.encodeAdversarialJSON(first),
            try LatticeConsensusSimulator.encodeAdversarialJSON(second)
        )
    }

    /// The committed `docs/consensus/tre-134-adversarial-report.{md,json}` artifacts must
    /// be byte-for-byte reproducible from `--seed 42`. Regenerate the report in-memory and
    /// byte-compare both committed files so a drift between the code and the checked-in
    /// report (or a regeneration with a different seed) fails CI.
    func testCommittedReportIsByteReproducibleFromSeed42() async throws {
        // Repo root is three directories up from this source file
        // (Tests/LatticeTests/ConsensusSimulatorTests.swift).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let docsDir = repoRoot.appendingPathComponent("docs/consensus")
        let committedJSON = try Data(contentsOf: docsDir.appendingPathComponent("tre-134-adversarial-report.json"))
        let committedMD = try Data(contentsOf: docsDir.appendingPathComponent("tre-134-adversarial-report.md"))

        let report = await LatticeConsensusSimulator.runAdversarialReport(seed: 42)
        let regeneratedJSON = try LatticeConsensusSimulator.encodeAdversarialJSON(report)
        let regeneratedMD = Data(LatticeConsensusSimulator.renderAdversarialMarkdown(report).utf8)

        XCTAssertEqual(regeneratedJSON, committedJSON,
            "docs/consensus/tre-134-adversarial-report.json is out of date; regenerate with `swift run LatticeSim --seed 42`")
        XCTAssertEqual(regeneratedMD, committedMD,
            "docs/consensus/tre-134-adversarial-report.md is out of date; regenerate with `swift run LatticeSim --seed 42`")
    }

    func testDeepReorgProbabilityGrowsWithHashrateAndIsNegligibleBelowMajority() async throws {
        let report = await LatticeConsensusSimulator.runAdversarialReport(seed: 42)
        let deep = report.deepReorg.sorted { $0.hashrateFraction < $1.hashrateFraction }

        // Monotone non-decreasing in f everywhere: more hashrate never reduces achievable
        // reorg depth.
        for (lo, hi) in zip(deep, deep.dropFirst()) {
            XCTAssertLessThanOrEqual(lo.reorgProbability, hi.reorgProbability,
                "reorg probability must not drop as f rises (\(lo.hashrateFraction) -> \(hi.hashrateFraction))")
            XCTAssertLessThanOrEqual(lo.meanReorgDepth, hi.meanReorgDepth,
                "mean reorg depth must not drop as f rises (\(lo.hashrateFraction) -> \(hi.hashrateFraction))")
        }

        // In the active region (f >= 0.4, where deep reorgs are no longer trial-noise) the
        // signal must grow STRICTLY with f — equal plateaus are only acceptable below this
        // band, where a finite trial count (200) cannot distinguish two near-zero
        // probabilities (e.g. 0.30 and 0.33 both round to a single observed reorg).
        let active = deep.filter { $0.hashrateFraction >= 0.4 }
        XCTAssertGreaterThanOrEqual(active.count, 3, "need several samples in the active region")
        for (lo, hi) in zip(active, active.dropFirst()) {
            XCTAssertLessThan(lo.reorgProbability, hi.reorgProbability,
                "reorg probability must strictly increase with f in the active region (\(lo.hashrateFraction) -> \(hi.hashrateFraction))")
            XCTAssertLessThan(lo.meanReorgDepth, hi.meanReorgDepth,
                "mean reorg depth must strictly increase with f in the active region (\(lo.hashrateFraction) -> \(hi.hashrateFraction))")
        }

        // Well below majority, deep reorgs are rare; at/above majority they dominate.
        let lowF = try XCTUnwrap(deep.first { $0.hashrateFraction == 0.25 })
        XCTAssertLessThan(lowF.reorgProbability, 0.05)
        let highF = try XCTUnwrap(deep.first { $0.hashrateFraction == 0.6 })
        XCTAssertGreaterThan(highF.reorgProbability, 0.5)
    }

    /// The selfish-mining profitability threshold must be the KNOWN Eyal–Sirer value for the
    /// tie-break advantage the node's fork choice actually realises. The no-finality
    /// incumbent-holds rule wins every equal-work tie for the honest network, i.e. γ = 0, and
    /// the γ = 0 threshold is EXACTLY f = 1/3 (the often-quoted ≈ 0.25 is the γ = ½ value, NOT
    /// γ = 0). We encode that threshold explicitly: assert (a) the curve is the closed-form
    /// Eyal–Sirer revenue at γ = 0, (b) γ is measured as 0 off the real fork choice, and (c)
    /// the gain crosses zero at exactly f = 1/3 (negative just below, positive just above).
    func testSelfishMiningThresholdIsExactlyOneThirdForGammaZero() async throws {
        let report = await LatticeConsensusSimulator.runAdversarialReport(seed: 42)

        // (b) The node's fork choice realises γ = 0 (honest incumbent holds every equal-work
        // tie). Confirm the helper that grounds γ in the real fork choice returns 0.
        let measuredGamma = await LatticeConsensusSimulator.measuredTieAdoptionGamma(seed: 42, fraction: 0.3)
        XCTAssertEqual(measuredGamma, 0.0, "incumbent-holds ties ⇒ γ = 0")

        // The exact γ = 0 threshold. NOT 0.25 — that is the γ = ½ value.
        let threshold = 1.0 / 3.0

        // (a) Each sampled share equals the closed-form Eyal–Sirer revenue at γ = 0, and gain
        // is positive iff f is above the 1/3 threshold.
        for p in report.selfishMining {
            let expected = LatticeConsensusSimulator.eyalSirerRevenueShare(fraction: p.hashrateFraction, gamma: 0.0)
            XCTAssertEqual(p.attackerRevenueShare, expected, accuracy: 1e-9,
                "selfish revenue must be the closed-form Eyal–Sirer value at f=\(p.hashrateFraction)")
            if p.hashrateFraction < threshold {
                XCTAssertLessThan(p.relativeGain, 0,
                    "selfish gain must be negative below the 1/3 threshold at f=\(p.hashrateFraction)")
            } else if p.hashrateFraction > threshold {
                XCTAssertGreaterThan(p.relativeGain, 0,
                    "selfish gain must be positive above the 1/3 threshold at f=\(p.hashrateFraction)")
            }
        }

        // (c) The gain crosses zero at EXACTLY f = 1/3: negative just below, ~0 at, positive
        // just above. This pins the threshold value itself, not just the sampled neighbourhood.
        let belowGain = LatticeConsensusSimulator.eyalSirerRevenueShare(fraction: threshold - 1e-4, gamma: 0.0) - (threshold - 1e-4)
        let atGain = LatticeConsensusSimulator.eyalSirerRevenueShare(fraction: threshold, gamma: 0.0) - threshold
        let aboveGain = LatticeConsensusSimulator.eyalSirerRevenueShare(fraction: threshold + 1e-4, gamma: 0.0) - (threshold + 1e-4)
        XCTAssertLessThan(belowGain, 0, "gain must be negative just below f = 1/3")
        XCTAssertEqual(atGain, 0, accuracy: 1e-9, "gain must be zero at exactly f = 1/3")
        XCTAssertGreaterThan(aboveGain, 0, "gain must be positive just above f = 1/3")

        // Revenue share is monotone non-decreasing in f.
        let sorted = report.selfishMining.sorted { $0.hashrateFraction < $1.hashrateFraction }
        for (lo, hi) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(lo.attackerRevenueShare, hi.attackerRevenueShare)
        }
    }

    func testBalancingIsInfeasibleBelowMajority() async throws {
        let report = await LatticeConsensusSimulator.runAdversarialReport(seed: 42)
        for p in report.balancing where p.hashrateFraction < 0.5 {
            // No trial held the balance across the full horizon below majority.
            XCTAssertEqual(p.survivalProbability, 0,
                "balancing must never survive the horizon below majority (f=\(p.hashrateFraction))")
            // And the cost (attacker blocks burned) is bounded by the stall it bought.
            XCTAssertLessThanOrEqual(p.meanAttackerBlocksSpent, p.meanStallRounds + 1e-9)
        }
    }

    /// The cost of stalling convergence must grow with the attacker's work: a higher `f`
    /// lets the attacker win more re-balancing PoW races, so it both sustains a longer
    /// stall and burns strictly more of its own blocks doing it. Assert both the per-step
    /// monotonicity of cost in `f` and an end-to-end strict growth across the curve so the
    /// scenario measures cost-as-a-function-of-`f`, not just feasibility.
    func testBalancingCostGrowsWithAttackerWork() async throws {
        let report = await LatticeConsensusSimulator.runAdversarialReport(seed: 42)
        let sorted = report.balancing.sorted { $0.hashrateFraction < $1.hashrateFraction }
        XCTAssertGreaterThanOrEqual(sorted.count, 3, "need several balancing points to test cost growth")

        // Monotone non-decreasing in f everywhere: more attacker work never lowers the
        // blocks it must spend (nor the stall it can buy) to keep the branches tied.
        for (lo, hi) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(lo.meanAttackerBlocksSpent, hi.meanAttackerBlocksSpent,
                "attacker cost must not drop as f rises (\(lo.hashrateFraction) -> \(hi.hashrateFraction))")
            XCTAssertLessThanOrEqual(lo.meanStallRounds, hi.meanStallRounds,
                "stall length must not drop as f rises (\(lo.hashrateFraction) -> \(hi.hashrateFraction))")
        }

        // End-to-end the cost must grow STRICTLY: the lowest-f attacker spends materially
        // fewer blocks than the highest-f one (cost is a real, increasing function of f,
        // not a constant).
        let lowest = try XCTUnwrap(sorted.first)
        let highest = try XCTUnwrap(sorted.last)
        XCTAssertLessThan(lowest.meanAttackerBlocksSpent, highest.meanAttackerBlocksSpent,
            "attacker cost must strictly increase from f=\(lowest.hashrateFraction) to f=\(highest.hashrateFraction)")
    }

    /// merged-mining economics: `f` is DERIVED through the real per-chain PoW gate,
    /// not asserted. The attacker's effective per-chain fraction must equal its share of THAT
    /// chain's own subscribers, INDEPENDENT of the other chains' targets — proving there is no
    /// nexus-anchored amplification under independent per-chain validation + opt-in subscription.
    func testMergedMiningPerChainFractionIsDerivedWithNoNexusAmplification() throws {
        // Target chain: attacker controls 30% of ITS subscribers. The tree also contains a much
        // easier chain (huge target) and a harder chain (small target) with different attacker
        // splits — none of which may move the target chain's derived fraction.
        // Targets kept within a few bits of each other so the rare-clearance Monte-Carlo stays
        // sample-efficient; the easiest (largest) sets the search floor.
        let easyChain = LatticeConsensusSimulator.SubscribedChain(
            name: "easy", targetWord: 1 << 40, honestHashrate: 10, attackerHashrate: 90)
        let target = LatticeConsensusSimulator.SubscribedChain(
            name: "target", targetWord: 1 << 38, honestHashrate: 70, attackerHashrate: 30)
        let hardChain = LatticeConsensusSimulator.SubscribedChain(
            name: "hard", targetWord: 1 << 36, honestHashrate: 99, attackerHashrate: 1)
        let tree = [easyChain, target, hardChain]

        let derived = LatticeConsensusSimulator.derivePerChainAttackerFraction(
            chain: target, tree: tree, seed: 42, samples: 200_000)
        // Equals the attacker's share of the TARGET chain's subscribers (30/100), within
        // Monte-Carlo tolerance — and crucially is unaffected by the easy/hard siblings.
        XCTAssertEqual(derived, 0.30, accuracy: 0.01,
            "per-chain attacker fraction must equal its share of the target chain's own subscribers")

        // No amplification: re-deriving with the OTHER chains' targets and splits changed must
        // not move the target chain's fraction (independent per-chain validation).
        let amplified = [
            LatticeConsensusSimulator.SubscribedChain(
                name: "easy", targetWord: 1 << 40, honestHashrate: 1, attackerHashrate: 999),
            target,
            LatticeConsensusSimulator.SubscribedChain(
                name: "hard2", targetWord: 1 << 39, honestHashrate: 1, attackerHashrate: 999)
        ]
        let derivedAmplified = LatticeConsensusSimulator.derivePerChainAttackerFraction(
            chain: target, tree: amplified, seed: 42, samples: 200_000)
        XCTAssertEqual(derivedAmplified, derived, accuracy: 0.01,
            "other chains' targets/splits must not amplify the target chain's attacker fraction")
    }

    /// The per-chain PoW gate used by the derivation is the real `validateProofOfWork`
    /// polarity: a solution clears a chain iff its hash is at most that chain's target.
    func testMergedMiningGateMatchesValidateProofOfWorkPolarity() {
        XCTAssertTrue(LatticeConsensusSimulator.powClears(target: UInt256(100), hash: UInt256(50)))
        XCTAssertTrue(LatticeConsensusSimulator.powClears(target: UInt256(100), hash: UInt256(100)))
        XCTAssertFalse(LatticeConsensusSimulator.powClears(target: UInt256(100), hash: UInt256(101)))
    }

    func testAdversarialMarkdownRendersAllThreeScenarios() async throws {
        let report = await LatticeConsensusSimulator.runAdversarialReport(seed: 42)
        let md = LatticeConsensusSimulator.renderAdversarialMarkdown(report)
        XCTAssertTrue(md.contains("(a) Deep reorg"))
        XCTAssertTrue(md.contains("(b) Selfish mining"))
        XCTAssertTrue(md.contains("(c) Balancing attack"))
        XCTAssertTrue(md.contains(" C5"))
    }

    func testDiscreteEventScenarioHonorsConfiguredTopologyLatencyAndWork() async throws {
        let spec = ConsensusSimScenarioSpec(
            scenario: "configured-work-latency",
            seed: 7,
            blocks: [
                ConsensusSimBlockSpec(hash: "G", height: 0),
                ConsensusSimBlockSpec(hash: "M1", parent: "G", height: 1),
                ConsensusSimBlockSpec(hash: "F1", parent: "G", height: 1, work: UInt256(3))
            ],
            initiallyVisible: ["G", "M1"],
            initialMain: ["G", "M1"],
            releases: [ConsensusSimRelease(atMillis: 250, blockHash: "F1")]
        )

        let trace = await LatticeConsensusSimulator.runDiscreteEventScenario(spec)

        XCTAssertEqual(trace.scenario, "configured-work-latency")
        XCTAssertEqual(trace.finalTip, "F1")
        XCTAssertEqual(trace.events.first?.label, "t=250ms release F1")
        XCTAssertEqual(trace.events.first?.candidateTrueCumWork, "0000000000000000000000000000000000000000000000000000000000000003")
        XCTAssertEqual(trace.events.first?.reorged, true)
    }
}
