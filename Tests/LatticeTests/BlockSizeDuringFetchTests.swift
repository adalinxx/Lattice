import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticeValidation
@testable import LatticeBlockTree
@testable import LatticeImport
import cashew
import UInt256

/// `maxBlockSize` is decided while the counted closure resolves: the verdict
/// is the full-closure verdict, reached without the whole closure.
final class BlockSizeDuringFetchTests: XCTestCase {
    // MARK: - The early verdict is the full-closure verdict

    func testEarlyVerdictEqualsFullClosureVerdictAroundTheBoundary() async throws {
        let fetcher = StorableFetcher()
        for (name, block) in try await generatedBlocks(fetcher: fetcher) {
            let full = try await fullClosureSize(of: block, fetcher: fetcher)
            let decoded = try XCTUnwrap(Block(data: XCTUnwrap(block.toData())))
            for limit in [1, full / 2, full - 1, full, full + 1, full * 2] {
                let expected = full <= limit
                for (held, candidate) in [("materialized", block), ("unresolved", decoded)] {
                    let label = "\(name) \(held) limit \(limit) of \(full)"
                    let fits = try await candidate.validateBlockSize(
                        spec: sizeSpec(limit), fetcher: fetcher
                    )
                    XCTAssertEqual(fits, expected, label)
                    do {
                        let size = try await candidate.logicalContentByteSize(
                            fetcher: fetcher, limit: limit
                        )
                        XCTAssertTrue(expected, label)
                        XCTAssertEqual(size, full, label)
                    } catch BlockContentSizeError.exceedsLimit {
                        XCTAssertFalse(expected, label)
                    }
                }
            }
        }
    }

    /// What resolution fetches is exactly what the rule counts, less the
    /// block's own node: a partial sum of fetched content never counts an item
    /// the full sum does not.
    func testResolutionFetchesExactlyTheCountedClosure() async throws {
        let fetcher = StorableFetcher()
        for (name, block) in try await generatedBlocks(fetcher: fetcher) {
            let rootData = try XCTUnwrap(block.toData())
            let decoded = try XCTUnwrap(Block(data: rootData))
            let fetched = StorableFetcher()
            _ = try await BlockHeader(node: decoded).resolve(
                paths: [
                    [TRANSACTIONS_PROPERTY]: .recursive,
                    [CHILDREN_PROPERTY]: .targeted,
                ],
                fetcher: fetcher,
                cache: fetched
            )
            var counted = try await fullClosureEntries(of: block, fetcher: fetcher)
            XCTAssertEqual(
                counted.removeValue(forKey: try BlockHeader(node: block).rawCID), rootData, name
            )
            XCTAssertEqual(fetched.entries, counted, name)
        }
    }

    func testVerdictIsIndependentOfFetchOrderAndBatching() async throws {
        let fetcher = StorableFetcher()
        for (name, block) in try await generatedBlocks(fetcher: fetcher) {
            let full = try await fullClosureSize(of: block, fetcher: fetcher)
            let decoded = try XCTUnwrap(Block(data: XCTUnwrap(block.toData())))
            var sources: [any Fetcher] = (0..<4).map { JitterFetcher(base: fetcher, seed: $0) }
            sources.append(CoalescingFetcher(FetcherContentSource(fetcher)))
            for (index, source) in sources.enumerated() {
                for limit in [full / 2, full - 1, full] {
                    let fits = try await decoded.validateBlockSize(
                        spec: sizeSpec(limit), fetcher: source
                    )
                    XCTAssertEqual(fits, full <= limit, "\(name) source \(index) limit \(limit)")
                }
            }
        }
    }

    // MARK: - A peer cannot make a valid block look oversized

