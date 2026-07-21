public struct GenesisAction: Codable, Sendable {
    public let directory: String
    public let blockCID: String
    public let parentWorkAuthorityKey: ParentWorkAuthorityKey

    public init(
        directory: String,
        blockCID: String,
        parentWorkAuthorityKey: ParentWorkAuthorityKey
    ) {
        self.directory = directory
        self.blockCID = blockCID
        self.parentWorkAuthorityKey = parentWorkAuthorityKey
    }

    func stateDelta() -> Int {
        blockCID.utf8.count + directory.utf8.count
            + parentWorkAuthorityKey.value.utf8.count
    }
}
