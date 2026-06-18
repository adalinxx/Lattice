import XCTest
@testable import Lattice
import UInt256
import Foundation

// MARK: - Deterministic PRNG for Reproducible Fuzz Tests

struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

// MARK: - Random Generators

extension SeededRNG {
    mutating func randomString(length: Int) -> String {
        let chars = "abcdef0123456789"
        return String((0..<length).map { _ in chars.randomElement(using: &self)! })
    }

    mutating func randomHash() -> String {
        randomString(length: 64)
    }

    mutating func randomUInt64(in range: ClosedRange<UInt64>) -> UInt64 {
        UInt64.random(in: range, using: &self)
    }

    mutating func randomBool() -> Bool {
        Bool.random(using: &self)
    }
}

// MARK: - ChainSpec Fuzz Tests

final class ChainSpecFuzzTests: XCTestCase {

    func testRewardAtBlockNeverOverflows() {
        var rng = SeededRNG(seed: 42)
        for _ in 0..<1000 {
            let reward = UInt64.random(in: 1...1_000_000, using: &rng)
            let interval = UInt64.random(in: 1...1_000_000, using: &rng)
            let premine = UInt64.random(in: 0...interval - 1, using: &rng)
            let spec = ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 1000,
                premine: premine,
                targetBlockTime: 1000,
                initialReward: reward,
                halvingInterval: interval
            )
            guard spec.isValid else { continue }

            let blockHeight = UInt64.random(in: 0...UInt64.max / 2, using: &rng)
            let blockReward = spec.rewardAtBlock(blockHeight)
            XCTAssertTrue(blockReward <= spec.initialReward,
                          "Reward \(blockReward) exceeded initial \(spec.initialReward) at block \(blockHeight)")
        }
    }

    func testRewardMonotonicallyDecreases() {
        var rng = SeededRNG(seed: 101)
        for _ in 0..<200 {
            let reward = UInt64.random(in: 1...1_000_000, using: &rng)
            let interval = UInt64.random(in: 1...100_000, using: &rng)
            let spec = ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 1000,
                premine: 0,
                targetBlockTime: 1000,
                initialReward: reward,
                halvingInterval: interval
            )
            guard spec.isValid else { continue }

            var prevReward = spec.rewardAtBlock(0)
            for i: UInt64 in 1..<10 {
                let (block, overflow) = interval.multipliedReportingOverflow(by: i)
                guard !overflow else { break }
                let r = spec.rewardAtBlock(block)
                XCTAssertTrue(r <= prevReward,
                              "Reward increased from \(prevReward) to \(r) at halving \(i)")
                prevReward = r
            }
        }
    }

    func testTotalRewardsConsistentWithIndividualSum() {
        var rng = SeededRNG(seed: 202)
        for _ in 0..<100 {
            let reward = UInt64.random(in: 1...10_000, using: &rng)
            let interval = UInt64.random(in: 100...10_000, using: &rng)
            let spec = ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 1000,
                premine: 0,
                targetBlockTime: 1000,
                initialReward: reward,
                halvingInterval: interval
            )
            guard spec.isValid else { continue }

            let blockCount = UInt64.random(in: 1...500, using: &rng)
            let totalFromMethod = spec.totalRewards(upToBlock: blockCount)
            let totalFromIndividual = (0..<blockCount).reduce(UInt64(0)) { sum, idx in
                sum + spec.rewardAtBlock(idx)
            }
            XCTAssertEqual(totalFromMethod, totalFromIndividual,
                           "Mismatch for reward=\(reward), interval=\(interval), blockCount=\(blockCount)")
        }
    }

    func testPairDifficultyTracksTargetRatio() {
        var rng = SeededRNG(seed: 303)
        let spec = ChainSpec.development

        for _ in 0..<500 {
            let prevDiff = UInt256(UInt64.random(in: 100...UInt64.max / 2, using: &rng))
            let prevTime: Int64 = 1_000_000
            let delta = Int64.random(in: 1...600_000, using: &rng)
            let blockTime = prevTime + delta

            let newDiff = spec.calculateMinimumTarget(
                previousTarget: prevDiff,
                blockTimestamp: blockTime,
                previousTimestamp: prevTime
            )

            let actual = UInt256(UInt64(delta))
            let target = UInt256(spec.targetBlockTime)
            let quotient = prevDiff / target
            let remainder = prevDiff % target
            let scaledQuotient = quotient > UInt256.max / actual ? UInt256.max : quotient * actual
            let scaledRemainderProduct = remainder > UInt256.max / actual ? UInt256.max : remainder * actual
            let scaledRemainder = scaledRemainderProduct / target
            let ratio = scaledQuotient > UInt256.max - scaledRemainder ? UInt256.max : scaledQuotient + scaledRemainder
            let expected = max(ratio, ChainSpec.minimumTarget)
            XCTAssertEqual(newDiff, expected, "Difficulty must follow exact target ratio: \(prevDiff), delta=\(delta)ms")
        }
    }

    func testChainSpecValidationEdgeCases() {
        var rng = SeededRNG(seed: 404)
        for _ in 0..<500 {
            let txCount = UInt64.random(in: 0...100, using: &rng)
            let stateGrowth = Int.random(in: 0...10000, using: &rng)
            let blockTime = UInt64.random(in: 0...600_000, using: &rng)
            let reward = UInt64.random(in: 0...1_000_000, using: &rng)
            let interval = UInt64.random(in: 0...1_000_000, using: &rng)
            let premine = UInt64.random(in: 0...UInt64.max / 2, using: &rng)

            let spec = ChainSpec(
                maxNumberOfTransactionsPerBlock: txCount,
                maxStateGrowth: stateGrowth,
                premine: premine,
                targetBlockTime: blockTime,
                initialReward: reward,
                halvingInterval: interval
            )

            if spec.isValid {
                XCTAssertGreaterThan(txCount, 0)
                XCTAssertGreaterThan(stateGrowth, 0)
                XCTAssertGreaterThan(blockTime, 0)
                XCTAssertGreaterThan(reward, 0)
                XCTAssertGreaterThan(interval, 0)
                // premine is intentionally uncapped (cap `premine < halvingInterval`
                // removed); a valid spec may premine across many halvings. The
                // emission math stays well-defined and supply-bounded — see
                // PremineUncappedTests.
            }
        }
    }

    func testPremineAmountConsistency() {
        var rng = SeededRNG(seed: 505)
        for _ in 0..<200 {
            let reward = UInt64.random(in: 1...10_000, using: &rng)
            let interval = UInt64.random(in: 100...100_000, using: &rng)
            let premine = UInt64.random(in: 0...min(interval - 1, 10_000), using: &rng)

            let spec = ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 1000,
                premine: premine,
                targetBlockTime: 1000,
                initialReward: reward,
                halvingInterval: interval
            )
            guard spec.isValid else { continue }

            let premineTotal = spec.premineAmount()
            let manualTotal = (0..<premine).reduce(UInt64(0)) { sum, idx in
                sum + (reward >> (idx / interval))
            }
            XCTAssertEqual(premineTotal, manualTotal,
                           "Premine mismatch for reward=\(reward), premine=\(premine)")
        }
    }
}

