import Foundation
import UInt256

// MARK: - State-trie key grammar (consensus)
//
// The grammar for every semantic atom used as a state-trie key, enforced on the
// block-validation path (`TransactionBody.stateAtomsAreValid` /
// `genesisActionsAreValid`, chain-path construction, account-state reads).
//
// There is intentionally NO length/count limit here — key size is a node
// storage concern, not a protocol rule. Two structural constraints remain, and
// neither is a "limit":
//   * Visible ASCII (0x21…0x7e): the state trie keys by Swift `String`, whose
//     Unicode canonical equivalence would otherwise let byte-distinct keys
//     collide and serialize nondeterministically across nodes. This dissolves
//     once cashew keys tries by raw bytes.
//   * No `DIRECTORY_KEY_SEPARATOR` ("/") in account/directory atoms: preserves
//     receipt-key injectivity across chains (a `/` would let a withdrawal settle
//     against the wrong chain's receipt).

func isDeterministicKeyAtom(_ value: String) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.allSatisfy { (0x21...0x7e).contains($0) }
}

func isValidAccountAtom(_ value: String) -> Bool {
    isDeterministicKeyAtom(value) && !value.contains(DIRECTORY_KEY_SEPARATOR)
}

func isValidDirectoryAtom(_ value: String) -> Bool {
    isDeterministicKeyAtom(value) && !value.contains(DIRECTORY_KEY_SEPARATOR)
}

func isValidGeneralAtom(_ value: String) -> Bool {
    isDeterministicKeyAtom(value)
}

enum ChildProofWireLimits {
    // Structural serialized field width: a directory is length-prefixed with a
    // UInt16 in the proof wire format, so this is the encoding capacity, not a
    // policy limit on how long a directory may be.
    static let maximumDirectoryBytes = Int(UInt16.max)
    // Structural serialized field width: the directory path is length-prefixed
    // with a UInt16 in the proof wire format, so this is the encoding capacity,
    // not a policy limit on how deeply a chain may nest. A node that wants a
    // tighter bound on proof-walk depth enforces it as a local resource choice.
    static let maximumDepth = Int(UInt16.max)
}

public enum ChainRuntimeContextError: Error, Sendable, Equatable {
    case emptyPath
    case emptyDirectory
    case rootMustBeNexus
    case directoryContainsSeparator
    case invalidDirectory
    case directoryTooLong
    case pathTooDeep
}

/// Immutable Nexus-rooted identity for one chain process.
public struct ChainRuntimeContext: Sendable, Equatable {
    public let path: [String]

    public init(path: [String]) throws {
        guard !path.isEmpty else { throw ChainRuntimeContextError.emptyPath }
        guard path.allSatisfy({ !$0.isEmpty }) else {
            throw ChainRuntimeContextError.emptyDirectory
        }
        guard path.first == DEFAULT_ROOT_DIRECTORY else {
            throw ChainRuntimeContextError.rootMustBeNexus
        }
        guard path.dropFirst().count <= ChildProofWireLimits.maximumDepth else {
            throw ChainRuntimeContextError.pathTooDeep
        }
        // A directory must fit the proof wire format's UInt16 length prefix so
        // every chain path stays provable. This is a serialized field width, not
        // a policy limit.
        guard path.allSatisfy({
            $0.utf8.count <= ChildProofWireLimits.maximumDirectoryBytes
        }) else {
            throw ChainRuntimeContextError.directoryTooLong
        }
        guard path.allSatisfy({ !$0.contains(DIRECTORY_KEY_SEPARATOR) }) else {
            throw ChainRuntimeContextError.directoryContainsSeparator
        }
        guard path.allSatisfy(isValidDirectoryAtom) else {
            throw ChainRuntimeContextError.invalidDirectory
        }
        self.path = path
    }

    public var isRoot: Bool { path.count == 1 }
    var proofPath: [String] { Array(path.dropFirst()) }
}
