import cashew
import Foundation

/// A block's commitments to its child chains: directory → child block, in
/// one flat node. Every entry travels with any proof of one child, so a
/// child's carriage is verified against the whole index and its absence
/// from a block is decided by the same node; below about a hundred children
/// the radix trie this replaces shipped the same entries and cost a node
/// per child on top.
///
/// Encoded as the sorted array of entries, so the same commitments always
/// produce the same bytes; decoding refuses an unsorted, repeated, or empty
/// directory, so one CID names one index.
public struct ChildIndex: Node, Hashable {
    public let entries: [String: VolumeImpl<Block>]

    public init(entries: [String: VolumeImpl<Block>] = [:]) {
        self.entries = entries
    }

    public var count: Int { entries.count }

    public subscript(directory: String) -> VolumeImpl<Block>? {
        entries[directory]
    }

    public func inserting(_ child: VolumeImpl<Block>, at directory: String) -> ChildIndex {
        var updated = entries
        updated[directory] = child
        return ChildIndex(entries: updated)
    }

    // MARK: Node

    public func get(property: PathSegment) -> (any Header)? {
        entries[property]
    }

    public func properties() -> Set<PathSegment> {
        Set(entries.keys)
    }

    public func set(properties: [PathSegment: any Header]) -> ChildIndex {
        var updated = entries
        for (directory, header) in properties {
            guard let child = header as? VolumeImpl<Block> else { continue }
            updated[directory] = child
        }
        return ChildIndex(entries: updated)
    }

    // MARK: Codable

    private struct Entry: Codable {
        let key: String
        let value: VolumeImpl<Block>
    }

    enum CodingKeys: String, CodingKey {
        case entries
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let sorted = entries.keys.sorted().map { Entry(key: $0, value: entries[$0]!) }
        try container.encode(sorted, forKey: .entries)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([Entry].self, forKey: .entries)
        var entries: [String: VolumeImpl<Block>] = [:]
        var previous: String?
        for entry in decoded {
            guard !entry.key.isEmpty, previous.map({ $0 < entry.key }) ?? true else {
                throw DecodingError.dataCorruptedError(
                    forKey: .entries,
                    in: container,
                    debugDescription: "child index entries must be sorted, distinct and named"
                )
            }
            entries[entry.key] = entry.value
            previous = entry.key
        }
        self.entries = entries
    }

    public static func == (lhs: ChildIndex, rhs: ChildIndex) -> Bool {
        lhs.entries.mapValues(\.rawCID) == rhs.entries.mapValues(\.rawCID)
    }

    public func hash(into hasher: inout Hasher) {
        for directory in entries.keys.sorted() {
            hasher.combine(directory)
            hasher.combine(entries[directory]!.rawCID)
        }
    }
}
