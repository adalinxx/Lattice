import XCTest
@testable import Lattice
import Foundation

final class ChildBlockProofCoreTests: XCTestCase {
    private func proof(
        root: String = "bafyroot",
        path: [String] = ["Nexus", "ChildA"],
        entries: [(String, Data)] = [("bafyroot", Data([1, 2, 3])), ("bafychild", Data([4, 5]))]
    ) -> ChildBlockProof {
        ChildBlockProof(rootCID: root, directoryPath: path, entries: entries)
    }

    func test_serialize_roundTrips() throws {
        let p = proof()
        guard let back = ChildBlockProof.deserialize(try p.serialize()) else {
            return XCTFail("deserialize failed")
        }
        XCTAssertEqual(back.rootCID, p.rootCID)
        XCTAssertEqual(back.directoryPath, p.directoryPath)
        XCTAssertEqual(back.entries.map(\.cid), p.entries.map(\.cid))
        XCTAssertEqual(back.entries.map(\.data), p.entries.map(\.data))
    }

    func test_deserialize_rejectsTruncated() throws {
        let bytes = try proof().serialize()
        XCTAssertNil(ChildBlockProof.deserialize(bytes.prefix(bytes.count - 1)),
                     "a truncated proof must not decode")
        XCTAssertNil(ChildBlockProof.deserialize(Data()), "empty input must not decode")
        XCTAssertNil(
            ChildBlockProof.deserialize(bytes + Data([0])),
            "trailing bytes must not produce a second encoding of the same proof"
        )
    }

    func test_serializeRejectsOversizedFields() {
        let oversized = String(repeating: "x", count: Int(UInt16.max) + 1)
        XCTAssertThrowsError(
            try proof(root: oversized).serialize()
        ) { error in
            XCTAssertEqual(error as? ChildProofSerializationError, .valueTooLarge)
        }
    }

    func test_deserializeRejectsNonCanonicalEntryOrder() throws {
        var nonCanonical = try proof(root: "r", path: [], entries: [
            ("a", Data([1])),
            ("b", Data([2]))
        ]).serialize()
        nonCanonical.swapAt(9, 17)

        XCTAssertNil(ChildBlockProof.deserialize(nonCanonical))
    }

    func test_composing_concatenatesDirectoryPath() {
        let hop1 = proof(root: "bafyA", path: ["Nexus", "A"], entries: [("bafyA", Data([1]))])
        let hop2 = proof(root: "bafyB", path: ["A", "B"], entries: [("bafyB", Data([2]))])
        let composed = hop1.composing(hop: hop2)
        XCTAssertEqual(composed.directoryPath.first, "Nexus")
        XCTAssertEqual(composed.directoryPath.last, "B")
    }

    func test_composingDeduplicatesIdenticalEntries() {
        let shared = ("shared", Data([1]))
        let upstream = proof(entries: [shared])
        let hop = proof(root: "shared", path: ["Child"], entries: [shared])

        let composed = upstream.composing(hop: hop)

        XCTAssertEqual(composed.entries.count, 1)
    }
}
