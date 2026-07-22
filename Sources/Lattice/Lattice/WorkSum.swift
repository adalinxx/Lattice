import UInt256

/// An exact, growable sum of fixed-width proof-of-work contributions.
/// Individual targets remain `UInt256`; cumulative and subtree work must not
/// clamp because fork choice depends on strict ordering after every addition.
public struct WorkSum: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    private var limbs: [UInt64]

    public static let zero = WorkSum(limbs: [])

    private init(limbs: [UInt64]) {
        self.limbs = limbs
        while self.limbs.last == 0 { self.limbs.removeLast() }
    }

    public init(_ value: UInt256) {
        let words = value.words
        let wordsPerLimb = UInt64.bitWidth / UInt.bitWidth
        var parsed: [UInt64] = []
        parsed.reserveCapacity((words.count + wordsPerLimb - 1) / wordsPerLimb)
        for index in stride(from: 0, to: words.count, by: wordsPerLimb) {
            var limb = UInt64(words[index])
            for offset in 1..<min(wordsPerLimb, words.count - index) {
                limb |= UInt64(words[index + offset]) << (offset * UInt.bitWidth)
            }
            parsed.append(limb)
        }
        self.init(limbs: parsed)
    }

    public init?(hex: String) {
        guard !hex.isEmpty,
              hex.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
              }) else { return nil }

        var parsed: [UInt64] = []
        var end = hex.endIndex
        while end > hex.startIndex {
            let width = min(16, hex.distance(from: hex.startIndex, to: end))
            let start = hex.index(end, offsetBy: -width)
            guard let limb = UInt64(hex[start..<end], radix: 16) else { return nil }
            parsed.append(limb)
            end = start
        }
        self.init(limbs: parsed)
    }

    public static func < (lhs: WorkSum, rhs: WorkSum) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for index in lhs.limbs.indices.reversed() {
            if lhs.limbs[index] != rhs.limbs[index] {
                return lhs.limbs[index] < rhs.limbs[index]
            }
        }
        return false
    }

    public static func + (lhs: WorkSum, rhs: WorkSum) -> WorkSum {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var result: [UInt64] = []
        result.reserveCapacity(count + 1)
        var carry = false
        for index in 0..<count {
            let left = index < lhs.limbs.count ? lhs.limbs[index] : 0
            let right = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (partial, firstOverflow) = left.addingReportingOverflow(right)
            let (sum, secondOverflow) = partial.addingReportingOverflow(carry ? 1 : 0)
            result.append(sum)
            carry = firstOverflow || secondOverflow
        }
        if carry { result.append(1) }
        return WorkSum(limbs: result)
    }

    public static func + (lhs: WorkSum, rhs: UInt256) -> WorkSum {
        lhs + WorkSum(rhs)
    }

    public func subtracting(_ other: WorkSum) -> WorkSum? {
        guard self >= other else { return nil }
        var result: [UInt64] = []
        result.reserveCapacity(limbs.count)
        var borrow = false
        for index in limbs.indices {
            let right = index < other.limbs.count ? other.limbs[index] : 0
            let (partial, firstBorrow) = limbs[index].subtractingReportingOverflow(right)
            let (difference, secondBorrow) = partial.subtractingReportingOverflow(borrow ? 1 : 0)
            result.append(difference)
            borrow = firstBorrow || secondBorrow
        }
        return borrow ? nil : WorkSum(limbs: result)
    }

    public var uint64Value: UInt64? {
        limbs.count <= 1 ? (limbs.first ?? 0) : nil
    }

    public func toHexString() -> String {
        guard let mostSignificant = limbs.last else {
            return String(repeating: "0", count: 64)
        }
        var result = String(mostSignificant, radix: 16)
        for limb in limbs.dropLast().reversed() {
            let encoded = String(limb, radix: 16)
            result += String(repeating: "0", count: 16 - encoded.count) + encoded
        }
        return result.count < 64
            ? String(repeating: "0", count: 64 - result.count) + result
            : result
    }

    public var description: String { toHexString() }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let value = WorkSum(hex: encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid hexadecimal work sum"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(toHexString())
    }
}

