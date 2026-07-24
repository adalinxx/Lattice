import XCTest
@testable import Lattice
import UInt256
import cashew

final class ProtocolResourceBoundTests: XCTestCase {
    func testCIDIdentityHasAConsensusTextBound() {
        let cid = testCID("bounded-cid")
        XCTAssertLessThanOrEqual(cid.utf8.count, CIDIdentity.maximumTextBytes)
        XCTAssertEqual(CIDIdentity.canonicalString(cid), cid)
        XCTAssertNil(CIDIdentity.canonicalString(
            String(repeating: "x", count: CIDIdentity.maximumTextBytes + 1)
        ))
    }

    func testStateAtomBoundariesAndGrammar() {
        XCTAssertTrue(StateAtomLimits.isAccount(String(repeating: "a", count: 128)))
        XCTAssertFalse(StateAtomLimits.isAccount(String(repeating: "a", count: 129)))
        XCTAssertFalse(StateAtomLimits.isAccount("alice bob"))
        XCTAssertFalse(StateAtomLimits.isAccount("alice/bob"))
        XCTAssertFalse(StateAtomLimits.isAccount("álîce"))

        XCTAssertTrue(StateAtomLimits.isDirectory(String(repeating: "d", count: 64)))
        XCTAssertFalse(StateAtomLimits.isDirectory(String(repeating: "d", count: 65)))
        XCTAssertFalse(StateAtomLimits.isDirectory("parent/child"))

        XCTAssertTrue(StateAtomLimits.isGeneralKey(String(repeating: "k", count: 128)))
        XCTAssertFalse(StateAtomLimits.isGeneralKey(String(repeating: "k", count: 129)))
    }

    func testTransactionShapeChecksEveryStateKeyAtom() {
        let body = TransactionBody(
            accountActions: [AccountAction(owner: "owner", delta: 1)],
            actions: [Action(key: "key", oldValue: nil, newValue: "value")],
            depositActions: [
                DepositAction(
                    nonce: 1,
                    demander: "demander",
                    amountDemanded: 1,
                    amountDeposited: 1
                ),
            ],
            genesisActions: [
                GenesisAction(directory: "Child", blockCID: "ignored"),
            ],
            receiptActions: [
                ReceiptAction(
                    withdrawer: "withdrawer",
                    nonce: 1,
                    demander: "demander",
                    amountDemanded: 1,
                    directory: "Child"
                ),
            ],
            withdrawalActions: [
                WithdrawalAction(
                    withdrawer: "withdrawer",
                    nonce: 1,
                    demander: "demander",
                    amountDemanded: 1,
                    amountWithdrawn: 1
                ),
            ],
            signers: ["withdrawer"],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus", "Child"]
        )
        XCTAssertTrue(body.stateAtomsAreValid())

        let invalid = TransactionBody(
            accountActions: body.accountActions,
            actions: body.actions,
            depositActions: body.depositActions,
            genesisActions: body.genesisActions,
            receiptActions: [
                ReceiptAction(
                    withdrawer: "withdrawer",
                    nonce: 1,
                    demander: "demander",
                    amountDemanded: 1,
                    directory: "Child/Grandchild"
                ),
            ],
            withdrawalActions: body.withdrawalActions,
            signers: body.signers,
            fee: body.fee,
            nonce: body.nonce,
            chainPath: body.chainPath
        )
        XCTAssertFalse(invalid.stateAtomsAreValid())
    }

    func testReceiptStateUsesGoldenDomainSeparatedDigest() async throws {
        let action = ReceiptAction(
            withdrawer: "bob",
            nonce: 7,
            demander: "alice",
            amountDemanded: 42,
            directory: "Child"
        )
        let key = ReceiptKey(receiptAction: action)
        XCTAssertEqual(
            key.storageKey,
            "e055b2f2d5ed425be5e6917175e19f86c5ab825b2b6c811af74c93befc48e6c1"
        )
        XCTAssertEqual(
            key.storageKey.count,
            64
        )

        let fetcher = StorableFetcher()
        let (updated, _) = try await LatticeState.empty.receiptState
            .proveAndUpdateState(
                allReceiptActions: [action],
                fetcher: fetcher
            )
        XCTAssertNil(try updated.node?.get(key: key.description) as String?)
        XCTAssertEqual(
            try updated.node?.get(key: key.storageKey) as String?,
            action.withdrawer
        )
    }