    func testGarbageBytesUnderACountedCIDAreNotAVerdict() async throws {
        let fetcher = StorableFetcher()
        let transaction = contentTransaction(nonce: 0, payloadBytes: 512)
        let block = try await buildAndStoreGenesis(
            spec: sizeSpec(1_000_000), transactions: [transaction],
            timestamp: 1, target: UInt256.max, fetcher: fetcher
        )
        let full = try await fullClosureSize(of: block, fetcher: fetcher)
        let decoded = try XCTUnwrap(Block(data: XCTUnwrap(block.toData())))
        let garbage = Data(repeating: 0x5a, count: full * 8)
        for forged in [try VolumeImpl<Transaction>(node: transaction).rawCID, transaction.body.rawCID] {
            do {
                _ = try await decoded.validateBlockSize(
                    spec: sizeSpec(full),
                    fetcher: ForgingFetcher(base: fetcher, forged: [forged: garbage])
                )
                XCTFail("unverified bytes must not complete the size check")
            } catch {
                XCTAssertFalse(error is BlockContentSizeError)
                XCTAssertFalse(ChainLevel.isDeterministicInvalidityForTesting(
                    ChainLevel.classifyValidationFailureForTesting(error)
                ))
            }
        }
    }

    func testContentServedBesideTheClosureIsNotCounted() async throws {
        let fetcher = StorableFetcher()
        let block = try await buildAndStoreGenesis(
            spec: sizeSpec(1_000_000),
            transactions: [contentTransaction(nonce: 0, payloadBytes: 512)],
            timestamp: 1, target: UInt256.max, fetcher: fetcher
        )
        let full = try await fullClosureSize(of: block, fetcher: fetcher)
        let decoded = try XCTUnwrap(Block(data: XCTUnwrap(block.toData())))
        // A source that pads every answer with a large member nobody asked for.
        let padding = try HeaderImpl(node: PublicKey(key: String(repeating: "p", count: full * 8)))
        let padded = PaddingSource(
            base: FetcherContentSource(fetcher),
            padding: [padding.rawCID: try XCTUnwrap(padding.node?.toData())]
        )
        let fits = try await decoded.validateBlockSize(
            spec: sizeSpec(full), fetcher: CoalescingFetcher(padded)
        )
        XCTAssertTrue(fits)
    }

    // MARK: - An oversized block is decided without its whole closure

    func testOversizedTransactionIsDecidedBeforeItsBodyIsRequested() async throws {
        let fetcher = StorableFetcher()
        let transaction = contentTransaction(nonce: 0, payloadBytes: 50_000)
        let block = try await buildAndStoreGenesis(
            spec: sizeSpec(1_000_000), transactions: [transaction],
            timestamp: 1, target: UInt256.max, fetcher: fetcher
        )
        let decoded = try XCTUnwrap(Block(data: XCTUnwrap(block.toData())))
        let recording = RecordingFetcher(base: fetcher)
        let fits = try await decoded.validateBlockSize(spec: sizeSpec(10_000), fetcher: recording)
        XCTAssertFalse(fits)
        let requested = await recording.requested
        XCTAssertTrue(requested.contains(try VolumeImpl<Transaction>(node: transaction).rawCID))
        XCTAssertFalse(requested.contains(transaction.body.rawCID))
    }

    func testOversizedBlockIsDecidedAfterResolvingAboutTheLimit() async throws {
        let fetcher = StorableFetcher()
        let block = try await buildAndStoreGenesis(
            spec: ChainSpec.test(maxNumberOfTransactionsPerBlock: 1_000),
            transactions: (0..<300).map { contentTransaction(nonce: $0, payloadBytes: 400) },
            timestamp: 1, target: UInt256.max, fetcher: fetcher
        )
        let full = try await fullClosureSize(of: block, fetcher: fetcher)
        let decoded = try XCTUnwrap(Block(data: XCTUnwrap(block.toData())))
        // One fetch at a time, abandoned on cancellation: what this serves is
        // what a bounded acquisition downloads.
        let serial = SerialFetcher(base: fetcher)
        let limit = full / 20
        let fits = try await decoded.validateBlockSize(spec: sizeSpec(limit), fetcher: serial)
        XCTAssertFalse(fits)
        let served = await serial.servedBytes
        XCTAssertGreaterThan(served, limit - (try XCTUnwrap(block.toData())).count)
        XCTAssertLessThan(served, full / 4, "served \(served) of \(full), limit \(limit)")
    }

