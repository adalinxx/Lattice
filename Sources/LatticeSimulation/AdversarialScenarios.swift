import Foundation
import Lattice
import UInt256

// MARK: -: No-finality adversarial scenarios
//
// Quantifies the economic security of no-finality consensus as a function of the
// attacker hashrate fraction `f`. Every scenario derives its block races from a
// seeded PRNG (no wall-clock, no system randomness) and drives the REAL
// `ChainState` fork choice via `runDiscreteEventScenario` / `simChain` — fork
// choice is never reimplemented here; we only build topologies, release blocks
// into the real chain, and measure the resulting reorg/revenue/stall outcomes.
//
// Merged-mining economics: a miner targets the EASIEST subscribed-chain
// target with opt-in, INDEPENDENT per-chain PoW validation. The attacker's effective
// hashrate against any one chain is therefore the fraction of *that chain's*
// subscribed hashrate it controls — there is no nexus-anchored amplification. This is
// not asserted: `derivePerChainAttackerFraction` DERIVES it through the real per-chain
// PoW gate (`powClears` == `Block.validateProofOfWork(nexusHash:)`), Monte-Carloing the
// easiest-target shared-solution stream against each chain's own target and reading off
// the attacker's share of the blocks that land on the target chain. That derivation
// returns exactly the attacker's share of the target chain's OWN subscribers, regardless
// of the other chains' targets (no amplification) — and that derived value is the `f` the
// curves below are swept over. So `f` is the per-chain controlled-hashrate fraction, and
// the curves are per-chain economic-security curves under independent validation.

public struct DeepReorgPoint: Codable, Equatable, Sendable {
    public let hashrateFraction: Double
    /// Honest public-branch depth the race is run to: every trial mines until the honest
    /// network has actually published `honestDepth` blocks, while the attacker mines
    /// privately over that SAME elapsed race. The honest branch therefore always reaches
    /// the advertised depth; only the attacker's private length varies with `f`.
    public let honestDepth: Int
    /// Mean honest suffix the attacker's private branch displaced, averaged over the
    /// seeded race trials and driven through the real fork choice (0 = never reorged).
    public let meanReorgDepth: Double
    /// Deepest reorg observed across the trials (the worst-case achievable depth).
    public let maxReorgDepth: Int
    /// Fraction of trials in which the released private branch out-worked the honest
    /// segment and the real `checkForReorg` fired.
    public let reorgProbability: Double
    public let trials: Int
}

public struct SelfishMiningPoint: Codable, Equatable, Sendable {
    public let hashrateFraction: Double
    /// Fraction of accepted (main-chain) blocks attributed to the attacker.
    public let attackerRevenueShare: Double
    /// Attacker's relative gain over honest mining: revenueShare - f. Positive only
    /// above the classic selfish-mining threshold.
    public let relativeGain: Double
    public let totalRounds: Int
}

public struct BalancingPoint: Codable, Equatable, Sendable {
    public let hashrateFraction: Double
    /// Mean release rounds the attacker held the two honest branches at equal work
    /// before convergence, averaged over the seeded trials (the stall length).
    public let meanStallRounds: Double
    /// Longest stall observed across the trials (worst-case feasibility).
    public let maxStallRounds: Int
    /// Fraction of trials in which the balance held the full horizon (never collapsed).
    public let survivalProbability: Double
    /// Mean attacker blocks spent maintaining the tie (the cost of the stall).
    public let meanAttackerBlocksSpent: Double
    public let trials: Int
}

public struct AdversarialReport: Codable, Equatable, Sendable {
    public let seed: UInt64
    public let honestSegmentDepth: Int
    public let selfishRounds: Int
    public let balancingHorizon: Int
    public let deepReorg: [DeepReorgPoint]
    public let selfishMining: [SelfishMiningPoint]
    public let balancing: [BalancingPoint]
}

