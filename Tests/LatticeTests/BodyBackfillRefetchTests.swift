import XCTest
@testable import Lattice
import cashew
import UInt256
import Foundation
import Network
import os

// A REAL TCP transport for the backfill path (Finding #2): peer B listens on a
// loopback socket and serves block bytes by CID out of its in-memory CAS; node A
// reaches it through `TCPCASFetcher`, which opens an actual `NWConnection` and reads
// the body off the wire. This exercises `backfillSubtree` over a real async network
// transport (connect / length-prefixed request / length-prefixed reply / EOF), not
// an in-process dictionary lookup — so the refetch is proven through the same kind of
// socket I/O the production Ivy sync transport performs, mirroring the
// MultiNodeLifecycle / TCPIntegration pattern.
//
// Wire protocol (one request per connection): client writes a UInt32 big-endian
// length followed by the UTF-8 CID; server replies with a UInt32 big-endian length
// followed by the body bytes (length 0 ⇒ not found), then closes.

/// A loopback TCP server backed by a `StorableFetcher` CAS.
final class TCPCASServer: @unchecked Sendable {
    private let listener: NWListener
    private let cas: StorableFetcher
    let port: UInt16

    init(cas: StorableFetcher) throws {
        self.cas = cas
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [cas] conn in
            TCPCASServer.serve(conn, cas: cas)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: .global())
        ready.wait()
        self.port = listener.port!.rawValue
    }

    func stop() { listener.cancel() }

    private static func serve(_ conn: NWConnection, cas: StorableFetcher) {
        conn.start(queue: .global())
        // Read the 4-byte length prefix, then the CID.
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { lenData, _, _, _ in
            guard let lenData, lenData.count == 4 else { conn.cancel(); return }
            let len = lenData.withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
            conn.receive(minimumIncompleteLength: len, maximumLength: len) { cidData, _, _, _ in
                guard let cidData, let cid = String(data: cidData, encoding: .utf8) else {
                    conn.cancel(); return
                }
                let body = (try? cas.fetchSync(rawCid: cid)) ?? Data()
                var out = Data()
                var n = UInt32(body.count).bigEndian
                withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
                out.append(body)
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }
}

/// A `Fetcher` that retrieves bodies over a real loopback TCP connection to a
/// `TCPCASServer` — the production seam the node fills with its Ivy sync transport.
struct TCPCASFetcher: Fetcher {
    let port: UInt16

    /// One-shot resume guard for a single connection's continuation, safe to capture
    /// in the `@Sendable` Network callbacks (each fires once, on the socket queue).
    private final class OneShot: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        private let cont: CheckedContinuation<Data, Error>
        private let conn: NWConnection
        init(_ cont: CheckedContinuation<Data, Error>, _ conn: NWConnection) {
            self.cont = cont; self.conn = conn
        }
        func finish(_ result: Result<Data, Error>) {
            let already = lock.withLock { done -> Bool in
                if done { return true }; done = true; return false
            }
            if already { return }
            conn.cancel()
            cont.resume(with: result)
        }
    }

    func fetch(rawCid: String) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let shot = OneShot(cont, conn)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var req = Data()
                    let cidBytes = Data(rawCid.utf8)
                    var len = UInt32(cidBytes.count).bigEndian
                    withUnsafeBytes(of: &len) { req.append(contentsOf: $0) }
                    req.append(cidBytes)
                    conn.send(content: req, completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { lenData, _, _, _ in
                            guard let lenData, lenData.count == 4 else {
                                shot.finish(.failure(FetcherError.notFound(rawCid))); return
                            }
                            let n = lenData.withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
                            if n == 0 { shot.finish(.failure(FetcherError.notFound(rawCid))); return }
                            conn.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, _ in
                                if let body, body.count == n { shot.finish(.success(body)) }
                                else { shot.finish(.failure(FetcherError.notFound(rawCid))) }
                            }
                        }
                    })
                case .failed, .cancelled:
                    shot.finish(.failure(FetcherError.notFound(rawCid)))
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }
    }
}