    // MARK: - Acquisition and admission

    func testStoreBlockStopsAtTheChainsLimitAndStoresNothing() async throws {
        let source = StorableFetcher()
        let transaction = contentTransaction(nonce: 0, payloadBytes: 50_000)
        let block = try await buildAndStoreGenesis(
            spec: sizeSpec(10_000), transactions: [transaction],
            timestamp: 1, target: UInt256.max, fetcher: source
        )
        let withoutBody = HidingFetcher(base: source, hidden: [transaction.body.rawCID])
        let destination = StorableFetcher()
        do {
            try await BlockHeader(rawCID: BlockHeader(node: block).rawCID)
                .storeBlock(fetcher: withoutBody, storer: destination)
            XCTFail("an oversized block is not stored")
        } catch {
            XCTAssertEqual(error as? BlockContentSizeError, .exceedsLimit)
        }
        XCTAssertTrue(destination.entries.isEmpty)
    }

    /// The block's content exceeds its chain's limit and part of it cannot be
    /// had at all: execution still proves the block invalid.
    func testConnectProvesAnOversizedBlockInvalidWithoutItsWholeClosure() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: sizeSpec(10_000), timestamp: 1_000, target: UInt256.max, fetcher: fetcher
        )
        let transaction = contentTransaction(nonce: 0, payloadBytes: 50_000)
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [transaction],
            timestamp: 2_000, target: UInt256.max, fetcher: fetcher
        )
        let blockHash = try BlockHeader(node: block).rawCID
        var tree = try await TreeDriver.tree(
            genesis: genesis, context: testChainContext(), fetcher: fetcher
        )
        let inserted = try await TreeDriver.insert(block, into: &tree, fetcher: fetcher)
        XCTAssertNotNil(inserted.update, "\(inserted)")

        let withoutBody = HidingFetcher(base: fetcher, hidden: [transaction.body.rawCID])
        for source: any Fetcher in [withoutBody, fetcher] {
            let job = try XCTUnwrap(tree.connectJob(for: blockHash))
            let verdict = await ChainTree.connect(job, fetcher: source)
            XCTAssertTrue(verdict.provesInvalid, "\(String(describing: verdict.retryFailure))")
        }
    }

    // MARK: - Fixtures

    private func generatedBlocks(fetcher: StorableFetcher) async throws -> [(String, Block)] {
        let spec = ChainSpec.test(maxNumberOfTransactionsPerBlock: 1_000)
        func genesis(_ transactions: [Transaction], children: [String: Block] = [:], at timestamp: Int64) async throws -> Block {
            try await buildAndStoreGenesis(
                spec: spec, transactions: transactions, children: children,
                timestamp: timestamp, target: UInt256.max, fetcher: fetcher
            )
        }
        let huge = contentTransaction(nonce: 0, payloadBytes: 20_000)
        let small = (1...40).map { contentTransaction(nonce: $0, payloadBytes: 64) }
        // Two transaction Volumes over one body: the body counts once.
        let sharedBody = [
            Transaction(signatures: ["a": "1"], body: huge.body),
            Transaction(signatures: ["b": "2"], body: huge.body),
        ]
        let empty = try await genesis([], at: 1)
        return [
            ("empty", empty),
            ("one huge", try await genesis([huge], at: 2)),
            ("many small", try await genesis(small, at: 3)),
            ("duplicate", try await genesis([huge, huge], at: 4)),
            ("shared body", try await genesis(sharedBody, at: 5)),
            ("mixed with children", try await genesis([huge] + small, children: ["Child": empty], at: 6)),
            ("ordinary", try await buildAndStoreBlock(
                previous: empty, transactions: small, timestamp: 7,
                target: UInt256.max, fetcher: fetcher
            )),
        ]
    }

    /// The rule stated without any limit: every unique CID of the block's
    /// root Volume boundary and of every transaction Volume, over the whole
    /// closure.
    private func fullClosureEntries(of block: Block, fetcher: any Fetcher) async throws -> [String: Data] {
        let resolved = try await BlockHeader(node: block).resolve(
            paths: [
                [TRANSACTIONS_PROPERTY]: .recursive,
                [CHILDREN_PROPERTY]: .targeted,
            ],
            fetcher: fetcher
        )
        let closure = StorableFetcher()
        try await resolved.store(paths: [[TRANSACTIONS_PROPERTY]: .recursive], storer: closure)
        return closure.entries
    }

    private func fullClosureSize(of block: Block, fetcher: any Fetcher) async throws -> Int {
        try await fullClosureEntries(of: block, fetcher: fetcher).values.reduce(0) { $0 + $1.count }
    }

    private func sizeSpec(_ maxBlockSize: Int) -> ChainSpec {
        ChainSpec.test(maxBlockSize: maxBlockSize, initialReward: 1, halvingInterval: 1_000, halfLife: 10)
    }

    private func contentTransaction(nonce: Int, payloadBytes: Int) -> Transaction {
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [], receiptActions: [],
            withdrawalActions: [], signers: [], nonce: UInt64(nonce), chainPath: ["Nexus"]
        )
        return Transaction(
            signatures: ["fixture": String(repeating: "x", count: payloadBytes)],
            body: try! HeaderImpl(node: body)
        )
    }
}

