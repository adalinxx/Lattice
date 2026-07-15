import Foundation
import cashew
import UInt256

// MARK: - Proof

/// Sparse proof that a block is embedded under a PoW root, following the
/// content-addressed path `root → children[d0] → children[d1] → … → block`.
///
/// `directoryPath` is the chain of child directories from the PoW root down to the
/// proven block — `["SwapTest"]` for a direct child of the root, `["Mid","Stable"]`
/// for a grandchild. `entries` is the union of the sparse cashew CAS entries along
/// that whole path; `rootCID` is the absolute PoW-root block. A single-hop proof is
/// just a 1-element path — the depth-1 case is not special.
///
/// Multi-hop proofs are built by `compose`: a relaying node that holds only its own
/// `root→self` proof (not the blocks above it) appends a locally-generated
/// `self→child` hop to extend the path one level, without ever materializing the
/// ancestor chain.
///
/// Inner proof format (wrapped by `ChildBlockProofEnvelope` on the wire):
///   [proofLen: UInt32 LE]
///   [pathLen: UInt16 LE]  for each: [dirLen: UInt16 LE][dir: UTF-8]
///   [numEntries: UInt16 LE]
///   for each entry:
///     [cidLen: UInt16 LE][cid: UTF-8]
///     [dataLen: UInt32 LE][data: bytes]
///
/// To verify: store entries into a MemoryBroker, fetch the root, check its PoW
/// hash, then walk `directoryPath` via targeted resolution down to the leaf CID.
public struct ChildBlockProof: Sendable {
    /// CAS entries from the sparse path (union across all hops, root → leaf only).
    public let entries: [(cid: String, data: Data)]
    /// CID of the PoW root block.
    public let rootCID: String
    /// Child directories from the root down to the proven block (root-exclusive).
    public let directoryPath: [String]

    public init(rootCID: String, directoryPath: [String], entries: [(cid: String, data: Data)]) {
        self.rootCID = rootCID
        self.directoryPath = directoryPath
        self.entries = entries
    }

    /// Stable identity for this one vertical PoW path. A child block may collect
    /// several paths; this ID dedupes the path without treating it as ancestry.
    public var proofPathID: String {
        var parts = ["root", String(rootCID.utf8.count), rootCID, "path", String(directoryPath.count)]
        for dir in directoryPath {
            parts.append(String(dir.utf8.count))
            parts.append(dir)
        }
        return parts.joined(separator: ":")
    }

    /// Stable content identity for sorting/deduping proof envelopes. It includes
    /// normalized CAS entries, so wire/collection order is never consensus input.
    public var canonicalProofID: String {
        var parts = [proofPathID, "entries", String(entries.count)]
        for entry in canonicalEntries(entries) {
            parts.append(String(entry.cid.utf8.count))
            parts.append(entry.cid)
            parts.append(String(entry.data.count))
            parts.append(entry.data.base64EncodedString())
        }
        return parts.joined(separator: ":")
    }

    public var canonicalized: ChildBlockProof {
        ChildBlockProof(rootCID: rootCID, directoryPath: directoryPath, entries: canonicalEntries(entries))
    }

    public var entryMap: [String: Data] {
        var map: [String: Data] = [:]
        for entry in entries {
            map[entry.cid] = entry.data
        }
        return map
    }

    // MARK: - Generation

    /// Generate a single-hop sparse proof for `childDirectory` from a block the
    /// caller holds (the PoW root, or — for `compose` — an intermediate block).
    /// `directoryPath` is `[childDirectory]`; multi-level paths are built by
    /// composing single hops.
    public static func generate(
        rootHeader: VolumeImpl<Block>,
        childDirectory: String,
        fetcher: Fetcher
    ) async throws -> ChildBlockProof {
        let path: [[String]: ResolutionStrategy] = [["children", childDirectory]: .targeted]
        let resolvedRoot = try await rootHeader.resolve(paths: path, fetcher: fetcher)
        let storer = _CollectingStorer()
        try await resolvedRoot.store(paths: path, storer: storer)

        return ChildBlockProof(rootCID: rootHeader.rawCID, directoryPath: [childDirectory], entries: dedupedEntries(storer.entries))
    }