//: body-backfill refetch transport for a HELD strictly-heavier subtree.
//
// CFC-A1 makes fork choice HOLD (no-downgrade, retry-bounded) when a heavier
// subtree is incomplete locally; retains the weight index so the node
// KNOWS the heavier branch exists even with bodies pruned. THE missing piece this
// suite covers: when the node holds on a heavier-but-incomplete subtree it must
// REQUEST the missing interior bodies over the REAL sync path, VALIDATE them
// (content binding cid==hash + the existing per-block consensus walk), and
// CONVERGE on the heavier chain. Missing data = a FETCH TRIGGER, never a downgrade.
//
// The load-bearing test is a two-node / real-transport convergence driven through
// the PRODUCTION choke point: node A is a real `ChainLevel` missing the interior
// bodies of the strictly-heavier subtree, node B (oracle) has the full chain in its
// CAS, and A's transport to B is a real `ChainSyncer`. A's node loop calls the
// production trigger `ChainLevel.backfillHeldHeavierSubtree(syncer:maxBodies:)` —
// the same entry the node uses after a non-extending submission — which detects the
// hold, refetches+validates the missing bodies over the real transport, submits them
// through the real fork-choice path, and converges on the heavier tip (A.tip ==
// B.tip == F5). The test does NOT call `backfillSubtree` directly; it exercises the
// wired choke point so a regression that unwires it fails here.
// Plus a fail-closed test: forged/unresolvable bodies are NOT adopted and do NOT
// downgrade onto the lighter incumbent.

final class BodyBackfillRefetchTests: XCTestCase {

    private static func spec(_ dir: String = "Nexus") -> ChainSpec {
        ChainSpec(maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
                  maxBlockSize: 1_000_000, premine: 0, targetBlockTime: 1_000,
                  initialReward: 1024, halvingInterval: 10_000, retargetWindow: 5)
    }
    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private let easy = UInt256.max // target = max ⇒ PoW trivially valid, work = 1/block.

    private func cid(_ b: Block) -> String { try! VolumeImpl<Block>(node: b).rawCID }

    private func storeBlock(_ block: Block, to fetcher: StorableFetcher) async throws {
        let storer = CollectingStorer()
        try VolumeImpl<Block>(node: block).storeRecursively(storer: storer)
        await storer.flush(to: fetcher)
    }

    // Build the oracle (node B): a CAS holding the FULL DAG, plus the real blocks.
    //   main: G -> M1 -> M2                      (incumbent on A; cum work 3)
    //   fork: G -> F1 -> F2 -> F3 -> F4 -> F5    (strictly heavier; cum work 6)
    // All target = max ⇒ work = 1/block, so the 5-block fork strictly outweighs the
    // 2-block main extension. Returns the blocks for both branches.
    private func buildOracle(into fetcher: StorableFetcher) async throws
        -> (genesis: Block, main: [Block], fork: [Block]) {
        let base = Self.now() - 200_000
        let genesis = try await BlockBuilder.buildGenesis(spec: Self.spec(), timestamp: base, target: easy, fetcher: fetcher)
        try await storeBlock(genesis, to: fetcher)

        // Main extension.
        var main: [Block] = []
        var prev = genesis
        for i in 1...2 {
            let b = try await BlockBuilder.buildBlock(previous: prev, timestamp: base + Int64(i) * 1000,
                                                      target: easy, nonce: UInt64(100 + i), fetcher: fetcher)
            try await storeBlock(b, to: fetcher)
            main.append(b)
            prev = b
        }

        // Strictly-heavier fork off genesis.
        var fork: [Block] = []
        prev = genesis
        for i in 1...5 {
            let b = try await BlockBuilder.buildBlock(previous: prev, timestamp: base + Int64(i) * 1000,
                                                      target: easy, nonce: UInt64(200 + i), fetcher: fetcher)
            try await storeBlock(b, to: fetcher)
            fork.append(b)
            prev = b
        }
        return (genesis, main, fork)
    }

