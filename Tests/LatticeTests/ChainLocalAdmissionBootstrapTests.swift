import Foundation
import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256
import cashew
import WAT

final class ChainLocalAdmissionBootstrapTests: XCTestCase {
    func testRootLevelRejectsASecondParentlessRoot() async throws {
        let fetcher = StorableFetcher()
        let first = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let second = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let level = AdmissionFixture.makeLevel(genesis: first)
        let secondHeader = try BlockHeader(node: second)

        let result = try await level.admit(secondHeader, fetcher: fetcher)

        XCTAssertEqual(result.failure, .protocolInvalid)
        let containsSecond = await level.chain.contains(blockHash: secondHeader.rawCID)
        XCTAssertFalse(containsSecond)

        let targetMiss = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 3_000,
            target: UInt256(1),
            nonce: 2,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(targetMiss.proofOfWorkHash(), targetMiss.target)
        let missResult = try await level.admit(targetMiss, fetcher: fetcher)
        XCTAssertEqual(missResult.failure, .proofOfWorkInvalid)
    }

    func testPublicBootstrapRequiresVerifiedGenesisAndStorage() async throws {
        let fetcher = StorableFetcher()
        let transaction = AdmissionFixture.unsignedStateChangingGenesisTransaction(
            key: "bootstrap",
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
        )
        let childGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 1,
            transactions: [transaction]
        )
        let context = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        let header = try BlockHeader(node: childGenesis)
        // The self-contained genesis is authorized solely by the parent's record
        // (ParentGenesisLink), bound to the empty parent state. No carrier proof.
        let genesisLink = testParentGenesisLink(
            directory: "Child",
            childGenesisCID: header.rawCID,
            parentStateCID: childGenesis.parentState.rawCID
        )

