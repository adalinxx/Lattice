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

    func test_serialize_roundTrips() {
        let p = proof()
        guard let back = ChildBlockProof.deserialize(p.serialize()) else {
            return XCTFail("deserialize failed")
        }
        XCTAssertEqual(back.rootCID, p.rootCID)
        XCTAssertEqual(back.directoryPath, p.directoryPath)
        XCTAssertEqual(back.entries.map(\.cid), p.entries.map(\.cid))
        XCTAssertEqual(back.entries.map(\.data), p.entries.map(\.data))
    }

    func test_deserialize_rejectsTruncated() {
        let bytes = proof().serialize()
        XCTAssertNil(ChildBlockProof.deserialize(bytes.prefix(bytes.count - 1)),
                     "a truncated proof must not decode")
        XCTAssertNil(ChildBlockProof.deserialize(Data()), "empty input must not decode")
    }

    func test_canonicalProofID_isOrderIndependentOverEntries() {
        let a = proof(entries: [("c1", Data([1])), ("c2", Data([2]))])
        let b = proof(entries: [("c2", Data([2])), ("c1", Data([1]))])
        XCTAssertEqual(a.canonicalProofID, b.canonicalProofID,
                       "canonical proof identity must not depend on entry order")
    }

    func test_composing_concatenatesDirectoryPath() {
        let hop1 = proof(root: "bafyA", path: ["Nexus", "A"], entries: [("bafyA", Data([1]))])
        let hop2 = proof(root: "bafyB", path: ["A", "B"], entries: [("bafyB", Data([2]))])
        let composed = hop1.composing(hop: hop2)
        XCTAssertEqual(composed.directoryPath.first, "Nexus")
        XCTAssertEqual(composed.directoryPath.last, "B")
    }
}