    // Construct node A's persisted state directly: it holds the main chain
    // {G, M1, M2} and the fork BASE F1 as live bodies, with chainTip = M2 (the
    // lighter incumbent), and the heavy fork TAIL {F2..F5} present only in the
    // pruning-durable weight index (bodies absent) — exactly a node that holds the
    // incumbent + fork prefix and pruned/never-fetched the heavy interior. This is
    // the CFC-A1 HOLD state keeps weighable.
    private func buildHeldNodeA(
        genesis: Block, main: [Block], fork: [Block], forkBasePruned: Bool = false
    ) -> PersistedChainState {
        let w = UInt256(1) // work per block (target = max).
        func liveMeta(_ b: Block, parent: String?, height: UInt64, cum: UInt256, children: [String]) -> PersistedBlockMeta {
            PersistedBlockMeta(
                blockHash: cid(b), parentBlockHash: parent, blockHeight: height,
                parentChainBlocks: [:], childHashes: children,
                target: easy.toHexString(), timestamp: b.timestamp,
                cumulativeWork: cum.toHexString())
        }
        let gHash = cid(genesis)
        let m1 = main[0], m2 = main[1]
        let f1 = fork[0], f2 = fork[1], f3 = fork[2], f4 = fork[3], f5 = fork[4]

        // Pruned-but-retained heavy tail F2..F5 (and optionally the fork base F1):
        // bodies absent, weights retained.
        // cumulativeWork (genesis-relative prefix): F1=2, F2=3, F3=4, F4=5, F5=6.
        // subtreeWeight (own + descendants): F5=1, F4=2, F3=3, F2=4, F1=5.
        func pruned(_ b: Block, parent: String, height: UInt64, cum: UInt256, subtree: UInt256, children: [String]) -> PersistedBlockMeta {
            PersistedBlockMeta(
                blockHash: cid(b), parentBlockHash: parent, blockHeight: height,
                parentChainBlocks: [:], childHashes: children,
                target: easy.toHexString(),
                cumulativeWork: cum.toHexString(), subtreeWeight: subtree.toHexString(),
                workHex: w.toHexString())
        }

        // Live blocks: G (children M1 + F1), M1, M2, and — unless the fork base is
        // itself pruned — F1 (child F2, body-pruned tail).
        var live: [PersistedBlockMeta] = [
            liveMeta(genesis, parent: nil, height: 0, cum: UInt256(1), children: [cid(m1), cid(f1)]),
            liveMeta(m1, parent: gHash, height: 1, cum: UInt256(2), children: [cid(m2)]),
            liveMeta(m2, parent: cid(m1), height: 2, cum: UInt256(3), children: []),
        ]
        var prunedTail: [PersistedBlockMeta] = [
            pruned(f2, parent: cid(f1), height: 2, cum: UInt256(3), subtree: UInt256(4), children: [cid(f3)]),
            pruned(f3, parent: cid(f2), height: 3, cum: UInt256(4), subtree: UInt256(3), children: [cid(f4)]),
            pruned(f4, parent: cid(f3), height: 4, cum: UInt256(5), subtree: UInt256(2), children: [cid(f5)]),
            pruned(f5, parent: cid(f4), height: 5, cum: UInt256(6), subtree: UInt256(1), children: []),
        ]
        if forkBasePruned {
            // The fork base F1 is body-pruned too — present only in the weight index.
            prunedTail.insert(
                pruned(f1, parent: gHash, height: 1, cum: UInt256(2), subtree: UInt256(5), children: [cid(f2)]),
                at: 0)
        } else {
            live.append(liveMeta(f1, parent: gHash, height: 1, cum: UInt256(2), children: [cid(f2)]))
        }

        return PersistedChainState(
            chainTip: cid(m2),
            tipPostStateCID: nil, tipPrevStateCID: nil, tipSpecCID: nil,
            tipTarget: nil, tipNextTarget: nil, tipHeight: 2, tipTimestamp: nil,
            mainChainHashes: [gHash, cid(m1), cid(m2)],
            blocks: live, prunedWeightIndex: prunedTail,
            parentChainMap: [:], missingBlockHashes: [])
    }

    // MARK: - Convergence via REAL refetch (the load-bearing test)