// MARK: - Fork Choice Fuzz Tests

@MainActor
final class ForkChoiceFuzzTests: XCTestCase {

    func testRandomChainTopologyInvariants() async {
        var rng = SeededRNG(seed: 909)

        for _ in 0..<50 {
            let chainLength = Int.random(in: 2...20, using: &rng)
            let numForks = Int.random(in: 0...5, using: &rng)

            var blocks: [BlockMeta] = []
            let genesis = makeBlockMeta(hash: "G", height: 0)
            blocks.append(genesis)

            var tip = "G"
            for i in 1..<chainLength {
                let hash = "main_\(i)"
                let meta = makeBlockMeta(hash: hash, previousHash: tip, height: UInt64(i))
                blocks[blocks.count - 1].childHashes.append(hash)
                blocks.append(meta)
                tip = hash
            }

            var longestFork = 0
            for f in 0..<numForks {
                let forkPoint = Int.random(in: 0..<chainLength, using: &rng)
                let forkLen = Int.random(in: 1...8, using: &rng)
                longestFork = max(longestFork, forkLen)

                for j in 0..<forkLen {
                    let forkIdx = UInt64(forkPoint + j + 1)
                    let hash = "fork\(f)_\(j)"
                    let prevHash = j == 0 ? blocks[forkPoint].blockHash : "fork\(f)_\(j-1)"
                    let meta = makeBlockMeta(hash: hash, previousHash: prevHash, height: forkIdx)
                    if j == 0 {
                        blocks[forkPoint].childHashes.append(hash)
                    } else {
                        blocks[blocks.count - 1].childHashes.append(hash)
                    }
                    blocks.append(meta)
                }
            }

            let mainHashes = Set((0..<chainLength).map { "main_\($0)" } + ["G"])
            let chain = makeChain(blocks: blocks, mainChainHashes: mainHashes)

            let chainTip = await chain.getMainChainTip()
            let tipOnMain = await chain.isOnMainChain(hash: chainTip)
            XCTAssertTrue(tipOnMain, "Chain tip must be on main chain")

            let tipBlock = await chain.getConsensusBlock(hash: chainTip)
            XCTAssertNotNil(tipBlock, "Chain tip must exist in block map")

            let genesisOnMain = await chain.isOnMainChain(hash: "G")
            XCTAssertTrue(genesisOnMain, "Genesis must always be on main chain")
        }
    }

