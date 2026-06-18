import Foundation
import UInt256

public struct ConsensusWorkSegment: Sendable, Equatable {
    public let headHash: String
    public let baseHash: String?
    public let tipHash: String
    public let blocks: [String]
    /// Cached chain-local prefix work keyed by block hash. `blocks` is the
    /// ordered same-chain path; this map supplies the prefix sums used for
    /// constant-time subtraction along that path.
    public let cumulativeWorkByBlock: [String: UInt256]
    /// Chain-local prefix work immediately before `baseHash`'s successor.
    public let startWork: UInt256
    /// Chain-local prefix work at `tipHash`.
    public let endWork: UInt256
    public let children: [ConsensusWorkSegment]

    public init(
        headHash: String,
        baseHash: String?,
        tipHash: String,
        blocks: [String],
        cumulativeWorkByBlock: [String: UInt256] = [:],
        startWork: UInt256,
        endWork: UInt256,
        children: [ConsensusWorkSegment] = []
    ) {
        self.headHash = headHash
        self.baseHash = baseHash
        self.tipHash = tipHash
        self.blocks = blocks
        self.cumulativeWorkByBlock = cumulativeWorkByBlock
        self.startWork = startWork
        self.endWork = endWork
        self.children = children
    }

    public init(
        baseHash: String?,
        tipHash: String,
        startWork: UInt256,
        endWork: UInt256,
        children: [ConsensusWorkSegment] = []
    ) {
        self.init(
            headHash: tipHash,
            baseHash: baseHash,
            tipHash: tipHash,
            blocks: [tipHash],
            cumulativeWorkByBlock: [tipHash: endWork],
            startWork: startWork,
            endWork: endWork,
            children: children
        )
    }

    public var work: UInt256 {
        endWork > startWork ? endWork &- startWork : .zero
    }

    public var totalWork: UInt256 {
        children.reduce(work) { total, child in
            saturatingWorkSum(total, child.totalWork)
        }
    }

    public func cachedCumulativeWork(for blockHash: String) -> UInt256? {
        cumulativeWorkByBlock[blockHash]
    }

    /// Total work reachable from `blockHash` inside this same-chain segment
    /// tree. Linear suffixes are prefix-subtractions; recursion only follows
    /// child segments at fork boundaries.
    public func totalWork(startingAt blockHash: String) -> UInt256? {
        guard let cumulativePath = validatedCumulativePath() else { return nil }
        if let index = blocks.firstIndex(of: blockHash) {
            let prefixBeforeBlock: UInt256
            if index == 0 {
                prefixBeforeBlock = startWork
            } else {
                prefixBeforeBlock = cumulativePath[index - 1]
            }
            let segmentSuffix = endWork > prefixBeforeBlock ? endWork &- prefixBeforeBlock : .zero
            var total = segmentSuffix
            for child in children {
                guard let childWork = child.totalWork(startingAt: child.headHash) else { return nil }
                total = saturatingWorkSum(total, childWork)
            }
            return total
        }
        for child in children {
            if let work = child.totalWork(startingAt: blockHash) {
                return work
            }
        }
        return nil
    }

    private func validatedCumulativePath() -> [UInt256]? {
        guard !blocks.isEmpty,
              blocks.first == headHash,
              blocks.last == tipHash,
              Set(blocks).count == blocks.count,
              cumulativeWorkByBlock[tipHash] == endWork else { return nil }

        var previous = startWork
        var cumulativePath: [UInt256] = []
        cumulativePath.reserveCapacity(blocks.count)
        for blockHash in blocks {
            guard let cumulativeWork = cumulativeWorkByBlock[blockHash],
                  cumulativeWork >= previous else { return nil }
            cumulativePath.append(cumulativeWork)
            previous = cumulativeWork
        }
        return cumulativePath
    }
}

/// One node in a verified same-chain work graph.
public struct ConsensusWorkNode: Sendable, Equatable {
    public let parent: String?
    public let localWork: UInt256
    public let cumulativeWork: UInt256