    func testRefetchesMissingInteriorBodiesAndConvergesOnHeavierTip() async throws {
        // Node B (oracle): full chain in its CAS.
        let oracleCAS = StorableFetcher()
        let (genesis, main, fork) = try await buildOracle(into: oracleCAS)
        let f5Hash = cid(fork[4])

        // Node A: the held incumbent — tip M2, heavy fork tail bodies absent.
        let aCAS = StorableFetcher() // A's own CAS: holds only the live bodies.
        for b in [genesis, main[0], main[1], fork[0]] {
            try await storeBlock(b, to: aCAS)
        }
        let persistedA = buildHeldNodeA(genesis: genesis, main: main, fork: fork)
        let chainA = try ChainState.restore(from: persistedA)
        // A is a REAL chain level (the same type the node runs), not a bare ChainState.
        let levelA = ChainLevel(chain: chainA, children: [:])

        // Precondition: A holds the lighter incumbent M2 and KNOWS the heavier leaf.
        let aIncumbent = await chainA.getMainChainTip()
        XCTAssertEqual(aIncumbent, cid(main[1]), "A incumbent tip is M2")
        let heaviest = await chainA.heaviestDescent(fromHash: cid(genesis))
        XCTAssertEqual(heaviest?.tipHash, f5Hash, "A knows F5 is the heaviest leaf from the index")
        XCTAssertEqual(heaviest?.cumulativeWork, UInt256(6), "A knows F5's durable cumulative work (6)")
        // A holds no fork-tail body yet.
        let preF3 = await chainA.getConsensusBlock(hash: cid(fork[2]))
        XCTAssertNil(preF3, "F3 body absent on A")

        // A's transport to peer B: a real ChainSyncer over B's content-addressed
        // store, writing refetched bodies into A's own CAS.
        let syncer = ChainSyncer(
            fetcher: oracleCAS, // the peer/oracle B's content-addressed store.
            store: { cid, data in await aCAS.store(rawCid: cid, data: data) },
            genesisBlockHash: cid(genesis),
            validateBlockConsensus: true
        )

        // THE PRODUCTION CHOKE POINT: A's node loop drives the wired trigger. It
        // detects the held heavier subtree, refetches+validates the missing interior
        // bodies over the real transport, and submits them through the real
        // fork-choice path — all inside ChainLevel.backfillHeldHeavierSubtree. This
        // is the exact call a node makes; the test does NOT touch backfillSubtree.
        let converged = try await levelA.backfillHeldHeavierSubtree(syncer: syncer, maxBodies: 64)
        XCTAssertTrue(converged, "A backfilled the held heavier subtree over the real transport")

        // CONVERGENCE: A adopts the strictly-heavier tip F5 — same as the oracle's tip.
        let convergedTip = await chainA.getMainChainTip()
        XCTAssertEqual(convergedTip, f5Hash, "A converges on the heavier tip F5")
        let aWork = await chainA.getCumulativeWork(forHash: f5Hash)
        XCTAssertEqual(aWork, UInt256(6), "A's adopted tip carries the full heavy-branch work")
        // No body-pruned hole remains: the heavy interior is now present on A.
        let f3Body = await chainA.getConsensusBlock(hash: cid(fork[2]))
        XCTAssertNotNil(f3Body, "F3 body now present on A")
        // No downgrade ever occurred: the adopted tip strictly outweighs the old M2.
        XCTAssertGreaterThan(aWork!, UInt256(3), "adopted tip strictly heavier than the old incumbent M2")

        // Finding #3 (convergence is observed, not assumed): the return value reflects
        // ACTUAL chain convergence, not merely "bodies were fetched". Now that A holds
        // F5 there is no remaining hold, so a second pass detects no target and returns
        // false — proving the boolean is gated on the chain tip reaching the target, so
        // a regression to `!backfilled.isEmpty` (which ignores non-adoption) is caught.
        let secondPass = try await levelA.backfillHeldHeavierSubtree(syncer: syncer, maxBodies: 64)
        XCTAssertFalse(secondPass, "no hold remains after convergence ⇒ no false-positive success")
    }

    // MARK: - Convergence through the PRODUCTION choke point (Lattice.processBlockHeader)