/// Answers each CID after a delay fixed by the seed, so sibling fetches
/// complete in a different order per seed.
private struct JitterFetcher: Fetcher {
    let base: any Fetcher
    let seed: Int

    func fetch(rawCid: String) async throws -> Data {
        let spread = rawCid.utf8.reduce(UInt64(seed) &+ 1) { ($0 &* 31) &+ UInt64($1) }
        try await Task.sleep(nanoseconds: (spread % 5) * 300_000)
        return try await base.fetch(rawCid: rawCid)
    }
}

private struct ForgingFetcher: Fetcher {
    let base: any Fetcher
    let forged: [String: Data]

    func fetch(rawCid: String) async throws -> Data {
        if let data = forged[rawCid] { return data }
        return try await base.fetch(rawCid: rawCid)
    }
}

private struct HidingFetcher: Fetcher {
    let base: any Fetcher
    let hidden: Set<String>

    func fetch(rawCid: String) async throws -> Data {
        if hidden.contains(rawCid) { throw cashew.FetcherError.notFound(rawCid) }
        return try await base.fetch(rawCid: rawCid)
    }
}

private struct PaddingSource: ContentSource {
    let base: any ContentSource
    let padding: [String: Data]

    func fetch(_ cids: Set<String>) async -> [String: Data] {
        await base.fetch(cids).merging(padding) { requested, _ in requested }
    }
}

private actor RecordingFetcher: Fetcher {
    private let base: any Fetcher
    private(set) var requested: Set<String> = []

    init(base: any Fetcher) { self.base = base }

    func fetch(rawCid: String) async throws -> Data {
        requested.insert(rawCid)
        return try await base.fetch(rawCid: rawCid)
    }
}

private actor SerialFetcher: Fetcher {
    private let base: any Fetcher
    private var busy = false
    private(set) var servedBytes = 0

    init(base: any Fetcher) { self.base = base }

    func fetch(rawCid: String) async throws -> Data {
        while busy { try await Task.sleep(nanoseconds: 200_000) }
        busy = true
        defer { busy = false }
        try await Task.sleep(nanoseconds: 2_000_000)
        let data = try await base.fetch(rawCid: rawCid)
        servedBytes += data.count
        return data
    }
}
