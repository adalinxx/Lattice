import XCTest
import UInt256
@testable import Lattice

/// Arrival order must not change the answer.
///
/// §9.9 requires recovery to reproject "identically, independent of arrival
/// order". That is ultimately a property of `ChainState`, which this accumulator
/// is not yet wired into, so this file proves the narrower thing the structure
/// can promise on its own — and deliberately the narrower thing that matters
/// most here.
///
/// The same final graph reaches the accumulator by two routes:
///
///   - **sibling first**: the losing sibling arrives as the only child, so it
///     briefly IS the tip and is on-spine; the canonical block then displaces
///     it. This takes the freeze-and-join path.
///   - **canonical first**: the canonical block is already on the spine, so the
///     sibling arrives off-spine under a fork. No block leaves; instead the
///     spine suffix above the fork must be corrected.
///
/// Those two routes are precisely where a height-based correction rule and an
/// ancestor-based one disagree. A height test passes the whole merged-mining
/// measurement — which delivers sibling-first — and is silently wrong on the
/// other order. Asserting the two routes agree is what closes that.
final class SpineWorkAccumulatorOrderTests: XCTestCase {
    private func work(_ value: UInt64) -> WorkSum { WorkSum(UInt256(value)) }

    /// Build root -> main chain with one losing sibling at each height, by the
    /// given delivery order, and return each block's final subtree total.
    private func totals(siblingFirst: Bool, heights: Int) -> [String: WorkSum] {
        var accumulator = SpineWorkAccumulator.empty
        accumulator.apply(
            work: work(4),
            joining: [.init(hash: "root", base: work(4))]
        )
        var spine = ["root"]
        var previous = "root"
        var tracked = ["root"]

        for height in 1...heights {
            let side = "side-\(height)"
            let main = "main-\(height)"
            tracked.append(side)
            tracked.append(main)

            if siblingFirst {
                // The sibling is the only child, so it becomes the tip.
                accumulator.apply(
                    work: work(1),
                    joining: [.init(hash: side, base: work(1))]
                )
                spine.append(side)
                // The canonical block displaces it: it is both the
                // over-credited non-ancestor and the leaver, and the freeze
                // settles both.
                accumulator.apply(
                    work: work(4),
                    leaving: [side],
                    correctingNonAncestors: [side],
                    joining: [.init(hash: main, base: work(4))]
                )
                spine.removeLast()
                spine.append(main)
            } else {
                // The canonical block extends the tip: nothing to correct.
                accumulator.apply(
                    work: work(4),
                    joining: [.init(hash: main, base: work(4))]
                )
                spine.append(main)
                // The sibling now arrives OFF-spine, under the fork at
                // `previous`. Everything on the spine above that fork is not an
                // ancestor of it and must be corrected; the sibling keeps its
                // own total directly.
                let forkIndex = spine.firstIndex(of: previous) ?? 0
                let aboveFork = Array(spine[(forkIndex + 1)...])
                accumulator.apply(
                    work: work(1),
                    correctingNonAncestors: aboveFork
                )
                accumulator.setDirect(side, total: work(1))
            }
            previous = main
        }

        var result: [String: WorkSum] = [:]
        for hash in tracked {
            result[hash] = accumulator.subtreeWork(hash) ?? .zero
        }
        return result
    }

    func testSiblingFirstAndCanonicalFirstAgree() {
        let heights = 12
        let a = totals(siblingFirst: true, heights: heights)
        let b = totals(siblingFirst: false, heights: heights)

        XCTAssertEqual(
            Set(a.keys),
            Set(b.keys),
            "both orders must track the same blocks"
        )
        for hash in a.keys.sorted() {
            XCTAssertEqual(
                a[hash],
                b[hash],
                "arrival order changed the subtree total at \(hash)"
            )
        }

        // And both must match the graph's own arithmetic: at height h the
        // canonical block's subtree holds every later canonical block and every
        // later sibling.
        for height in 1...heights {
            let later = heights - height
            let expected = work(4) + work(UInt64(later) * 5)
            XCTAssertEqual(
                a["main-\(height)"],
                expected,
                "canonical subtree total at height \(height)"
            )
        }
        XCTAssertEqual(
            a["root"],
            work(4) + work(UInt64(heights) * 5),
            "the root's subtree is the whole graph"
        )
        for height in 1...heights {
            XCTAssertEqual(
                a["side-\(height)"],
                work(1),
                "a losing sibling holds only its own work, whenever it arrived"
            )
        }
    }
}
