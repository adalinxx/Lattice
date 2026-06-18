import Lattice
import UInt256

// MARK: - ChainSpec test presets
//
// Test-fixture parameter sets (Bitcoin-, Ethereum- and development-shaped specs)
// formerly shipped inside the Lattice library despite having no production
// callers — they exist purely so tests can sweep representative spec shapes.
// Relocated to test support (wave-4); values are byte-identical.
extension ChainSpec {

    static let bitcoin: ChainSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 3000,
        maxStateGrowth: 1_000_000,
        maxBlockSize: 4_000_000,
        premine: 0,
        targetBlockTime: 600_000,
        initialReward: 5_000_000_000,
        halvingInterval: 210_000,
        retargetWindow: 2016
    )

    static let ethereum: ChainSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 1000,
        maxStateGrowth: 24_000_000,
        maxBlockSize: 30_000_000,
        premine: 72_000_000,
        targetBlockTime: 12_000,
        initialReward: 2_000_000_000_000_000_000,
        halvingInterval: 100_000_000,
        retargetWindow: 20
    )

    static let development: ChainSpec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 1000,
        targetBlockTime: 1_000,
        initialReward: 1024,
        halvingInterval: 10_000,
        retargetWindow: 5
    )
}