    func testRandomReorgPreservesConnectivity() async {
        var rng = SeededRNG(seed: 1010)

        for _ in 0..<30 {
            let mainLen = Int.random(in: 3...10, using: &rng)
            let forkLen = mainLen + Int.random(in: 1...5, using: &rng)

            var blocks: [BlockMeta] = []
            let genesis = makeBlockMeta(hash: "G", height: 0, childHashes: ["M1", "F1"])
            blocks.append(genesis)

            for i in 1...mainLen {
                let hash = "M\(i)"
                let prev = i == 1 ? "G" : "M\(i-1)"
                let children = i < mainLen ? ["M\(i+1)"] : [String]()
                blocks.append(makeBlockMeta(hash: hash, previousHash: prev, height: UInt64(i), childHashes: children))
            }
            for i in 1...forkLen {
                let hash = "F\(i)"
                let prev = i == 1 ? "G" : "F\(i-1)"
                let children = i < forkLen ? ["F\(i+1)"] : [String]()
                blocks.append(makeBlockMeta(hash: hash, previousHash: prev, height: UInt64(i), childHashes: children))
            }

            let mainHashes = Set(["G"] + (1...mainLen).map { "M\($0)" })
            let chain = makeChain(blocks: blocks, mainChainHashes: mainHashes)

            let forkTipHash = "F\(forkLen)"
            let forkTip = await chain.getConsensusBlock(hash: forkTipHash)!
            let reorg = await chain.checkForReorg(block: forkTip)

            XCTAssertNotNil(reorg, "Longer fork should trigger reorg")

            let newTip = await chain.getMainChainTip()
            XCTAssertEqual(newTip, forkTipHash)

            var current = newTip
            var depth = 0
            while current != "G" {
                let block = await chain.getConsensusBlock(hash: current)
                XCTAssertNotNil(block, "Block \(current) missing from chain")
                guard let prevHash = block?.parentBlockHash else {
                    XCTFail("Block \(current) has no previous hash but is not genesis")
                    break
                }
                current = prevHash
                depth += 1
                if depth > forkLen + 10 { XCTFail("Infinite loop in chain traversal"); break }
            }
        }
    }
}

// MARK: - CryptoUtils Fuzz Tests

final class CryptoUtilsFuzzTests: XCTestCase {

    func testSignVerifyRoundTrip() {
        var rng = SeededRNG(seed: 1111)
        for _ in 0..<50 {
            let keyPair = CryptoUtils.generateKeyPair()
            let message = rng.randomString(length: Int.random(in: 1...200, using: &rng))
            guard let signature = CryptoUtils.sign(message: message, privateKeyHex: keyPair.privateKey) else {
                XCTFail("Signing failed")
                continue
            }
            XCTAssertTrue(CryptoUtils.verify(message: message, signature: signature, publicKeyHex: keyPair.publicKey),
                          "Valid signature rejected")
        }
    }