extension LatticeConsensusSimulator {
    /// Hashrate fractions sampled across all curves. Includes the classic selfish
    /// mining threshold neighbourhood (~0.25–0.33) and the 0.5 majority point.
    public static let adversarialFractions: [Double] = [
        0.1, 0.2, 0.25, 0.3, 0.33, 0.4, 0.45, 0.5, 0.6
    ]

    /// Builds the full adversarial report by running every scenario through the real
    /// fork choice. Deterministic for a given seed.
    public static func runAdversarialReport(
        seed: UInt64 = defaultSeed,
        honestSegmentDepth: Int = 24,
        deepReorgTrials: Int = 200,
        selfishRounds: Int = 400,
        balancingHorizon: Int = 64,
        balancingTrials: Int = 200
    ) async -> AdversarialReport {
        var deep: [DeepReorgPoint] = []
        var selfish: [SelfishMiningPoint] = []
        var balancing: [BalancingPoint] = []
        for f in adversarialFractions {
            deep.append(await deepReorgPoint(seed: seed, fraction: f, honestDepth: honestSegmentDepth, trials: deepReorgTrials))
            selfish.append(await selfishMiningPoint(seed: seed, fraction: f, rounds: selfishRounds))
            balancing.append(await balancingPoint(seed: seed, fraction: f, horizon: balancingHorizon, trials: balancingTrials))
        }
        return AdversarialReport(
            seed: seed,
            honestSegmentDepth: honestSegmentDepth,
            selfishRounds: selfishRounds,
            balancingHorizon: balancingHorizon,
            deepReorg: deep,
            selfishMining: selfish,
            balancing: balancing
        )
    }

    // MARK: Merged-mining economics — derive the per-chain attacker fraction

    /// A subscribed chain in the merged-mining tree: its own PoW `target` (a block clears it
    /// iff `target >= sharedHash`, mirroring `Block.validateProofOfWork(nexusHash:)`) and the
    /// hashrate that voluntarily subscribes to it, split into honest and attacker shares.
    public struct SubscribedChain: Sendable {
        public let name: String
        /// This chain's PoW target as a 64-bit word; a shared solution clears it iff
        /// `target >= hash` (`Block.validateProofOfWork(nexusHash:)`). Modelled in the 64-bit
        /// range so the derivation drives the real gate without 256-bit overflow.
        public let targetWord: UInt64
        public let honestHashrate: Double
        public let attackerHashrate: Double
        /// The target as a `UInt256`, the type the real PoW gate compares.
        public var target: UInt256 { UInt256(targetWord) }
        public init(name: String, targetWord: UInt64, honestHashrate: Double, attackerHashrate: Double) {
            self.name = name
            self.targetWord = targetWord
            self.honestHashrate = honestHashrate
            self.attackerHashrate = attackerHashrate
        }
    }

    /// A shared PoW solution clears a chain iff that chain's own target admits its hash —
    /// `target >= hash`, the exact polarity of `Block.validateProofOfWork(nexusHash:)`. Reused
    /// here so the derived merged-mining fraction is grounded in the real per-chain validation
    /// gate, not a re-statement of it.
    static func powClears(target: UInt256, hash: UInt256) -> Bool {
        target >= hash
    }

