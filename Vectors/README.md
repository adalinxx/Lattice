# Lattice conformance vectors

Published test vectors for SDKs in other languages. An SDK that reproduces
every vector here encodes, addresses, signs and verifies exactly as Lattice
does.

Every file is generated from the real Lattice code by
`Tests/LatticeTests/ConformanceVectorTests.swift`, and CI checks it on macOS
and Linux on every run in two ways. First, the committed file must be
byte-identical to a fresh in-memory regeneration. Second, every vector is run
back through the Lattice verifier: the bytes decode and re-encode to the same
CID, and each signature and proof verifies exactly when its `valid` field says
it does.

## Files

Each file is JSON with a top-level `version`, a `spec` reference into
[`docs/spec.md`](../docs/spec.md), a `description`, and a `vectors` array.
Every vector has a stable `name`. Hex is lowercase and has no `0x` prefix,
except the negative vector `message/uppercase-signature-hex`, whose
signature is uppercase on purpose and must be rejected.

| File | Contents | Spec |
|---|---|---|
| `encoding.json` | DAG-CBOR bytes (`dagCborHex`) and CID (`cid`) for a `TransactionBody` with each action kind, a `Transaction` with one signer and one with two, a genesis `Block` at the maximum target and one at a lower target, and two `ChainSpec`s. `value` shows the same fields as readable JSON, for building the value in an SDK. `dagCborHex` is normative. | §3 |
| `addresses.json` | Ed25519 key (`privateKey` when one is known, then `publicKeyEd25519Hex`), its Multikey hex (`publicKey`), the DAG-CBOR `PublicKey` node, and the `address`. | §11.1 |
| `signing.json` | Ed25519 signatures over `signedBytesHex = UTF8("lattice-tx-v1:" + message)`. Scheme `message` verifies with `CryptoUtils.verify`. Scheme `transaction` carries the body (`transactionBodyDagCborHex`, `transactionBodyCid`) and verifies with `TransactionSigning.verify`: its `message` is the `lattice-tx-v1` envelope, or the body CID for the legacy form. Includes negative cases: a tampered message, the wrong public key, a tampered signature, uppercase signature hex, a bare 32-byte Ed25519 key instead of Multikey, a malleated signature (S + L), and a tampered nonce. | §7.1 |
| `proofs.json` | Sparse Merkle proofs over an `AccountState` trie (address to uint64 balance). `entries` are the content-addressed DAG-CBOR nodes along the key's path. A proof is valid when `key` resolves from `root`, using only those entries (each checked against its CID), to exactly `value`, or to absence when `value` is `null`. Includes negative cases: a wrong root, a wrong value, a claimed absence of a present key, and a tampered entry (the leaf's bytes altered under its original CID, claiming the altered value), which only the entry-CID check rejects. | §3.4 |

Encoding details an SDK must match, all visible in `encoding.json`:

- DAG-CBOR map keys are sorted by length first, then bytewise.
- A field that is a Header (a content-addressed child object, such as a
  block's `spec`, `transactions` or states, or a transaction's `body`) is the
  map `{"rawCID": "<cid>"}`, not a tag-42 link. Other CID-valued fields are
  plain text strings: addresses (`signers`, `owner`, `demander`,
  `withdrawer`). `PublicKey.key` is the Multikey
  hex as a text string.
- A `U256` is a `"0x"`-prefixed, lowercase hex string of minimal length: no
  leading zero digits, so zero is `"0x0"` (see
  `block/genesis-non-max-target`).
- An absent optional field is omitted, not encoded as null.
- A transaction's `signatures` is an array of `{"key", "value"}` maps
  (public-key hex, signature hex), sorted ascending by `key`, independent of
  the order of `signers` (see `transaction/signed-two-signers`).
- A CID string is multibase prefix `b` followed by lowercase RFC 4648 base32
  without padding of the binary CID: version `0x01` (CIDv1), codec `0x71`
  (dag-cbor), then the multihash `0x12 0x20` (sha2-256, 32 bytes) and the
  SHA-256 digest of the DAG-CBOR bytes.
- `WasmPolicyRef.moduleCID` in `chain-spec/with-wasm-policy` is an opaque
  string here; the encoding does not validate it as a CID.

The keys come from the golden generator's fixed seed (`GoldenRandom(seed:
0x5EED_5EED)`). Generation uses no clock and no system randomness.

## Signatures and hosts

The committed signatures are the deterministic RFC 8032 Ed25519 signatures,
which any RFC 8032 signer reproduces from `privateKey` and `signedBytesHex`.
swift-crypto signs this way on Linux (BoringSSL). CryptoKit on Apple platforms
randomizes Ed25519 signatures instead. Both are valid, and verification is the
consensus rule. So:

- a host that signs deterministically must reproduce each signature byte for
  byte;
- a host that does not (macOS) keeps the committed signature, as long as
  Lattice still verifies it.

Regenerate any vector that adds or changes a signature on Linux. A signature
regenerated on macOS is random, and the Linux CI job rejects it.

## Regenerating

```sh
LATTICE_REGENERATE_GOLDENS=1 swift test --filter ConformanceVectorTests
```

This rewrites the files, and then the tests FAIL on purpose, so that a
changed vector always shows up as a reviewed diff. Unset the variable and
rerun, and the tests pass. For signatures, run it on Linux, for example in
`swift:6.1-jammy`.

## Versioning

This rule is a review convention; no check enforces it.

- Adding a vector or a file is additive. It keeps `version`.
- Changing or removing an existing vector changes what "conforming" means.
  That is a consensus-level change, so it must bump `version`, and the PR
  must call it out. All files share one version,
  `ConformanceVectorTests.vectorVersion`.

SDKs should pin the `version` they were checked against.