/// Exact proof-of-work keyed by physical grind identity. A grind has one block
/// location per chain, but may appear once at every level of the hierarchy.
/// If several levels observe its difficulty, the strongest verified value wins.
public struct WorkMeasure: Codable, Sendable, Equatable {
    private var workByGrind: [String: UInt256]

    public static let zero = WorkMeasure()

    public init() {
        workByGrind = [:]
    }

    public init(_ contribution: VerifiedWorkContribution) {
        workByGrind = [contribution.id: contribution.work]
    }

    public init(_ contributions: some Sequence<VerifiedWorkContribution>) {
        workByGrind = [:]
        for contribution in contributions {
            insert(contribution)
        }
    }

    public var total: WorkSum {
        workByGrind.values.reduce(.zero) { $0 + $1 }
    }

    public var grindIDs: Set<String> {
        Set(workByGrind.keys)
    }

    public var isEmpty: Bool {
        workByGrind.isEmpty
    }

    var entries: [String: UInt256] {
        workByGrind
    }

    func normalized(using strongestWork: [String: UInt256]) -> WorkMeasure {
        var result = self
        for id in workByGrind.keys {
            if let strongest = strongestWork[id] {
                result.workByGrind[id] = strongest
            }
        }
        return result
    }

    public func work(forGrind id: String) -> UInt256? {
        workByGrind[id]
    }

    @discardableResult
    public mutating func insert(_ contribution: VerifiedWorkContribution) -> Bool {
        guard contribution.work > (workByGrind[contribution.id] ?? .zero) else {
            return false
        }
        workByGrind[contribution.id] = contribution.work
        return true
    }

    public mutating func formUnion(_ other: WorkMeasure) {
        for (id, work) in other.workByGrind where work > (workByGrind[id] ?? .zero) {
            workByGrind[id] = work
        }
    }

    public func union(_ other: WorkMeasure) -> WorkMeasure {
        var result = self
        result.formUnion(other)
        return result
    }

    /// A transport adapter can split an exact measure without exposing its
    /// storage. Rejoining any partition with `union` recovers this measure.
    public func restricted(toGrindIDs ids: Set<String>) -> WorkMeasure {
        WorkMeasure(workByGrind.compactMap { id, work in
            ids.contains(id)
                ? VerifiedWorkContribution(id: id, work: work)
                : nil
        })
    }
}

/// One coherent node-provided view of work inherited by blocks in this chain.
/// The node authenticates, routes, and caches the delegated parent processes;
/// Lattice consumes the snapshot as a live fork-choice input. `revision` is a
/// source-progress watermark, not a commitment to the snapshot contents.
public struct InheritedWorkFact: Sendable, Equatable {
    public let blockCID: String
    public let grindID: String
    public let work: UInt256

    /// Recovery and transport may construct delegated facts without gaining
    /// access to the package-only local-work contribution type.
    public init?(
        blockCID: String,
        grindID: String,
        work: UInt256
    ) {
        guard work > .zero,
              CIDIdentity.isCanonical(blockCID),
              CIDIdentity.isCanonical(grindID) else { return nil }
        self.blockCID = blockCID
        self.grindID = grindID
        self.work = work
    }
}

public struct InheritedWorkSnapshot: Codable, Sendable, Equatable {
    public let revision: UInt64
    /// The authenticated immediate-parent relation. Valid snapshots contain
    /// one block location and one greatest quantity per physical grind.
    private let workByBlock: [String: WorkMeasure]
    private enum CodingKeys: String, CodingKey {
        case revision
        case workByBlock
    }

    public static let zero = InheritedWorkSnapshot(revision: 0, workByBlock: [:])

    public init(revision: UInt64, workByBlock: [String: WorkMeasure]) {
        self.revision = revision
        self.workByBlock = workByBlock
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            revision: try container.decode(UInt64.self, forKey: .revision),
            workByBlock: try container.decode([String: WorkMeasure].self, forKey: .workByBlock)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(workByBlock, forKey: .workByBlock)
    }