    // The load-bearing two-node convergence test driven entirely through the real
    // production entry point. Node B (oracle) holds the full heavier chain in its CAS.
    // Node A is a real `Lattice` over a real `ChainLevel` holding the lighter incumbent
    // M2 plus the CFC-A1 hold (heavy tail F2..F5 in the retained weight index, bodies
    // absent). A's node wires the backfill provider — a real `ChainSyncer` to B
    // — exactly as the node does. A then RECEIVES a fork block (F2) over the same
    // `Lattice.processBlockHeader` path gossip uses; that submission is non-extending
    // (F2 only ties M2 at height 2), so it lands in the non-extending choke point, which
    // drives the wired backfill: A refetches+validates F3..F5 over the real transport,
    // submits them through the real fork-choice path, and converges on B's heavier tip
    // F5. The test never calls `backfillHeldHeavierSubtree`/`backfillSubtree` directly —
    // a regression that unwires the choke point fails here.
    func testProcessBlockHeaderChokePointConvergesOnHeavierTipViaRealTransport() async throws {
        // Node B (oracle): full chain in its CAS.
        let oracleCAS = StorableFetcher()
        let (genesis, main, fork) = try await buildOracle(into: oracleCAS)
        let f2 = fork[1]
        let f5Hash = cid(fork[4])

        // Node A: the held incumbent — tip M2, heavy fork tail F2..F5 bodies absent.
        // A's CAS holds the live bodies AND F2 (the fork block A is about to receive
        // over gossip), mirroring a node that just got F2 relayed to it.
        let aCAS = StorableFetcher()
        for b in [genesis, main[0], main[1], fork[0], f2] {
            try await storeBlock(b, to: aCAS)
        }
        let chainA = try ChainState.restore(from: buildHeldNodeA(genesis: genesis, main: main, fork: fork))
        let levelA = ChainLevel(chain: chainA, children: [:])
        let latticeA = Lattice(nexus: levelA)

        // Wire A's node-level backfill transport: a real `ChainSyncer` to peer B,
        // writing refetched bodies into A's own CAS — the exact provider the node sets.
        let genesisHash = cid(genesis)
        await latticeA.setBackfillSyncerProvider { _ in
            let syncer = ChainSyncer(
                fetcher: oracleCAS,
                store: { cid, data in await aCAS.store(rawCid: cid, data: data) },
                genesisBlockHash: genesisHash,
                validateBlockConsensus: true
            )
            return (syncer, 64)
        }

        // Precondition: A holds the lighter incumbent M2.
        let preTip = await chainA.getMainChainTip()
        XCTAssertEqual(preTip, cid(main[1]), "A incumbent tip is M2")
        let preF3 = await chainA.getConsensusBlock(hash: cid(fork[2]))
        XCTAssertNil(preF3, "F3 body absent on A pre-receive")

        // THE PRODUCTION ENTRY POINT: A receives fork block F2 over the same path gossip
        // uses. F2 only ties M2 (height 2, cum work 3), so the submission is
        // non-extending and lands in the choke point that drives the wired backfill.
        let result = await latticeA.processBlockHeader(
            try! VolumeImpl<Block>(node: f2), fetcher: aCAS
        )
        XCTAssertTrue(result.isAccepted, "A accepts: the choke point backfilled and adopted the heavier branch")

        // CONVERGENCE: A adopts the strictly-heavier tip F5 — same as the oracle's tip.
        let convergedTip = await chainA.getMainChainTip()
        XCTAssertEqual(convergedTip, f5Hash, "A converges on the heavier tip F5")
        let aWork = await chainA.getCumulativeWork(forHash: f5Hash)
        XCTAssertEqual(aWork, UInt256(6), "A's adopted tip carries the full heavy-branch work")
        let postF3 = await chainA.getConsensusBlock(hash: cid(fork[2]))
        XCTAssertNotNil(postF3, "F3 body now present on A")
        XCTAssertGreaterThan(aWork!, UInt256(3), "adopted tip strictly heavier than the old incumbent M2")
    }

    // MARK: - Fail closed on forged / unresolvable bodies (no downgrade)

    func testForgedBodyIsRejectedAndDoesNotDowngrade() async throws {
        let oracleCAS = StorableFetcher()
        let (genesis, main, fork) = try await buildOracle(into: oracleCAS)
        let f5Hash = cid(fork[4])

        // A FORGED CAS: it answers the heavy-tail CIDs with a DIFFERENT block's bytes
        // (content that does not hash to the requested CID). The genesis + main +
        // fork-base bodies are served honestly so the walk can reach the forgery.
        let forgedCAS = StorableFetcher()
        for b in [genesis, main[0], main[1], fork[0]] {
            try await storeBlock(b, to: forgedCAS)
        }
        // Serve a wrong body under each heavy-tail CID: store fork[0]'s bytes (F1)
        // under F2..F5's CIDs. The decoded block will not hash to the requested CID.
        let f1Data = fork[0].toData()!
        for tail in [fork[1], fork[2], fork[3], fork[4]] {
            await forgedCAS.store(rawCid: cid(tail), data: f1Data)
        }

        let aCAS = StorableFetcher()
        for b in [genesis, main[0], main[1], fork[0]] { try await storeBlock(b, to: aCAS) }
        let chainA = try ChainState.restore(from: buildHeldNodeA(genesis: genesis, main: main, fork: fork))
        let levelA = ChainLevel(chain: chainA, children: [:])
        let incumbentTip = await chainA.getMainChainTip()
        XCTAssertEqual(incumbentTip, cid(main[1]), "A incumbent tip is M2")
        _ = f5Hash // tip is computed by the production trigger, not passed in.

        let syncer = ChainSyncer(
            fetcher: forgedCAS,
            store: { cid, data in await aCAS.store(rawCid: cid, data: data) },
            genesisBlockHash: cid(genesis),
            validateBlockConsensus: true
        )

        // The production trigger MUST fail closed on the forged content (cid != hash).
        do {
            _ = try await levelA.backfillHeldHeavierSubtree(syncer: syncer, maxBodies: 64)
            XCTFail("forged bodies must throw, not be adopted")
        } catch SyncError.contentMismatch {
            // expected: content binding rejected the forgery.
        }

        // No forged body was submitted, so A did NOT downgrade onto a lighter branch
        // and did NOT adopt the heavier tip from unverified data — it still holds M2.
        let tipAfter = await chainA.getMainChainTip()
        XCTAssertEqual(tipAfter, cid(main[1]),
                       "A still holds the incumbent M2 (invalid bodies ≠ a downgrade)")
        let forgedF3 = await chainA.getConsensusBlock(hash: cid(fork[2]))
        XCTAssertNil(forgedF3, "no forged heavy-tail body was installed on A")
    }

