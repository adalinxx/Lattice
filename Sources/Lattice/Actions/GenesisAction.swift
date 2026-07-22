public struct GenesisAction: Codable, Sendable {
    public let directory: String
    public let blockCID: String

    public init(directory: String, blockCID: String) {
        self.directory = directory
        self.blockCID = blockCID
    }

    func stateDelta() -> Int {
        blockCID.utf8.count + directory.utf8.count
    }
}