    // MARK: - Composition

    /// Extend an upstream `root → self` proof by one level using a locally-generated
    /// `self → child` hop, yielding `root → … → self → child`. The relaying node
    /// holds only its own proof and its own block, never the blocks above it: the
    /// upstream path is reused verbatim, the hop appends `child`, and the entry sets
    /// are unioned (deduped by CID) so the verifier can walk the whole path. The hop
    /// must be rooted at `self` — the block whose directory is the last element of
    /// the upstream path — so the seam is content-addressed and unforgeable.
    public func composing(hop: ChildBlockProof) -> ChildBlockProof {
        var merged = entries
        var seen = Set(entries.map { $0.cid })
        for e in hop.entries where seen.insert(e.cid).inserted {
            merged.append(e)
        }
        return ChildBlockProof(
            rootCID: rootCID,
            directoryPath: directoryPath + hop.directoryPath,
            entries: merged
        )
    }

    // MARK: - Verification

    /// A sealed in-memory source over this proof's witness entries. The proof's
    /// entry map is attacker-supplied and content-bound at each hop;
    /// `InMemoryContentSource` has no tier chain, so verification cannot reach the
    /// network by construction (it physically has nowhere to fall through to).
    private func proofSource() -> InMemoryContentSource {
        InMemoryContentSource(Dictionary(entries.map { ($0.cid, $0.data) }, uniquingKeysWith: { first, _ in first }))
    }

    /// Recompute the root CID from proof-supplied bytes. A proof is untrusted
    /// evidence, so an unexpected serialization failure is an invalid witness,
    /// never a reason to trap the verifier.
    private func isContentBoundRoot(_ rootBlock: Block) -> Bool {
        guard let header = try? VolumeImpl<Block>(node: rootBlock) else {
            return false
        }
        return header.rawCID == rootCID
    }

    /// Resolve the root block's content, confirm the root block's
    /// proofOfWorkHash() equals `rootHash`, then walk `directoryPath` hop by hop
    /// (root.children[d0] → that block's children[d1] → …) and confirm the final
    /// leaf header equals `childCID`. Any missing entry, broken hop, or hash
    /// mismatch fails closed.
    public func verify(rootHash: UInt256, childCID: String) async -> Bool {
        guard !entries.isEmpty, !directoryPath.isEmpty else { return false }

        let fetcher = proofSource()

        guard let rootBlockData = try? await fetcher.fetch(rawCid: rootCID),
              let rootBlock = Block(data: rootBlockData) else { return false }

        // Content-bind the root bytes to rootCID. The proof's entry map is attacker-
        // supplied, so bytes stored under the rootCID key must be verified to actually
        // hash to it — otherwise a forger could ship arbitrary bytes as "the root" and
        // control proofOfWorkHash().
        guard isContentBoundRoot(rootBlock) else { return false }
        // The root block's PoW hash must match the claimed PoW hash and clear
        // the root target. A content-bound but unmined carrier is not authority
        // to secure a child block.
        guard rootBlock.proofOfWorkHash() == rootHash else { return false }
        guard rootBlock.validateProofOfWork(nexusHash: rootHash) else { return false }

        // Walk the path: resolve children[dir] at each level, descending into the
        // resolved child block for the next hop until the final leaf.
        var currentBlock = rootBlock
        for (i, dir) in directoryPath.enumerated() {
            guard let childrenNode = try? await currentBlock.children.resolve(
                paths: [[dir]: .targeted], fetcher: fetcher
            ).node,
            let childHeader: VolumeImpl<Block> = try? childrenNode.get(key: dir) else { return false }

            if i == directoryPath.count - 1 {
                return childHeader.rawCID == childCID
            }
            guard let next = try? await childHeader.resolve(fetcher: fetcher).node else { return false }
            // Each intermediate carrier is itself a child-chain block secured by
            // the same absolute PoW root. Without this check an arbitrary nested
            // container could manufacture a descendant path beneath a valid root.
            guard next.validateProofOfWork(nexusHash: rootHash) else { return false }
            currentBlock = next
        }
        return false
    }