    func testWrongKeyRejected() {
        var rng = SeededRNG(seed: 1212)
        for _ in 0..<50 {
            let keyPair1 = CryptoUtils.generateKeyPair()
            let keyPair2 = CryptoUtils.generateKeyPair()
            let message = rng.randomString(length: 32)
            guard let signature = CryptoUtils.sign(message: message, privateKeyHex: keyPair1.privateKey) else {
                continue
            }
            XCTAssertFalse(CryptoUtils.verify(message: message, signature: signature, publicKeyHex: keyPair2.publicKey),
                           "Signature verified with wrong public key")
        }
    }

    func testTamperedMessageRejected() {
        var rng = SeededRNG(seed: 1313)
        for _ in 0..<50 {
            let keyPair = CryptoUtils.generateKeyPair()
            let message = rng.randomString(length: 32)
            guard let signature = CryptoUtils.sign(message: message, privateKeyHex: keyPair.privateKey) else {
                continue
            }
            let tampered = message + "x"
            XCTAssertFalse(CryptoUtils.verify(message: tampered, signature: signature, publicKeyHex: keyPair.publicKey),
                           "Tampered message accepted")
        }
    }

    func testSha256Determinism() {
        var rng = SeededRNG(seed: 1414)
        for _ in 0..<200 {
            let input = rng.randomString(length: Int.random(in: 0...500, using: &rng))
            let hash1 = CryptoUtils.sha256(input)
            let hash2 = CryptoUtils.sha256(input)
            XCTAssertEqual(hash1, hash2)
            XCTAssertEqual(hash1.count, 64)
        }
    }

    func testSha256CollisionResistance() {
        var hashes = Set<String>()
        for i in 0..<1000 {
            let input = "unique_input_\(i)"
            let hash = CryptoUtils.sha256(input)
            XCTAssertFalse(hashes.contains(hash), "SHA-256 collision found for input \(i)")
            hashes.insert(hash)
        }
    }
}

// MARK: - UInt256 Fuzz Tests

final class UInt256FuzzTests: XCTestCase {

    func testHexRoundTrip() {
        var rng = SeededRNG(seed: 1616)
        for _ in 0..<500 {
            let value = UInt256(UInt64.random(in: 0...UInt64.max, using: &rng))
            let hex = value.toPrefixedHexString()
            let parsed = UInt256.fromHexString(hex)
            XCTAssertEqual(parsed, value, "Round-trip failed for \(value)")
        }
    }

    func testHashDeterminism() {
        var rng = SeededRNG(seed: 1717)
        for _ in 0..<200 {
            let len = Int.random(in: 0...500, using: &rng)
            var data = Data(count: len)
            for i in 0..<len {
                data[i] = UInt8.random(in: 0...255, using: &rng)
            }
            let h1 = UInt256.hash(data)
            let h2 = UInt256.hash(data)
            XCTAssertEqual(h1, h2)
        }
    }

    func testHashDistribution() {
        var rng = SeededRNG(seed: 1818)
        var hashes: Set<String> = Set()
        for i in 0..<500 {
            let h = UInt256.hash("input_\(i)_\(rng.randomString(length: 8))")
            hashes.insert(h.toPrefixedHexString())
        }
        XCTAssertEqual(hashes.count, 500, "Hash collisions detected in 500 unique inputs")
    }
}

// MARK: - AccountAction Fuzz Tests

final class AccountActionFuzzTests: XCTestCase {

    func testVerifyRejectsZeroDelta() {
        var rng = SeededRNG(seed: 1919)
        for _ in 0..<200 {
            let action = AccountAction(owner: rng.randomHash(), delta: 0)
            XCTAssertFalse(action.verify(), "Verify should reject zero-delta action")
        }
    }

    func testVerifyAcceptsChange() {
        var rng = SeededRNG(seed: 2020)
        for _ in 0..<200 {
            let old = UInt64.random(in: 0...UInt64.max / 2, using: &rng)
            let new = old + UInt64.random(in: 1...1000, using: &rng)
            let action = AccountAction(owner: rng.randomHash(), delta: Int64(new) - Int64(old))
            XCTAssertTrue(action.verify(), "Verify should accept changed action")
        }
    }

