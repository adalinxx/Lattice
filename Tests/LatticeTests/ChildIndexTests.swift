import XCTest
@testable import Lattice
import UInt256
import cashew

/// The child index is one flat node: its bytes are canonical, a proof of one
/// child carries the whole index and nothing else, and the block reads it
/// with a single fetch.
final class ChildIndexTests: XCTestCase {

    private func spec() -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            halfLife: 10
        )
    }

    func testEncodingIsSortedAndRoundTrips() throws {
        let a = try VolumeImpl<Block>(node: makeGenesisBlock(spec: spec(), nonce: 1))
        let b = try VolumeImpl<Block>(node: makeGenesisBlock(spec: spec(), nonce: 2))
        let forward = ChildIndex(entries: ["Payments": a, "Games": b])
        let reversed = ChildIndex(entries: ["Games": b, "Payments": a])
        let forwardData = try XCTUnwrap(forward.toData())
        XCTAssertEqual(forwardData, reversed.toData(), "insertion order does not reach the bytes")
        let decoded = try XCTUnwrap(ChildIndex(data: forwardData))
        XCTAssertEqual(decoded.entries.mapValues(\.rawCID), forward.entries.mapValues(\.rawCID))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded["Games"]?.rawCID, b.rawCID)
        XCTAssertEqual(
            try HeaderImpl(node: forward).rawCID,
            try HeaderImpl(node: reversed).rawCID
        )
    }

    /// One CID names one index: unsorted, repeated, or unnamed entries are not
    /// an index, whatever bytes claim to be.
    func testDecodingRefusesUnsortedRepeatedOrUnnamedEntries() throws {
        let a = try VolumeImpl<Block>(node: makeGenesisBlock(spec: spec(), nonce: 1))
        func encoded(_ keys: [String]) throws -> Data {
            struct Entry: Codable { let key: String; let value: VolumeImpl<Block> }
            struct Wire: Codable { let entries: [Entry] }
            return try DagCBOR.encode(Wire(entries: keys.map { Entry(key: $0, value: a) }))
        }
        XCTAssertNotNil(ChildIndex(data: try encoded(["A", "B"])))
        XCTAssertNil(ChildIndex(data: try encoded(["B", "A"])), "unsorted")
        XCTAssertNil(ChildIndex(data: try encoded(["A", "A"])), "repeated")
        XCTAssertNil(ChildIndex(data: try encoded([""])), "unnamed")
        XCTAssertNotNil(ChildIndex(data: try encoded([])), "an empty index is an index")
    }

    /// A proof of one child is the root block, the index, and the child: three
    /// entries, however many siblings the index holds.
    func testSingleHopProofCarriesTheWholeIndexAndNothingElse() async throws {
        let fetcher = StorableFetcher()
        let s = spec()
        let parentGenesis = try await buildAndStoreGenesis(
            spec: s, timestamp: 1_000, target: UInt256.max, fetcher: fetcher
        )
        var children: [String: Block] = [:]
        for (index, directory) in ["Alpha", "Beta", "Gamma"].enumerated() {
            let child = makeGenesisBlock(spec: s, nonce: UInt64(index + 1))
            try await VolumeImpl<Block>(node: child).storeBlock(storer: fetcher)
            children[directory] = child
        }
        let carrier = try await buildAndStoreBlock(
            previous: parentGenesis,
            children: children,
            timestamp: 2_000,
            fetcher: fetcher
        )
        let carrierHeader = try BlockHeader(node: carrier)
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Beta",
            fetcher: fetcher
        )
        XCTAssertEqual(proof.entries.count, 3, "root block, index, child block")
        XCTAssertEqual(
            Set(proof.entries.map(\.cid)),
            [carrierHeader.rawCID, carrier.children.rawCID, try BlockHeader(node: children["Beta"]!).rawCID]
        )
        let hopValue = await proof.directHop()
        let hop = try XCTUnwrap(hopValue)
        XCTAssertEqual(hop.childCID, try BlockHeader(node: children["Beta"]!).rawCID)
        // The index names every sibling, so a block read from bytes learns all
        // of its commitments from the same node the proof carried.
        let fromBytes = try await BlockHeader(rawCID: carrierHeader.rawCID).resolve(
            paths: [[CHILDREN_PROPERTY]: .targeted], fetcher: fetcher
        )
        let map = try XCTUnwrap(fromBytes.node?.children.node?.entries.mapValues(\.rawCID))
        XCTAssertEqual(Set(map.keys), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(map["Gamma"], try BlockHeader(node: children["Gamma"]!).rawCID)
    }

    /// A block read from bytes fetches its index with one request and only when
    /// it is asked for; the child blocks stay independent volumes.
    func testResolvingTheIndexFetchesOneNodeAndNoChildBlocks() async throws {
        let fetcher = StorableFetcher()
        let s = spec()
        let parentGenesis = try await buildAndStoreGenesis(
            spec: s, timestamp: 1_000, target: UInt256.max, fetcher: fetcher
        )
        let child = makeGenesisBlock(spec: s, nonce: 7)
        let carrier = try await buildAndStoreBlock(
            previous: parentGenesis,
            children: ["Solo": child],
            timestamp: 2_000,
            fetcher: fetcher
        )
        let counting = FetchCounter(backing: fetcher)
        let header = BlockHeader(rawCID: try BlockHeader(node: carrier).rawCID)
        let resolved = try await header.resolve(
            paths: [[CHILDREN_PROPERTY]: .targeted], fetcher: counting
        )
        let index = try XCTUnwrap(resolved.node?.children.node)
        XCTAssertEqual(index.count, 1)
        XCTAssertNil(index["Solo"]?.node, "the child block is not fetched")
        let fetches = await counting.count()
        XCTAssertEqual(fetches, 2, "the block and its index")
    }
}

private actor FetchCounter: Fetcher {
    private let backing: StorableFetcher
    private var fetched = 0
    init(backing: StorableFetcher) { self.backing = backing }
    func fetch(rawCid: String) async throws -> Data {
        fetched += 1
        return try await backing.fetch(rawCid: rawCid)
    }
    func count() -> Int { fetched }
}
