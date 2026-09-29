import CID
import Crypto
import Foundation
import Multihash
import Multikey
import UInt256
import XCTest
import cashew
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticeProofs
@testable import LatticeValidation

/// Conformance vectors: the published files under `Vectors/` that let SDKs in
/// other languages check they encode, address, sign and verify exactly as
/// Lattice does (see `Vectors/README.md`).
///
/// Every file is generated here from the real Lattice code and checked on every
/// run two ways: the committed file must be byte-identical to a fresh
/// in-memory regeneration, AND every committed vector is run back through the
/// Lattice verifier (bytes decode and re-encode to the same CID, signatures and
/// proofs verify exactly when the file says they do). Regeneration follows the
/// golden convention: `LATTICE_REGENERATE_GOLDENS=1` rewrites the files and the
/// test then FAILS, so a changed vector always shows up as a reviewed diff.
///
/// Ed25519 signing is deterministic (RFC 8032) through swift-crypto's BoringSSL
/// backend on Linux, but CryptoKit on Apple platforms randomizes signatures. The
/// committed signatures are the RFC 8032 ones: a host that signs
/// deterministically must reproduce them byte for byte; a host that does not
/// keeps the committed signature as long as Lattice still verifies it.
final class ConformanceVectorTests: XCTestCase {
    static let vectorVersion = 1

