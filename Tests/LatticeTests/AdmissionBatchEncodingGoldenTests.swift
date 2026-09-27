import Foundation
import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

/// The durable on-disk shape of `BlockImportBatch`: a fixed set of batches
/// encoded to JSON bytes, pinned as hex. Recovery replays these bytes from a
/// node's fact log, so a refactor that renames a coding key, reorders an enum
/// payload, or changes a value's presentation would strand every existing log.
struct AdmissionBatchEncodingGolden: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let name: String
        let byteCount: Int
        let hex: String
        /// `ChainFactID` of each fact — the identity the fact log dedups by —
        /// encoded with the same encoder, as its JSON text (ASCII bytes).
        let factIDs: [String]
    }

    let entries: [Entry]

    static func diff(expected: AdmissionBatchEncodingGolden, actual: AdmissionBatchEncodingGolden) -> [String] {
        var lines: [String] = []
        let actualByName = Dictionary(uniqueKeysWithValues: actual.entries.map { ($0.name, $0) })
        for entry in expected.entries {
            guard let other = actualByName[entry.name] else {
                lines.append("\(entry.name): missing from actual")
                continue
            }
            var pairs: [(field: String, expected: String, actual: String)] = [
                ("byteCount", "\(entry.byteCount)", "\(other.byteCount)"),
                ("factIDs", "\(entry.factIDs)", "\(other.factIDs)"),
            ]
            if entry.hex != other.hex {
                let expectedText = String(decoding: Data(hex: entry.hex) ?? Data(), as: UTF8.self)
                let actualText = String(decoding: Data(hex: other.hex) ?? Data(), as: UTF8.self)
                pairs.append(("json", expectedText, actualText))
            }
            lines += GoldenFile.fieldDiff(entry.name, pairs)
        }
        for name in Set(actualByName.keys).subtracting(expected.entries.map(\.name)).sorted() {
            lines.append("\(name): unexpected in actual")
        }
        return lines
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hexDigits: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

final class AdmissionBatchEncodingGoldenTests: XCTestCase {
    static let goldenName = "admission-batch-encoding.json"

    private func cid(_ seed: String) -> String { testCID("batch-encoding/\(seed)") }

    /// Sorted keys, unescaped slashes, no whitespace — the configuration the
    /// node's fact log writes with (lattice-node `NodeStore`), so these bytes
    /// are the bytes recovery reads. What this pins is the coding-key set and
    /// every value's form; a fixture key carries a "/" so escaping drift shows.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// One batch of every durable shape the reducer accepts.
    private func fixedBatches() throws -> [(name: String, batch: BlockImportBatch)] {
        let block = cid("block")
        let identity = AttributedRunIdentity(carrierBlockHash: cid("committer"), directory: "Child")
        let identityID = try XCTUnwrap(identity.contributionID, "attributed-run identity has no CID")
        return [
            ("blockWithWorkAndValidation", BlockImportBatch(facts: [
                .block(ChainBlockFact(
                    blockHash: block,
                    parentBlockHash: cid("parent"),
                    blockHeight: 7,
                    postStateCID: cid("post"),
                    prevStateCID: cid("prev"),
                    specCID: cid("spec"),
                    target: UInt256(1_000).toHexString(),
                    nextTarget: UInt256(999).toHexString(),
                    timestamp: 1_700_000_000_123,
                    stateDiff: StateDiff(replaced: [cid("replaced"): 1], created: [cid("created"): 2]),
                    childCommitments: [
                        "Child": cid("child-block"),
                        "Other": cid("other-block"),
                        "With/Slash": cid("slash-block"),
                    ]
                )),
                .work(ChainWorkFact(
                    blockHash: block,
                    contribution: VerifiedWorkContribution(id: cid("grind"), work: UInt256(UInt64.max) + UInt256(1))
                )),
                .validation(ChainValidationFact(blockHash: block)),
            ])),
            ("genesisWithoutCommitments", BlockImportBatch(facts: [
                .block(ChainBlockFact(
                    blockHash: cid("genesis"),
                    parentBlockHash: nil,
                    blockHeight: 0,
                    postStateCID: cid("genesis-post"),
                    prevStateCID: cid("genesis-prev"),
                    specCID: cid("spec"),
                    target: UInt256.max.toHexString(),
                    nextTarget: UInt256.max.toHexString(),
                    timestamp: 0,
                    stateDiff: .empty
                )),
                .work(ChainWorkFact(
                    blockHash: cid("genesis"),
                    contribution: VerifiedWorkContribution(id: cid("genesis"), work: UInt256(1))
                )),
            ])),
            ("attributedRun", BlockImportBatch(facts: [
                .work(ChainWorkFact(
                    blockHash: block,
                    contribution: VerifiedWorkContribution(id: identityID, work: UInt256(42)),
                    attributedRun: identity
                )),
            ])),
            ("exclusion", BlockImportBatch(facts: [
                .exclusion(ChainExclusionFact(blockHash: block)),
            ])),
            ("validation", BlockImportBatch.validation(blockHash: block)),
        ]
    }

    func testDurableBatchBytesMatchGolden() throws {
        let entries = try fixedBatches().map { fixture in
            let bytes = try Self.encoder().encode(fixture.batch)
            return AdmissionBatchEncodingGolden.Entry(
                name: fixture.name,
                byteCount: bytes.count,
                hex: bytes.hexDigits,
                factIDs: try fixture.batch.facts.map {
                    String(decoding: try Self.encoder().encode($0.id), as: UTF8.self)
                }
            )
        }
        try GoldenFile.assert(
            AdmissionBatchEncodingGolden(entries: entries),
            matches: Self.goldenName,
            diff: AdmissionBatchEncodingGolden.diff
        )
    }

    /// The pinned bytes decode to the fixed batches, and re-encode to the same
    /// bytes — so a log written by this version is readable by the next.
    func testGoldenBytesRoundTripThroughDecodeAndReencode() throws {
        let data = try XCTUnwrap(FileManager.default.contents(atPath: GoldenFile.url(Self.goldenName).path))
        let golden = try JSONDecoder().decode(AdmissionBatchEncodingGolden.self, from: data)
        let fixtures = Dictionary(uniqueKeysWithValues: try fixedBatches().map { ($0.name, $0.batch) })
        XCTAssertEqual(Set(golden.entries.map(\.name)), Set(fixtures.keys))
        for entry in golden.entries {
            let bytes = try XCTUnwrap(Data(hex: entry.hex), "\(entry.name): golden hex is malformed")
            let decoded = try JSONDecoder().decode(BlockImportBatch.self, from: bytes)
            XCTAssertEqual(decoded, fixtures[entry.name], "\(entry.name): decoded batch")
            XCTAssertEqual(try Self.encoder().encode(decoded), bytes, "\(entry.name): re-encoded bytes")
        }
    }
}
