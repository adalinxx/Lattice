import XCTest
@testable import Lattice
import UInt256

/// A parent chain attests state continuity so a child chain can validate
/// cross-chain withdrawals against a parent state. The attestation is only
/// meaningful if the attested state is one the parent chain actually PRODUCED
/// by executing its transition.
///
/// The weighed tier records a block's DECLARED `postState` without executing it
/// — `ChainLocalAdmission` calls it "an unverified claim". A block that never
/// becomes canonical is never validated, so it is never excluded, and its
/// unverified claim stays in the graph permanently.
///
/// These tests pin the boundary: an unverified declared state MUST NOT be
/// attestable.
final class ParentStateAttestationTierTests: XCTestCase {
    private let easy = UInt256.max

    private func spec() -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 1_000_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1_024,
            halvingInterval: 10_000,
            retargetWindow: 5
        )
    }

    /// A real, well-formed `LatticeState` that the chain under test never
    /// produced — built by executing a transition on an unrelated chain.
    private func stateFromAnUnrelatedChain(
        fetcher: StorableFetcher
    ) async throws -> LatticeStateHeader {
        let keyPair = CryptoUtils.generateKeyPair()
        let signer = testAddress(publicKey: keyPair.publicKey)
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(key: "unrelated", oldValue: nil, newValue: "v")],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [signer],
            fee: 0,
            nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let unrelated = try await buildAndStoreGenesis(
            spec: spec(),
            transactions: [signedTestTransaction(body, by: keyPair)],
            timestamp: 9_000,
            target: easy,
            nonce: 99,
            fetcher: fetcher
        )
        return unrelated.postState
    }

    /// A sibling of `honest` that declares someone else's state as its own
    /// post-state. Every field the weighed tier checks — version, spec,
    /// `prevState == parent.postState`, height, timestamp, target schedule —
    /// is correct. Only `postState`, which the weighed tier does NOT check,
    /// is a lie.
    private func forgedSibling(
        of honest: Block,
        declaring forged: LatticeStateHeader,
        nonce: UInt64
    ) -> Block {
        Block(
            version: honest.version,
            parent: honest.parent,
            transactions: honest.transactions,
            target: honest.target,
            nextTarget: honest.nextTarget,
            spec: honest.spec,
            parentState: honest.parentState,
            prevState: honest.prevState,
            postState: forged,
            children: honest.children,
            height: honest.height,
            timestamp: honest.timestamp + 1,
            nonce: nonce
        )
    }

    /// C2b: one weighed sibling makes an unproduced state attestable.
    ///
    /// The attacker mines a single block at current difficulty, declaring an
    /// arbitrary post-state. It is a sibling, so it never becomes canonical,
    /// so it is never validated, so it is never excluded — and the parent
    /// vouches for the declared state forever.
    func testWeighedDeclaredPostStateIsNotAttestable() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: spec(), timestamp: 1_000, target: easy, fetcher: fetcher
        )
        let honest = try await buildAndStoreBlock(
            previous: genesis, timestamp: 2_000, target: easy, nonce: 1,
            fetcher: fetcher
        )

        let forgedState = try await stateFromAnUnrelatedChain(fetcher: fetcher)
        let forged = forgedSibling(of: honest, declaring: forgedState, nonce: 7)
        _ = try await storeBuiltBlock(forged, in: fetcher)

        let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
        let admitted = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: forged),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            mode: .weighed,
            stage: testAdmissionStage
        )
        guard case .accepted = admitted else {
            return XCTFail("weighed admission accepts a declared post-state; got \(admitted)")
        }

        // The anchor a child chain would hold: the honest sibling's prevState.
        let anchor = honest.prevState.rawCID
        let chain = await level.chain

        let attested = await chain.hasStateContinuity(
            from: anchor,
            to: forgedState.rawCID
        )
        XCTAssertFalse(
            attested,
            """
            The parent attested a state it never produced. A child anchored at \
            \(anchor) could be moved to an attacker-authored parent state and \
            settle cross-chain withdrawals against its forged receiptState.
            """
        )
    }

    /// C1: block 1 must prove its `parentState` like every other height.
    ///
    /// Spec §5.3 step 6 has no height-1 exemption: "For non-genesis, compare
    /// the predecessor's `parentState` with `B.parentState`. Equality is
    /// sufficient; otherwise require an exact continuity link." A genesis's
    /// `parentState` is `emptyHeader`, and every genesis's `prevState` is
    /// `emptyHeader` too, so continuity from it terminates at the PARENT's own
    /// genesis — i.e. "reachable from real parent history", which is exactly
    /// the anchor block 1 needs.
    ///
    /// Without that requirement, block 1's `parentState` is checked only by the
    /// proof's terminal binding, which compares the child's declared value
    /// against a CARRIER the attacker authored — two attacker-chosen fields.
    func testBlockOneMustProveItsParentStateAnchor() async throws {
        let fetcher = StorableFetcher()
        let childGenesis = try await buildAndStoreGenesis(
            spec: spec(), timestamp: 1_000, target: easy, nonce: 1,
            fetcher: fetcher
        )

        // An unrelated chain, standing in for the carrier bytes an attacker
        // authors. §9.5 requires no carrier canonicity, so this need not be a
        // block of the child's actual parent chain.
        // It must carry real state: a genesis with no transactions has
        // `postState == emptyHeader`, which equals a child genesis's
        // `parentState` and would take the equality branch rather than
        // exercising the anchor requirement at all.
        let keyPair = CryptoUtils.generateKeyPair()
        let unrelatedGenesis = try await buildAndStoreGenesis(
            spec: spec(),
            transactions: [signedTestTransaction(
                TransactionBody(
                    accountActions: [],
                    actions: [Action(key: "k", oldValue: nil, newValue: "v")],
                    depositActions: [],
                    genesisActions: [],
                    receiptActions: [],
                    withdrawalActions: [],
                    signers: [testAddress(publicKey: keyPair.publicKey)],
                    fee: 0,
                    nonce: 0,
                    chainPath: [DEFAULT_ROOT_DIRECTORY]
                ),
                by: keyPair
            )],
            timestamp: 500, target: easy, nonce: 2, fetcher: fetcher
        )
        XCTAssertNotEqual(
            unrelatedGenesis.postState.rawCID,
            LatticeState.emptyHeader.rawCID,
            "the carrier chain must carry real state or the test is vacuous"
        )
        let shell = try await buildAndStoreBlock(
            previous: unrelatedGenesis, timestamp: 1_500, target: easy,
            nonce: 3, fetcher: fetcher
        )
        // Block 1, bound to the shell's pre-state rather than to anything the
        // child's real parent chain ever produced.
        let blockOne = try await buildAndStoreBlock(
            previous: childGenesis, parentChainBlock: shell,
            timestamp: 2_000, target: easy, nonce: 4, fetcher: fetcher
        )
        // A carrier sharing that pre-state and naming block 1, so the proof's
        // terminal binding is satisfied by construction.
        let carrier = try await buildAndStoreBlock(
            previous: unrelatedGenesis, children: ["Child": blockOne],
            timestamp: 1_600, target: easy, nonce: 5, fetcher: fetcher
        )

        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )

        let outcome = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: blockOne),
            fetcher: fetcher,
            childPackage: try await childValidationPackage(
                proof: proof, fetcher: fetcher
            ),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )

        // Block 1 must be made to prove its anchor. Demanding the continuity
        // evidence is retriable and correct; silently accepting an unanchored
        // parentState is not.
        guard case .rejected(let failure, _, _) = outcome else {
            return XCTFail(
                """
                Block 1 was admitted with a parentState anchored to nothing but \
                attacker-supplied carrier bytes. Cross-chain withdrawals settle \
                against this state, so its receiptState can be forged; got \
                \(outcome)
                """
            )
        }
        guard case .crossChainEvidenceRequired(.parentStateContinuity) = failure
        else {
            return XCTFail(
                "expected a retriable demand for continuity evidence, got \(failure)"
            )
        }
    }

    /// The same state, reached through a block the chain DID execute, must stay
    /// attestable — the filter must narrow to unverified claims and nothing
    /// more. Without this, the fix would be indistinguishable from breaking
    /// continuity outright.
    func testExecutedPostStateRemainsAttestable() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: spec(), timestamp: 1_000, target: easy, fetcher: fetcher
        )
        let executed = try await buildAndStoreBlock(
            previous: genesis, timestamp: 2_000, target: easy, nonce: 1,
            fetcher: fetcher
        )

        let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
        let admitted = try await level.admitBlockHeaderChainLocal(
            try BlockHeader(node: executed),
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        guard case .accepted = admitted else {
            return XCTFail("eager admission must accept, got \(admitted)")
        }

        let chain = await level.chain
        let attested = await chain.hasStateContinuity(
            from: executed.prevState.rawCID,
            to: executed.postState.rawCID
        )
        XCTAssertTrue(
            attested,
            "an executed transition must remain attestable"
        )
    }
}