    /// Reconstruct the PoW-root block from the proof's own entries and return its
    /// PoW hash AND its height — the intrinsic anchor the proof commits to. The
    /// hash is what a child block's PoW is checked against (its work lives on the
    /// cross-chain path to the root, not its own hash); the height lets a verifier bind
    /// the root to a canonical block at that height even after the root's body has been
    /// pruned (durable `block_index` commitment). Content-bound: the bytes under
    /// `rootCID` must hash to it (the proof's entry map is attacker-supplied), so a
    /// forger can't ship arbitrary "root" bytes. `nil` if the root entry is missing.
    public func anchorRoot() async -> (hash: UInt256, height: UInt64)? {
        guard !entries.isEmpty else { return nil }
        let fetcher = proofSource()
        guard let rootData = try? await fetcher.fetch(rawCid: rootCID),
              let rootBlock = Block(data: rootData),
              isContentBoundRoot(rootBlock) else { return nil }
        return (rootBlock.proofOfWorkHash(), rootBlock.height)
    }

    /// The intrinsic anchor hash (see `anchorRoot`). `nil` if the root can't be rebuilt.
    public func anchorRootHash() async -> UInt256? {
        await anchorRoot()?.hash
    }

    /// The parent-chain block that committed this proof's leaf.
    ///
    /// For a direct child this is the PoW root block. For deeper chains this is
    /// the last intermediate block on the vertical proof path, i.e. the block
    /// whose `children` dictionary contains the proven leaf. The returned parent
    /// hash/height lets the child layer compare consecutive child blocks against
    /// the parent chain's ancestry without mutating parent-chain state.
    public func committingParentAnchor() async -> ParentAnchor? {
        guard let committed = await committingParentBlock() else { return nil }
        return ParentAnchor(
            blockHash: committed.cid,
            parentHash: committed.block.parent?.rawCID,
            height: committed.block.height,
            prevStateCID: committed.block.prevState.rawCID
        )
    }

    /// Reconstruct the parent-chain block whose `children` dictionary commits
    /// the proven child. This is the state-root anchor for child validation:
    /// the child block's `parentState` must equal this block's `prevState`.
    public func committingParentBlock() async -> (cid: String, block: Block)? {
        guard !entries.isEmpty, !directoryPath.isEmpty else { return nil }
        let fetcher = proofSource()

        guard let rootData = try? await fetcher.fetch(rawCid: rootCID),
              let rootBlock = Block(data: rootData),
              isContentBoundRoot(rootBlock) else { return nil }

        if directoryPath.count == 1 {
            return (rootCID, rootBlock)
        }

        var currentHash = rootCID
        var currentBlock = rootBlock
        for dir in directoryPath.dropLast() {
            guard let childrenNode = try? await currentBlock.children.resolve(
                paths: [[dir]: .targeted], fetcher: fetcher
            ).node,
            let childHeader: VolumeImpl<Block> = try? childrenNode.get(key: dir),
            let next = try? await childHeader.resolve(fetcher: fetcher).node else { return nil }
            currentHash = childHeader.rawCID
            currentBlock = next
        }

        return (currentHash, currentBlock)
    }

    /// The parent-state root proven for the child block by this proof carrier.
    public func committingParentPrevStateCID() async -> String? {
        await committingParentBlock()?.block.prevState.rawCID
    }

    // MARK: - Inherited work (F5-4)