    func testUnresolvableBodyFailsClosedAndDoesNotDowngrade() async throws {
        let oracleCAS = StorableFetcher()
        let (genesis, main, fork) = try await buildOracle(into: oracleCAS)
        let f5Hash = cid(fork[4])

        // A CAS that is MISSING the heavy tail entirely (peer pruned / unreachable):
        // only genesis + main + fork-base resolve.
        let partialCAS = StorableFetcher()
        for b in [genesis, main[0], main[1], fork[0]] {
            try await storeBlock(b, to: partialCAS)
        }

        let aCAS = StorableFetcher()
        for b in [genesis, main[0], main[1], fork[0]] { try await storeBlock(b, to: aCAS) }
        let chainA = try ChainState.restore(from: buildHeldNodeA(genesis: genesis, main: main, fork: fork))
        let levelA = ChainLevel(chain: chainA, children: [:])
        _ = f5Hash // tip is computed by the production trigger, not passed in.

        let syncer = ChainSyncer(
            fetcher: partialCAS,
            store: { cid, data in await aCAS.store(rawCid: cid, data: data) },
            genesisBlockHash: cid(genesis),
            fetchTimeout: .seconds(2),
            validateBlockConsensus: true)

        do {
            _ = try await levelA.backfillHeldHeavierSubtree(syncer: syncer, maxBodies: 64)
            XCTFail("unresolvable bodies must throw, not be adopted")
        } catch SyncError.bodyUnavailable {
            // expected: the fetch could not be satisfied — UNAVAILABLE, not invalid.
            // Missing data stays a refetch/hold condition (Finding #2), never an
            // invalid-body classification that would mark the heavier branch bad.
        }

        let tipAfter = await chainA.getMainChainTip()
        XCTAssertEqual(tipAfter, cid(main[1]),
                       "A still holds the incumbent M2 (unavailable bodies ≠ a downgrade)")
    }

    // MARK: - Convergence over a REAL TCP transport (Finding #2)

    // The same load-bearing convergence, but A refetches the missing interior bodies
    // over an ACTUAL loopback TCP socket to peer B (not an in-process CAS). B listens
    // on a real port and serves block bytes by CID; A's `ChainSyncer` fetcher opens an
    // `NWConnection`, requests each missing body over the wire, validates it, and
    // converges on B's heavier tip F5. This proves the backfill works through real
    // async network I/O — the production seam the node fills with its Ivy transport.
    func testRefetchesOverRealTCPTransportAndConvergesOnHeavierTip() async throws {
        // Node B (oracle): full chain in its CAS, served over a real TCP socket.
        let oracleCAS = StorableFetcher()
        let (genesis, main, fork) = try await buildOracle(into: oracleCAS)
        let f5Hash = cid(fork[4])
        let server = try TCPCASServer(cas: oracleCAS)
        defer { server.stop() }

        // Node A: the held incumbent — tip M2, heavy fork tail bodies absent.
        let aCAS = StorableFetcher()
        for b in [genesis, main[0], main[1], fork[0]] { try await storeBlock(b, to: aCAS) }
        let chainA = try ChainState.restore(from: buildHeldNodeA(genesis: genesis, main: main, fork: fork))
        let levelA = ChainLevel(chain: chainA, children: [:])

        let preTip = await chainA.getMainChainTip()
        XCTAssertEqual(preTip, cid(main[1]), "A incumbent tip is M2")
        let preF3 = await chainA.getConsensusBlock(hash: cid(fork[2]))
        XCTAssertNil(preF3, "F3 body absent on A")

        // A's transport to B is a REAL TCP fetcher hitting B's listening socket.
        let syncer = ChainSyncer(
            fetcher: TCPCASFetcher(port: server.port),
            store: { cid, data in await aCAS.store(rawCid: cid, data: data) },
            genesisBlockHash: cid(genesis),
            validateBlockConsensus: true
        )

        let converged = try await levelA.backfillHeldHeavierSubtree(syncer: syncer, maxBodies: 64)
        XCTAssertTrue(converged, "A backfilled the held heavier subtree over a real TCP socket")

        let convergedTip = await chainA.getMainChainTip()
        XCTAssertEqual(convergedTip, f5Hash, "A converges on the heavier tip F5 over TCP")
        let aWork = await chainA.getCumulativeWork(forHash: f5Hash)
        XCTAssertEqual(aWork, UInt256(6), "A's TCP-adopted tip carries the full heavy-branch work")
        let postF3 = await chainA.getConsensusBlock(hash: cid(fork[2]))
        XCTAssertNotNil(postF3, "F3 body now present on A")
    }

