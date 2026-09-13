import XCTest
import UInt256
@testable import Lattice

/// The accumulator on its own, against a brute-force oracle.
///
/// Fork choice is the wrong place to first learn this is wrong: a bad stamp
/// surfaces there as an unexplained path divergence. These tests hold a tiny
/// explicit tree and drive the accumulator through the admission shapes the
/// measurement found — tip extension, displacement, and a mutation at depth —
/// comparing every block's subtree total against a walk of the model after
/// every step.
final class SpineWorkAccumulatorTests: XCTestCase {
    /// The naive answer: walk the tree and add work up.
    private struct Model {
        private(set) var parentOf: [String: String?] = [:]
        private(set) var childrenOf: [String: [String]] = [:]
        private(set) var own: [String: WorkSum] = [:]
        private(set) var blocks: [String] = []

        mutating func add(_ hash: String, parent: String?, work: WorkSum) {
            blocks.append(hash)
            parentOf[hash] = parent
            childrenOf[hash] = []
            own[hash] = work
            if let parent { childrenOf[parent, default: []].append(hash) }
        }

        mutating func addWork(_ delta: WorkSum, to hash: String) {
            own[hash] = (own[hash] ?? .zero) + delta
        }

        func subtreeWork(_ hash: String) -> WorkSum {
            var total = own[hash] ?? .zero
            for child in childrenOf[hash] ?? [] {
                total = total + subtreeWork(child)
            }
            return total
        }

        /// Ancestors-or-self, root-ward.
        func ancestry(of hash: String) -> Set<String> {
            var result: Set<String> = [hash]
            var current = hash
            while let parent = parentOf[current] ?? nil {
                result.insert(parent)
                current = parent
            }
            return result
        }
    }

    private func work(_ value: UInt64) -> WorkSum { WorkSum(UInt256(value)) }