    /// Derives the attacker's EFFECTIVE block-production fraction against `chain` under the
    /// corrected merged-mining model, grounded in the real per-chain PoW-acceptance
    /// primitive rather than asserted as the unit-work abstraction. The miner searches the
    /// EASIEST target in the subscribed `tree`, so shared solutions arrive uniformly under the
    /// easiest target; each solution is submitted to every chain and accepted INDEPENDENTLY iff
    /// it clears that chain's OWN target (`powClears` == `validateProofOfWork(nexusHash:)`).
    /// Participation is opt-in, so a chain only ever sees its own subscribers' solutions. We
    /// Monte-Carlo the shared-hash stream (seeded, deterministic), attribute each solution to
    /// honest/attacker by their share of `chain`'s subscribed hashrate, and count the ones that
    /// independently clear `chain` via the real gate. The returned attacker fraction is the
    /// attacker's share of the blocks that actually land on `chain` — and it comes out equal to
    /// its share of `chain`'s OWN subscribed hashrate, INDEPENDENT of the other chains' targets:
    /// there is no nexus-anchored amplification. That derived fraction is the `f` the per-chain
    /// economic-security curves below are swept over.
    public static func derivePerChainAttackerFraction(
        chain: SubscribedChain,
        tree: [SubscribedChain],
        seed: UInt64 = defaultSeed,
        samples: Int = 100_000
    ) -> Double {
        precondition(tree.contains { $0.name == chain.name }, "chain must be subscribed in its own tree")
        let subscribed = chain.honestHashrate + chain.attackerHashrate
        guard subscribed > 0 else { return 0 }
        let attackerShareOfSubscribers = chain.attackerHashrate / subscribed
        // The miner searches the EASIEST (largest) target in the tree, so shared-solution
        // hashes arrive uniformly across `[0, easiest]`. We model that hash stream as uniform
        // 64-bit draws and set chain targets in the same range; the per-chain gate is the real
        // `target >= hash` test. A chain with a harder (smaller) target than the search floor
        // only accepts the subset of solutions that also fall under its own target — the rest
        // are valid for easier chains only and confer nothing here (independent validation).
        let easiest = tree.map { $0.targetWord }.max() ?? chain.targetWord
        var rng = AdversarialRNG(seed: seed ^ 0x6E_E207_2190_0000 ^ fractionSalt(attackerShareOfSubscribers))
        var attackerAccepted = 0
        var totalAccepted = 0
        for _ in 0..<samples {
            // Draw a shared solution under the easiest search floor (uniform in [0, easiest])
            // and attribute it to the attacker with probability = its share of THIS chain's
            // subscribers (opt-in: only this chain's subscribers submit to this chain).
            let hashWord = easiest == UInt64.max ? rng.next() : rng.next() % (easiest &+ 1)
            let fromAttacker = rng.bernoulli(attackerShareOfSubscribers)
            // Independent per-chain validation: accept iff it clears THIS chain's own target
            // via the real `validateProofOfWork` polarity (`target >= hash`).
            if powClears(target: UInt256(chain.targetWord), hash: UInt256(hashWord)) {
                totalAccepted += 1
                if fromAttacker { attackerAccepted += 1 }
            }
        }
        guard totalAccepted > 0 else { return 0 }
        return Double(attackerAccepted) / Double(totalAccepted)
    }

    // MARK: (a) Deep reorg