        // A ParentGenesisLink that does not authorize this exact genesis (wrong
        // recorded state) is rejected — the record gate is the sole authorization.
        let wrongFact = try await ChainLevel.bootstrap(
            context: context,
            genesisHeader: header,
            fetcher: fetcher,
            parentGenesisLink: testParentGenesisLink(
                directory: "Child",
                childGenesisCID: header.rawCID,
                parentStateCID: testCID("wrong-deployment-state")
            ),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        XCTAssertEqual(wrongFact.failure, .providerMalformedEvidence)

        do {
            _ = try await ChainLevel.bootstrap(
                context: context,
                genesisHeader: header,
                fetcher: fetcher,
                parentGenesisLink: genesisLink,
                validationContentStorer: FailingAdmissionStorer(),
                materializedVolumeStorer: FailingAdmissionStorer(),
                stage: testAdmissionStage
            )
            XCTFail("storage must gate first-root visibility")
        } catch ChainLocalTestError.storageFailure {}

        let bootstrapResult = try await ChainLevel.bootstrap(
            context: context,
            genesisHeader: header,
            fetcher: fetcher,
            parentGenesisLink: genesisLink,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        guard case .accepted(let bootstrap) = bootstrapResult else {
            return XCTFail("the target-hit child genesis must bootstrap")
        }
        let child = bootstrap.level
        XCTAssertFalse(bootstrap.stateDiff.created.isEmpty)
        XCTAssertNotNil(bootstrap.materializedPostState)
        XCTAssertEqual(
            bootstrap.commit,
            ChainCommit(
                tipHash: header.rawCID,
                canonicalBlocksAdded: [header.rawCID: 0]
            )
        )
        let childTip = await child.chain.canonicalTip
        XCTAssertEqual(childTip, header.rawCID)

        let nonGenesis = try await AdmissionFixture.makeChild(
            of: childGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2
        )
        do {
            _ = try await ChainLevel.bootstrap(
                context: context,
                genesisHeader: try BlockHeader(node: nonGenesis),
                fetcher: fetcher,
                parentGenesisLink: genesisLink,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: testAdmissionStage
            )
            XCTFail("a non-genesis block cannot create a child runtime")
        } catch let failure as BlockImportError {
            XCTAssertEqual(failure, .protocolInvalid)
        }
    }

    func testPublicRootBootstrapStagesTransactionGenesisBeforeVisibility() async throws {
        let fetcher = StorableFetcher()
        let transaction = AdmissionFixture.unsignedStateChangingGenesisTransaction(
            key: "root-bootstrap",
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let genesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [transaction]
        )
        let header = try BlockHeader(node: genesis)
        let context = testChainContext(path: [DEFAULT_ROOT_DIRECTORY])

        do {
            _ = try await ChainLevel.bootstrap(
                context: context,
                genesisHeader: header,
                fetcher: fetcher,
                validationContentStorer: FailingAdmissionStorer(),
                materializedVolumeStorer: FailingAdmissionStorer(),
                stage: testAdmissionStage
            )
            XCTFail("storage must gate root visibility")
        } catch ChainLocalTestError.storageFailure {}

        do {
            _ = try await ChainLevel.bootstrap(
                context: context,
                genesisHeader: header,
                fetcher: fetcher,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: { _ in throw ChainLocalTestError.stageFailure }
            )
            XCTFail("staging must gate root visibility")
        } catch ChainLocalTestError.stageFailure {}

        let recorder = AdmissionStageRecorder()
        let result = try await ChainLevel.bootstrap(
            context: context,
            genesisHeader: header,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: { batch in await recorder.stage(batch) }
        )

        XCTAssertFalse(result.stateDiff.created.isEmpty)
        XCTAssertNotNil(result.materializedPostState)
        let rootChain = await result.level.chain
        let rootTip = await rootChain.canonicalTip
        XCTAssertEqual(rootTip, header.rawCID)
        let batches = await recorder.recordedBatches()
        XCTAssertEqual(batches.count, 1)
        let restored = try await ChainState.restore(replaying: batches)
        let restoredTip = await restored.canonicalTip
        let restoredRevision = await restored.currentRevision()
        let liveRevision = await rootChain.currentRevision()
        XCTAssertEqual(restoredTip, rootTip)
        XCTAssertEqual(restoredRevision, liveRevision)
    }

    func testGenesisPolicyResourceLimitIsUnavailableNotConsensus() async throws {
        // A policy module declaring more initial memory than THIS node's limit
        // must yield an UNAVAILABLE verdict (this node cannot verify), never
        // protocolInvalid — otherwise two nodes with different limits fork on the
        // same genesis. Raising the node-local limit (injected via
        // ValidationContext) admits the very same block.
        let fetcher = StorableFetcher()
        let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: Data(try wat2wasm("""
        (module
          (memory (export "memory") 33)
          (func (export "lattice_alloc") (param $len i32) (result i32) i32.const 1024)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """))))
        try await module.storeRecursively(storer: fetcher)
        let policy = WasmPolicyRef(moduleCID: module.rawCID, scope: .transaction)
        let genesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(wasmPolicies: [policy]),
            timestamp: 1_000,
            target: AdmissionFixture.easy,
            fetcher: fetcher
        )
        let header = try BlockHeader(node: genesis)
        let context = testChainContext()

        // Default limit (2 MiB) < 33 pages (2.06 MiB): unavailable, not invalid.
        do {
            _ = try await ChainLevel.bootstrap(
                context: context, genesisHeader: header, fetcher: fetcher,
                validationContentStorer: fetcher, materializedVolumeStorer: fetcher,
                stage: testAdmissionStage)
            XCTFail("oversized policy must fail admission on the limited node")
        } catch let failure as BlockImportError {
            XCTAssertEqual(failure, .unavailableEvidence)
        }

        // Same block, node with a raised limit injected via ValidationContext.
        let raised = ValidationContext(
            nowMilliseconds: 10_000,
            wasmResourceLimits: WasmPolicyResourceLimits(maxMemoryBytes: 4 * 1024 * 1024))
        let result = try await ChainLevel.bootstrap(
            context: context, genesisHeader: header, fetcher: fetcher,
            validationContext: raised,
            validationContentStorer: fetcher, materializedVolumeStorer: fetcher,
            stage: testAdmissionStage)
        let tip = await result.level.chain.canonicalTip
        XCTAssertEqual(tip, header.rawCID)
    }

    func testGenesisBootstrapRequiresUnsignedTransactions() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "unsigned-root",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        let header = try BlockHeader(node: genesis)
        let context = testChainContext(path: [DEFAULT_ROOT_DIRECTORY])

        let direct = try await genesis.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        XCTAssertTrue(direct.0)

        let result = try await ChainLevel.bootstrap(
            context: context,
            genesisHeader: header,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        let rootTip = await result.level.chain.canonicalTip
        XCTAssertEqual(rootTip, header.rawCID)
        XCTAssertEqual(
            result.commit,
            ChainCommit(
                tipHash: header.rawCID,
                canonicalBlocksAdded: [header.rawCID: 0]
            )
        )
    }

    func testGenesisBootstrapDoesNotRelaxLaterTransactions() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "unsigned-root",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        let genesisHeader = try BlockHeader(node: genesis)
        let bootstrap = try await ChainLevel.bootstrap(
            context: testChainContext(),
            genesisHeader: genesisHeader,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        let unsignedBody = TransactionBody(
            accountActions: [],
            actions: [Action(key: "unsigned-height-one", oldValue: nil, newValue: "value")],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let unsignedTransaction = Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: unsignedBody)
        )
        let candidate = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [unsignedTransaction],
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: fetcher
        )

        let result = try await bootstrap.level.admit(candidate, fetcher: fetcher)
        XCTAssertEqual(result.failure, .protocolInvalid)
    }

    func testGenesisBootstrapIgnoresSignatures() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [AdmissionFixture.signedStateChangingGenesisTransaction(
                key: "signed-root",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        let header = try BlockHeader(node: genesis)

        _ = try await ChainLevel.bootstrap(
            context: testChainContext(),
            genesisHeader: header,
            fetcher: fetcher,
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
    }

    func testGenesisBootstrapIgnoresEverySignatureShape() async throws {
        let keyPair = CryptoUtils.generateKeyPair()
        let signer = testAddress(publicKey: keyPair.publicKey)

        func body(signers: [String]) -> TransactionBody {
            TransactionBody(
                accountActions: [],
                actions: [Action(key: "malformed-pair", oldValue: nil, newValue: "value")],
                depositActions: [],
                genesisActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: signers,
                nonce: 0,
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )
        }

        let declaredButUnsigned = Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: body(signers: [signer]))
        )
        let signedButUndeclared = signedTestTransaction(body(signers: []), by: keyPair)
        let invalidSignature = Transaction(
            signatures: [keyPair.publicKey: "not-a-signature"],
            body: try HeaderImpl<TransactionBody>(node: body(signers: [signer]))
        )

        for transaction in [declaredButUnsigned, signedButUndeclared, invalidSignature] {
            let fetcher = StorableFetcher()
            let genesis = try await AdmissionFixture.makeGenesis(
                fetcher: fetcher,
                timestamp: 1_000,
                transactions: [transaction]
            )
            let header = try BlockHeader(node: genesis)
            _ = try await ChainLevel.bootstrap(
                context: testChainContext(),
                genesisHeader: header,
                fetcher: fetcher,
                validationContentStorer: fetcher,
                materializedVolumeStorer: fetcher,
                stage: testAdmissionStage
            )
        }
    }

    func testChildBootstrapAcceptsUnsignedGenesisTransactions() async throws {
        let fetcher = StorableFetcher()
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: chainLocalSpec(),
            parentState: LatticeState.emptyHeader,
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "unsigned-child",
                chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
            )],
            timestamp: 1_000,
            target: AdmissionFixture.easy,
            fetcher: fetcher
        )
        try await storeBuiltBlock(childGenesis, in: fetcher)
        let childHeader = try BlockHeader(node: childGenesis)

        let result = try await ChainLevel.bootstrap(
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Child"]
            ),
            genesisHeader: childHeader,
            fetcher: fetcher,
            parentGenesisLink: testParentGenesisLink(
                directory: "Child",
                childGenesisCID: childHeader.rawCID,
                parentStateCID: childGenesis.parentState.rawCID
            ),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        XCTAssertNil(result.failure)
    }

    func testGenesisDifficultySeedIsValidatedBeforeStorageOrStaging() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let forged = Block(
            version: genesis.version,
            parent: genesis.parent,
            transactions: genesis.transactions,
            target: genesis.target,
            nextTarget: genesis.target - UInt256(1),
            spec: genesis.spec,
            parentState: genesis.parentState,
            prevState: genesis.prevState,
            postState: genesis.postState,
            children: genesis.children,
            height: genesis.height,
            timestamp: genesis.timestamp,
            rewardRecipient: genesis.rewardRecipient,
            nonce: genesis.nonce
        )
        try await storeBuiltBlock(forged, in: fetcher)
        let direct = try await forged.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        XCTAssertFalse(direct.0)
        XCTAssertFalse(GenesisCeremony.verify(
            block: forged,
            config: GenesisConfig(
                spec: chainLocalSpec(),
                timestamp: forged.timestamp
            )
        ))

        let durable = RecordingAdmissionStorer()
        let recorder = AdmissionStageRecorder()
        do {
            _ = try await ChainLevel.bootstrap(
                context: testChainContext(),
                genesisHeader: try BlockHeader(node: forged),
                fetcher: fetcher,
                validationContentStorer: durable,
                materializedVolumeStorer: durable,
                stage: { batch in await recorder.stage(batch) }
            )
            XCTFail("genesis must seed its first successor with its own target")
        } catch let failure as BlockImportError {
            XCTAssertEqual(failure, .protocolInvalid)
        }
        let storeCalls = await durable.storeCallCount()
        let staged = await recorder.recordedBatches()
        XCTAssertEqual(storeCalls, 0)
        XCTAssertTrue(staged.isEmpty)
    }

    func testRootBootstrapRejectsTargetMissWithoutStoring() async throws {
        let fetcher = StorableFetcher()
        let durable = RecordingAdmissionStorer()
        let recorder = AdmissionStageRecorder()

        let hardGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 2_000,
            target: UInt256(1),
            nonce: 1,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(hardGenesis.proofOfWorkHash(), hardGenesis.target)
        do {
            _ = try await ChainLevel.bootstrap(
                context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY]),
                genesisHeader: try BlockHeader(node: hardGenesis),
                fetcher: fetcher,
                validationContentStorer: durable,
                materializedVolumeStorer: durable,
                stage: { batch in await recorder.stage(batch) }
            )
            XCTFail("a target miss cannot bootstrap the root")
        } catch let failure as BlockImportError {
            XCTAssertEqual(failure, .proofOfWorkInvalid)
        }
        let targetMissStoreCalls = await durable.storeCallCount()
        let targetMissBatches = await recorder.recordedBatches()
        XCTAssertEqual(targetMissStoreCalls, 0)
        XCTAssertTrue(targetMissBatches.isEmpty)
    }

    func testBootstrapDoesNotStageOnCurrentChainTargetMiss() async throws {
        let fetcher = StorableFetcher()
        let childGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 1_000,
            target: UInt256(1),
            nonce: 1,
            fetcher: fetcher
        )
        let header = try BlockHeader(node: childGenesis)
        let recorder = AdmissionStageRecorder()

        let result = try await ChainLevel.bootstrap(
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"]),
            genesisHeader: header,
            fetcher: fetcher,
            parentGenesisLink: testParentGenesisLink(
                directory: "Child",
                childGenesisCID: header.rawCID,
                parentStateCID: childGenesis.parentState.rawCID
            ),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: { record in await recorder.stage(record) }
        )
        XCTAssertEqual(result.failure, .proofOfWorkInvalid)
        let stageCount = await recorder.count(for: header.rawCID)
        XCTAssertEqual(stageCount, 0)
    }

    func testHeightOverflowFailsClosedInBuilder() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let overflowParent = Block(
            version: genesis.version,
            parent: genesis.parent,
            transactions: genesis.transactions,
            target: genesis.target,
            nextTarget: genesis.nextTarget,
            spec: genesis.spec,
            parentState: genesis.parentState,
            prevState: genesis.prevState,
            postState: genesis.postState,
            children: genesis.children,
            height: UInt64.max,
            timestamp: genesis.timestamp,
            rewardRecipient: genesis.rewardRecipient,
            nonce: genesis.nonce
        )

        do {
            _ = try await BlockBuilder.buildBlock(
                previous: overflowParent,
                timestamp: 2_000,
                fetcher: fetcher
            )
            XCTFail("height overflow must reject construction")
        } catch BlockBuilderError.heightOverflow {
            // Expected.
        }
    }
}