    // MARK: - maxBodies overflow fails closed (Finding #5a)

    // The bounded-refetch depth guard: the heavy tail is 4 bodies deep (F2..F5) but
    // the cap is 2. The backfill MUST throw the DISTINCT `backfillTooDeep` error
    // (Finding #4 — not `insufficientWork`, which is a PoW/weight invariant) and MUST
    // NOT partially adopt or downgrade: A stays on the incumbent M2 with no fork-tail
    // body installed (Finding #1 — nothing is promoted to the CAS on a failed batch).
    func testMaxBodiesOverflowFailsClosedWithDistinctError() async throws {
        let oracleCAS = StorableFetcher()
        let (genesis, main, fork) = try await buildOracle(into: oracleCAS)

        let aCAS = StorableFetcher()
        for b in [genesis, main[0], main[1], fork[0]] { try await storeBlock(b, to: aCAS) }
        let chainA = try ChainState.restore(from: buildHeldNodeA(genesis: genesis, main: main, fork: fork))
        let levelA = ChainLevel(chain: chainA, children: [:])
        let preTip = await chainA.getMainChainTip()
        XCTAssertEqual(preTip, cid(main[1]), "A incumbent tip is M2")

        let syncer = ChainSyncer(
            fetcher: oracleCAS,
            store: { cid, data in await aCAS.store(rawCid: cid, data: data) },
            genesisBlockHash: cid(genesis),
            validateBlockConsensus: true
        )

        do {
            // Heavy tail F2..F5 = 4 missing bodies; cap of 2 must refuse.
            _ = try await levelA.backfillHeldHeavierSubtree(syncer: syncer, maxBodies: 2)
            XCTFail("a tail deeper than maxBodies must throw, not partially adopt")
        } catch SyncError.backfillTooDeep {
            // expected: the DISTINCT bounded-refetch refusal (not insufficientWork).
        }

        // No partial adoption / no downgrade: A still holds the incumbent M2.
        let tipAfter = await chainA.getMainChainTip()
        XCTAssertEqual(tipAfter, cid(main[1]), "A still holds incumbent M2 after a too-deep refusal")
        // And the staged-but-unpromoted bodies were never admitted to the CAS
        // (Finding #1: nothing persists unless the WHOLE batch validated).
        let f2Body = await chainA.getConsensusBlock(hash: cid(fork[1]))
        XCTAssertNil(f2Body, "no F2 body installed")
        let f3Body = await chainA.getConsensusBlock(hash: cid(fork[2]))
        XCTAssertNil(f3Body, "no F3 body installed")
        XCTAssertFalse(aCAS.contains(rawCid: cid(fork[1])), "F2 body never promoted to A's CAS")
        XCTAssertFalse(aCAS.contains(rawCid: cid(fork[2])), "F3 body never promoted to A's CAS")
    }

    // MARK: - Periodic sync trigger drives the same convergence (Finding #5b)

