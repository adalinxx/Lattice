import XCTest
@testable import Lattice
import Foundation

final class AddressValidationTests: XCTestCase {
    func test_createdAddress_isValidAndBindsToKey() {
        let (_, publicKey) = CryptoUtils.generateKeyPair()
        let address = CryptoUtils.createAddress(from: publicKey)

        XCTAssertTrue(CryptoUtils.isValidAddress(address), "a freshly created address must be structurally valid")
        XCTAssertTrue(CryptoUtils.isAddress(address, of: publicKey), "the address must bind to the public key it was derived from")
    }

    func test_isAddress_rejectsWrongKey() {
        let (_, keyA) = CryptoUtils.generateKeyPair()
        let (_, keyB) = CryptoUtils.generateKeyPair()
        let addressA = CryptoUtils.createAddress(from: keyA)

        XCTAssertFalse(CryptoUtils.isAddress(addressA, of: keyB), "an address must not bind to a different public key")
    }

    func test_isValidAddress_rejectsMalformed() {
        let (_, publicKey) = CryptoUtils.generateKeyPair()
        let address = CryptoUtils.createAddress(from: publicKey)

        XCTAssertFalse(CryptoUtils.isValidAddress(""), "empty string is not an address")
        XCTAssertFalse(CryptoUtils.isValidAddress("bafyrei"), "a bare valid-looking prefix is not a CID")
        XCTAssertFalse(CryptoUtils.isValidAddress("not-a-cid"), "garbage is not an address")
        XCTAssertFalse(CryptoUtils.isValidAddress(address + "x"), "a corrupted address must not round-trip")

        // A single-character tamper past the multibase prefix breaks the
        // canonical base32-lower encoding, so it must not round-trip.
        var chars = Array(address)
        let i = chars.indices.dropFirst("bafyrei".count).first { chars[$0].isLowercase }!
        chars[i] = Character(String(chars[i]).uppercased())
        let tampered = String(chars)
        XCTAssertNotEqual(tampered, address)
        XCTAssertFalse(CryptoUtils.isValidAddress(tampered), "a single-char non-canonical tamper must be rejected")
    }

    func test_isValidAddress_rejectsNonPublicKeyCID_isStructurallyValidButUnbound() {
        // A CID of arbitrary content can be structurally valid yet must not bind to a key.
        let (_, publicKey) = CryptoUtils.generateKeyPair()
        let address = CryptoUtils.createAddress(from: publicKey)
        XCTAssertTrue(CryptoUtils.isValidAddress(address))
        // No key derives a different-content CID, so isAddress is the value-disbursal gate.
        XCTAssertTrue(CryptoUtils.isAddress(address, of: publicKey))
    }
}