    public init(parent: String?, localWork: UInt256, cumulativeWork: UInt256) {
        self.parent = parent
        self.localWork = localWork
        self.cumulativeWork = cumulativeWork
    }
}

/// A maximal no-fork run inside a verified same-chain work graph.
public struct ConsensusWorkRun: Sendable, Equatable {
    public let head: String
    public let tail: String
    public let blocks: [String]
    public let work: UInt256

    public init(head: String, tail: String, blocks: [String], work: UInt256) {
        self.head = head
        self.tail = tail
        self.blocks = blocks
        self.work = work
    }
}

public enum ConsensusSegmentedWork {
    public static func childrenByParent(_ graph: [String: ConsensusWorkNode]) -> [String: [String]] {
        var children: [String: [String]] = [:]
        for (cid, entry) in graph {
            guard let parent = entry.parent, graph[parent] != nil else { continue }
            children[parent, default: []].append(cid)
        }
        return children.mapValues { $0.sorted() }
    }

    public static func cumulativeWork(
        parentCID: String?,
        localWork: UInt256,
        graph: [String: ConsensusWorkNode]
    ) -> UInt256 {
        guard let parentCID,
              let parent = graph[parentCID] else { return localWork }
        return saturatingWorkSum(parent.cumulativeWork, localWork)
    }

    /// Segmentized observed total work for a verified same-chain graph. Linear
    /// no-fork runs are folded into segments and recursion only re-enters at fork
    /// points.
    public static func observedRuns(
        for cid: String,
        graph: [String: ConsensusWorkNode]
    ) -> [ConsensusWorkRun]? {
        let children = childrenByParent(graph)
        var runs: [ConsensusWorkRun] = []
        var visiting = Set<String>()

        func visit(_ start: String) -> Bool {
            var current = start
            var runBlocks: [String] = []
            var runWork = UInt256.zero

            while true {
                guard let entry = graph[current],
                      visiting.insert(current).inserted else { return false }
                runBlocks.append(current)
                runWork = saturatingWorkSum(runWork, entry.localWork)

                let childBlocks = children[current] ?? []
                if childBlocks.count == 1 {
                    current = childBlocks[0]
                    continue
                }

                guard let head = runBlocks.first, let tail = runBlocks.last else { return false }
                runs.append(ConsensusWorkRun(head: head, tail: tail, blocks: runBlocks, work: runWork))
                for child in childBlocks {
                    guard visit(child) else { return false }
                }
                return true
            }
        }

        guard visit(cid) else { return nil }
        return runs
    }

    public static func observedTotalWork(
        for cid: String,
        graph: [String: ConsensusWorkNode]
    ) -> UInt256? {
        observedRuns(for: cid, graph: graph)?.reduce(UInt256.zero) { total, run in
            saturatingWorkSum(total, run.work)
        }
    }

    public static func segmentTree(
        for cid: String,
        graph: [String: ConsensusWorkNode]
    ) -> ConsensusWorkSegment? {
        let children = childrenByParent(graph)
        var visiting = Set<String>()

        func build(_ start: String) -> ConsensusWorkSegment? {
            var current = start
            var runBlocks: [String] = []
            var cumulativeWorkByBlock: [String: UInt256] = [:]
            var runWork = UInt256.zero

            while true {
                guard let entry = graph[current],
                      visiting.insert(current).inserted else { return nil }
                runBlocks.append(current)
                cumulativeWorkByBlock[current] = entry.cumulativeWork
                runWork = saturatingWorkSum(runWork, entry.localWork)

                let childBlocks = children[current] ?? []
                if childBlocks.count == 1 {
                    current = childBlocks[0]
                    continue
                }

                guard let head = runBlocks.first,
                      let tail = runBlocks.last,
                      let headEntry = graph[head],
                      runWork > .zero else { return nil }
                let startWork = headEntry.parent.flatMap { graph[$0]?.cumulativeWork } ?? .zero
                let childSegments = childBlocks.compactMap(build)
                guard childSegments.count == childBlocks.count else { return nil }
                return ConsensusWorkSegment(
                    headHash: head,
                    baseHash: headEntry.parent,
                    tipHash: tail,
                    blocks: runBlocks,
                    cumulativeWorkByBlock: cumulativeWorkByBlock,
                    startWork: startWork,
                    endWork: saturatingWorkSum(startWork, runWork),
                    children: childSegments
                )
            }
        }

        return build(cid)
    }

