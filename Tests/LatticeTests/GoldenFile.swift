import Foundation
import XCTest

/// Checked-in expectations under `Tests/LatticeTests/Goldens/`.
///
/// A golden pins an observable the refactor must not move, as data: the test
/// computes the observable through public API and compares it to the file. The
/// files are located from `#filePath` so no resource declaration is needed and
/// regeneration writes straight back into the source tree.
///
/// Regeneration is deliberate: with `LATTICE_REGENERATE_GOLDENS=1` the file is
/// rewritten and the test then FAILS, so a changed expectation always shows up
/// as a reviewed diff and never as a silently green run.
enum GoldenFile {
    static let regenerateEnvironmentKey = "LATTICE_REGENERATE_GOLDENS"

    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
    }

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static var isRegenerating: Bool {
        ProcessInfo.processInfo.environment[regenerateEnvironmentKey] == "1"
    }

    /// Deterministic, reviewable encoding: sorted keys, one entry per line.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Compare `actual` against the golden `name`. `diff` renders the divergence
    /// so a failure names the block or field that moved, not two blobs.
    static func assert<T: Codable & Equatable>(
        _ actual: T,
        matches name: String,
        diff: (_ expected: T, _ actual: T) -> [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = url(name)
        let encoded = try encoder().encode(actual)
        if isRegenerating {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try encoded.write(to: url)
            XCTFail(
                "\(name) regenerated at \(url.path); review the diff, unset "
                    + "\(regenerateEnvironmentKey) and rerun",
                file: file, line: line
            )
            return
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            XCTFail(
                "missing golden \(url.path); run once with "
                    + "\(regenerateEnvironmentKey)=1 to create it, then review it",
                file: file, line: line
            )
            return
        }
        let expected = try JSONDecoder().decode(T.self, from: data)
        guard expected == actual else {
            XCTFail(
                "\(name) diverged from the checked-in golden:\n"
                    + diff(expected, actual).joined(separator: "\n"),
                file: file, line: line
            )
            return
        }
        // The values agree; the bytes must too. A hand-edited or stale file
        // that happens to decode to the right value is still not the file this
        // encoder would write, and the next regeneration would show a diff
        // nobody made.
        XCTAssertEqual(
            encoded, data,
            "\(name) decodes to the expected value but its bytes are not the "
                + "canonical encoding; regenerate with \(regenerateEnvironmentKey)=1",
            file: file, line: line
        )
    }

    /// Field-by-field lines for one record, keyed by a stable name.
    static func fieldDiff(
        _ label: String,
        _ pairs: [(field: String, expected: String, actual: String)]
    ) -> [String] {
        pairs.compactMap { pair in
            pair.expected == pair.actual
                ? nil
                : "\(label).\(pair.field): expected \(pair.expected), actual \(pair.actual)"
        }
    }
}

/// A small deterministic generator for fixture construction: no system RNG,
/// no clock, so a golden built from it is reproducible on every host.
struct GoldenRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int((next() >> 33) % UInt64(upperBound))
    }

    /// Bernoulli trial with `percent` chance of success.
    mutating func chance(_ percent: Int) -> Bool {
        nextInt(100) < percent
    }

    mutating func shuffle<Element>(_ values: inout [Element]) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            values.swapAt(index, nextInt(index + 1))
        }
    }
}