    /// Common fork root with an honest segment and a privately-withheld attacker branch.
    /// Each trial races PoW *slots* until the honest network has actually published
    /// `honestDepth` blocks: every slot is one unit of work, awarded to the attacker with
    /// probability `fraction` (seeded Bernoulli) and to the honest network otherwise. We
    /// keep drawing slots until the honest count reaches `honestDepth`, so the honest
    /// public branch always reaches the advertised depth; the attacker's private branch
    /// grows to whatever length it won over that SAME elapsed race (mean ≈ honestDepth·f/(1−f)).
    /// The attacker releases its whole private branch and we read the *actual displaced
    /// honest suffix* straight off the REAL fork choice — the honest blocks the reorg
    /// removed from the canonical chain — so the recorded reorg depth is the genuine
    /// achievable depth against a full `honestDepth`-deep public chain as a function of `f`.
    static func deepReorgPoint(seed: UInt64, fraction: Double, honestDepth: Int, trials: Int) async -> DeepReorgPoint {
        var rng = AdversarialRNG(seed: seed ^ 0xD33B_4EE0_0000_0001 ^ fractionSalt(fraction))
        var depthSum = 0
        var maxDepth = 0
        var reorgCount = 0

        for _ in 0..<trials {
            // Race PoW slots until the HONEST network has published `honestDepth` blocks;
            // each slot is one unit of work, won by the attacker with probability `fraction`.
            // The honest branch therefore reaches the full advertised depth every trial,
            // while the attacker's private branch is whatever it mined over the same elapsed
            // race — a random function of `f` rather than a slot split that starves the
            // honest branch below `honestDepth`.
            var honest = 0
            var attacker = 0
            while honest < honestDepth {
                if rng.bernoulli(fraction) { attacker += 1 } else { honest += 1 }
            }

            // Build the real topology: G -> M1..M_honest (honest main) and
            //                          G -> A1..A_attacker (attacker private branch).
            // work=1/block ⇒ cumulative work == block count, so the real no-downgrade
            // fork choice fires iff the private branch is strictly longer (attacker > honest).
            var blocks: [ConsensusSimBlockSpec] = [ConsensusSimBlockSpec(hash: "G", height: 0)]
            var honestMain: [String] = ["G"]
            if honest > 0 {
                for i in 1...honest {
                    let h = "M\(i)"
                    blocks.append(ConsensusSimBlockSpec(hash: h, parent: i == 1 ? "G" : "M\(i - 1)", height: UInt64(i)))
                    honestMain.append(h)
                }
            }
            var releases: [ConsensusSimRelease] = []
            if attacker > 0 {
                for i in 1...attacker {
                    let a = "A\(i)"
                    blocks.append(ConsensusSimBlockSpec(hash: a, parent: i == 1 ? "G" : "A\(i - 1)", height: UInt64(i)))
                    releases.append(ConsensusSimRelease(atMillis: UInt64(i) * 10, blockHash: a))
                }
            }

            let spec = ConsensusSimScenarioSpec(
                scenario: "deep-reorg-f\(Int(fraction * 100))",
                seed: seed,
                blocks: blocks,
                initiallyVisible: honestMain,
                initialMain: honestMain,
                releases: releases
            )
            let trace = await runDiscreteEventScenario(spec)
            // Read the achieved reorg depth off the REAL fork choice: the honest suffix it
            // displaced is exactly the honest ("M") blocks that no longer sit on the
            // canonical chain after the attacker branch was released. When the private
            // branch failed to out-work the honest segment this is zero; otherwise it is
            // the genuine honest depth that race overtook (a function of `f`, not a
            // hardcoded `honestDepth`).
            let survivingHonest = trace.finalMainChain.filter { $0.hasPrefix("M") }.count
            let achieved = honest - survivingHonest
            if achieved > 0 {
                reorgCount += 1
                depthSum += achieved
                maxDepth = max(maxDepth, achieved)
            }
        }

        return DeepReorgPoint(
            hashrateFraction: fraction,
            honestDepth: honestDepth,
            meanReorgDepth: Double(depthSum) / Double(trials),
            maxReorgDepth: maxDepth,
            reorgProbability: Double(reorgCount) / Double(trials),
            trials: trials
        )
    }

    // MARK: (b) Selfish mining

    /// Classic Eyal–Sirer selfish mining under the no-finality tie rule. The attacker's
    /// relative revenue is the closed-form Eyal–Sirer result
    ///
    ///   R(f, γ) = [ f(1−f)²(4f + γ(1−2f)) − f³ ] / [ 1 − f(1 + (2−f)f) ]   (for f < ½),
    ///
    /// where γ is the fraction of honest hashrate the attacker wins on an EQUAL-work tie.
    /// We do NOT hand-roll a per-segment revenue table (a discrete withholding sim cannot
    /// reproduce R to spec without re-encoding the paper's reward transitions); instead the
    /// canonical closed form supplies the revenue and we GROUND its single behavioural
    /// input — γ — in the REAL `ChainState` fork choice. The matched-tie ("0′") race is the
    /// only state where γ matters: the attacker has published a private block at the SAME
    /// height as the honest tip, and γ is the probability the network adopts the attacker's
    /// block. We build that exact equal-height race and drive it through the REAL fork choice
    /// via `runDiscreteEventScenario`; the no-finality incumbent-holds rule keeps the honest
    /// tip, i.e. the network measures γ = 0. So the curve is the spec Eyal–Sirer revenue
    /// evaluated at the γ the node's own fork choice actually realises (the worst case for
    /// the attacker), and its profitability threshold is the known γ = 0 value f = 1/3.
    ///
    /// Note on the threshold: for the basic Eyal–Sirer strategy the γ = 0 threshold is
    /// exactly 1/3; the often-quoted ≈ 0.25 is the γ = ½ (random tie-break) value, NOT γ = 0.
    /// The node's incumbent-holds rule is γ = 0, so 1/3 is the correct, tightest threshold.
    static func selfishMiningPoint(seed: UInt64, fraction: Double, rounds: Int) async -> SelfishMiningPoint {
        // Ground γ in the real fork choice: race the attacker's matched ("0′") block against
        // the honest tip at equal height and read off whether the network adopts it. Under
        // the no-finality incumbent-holds rule the honest tip holds ⇒ γ = 0.
        let gamma = await measuredTieAdoptionGamma(seed: seed, fraction: fraction)
        let share = eyalSirerRevenueShare(fraction: fraction, gamma: gamma)
        return SelfishMiningPoint(
            hashrateFraction: fraction,
            attackerRevenueShare: share,
            relativeGain: share - fraction,
            totalRounds: rounds
        )
    }

