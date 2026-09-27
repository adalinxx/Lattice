import cashew

// The committed genesis state records each child chain's genesis CID. Resolving
// that content reveals the child spec, including its parent-work authority.
public typealias GenesisState = VolumeMerkleDictionaryImpl<String>
public typealias GenesisStateHeader = VolumeImpl<GenesisState>