    /// Build a snapshot from already authenticated delegated facts. This keeps
    /// live local proof-of-work mutation package-only while allowing a node to
    /// restore its durable immediate-parent view.
    public init(revision: UInt64, facts: [InheritedWorkFact]) {
        var workByBlock: [String: WorkMeasure] = [:]
        for fact in facts {
            var measure = workByBlock[fact.blockCID] ?? .zero
            _ = measure.insert(VerifiedWorkContribution(
                id: fact.grindID,
                work: fact.work
            ))
            workByBlock[fact.blockCID] = measure
        }
        self.init(revision: revision, workByBlock: workByBlock)
    }

    public func work(forBlock hash: String) -> WorkMeasure {
        workByBlock[hash] ?? .zero
    }

    /// Exact source facts for one block. This spelling emphasizes that
    /// persistence and transport retain the relation itself.
    public func sourceWork(forBlock hash: String) -> WorkMeasure {
        workByBlock[hash] ?? .zero
    }

    public var isEmpty: Bool {
        workByBlock.values.allSatisfy(\.isEmpty)
    }

    /// Untrusted transport and recovery bytes may represent an invalid relation;
    /// consensus accepts only one immutable block location per physical grind.
    public var hasUniqueGrindLocations: Bool {
        var locations: [String: String] = [:]
        for (blockCID, measure) in workByBlock {
            for grindID in measure.grindIDs {
                if let existing = locations[grindID], existing != blockCID {
                    return false
                }
                locations[grindID] = blockCID
            }
        }
        return true
    }

    /// Whether every retained inherited fact belongs to one of the supplied
    /// child blocks.
    public func isScoped(to blockCIDs: Set<String>) -> Bool {
        workByBlock.keys.allSatisfy(blockCIDs.contains)
    }

    /// The block CIDs represented by this snapshot, in stable order. This
    /// permits a node to page a trusted snapshot without exposing mutable
    /// storage internals.
    public var blockCIDs: [String] {
        workByBlock.keys.sorted()
    }

    /// Retain only source facts for the supplied blocks.
    public func restricted(to blockCIDs: Set<String>) -> InheritedWorkSnapshot {
        InheritedWorkSnapshot(
            revision: revision,
            workByBlock: workByBlock.filter { blockCIDs.contains($0.key) }
        )
    }

    /// The monotonic source facts this snapshot adds beyond an earlier one.
    public func additions(since earlier: InheritedWorkSnapshot) -> InheritedWorkSnapshot {
        let stronger = workByBlock.reduce(into: [String: WorkMeasure]()) {
            result, entry in
            let (blockCID, measure) = entry
            let previous = earlier.sourceWork(forBlock: blockCID)
            let additions = WorkMeasure(measure.entries.compactMap { id, work in
                work > (previous.work(forGrind: id) ?? .zero)
                    ? VerifiedWorkContribution(id: id, work: work)
                    : nil
            })
            if !additions.isEmpty {
                result[blockCID] = additions
            }
        }
        return InheritedWorkSnapshot(revision: revision, workByBlock: stronger)
    }

    var strongestWorkByGrind: [String: UInt256] {
        Self.strongestWork(in: workByBlock)
    }

    private static func strongestWork(
        in workByBlock: [String: WorkMeasure]
    ) -> [String: UInt256] {
        workByBlock.values.reduce(into: [:]) { strongest, measure in
            for (id, work) in measure.entries where work > (strongest[id] ?? .zero) {
                strongest[id] = work
            }
        }
    }

    /// Package-internal source relation.
    var entriesByBlock: [String: WorkMeasure] {
        workByBlock
    }

    /// Every consensus identity is a canonical content identifier. Opaque test
    /// labels must not cross the inherited-work admission boundary.
    var hasCanonicalCIDs: Bool {
        workByBlock.allSatisfy { blockCID, measure in
            guard CIDIdentity.isCanonical(blockCID) else { return false }
            return measure.entries.keys.allSatisfy { grindID in
                CIDIdentity.isCanonical(grindID)
            }
        }
    }

    public func union(_ newer: InheritedWorkSnapshot) -> InheritedWorkSnapshot {
        var merged = workByBlock
        for hash in newer.workByBlock.keys {
            merged[hash] = (merged[hash] ?? .zero).union(
                newer.sourceWork(forBlock: hash)
            )
        }
        return InheritedWorkSnapshot(
            revision: max(revision, newer.revision),
            workByBlock: merged
        )
    }
}