    func testAggregateWithdrawalsRejectDuplicateReceiptKeys() {
        func body(nonces: Range<Int>) -> TransactionBody {
            TransactionBody(
                accountActions: [],
                actions: [],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: nonces.map {
                    WithdrawalAction(
                        withdrawer: "withdrawer",
                        nonce: UInt128($0),
                        demander: "demander",
                        amountDemanded: 1,
                        amountWithdrawn: 1
                    )
                },
                signers: ["withdrawer"],
                fee: 0,
                nonce: 0,
                chainPath: ["Nexus", "Child"]
            )
        }

        let exact = body(nonces: 0..<64)
        XCTAssertTrue(TransactionBody.withdrawalsHaveUniqueReceiptKeys(
            bodies: [exact],
            directory: "Child"
        ))
        XCTAssertTrue(exact.withdrawalActionsAreValid())

        let over = body(nonces: 0..<65)
        XCTAssertTrue(TransactionBody.withdrawalsHaveUniqueReceiptKeys(
            bodies: [over],
            directory: "Child"
        ))
        XCTAssertTrue(over.withdrawalActionsAreValid())

        let duplicate = body(nonces: 0..<1)
        XCTAssertFalse(TransactionBody.withdrawalsHaveUniqueReceiptKeys(
            bodies: [duplicate, duplicate],
            directory: "Child"
        ))
    }

    func testBlockBuilderRejectsInvalidStateAtomBeforeTransition() async throws {
        let body = TransactionBody(
            accountActions: [],
            actions: [
                Action(
                    key: String(repeating: "k", count: 129),
                    oldValue: nil,
                    newValue: "value"
                ),
            ],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let transaction = Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: body)
        )

        do {
            _ = try await BlockBuilder.buildGenesis(
                spec: resourceBoundSpec(),
                transactions: [transaction],
                timestamp: 1,
                target: UInt256.max,
                fetcher: StorableFetcher()
            )
            XCTFail("expected invalid state key to be rejected")
        } catch BlockBuilderError.invalidTransactionContent {
            // Resource grammar is enforced before trie materialization.
        }
    }

    func testGenesisRejectsLatentInvalidActionPolicyModule() async throws {
        let fetcher = StorableFetcher()
        let module = try WasmPolicyModuleHeader(
            node: WasmPolicyModule(bytes: Data([0x00]))
        )
        try await module.storeRecursively(storer: fetcher)
        let policy = WasmPolicyRef(
            moduleCID: module.rawCID,
            scope: .action
        )
        let spec = resourceBoundSpec(wasmPolicies: [policy])
        let genesis = try await buildAndStoreGenesis(
            spec: spec,
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )

        let contextual = try await TransactionBody.batchVerifyPolicies(
            bodies: [],
            spec: spec,
            chainPath: ["Nexus"],
            fetcher: fetcher
        )
        let configured = try await TransactionBody.validateConfiguredPolicyModules(
            spec: spec,
            fetcher: fetcher
        )
        let genesisValid = try await genesis.validateGenesis(
            fetcher: fetcher,
            chainPath: ["Nexus"]
        ).0
        XCTAssertTrue(contextual)
        XCTAssertFalse(configured)
        XCTAssertFalse(genesisValid)
    }

    func testMaximumWasmModuleFitsPublishedVolumeBound() throws {
        let module = WasmPolicyModule(
            bytes: Data(
                repeating: 0,
                count: WasmPolicyEvaluator.maxModuleBytes
            )
        )
        let serialized = try XCTUnwrap(module.toData())
        XCTAssertLessThanOrEqual(
            serialized.count,
            WasmPolicyEvaluator.maximumModuleVolumeBytes
        )
    }
}

private func resourceBoundSpec(
    wasmPolicies: [WasmPolicyRef] = []
) -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: 1_000,
        initialReward: 1,
        halvingInterval: 1_000,
        wasmPolicies: wasmPolicies
    )
}
