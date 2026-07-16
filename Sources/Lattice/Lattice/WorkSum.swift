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

/// Exact proof-of-work keyed by physical grind identity.
///
/// One grind may cover any number of blocks or chain levels, but contributes
/// only once to a fork-choice comparison. If the same grind is observed at
/// multiple accepted difficulties, its strongest verified value wins.
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
}

/// One coherent node-provided view of work inherited by blocks in this chain.
/// The node authenticates, routes, and caches the immediate-parent process;
/// Lattice consumes the snapshot as a live fork-choice input. `revision` is a
/// source-progress watermark, not a commitment to the snapshot contents.
public struct InheritedWorkSnapshot: Codable, Sendable, Equatable {
    public let revision: UInt64
    private let workByBlock: [String: WorkMeasure]

    public static let zero = InheritedWorkSnapshot(revision: 0, workByBlock: [:])

    public init(revision: UInt64, workByBlock: [String: WorkMeasure]) {
        var strongestWork: [String: UInt256] = [:]
        for measure in workByBlock.values {
            for (id, work) in measure.entries where work > (strongestWork[id] ?? .zero) {
                strongestWork[id] = work
            }
        }
        self.revision = revision
        self.workByBlock = workByBlock.mapValues {
            $0.normalized(using: strongestWork)
        }
    }

    public func work(forBlock hash: String) -> WorkMeasure {
        workByBlock[hash] ?? .zero
    }

    public var isEmpty: Bool {
        workByBlock.values.allSatisfy(\.isEmpty)
    }

    var strongestWorkByGrind: [String: UInt256] {
        workByBlock.values.reduce(into: [:]) { strongest, measure in
            for (id, work) in measure.entries where work > (strongest[id] ?? .zero) {
                strongest[id] = work
            }
        }
    }

    var entriesByBlock: [String: WorkMeasure] {
        workByBlock
    }

    public func union(_ newer: InheritedWorkSnapshot) -> InheritedWorkSnapshot {
        var merged = workByBlock
        for hash in newer.workByBlock.keys {
            merged[hash] = (merged[hash] ?? .zero).union(newer.work(forBlock: hash))
        }
        return InheritedWorkSnapshot(
            revision: max(revision, newer.revision),
            workByBlock: merged
        )
    }
}

public typealias InheritedWorkProvider = @Sendable () -> InheritedWorkSnapshot