    /// Drive one admission, computing the leaver/correction/joiner sets from the
    /// model exactly as the rule specifies, then assert every tracked block.
    private func assertSpineTotals(
        _ accumulator: SpineWorkAccumulator,
        _ model: Model,
        _ spine: [String],
        _ event: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            accumulator.debugStampsAreInThePast,
            "\(event): a stamp is not a past value of the accumulator",
            file: file, line: line
        )
        for hash in spine {
            XCTAssertEqual(
                accumulator.subtreeWork(hash),
                model.subtreeWork(hash),
                "\(event): on-spine subtree total at \(hash)",
                file: file, line: line
            )
        }
    }

    /// Tip extension, the case the owner's directive is about: no leaver, no
    /// correction, one add and one stamp, whatever the chain length.
    func testTipExtensionIsOneAddAndOneStamp() {
        var accumulator = SpineWorkAccumulator.empty
        var model = Model()
        var spine: [String] = []

        for step in 0..<64 {
            let hash = "b-\(step)"
            let parent = step == 0 ? nil : "b-\(step - 1)"
            let w = work(UInt64(step % 5 + 1))
            model.add(hash, parent: parent, work: w)

            // Every existing spine block is an ancestor of a tip extension, so
            // nothing is corrected and nothing leaves.
            XCTAssertTrue(accumulator.apply(
                work: w,
                joining: [.init(hash: hash, base: w)]
            ), "step \(step): apply")
            spine.append(hash)
            assertSpineTotals(accumulator, model, spine, "tip extension \(step)")
        }
    }

    /// The measured displacement: a losing sibling is briefly the tip, then the
    /// canonical block takes its place. 400 of these per 400 heights in the
    /// merged-mining sync, so this is the hot path, not a corner.
    func testDisplacementFreezesTheLeaverAtItsPreAdmissionTotal() {
        var accumulator = SpineWorkAccumulator.empty
        var model = Model()

        model.add("root", parent: nil, work: work(4))
        XCTAssertTrue(accumulator.apply(
            work: work(4),
            joining: [.init(hash: "root", base: work(4))]
        ))
        var spine = ["root"]
        var previous = "root"

        for height in 1...16 {
            // The sibling arrives first and becomes the tip: a tip extension.
            let side = "side-\(height)"
            model.add(side, parent: previous, work: work(1))
            XCTAssertTrue(accumulator.apply(
                work: work(1),
                joining: [.init(hash: side, base: work(1))]
            ))
            spine.append(side)
            assertSpineTotals(accumulator, model, spine, "sibling tip \(height)")

            // Then the canonical block displaces it. The sibling is both the
            // over-credited non-ancestor and the leaver, so the freeze handles
            // both — and it must freeze at the PRE-increment value, since the
            // canonical block is not its descendant.
            let main = "main-\(height)"
            model.add(main, parent: previous, work: work(4))
            XCTAssertTrue(accumulator.apply(
                work: work(4),
                leaving: [side],
                correctingNonAncestors: [side],
                joining: [.init(hash: main, base: work(4))]
            ), "height \(height): displacement")
            spine.removeLast()
            spine.append(main)
            previous = main

            assertSpineTotals(accumulator, model, spine, "displacement \(height)")
            XCTAssertEqual(
                accumulator.subtreeWork(side),
                model.subtreeWork(side),
                "height \(height): the frozen leaver keeps its own total"
            )
        }
    }

    /// A mutation at depth — the late securing contribution. Every spine block
    /// ABOVE it is a descendant, not an ancestor, so every one of them is
    /// over-credited and must be corrected. This is the O(distance from tip)
    /// case, and the measurement says it is rare.
    func testDepthMutationCorrectsTheSuffixAboveIt() {
        var accumulator = SpineWorkAccumulator.empty
        var model = Model()
        var spine: [String] = []
        for step in 0..<24 {
            let hash = "b-\(step)"
            let parent = step == 0 ? nil : "b-\(step - 1)"
            model.add(hash, parent: parent, work: work(2))
            XCTAssertTrue(accumulator.apply(
                work: work(2),
                joining: [.init(hash: hash, base: work(2))]
            ))
            spine.append(hash)
        }

        let target = "b-5"
        let extra = work(37)
        model.addWork(extra, to: target)
        // Ancestors-or-self of the target keep the credit; everything above it
        // on the spine is a descendant and must not.
        let ancestry = model.ancestry(of: target)
        let nonAncestors = spine.filter { !ancestry.contains($0) }
        XCTAssertEqual(
            nonAncestors.count,
            18,
            "the suffix above the mutation is what costs distance-from-tip"
        )
        XCTAssertTrue(accumulator.apply(
            work: extra,
            correctingNonAncestors: nonAncestors
        ))
        assertSpineTotals(accumulator, model, spine, "depth mutation")
    }

    /// Stamping before the increment instead of after double-counts a block's
    /// own work. Asserted directly, because the ordering reads as arbitrary and
    /// is exactly the kind of line a later tidy-up would flip.
    func testStampIsTakenAfterTheIncrement() {
        var accumulator = SpineWorkAccumulator.empty
        accumulator.apply(
            work: work(7),
            joining: [.init(hash: "only", base: work(7))]
        )
        XCTAssertEqual(
            accumulator.subtreeWork("only"),
            work(7),
            "a lone block's total is its own work, not twice it"
        )
    }

    /// A malformed call must leave the accumulator untouched: there is no undo.
    func testMalformedApplyLeavesStateUnchanged() {
        var accumulator = SpineWorkAccumulator.empty
        accumulator.apply(
            work: work(3),
            joining: [.init(hash: "a", base: work(3))]
        )
        let before = accumulator.debugAccumulator
        XCTAssertFalse(
            accumulator.apply(work: work(5), leaving: ["never-seen"]),
            "a leaver that is not on the spine must be refused"
        )
        XCTAssertEqual(
            accumulator.debugAccumulator,
            before,
            "a refused apply must not have moved the accumulator"
        )
        XCTAssertEqual(accumulator.subtreeWork("a"), work(3))
    }
}