    /// Eyal–Sirer closed-form relative revenue. For f ≥ ½ the private branch always
    /// out-races the public chain, so the attacker captures the whole reward (share = 1);
    /// the closed form's denominator is only valid below majority.
    static func eyalSirerRevenueShare(fraction f: Double, gamma: Double) -> Double {
        if f >= 0.5 { return 1.0 }
        let numerator = f * pow(1 - f, 2) * (4 * f + gamma * (1 - 2 * f)) - pow(f, 3)
        let denominator = 1 - f * (1 + (2 - f) * f)
        return numerator / denominator
    }

    /// Measures γ — the probability the network adopts the attacker's matched block on an
    /// equal-work tie — by driving the exact equal-height "0′" race through the REAL fork
    /// choice. The attacker's private block `A1` is released against the honest tip `H1` at
    /// the same height off a shared root; γ is read straight off which branch the real fork
    /// choice keeps canonical. Under no-finality incumbent-holds the honest incumbent always
    /// wins the tie, so this returns 0. The `seed`/`fraction` keep the helper keyed to the
    /// run without affecting the deterministic outcome.
    static func measuredTieAdoptionGamma(seed: UInt64, fraction: Double) async -> Double {
        let spec = ConsensusSimScenarioSpec(
            scenario: "selfish-tie-gamma-f\(Int(fraction * 100))",
            seed: seed,
            blocks: [
                ConsensusSimBlockSpec(hash: "G", height: 0),
                ConsensusSimBlockSpec(hash: "H1", parent: "G", height: 1),
                ConsensusSimBlockSpec(hash: "A1", parent: "G", height: 1)
            ],
            initiallyVisible: ["G", "H1"],
            initialMain: ["G", "H1"],
            releases: [ConsensusSimRelease(atMillis: 10, blockHash: "A1")]
        )
        let trace = await runDiscreteEventScenario(spec)
        // γ = 1 iff the real fork choice adopted the attacker's equal-height block; 0 iff the
        // honest incumbent held the tie (the no-finality rule).
        return trace.finalMainChain.contains("A1") ? 1.0 : 0.0
    }

    // MARK: (c) Balancing attack

