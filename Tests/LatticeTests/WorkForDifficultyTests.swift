import XCTest
@testable import Lattice
import UInt256

//: the single public work-from-target primitive.
final class WorkForDifficultyTests: XCTestCase {

    func testZeroDifficultyYieldsZeroWork() {
        XCTAssertEqual(workForTarget(.zero), .zero,
                       "zero target must return zero work, not trap on divide-by-zero")
    }

    func testNonZeroDifficultyIsMaxOverDifficulty() {
        XCTAssertEqual(workForTarget(UInt256(2)), UInt256.max / 2)
    }
}
