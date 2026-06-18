import cashew

// The committed genesis state records, per directory, the IDENTITY (CID) of the
// child chain's genesis block — not its content. The genesis block's content is
// validated by the child chain it belongs to (on sync), not by the parent that
// anchors it here.
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
            transforms[[genesisAction.directory]] = .insert(genesisAction.blockCID)
        }

        let proven = try await proof(paths: proofs, fetcher: fetcher)
        guard let result = try proven.transform(transforms: transforms) else {
            throw TransformErrors.transformFailed("genesis state transform returned nil")
        }
        return (result, diffCIDs(old: proven, new: result))
    }
}