    static let files = [
        "encoding.json", "addresses.json", "signing.json", "proofs.json",
    ]

    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Vectors", isDirectory: true)
    }

    // MARK: - Tests

    func testEncodingVectors() async throws {
        let committed: EncodingFile = try Self.load("encoding.json", orEmpty: EncodingFile.self)
        for vector in committed.vectors {
            try Self.verifyEncoding(vector)
        }
        try await Self.assertRegenerates(Self.generateEncoding(), "encoding.json")
    }

    func testAddressVectors() throws {
        let committed: AddressFile = try Self.load("addresses.json", orEmpty: AddressFile.self)
        for vector in committed.vectors {
            let multikey = Multikey(
                keyType: .ed25519,
                keyBytes: try XCTUnwrap(Data(hex: vector.publicKeyEd25519Hex))
            ).hexEncoded
            XCTAssertEqual(multikey, vector.publicKey, vector.name)
            let node = try XCTUnwrap(Data(hex: vector.publicKeyNodeDagCborHex))
            XCTAssertEqual(try DagCBOR.decode(PublicKey.self, from: node).key, vector.publicKey, vector.name)
            XCTAssertEqual(try Self.cid(of: node), vector.address, vector.name)
            XCTAssertEqual(CryptoUtils.createAddress(from: vector.publicKey), vector.address, vector.name)
            XCTAssertTrue(CryptoUtils.isAddress(vector.address, of: vector.publicKey), vector.name)
            if let privateKey = vector.privateKey {
                XCTAssertEqual(try Self.publicKey(privateKeyHex: privateKey), vector.publicKey, vector.name)
            }
        }
        try Self.assertRegenerates(Self.generateAddresses(), "addresses.json")
    }

    func testSigningVectors() async throws {
        let committed: SigningFile = try Self.load("signing.json", orEmpty: SigningFile.self)
        XCTAssertTrue(committed.vectors.contains { !$0.valid }, "signing.json must keep its negative cases")
        for vector in committed.vectors {
            XCTAssertEqual(
                try Self.signedBytes(vector.message).hexString, vector.signedBytesHex,
                "\(vector.name): signed bytes"
            )
            XCTAssertEqual(try Self.verifySignature(vector), vector.valid, "\(vector.name): verify result")
        }
        try await Self.assertRegenerates(Self.generateSigning(), "signing.json")
    }

    func testProofVectors() async throws {
        let committed: ProofFile = try Self.load("proofs.json", orEmpty: ProofFile.self)
        XCTAssertTrue(committed.vectors.contains { !$0.valid }, "proofs.json must keep its negative cases")
        for vector in committed.vectors {
            let verified = await Self.verifyProof(vector)
            XCTAssertEqual(verified, vector.valid, "\(vector.name): verify result")
        }
        try await Self.assertRegenerates(Self.generateProofs(), "proofs.json")
    }

    func testVectorsDirectoryHoldsOnlyPublishedFiles() throws {
        let present = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(Set(present), Set(Self.files + ["README.md"]))
    }

    // MARK: - File shapes

    struct EncodingFile: Codable {
        let version: Int
        let spec: String
        let description: String
        let vectors: [EncodingVector]
    }

    struct EncodingVector: Codable {
        let name: String
        let type: String
        /// The value's fields as Lattice's `Codable` sees them; informational,
        /// for building the value in an SDK. `dagCborHex` is normative.
        let value: JSONFragment
        let dagCborHex: String
        let cid: String
    }

    struct AddressFile: Codable {
        let version: Int
        let spec: String
        let description: String
        let vectors: [AddressVector]
    }

    struct AddressVector: Codable {
        let name: String
        let privateKey: String?
        let publicKeyEd25519Hex: String
        let publicKey: String
        let publicKeyNodeDagCborHex: String
        let address: String
    }

    struct SigningFile: Codable {
        let version: Int
        let spec: String
        let description: String
        let vectors: [SigningVector]
    }

    struct SigningVector: Codable {
        let name: String
        let scheme: String
        let publicKey: String
        let transactionBodyDagCborHex: String?
        let transactionBodyCid: String?
        let message: String
        let signedBytesHex: String
        let signature: String
        let valid: Bool
    }

    struct ProofFile: Codable {
        let version: Int
        let spec: String
        let description: String
        let vectors: [ProofVector]
    }

    struct ProofVector: Codable {
        struct Entry: Codable {
            let cid: String
            let dagCborHex: String
        }

        let name: String
        let root: String
        let key: String
        /// The value the proof claims for `key`; `nil` claims absence.
        let value: String?
        let entries: [Entry]
        let valid: Bool
    }

    /// Raw JSON text embedded verbatim, so a value keeps Lattice's own
    /// `Codable` shape without a parallel hand-written schema.
    struct JSONFragment: Codable {
        let object: [String: JSONValue]

        init<T: Encodable>(_ value: T) throws {
            let data = try JSONEncoder().encode(value)
            object = try JSONDecoder().decode([String: JSONValue].self, from: data)
        }

        init(from decoder: Decoder) throws {
            object = try decoder.singleValueContainer().decode([String: JSONValue].self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(object)
        }
    }

    indirect enum JSONValue: Codable {
        case null
        case bool(Bool)
        case int(Int64)
        case uint(UInt64)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Int64.self) { self = .int(value) }
            else if let value = try? container.decode(UInt64.self) { self = .uint(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
            else { self = .object(try container.decode([String: JSONValue].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .uint(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }

    // MARK: - Fixed inputs

    /// Fixed Ed25519 seeds drawn from the golden generator's conventional seed,
    /// so every key (and everything derived from it) is reproducible anywhere.
    static let privateKeys: [String] = {
        var random = GoldenRandom(seed: 0x5EED_5EED)
        return (0..<3).map { _ in
            var bytes = Data()
            for _ in 0..<4 {
                withUnsafeBytes(of: random.next().littleEndian) { bytes.append(contentsOf: $0) }
            }
            return bytes.hexString
        }
    }()

    static func publicKey(privateKeyHex: String) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: try XCTUnwrap(Data(hex: privateKeyHex))
        )
        return Multikey(keyType: .ed25519, keyBytes: key.publicKey.rawRepresentation).hexEncoded
    }

    struct Party {
        let privateKey: String
        let publicKey: String
        let address: String
    }

    static func parties() throws -> (alice: Party, bob: Party, carol: Party) {
        let all = try privateKeys.map { privateKey in
            let publicKey = try publicKey(privateKeyHex: privateKey)
            return Party(
                privateKey: privateKey,
                publicKey: publicKey,
                address: CryptoUtils.createAddress(from: publicKey)
            )
        }
        return (all[0], all[1], all[2])
    }

    static func nexusSpec() -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 1_000_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 210_000,
            halfLife: 120
        )
    }

    static func childSpec() -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 50,
            maxStateGrowth: 50_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 512,
            halvingInterval: 100_000,
            halfLife: 10,
            wasmPolicies: [WasmPolicyRef(moduleCID: "tre127-policy-module", scope: .action)]
        )
    }

    static func genesis(_ spec: ChainSpec, target: UInt256 = .max) async throws -> Block {
        try await BlockBuilder.buildGenesis(
            spec: spec,
            timestamp: 1_000_000_000_000,
            target: target,
            fetcher: InMemoryContentSource([:])
        )
    }

    static func body(
        signers: [Party],
        chainPath: [String] = ["Nexus"],
        nonce: UInt64 = 0,
        accountActions: [AccountAction] = [],
        actions: [Action] = [],
        depositActions: [DepositAction] = [],
        genesisActions: [GenesisAction] = [],
        receiptActions: [ReceiptAction] = [],
        withdrawalActions: [WithdrawalAction] = []
    ) -> TransactionBody {
        TransactionBody(
            accountActions: accountActions,
            actions: actions,
            depositActions: depositActions,
            genesisActions: genesisActions,
            receiptActions: receiptActions,
            withdrawalActions: withdrawalActions,
            signers: signers.map(\.address),
            nonce: nonce,
            chainPath: chainPath
        )
    }

    static func transactionBodies() async throws -> [(name: String, body: TransactionBody)] {
        let (alice, bob, _) = try parties()
        let childGenesisCID = try VolumeImpl<Block>(node: try await genesis(childSpec())).rawCID
        return [
            ("transaction-body/account-action", body(
                signers: [alice],
                accountActions: [
                    AccountAction(owner: alice.address, delta: -101),
                    AccountAction(owner: bob.address, delta: 100),
                ]
            )),
            ("transaction-body/action", body(
                signers: [alice],
                nonce: 1,
                actions: [Action(key: "greeting", oldValue: nil, newValue: "hello")]
            )),
            ("transaction-body/deposit-action", body(
                signers: [alice],
                chainPath: ["Nexus", "Child"],
                depositActions: [DepositAction(
                    nonce: 7, demander: alice.address, amountDemanded: 500, amountDeposited: 500
                )]
            )),
            ("transaction-body/genesis-action", body(
                signers: [alice],
                nonce: 2,
                genesisActions: [GenesisAction(directory: "Child", blockCID: childGenesisCID)]
            )),
            ("transaction-body/receipt-action", body(
                signers: [bob],
                receiptActions: [ReceiptAction(
                    withdrawer: bob.address, nonce: 7, demander: alice.address,
                    amountDemanded: 500, directory: "Child"
                )]
            )),
            ("transaction-body/withdrawal-action", body(
                signers: [bob],
                chainPath: ["Nexus", "Child"],
                withdrawalActions: [WithdrawalAction(
                    withdrawer: bob.address, nonce: 7, demander: alice.address,
                    amountDemanded: 500, amountWithdrawn: 500
                )]
            )),
        ]
    }

    /// A body signed by two parties, listed alice-then-carol in `signers`.
    static func twoSignerBody() throws -> TransactionBody {
        let (alice, bob, carol) = try parties()
        return body(
            signers: [alice, carol],
            nonce: 3,
            accountActions: [
                AccountAction(owner: alice.address, delta: -11),
                AccountAction(owner: carol.address, delta: -11),
                AccountAction(owner: bob.address, delta: 20),
            ]
        )
    }

    /// The Ed25519 group order L = 2^252 + 27742317777372353535851937790883648493,
    /// little-endian (RFC 8032 section 5.1).
    static let ed25519GroupOrder: [UInt8] = [
        0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
    ]

    // MARK: - Generation

    static func generateEncoding() async throws -> EncodingFile {
        var vectors: [EncodingVector] = []
        func add<T: Node & Encodable>(_ name: String, _ type: String, _ value: T) throws {
            let bytes = try DagCBOR.encode(value)
            vectors.append(EncodingVector(
                name: name,
                type: type,
                value: try JSONFragment(value),
                dagCborHex: bytes.hexString,
                cid: try HeaderImpl<T>(node: value).rawCID
            ))
        }
        for (name, body) in try await transactionBodies() {
            try add(name, "TransactionBody", body)
        }
        let (alice, _, carol) = try parties()
        let signing = try await generateSigning().vectors
        func signature(_ name: String) throws -> String {
            try XCTUnwrap(signing.first { $0.name == name }?.signature, name)
        }
        let accountBody = try await transactionBodies()[0].body
        try add("transaction/signed", "Transaction", Transaction(
            signatures: [alice.publicKey: try signature("transaction/envelope")],
            body: try HeaderImpl(node: accountBody)
        ))
        // Two signers: the signatures array is sorted by public-key hex, so
        // carol's entry precedes alice's although `signers` lists alice first.
        try add("transaction/signed-two-signers", "Transaction", Transaction(
            signatures: [
                alice.publicKey: try signature("transaction/two-signers/alice"),
                carol.publicKey: try signature("transaction/two-signers/carol"),
            ],
            body: try HeaderImpl(node: try twoSignerBody())
        ))
        try add("block/genesis", "Block", try await genesis(nexusSpec()))
        // A U256 is minimal-length hex: a non-max target shows the encoding
        // drops leading zero digits (no fixed 64-digit width).
        try add("block/genesis-non-max-target", "Block", try await genesis(
            nexusSpec(), target: UInt256.max >> 20
        ))
        try add("chain-spec/nexus", "ChainSpec", nexusSpec())
        try add("chain-spec/with-wasm-policy", "ChainSpec", childSpec())
        return EncodingFile(
            version: vectorVersion,
            spec: "docs/spec.md#3-data-structures",
            description: "DAG-CBOR bytes and CIDv1 (dag-cbor, sha2-256, base32) of representative Lattice values.",
            vectors: vectors
        )
    }

    static func generateAddresses() throws -> AddressFile {
        var vectors = try privateKeys.enumerated().map { index, privateKey in
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: try XCTUnwrap(Data(hex: privateKey)))
            return try addressVector(
                name: "ed25519/key-\(index)",
                privateKey: privateKey,
                ed25519: key.publicKey.rawRepresentation
            )
        }
        // The Ed25519 base point (RFC 8032 section 5.1): a public key with no
        // known private key, so the derivation is checked without signing.
        vectors.append(try addressVector(
            name: "ed25519/base-point",
            privateKey: nil,
            ed25519: try XCTUnwrap(Data(hex: "5866666666666666666666666666666666666666666666666666666666666666"))
        ))
        return AddressFile(
            version: vectorVersion,
            spec: "docs/spec.md#111-address-derivation",
            description: "address = CID(PublicKey(key: multikeyHex)); multikeyHex = hex(varint(0xed) || 32-byte Ed25519 key).",
            vectors: vectors
        )
    }

    static func addressVector(name: String, privateKey: String?, ed25519: Data) throws -> AddressVector {
        let publicKey = Multikey(keyType: .ed25519, keyBytes: ed25519).hexEncoded
        return AddressVector(
            name: name,
            privateKey: privateKey,
            publicKeyEd25519Hex: ed25519.hexString,
            publicKey: publicKey,
            publicKeyNodeDagCborHex: try DagCBOR.encode(PublicKey(key: publicKey)).hexString,
            address: CryptoUtils.createAddress(from: publicKey)
        )
    }

    static func generateSigning() async throws -> SigningFile {
        let (alice, bob, carol) = try parties()
        let committedFile = FileManager.default
            .contents(atPath: directory.appendingPathComponent("signing.json").path)
            .flatMap { try? JSONDecoder().decode(SigningFile.self, from: $0) }
        let committed = Dictionary(
            (committedFile?.vectors ?? []).map { ($0.name, $0.signature) },
            uniquingKeysWith: { first, _ in first }
        )
        func vector(
            _ name: String, scheme: String, signer: Party, body: TransactionBody? = nil,
            message: String, signature: String, valid: Bool
        ) throws -> SigningVector {
            SigningVector(
                name: name,
                scheme: scheme,
                publicKey: signer.publicKey,
                transactionBodyDagCborHex: try body.map { try DagCBOR.encode($0).hexString },
                transactionBodyCid: try body.map { try HeaderImpl(node: $0).rawCID },
                message: message,
                signedBytesHex: try signedBytes(message).hexString,
                signature: signature,
                valid: valid
            )
        }

        let message = "hello lattice"
        let messageSignature = try canonicalSignature(
            message: message, signer: alice, committed: committed["message/valid"]
        )
        let body = try await transactionBodies()[0].body
        let bodyCID = try HeaderImpl(node: body).rawCID
        let envelope = TransactionSigning.preimage(body: body)
        let envelopeSignature = try canonicalSignature(
            message: envelope, signer: alice, committed: committed["transaction/envelope"]
        )
        let legacySignature = try canonicalSignature(
            message: bodyCID, signer: alice, committed: committed["transaction/legacy-body-cid"]
        )
        let tamperedBody = Self.body(
            signers: [alice],
            nonce: body.nonce + 1,
            accountActions: body.accountActions
        )

        var flipped = try XCTUnwrap(Data(hex: messageSignature))
        flipped[0] ^= 0x01
        let twoSigners = try twoSignerBody()
        let twoSignerEnvelope = TransactionSigning.preimage(body: twoSigners)
        let twoSignerAlice = try canonicalSignature(
            message: twoSignerEnvelope, signer: alice, committed: committed["transaction/two-signers/alice"]
        )
        let twoSignerCarol = try canonicalSignature(
            message: twoSignerEnvelope, signer: carol, committed: committed["transaction/two-signers/carol"]
        )
        // The same key as a bare 32-byte Ed25519 hex (no Multikey prefix):
        // Lattice accepts exactly one key encoding, so this must not verify.
        let bareKey = Party(
            privateKey: alice.privateKey,
            publicKey: String(alice.publicKey.dropFirst(4)),
            address: alice.address
        )
        // S + L: the same point equation holds, but a non-canonical scalar
        // (S >= L) must be rejected, or every signature has a malleable twin.
        var malleated = try XCTUnwrap(Data(hex: messageSignature))
        var carry: UInt16 = 0
        for index in 0..<32 {
            let sum = UInt16(malleated[32 + index]) + UInt16(Self.ed25519GroupOrder[index]) + carry
            malleated[32 + index] = UInt8(sum & 0xff)
            carry = sum >> 8
        }
        XCTAssertEqual(carry, 0)

        return SigningFile(
            version: vectorVersion,
            spec: "docs/spec.md#71-signature-verification",
            description: "Ed25519 over signedBytes = UTF8(\"lattice-tx-v1:\" || message). For scheme \"transaction\" the message is the lattice-tx-v1 envelope of the body (or, legacy, the body CID) and verification is TransactionSigning.verify.",
            vectors: [
                try vector("message/valid", scheme: "message", signer: alice,
                           message: message, signature: messageSignature, valid: true),
                try vector("message/tampered-message", scheme: "message", signer: alice,
                           message: message + "!", signature: messageSignature, valid: false),
                try vector("message/wrong-public-key", scheme: "message", signer: bob,
                           message: message, signature: messageSignature, valid: false),
                try vector("message/tampered-signature", scheme: "message", signer: alice,
                           message: message, signature: flipped.hexString, valid: false),
                try vector("message/uppercase-signature-hex", scheme: "message", signer: alice,
                           message: message, signature: messageSignature.uppercased(), valid: false),
                try vector("message/bare-ed25519-public-key", scheme: "message", signer: bareKey,
                           message: message, signature: messageSignature, valid: false),
                try vector("message/malleated-signature-s-plus-l", scheme: "message", signer: alice,
                           message: message, signature: malleated.hexString, valid: false),
                try vector("transaction/envelope", scheme: "transaction", signer: alice, body: body,
                           message: envelope, signature: envelopeSignature, valid: true),
                try vector("transaction/legacy-body-cid", scheme: "transaction", signer: alice, body: body,
                           message: bodyCID, signature: legacySignature, valid: true),
                try vector("transaction/tampered-nonce", scheme: "transaction", signer: alice, body: tamperedBody,
                           message: TransactionSigning.preimage(body: tamperedBody),
                           signature: envelopeSignature, valid: false),
                try vector("transaction/two-signers/alice", scheme: "transaction", signer: alice, body: twoSigners,
                           message: twoSignerEnvelope, signature: twoSignerAlice, valid: true),
                try vector("transaction/two-signers/carol", scheme: "transaction", signer: carol, body: twoSigners,
                           message: twoSignerEnvelope, signature: twoSignerCarol, valid: true),
            ]
        )
    }

    /// The RFC 8032 signature where this host signs deterministically; on a
    /// host that randomizes Ed25519 (CryptoKit), the committed signature while
    /// Lattice still verifies it.
    static func canonicalSignature(message: String, signer: Party, committed: String?) throws -> String {
        let first = try XCTUnwrap(CryptoUtils.sign(message: message, privateKeyHex: signer.privateKey))
        let second = try XCTUnwrap(CryptoUtils.sign(message: message, privateKeyHex: signer.privateKey))
        #if !canImport(CryptoKit)
        // Only CryptoKit randomizes Ed25519. Everywhere else (BoringSSL on
        // Linux) the signer must be RFC 8032 deterministic, so this host can
        // never fall through to the lenient branch below.
        XCTAssertEqual(first, second, "this host's Ed25519 signer must be RFC 8032 deterministic")
        #endif
        if first == second { return first }
        if let committed, CryptoUtils.verify(message: message, signature: committed, publicKeyHex: signer.publicKey) {
            return committed
        }
        return first
    }

    static func generateProofs() async throws -> ProofFile {
        let (alice, bob, carol) = try parties()
        let state = try await accountState([alice.address: 1000, bob.address: 250, "_nonce_" + alice.address: 3])
        let otherState = try await accountState([alice.address: 999, bob.address: 250, "_nonce_" + alice.address: 3])

        let aliceProof = try await proof(state, key: alice.address, .existence)
        let bobProof = try await proof(state, key: bob.address, .existence)
        let carolProof = try await proof(state, key: carol.address, .insertion)
        // Alice's leaf with its value rewritten 1000 -> 999 under the ORIGINAL
        // CID. The claim (999) matches the tampered bytes, so only the
        // entry-CID integrity check can reject it.
        let leafValue1000 = "6576616c75651903e8"  // text "value", uint 1000
        let tamperedAliceProof = aliceProof.map { entry in
            ProofVector.Entry(
                cid: entry.cid,
                dagCborHex: entry.dagCborHex.replacingOccurrences(
                    of: leafValue1000, with: "6576616c75651903e7"  // uint 999
                )
            )
        }
        XCTAssertEqual(
            zip(aliceProof, tamperedAliceProof).filter { $0.dagCborHex != $1.dagCborHex }.count, 1,
            "exactly one proof entry (alice's leaf) must be tampered"
        )

        func vector(_ name: String, root: String, key: String, value: String?, entries: [ProofVector.Entry], valid: Bool) -> ProofVector {
            ProofVector(name: name, root: root, key: key, value: value, entries: entries, valid: valid)
        }
        return ProofFile(
            version: vectorVersion,
            spec: "docs/spec.md#34-latticestate",
            description: "Sparse Merkle proofs over an AccountState (address -> uint64 balance) trie. entries are the content-addressed DAG-CBOR nodes along the key's path; a proof is valid when the key resolves from root using ONLY those entries (each checked against its CID) to exactly value, or to absence when value is null.",
            vectors: [
                vector("existence/alice-balance", root: state.root, key: alice.address, value: "1000", entries: aliceProof, valid: true),
                vector("existence/bob-balance", root: state.root, key: bob.address, value: "250", entries: bobProof, valid: true),
                vector("non-existence/carol", root: state.root, key: carol.address, value: nil, entries: carolProof, valid: true),
                vector("negative/wrong-root", root: otherState.root, key: bob.address, value: "250", entries: bobProof, valid: false),
                vector("negative/wrong-value", root: state.root, key: alice.address, value: "999", entries: aliceProof, valid: false),
                vector("negative/absence-of-present-key", root: state.root, key: bob.address, value: nil, entries: bobProof, valid: false),
                vector("negative/tampered-entry", root: state.root, key: alice.address, value: "999", entries: tamperedAliceProof, valid: false),
            ]
        )
    }

    /// A fully stored AccountState: its root CID and every node by CID.
    static func accountState(_ balances: [String: UInt64]) async throws -> (root: String, store: [String: Data]) {
        var transforms: [[String]: Transform] = [:]
        for (key, value) in balances { transforms[[key]] = .insert(String(value)) }
        let header = try XCTUnwrap(
            try AccountStateHeader(node: AccountState()).transform(transforms: transforms)
        )
        let storer = _CollectingStorer()
        try await header.storeRecursively(storer: storer)
        return (header.rawCID, Dictionary(uniqueKeysWithValues: storer.entries.map { ($0.cid, $0.data) }))
    }

    /// cashew's sparse proof for `key`, generated from the stored state by CID
    /// alone, collected as the CID → bytes entries a verifier needs.
    static func proof(
        _ state: (root: String, store: [String: Data]),
        key: String,
        _ kind: SparseMerkleProof
    ) async throws -> [ProofVector.Entry] {
        let proven = try await AccountStateHeader(rawCID: state.root)
            .proof(paths: [[key]: kind], fetcher: InMemoryContentSource(state.store))
        // Exactly the nodes a targeted resolve of `key` reads — what the
        // verifier walks.
        let storer = _CollectingStorer()
        try await proven.store(paths: [[key]: .targeted], storer: storer)
        return storer.entries.map { ProofVector.Entry(cid: $0.cid, dagCborHex: $0.data.hexString) }
    }

    // MARK: - Verification (what an SDK re-implements)

    static func verifyEncoding(_ vector: EncodingVector) throws {
        let bytes = try XCTUnwrap(Data(hex: vector.dagCborHex), vector.name)
        XCTAssertEqual(try cid(of: bytes), vector.cid, "\(vector.name): CID of the bytes")
        func check<T: Node>(_ type: T.Type) throws {
            let value = try DagCBOR.decode(T.self, from: bytes)
            XCTAssertEqual(try DagCBOR.encode(value), bytes, "\(vector.name): re-encoding differs")
            XCTAssertEqual(try HeaderImpl<T>(node: value).rawCID, vector.cid, "\(vector.name): Lattice CID")
        }
        switch vector.type {
        case "TransactionBody": try check(TransactionBody.self)
        case "Transaction": try check(Transaction.self)
        case "Block": try check(Block.self)
        case "ChainSpec": try check(ChainSpec.self)
        default: XCTFail("\(vector.name): unknown type \(vector.type)")
        }
    }

    /// CIDv1, dag-cbor codec, sha2-256 multihash, base32 — computed from the
    /// bytes alone, as an SDK would.
    static func cid(of bytes: Data) throws -> String {
        try CID(
            version: .v1,
            codec: .dag_cbor,
            multihash: try Multihash(raw: bytes, hashedWith: .sha2_256)
        ).toBaseEncodedString
    }

    static func signedBytes(_ message: String) throws -> Data {
        CryptoUtils.signaturePayload(message)
    }

    static func verifySignature(_ vector: SigningVector) throws -> Bool {
        switch vector.scheme {
        case "message":
            return CryptoUtils.verify(message: vector.message, signature: vector.signature, publicKeyHex: vector.publicKey)
        case "transaction":
            let bodyBytes = try XCTUnwrap(vector.transactionBodyDagCborHex.flatMap { Data(hex: $0) }, vector.name)
            let body = try DagCBOR.decode(TransactionBody.self, from: bodyBytes)
            let bodyCID = try HeaderImpl(node: body).rawCID
            XCTAssertEqual(bodyCID, vector.transactionBodyCid, "\(vector.name): body CID")
            return TransactionSigning.verify(
                body: body, bodyCID: bodyCID, signature: vector.signature, publicKeyHex: vector.publicKey
            )
        default:
            XCTFail("\(vector.name): unknown scheme \(vector.scheme)")
            return false
        }
    }

    static func verifyProof(_ vector: ProofVector) async -> Bool {
        var entries: [String: Data] = [:]
        for entry in vector.entries {
            guard let data = Data(hex: entry.dagCborHex) else { return false }
            entries[entry.cid] = data
        }
        guard let node = try? await AccountStateHeader(rawCID: vector.root)
            .resolve(paths: [[vector.key]: .targeted], fetcher: InMemoryContentSource(entries))
            .node else { return false }
        do {
            let stored: UInt64? = try node.get(key: vector.key)
            return stored.map(String.init) == vector.value
        } catch {
            return false
        }
    }

    // MARK: - File plumbing (golden conventions)

    /// The committed file; while regenerating (the file may not exist yet)
    /// an empty one, so only the regeneration step runs.
    static func load<T: Decodable>(_ name: String, orEmpty type: T.Type) throws -> T {
        if GoldenFile.isRegenerating {
            return try JSONDecoder().decode(
                T.self,
                from: Data(#"{"version":0,"spec":"","description":"","vectors":[]}"#.utf8)
            )
        }
        return try load(name)
    }

    static func load<T: Decodable>(_ name: String) throws -> T {
        let url = directory.appendingPathComponent(name)
        let data = try XCTUnwrap(
            FileManager.default.contents(atPath: url.path),
            "missing vector file \(url.path); run once with \(GoldenFile.regenerateEnvironmentKey)=1"
        )
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func assertRegenerates<T: Encodable>(
        _ regenerated: T, _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let url = directory.appendingPathComponent(name)
        let encoded = try GoldenFile.encoder().encode(regenerated)
        if GoldenFile.isRegenerating {
            try encoded.write(to: url)
            XCTFail(
                "\(name) regenerated at \(url.path); review the diff, unset "
                    + "\(GoldenFile.regenerateEnvironmentKey) and rerun",
                file: file, line: line
            )
            return
        }
        let committed = try XCTUnwrap(FileManager.default.contents(atPath: url.path), name)
        guard committed != encoded else { return }
        let expectedLines = String(decoding: committed, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let actualLines = String(decoding: encoded, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let index = Array(zip(expectedLines, actualLines)).firstIndex { $0 != $1 } ?? min(expectedLines.count, actualLines.count)
        XCTFail(
            "\(name) is not what Lattice generates (first difference at line \(index + 1)):\n"
                + "  committed:   \(index < expectedLines.count ? String(expectedLines[index]) : "<end of file>")\n"
                + "  regenerated: \(index < actualLines.count ? String(actualLines[index]) : "<end of file>")",
            file: file, line: line
        )
    }
}
