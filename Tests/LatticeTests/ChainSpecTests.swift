import XCTest
@testable import Lattice
import UInt256

final class ChainSpecTests: XCTestCase {

    // MARK: - Basic Properties Tests

    func testChainSpecInitialization() {
        let chainSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 1000,
            maxStateGrowth: 500_000,
            premine: 21_000,
            targetBlockTime: 600_000,
            initialReward: 1_048_576,
            halvingInterval: 210_000,
            wasmPolicies: [
                WasmPolicyRef(moduleCID: "policy1", scope: .transaction),
                WasmPolicyRef(moduleCID: "policy2", scope: .action),
            ]
        )

        XCTAssertEqual(chainSpec.maxNumberOfTransactionsPerBlock, 1000)
        XCTAssertEqual(chainSpec.maxStateGrowth, 500_000)
        XCTAssertEqual(chainSpec.premine, 21_000)
        XCTAssertEqual(chainSpec.targetBlockTime, 600_000)
        XCTAssertEqual(chainSpec.initialReward, 1_048_576)
        XCTAssertEqual(chainSpec.halvingInterval, 210_000)
        XCTAssertEqual(ChainSpec.maxTargetChange, 2)
        XCTAssertEqual(chainSpec.wasmPolicies.count, 2)
    }

    func testLegacyChainSpecDecodesWithoutWasmPolicies() throws {
        let json = """
        {
          "directory": "Nexus",
          "maxNumberOfTransactionsPerBlock": 1000,
          "maxStateGrowth": 500000,
          "maxBlockSize": 1000000,
          "premine": 0,
          "targetBlockTime": 600000,
          "initialReward": 1048576,
          "halvingInterval": 210000,
          "retargetWindow": 120
        }
        """
        let spec = try JSONDecoder().decode(ChainSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.wasmPolicies, [])
    }

    func testLegacyJavaScriptFiltersRejectOnDecode() throws {
        let json = """
        {
          "directory": "Nexus",
          "maxNumberOfTransactionsPerBlock": 1000,
          "maxStateGrowth": 500000,
          "maxBlockSize": 1000000,
          "premine": 0,
          "targetBlockTime": 600000,
          "initialReward": 1048576,
          "halvingInterval": 210000,
          "retargetWindow": 120,
          "transactionFilters": ["function transactionFilter(tx) { return true; }"]
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(ChainSpec.self, from: Data(json.utf8)))
    }

    func testWasmPolicyRefDecodesDefaultEntrypoint() throws {
        let json = """
        {
          "moduleCID": "bafy-policy",
          "scope": "action"
        }
        """
        let policy = try JSONDecoder().decode(WasmPolicyRef.self, from: Data(json.utf8))
        XCTAssertEqual(policy.abiVersion, WasmPolicyRef.currentABIVersion)
        XCTAssertEqual(policy.entrypoint, WasmPolicyRef.Scope.action.defaultEntrypoint)
    }

    func testValidation() {
        let validSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 100, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 10_000)
        XCTAssertTrue(validSpec.isValid)

        let invalidTransactionCount = ChainSpec(maxNumberOfTransactionsPerBlock: 0, maxStateGrowth: 1000, premine: 100, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 10_000)
        XCTAssertFalse(invalidTransactionCount.isValid)

        let invalidStateGrowth = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 0, premine: 100, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 10_000)
        XCTAssertFalse(invalidStateGrowth.isValid)

        let invalidBlockTime = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 100, targetBlockTime: 0, initialReward: 1024, halvingInterval: 10_000)
        XCTAssertFalse(invalidBlockTime.isValid)

        let zeroReward = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 100, targetBlockTime: 10_000, initialReward: 0, halvingInterval: 10_000)
        XCTAssertFalse(zeroReward.isValid)

        let zeroInterval = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 100, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 0)
        XCTAssertFalse(zeroInterval.isValid)

        // Premine is uncapped: a premine equal to or larger than halvingInterval
        // (front-loading one or more full halving epochs) is a valid, honest
        // tokenomics choice — see PremineUncappedTests for emission/conservation
        // coverage. This previously failed under the removed `premine < halvingInterval`
        // cap.
        let premineAtIntervalBoundary = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 10_000, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 10_000)
        XCTAssertTrue(premineAtIntervalBoundary.isValid)

        let premineSpanningMultipleHalvings = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 25_000, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 10_000)
        XCTAssertTrue(premineSpanningMultipleHalvings.isValid)

        let smallPremine = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 9_999, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 10_000)
        XCTAssertTrue(smallPremine.isValid)
    }

    // MARK: - Reward Calculation Tests

    func testRewardAtBlock() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 0, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 1000)

        XCTAssertEqual(chainSpec.rewardAtBlock(0), 1024)
        XCTAssertEqual(chainSpec.rewardAtBlock(999), 1024)
        XCTAssertEqual(chainSpec.rewardAtBlock(1000), 512)
        XCTAssertEqual(chainSpec.rewardAtBlock(1999), 512)
        XCTAssertEqual(chainSpec.rewardAtBlock(2000), 256)
    }

    func testRewardCaching() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 0, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 1000)

        let reward1 = chainSpec.rewardAtBlock(500)
        let reward2 = chainSpec.rewardAtBlock(500)
        XCTAssertEqual(reward1, reward2)

        let reward3 = chainSpec.rewardAtBlock(1000)
        XCTAssertNotEqual(reward1, reward3)
    }

    func testTotalRewards() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 0, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 1000)

        XCTAssertEqual(chainSpec.totalRewards(upToBlock: 0), 0)
        XCTAssertEqual(chainSpec.totalRewards(upToBlock: 10), 1024 * 10)
        XCTAssertEqual(chainSpec.totalRewards(upToBlock: 1000), 1024 * 1000)

        // Across halving boundary: 1000 blocks at 1024 + 500 blocks at 512
        XCTAssertEqual(chainSpec.totalRewards(upToBlock: 1500), 1024 * 1000 + 512 * 500)
    }

    func testTotalRewardsOverflowSafety() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: UInt64.max / 2, halvingInterval: 10)

        let result = chainSpec.totalRewards(upToBlock: 10)
        XCTAssertEqual(result, UInt64.max)
    }

    func testPremineAmount() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 100, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 1000)
        let expectedPremine = chainSpec.totalRewards(upToBlock: 100)

        XCTAssertEqual(chainSpec.premineAmount(), expectedPremine)
        XCTAssertEqual(chainSpec.premineAmount(), 1024 * 100)
    }

    func testPremineBlockMiningTimeline() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 5, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 1000)

        XCTAssertEqual(chainSpec.rewardAtBlock(0), 1024)
        XCTAssertEqual(chainSpec.premineAmount(), 1024 * 5)

        // First halving at blockHeight = halvingInterval - premine = 995
        XCTAssertEqual(chainSpec.rewardAtBlock(994), 1024)
        XCTAssertEqual(chainSpec.rewardAtBlock(995), 512)
    }

    func testPremineOffsetInHalving() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 100, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 1000)

        XCTAssertEqual(chainSpec.rewardAtBlock(0), 1024)
        XCTAssertEqual(chainSpec.premineAmount(), 1024 * 100)

        let firstHalvingBlock: UInt64 = 1000 - 100  // = 900
        XCTAssertEqual(chainSpec.rewardAtBlock(firstHalvingBlock - 1), 1024)
        XCTAssertEqual(chainSpec.rewardAtBlock(firstHalvingBlock), 512)
    }

    // MARK: - Batch Operations Tests

    func testRewardRange() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 0, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 1000)

        let rewards = chainSpec.rewardRange(startBlock: 0, count: 10)
        XCTAssertEqual(rewards.count, 10)
        XCTAssertTrue(rewards.allSatisfy { $0 == 1024 })

        let emptyRewards = chainSpec.rewardRange(startBlock: 0, count: 0)
        XCTAssertEqual(emptyRewards.count, 0)
    }

    func testRewardRangeAcrossHalving() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 0, targetBlockTime: 10_000, initialReward: 16, halvingInterval: 100)

        let rewards = chainSpec.rewardRange(startBlock: 98, count: 4)
        XCTAssertEqual(rewards.count, 4)
        XCTAssertEqual(rewards[0], 16)
        XCTAssertEqual(rewards[1], 16)
        XCTAssertEqual(rewards[2], 8)
        XCTAssertEqual(rewards[3], 8)
    }

    // MARK: - Difficulty Adjustment Tests

    func testDifficultyCalculation() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 0, targetBlockTime: 60_000, initialReward: 1024, halvingInterval: 10_000)

        let baseDifficulty = UInt256(1000)
        let currentTime: Int64 = 1000000

        let normalDifficulty = chainSpec.calculateMinimumTarget(
            previousTarget: baseDifficulty,
            blockTimestamp: currentTime,
            previousTimestamp: currentTime - 60000
        )
        XCTAssertEqual(normalDifficulty, baseDifficulty)

        let harderDifficulty = chainSpec.calculateMinimumTarget(
            previousTarget: baseDifficulty,
            blockTimestamp: currentTime,
            previousTimestamp: currentTime - 30000
        )
        XCTAssertTrue(harderDifficulty < baseDifficulty)

        let easierDifficulty = chainSpec.calculateMinimumTarget(
            previousTarget: baseDifficulty,
            blockTimestamp: currentTime,
            previousTimestamp: currentTime - 120000
        )
        XCTAssertTrue(easierDifficulty > baseDifficulty)
    }

    // MARK: - Blockchain Convention Tests

    func testBitcoinLikeSpec() {
        let bitcoin = ChainSpec.bitcoin

        XCTAssertEqual(bitcoin.maxNumberOfTransactionsPerBlock, 3000)
        XCTAssertEqual(bitcoin.premine, 0)
        XCTAssertEqual(bitcoin.targetBlockTime, 600_000)
        XCTAssertEqual(bitcoin.halvingInterval, 210_000)
        XCTAssertTrue(bitcoin.isValid)
        XCTAssertEqual(bitcoin.initialReward, 5_000_000_000)
    }

    func testEthereumLikeSpec() {
        let ethereum = ChainSpec.ethereum

        XCTAssertEqual(ethereum.maxNumberOfTransactionsPerBlock, 1000)
        XCTAssertEqual(ethereum.premine, 72_000_000)
        XCTAssertEqual(ethereum.targetBlockTime, 12_000)
        XCTAssertTrue(ethereum.isValid)
    }

    func testDevelopmentSpec() {
        let dev = ChainSpec.development

        XCTAssertEqual(dev.targetBlockTime, 1_000)
        XCTAssertGreaterThan(dev.premine, 0)
        XCTAssertTrue(dev.isValid)
    }

    // MARK: - Edge Cases

    func testLargeBlockNumbers() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 0, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 10_000)

        let largeBlockReward = chainSpec.rewardAtBlock(UInt64.max / 2)
        XCTAssertGreaterThanOrEqual(largeBlockReward, 0)
    }

    func testTotalHalvings() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 0, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 10_000)
        XCTAssertEqual(chainSpec.totalHalvings, 11) // ceil(log2(1024)) + 1 = 11
        XCTAssertGreaterThan(chainSpec.totalHalvings, 0)
    }

    // MARK: - Performance Tests

    func testRewardCalculationPerformance() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 0, targetBlockTime: 10_000, initialReward: 1_048_576, halvingInterval: 210_000)

        measure {
            for i in 0..<10000 {
                _ = chainSpec.rewardAtBlock(UInt64(i))
            }
        }
    }

    func testTotalRewardsPerformance() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 0, targetBlockTime: 10_000, initialReward: 1_048_576, halvingInterval: 210_000)

        measure {
            _ = chainSpec.totalRewards(upToBlock: 1_000_000)
        }
    }

    func testBatchRewardPerformance() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 0, targetBlockTime: 10_000, initialReward: 1_048_576, halvingInterval: 210_000)

        measure {
            _ = chainSpec.rewardRange(startBlock: 0, count: 10000)
        }
    }

    func testPremineOffsetPerformanceWithLargeValues() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 5000, targetBlockTime: 60_000, initialReward: 1024, halvingInterval: 100_000)

        measure {
            for i: UInt64 in 0..<1000 {
                _ = chainSpec.rewardAtBlock(i)
            }
        }
    }

    // MARK: - Mathematical Correctness Tests

    func testGeometricSeriesCorrectness() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 0, targetBlockTime: 10_000, initialReward: 16, halvingInterval: 100)

        // Two full halving periods: 100 blocks at 16 + 100 blocks at 8
        let expectedTotal: UInt64 = 16 * 100 + 8 * 100
        let calculatedTotal = chainSpec.totalRewards(upToBlock: 200)
        XCTAssertEqual(calculatedTotal, expectedTotal)
    }

    func testRewardConsistency() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 1000, premine: 0, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 10_000)

        let individualSum = (0..<100).reduce(UInt64(0)) { sum, blockHeight in
            sum + chainSpec.rewardAtBlock(UInt64(blockHeight))
        }
        let totalCalculated = chainSpec.totalRewards(upToBlock: 100)
        XCTAssertEqual(individualSum, totalCalculated)
    }

    // MARK: - Validation Tests

    func testTransactionCountValidation() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 500, premine: 0, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 10_000)

        XCTAssertTrue(chainSpec.validateTransactionCount(500))
        XCTAssertTrue(chainSpec.validateTransactionCount(1000))
        XCTAssertFalse(chainSpec.validateTransactionCount(1001))
    }

    func testStateGrowthValidation() {
        let chainSpec = ChainSpec(maxNumberOfTransactionsPerBlock: 1000, maxStateGrowth: 500, premine: 0, targetBlockTime: 10_000, initialReward: 1024, halvingInterval: 10_000)

        XCTAssertTrue(chainSpec.validateStateGrowth(250))
        XCTAssertTrue(chainSpec.validateStateGrowth(500))
        XCTAssertFalse(chainSpec.validateStateGrowth(501))
    }

    func testChainSpecDoesNotVendUnusedDifficultyValidators() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent("Sources/Lattice/Block/ChainSpec.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let removedValidatorNames = [
            ["validate", "Difficulty"].joined(),
            ["validate", "Block", "Hash"].joined(),
        ]

        for name in removedValidatorNames {
            XCTAssertFalse(source.contains("func \(name)("))
        }
    }

    func testLiveBlockDifficultyValidatorAcceptsThresholdAndRejectsBelow() {
        let block = makeGenesisBlock(target: UInt256(1_000))

        XCTAssertTrue(block.validateProofOfWork(nexusHash: UInt256(1_000)))
        XCTAssertTrue(block.validateProofOfWork(nexusHash: UInt256(999)))
        XCTAssertFalse(block.validateProofOfWork(nexusHash: UInt256(1_001)))
    }

    func testChainSpecDifferences() {
        let bitcoin = ChainSpec.bitcoin
        let development = ChainSpec.development

        XCTAssertNotEqual(bitcoin.targetBlockTime, development.targetBlockTime)
        XCTAssertNotEqual(bitcoin.maxNumberOfTransactionsPerBlock, development.maxNumberOfTransactionsPerBlock)
        XCTAssertNotEqual(bitcoin.premine, development.premine)
    }

    func testBlockchainConventionCompliance() {
        XCTAssertEqual(ChainSpec.maxTargetChange, 2)

        let bitcoin = ChainSpec.bitcoin
        XCTAssertEqual(bitcoin.maxNumberOfTransactionsPerBlock, 3000)
        XCTAssertEqual(bitcoin.premine, 0)
        XCTAssertEqual(bitcoin.targetBlockTime, 600_000)

        let ethereum = ChainSpec.ethereum
        XCTAssertLessThan(ethereum.maxNumberOfTransactionsPerBlock, bitcoin.maxNumberOfTransactionsPerBlock)
        XCTAssertGreaterThan(ethereum.premine, 0)
        XCTAssertEqual(ethereum.targetBlockTime, 12_000)

        let dev = ChainSpec.development
        XCTAssertEqual(dev.targetBlockTime, 1_000)
    }

    // MARK: - Premine Offset Tests

    func testPremineOffsetTotalSupplyCalculations() {
        let chainSpec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 1000,
            maxStateGrowth: 1000,
            premine: 500,
            targetBlockTime: 60_000,
            initialReward: 1024,
            halvingInterval: 10_000
        )

        let firstHalvingBlock: UInt64 = 10_000 - 500  // = 9500
        let publicRewardsFirstPeriod = chainSpec.totalRewards(upToBlock: firstHalvingBlock)

        XCTAssertEqual(publicRewardsFirstPeriod, 1024 * firstHalvingBlock)
        XCTAssertEqual(chainSpec.premineAmount(), 1024 * 500)
    }

    func testIndependentRewardAndInterval() {
        let spec1 = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: 50, halvingInterval: 210_000)
        let spec2 = ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 1000, premine: 0, targetBlockTime: 1000, initialReward: 5_000_000, halvingInterval: 100)

        XCTAssertTrue(spec1.isValid)
        XCTAssertTrue(spec2.isValid)

        XCTAssertEqual(spec1.rewardAtBlock(0), 50)
        XCTAssertEqual(spec2.rewardAtBlock(0), 5_000_000)

        // spec1: halving at 210k, spec2: halving at 100
        XCTAssertEqual(spec1.rewardAtBlock(210_000), 25)
        XCTAssertEqual(spec2.rewardAtBlock(100), 2_500_000)
    }
}