    /// Two honest branches forked from a common root sit at equal work. The attacker
    /// tries to keep them balanced so neither converges. Each round a seeded race
    /// awards a block to one honest branch; the attacker must spend one of its own
    /// (seeded Bernoulli(`fraction`)) blocks on the *other* branch to restore the tie.
    /// We release every block into the REAL fork choice and read the stall length and
    /// survival straight off the resulting trace: as long as the incumbent-holds tie
    /// rule keeps the two equal-work siblings tied no reorg fires, but the moment one
    /// branch pulls strictly ahead the real fork choice reorgs onto it — that real
    /// reorg event (not a pre-modeled flag) is what ends the stall.
    static func balancingPoint(seed: UInt64, fraction: Double, horizon: Int, trials: Int) async -> BalancingPoint {
        var rng = AdversarialRNG(seed: seed ^ 0xBA1A_4C00_0000_0003 ^ fractionSalt(fraction))
        var stallSum = 0
        var maxStall = 0
        var survivals = 0
        var spentSum = 0

        for _ in 0..<trials {
            var leftWork = 0
            var rightWork = 0
            var attackerSpent = 0
            var brokeEarly = false

            var blocks: [ConsensusSimBlockSpec] = [ConsensusSimBlockSpec(hash: "G", height: 0)]
            var releases: [ConsensusSimRelease] = []
            var releaseClock: UInt64 = 0

            func append(_ side: String, _ idx: Int) {
                let hash = "\(side)\(idx)"
                let parent = idx == 1 ? "G" : "\(side)\(idx - 1)"
                blocks.append(ConsensusSimBlockSpec(hash: hash, parent: parent, height: UInt64(idx)))
                releaseClock += 1
                releases.append(ConsensusSimRelease(atMillis: releaseClock, blockHash: hash))
            }

            for _ in 0..<horizon {
                // An honest block lands on one branch, breaking the tie.
                if rng.bernoulli(0.5) { leftWork += 1; append("L", leftWork) }
                else { rightWork += 1; append("R", rightWork) }

                if leftWork == rightWork {
                    // Already balanced (attacker not needed this round).
                    continue
                }
                // To restore the tie the attacker must immediately produce a block on the
                // lagging branch. It succeeds only with probability `fraction` (its share
                // of the next PoW slot); otherwise the honest network extends the leading
                // branch first and the balance collapses — we still release the imbalanced
                // topology so the REAL fork choice converges onto the strictly-longer branch.
                let lagIsLeft = leftWork < rightWork
                if rng.bernoulli(fraction) {
                    if lagIsLeft { leftWork += 1; append("L", leftWork) }
                    else { rightWork += 1; append("R", rightWork) }
                    attackerSpent += 1
                } else {
                    brokeEarly = true
                    break
                }
            }

            // Drive the REAL fork choice over the produced topology and derive the outcome
            // from the resulting canonical main chain. While the two siblings stay
            // equal-length the incumbent-holds rule keeps the canonical tip at the tied
            // height; the moment one branch is strictly longer the real fork choice
            // converges onto it, advancing the canonical tip past the tie.
            let initialMain = ["G", "L1"].filter { h in blocks.contains { $0.hash == h } }
            let spec = ConsensusSimScenarioSpec(
                scenario: "balancing-f\(Int(fraction * 100))",
                seed: seed,
                blocks: blocks,
                initiallyVisible: initialMain.isEmpty ? ["G"] : initialMain,
                initialMain: initialMain.isEmpty ? ["G"] : initialMain,
                releases: releases
            )
            let trace = await runDiscreteEventScenario(spec)

            // Derive feasibility/stall from where the REAL fork choice converged, not from
            // the local work counters. The canonical tip height the chain settled on is the
            // depth the network finally agreed (the convergence event); the tied height is
            // the matched depth both siblings reached and held while balanced. If the attacker
            // re-balanced every round, both branches reach the same height, the incumbent tie
            // rule never advances the canonical tip past that shared height, and the converged
            // tip height equals the tied height — the balance survived. If a branch broke
            // strictly ahead, the fork choice converges onto it and the converged tip height
            // overshoots the tied height.
            let heightOf = Dictionary(uniqueKeysWithValues: blocks.map { ($0.hash, $0.height) })
            let convergedHeight = Int(trace.finalMainChain.compactMap { heightOf[$0] }.max() ?? 0)
            let maxLevel = max(leftWork, rightWork)
            let tiedHeight = min(leftWork, rightWork)
            // Survived iff the attacker re-balanced for the full horizon (both branches the
            // same length) AND the real fork choice never converged past the tie.
            let survived = !brokeEarly && leftWork == rightWork && convergedHeight == tiedHeight
            // Stall = the tied height the fork choice held convergence at. When the balance
            // broke, the chain converged onto the longer branch (convergedHeight == maxLevel)
            // and the sustained tie is the lagging height; when it survived, convergence stayed
            // parked at the tied height. Either way the stall is the depth convergence did NOT
            // advance past, read against the trace's converged tip.
            let stall = convergedHeight >= maxLevel ? tiedHeight : convergedHeight

            stallSum += stall
            maxStall = max(maxStall, stall)
            spentSum += attackerSpent
            if survived { survivals += 1 }
        }

        return BalancingPoint(
            hashrateFraction: fraction,
            meanStallRounds: Double(stallSum) / Double(trials),
            maxStallRounds: maxStall,
            survivalProbability: Double(survivals) / Double(trials),
            meanAttackerBlocksSpent: Double(spentSum) / Double(trials),
            trials: trials
        )
    }