    public static func inheritedSegments(
        for cid: String,
        graph: [String: ConsensusWorkNode]
    ) -> [ConsensusWorkSegment]? {
        guard let root = segmentTree(for: cid, graph: graph) else { return nil }
        return [root]
    }

    public static func flattenSegments(_ segments: [ConsensusWorkSegment]) -> [ConsensusWorkSegment] {
        var flattened: [ConsensusWorkSegment] = []
        func visit(_ segment: ConsensusWorkSegment) {
            flattened.append(segment)
            segment.children.forEach(visit)
        }
        segments.forEach(visit)
        return flattened
    }

    public static func flattenSegments(_ segment: ConsensusWorkSegment) -> [ConsensusWorkSegment] {
        flattenSegments([segment])
    }

}

/// Child-side inherited-work store. Proof/segment verification is the expensive
/// boundary; fork choice reads a scalar accumulated weight by child block hash.
public final class InheritedWeightStore: @unchecked Sendable {
    private typealias BlockWork = (blockHash: String, work: UInt256)

    private struct SegmentPrefixKey: Sendable, Hashable {
        var baseHash: String?
        var headHash: String
        var tipHash: String
        var blockCount: Int

        init(segment: ConsensusWorkSegment, tipIndex: Int) {
            self.baseHash = segment.baseHash
            self.headHash = segment.headHash
            self.tipHash = segment.blocks[tipIndex]
            self.blockCount = tipIndex + 1
        }
    }

    private struct SegmentRecordingState {
        var counted: Set<String>
        var coveredPrefixes: Set<SegmentPrefixKey>
        var total: UInt256
        var changed: Bool = false

        mutating func record(_ blockWork: ArraySlice<BlockWork>) {
            for contribution in blockWork where contribution.work > .zero {
                if counted.insert(contribution.blockHash).inserted {
                    total = saturatingWorkSum(total, contribution.work)
                    changed = true
                }
            }
        }
    }

    private let lock = NSLock()
    private var countedContributorsByChild: [String: Set<String>] = [:]
    /// Fast-path hint for no-fork tip extensions. Block hashes remain the
    /// accounting identity; this only skips already-covered linear prefixes.
    private var countedSegmentPrefixesByChild: [String: Set<SegmentPrefixKey>] = [:]
    private var inheritedWorkByChild: [String: UInt256] = [:]

    public init() {}

    @discardableResult
    public func recordVerifiedWorkContributions(
        _ contributions: [(id: String, work: UInt256)],
        committingChild childBlockHash: String
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !contributions.isEmpty else { return false }
        var counted = countedContributorsByChild[childBlockHash] ?? []
        var total = inheritedWorkByChild[childBlockHash] ?? .zero
        var changed = false
        for contribution in contributions where contribution.work > .zero {
            if counted.insert(contribution.id).inserted {
                total = saturatingWorkSum(total, contribution.work)
                changed = true
            }
        }
        if changed {
            countedContributorsByChild[childBlockHash] = counted
            inheritedWorkByChild[childBlockHash] = total
        }
        return changed
    }

