import XCTest
@testable import Lattice
import cashew

final class TransactionSigningEnvelopeTests: XCTestCase {
    private struct TransactionWire: Encodable {
        let signatures: [SignatureEntry]
        let body: HeaderImpl<TransactionBody>
    }

    func testTransactionSignatureBindsDomainChainPathNonceAndBodyCID() throws {
        let key = CryptoUtils.generateKeyPair()
        let signer = CryptoUtils.createAddress(from: key.publicKey)
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: signer, delta: -11),
                AccountAction(owner: recipient, delta: 10)
            ],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [signer],
            fee: 1,
            nonce: 4,
            chainPath: ["Nexus"]
        )
        let header = try! HeaderImpl<TransactionBody>(node: body)
        let signature = try XCTUnwrap(TransactionSigning.sign(bodyHeader: header, privateKeyHex: key.privateKey))

        XCTAssertTrue(TransactionSigning.verify(bodyHeader: header, signature: signature, publicKeyHex: key.publicKey))
        XCTAssertFalse(CryptoUtils.verify(message: header.rawCID, signature: signature, publicKeyHex: key.publicKey))

        let wrongChainBody = TransactionBody(
            accountActions: body.accountActions,
            actions: body.actions,
            depositActions: body.depositActions,
            genesisActions: body.genesisActions,
            receiptActions: body.receiptActions,
            withdrawalActions: body.withdrawalActions,
            signers: body.signers,
            fee: body.fee,
            nonce: body.nonce,
            chainPath: ["Nexus", "Child"]
        )
        let wrongNonceBody = TransactionBody(
            accountActions: body.accountActions,
            actions: body.actions,
            depositActions: body.depositActions,
            genesisActions: body.genesisActions,
            receiptActions: body.receiptActions,
            withdrawalActions: body.withdrawalActions,
            signers: body.signers,
            fee: body.fee,
            nonce: 5,
            chainPath: body.chainPath
        )
        XCTAssertFalse(TransactionSigning.verify(bodyHeader: try! HeaderImpl<TransactionBody>(node: wrongChainBody), signature: signature, publicKeyHex: key.publicKey))
        XCTAssertFalse(TransactionSigning.verify(bodyHeader: try! HeaderImpl<TransactionBody>(node: wrongNonceBody), signature: signature, publicKeyHex: key.publicKey))
    }

    func testTransactionSignaturesAreValidUsesEnvelope() throws {
        let key = CryptoUtils.generateKeyPair()
        let signer = CryptoUtils.createAddress(from: key.publicKey)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: signer, delta: -1)],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [signer],
            fee: 1,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let header = try! HeaderImpl<TransactionBody>(node: body)
        let envelopeSignature = try XCTUnwrap(TransactionSigning.sign(bodyHeader: header, privateKeyHex: key.privateKey))
        let legacySignature = try XCTUnwrap(CryptoUtils.sign(message: header.rawCID, privateKeyHex: key.privateKey))

        XCTAssertTrue(Transaction(signatures: [key.publicKey: envelopeSignature], body: header).signaturesAreValid())
        XCTAssertFalse(Transaction(signatures: [key.publicKey: legacySignature], body: header).signaturesAreValid())
    }

    func testDuplicateSignatureKeysAreRejectedNotCrashed() throws {
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
        let wire = TransactionWire(
            signatures: [
                SignatureEntry(key: "duplicate", value: "sig-a"),
                SignatureEntry(key: "duplicate", value: "sig-b"),
            ],
            body: bodyHeader
        )
        let data = try JSONEncoder().encode(wire)

        XCTAssertThrowsError(try JSONDecoder().decode(Transaction.self, from: data)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertEqual(context.debugDescription, "duplicate signature key")
        }
    }

    func testProductionTransactionSigningIsCentralizedInEnvelopeHelper() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sources = root.appendingPathComponent("Sources/Lattice")
        let allowed = "Sources/Lattice/Transaction/TransactionSigning.swift"
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) ?? FileManager.default.enumerator(atPath: sources.path)!
        var findings: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let text = try String(contentsOf: url, encoding: .utf8)
            if relative != allowed && text.contains("CryptoUtils.sign(") {
                findings.append(relative)
            }
        }

        XCTAssertEqual(findings, [], "Production transaction signing must go through TransactionSigning so the lattice-tx-v1 envelope is applied.")
    }
}