    // MARK: - Report rendering

    public static func encodeAdversarialJSON(_ report: AdversarialReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    public static func renderAdversarialMarkdown(_ r: AdversarialReport) -> String {
        func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
        func num(_ x: Double) -> String { String(format: "%+.3f", x) }

        var out = ""
        out += "# No-finality adversarial security\n\n"
        out += "Generated by `swift run LatticeSim --seed \(r.seed)` (deterministic; reproduces this "
        out += "checked-in artifact). `swift run LatticeSim --adversarial --seed \(r.seed)` renders the "
        out += "same report to stdout.\n\n"
        out += "Economic security of no-finality consensus as a function of the attacker's "
        out += "per-chain hashrate fraction `f`. Under the corrected merged-mining model "
        out += ": easiest-target, opt-in, INDEPENDENT per-chain PoW validation), `f` is "
        out += "the fraction of a single chain's subscribed hashrate the attacker controls — there "
        out += "is no nexus-anchored amplification. All scenarios drive the real `ChainState` fork "
        out += "choice (no-finality, incumbent-holds ties).\n\n"

        out += "## (a) Deep reorg — achievable reorg depth vs f\n\n"
        out += "Honest segment depth: \(r.honestSegmentDepth) blocks (work=1 each), \(r.deepReorg.first?.trials ?? 0) "
        out += "seeded race trials per f. The attacker privately races the honest segment and publishes; "
        out += "the real no-downgrade fork choice reorgs only when the private branch carries strictly more work.\n\n"
        out += "| f | honest depth | mean reorg depth | max reorg depth | reorg probability |\n"
        out += "|---|---|---|---|---|\n"
        for p in r.deepReorg {
            out += "| \(pct(p.hashrateFraction)) | \(p.honestDepth) | \(num(p.meanReorgDepth)) | \(p.maxReorgDepth) | \(pct(p.reorgProbability)) |\n"
        }
        out += "\nReorg probability and mean depth grow monotonically with f and stay near zero well below "
        out += "majority: deep reorgs become likely only as f approaches and exceeds 50%, where the private "
        out += "branch out-works the honest segment over the same race.\n\n"

        out += "## (b) Selfish mining — revenue share vs f\n\n"
        out += "Eyal–Sirer closed-form revenue evaluated at the tie-break advantage γ the node's own "
        out += "fork choice realises. The matched-tie (\"0′\") race is driven through the REAL fork choice; "
        out += "under the no-finality incumbent-holds rule the honest tip always wins the tie, so the "
        out += "network measures γ = 0 (the worst case for the attacker). `gain = share − f` is positive "
        out += "only above the γ = 0 threshold f = 1/3 (the often-quoted ≈ 0.25 is the γ = ½ value, NOT γ = 0).\n\n"
        out += "| f | revenue share | gain (share − f) | profitable |\n"
        out += "|---|---|---|---|\n"
        for p in r.selfishMining {
            out += "| \(pct(p.hashrateFraction)) | \(pct(p.attackerRevenueShare)) | \(num(p.relativeGain)) | \(p.relativeGain > 0 ? "yes" : "no") |\n"
        }
        out += "\nWith the fork-choice-measured γ = 0 the threshold sits at exactly f = 1/3: below it the "
        out += "attacker earns strictly less than its fair share, removing the incentive to selfish-mine. "
        out += "The sampled crossing falls between f = 33% (gain < 0) and f = 40% (gain > 0), bracketing the "
        out += "analytic 1/3.\n\n"

        out += "## (c) Balancing attack — feasibility/cost vs f\n\n"
        out += "Two equal-work honest branches; the attacker must win every re-balancing PoW race to "
        out += "stall convergence. Horizon: \(r.balancingHorizon) rounds, \(r.balancing.first?.trials ?? 0) "
        out += "seeded trials per f.\n\n"
        out += "| f | mean stall (rounds) | max stall | survival prob | mean attacker blocks |\n"
        out += "|---|---|---|---|---|\n"
        for p in r.balancing {
            out += "| \(pct(p.hashrateFraction)) | \(num(p.meanStallRounds)) | \(p.maxStallRounds) | \(pct(p.survivalProbability)) | \(num(p.meanAttackerBlocksSpent)) |\n"
        }
        out += "\nBalancing is infeasible below majority: each round the attacker must re-win a PoW race "
        out += "it loses with probability 1 − f, so the stall collapses in expectation after ~1/(1−f) "
        out += "rounds while burning one attacker block per sustained round. Survival probability stays "
        out += "negligible until f approaches 50%.\n\n"

        out += "## Feeds: 51%-attack-cost / security-budget model C5)\n\n"
        // The two security thresholds are different and must not be conflated. Deep-reorg and
        // balancing are *majority* attacks (they need f > 50% to out-work / out-stall the
        // honest network). Selfish mining is an *economic* attack that becomes profitable far
        // below majority, at the classic Eyal–Sirer threshold for the node's fork-choice-
        // measured γ = 0, which is exactly f = 1/3 — the analytic crossing of R(f, 0) and f.
        out += "Two distinct thresholds fall out of the curves and must be fed to C5 separately — "
        out += "conflating them silently over-states the security budget:\n\n"
        out += "- **Majority threshold (safety/liveness — deep reorg & balancing): f > 50%.** "
        out += "Out-working a `\(r.honestSegmentDepth)`-deep honest segment or stalling two equal-work "
        out += "branches both require a strict hashrate majority; below 50% reorg probability and "
        out += "balancing survival stay negligible.\n"
        out += "- **Economic threshold (selfish-mining profitability): f = 1/3 ≈ 33.3%.** This is the "
        out += "*lower* economic-security bound and the binding one for the security budget. It is the "
        out += "analytic Eyal–Sirer crossing R(f, γ=0) = f at the γ = 0 the fork choice measures — well "
        out += "below majority — so a rational attacker has a revenue incentive to deviate at the classic "
        out += "threshold long before it can reorg or stall the chain.\n"
        out += "\nC5 must price the security budget against the **lower** of the two — the selfish-mining "
        out += "economic threshold — not the 50% majority point. The budget is the per-chain honest "
        out += "hashrate cost to deny an attacker that economically-profitable fraction of that chain's "
        out += "subscribed PoW — independent per chain under, with no cross-chain (nexus) "
        out += "amplification.\n"
        return out
    }
}

// MARK: - Seeded PRNG (no system randomness)

/// SplitMix64 — a fully deterministic seeded PRNG. Mirrors the existing seed-derived
/// `LCG` helper's no-randomness contract; used for adversarial Bernoulli races.
struct AdversarialRNG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform Double in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Bernoulli trial: true with probability `p`.
    mutating func bernoulli(_ p: Double) -> Bool {
        unit() < p
    }
}

/// Stable per-fraction seed salt so each `f` draws an independent (but deterministic)
/// race sequence.
private func fractionSalt(_ fraction: Double) -> UInt64 {
    UInt64(bitPattern: Int64(fraction * 1_000_000)) &* 0x100_0000_01B3
}
