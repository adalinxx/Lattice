import XCTest
import UInt256
@testable import Lattice

final class CIDIdentityTests: XCTestCase {
    /// CIDv1 encoded in multibase base16 rather than Lattice's canonical
    /// base32. It names the exact same raw CID as `canonicalCID` below.
    private let alternateCID =
        "f01711220e9eb6c60800df90fc8e237ed53246f396e87579aba406aaa7976a056859ee22d"

    private func contribution(
        id: String,
        work: UInt64
    ) -> VerifiedWorkContribution {
        try! JSONDecoder().decode(
            VerifiedWorkContribution.self,
            from: Data("{\"id\":\"\(id)\",\"work\":\"0x\(String(work, radix: 16))\"}".utf8)
        )
    }

    func testCanonicalCIDIdentityNormalizesEquivalentAlternateMultibase() throws {
        let canonicalCID = try XCTUnwrap(CIDIdentity.canonicalString(alternateCID))

        XCTAssertNotEqual(canonicalCID, alternateCID)
        XCTAssertTrue(CIDIdentity.isCanonical(canonicalCID))
        XCTAssertFalse(CIDIdentity.isCanonical(alternateCID))
    }

    func testInheritedAliasCannotBecomeASecondPhysicalGrind() throws {
        let canonicalCID = try XCTUnwrap(CIDIdentity.canonicalString(alternateCID))
        let snapshot = InheritedWorkSnapshot(
            revision: 1,
            workByBlock: [
                canonicalCID: WorkMeasure([
                    contribution(id: canonicalCID, work: 7),
                    contribution(id: alternateCID, work: 11),
                ]),
            ]
        )
        XCTAssertTrue(snapshot.hasCanonicalCIDs)
        XCTAssertEqual(snapshot.blockCIDs, [canonicalCID])
        XCTAssertEqual(
            snapshot.work(forBlock: alternateCID).total,
            WorkSum(UInt256(11))
        )
    }

}