    /// The inherited work this proof's ROOT GRIND contributes to the proven child.
    ///
    /// A single grind (one PoW hash) is graded against every level's target, but it is
    /// ONE unit of work: a hash that clears the hardest target it meets clears every
    /// easier level for FREE. So the grind is counted ONCE, at the MAX `workForTarget`
    /// over the levels it clears — never the per-level SUM, which counts one grind once
    /// per level it happens to cover. That over-count is worst at EQUAL targets: an
    /// N-deep equal-difficulty path (lockstep, adding no independent security) would be
    /// credited N× a single grind — an inflation vector that max closes.
    ///
    /// The contribution is keyed by `rootCID` — the grind's identity — so the caller's
    /// dedup-by-id counts THIS grind once while summing genuinely INDEPENDENT grinds
    /// (distinct roots each doing real work): "count each grind once; independent grinds
    /// sum." The leaf's own work is excluded (same-chain subtree work, not inherited).
    /// At depth 1 (only the root above the leaf) max == the old sum, so direct children
    /// are unchanged; the correction only bites at depth >= 2.
    public func securingWorkContributions() async -> [(id: String, work: UInt256)] {
        guard !entries.isEmpty, !directoryPath.isEmpty else { return [] }

        let fetcher = proofSource()

        guard let rootData = try? await fetcher.fetch(rawCid: rootCID),
              let rootBlock = Block(data: rootData),
              // Content-bind: bytes under rootCID must hash to it (attacker-supplied map).
              isContentBoundRoot(rootBlock) else { return [] }

        let powHash = rootBlock.proofOfWorkHash()
        // Work this grind's hash actually clears at a level, or zero. `validateProofOfWork`
        // self-guards: a level claiming a harder target than the hash achieved clears nothing.
        func clearedWork(_ block: Block) -> UInt256 {
            block.validateProofOfWork(nexusHash: powHash) ? workForTarget(block.target) : .zero
        }

        var maxWork = clearedWork(rootBlock)
        var current = rootBlock
        for dir in directoryPath.dropLast() {
            guard let childrenNode = try? await current.children.resolve(
                paths: [[dir]: .targeted], fetcher: fetcher).node,
            let childHeader: VolumeImpl<Block> = try? childrenNode.get(key: dir),
            let next = try? await childHeader.resolve(fetcher: fetcher).node else { return [] }
            let levelWork = clearedWork(next)
            if levelWork > maxWork { maxWork = levelWork }
            current = next
        }
        // ONE contribution per grind, keyed by the grind's identity (rootCID).
        return maxWork > .zero ? [(id: rootCID, work: maxWork)] : []
    }

    /// The work this proof's ROOT GRIND contributes toward securing the proven block:
    /// the MAX `workForTarget` (`max/target`) over the levels above the leaf that the
    /// grind's single hash clears — counted ONCE, because one hash clearing the hardest
    /// target also clears every easier level for free (see `securingWorkContributions`).
    /// Distinct grinds are summed by the caller, not here. The leaf's own work is
    /// excluded — that's own-chain subtree weight, not inherited.
    ///
    /// The PoW hash is intrinsic to the proof — the root block's `proofOfWorkHash()`
    /// (the grind result; a forger can't fake a small one without doing the work) —
    /// so no `rootHash` is passed and none can be passed wrong. The caller is expected
    /// to have `verify`-ed the path against the *expected* PoW solution first. Per-level
    /// crediting self-guards: a level claiming a harder target than the hash achieved
    /// fails `validateProofOfWork` and earns nothing. `.zero` if the path can't be walked.
    public func securingWork() async -> UInt256 {
        await securingWorkContributions().reduce(UInt256.zero) { total, contribution in
            saturatingWorkSum(total, contribution.work)
        }
    }

    // MARK: - Serialization

    public func serialize() -> Data {
        var out = Data()
        let rootCIDBytes = Data(rootCID.utf8)
        writeU16(&out, UInt16(rootCIDBytes.count))
        out.append(rootCIDBytes)
        writeU16(&out, UInt16(directoryPath.count))
        for dir in directoryPath {
            let db = Data(dir.utf8)
            writeU16(&out, UInt16(db.count))
            out.append(db)
        }
        writeU16(&out, UInt16(entries.count))
        for (cid, data) in entries {
            let cb = Data(cid.utf8)
            writeU16(&out, UInt16(cb.count))
            out.append(cb)
            writeU32(&out, UInt32(data.count))
            out.append(data)
        }
        return out
    }