    @discardableResult
    public func recordVerifiedWorkSegments(
        _ segments: [ConsensusWorkSegment],
        committingChild childBlockHash: String
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !segments.isEmpty else { return false }

        var state = SegmentRecordingState(
            counted: countedContributorsByChild[childBlockHash] ?? [],
            coveredPrefixes: countedSegmentPrefixesByChild[childBlockHash] ?? [],
            total: inheritedWorkByChild[childBlockHash] ?? .zero
        )

        for segment in segments {
            guard Self.recordSegmentTreeIntoState(
                segment,
                state: &state
            ) else { return false }
        }

        countedContributorsByChild[childBlockHash] = state.counted
        countedSegmentPrefixesByChild[childBlockHash] = state.coveredPrefixes
        if state.changed {
            inheritedWorkByChild[childBlockHash] = state.total
        }
        return state.changed
    }

    @discardableResult
    public func recordVerifiedWorkSegment(_ segment: ConsensusWorkSegment, committingChild childBlockHash: String) -> Bool {
        recordVerifiedWorkSegments([segment], committingChild: childBlockHash)
    }

    @discardableResult
    public func recordVerifiedParentWork(_ work: UInt256, parentBlockHash: String, committingChild childBlockHash: String?) -> Bool {
        guard let childBlockHash else { return false }
        return recordVerifiedWorkContributions([(id: parentBlockHash, work: work)], committingChild: childBlockHash)
    }

    public func inheritedWeight(forChild childBlockHash: String) -> UInt256 {
        lock.lock(); defer { lock.unlock() }
        return inheritedWorkByChild[childBlockHash] ?? .zero
    }

    public var totalParentWork: UInt256 {
        lock.lock(); defer { lock.unlock() }
        return inheritedWorkByChild.values.reduce(UInt256.zero) { total, work in
            saturatingWorkSum(total, work)
        }
    }

    public func makeProvider() -> @Sendable (String) -> UInt256 {
        { [self] childBlockHash in inheritedWeight(forChild: childBlockHash) }
    }

    private static func recordSegmentTreeIntoState(
        _ segment: ConsensusWorkSegment,
        state: inout SegmentRecordingState
    ) -> Bool {
        guard let blockWork = validatedBlockWork(in: segment) else { return false }

        let suffixStart = Self.suffixStartAfterCoveredPrefix(segment: segment, coveredPrefixes: state.coveredPrefixes)
        state.record(blockWork.dropFirst(suffixStart))

        for child in segment.children {
            guard recordSegmentTreeIntoState(
                child,
                state: &state
            ) else { return false }
        }

        // Insert coverage only after every block in the segment tree validates
        // and records; the counted set is the sole accounting identity, so
        // skipping a covered prefix never drops work.
        state.coveredPrefixes.insert(SegmentPrefixKey(segment: segment, tipIndex: segment.blocks.count - 1))
        return true
    }

    /// Validates a verified same-chain segment's cumulative-work map and returns
    /// the per-block local work facts used by accounting.
    private static func validatedBlockWork(
        in segment: ConsensusWorkSegment
    ) -> [BlockWork]? {
        guard !segment.blocks.isEmpty,
              segment.blocks.first == segment.headHash,
              segment.blocks.last == segment.tipHash,
              Set(segment.blocks).count == segment.blocks.count,
              segment.cumulativeWorkByBlock[segment.tipHash] == segment.endWork else { return nil }

        var previous = segment.startWork
        var blockWork: [BlockWork] = []
        blockWork.reserveCapacity(segment.blocks.count)

        for blockHash in segment.blocks {
            guard let cumulativeWork = segment.cumulativeWorkByBlock[blockHash],
                  cumulativeWork >= previous else { return nil }
            blockWork.append((blockHash: blockHash, work: cumulativeWork &- previous))
            previous = cumulativeWork
        }

        return blockWork
    }

    private static func suffixStartAfterCoveredPrefix(
        segment: ConsensusWorkSegment,
        coveredPrefixes: Set<SegmentPrefixKey>
    ) -> Int {
        var index = segment.blocks.count - 1
        while index >= 0 {
            if coveredPrefixes.contains(SegmentPrefixKey(segment: segment, tipIndex: index)) {
                return index + 1
            }
            index -= 1
        }
        return 0
    }

}
