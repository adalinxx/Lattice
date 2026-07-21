import cashew

// The committed genesis state stays a string trie so an empty root preserves
// Nexus's exact genesis CID. Each value is a fixed-width authority prefix plus
// the child CID, decoded by `ChildGenesisAuthorization`.
public typealias GenesisState = VolumeMerkleDictionaryImpl<String>
public typealias GenesisStateHeader = VolumeImpl<GenesisState>

public extension GenesisStateHeader {
    func proveAndUpdateState(allGenesisActions: [GenesisAction], fetcher: Fetcher) async throws -> (GenesisStateHeader, StateDiff) {
        if allGenesisActions.isEmpty { return (self, .empty) }

        var proofs = [[String]: SparseMerkleProof]()
        var transforms = [[String]: Transform]()
        for genesisAction in allGenesisActions {
            if proofs[[genesisAction.directory]] != nil { throw StateErrors.conflictingActions }
            proofs[[genesisAction.directory]] = .insertion
            transforms[[genesisAction.directory]] = .insert(
                ChildGenesisAuthorization(
                    childGenesisCID: genesisAction.blockCID,
                    parentWorkAuthorityKey: genesisAction.parentWorkAuthorityKey
                ).description
            )
        }

        let proven = try await proof(paths: proofs, fetcher: fetcher)
        guard let result = try proven.transform(transforms: transforms) else {
            throw TransformErrors.transformFailed("genesis state transform returned nil")
        }
        return (result, diffCIDs(old: proven, new: result))
    }
}