    public static func deserialize(_ data: Data) -> ChildBlockProof? {
        var pos = data.startIndex
        guard let rootCIDLen = readU16(data, &pos),
              data.distance(from: pos, to: data.endIndex) >= Int(rootCIDLen),
              let rootCID = String(data: data[pos..<data.index(pos, offsetBy: Int(rootCIDLen))], encoding: .utf8)
        else { return nil }
        pos = data.index(pos, offsetBy: Int(rootCIDLen))

        guard let pathCount = readU16(data, &pos) else { return nil }
        var directoryPath: [String] = []
        for _ in 0..<Int(pathCount) {
            guard let dirLen = readU16(data, &pos),
                  data.distance(from: pos, to: data.endIndex) >= Int(dirLen),
                  let dir = String(data: data[pos..<data.index(pos, offsetBy: Int(dirLen))], encoding: .utf8)
            else { return nil }
            directoryPath.append(dir)
            pos = data.index(pos, offsetBy: Int(dirLen))
        }

        guard let count = readU16(data, &pos) else { return nil }
        var entries: [(String, Data)] = []
        for _ in 0..<Int(count) {
            guard let cidLen = readU16(data, &pos),
                  data.distance(from: pos, to: data.endIndex) >= Int(cidLen),
                  let cid = String(data: data[pos..<data.index(pos, offsetBy: Int(cidLen))], encoding: .utf8)
            else { return nil }
            pos = data.index(pos, offsetBy: Int(cidLen))

            guard let dataLen = readU32(data, &pos),
                  data.distance(from: pos, to: data.endIndex) >= Int(dataLen)
            else { return nil }
            entries.append((cid, Data(data[pos..<data.index(pos, offsetBy: Int(dataLen))])))
            pos = data.index(pos, offsetBy: Int(dataLen))
        }
        return ChildBlockProof(rootCID: rootCID, directoryPath: directoryPath, entries: entries)
    }
}

// MARK: - Internal helpers

public final class _CollectingStorer: Storer, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [String: Data] = [:]
    public init() {}
    public func store(entries: [String: Data]) async {
        lock.withLock { storedEntries.merge(entries) { _, new in new } }
    }
    public var entries: [(cid: String, data: Data)] {
        lock.withLock {
            storedEntries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
    }
}

/// Drop duplicate CIDs (content-addressed, so identical bytes per CID), preserving
/// first-seen order. Used when a proof folds entries from more than one collection
/// pass over the same root.
func dedupedEntries(_ entries: [(cid: String, data: Data)]) -> [(cid: String, data: Data)] {
    var seen = Set<String>()
    var result: [(cid: String, data: Data)] = []
    for e in entries where seen.insert(e.cid).inserted {
        result.append(e)
    }
    return result
}

private func canonicalEntries(_ entries: [(cid: String, data: Data)]) -> [(cid: String, data: Data)] {
    entries.sorted {
        if $0.cid != $1.cid { return $0.cid < $1.cid }
        return $0.data.lexicographicallyPrecedes($1.data)
    }
}


private func writeU16(_ out: inout Data, _ v: UInt16) {
    out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8))
}
private func writeU32(_ out: inout Data, _ v: UInt32) {
    out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8(v >> 24))
}
private func readU16(_ data: Data, _ pos: inout Data.Index) -> UInt16? {
    guard data.distance(from: pos, to: data.endIndex) >= 2 else { return nil }
    let v = UInt16(data[pos]) | (UInt16(data[data.index(after: pos)]) << 8)
    pos = data.index(pos, offsetBy: 2); return v
}
private func readU32(_ data: Data, _ pos: inout Data.Index) -> UInt32? {
    guard data.distance(from: pos, to: data.endIndex) >= 4 else { return nil }
    let v = UInt32(data[pos]) | (UInt32(data[data.index(pos, offsetBy: 1)]) << 8)
              | (UInt32(data[data.index(pos, offsetBy: 2)]) << 16)
              | (UInt32(data[data.index(pos, offsetBy: 3)]) << 24)
    pos = data.index(pos, offsetBy: 4); return v
}