    func testStateDeltaIsConservativelyZero() {
        var rng = SeededRNG(seed: 2121)
        for _ in 0..<200 {
            let owner = rng.randomHash()

            // With delta model, stateDelta() returns 0 (conservative) since
            // insertion/deletion can't be determined without current state
            let creditAction = AccountAction(owner: owner, delta: Int64(100))
            XCTAssertEqual(creditAction.stateDelta(), 0)

            let debitAction = AccountAction(owner: owner, delta: -Int64(100))
            XCTAssertEqual(debitAction.stateDelta(), 0)

            let smallDelta = AccountAction(owner: owner, delta: Int64(50))
            XCTAssertEqual(smallDelta.stateDelta(), 0)
        }
    }
}

// MARK: - Action (Generic KV) Fuzz Tests

final class ActionFuzzTests: XCTestCase {

    func testVerifyRequiresNonEmptyKey() {
        let action = Action(key: "", oldValue: nil, newValue: "val")
        XCTAssertFalse(action.verify())
    }

    func testVerifyRequiresAtLeastOneValue() {
        var rng = SeededRNG(seed: 2222)
        for _ in 0..<100 {
            let key = rng.randomString(length: 10)
            let action = Action(key: key, oldValue: nil, newValue: nil)
            XCTAssertFalse(action.verify())
        }
    }

    func testStateDeltaInsertIsPositive() {
        var rng = SeededRNG(seed: 2323)
        for _ in 0..<100 {
            let key = rng.randomString(length: Int.random(in: 1...50, using: &rng))
            let value = rng.randomString(length: Int.random(in: 1...100, using: &rng))
            let action = Action(key: key, oldValue: nil, newValue: value)
            let delta = try! action.stateDelta()
            XCTAssertGreaterThan(delta, 0)
        }
    }

    func testStateDeltaDeleteIsNegative() {
        var rng = SeededRNG(seed: 2424)
        for _ in 0..<100 {
            let key = rng.randomString(length: Int.random(in: 1...50, using: &rng))
            let value = rng.randomString(length: Int.random(in: 1...100, using: &rng))
            let action = Action(key: key, oldValue: value, newValue: nil)
            let delta = try! action.stateDelta()
            XCTAssertLessThan(delta, 0)
        }
    }

    func testStateDeltaUpdateReflectsSizeDiff() {
        var rng = SeededRNG(seed: 2525)
        for _ in 0..<100 {
            let key = rng.randomString(length: 10)
            let shortVal = rng.randomString(length: 5)
            let longVal = rng.randomString(length: 50)
            let growAction = Action(key: key, oldValue: shortVal, newValue: longVal)
            let growDelta = try! growAction.stateDelta()
            XCTAssertGreaterThan(growDelta, 0)

            let shrinkAction = Action(key: key, oldValue: longVal, newValue: shortVal)
            let shrinkDelta = try! shrinkAction.stateDelta()
            XCTAssertLessThan(shrinkDelta, 0)
        }
    }
}

// MARK: - BlockMeta Weights Fuzz Tests

final class BlockMetaWeightsFuzzTests: XCTestCase {

    func testParentIndexIsMinimumOfValues() {
        var rng = SeededRNG(seed: 2929)
        for _ in 0..<200 {
            let count = Int.random(in: 1...10, using: &rng)
            var parentBlocks: [String: UInt64?] = [:]
            var minVal: UInt64? = nil
            for _ in 0..<count {
                let key = rng.randomHash()
                let val: UInt64? = rng.randomBool() ? rng.randomUInt64(in: 0...1000) : nil
                parentBlocks[key] = val
                if let v = val {
                    minVal = minVal.map { min($0, v) } ?? v
                }
            }
            let meta = BlockMeta(
                blockInfo: BlockInfoImpl(blockHash: "test", parentBlockHash: nil, blockHeight: 0, work: UInt256.zero),
                parentChainBlocks: parentBlocks,
                childHashes: []
            )
            XCTAssertEqual(meta.parentIndex, minVal)
        }
    }
}