    // The backfill must also converge when driven OUTSIDE the processBlockHeader
    // choke point — e.g. a periodic sync pass that calls `backfillHeldHeavierSubtree`
    // directly with no preceding block submission. Here A receives NO fork block; the
    // periodic sweep alone detects the held heavier subtree and converges on F5,
    // proving the trigger is not coupled to a block-arrival event.
    func testPeriodicSyncTriggerConvergesWithoutBlockArrival() async throws {
        let oracleCAS = StorableFetcher()
        let (genesis, main, fork) = try await buildOracle(into: oracleCAS)
        let f5Hash = cid(fork[4])

        let aCAS = StorableFetcher()
        // A holds only its live bodies — it never received any fork block over gossip.
        for b in [genesis, main[0], main[1], fork[0]] { try await storeBlock(b, to: aCAS) }
        let chainA = try ChainState.restore(from: buildHeldNodeA(genesis: genesis, main: main, fork: fork))
        let levelA = ChainLevel(chain: chainA, children: [:])
        let preTip = await chainA.getMainChainTip()
        XCTAssertEqual(preTip, cid(main[1]), "A incumbent tip is M2")

        let syncer = ChainSyncer(
            fetcher: oracleCAS,
            store: { cid, data in await aCAS.store(rawCid: cid, data: data) },
            genesisBlockHash: cid(genesis),
            validateBlockConsensus: true
        )

        // A periodic sync pass calls the trigger directly (no block arrival).
        let converged = try await levelA.backfillHeldHeavierSubtree(syncer: syncer, maxBodies: 64)
        XCTAssertTrue(converged, "the periodic pass detected the hold and backfilled it")
        let convergedTip = await chainA.getMainChainTip()
        XCTAssertEqual(convergedTip, f5Hash,
                       "periodic sync converges on the heavier tip F5 without any block arrival")
    }

    // MARK: - Cancelled syncer mid-backfill fails closed (Finding #5c)

    // A syncer cancelled before/during the walk must throw `SyncError.cancelled` and
    // NOT adopt or downgrade: a cancelled backfill is an aborted refetch, never a
    // fork-choice decision. A stays on the incumbent M2 with no tail body installed.
    func testCancelledSyncerMidBackfillFailsClosed() async throws {
        let oracleCAS = StorableFetcher()
        let (genesis, main, fork) = try await buildOracle(into: oracleCAS)

        let aCAS = StorableFetcher()
        for b in [genesis, main[0], main[1], fork[0]] { try await storeBlock(b, to: aCAS) }
        let chainA = try ChainState.restore(from: buildHeldNodeA(genesis: genesis, main: main, fork: fork))
        let levelA = ChainLevel(chain: chainA, children: [:])

        let syncer = ChainSyncer(
            fetcher: oracleCAS,
            store: { cid, data in await aCAS.store(rawCid: cid, data: data) },
            genesisBlockHash: cid(genesis),
            validateBlockConsensus: true
        )
        await syncer.cancel() // cancel before the walk begins.

        do {
            _ = try await levelA.backfillHeldHeavierSubtree(syncer: syncer, maxBodies: 64)
            XCTFail("a cancelled syncer must throw, not adopt")
        } catch SyncError.cancelled {
            // expected: aborted refetch, fail closed.
        }

        let tipAfter = await chainA.getMainChainTip()
        XCTAssertEqual(tipAfter, cid(main[1]),
                       "A still holds incumbent M2 after a cancelled backfill")
        let f3Body = await chainA.getConsensusBlock(hash: cid(fork[2]))
        XCTAssertNil(f3Body, "no fork-tail body installed by a cancelled backfill")
        XCTAssertFalse(aCAS.contains(rawCid: cid(fork[2])),
                       "cancelled backfill promoted nothing to A's CAS")
    }

    // MARK: - Fork base itself body-pruned still triggers backfill (fresh review finding)

    // The held heavier branch's FORK BASE (its deepest off-main ancestor) may also be
    // body-pruned — present only in the weight index. The detector must still
    // fire: the index already knows the branch is strictly heavier, so a pruned
    // fork-base body is one more refetch target, not a reason to suppress convergence.
    // Regression for the gap where `heldHeavierBackfillTarget` resolved the fork base
    // from the index for weighing but then required its LIVE body (`hashToBlock`), so a
    // fully-pruned heavy branch (fork base included) would never backfill.
    func testForkBaseBodyAlsoPrunedStillTriggersBackfillTarget() async throws {
        let oracleCAS = StorableFetcher()
        let (genesis, main, fork) = try await buildOracle(into: oracleCAS)
        let chainA = try ChainState.restore(
            from: buildHeldNodeA(genesis: genesis, main: main, fork: fork, forkBasePruned: true))

        let target = await chainA.heldHeavierBackfillTarget()
        XCTAssertNotNil(target,
                        "a heavier branch whose fork-base body is also pruned must still trigger backfill")
        XCTAssertEqual(target?.tipHash, cid(fork[4]), "the heaviest index-known leaf is F5")
        // Every fork body, including the pruned fork base F1, is a refetch target.
        XCTAssertEqual(target?.missingBodies.count, 5, "F1..F5 are all missing bodies to refetch")
        XCTAssertTrue(target?.missingBodies.contains(cid(fork[0])) ?? false,
                      "the pruned fork base F1 is itself a refetch target")
    }
}
